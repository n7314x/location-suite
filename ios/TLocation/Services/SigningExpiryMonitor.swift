//
//  SigningExpiryMonitor.swift
//  TLocation
//

import Foundation

/// What the app knows about when its own signature expires: the last value read
/// from the device, when that read happened, and when it is worth reading again.
///
/// The value is read from `misagent`, the service that serves the provisioning
/// profiles iOS validates against, so it tracks both Location Suite's direct
/// profile refresh and profiles installed by another recovery tool. See
/// ``AppSigningInfo`` for why the app bundle is not read instead.
///
/// The reading is persisted, because it cannot be taken on demand: it needs a
/// pairing file and a live tunnel, neither of which exists at cold launch. So the
/// UI is driven entirely from the cache, the cache is refreshed opportunistically
/// whenever a read is actually possible, and — the invariant this whole type
/// exists to hold — **a read that fails changes nothing**. A device that cannot
/// be reached leaves yesterday's answer exactly where it was; it can never turn
/// into "expired".
final class SigningExpiryMonitor: ObservableObject {
    /// One answer from the device, and the moment it was given.
    struct Reading: Equatable {
        /// `nil` means the device answered but carries no provisioning profile
        /// for this app: *unknown*, which never warns. Distinct from `reading`
        /// itself being `nil`, which means the device has never answered at all.
        let expirationDate: Date?
        let checkedAt: Date
    }

    static let shared = SigningExpiryMonitor()

    /// How old a reading may be and still be allowed to raise the launch warning.
    ///
    /// An expiry only ever moves *later* — a refresh renews it, and nothing
    /// shortens it — so a stale reading can only ever cry wolf, never miss a real
    /// lapse. Six hours is therefore a bound on how long a refresh the user has
    /// already performed can keep nagging them, while still letting a reading
    /// taken earlier the same day drive the warning, rather than demanding the
    /// tunnel be up at the exact instant the app launches.
    static let trustWindow: TimeInterval = 6 * 60 * 60

    /// Floor between two device reads. The value changes once a week at most, so
    /// anything shorter is pure traffic on an endpoint shared with the simulation.
    private static let refreshInterval: TimeInterval = 30 * 60

    /// The cache. Published so both the Settings row and the launch warning are
    /// driven by it and nothing else. Main thread only.
    @Published private(set) var reading: Reading?

    /// Guards against two overlapping reads. Main thread only, like `reading`.
    private var isReading = false

    private init() {
        reading = Self.persistedReading()
    }

    /// True when there is a reading *and* it is recent enough to act on. The
    /// launch warning requires this; the Settings row does not, because it shows
    /// when the reading was taken and lets the user judge for themselves.
    var isTrustworthy: Bool {
        guard let reading else { return false }
        return Date().timeIntervalSince(reading.checkedAt) <= Self.trustWindow
    }

    // MARK: - Refreshing

    /// Reads the expiry from the device, if a read is possible and due.
    ///
    /// Every guard below is a reason to do nothing at all, never a reason to
    /// invent a value. Call it as often as is convenient — on appear, on becoming
    /// active, whenever the tunnel connects; it is cheap when it declines.
    ///
    /// **Queue.** The FFI work runs on the serial `LocationSimulationCommandQueue`,
    /// the same queue every location-simulation command uses, and never on the
    /// main thread. That is not incidental:
    ///
    /// * The read only borrows a transport that is already open: first the idle
    ///   retained LocationSimulation adapter/handshake, otherwise
    ///   `JITEnableContext`'s existing pair. It never calls `ensureTunnel()`,
    ///   performs a second RemotePairing handshake, or tears down the warm
    ///   LocationSimulation session.
    /// * Being serial, it also means one read at a time and never a read
    ///   overlapping a resend.
    ///
    /// A simulation command issued while a read is in flight waits for its few
    /// RSD round trips. When a simulation is already active the read is skipped;
    /// nothing here is urgent enough to disturb a working simulation.
    func refreshIfPossible(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshIfPossible(reason: reason) }
            return
        }

        guard !isReading else { return }

        if let reading, Date().timeIntervalSince(reading.checkedAt) < Self.refreshInterval {
            return
        }

        // Deliberately does not *build* a tunnel. It can borrow either the idle
        // warm LocationSimulation RSD transport or JITEnableContext's existing
        // tunnel, but it never destroys the former or creates a competing
        // RemotePairing handshake.
        let plan = DeviceMaintenanceTransport.plan
        guard plan == .reuseWarmSession || plan == .reuseExistingTunnel else { return }
        guard !LocationSimulationSession.isActive else { return }

        isReading = true
        LocationSimulationCommandQueue.shared.async { [weak self] in
            // Re-checked on the far side of the serial queue, where the state has
            // settled: a `simulate_location` that was mid-rebuild when the checks
            // above ran has returned by the time this block starts.
            let outcome: Reading? = LocationSimulationSession.isActive
                ? nil
                : Self.readFromDevice(reason: reason)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                // `nil` is "the device did not answer". The cache stays exactly
                // as it was — this is the invariant in the type comment.
                guard let outcome else { return }
                self.store(outcome)
            }
        }
    }

    /// The device read itself. Returns `nil` for *no answer* — a failure, which
    /// must leave the cache untouched — as opposed to a `Reading` whose
    /// `expirationDate` is `nil`, which is the device answering "no profile for
    /// this app".
    private static func readFromDevice(reason: String) -> Reading? {
        // Read from the bundle rather than hardcoded, so a rename or a fork does
        // not silently start matching nothing.
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            LogManager.shared.addWarningLog(
                "Signing expiry check skipped: this build reports no bundle identifier."
            )
            return nil
        }

        do {
            let profiles = try DeviceMaintenanceTransport.readProfiles()
            let expiry = AppSigningInfo.expirationDate(
                forBundleIdentifier: bundleIdentifier,
                in: profiles
            )

            if let expiry {
                LogManager.shared.addInfoLog(
                    "Signing expiry read from the device after \(reason): \(AppSigningInfo.formatted(expiry)) (\(profiles.count) profiles on device)."
                )
            } else {
                LogManager.shared.addInfoLog(
                    "Signing expiry read from the device after \(reason): none of the \(profiles.count) profiles on the device covers \(bundleIdentifier)."
                )
            }

            return Reading(expirationDate: expiry, checkedAt: Date())
        } catch {
            // A warning, not an error: no tunnel and no pairing file are the
            // normal state of this app at launch, and the readiness overlay
            // already says so far more usefully than an alert from here would.
            LogManager.shared.addWarningLog(
                "Could not read the signing expiry from the device after \(reason): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Persistence

    /// A successful read is authoritative, including when it found nothing: the
    /// device is the source of truth, so "checked, no profile" replaces a
    /// previously known date rather than silently keeping it alive.
    private func store(_ newReading: Reading) {
        reading = newReading

        let defaults = UserDefaults.standard
        if let expirationDate = newReading.expirationDate {
            defaults.set(
                expirationDate.timeIntervalSince1970,
                forKey: UserDefaults.Keys.signingExpiryDate
            )
        } else {
            defaults.removeObject(forKey: UserDefaults.Keys.signingExpiryDate)
        }
        defaults.set(
            newReading.checkedAt.timeIntervalSince1970,
            forKey: UserDefaults.Keys.signingExpiryCheckedAt
        )
        SigningExpiryNotificationScheduler.shared.scheduleIfAuthorized(
            expirationDate: newReading.expirationDate
        )
    }

    /// Commits a value only after the profile refresh pipeline has installed a
    /// profile and reread it from misagent. Apple API output is never allowed to
    /// call this method directly.
    func recordAuthoritativeReading(expirationDate: Date?, checkedAt: Date) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.recordAuthoritativeReading(expirationDate: expirationDate, checkedAt: checkedAt)
            }
            return
        }
        store(Reading(expirationDate: expirationDate, checkedAt: checkedAt))
    }

    /// The timestamp is what records that a read ever happened, so its absence —
    /// not the date's — is what "never checked" means.
    private static func persistedReading() -> Reading? {
        let defaults = UserDefaults.standard
        guard let checkedAt = defaults.object(
            forKey: UserDefaults.Keys.signingExpiryCheckedAt
        ) as? Double else {
            return nil
        }

        let expiry = (defaults.object(forKey: UserDefaults.Keys.signingExpiryDate) as? Double)
            .map(Date.init(timeIntervalSince1970:))

        return Reading(
            expirationDate: expiry,
            checkedAt: Date(timeIntervalSince1970: checkedAt)
        )
    }
}

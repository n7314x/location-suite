//
//  RootView.swift
//  TLocation
//

import Combine
import SwiftUI
import UIKit

private enum RootViewLinks {
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!

    static let localDevVPN: [URL] = [
        URL(string: "stosvpn://")!,
        localDevVPNAppStore
    ]
}

/// Opens the first URL in `candidates` that the system actually resolves, chaining
/// through `open`'s completion handler.
///
/// Deliberately declaration-free: no `LSApplicationQueriesSchemes` entry and no
/// `canOpenURL` check. A scheme that does not resolve — app missing, or renamed
/// since LocalDevVPN was StosVPN — just reports failure and hands off to the next
/// candidate, so a wrong guess costs nothing but is invisible to the user.
///
/// A free function rather than a method so the recursive step does not have to
/// capture the enclosing `View` value in an escaping closure.
private func openFirstResolving(_ candidates: [URL]) {
    guard let next = candidates.first else { return }
    UIApplication.shared.open(next) { success in
        guard !success else { return }
        openFirstResolving(Array(candidates.dropFirst()))
    }
}

private enum ExternalLocationAction: Identifiable {
    case simulate(URL, Double, Double)
    case clear

    var id: String {
        switch self {
        case .simulate(let url, _, _): return "simulate-\(url.absoluteString)"
        case .clear: return "clear-location"
        }
    }

    var title: String {
        switch self {
        case .simulate: return String(localized: "Simulate Location?")
        case .clear: return String(localized: "Clear Location?")
        }
    }

    var message: String {
        switch self {
        case .simulate(_, let latitude, let longitude):
            // Formatted first so the sentence carries one ready-made
            // coordinate string rather than two bare numbers a translator
            // would have to keep in the English order.
            let coordinate = String(format: "%.6f, %.6f", latitude, longitude)
            return String(localized: "An external link wants to set the simulated location to \(coordinate).")
        case .clear:
            return String(localized: "An external link wants to clear the simulated location.")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .simulate: return String(localized: "Set Location")
        case .clear: return String(localized: "Clear Location")
        }
    }
}

struct RootView: View {
    @AppStorage("locationSuite.setupCompleted") private var setupCompleted = false
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var signing = SigningExpiryMonitor.shared
    @ObservedObject private var maintenance = SelfMaintenanceService.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingPairingFilePicker = false
    @State private var isShowingSettings = false
    @State private var pairingImportError: String?
    @State private var checkedExistingSetup = false
    @State private var pendingLocationAction: ExternalLocationAction?
    @State private var pairingExists = FileManager.default.fileExists(
        atPath: PairingFileStore.prepareURL().path
    )
    @State private var isShowingExpiryWarning = false
    @State private var suppressExpiryWarning = false
    @State private var simulationSessionOpen = LocationSimulationSession.isOpen
    /// The expiry warning is decided once per launch — but only once there is
    /// something to decide *with*. Without this, dismissing with "Later" would
    /// only last until the app next came back to the foreground.
    @State private var hasEvaluatedExpiryWarning = false

    private let statusTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isReady: Bool {
        pairingExists
            && (
                simulationSessionOpen
                    || LocationSimulationSession.isMaintained
                    || (
                        PhoneLocalConnectionPolicy.isReady(
                            endpointReachability: tunnel.endpointReachability,
                            remotePairingConnected: tunnel.isConnected
                        )
                        && mounting.coolisMounted
                    )
            )
    }

    var body: some View {
        NavigationStack {
            // The setup experience owns the screen until this device is ready.
            // Keep the map alive for session notifications but block map input.
            ZStack {
                LocationSimulationView()
                    .allowsHitTesting(isReady && setupCompleted && !isShowingExpiryWarning)

                // Strictly one card at a time — `else if`, not two independent
                // `if`s, so the two can never stack on top of each other. The
                // expiry warning wins. Dismissing it reveals setup underneath.
                if isShowingExpiryWarning {
                    expiryOverlay
                } else if !isReady || !setupCompleted {
                    SetupExperienceView(
                        pairingExists: pairingExists,
                        isReady: isReady,
                        pairingImportError: pairingImportError,
                        startsAtConnection: setupCompleted || pairingExists,
                        onImportPairing: { isShowingPairingFilePicker = true },
                        onRetryConnection: retryConnection,
                        onOpenLocalDevVPN: openLocalDevVPN,
                        onOpenSettings: { isShowingSettings = true },
                        onFinish: finishSetup
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isReady)
            .animation(.easeInOut(duration: 0.2), value: isShowingExpiryWarning)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes
        ) { result in
            importPairingFile(result)
        }
        .onAppear {
            // Existing installations with a pairing file have already passed
            // initial setup; connection recovery remains available if needed.
            if !checkedExistingSetup {
                checkedExistingSetup = true
                if pairingExists { setupCompleted = true }
            }
            startTunnelInBackground(showErrorUI: false)
            MountingProgress.shared.checkforMounted()
            signing.refreshIfPossible(reason: "launch")
            evaluateExpiryWarning()
            Task {
                    await maintenance.restoreRememberedSessionIfNeeded()
                    await maintenance.handleForegroundActivation()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                signing.refreshIfPossible(reason: "a return to the foreground")
                evaluateExpiryWarning()
                Task {
                    await maintenance.restoreRememberedSessionIfNeeded()
                    await maintenance.handleForegroundActivation()
                }
            }
        }
        // The tunnel is almost never up at the instant `onAppear` runs, so this is
        // the edge that actually gets the first read of a cold launch taken.
        .onChange(of: tunnel.isConnected) { _, isConnected in
            if isConnected {
                signing.refreshIfPossible(reason: "the tunnel connecting")
                Task {
                    await maintenance.restoreRememberedSessionIfNeeded()
                    await maintenance.handleForegroundActivation()
                }
            }
        }
        // A reading landing seconds after launch is the normal case, so the
        // decision is retried whenever one does rather than only at `onAppear`.
        .onChange(of: signing.reading) { _, _ in
            evaluateExpiryWarning()
            Task {
                    await maintenance.restoreRememberedSessionIfNeeded()
                    await maintenance.handleForegroundActivation()
                }
        }
        .onReceive(statusTimer) { _ in
            // Cheap existence check only. `prepareURL()` does directory creation and a
            // full byte-compare, which must not run on the main thread once per second.
            pairingExists = FileManager.default.fileExists(atPath: PairingFileStore.url.path)
            if mounting.mountingThread == nil, !mounting.coolisMounted {
                MountingProgress.shared.checkforMounted()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPairingFilePicker)) { _ in
            isShowingPairingFilePicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationSimulationSessionChanged)) { _ in
            simulationSessionOpen = LocationSimulationSession.isOpen
        }
        .onOpenURL { url in
            handleURL(url)
        }
        .confirmationDialog(
            pendingLocationAction?.title ?? String(localized: "External Location Request"),
            isPresented: Binding(
                get: { pendingLocationAction != nil },
                set: { if !$0 { pendingLocationAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLocationAction
        ) { action in
            Button(action.confirmationTitle, role: .destructive) {
                performLocationAction(action)
                pendingLocationAction = nil
            }
            Button("Cancel", role: .cancel) { pendingLocationAction = nil }
        } message: { action in
            Text(action.message)
        }
        .modifier(TwoFactorPromptOverlayModifier())
    }

    // MARK: - Signing expiry warning

    /// Expiry the card speaks about: whatever the device last told us, or `nil`
    /// when it has never been asked or answered "no profile for this app".
    private var expiryDate: Date? { signing.reading?.expirationDate }

    private var signatureHasExpired: Bool {
        expiryDate.map { AppSigningInfo.hasExpired($0) } ?? false
    }

    /// Decides once per launch whether to warn that the signature is about to
    /// lapse — but only once there is a reading worth deciding on.
    ///
    /// The two ways of knowing nothing are both silence, never a warning:
    ///
    /// * `signing.reading == nil` — the device has never been reachable, so
    ///   there is no expiry, only an absence. A device that cannot be read is
    ///   not a device whose signature has lapsed.
    /// * `signing.reading?.expirationDate == nil` — the device answered and
    ///   carries no profile for this app (App Store or TrollStore install).
    ///
    /// Neither marks the decision as made: a reading can still arrive seconds
    /// later, when the tunnel comes up, and `onChange(of: signing.reading)` calls
    /// back in. Only a trustworthy reading closes the question, and from then on
    /// every early return marks it made, so "Later" holds for the rest of the
    /// session even across foreground/background cycles.
    private func evaluateExpiryWarning() {
        guard !hasEvaluatedExpiryWarning else { return }

        // A reading older than the trust window can only ever cry wolf (an expiry
        // moves later, never earlier), so it is not allowed to raise the card —
        // and it does not settle the question either, because a fresh read may
        // still land this session.
        guard let expiry = signing.reading?.expirationDate, signing.isTrustworthy else { return }

        hasEvaluatedExpiryWarning = true

        guard AppSigningInfo.isExpiringSoon(expiry) else { return }

        // Suppression is keyed to this exact expiry date, so a profile refresh
        // starts warning again next week. Now that
        // the date is read from the device it actually moves, which is what makes
        // the checkbox mean what it says.
        guard !ExpiryWarningSuppression.isSuppressed(expiry) else { return }

        isShowingExpiryWarning = true
    }

    private func dismissExpiryWarning() {
        if suppressExpiryWarning, let expiry = expiryDate {
            ExpiryWarningSuppression.suppress(expiry)
        }
        isShowingExpiryWarning = false
    }

    private var expiryTitle: String {
        guard let expiry = expiryDate, !AppSigningInfo.hasExpired(expiry) else {
            return String(localized: "TLocation has expired")
        }
        let duration = AppSigningInfo.durationPhrase(expiry.timeIntervalSinceNow)
        return String(localized: "TLocation expires in \(duration)")
    }

    private var expiryBody: String {
        signatureHasExpired
            ? String(localized: "This installation has expired. Location Suite cannot repair itself after it stops launching; reinstall it with iLoader, then return here before the next expiry.")
            : String(localized: "Open Self Maintenance to renew the provisioning profile on this iPhone. If the app fully expires, use iLoader for emergency recovery.")
    }

    /// Same visual language as the setup experience: full-screen material scrim
    /// plus a rounded material card. Uses no iOS-26-only API, so it needs no
    /// availability gate — `.regularMaterial` is the floor on iOS 17.4.
    private var expiryOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            expiryCard
                .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private var expiryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label(expiryTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(signatureHasExpired ? .red : .orange)
                Text(expiryBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Refreshing keeps your pairing file and bookmarks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $suppressExpiryWarning) {
                Text("Don't show again for this expiry")
                    .font(.subheadline)
            }

            VStack(spacing: 10) {
                Button {
                    isShowingSettings = true
                    dismissExpiryWarning()
                } label: {
                    Label("Open Self Maintenance", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    dismissExpiryWarning()
                } label: {
                    Text("Later")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    // MARK: - Guided connection recovery

    private func openLocalDevVPN() {
        openFirstResolving(RootViewLinks.localDevVPN)
    }

    /// Guided recovery can be on screen with a simulation still running —
    /// `concludeSimulationHasStopped()` puts it there, and so does any tunnel
    /// failure — so this tap has to assume a resend may be mid-handshake. The
    /// tunnel start therefore queues behind whatever the location-simulation
    /// queue is doing rather than racing it for `<targetIP>:49152`; it is
    /// deferred, never dropped. See `startTunnelAfterPendingLocationCommands`.
    ///
    /// The other two are immediate on purpose: they are what makes the tap feel
    /// answered, and neither touches the device's location-simulation service.
    private func retryConnection() {
        markTunnelDisconnected()
        startTunnelAfterPendingLocationCommands(showErrorUI: false)
        MountingProgress.shared.checkforMounted()
    }

    private func importPairingFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try PairingFileStore.importFromPicker(url)
                pairingExists = true
                pairingImportError = nil
                markTunnelDisconnected()
                // Same endpoint contention as Retry above: a pairing file can be
                // imported from guided recovery with a simulation still
                // running.
                startTunnelAfterPendingLocationCommands(showErrorUI: false)
                AlertPresenter.dismissPresentedAlert()
            } catch {
                pairingImportError = error.localizedDescription
                LogManager.shared.addErrorLog("Failed to import pairing file: \(error.localizedDescription)")
            }
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            pairingImportError = error.localizedDescription
            LogManager.shared.addErrorLog("Pairing file picker failed: \(error.localizedDescription)")
        }
    }

    private func finishSetup(createRoute: Bool) {
        guard isReady else { return }
        setupCompleted = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if createRoute {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openRouteComposerRequested, object: nil)
            }
        }
    }

    // MARK: - URL scheme (tlocation://)

    private func handleURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        switch host {
        case "simulate-location", "set-location", "location", "location-simulation":
            confirmSimulatedLocation(from: url)
        case "clear-location", "stop-location":
            pendingLocationAction = .clear
        default:
            break
        }
    }

    private func confirmSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: String(localized: "Invalid Location URL"),
                // A literal URL template: nothing here is translatable.
                message: "Use tlocation://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }
        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: String(localized: "Invalid Coordinates"),
                message: String(localized: "Latitude must be between -90 and 90. Longitude must be between -180 and 180."),
                showOk: true
            )
            return
        }
        pendingLocationAction = .simulate(url, coordinate.latitude, coordinate.longitude)
    }

    private func performLocationAction(_ action: ExternalLocationAction) {
        switch action {
        case .simulate(let url, _, _):
            requestSimulatedLocation(from: url)
        case .clear:
            requestClearSimulatedLocation()
        }
    }

    /// Hands the request to `LocationSimulationView`, which is the single owner of the
    /// simulation state (map pin, 4s resend loop, route playback, background task).
    /// Calling the FFI here instead would leave that state out of sync: the resend loop
    /// would revive a cleared position, and a URL-started simulation could not be stopped
    /// from the map.
    private func requestSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url),
              coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        guard requirePairingFile(
            message: String(localized: "Import a pairing file before simulating location from a URL.")
        ) else { return }

        // No coordinate in the log — see `simulate_location`.
        LogManager.shared.addInfoLog("Requested simulated location from URL")
        LocationSimulationRequest.postSimulate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func requestClearSimulatedLocation() {
        guard requirePairingFile(
            message: String(localized: "Import a pairing file before clearing the simulated location from a URL.")
        ) else { return }

        LogManager.shared.addInfoLog("Requested clear of simulated location from URL")
        LocationSimulationRequest.postClear()
    }

    private func requirePairingFile(message: String) -> Bool {
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            showAlert(title: String(localized: "Pairing File Required"), message: message, showOk: true)
            return false
        }
        return true
    }

    private func coordinate(from url: URL) -> (latitude: Double, longitude: Double)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                    return value
                }
            }
            return nil
        }

        if let latitudeText = queryValue(["lat", "latitude"]),
           let longitudeText = queryValue(["lon", "lng", "long", "longitude"]),
           let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (latitude, longitude)
        }

        let coordinateText = queryValue(["coordinate", "coordinates", "coords", "q", "ll"])
            ?? components?.path
            ?? ""
        let values = numbers(in: coordinateText)
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func coordinateIsValid(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    private func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

import Combine
import Foundation

@MainActor
final class SelfMaintenanceService: ObservableObject {
    private struct PreparedSignIn: Sendable {
        let result: AppleDeveloperSignInResult
        let selectedTeamIdentifier: String?
    }

    enum AccountState: Equatable {
        case notSignedIn
        case selectingTeam
        case signedIn(teamName: String)
    }

    static let shared = SelfMaintenanceService()
    static let defaultAnisetteEndpoint = "https://ani.sidestore.io"
    static let defaultAnisetteFallbacks = "https://ani.stikstore.app"
    static let anisetteTimeout: TimeInterval = 45

    @Published private(set) var accountState: AccountState = .notSignedIn
    @Published private(set) var availableTeams: [DeveloperTeamSummary] = []
    @Published private(set) var selectedTeamIdentifier: String?
    @Published private(set) var activeAnisetteEndpoint: String?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: SelfMaintenanceError?
    @Published private(set) var history: SigningRefreshHistory

    private let defaults: UserDefaults
    private let secrets: SecretStorage
    private let gate = MaintenanceOperationGate()
    private let accountQueue = DispatchQueue(
        label: "vn.truongkma.tlocation.self-maintenance.account",
        qos: .userInitiated
    )
    private var session: AppleDeveloperSessionHandle?
    /// A live Apple developer session cannot be serialized safely. On each app
    /// process we rebuild it once from the device-only Keychain credential when
    /// the user enabled Remember Password.
    private var didAttemptRememberedSessionRestore = false

    init(defaults: UserDefaults = .standard, secrets: SecretStorage = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        self.history = Self.loadHistory(from: defaults)
        defaults.register(defaults: [
            UserDefaults.Keys.autoRefreshSigning: true,
            UserDefaults.Keys.rememberApplePassword: false,
            UserDefaults.Keys.anisettePrimaryEndpoint: Self.defaultAnisetteEndpoint,
            UserDefaults.Keys.anisetteFallbackEndpoints: Self.defaultAnisetteFallbacks,
        ])
        selectedTeamIdentifier = defaults.string(forKey: UserDefaults.Keys.selectedDeveloperTeam)
    }

    var hasReusableCredentials: Bool {
        if session != nil { return true }
        guard defaults.bool(forKey: UserDefaults.Keys.rememberApplePassword) else { return false }
        return (try? secrets.data(for: SelfMaintenanceSecretAccount.applePassword)) != nil
    }

    var isSignedIn: Bool { session != nil && selectedTeamIdentifier != nil }

    func signIn(
        appleID: String,
        password: String,
        rememberPassword: Bool,
        primaryAnisetteEndpoint: String,
        fallbackAnisetteEndpoints: String
    ) async {
        guard gate.begin() else {
            publish(error: SelfMaintenanceError(
                category: .unknown,
                message: "Another self-maintenance operation is already running."
            ))
            return
        }
        isWorking = true
        statusMessage = "Signing in to Apple…"
        lastError = nil
        defer {
            isWorking = false
            gate.end()
        }

        do {
            let endpoints = try Self.anisetteEndpoints(
                primary: primaryAnisetteEndpoint,
                fallbacks: fallbackAnisetteEndpoints
            )
            let prepared = try await performSignIn(
                appleID: appleID,
                password: password,
                endpoints: endpoints,
                preferredTeam: defaults.string(forKey: UserDefaults.Keys.selectedDeveloperTeam)
            )
            defaults.set(appleID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: UserDefaults.Keys.appleAccountEmail)
            defaults.set(primaryAnisetteEndpoint, forKey: UserDefaults.Keys.anisettePrimaryEndpoint)
            defaults.set(fallbackAnisetteEndpoints, forKey: UserDefaults.Keys.anisetteFallbackEndpoints)
            defaults.set(rememberPassword, forKey: UserDefaults.Keys.rememberApplePassword)
            if rememberPassword {
                try secrets.set(Data(password.utf8), for: SelfMaintenanceSecretAccount.applePassword)
            } else {
                try secrets.remove(account: SelfMaintenanceSecretAccount.applePassword)
            }
            apply(prepared)
            didAttemptRememberedSessionRestore = true
            statusMessage = selectedTeamIdentifier == nil
                ? "Choose the personal team that signed this installation."
                : "Apple developer session is ready."
            await SigningExpiryNotificationScheduler.shared.requestAuthorizationAndSchedule(
                expirationDate: SigningExpiryMonitor.shared.reading?.expirationDate
            )
        } catch {
            let normalized = normalize(error)
            publish(error: normalized)
            LogManager.shared.addWarningLog(normalized.safeSignInLogMessage)
        }
    }

    func restoreRememberedSessionIfNeeded() async {
        guard session == nil, !didAttemptRememberedSessionRestore else { return }
        didAttemptRememberedSessionRestore = true

        guard defaults.bool(forKey: UserDefaults.Keys.rememberApplePassword),
              let appleID = defaults.string(forKey: UserDefaults.Keys.appleAccountEmail)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !appleID.isEmpty,
              let passwordData = try? secrets.data(for: SelfMaintenanceSecretAccount.applePassword),
              let password = String(data: passwordData, encoding: .utf8),
              !password.isEmpty else {
            return
        }

        let primary = defaults.string(forKey: UserDefaults.Keys.anisettePrimaryEndpoint)
            ?? Self.defaultAnisetteEndpoint
        let fallbacks = defaults.string(forKey: UserDefaults.Keys.anisetteFallbackEndpoints)
            ?? Self.defaultAnisetteFallbacks

        await signIn(
            appleID: appleID,
            password: password,
            rememberPassword: true,
            primaryAnisetteEndpoint: primary,
            fallbackAnisetteEndpoints: fallbacks
        )
    }

    /// Allows an explicit foreground/manual retry after a transient restore
    /// failure without creating repeated automatic Apple login attempts.
    func allowRememberedSessionRestoreRetry() {
        if session == nil { didAttemptRememberedSessionRestore = false }
    }

    func selectTeam(_ identifier: String) async {
        guard let session else {
            publish(error: SelfMaintenanceError(
                category: .developerSessionFailed,
                message: "Sign in before selecting a developer team."
            ))
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await onAccountQueue {
                try AppleDeveloperBridge.selectTeam(identifier, session: session)
            }
            selectedTeamIdentifier = identifier
            defaults.set(identifier, forKey: UserDefaults.Keys.selectedDeveloperTeam)
            let team = availableTeams.first { $0.identifier == identifier }
            accountState = .signedIn(teamName: team?.displayName ?? identifier)
            statusMessage = "Apple developer session is ready."
            lastError = nil
        } catch {
            publish(error: normalize(error))
        }
    }

    func signOut() {
        didAttemptRememberedSessionRestore = true
        session = nil
        availableTeams = []
        activeAnisetteEndpoint = nil
        accountState = .notSignedIn
        statusMessage = nil
        lastError = nil
        defaults.set(false, forKey: UserDefaults.Keys.rememberApplePassword)
        try? secrets.remove(account: SelfMaintenanceSecretAccount.applePassword)
        // Anisette state is deliberately retained. Signing out must not destroy
        // the stable device identity used by the v3 provider.
    }

    func forgetRememberedPassword() {
        defaults.set(false, forKey: UserDefaults.Keys.rememberApplePassword)
        do {
            try secrets.remove(account: SelfMaintenanceSecretAccount.applePassword)
        } catch {
            publish(error: normalize(error))
        }
    }

    func refreshSigningNow(password: String? = nil, automatic: Bool = false) async {
        guard gate.begin() else {
            if automatic { return }
            publish(error: SelfMaintenanceError(
                category: .unknown,
                message: "Another self-maintenance operation is already running."
            ))
            return
        }
        isWorking = true
        statusMessage = "Reading the installed provisioning profile…"
        lastError = nil
        let attemptedAt = Date()
        var observedBefore: Date?
        defer {
            isWorking = false
            gate.end()
        }

        do {
            guard !LocationSimulationSession.isActive else {
                throw SelfMaintenanceError(
                    category: .deviceTransportUnavailable,
                    message: "Stop the active location simulation before refreshing signing. The warm session was not disturbed."
                )
            }
            guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
                throw SelfMaintenanceError(category: .profileCreationFailed, message: "This build has no bundle identifier.")
            }

            let deviceSnapshot = try await onDeviceQueue { try DeviceMaintenanceTransport.snapshot() }
            guard let currentProfile = AppSigningInfo.currentProfile(
                forBundleIdentifier: bundleIdentifier,
                in: deviceSnapshot.profiles
            ) else {
                throw SelfMaintenanceError(
                    category: .profileCreationFailed,
                    message: "The device did not report a current provisioning profile for Location Suite."
                )
            }
            observedBefore = currentProfile.expirationDate

            if session == nil {
                let appleID = defaults.string(forKey: UserDefaults.Keys.appleAccountEmail) ?? ""
                let secret = try passwordData(override: password)
                guard let secret, let password = String(data: secret, encoding: .utf8), !password.isEmpty else {
                    throw SelfMaintenanceError(
                        category: .appleAuthenticationFailed,
                        message: "Enter your Apple Account password in Self Maintenance to refresh signing."
                    )
                }
                let endpoints = try Self.anisetteEndpoints(
                    primary: defaults.string(forKey: UserDefaults.Keys.anisettePrimaryEndpoint)
                        ?? Self.defaultAnisetteEndpoint,
                    fallbacks: defaults.string(forKey: UserDefaults.Keys.anisetteFallbackEndpoints)
                        ?? Self.defaultAnisetteFallbacks
                )
                let prepared = try await performSignIn(
                    appleID: appleID,
                    password: password,
                    endpoints: endpoints,
                    preferredTeam: currentProfile.teamIdentifier
                )
                apply(prepared)
            }

            guard let session else {
                throw SelfMaintenanceError(category: .developerSessionFailed, message: "The Apple developer session is unavailable.")
            }
            guard selectedTeamIdentifier == currentProfile.teamIdentifier || currentProfile.teamIdentifier == nil else {
                throw SelfMaintenanceError(
                    category: .teamSelectionFailed,
                    message: "Select the personal team that signed the current Location Suite profile."
                )
            }

            statusMessage = "Requesting a renewed profile from Apple…"
            let renewedProfile = try await onAccountQueue {
                try AppleDeveloperBridge.refreshProfile(
                    session: session,
                    device: deviceSnapshot.identity,
                    portalBundleIdentifier: currentProfile.portalBundleIdentifier
                )
            }
            guard let proposed = AppSigningInfo.currentProfile(
                forBundleIdentifier: bundleIdentifier,
                in: [renewedProfile]
            ), proposed.expirationDate > currentProfile.expirationDate else {
                throw SelfMaintenanceError(
                    category: .profileDidNotExtendExpiry,
                    message: "Apple returned a profile, but its expiration was not later than the installed profile. Nothing was installed."
                )
            }

            statusMessage = "Installing and verifying the renewed profile…"
            guard !LocationSimulationSession.isActive else {
                throw SelfMaintenanceError(
                    category: .deviceTransportUnavailable,
                    message: "A location simulation started before profile installation. Retry after stopping it; the warm session was not disturbed."
                )
            }
            let profilesAfter = try await onDeviceQueue {
                try DeviceMaintenanceTransport.installAndReadProfiles(renewedProfile)
            }
            let actualAfter = AppSigningInfo.expirationDate(
                forBundleIdentifier: bundleIdentifier,
                in: profilesAfter
            )
            switch SigningRefreshVerifier.verify(before: currentProfile.expirationDate, after: actualAfter) {
            case .verified(let before, let after):
                history = SigningRefreshHistoryReducer.success(
                    previous: history,
                    attemptedAt: attemptedAt,
                    before: before,
                    after: after
                )
                storeHistory()
                SigningExpiryMonitor.shared.recordAuthoritativeReading(
                    expirationDate: after,
                    checkedAt: Date()
                )
                SigningExpiryNotificationScheduler.shared.scheduleIfAuthorized(expirationDate: after)
                statusMessage = "Signing renewed and verified on this iPhone."
                lastError = nil
                LogManager.shared.addInfoLog("Profile-only signing refresh succeeded after the device reported a later expiration.")
            case .missingBefore, .missingAfter, .didNotIncrease:
                throw SelfMaintenanceError(
                    category: .profileDidNotExtendExpiry,
                    message: "The profile was installed, but the device did not report a later expiration. Refresh was not accepted as successful."
                )
            }
        } catch {
            let normalized = normalize(error)
            history = SigningRefreshHistoryReducer.failure(
                previous: history,
                attemptedAt: attemptedAt,
                category: normalized.category,
                observedBefore: observedBefore
            )
            storeHistory()
            publish(error: normalized)
            LogManager.shared.addWarningLog("Profile-only signing refresh failed: \(normalized.category.rawValue).")
        }
    }

    func handleForegroundActivation() async {
        let autoEnabled = defaults.bool(forKey: UserDefaults.Keys.autoRefreshSigning)
        let plan = DeviceMaintenanceTransport.plan
        let safeTransport = plan == .reuseWarmSession || plan == .reuseExistingTunnel
        let decision = SigningAutoRefreshPolicy.decision(
            enabled: autoEnabled,
            expirationDate: SigningExpiryMonitor.shared.reading?.expirationDate,
            checkedAt: SigningExpiryMonitor.shared.reading?.checkedAt,
            trustWindow: SigningExpiryMonitor.trustWindow,
            hasAccountSessionOrRememberedPassword: hasReusableCredentials,
            hasSafeDeviceTransport: safeTransport,
            simulationActive: LocationSimulationSession.isActive,
            history: history
        )
        switch decision {
        case .attempt:
            await refreshSigningNow(automatic: true)
        case .needsAccount:
            surfaceForegroundPromptOnce(
                "Location Suite signing expires within 72 hours. Open Self Maintenance in Settings and enter your Apple Account password."
            )
        case .needsDeviceTransport:
            surfaceForegroundPromptOnce(
                "Location Suite signing expires within 72 hours. Open LocalDevVPN, then return to Location Suite to refresh."
            )
        default:
            break
        }
    }

    private func performSignIn(
        appleID: String,
        password: String,
        endpoints: [URL],
        preferredTeam: String?
    ) async throws -> PreparedSignIn {
        let storageDirectory = try Self.protectedStorageDirectory()
        // Read the main-actor configuration before entering the Sendable queue
        // closure. This also keeps the boundary valid under Swift 6 isolation.
        let timeout = Self.anisetteTimeout
        let prepared = try await onAccountQueue {
            let result = try AppleDeveloperBridge.signIn(
                appleID: appleID,
                password: password,
                anisetteEndpoints: endpoints,
                storageDirectory: storageDirectory,
                timeout: timeout
            )
            let identifier = TeamSelectionPolicy.selection(
                from: result.summary.teams,
                preferredIdentifier: preferredTeam
            )
            if let identifier {
                try AppleDeveloperBridge.selectTeam(identifier, session: result.session)
            }
            return PreparedSignIn(result: result, selectedTeamIdentifier: identifier)
        }
        try Self.applyCompleteProtection(to: storageDirectory)
        return prepared
    }

    private func apply(_ prepared: PreparedSignIn) {
        let result = prepared.result
        session = result.session
        availableTeams = result.summary.teams
        activeAnisetteEndpoint = result.summary.anisetteEndpoint
        let selection = prepared.selectedTeamIdentifier
        selectedTeamIdentifier = selection
        if let selection {
            defaults.set(selection, forKey: UserDefaults.Keys.selectedDeveloperTeam)
            let team = result.summary.teams.first { $0.identifier == selection }
            accountState = .signedIn(teamName: team?.displayName ?? selection)
        } else {
            accountState = .selectingTeam
        }
    }

    private func passwordData(override: String?) throws -> Data? {
        if let override, !override.isEmpty { return Data(override.utf8) }
        guard defaults.bool(forKey: UserDefaults.Keys.rememberApplePassword) else { return nil }
        return try secrets.data(for: SelfMaintenanceSecretAccount.applePassword)
    }

    private func publish(error: SelfMaintenanceError) {
        lastError = error
        statusMessage = error.message
    }

    private func normalize(_ error: Error) -> SelfMaintenanceError {
        if let error = error as? SelfMaintenanceError { return error }
        let nsError = error as NSError
        let category: SelfMaintenanceFailureCategory
        if nsError.domain == "profiles" {
            category = nsError.localizedDescription.localizedCaseInsensitiveContains("install")
                ? .profileInstallFailed
                : .deviceTransportUnavailable
        } else {
            category = .unknown
        }
        return SelfMaintenanceError(
            category: category,
            message: SensitiveDiagnosticRedactor.redact(nsError.localizedDescription)
        )
    }

    private func storeHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: UserDefaults.Keys.signingRefreshHistory)
    }

    private static func loadHistory(from defaults: UserDefaults) -> SigningRefreshHistory {
        guard let data = defaults.data(forKey: UserDefaults.Keys.signingRefreshHistory),
              let history = try? JSONDecoder().decode(SigningRefreshHistory.self, from: data) else {
            return .empty
        }
        return history
    }

    private static func anisetteEndpoints(primary: String, fallbacks: String) throws -> [URL] {
        let raw = [primary] + fallbacks
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map(String.init)
        var seen = Set<String>()
        let urls = raw.compactMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
                return nil
            }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
        guard !urls.isEmpty else {
            throw SelfMaintenanceError(
                category: .anisetteUnavailable,
                message: "Configure at least one valid HTTPS v3 anisette endpoint."
            )
        }
        return urls
    }

    private static func protectedStorageDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("SelfMaintenancePrivate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try applyCompleteProtection(to: directory)
        return directory
    }

    private static func applyCompleteProtection(to directory: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        }
    }

    private func onAccountQueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            accountQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private func onDeviceQueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private func surfaceForegroundPromptOnce(_ message: String) {
        let now = Date()
        if let last = defaults.object(forKey: UserDefaults.Keys.signingForegroundPromptAt) as? Date,
           now.timeIntervalSince(last) < SigningAutoRefreshPolicy.failureCooldown {
            return
        }
        defaults.set(now, forKey: UserDefaults.Keys.signingForegroundPromptAt)
        statusMessage = message
        showAlert(title: "Signing renewal needs attention", message: message, showOk: true)
    }
}

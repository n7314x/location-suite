import Foundation

enum SelfMaintenanceFailureCategory: String, Codable, CaseIterable, Sendable {
    case anisetteUnavailable
    case appleAuthenticationFailed
    case twoFactorRequired
    case twoFactorCancelled
    case grandSlamUnavailable
    case developerSessionFailed
    case teamSelectionFailed
    case deviceRegistrationFailed
    case certificateUnavailable
    case certificateLimitReached
    case profileCreationFailed
    case profileInstallFailed
    case profileDidNotExtendExpiry
    case ipaDownloadFailed
    case ipaHashMismatch
    case ipaInvalid
    case signingFailed
    case afcUploadFailed
    case installationProxyFailed
    case selfInstallInterrupted
    case localDevVPNUnavailable
    case deviceTransportUnavailable
    case unknown
}

struct SelfMaintenanceError: Error, Codable, Equatable, LocalizedError, Sendable {
    let category: SelfMaintenanceFailureCategory
    let message: String

    var errorDescription: String? { message }

    static func serviceUnavailable(_ category: SelfMaintenanceFailureCategory) -> SelfMaintenanceError {
        SelfMaintenanceError(
            category: category,
            message: "Apple signing services are temporarily unavailable."
        )
    }
}

struct DeveloperTeamSummary: Codable, Equatable, Identifiable, Sendable {
    let identifier: String
    let name: String?
    let teamType: String?
    let status: String?

    var id: String { identifier }

    var displayName: String {
        let base = name?.isEmpty == false ? name! : "Personal Team"
        return "\(base) (\(identifier))"
    }

    var looksPersonal: Bool {
        let value = "\(name ?? "") \(teamType ?? "")".lowercased()
        return value.contains("personal") || value.contains("individual") || value.contains("free")
    }
}

struct AccountSignInSummary: Codable, Equatable, Sendable {
    let anisetteEndpoint: String
    let teams: [DeveloperTeamSummary]
}

enum TeamSelectionPolicy {
    static func selection(
        from teams: [DeveloperTeamSummary],
        preferredIdentifier: String?
    ) -> String? {
        if let preferredIdentifier,
           teams.contains(where: { $0.identifier == preferredIdentifier }) {
            return preferredIdentifier
        }
        if teams.count == 1 { return teams[0].identifier }
        let personal = teams.filter(\.looksPersonal)
        return personal.count == 1 ? personal[0].identifier : nil
    }
}

struct SigningRefreshHistory: Codable, Equatable, Sendable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastFailureCategory: SelfMaintenanceFailureCategory?
    var actualExpiryBefore: Date?
    var actualExpiryAfter: Date?

    static let empty = SigningRefreshHistory()

    init(
        lastAttempt: Date? = nil,
        lastSuccess: Date? = nil,
        lastFailureCategory: SelfMaintenanceFailureCategory? = nil,
        actualExpiryBefore: Date? = nil,
        actualExpiryAfter: Date? = nil
    ) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.lastFailureCategory = lastFailureCategory
        self.actualExpiryBefore = actualExpiryBefore
        self.actualExpiryAfter = actualExpiryAfter
    }
}

enum VerifiedExpiryIncrease: Equatable, Sendable {
    case verified(before: Date, after: Date)
    case missingBefore
    case missingAfter
    case didNotIncrease(before: Date, after: Date)
}

enum SigningRefreshVerifier {
    static func verify(before: Date?, after: Date?) -> VerifiedExpiryIncrease {
        guard let before else { return .missingBefore }
        guard let after else { return .missingAfter }
        guard after > before else { return .didNotIncrease(before: before, after: after) }
        return .verified(before: before, after: after)
    }
}

enum SigningRefreshHistoryReducer {
    static func success(
        previous: SigningRefreshHistory,
        attemptedAt: Date,
        before: Date,
        after: Date
    ) -> SigningRefreshHistory {
        SigningRefreshHistory(
            lastAttempt: attemptedAt,
            lastSuccess: attemptedAt,
            lastFailureCategory: nil,
            actualExpiryBefore: before,
            actualExpiryAfter: after
        )
    }

    /// A failed operation records its category and attempted preflight value,
    /// but never overwrites the last authoritative post-refresh expiry.
    static func failure(
        previous: SigningRefreshHistory,
        attemptedAt: Date,
        category: SelfMaintenanceFailureCategory,
        observedBefore: Date?
    ) -> SigningRefreshHistory {
        var result = previous
        result.lastAttempt = attemptedAt
        result.lastFailureCategory = category
        if let observedBefore { result.actualExpiryBefore = observedBefore }
        return result
    }
}

enum SigningAutoRefreshDecision: Equatable, Sendable {
    case disabled
    case noTrustedExpiry
    case notDue
    case cooldown
    case needsAccount
    case blockedBySimulation
    case needsDeviceTransport
    case attempt
}

enum SigningAutoRefreshPolicy {
    static let threshold: TimeInterval = 72 * 60 * 60
    static let failureCooldown: TimeInterval = 6 * 60 * 60
    static let successCooldown: TimeInterval = 12 * 60 * 60

    static func decision(
        enabled: Bool,
        expirationDate: Date?,
        checkedAt: Date?,
        trustWindow: TimeInterval,
        hasAccountSessionOrRememberedPassword: Bool,
        hasSafeDeviceTransport: Bool,
        simulationActive: Bool,
        history: SigningRefreshHistory,
        now: Date = Date()
    ) -> SigningAutoRefreshDecision {
        guard enabled else { return .disabled }
        guard let expirationDate, let checkedAt,
              now.timeIntervalSince(checkedAt) <= trustWindow else {
            return .noTrustedExpiry
        }
        guard expirationDate.timeIntervalSince(now) <= threshold else { return .notDue }
        if let lastAttempt = history.lastAttempt {
            let cooldown = history.lastFailureCategory == nil ? successCooldown : failureCooldown
            if now.timeIntervalSince(lastAttempt) < cooldown { return .cooldown }
        }
        guard !simulationActive else { return .blockedBySimulation }
        guard hasAccountSessionOrRememberedPassword else { return .needsAccount }
        guard hasSafeDeviceTransport else { return .needsDeviceTransport }
        return .attempt
    }
}

enum MaintenanceTransportPlan: Equatable, Sendable {
    case reuseWarmSession
    case reuseExistingTunnel
    case blockedBySimulation
    case requireWiFi
    case unavailable
}

enum MaintenanceTransportPlanner {
    static func plan(
        warmSessionOpen: Bool,
        simulationActive: Bool,
        existingTunnelAvailable: Bool,
        cellular: Bool
    ) -> MaintenanceTransportPlan {
        if simulationActive { return .blockedBySimulation }
        if warmSessionOpen { return .reuseWarmSession }
        if existingTunnelAvailable { return .reuseExistingTunnel }
        if cellular { return .requireWiFi }
        return .unavailable
    }
}

enum CertificateCapacityAction: Equatable, Sendable {
    case reuseExisting
    case create
    case stopAtLimit
}

enum CertificateReusePolicy {
    /// Revocation is intentionally absent. A replacement can only be a separate,
    /// explicit user-confirmed workflow added after the profile-only gate.
    static func action(hasMatchingIdentity: Bool, hasCapacity: Bool) -> CertificateCapacityAction {
        if hasMatchingIdentity { return .reuseExisting }
        return hasCapacity ? .create : .stopAtLimit
    }
}

enum TwoFactorState: Equatable, Sendable {
    case idle
    case waiting
    case submitted
    case cancelled
    case completed
}

enum TwoFactorEvent: Sendable {
    case requested
    case codeSubmitted
    case cancel
    case accepted
}

enum TwoFactorStateMachine {
    static func reduce(_ state: TwoFactorState, _ event: TwoFactorEvent) -> TwoFactorState {
        switch (state, event) {
        case (.idle, .requested): return .waiting
        case (.waiting, .codeSubmitted): return .submitted
        case (.waiting, .cancel): return .cancelled
        case (.submitted, .accepted): return .completed
        default: return state
        }
    }
}

protocol SecretStorage: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func remove(account: String) throws
}

final class MaintenanceOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        active = true
        return true
    }

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

enum SigningReminderSchedule {
    static let thresholds: [TimeInterval] = [72, 48, 24].map { $0 * 60 * 60 }

    static func dates(expirationDate: Date, now: Date = Date()) -> [Date] {
        thresholds
            .map { expirationDate.addingTimeInterval(-$0) }
            .filter { $0 > now }
            .sorted()
    }
}

enum SensitiveDiagnosticRedactor {
    private static let tokenPatterns = [
        #"github_pat_[A-Za-z0-9_]+"#,
        #"gh[pousr]_[A-Za-z0-9]+"#,
        #"(?i)(password|security-code|2fa|xcode\.auth|spd|token|private[_ -]?key|p12)\s*[:=]\s*[^\s,;]+"#,
        #"(?i)(latitude|longitude|coordinates?)\s*[:=]\s*[-+0-9., ]+"#
    ]

    static func redact(_ value: String, knownSecrets: [String] = []) -> String {
        var result = value
        for secret in knownSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for pattern in tokenPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<redacted>"
            )
        }
        return result
    }
}

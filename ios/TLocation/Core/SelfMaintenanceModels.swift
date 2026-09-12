import Foundation

enum SelfMaintenanceFailureCategory: String, Codable, CaseIterable, Sendable {
    case anisetteUnavailable
    case anisetteRejected
    case appleAuthenticationFailed
    case appleAccountLocked
    case appleNetworkUnavailable
    case twoFactorRequired
    case twoFactorCancelled
    case twoFactorFailed
    case grandSlamUnavailable
    case invalidClientMetadata
    case termsRequired
    case malformedAppleResponse
    case unknownAppleLoginResponse
    case developerSessionFailed
    case signingCorePanic
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
    let stage: String?
    let message: String

    init(
        category: SelfMaintenanceFailureCategory,
        stage: String? = nil,
        message: String
    ) {
        self.category = category
        self.stage = stage
        self.message = message
    }

    var errorDescription: String? { technicalDetail }

    var userFacingSummary: String {
        switch stage {
        case "creatingAnisetteProvider":
            return "Could not create the anisette provider."
        case "appleLogin":
            return "Could not sign in to the Apple Account."
        case "developerSession":
            return "Could not create the Apple developer session."
        case "listingTeams":
            return "Could not list Apple developer teams."
        case "buildingResult":
            return "Could not prepare the developer-session response."
        case "initializingCore", "installingCryptoProvider", "initializingErrorHooks",
             "parsingInputs", "creatingRuntime", "preparingStorage":
            return "Could not initialize Apple developer sign-in."
        default:
            return fallbackMessage
        }
    }

    var technicalDetail: String {
        SensitiveDiagnosticRedactor.sanitizedChain(message, fallback: fallbackMessage)
    }

    var hasDistinctTechnicalDetail: Bool {
        technicalDetail != userFacingSummary
    }

    var safeSignInLogMessage: String {
        let stageValue = stage.flatMap { $0.isEmpty ? nil : $0 } ?? "unavailable"
        return "Self-maintenance sign-in failed "
            + "stage=\(stageValue) "
            + "category=\(category.rawValue) "
            + "detail=\(technicalDetail)"
    }

    private var fallbackMessage: String {
        switch category {
        case .anisetteUnavailable, .grandSlamUnavailable:
            return "Apple signing services are temporarily unavailable."
        case .anisetteRejected:
            return "Apple rejected the anisette data."
        case .appleAuthenticationFailed:
            return "Could not sign in to the Apple Account."
        case .appleAccountLocked:
            return "The Apple Account is locked."
        case .appleNetworkUnavailable:
            return "Apple sign-in could not reach the network."
        case .twoFactorRequired:
            return "Apple requires two-factor authentication."
        case .twoFactorCancelled:
            return "Two-factor authentication was cancelled."
        case .twoFactorFailed:
            return "Apple two-factor authentication failed."
        case .invalidClientMetadata:
            return "Apple rejected the sign-in client metadata."
        case .termsRequired:
            return "The Apple Account requires an agreement or terms review."
        case .malformedAppleResponse:
            return "Apple returned a response that could not be read."
        case .unknownAppleLoginResponse:
            return "Apple returned an unknown sign-in response."
        case .developerSessionFailed:
            return "Could not create the Apple developer session."
        case .signingCorePanic:
            return "The signing core stopped unexpectedly."
        case .teamSelectionFailed:
            return "Could not list or select an Apple developer team."
        default:
            return "The self-maintenance operation failed."
        }
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
    private static let maximumChainDepth = 8
    private static let maximumChainCharacters = 1_200
    private static let maximumLineCharacters = 240

    private static let tokenPatterns = [
        #"github_pat_[A-Za-z0-9_]+"#,
        #"gh[pousr]_[A-Za-z0-9]+"#,
        #"(?i)\b(authorization|proxy-authorization|cookie|set-cookie|x-apple-i-md[^\s:=]*|x-mme-client-info|x-mme-device-id|x-apple-identity-token)\b\s*[:=][^\r\n]*"#,
        #"(?i)\b(password|passwd|security[-_ ]?code|two[-_ ]?factor[-_ ]?code|2fa[-_ ]?code|xcode\.auth|spd|access[-_ ]?token|refresh[-_ ]?token|token|secret|private[_ -]?key|client[-_ ]?secret|adi_pb|machine[-_ ]?id|local[-_ ]?user[-_ ]?(?:uuid|id)|device[-_ ]?(?:unique[-_ ]?)?(?:identifier|id)|udid|serial[-_ ]?(?:number)?|routing[-_ ]?info|dsid|adsid|gsidmstoken|p12)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|(?:bearer\s+)?[^\s,;]+)"#,
        #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        #"\b[0-9]{6}\b"#,
        #"(?i)\bhttps?://[^\s]+"#,
        #"\b(?:[A-Fa-f0-9]{24,}|[A-Za-z0-9_+/=-]{24,}|[A-Za-z0-9_-]{12,}(?:\.[A-Za-z0-9_-]{12,}){2})\b"#,
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

    static func sanitizedSingleLine(
        _ value: String,
        knownSecrets: [String] = [],
        fallback: String = "The self-maintenance operation failed."
    ) -> String {
        let rawFirstLine = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstLine = rawFirstLine.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = firstLine.lowercased()
        if lower.hasPrefix("{") || lower.hasPrefix("[")
            || lower.hasPrefix("<?xml") || lower.hasPrefix("<plist")
            || lower.hasPrefix("bplist") || lower.contains("-----begin")
            || lower.contains("private key material")
            || lower.contains("certificate key material") {
            return fallback
        }
        var result = firstLine
        let responseBoundary = [
            "response body", "response-body", "raw response", "response payload",
            "body:", "body=", ": {", ": [", "<?xml", "<plist", "bplist",
            "pairing content", "pairing-content", "pairing data", "pairing-data",
            "pair record:", "pair record=", "pairing record:", "pairing record="
        ]
            .compactMap { result.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
        if let responseBoundary {
            result = String(result[..<responseBoundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        result = redact(result, knownSecrets: knownSecrets)
        if result.count > maximumLineCharacters {
            result = String(result.prefix(maximumLineCharacters - 3)) + "..."
        }
        return result.isEmpty ? fallback : result
    }

    static func sanitizedChain(
        _ value: String,
        knownSecrets: [String] = [],
        fallback: String = "The self-maintenance operation failed."
    ) -> String {
        var lines: [String] = []
        var characterCount = 0
        for rawLine in value.components(separatedBy: .newlines) {
            guard lines.count < maximumChainDepth else { break }
            let line = sanitizedSingleLine(
                rawLine,
                knownSecrets: knownSecrets,
                fallback: ""
            )
            guard !line.isEmpty, !lines.contains(line) else { continue }
            let separatorCount = lines.isEmpty ? 0 : 1
            let available = maximumChainCharacters - characterCount - separatorCount
            guard available > 0 else { break }
            let bounded: String
            if line.count <= available {
                bounded = line
            } else if available <= 3 {
                bounded = String(repeating: ".", count: available)
            } else {
                bounded = String(line.prefix(available - 3)) + "..."
            }
            lines.append(bounded)
            characterCount += separatorCount + bounded.count
            if bounded.count == available { break }
        }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
    }
}

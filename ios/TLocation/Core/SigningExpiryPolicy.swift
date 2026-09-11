import Foundation

enum SigningExpirySeverity: String, Equatable, Sendable {
    case normal
    case subtleWarning
    case clearWarning
    case urgentWarning
    case expired
    case unknown
}

enum SigningExpiryPolicy {
    static let subtleThreshold: TimeInterval = 72 * 60 * 60
    static let clearThreshold: TimeInterval = 48 * 60 * 60
    static let urgentThreshold: TimeInterval = 24 * 60 * 60

    static func severity(
        expirationDate: Date?,
        checkedAt: Date?,
        now: Date = Date(),
        trustWindow: TimeInterval
    ) -> SigningExpirySeverity {
        guard let expirationDate, let checkedAt,
              now.timeIntervalSince(checkedAt) <= trustWindow else {
            return .unknown
        }
        let remaining = expirationDate.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= urgentThreshold { return .urgentWarning }
        if remaining <= clearThreshold { return .clearWarning }
        if remaining <= subtleThreshold { return .subtleWarning }
        return .normal
    }
}

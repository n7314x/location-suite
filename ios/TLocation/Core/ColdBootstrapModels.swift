import Foundation

enum ColdBootstrapStage: String, Codable, CaseIterable, Equatable, Sendable {
    case waitingForTunnel
    case tcpConnect
    case remotePairing
    case rsdConnect
    case locationSimulationChannel
    case coordinateSet
    case ready

    var displayName: String {
        switch self {
        case .waitingForTunnel: return "LocalDevVPN route"
        case .tcpConnect: return "TCP connect"
        case .remotePairing: return "RemotePairing"
        case .rsdConnect: return "RSD connect"
        case .locationSimulationChannel: return "DVT LocationSimulation"
        case .coordinateSet: return "Coordinate set"
        case .ready: return "Ready"
        }
    }
}

enum ColdBootstrapFailureCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case localVPNUnavailable
    case noRoute
    case connectionRefused
    case timeout
    case connectionReset
    case pairingRejected
    case remotePairingFailed
    case rsdFailed
    case dvtFailed
    case ddiUnavailable
    case coordinateSetFailed
    case invalidTarget
    case pairingFileUnreadable
    case unknown

    var displayName: String {
        switch self {
        case .localVPNUnavailable: return "LocalDevVPN Unavailable"
        case .noRoute: return "No Route"
        case .connectionRefused: return "Connection Refused"
        case .timeout: return "Connection Timed Out"
        case .connectionReset: return "Connection Reset"
        case .pairingRejected: return "Pairing Rejected"
        case .remotePairingFailed: return "RemotePairing Failed"
        case .rsdFailed: return "RSD Failed"
        case .dvtFailed: return "DVT Failed"
        case .ddiUnavailable: return "DDI Unavailable"
        case .coordinateSetFailed: return "Coordinate Set Failed"
        case .invalidTarget: return "Invalid Target"
        case .pairingFileUnreadable: return "Pairing File Unreadable"
        case .unknown: return "Unknown Failure"
        }
    }
}

struct ColdBootstrapStageMeasurement: Codable, Equatable, Sendable {
    let attempt: Int
    let stage: ColdBootstrapStage
    /// Nil when the upstream FFI exposes only a combined operation. In
    /// particular, a successful tunnel_create_rppairing proves TCP connected,
    /// but does not expose the TCP/handshake boundary needed to time it honestly.
    let elapsed: TimeInterval?
}

struct LocationBootstrapError: Codable, Equatable, Sendable {
    let stage: ColdBootstrapStage
    let statusCode: Int32
    let ffiCode: Int32?
    let ffiSubcode: Int32?
    let errno: Int32?
    let category: ColdBootstrapFailureCategory
    let detail: String

    var userTitle: String { category.displayName }

    var userMessage: String {
        switch category {
        case .localVPNUnavailable:
            return "The phone-local LocalDevVPN endpoint is not available. Open LocalDevVPN, reconnect it, then retry."
        case .noRoute:
            return "The LocalDevVPN route to the phone-local endpoint is unavailable."
        case .connectionRefused:
            return "LocalDevVPN routed the attempt, but the phone's RemotePairing endpoint refused a fresh connection."
        case .timeout:
            return "The phone-local endpoint did not answer before the bounded connection attempts timed out."
        case .connectionReset:
            return "The phone-local endpoint accepted the connection and then reset it."
        case .pairingRejected:
            return "The phone-local endpoint accepted the connection, but RemotePairing authentication failed. Import a valid pairing file."
        case .remotePairingFailed:
            return "TCP reached the phone-local endpoint, but the RemotePairing handshake failed."
        case .rsdFailed:
            return "RemotePairing connected, but the Remote Service Discovery channel could not be established."
        case .dvtFailed:
            return "RSD connected, but the DVT LocationSimulation service could not be opened."
        case .ddiUnavailable:
            return "Transport connected, but the developer service reported that the Developer Disk Image is unavailable."
        case .coordinateSetFailed:
            return "The LocationSimulation channel opened, but the device rejected the coordinate."
        case .invalidTarget:
            return "The configured phone-local target address is invalid."
        case .pairingFileUnreadable:
            return "The pairing file could not be read. Import a valid pairing file in Settings."
        case .unknown:
            return "The cold location-simulation bootstrap failed at \(stage.displayName)."
        }
    }
}

struct ColdBootstrapTrace: Codable, Equatable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let targetHost: String
    let targetPort: UInt16
    let underlyingNetwork: String
    let measurements: [ColdBootstrapStageMeasurement]
    let retryCount: Int
    let totalElapsed: TimeInterval
    let failure: LocationBootstrapError?

    var finalStage: ColdBootstrapStage {
        failure?.stage ?? measurements.last?.stage ?? .waitingForTunnel
    }

    var resultDescription: String {
        failure?.category.displayName ?? "Ready"
    }
}

struct LocationSimulationAttemptResult: Sendable {
    let statusCode: Int32
    let coldBootstrapTrace: ColdBootstrapTrace?
}

struct LocationBootstrapFFIError: Equatable, Sendable {
    let code: Int32
    let subcode: Int32
    let message: String
}

enum ColdBootstrapSequenceNumber {
    /// Process-monotonic and sufficiently granular for serial bootstrap calls;
    /// unlike wall time, it cannot move backward after a clock correction.
    static func next() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum ColdBootstrapErrorClassifier {
    static func classify(
        stage: ColdBootstrapStage,
        statusCode: Int32,
        ffi: LocationBootstrapFFIError?
    ) -> LocationBootstrapError {
        let rawDetail = ffi?.message ?? "No upstream error detail was provided."
        let detail = BootstrapDiagnosticPrivacy.sanitize(rawDetail)
        let lower = detail.lowercased()
        let socketErrno = errno(from: ffi)

        let category: ColdBootstrapFailureCategory
        if stage == .waitingForTunnel && (
            lower.contains("vpn") || lower.contains("network unavailable")
        ) {
            category = .localVPNUnavailable
        } else if socketErrno == 65 || lower.contains("no route") || lower.contains("network is unreachable") {
            category = .noRoute
        } else if socketErrno == 61 || lower.contains("connection refused") {
            category = .connectionRefused
        } else if socketErrno == 60 || lower.contains("timed out") || lower.contains("timeout") {
            category = .timeout
        } else if socketErrno == 54 || lower.contains("connection reset") {
            category = .connectionReset
        } else {
            switch stage {
            case .waitingForTunnel:
                category = .localVPNUnavailable
            case .tcpConnect:
                category = .unknown
            case .remotePairing:
                category = lower.contains("pair") || lower.contains("verify") || lower.contains("public_key")
                    ? .pairingRejected
                    : .remotePairingFailed
            case .rsdConnect:
                category = .rsdFailed
            case .locationSimulationChannel:
                category = lower.contains("developer disk")
                    || lower.contains("ddi")
                    || lower.contains("image not mounted")
                    ? .ddiUnavailable
                    : .dvtFailed
            case .coordinateSet:
                category = .coordinateSetFailed
            case .ready:
                category = .unknown
            }
        }

        return LocationBootstrapError(
            stage: stage,
            statusCode: statusCode,
            ffiCode: ffi?.code,
            ffiSubcode: ffi?.subcode,
            errno: socketErrno,
            category: category,
            detail: detail
        )
    }

    static func errno(from ffi: LocationBootstrapFFIError?) -> Int32? {
        guard let ffi else { return nil }
        let patterns = [
            #"os error\s+(\d+)"#,
            #"errno[\s:=]+(\d+)"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(ffi.message.startIndex..., in: ffi.message)
            guard let match = expression.firstMatch(in: ffi.message, range: range),
                  let numberRange = Range(match.range(at: 1), in: ffi.message),
                  let value = Int32(ffi.message[numberRange]) else {
                continue
            }
            return value
        }
        return [54, 60, 61, 65].contains(ffi.subcode) ? ffi.subcode : nil
    }
}

enum ColdBootstrapRecoveryPolicy {
    /// Delays after the initial attempt. No jitter is used: the location command
    /// queue is already serial, and deterministic bounds are more useful than
    /// randomized timing for this physical-device experiment.
    static func retryDelays(
        for category: ColdBootstrapFailureCategory,
        underlyingNetwork: String
    ) -> [TimeInterval] {
        switch category {
        case .localVPNUnavailable, .noRoute, .timeout:
            return [0.150, 0.300, 0.600, 1.200]
        case .connectionRefused:
            return underlyingNetwork.caseInsensitiveCompare("Cellular") == .orderedSame
                ? [0.150]
                : [0.150, 0.300]
        case .connectionReset, .remotePairingFailed, .rsdFailed:
            return [0.150, 0.300]
        case .pairingRejected, .dvtFailed, .ddiUnavailable,
             .coordinateSetFailed, .invalidTarget, .pairingFileUnreadable, .unknown:
            return []
        }
    }
}

enum ColdBootstrapRetryEvent: Equatable, Sendable {
    case pathChanged
    case localVPNReconnected
    case becameActiveAfterDelay
    case userRetry
}

struct ColdBootstrapRetryGate: Equatable, Sendable {
    private(set) var blocksAutomaticRetry = false

    mutating func recordFinalFailure(
        _ category: ColdBootstrapFailureCategory,
        underlyingNetwork: String
    ) {
        if category == .connectionRefused,
           underlyingNetwork.caseInsensitiveCompare("Cellular") == .orderedSame {
            blocksAutomaticRetry = true
        }
    }

    mutating func meaningfulEvent(_ event: ColdBootstrapRetryEvent) {
        blocksAutomaticRetry = false
    }
}

enum ColdBootstrapSafetyPolicy {
    static func shouldStartColdBootstrap(
        warmSessionOpen: Bool,
        warmSessionMaintained: Bool
    ) -> Bool {
        !warmSessionOpen && !warmSessionMaintained
    }

    /// A disposable TCP probe is intentionally disabled. Upstream exposes no
    /// guarantee that a bare connection is harmless to the single listener, so
    /// the real tunnel_create_rppairing call is the probe and handshake together.
    static let permitsDisposableTCPProbe = false
}

enum ColdBootstrapTraceOrdering {
    static func shouldReplace(currentSequence: UInt64?, with newSequence: UInt64) -> Bool {
        newSequence >= (currentSequence ?? 0)
    }
}

enum ColdBootstrapStageSequence {
    static let successful: [ColdBootstrapStage] = [
        .waitingForTunnel,
        .tcpConnect,
        .remotePairing,
        .rsdConnect,
        .locationSimulationChannel,
        .coordinateSet,
        .ready,
    ]

    static func isSuccessful(_ measurements: [ColdBootstrapStageMeasurement]) -> Bool {
        guard let attempt = measurements.last?.attempt else { return false }
        return measurements.filter { $0.attempt == attempt }.map(\.stage) == successful
    }
}

enum BootstrapDiagnosticPrivacy {
    static func sanitize(_ raw: String) -> String {
        var result = String(raw.prefix(1_000))
        result = replacing(
            in: result,
            pattern: #"[-+]?\d{1,3}\.\d{4,}\s*,\s*[-+]?\d{1,3}\.\d{4,}"#,
            with: "<redacted coordinate>"
        )
        result = replacing(
            in: result,
            pattern: #"(?:/Users/|/home/|/private/var/|/var/mobile/)[^\s\n]+"#,
            with: "<redacted path>"
        )
        result = replacing(
            in: result,
            pattern: #"(?i)(private[_ -]?key|apple[_ -]?password|session[_ -]?cookie)\s*[:=]\s*[^\s,;}]+"#,
            with: "$1=<redacted>"
        )
        return result
    }

    private static func replacing(in value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}

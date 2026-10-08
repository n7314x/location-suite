import Foundation

enum SetupRecoveryAction: Equatable {
    case prepareLTESession
    case openLocalDevVPN
    case importPairingFile
    case openDeveloperSettings
    case retryConnection

    var title: String {
        switch self {
        case .prepareLTESession: return "Prepare LTE Session"
        case .openLocalDevVPN: return "Open LocalDevVPN"
        case .importPairingFile: return "Replace Pairing File"
        case .openDeveloperSettings: return "Open Developer Settings"
        case .retryConnection: return "Retry Connection"
        }
    }
}

struct SetupRecovery: Equatable {
    let title: String
    let explanation: String
    let action: SetupRecoveryAction

    static func recommendation(trace: ColdBootstrapTrace?, warmSessionOpen: Bool) -> SetupRecovery? {
        guard let trace, let failure = trace.failure else { return nil }

        if LTEPreparationRecoveryPolicy.shouldOffer(trace: trace, warmSessionOpen: warmSessionOpen) {
            return SetupRecovery(
                title: "The phone refused a fresh LTE connection",
                explanation: "Keep LocalDevVPN connected, turn on Airplane Mode, then prepare the idle session. Turn Airplane Mode off after it is ready.",
                action: .prepareLTESession
            )
        }

        switch failure.category {
        case .localVPNUnavailable, .noRoute:
            return SetupRecovery(
                title: "The phone-local route is unavailable",
                explanation: "Connect or reconnect LocalDevVPN, then retry the device connection.",
                action: .openLocalDevVPN
            )
        case .timeout:
            return SetupRecovery(
                title: "The device endpoint did not respond",
                explanation: "Check that LocalDevVPN is connected and retry the phone-local connection.",
                action: .openLocalDevVPN
            )
        case .connectionRefused:
            return SetupRecovery(
                title: "RemotePairing refused the connection",
                explanation: "The local route reached the endpoint, but it refused a new connection. Reconnect LocalDevVPN, then retry.",
                action: .openLocalDevVPN
            )
        case .pairingRejected, .pairingFileUnreadable:
            return SetupRecovery(
                title: "The pairing file needs attention",
                explanation: "Import a current pairing file for this iPhone, then retry.",
                action: .importPairingFile
            )
        case .ddiUnavailable, .dvtFailed:
            return SetupRecovery(
                title: "Developer services are not ready",
                explanation: "Check Developer Mode and the DDI status in Settings. Redownload the DDI there if needed.",
                action: .openDeveloperSettings
            )
        case .invalidTarget:
            return SetupRecovery(
                title: "Check the device address",
                explanation: "Review the target device IP in Advanced Connection settings.",
                action: .openDeveloperSettings
            )
        case .connectionReset, .remotePairingFailed, .rsdFailed, .coordinateSetFailed, .unknown:
            return SetupRecovery(
                title: "Connection stopped at \(failure.stage.displayName)",
                explanation: failure.userMessage,
                action: .retryConnection
            )
        }
    }
}

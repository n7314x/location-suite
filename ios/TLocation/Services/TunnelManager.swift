//
//  TunnelManager.swift
//  TLocation
//

import Foundation
import Network

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false
    @Published private(set) var underlyingNetwork: UnderlyingNetworkKind = .unknown
    @Published private(set) var endpointReachability: EndpointReachability = .unknown
    @Published private(set) var lastConnectionFailureCategory: PhoneLocalConnectionFailureCategory?
    @Published private(set) var lastConnectionFailure: String?

    private var isStarting = false
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "vn.truongkma.tlocation.network-path")
    private var networkRetryWorkItem: DispatchWorkItem?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.networkKind(for: path)
            DispatchQueue.main.async {
                self?.networkPathChanged(to: kind)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
            self.endpointReachability = .unknown
        }
    }

    /// Records the endpoint actually used by a point/route simulation. These
    /// calls are more authoritative than interface type and keep diagnostics in
    /// step when the bootstrap tunnel itself is not the active session.
    func recordSimulationEndpointSuccess() {
        runOnMain {
            self.isConnected = true
            self.endpointReachability = .reachable
            self.lastConnectionFailureCategory = nil
            self.lastConnectionFailure = nil
        }
    }

    func recordSimulationEndpointFailure(code: Int32, detail: String) {
        runOnMain {
            switch code {
            case 9, 10, 11:
                // The RemotePairing handshake succeeded; a service above it
                // rejected the request.
                self.endpointReachability = .reachable
                self.isConnected = true
            default:
                self.endpointReachability = .unreachable
                self.isConnected = false
            }
            self.lastConnectionFailureCategory = Self.failureCategory(forSimulationCode: code)
            self.lastConnectionFailure = detail
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        let pairingFilePresent = FileManager.default.fileExists(atPath: pairingFileURL.path)
        guard PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: pairingFilePresent,
            underlyingNetwork: underlyingNetwork
        ) else {
            isConnected = false
            LogManager.shared.addWarningLog(
                "Tunnel start skipped: no pairing file at \(pairingFileURL.path)"
            )
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true
        endpointReachability = .checking

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            endpointReachability = .reachable
            lastConnectionFailureCategory = nil
            lastConnectionFailure = nil
            LogManager.shared.addInfoLog(
                "Tunnel connected successfully to \(DeviceConnectionContext.targetIPAddress):49152"
            )
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            endpointReachability = .unreachable
            lastConnectionFailureCategory = Self.failureCategory(for: error)
            lastConnectionFailure = error.localizedDescription
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        guard FileManager.default.fileExists(atPath: trustcachePath),
              !MountingProgress.shared.coolisMounted,
              MountingProgress.shared.mountingThread == nil else {
            return
        }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: String(localized: "Connection Error"),
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: String(localized: "Invalid Pairing File"),
            message: String(localized: "The pairing file may be invalid or expired. You can import a new pairing file to replace it."),
            showOk: true,
            showTryAgain: false,
            primaryButtonText: String(localized: "Select New File")
        ) { _ in
            NotificationCenter.default.post(name: .showPairingFilePicker, object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func networkPathChanged(to kind: UnderlyingNetworkKind) {
        let didChange = underlyingNetwork != kind
        underlyingNetwork = kind
        guard didChange,
              !isConnected,
              !isStarting,
              !LocationSimulationSession.isMaintained else { return }

        networkRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isConnected,
                  !self.isStarting,
                  !LocationSimulationSession.isMaintained else { return }
            self.start(showErrorUI: false)
        }
        networkRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private static func networkKind(for path: NWPath) -> UnderlyingNetworkKind {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }

    private static func failureCategory(for error: NSError) -> PhoneLocalConnectionFailureCategory {
        let message = error.localizedDescription.lowercased()
        if error.code == -18 || message.contains("parse target ip") { return .invalidAddress }
        if message.contains("no route") || message.contains("network is unreachable") { return .noRoute }
        if error.code == 61 || message.contains("refused") { return .refused }
        if message.contains("timed out") || message.contains("timeout") { return .timedOut }
        if error.code == -9 || message.contains("pair") || message.contains("verify") { return .pairing }
        return .unknown
    }

    private static func failureCategory(forSimulationCode code: Int32) -> PhoneLocalConnectionFailureCategory {
        switch code {
        case 1: return .invalidAddress
        case 2: return .pairing
        case 3: return .noRoute
        case 9, 10, 11, 12: return .service
        default: return .unknown
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

/// `startTunnelInBackground()`, but never *while* a location-simulation command
/// is inside the FFI.
///
/// `simulate_location` calls `tunnel_create_rppairing` against
/// `<targetIP>:49152`, which this app's own recovery text documents as
/// single-occupancy (errno 48, "address already in use" — see
/// `tunnelConnectionAlertMessage(for:)` below). `JITEnableContext`'s tunnel is a
/// separate one to the same endpoint, so starting it on top of an in-flight
/// resend is the double handshake that `TLocationApp`'s deferred rebuild exists
/// to avoid. The readiness overlay — the only home of Retry — appears the moment
/// the tunnel is marked disconnected, which can happen with a resend loop still
/// alive, so Retry is one tap away from exactly that.
///
/// Deferred, never refused: the user must always be able to recover a dead
/// tunnel, so unlike `attemptDeferredTunnelReconnect` this has no condition
/// attached and nothing can drop it. Appending to the serial
/// `LocationSimulationCommandQueue` is only a matter of waiting its turn — the
/// hop cannot begin until any FFI call already running there has returned, and
/// once it does begin the start is unconditional. Ticks queued ahead of it that
/// belong to a run that has ended return without calling anything (see
/// `ResendGeneration`), so a concluded run leaves nothing real in the way.
///
/// The start itself is bounced back to the main thread, which is where
/// `TunnelManager.start(showErrorUI:)` requires to be called from; no FFI runs
/// on the command queue as part of this.
func startTunnelAfterPendingLocationCommands(showErrorUI: Bool = true) {
    LocationSimulationCommandQueue.shared.async {
        DispatchQueue.main.async {
            startTunnelInBackground(showErrorUI: showErrorUI)
        }
    }
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = "\(DeviceConnectionContext.targetIPAddress):49152"
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    let targetIP = DeviceConnectionContext.targetIPAddress
    let rawMessage = error.localizedDescription
    let lowercasedMessage = rawMessage.lowercased()

    let likelyCause: String
    let recoverySteps: [String]

    let defaultIP = DeviceConnectionContext.defaultTargetIPAddress

    if error.code == 48 || lowercasedMessage.contains("address already in use") || lowercasedMessage.contains("port already in use") {
        likelyCause = String(localized: "A port needed for the connection to this device is already in use.")
        recoverySteps = [
            String(localized: "Close other JIT, debugging, proxy, or VPN apps that may be using the connection."),
            String(localized: "Disconnect and reconnect LocalDevVPN."),
            String(localized: "Restart TLocation, then try again."),
            String(localized: "If it keeps happening, reboot the device to clear the stuck port.")
        ]
    } else if error.code == 54 || lowercasedMessage.contains("connection reset") {
        likelyCause = String(localized: "The device or VPN closed the connection before setup finished.")
        recoverySteps = [
            String(localized: "Open LocalDevVPN and confirm the VPN is connected."),
            String(localized: "Make sure LocalDevVPN is using the default \(defaultIP) address."),
            String(localized: "Reconnect LocalDevVPN, then try again."),
            String(localized: "If this keeps happening, select a fresh pairing file.")
        ]
    } else if error.code == -18 || lowercasedMessage.contains("parse target ip") {
        likelyCause = String(localized: "The configured target IP address is not valid.")
        recoverySteps = [
            String(localized: "Open Settings and check the target IP address."),
            String(localized: "Use the default \(defaultIP).")
        ]
    } else if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
        likelyCause = String(localized: "The app could not reach the device before the connection timed out.")
        recoverySteps = [
            String(localized: "Confirm LocalDevVPN is connected."),
            String(localized: "Wake and unlock the target device."),
            String(localized: "Confirm LocalDevVPN is exposing the device at \(targetIP)."),
            String(localized: "If cellular is active, iOS may not be publishing RemotePairing; the endpoint result is authoritative.")
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = String(localized: "The VPN route to the device is not available.")
        recoverySteps = [
            String(localized: "Disconnect and reconnect LocalDevVPN."),
            String(localized: "Confirm iOS shows the VPN indicator."),
            String(localized: "Retry after the network path finishes changing.")
        ]
    } else {
        likelyCause = String(localized: "The connection to this device could not be created.")
        recoverySteps = [
            String(localized: "Confirm LocalDevVPN is connected."),
            String(localized: "Wake and unlock the target device."),
            String(localized: "Reconnect LocalDevVPN, then try again.")
        ]
    }

    // A numbered list, not a sentence: each step is already a whole translated
    // string, and only the "1. " prefix is assembled here.
    let steps = recoverySteps.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    // The raw FFI message is deliberately left untranslated — it is diagnostic
    // detail for a bug report, not prose for the user.
    let message = String(
        localized: """
        \(likelyCause)

        Target: \(targetIP):49152
        Expected LocalDevVPN IP: \(defaultIP)

        Try this:
        \(steps)

        Technical details:
        Code \(error.code): \(rawMessage)
        """
    )
    let network = TunnelManager.shared.underlyingNetwork.rawValue
    let reachable = TunnelManager.shared.endpointReachability.rawValue
    return message + "\nUnderlying network: \(network)\nEndpoint reachable: \(reachable)"
}

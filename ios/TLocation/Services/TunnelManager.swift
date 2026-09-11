//
//  TunnelManager.swift
//  TLocation
//

import Foundation
import Network

final class TunnelManager: ObservableObject {
    private struct StartOutcome {
        let result: Result<Void, NSError>
        let trace: ColdBootstrapTrace?
    }

    static let shared = TunnelManager()

    @Published private(set) var isConnected = false
    @Published private(set) var underlyingNetwork: UnderlyingNetworkKind = .unknown
    @Published private(set) var endpointReachability: EndpointReachability = .unknown
    @Published private(set) var lastConnectionFailureCategory: PhoneLocalConnectionFailureCategory?
    @Published private(set) var lastConnectionFailure: String?
    @Published private(set) var lastColdBootstrap: ColdBootstrapTrace?

    private var isStarting = false
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "vn.truongkma.tlocation.network-path")
    private var networkRetryWorkItem: DispatchWorkItem?
    private var coldBootstrapRetryGate = ColdBootstrapRetryGate()

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

    /// Records a coordinate accepted by the simulation service. An update on an
    /// already-open session proves that warm session is healthy, but says
    /// nothing about whether a *fresh* TCP connection can currently be made.
    /// Only a coordinate that had to build a session updates fresh endpoint and
    /// RemotePairing diagnostics.
    func recordSimulationResult(
        _ result: LocationSimulationAttemptResult,
        reusedOpenSession: Bool
    ) {
        runOnMain {
            if let trace = result.coldBootstrapTrace,
               ColdBootstrapTraceOrdering.shouldReplace(
                   currentSequence: self.lastColdBootstrap?.sequence,
                   with: trace.sequence
               ) {
                self.lastColdBootstrap = trace
                if let failure = trace.failure {
                    self.coldBootstrapRetryGate.recordFinalFailure(
                        failure.category,
                        underlyingNetwork: trace.underlyingNetwork
                    )
                }
            }

            if result.statusCode == 0 {
                if !reusedOpenSession {
                    self.isConnected = true
                    self.endpointReachability = .reachable
                }
                self.lastConnectionFailureCategory = nil
                self.lastConnectionFailure = nil
                return
            }

            guard let failure = result.coldBootstrapTrace?.failure else {
                self.isConnected = false
                self.endpointReachability = .unreachable
                self.lastConnectionFailureCategory = .unknown
                self.lastConnectionFailure = "Location simulation failed with status \(result.statusCode)."
                return
            }

            switch failure.stage {
            case .rsdConnect, .locationSimulationChannel, .coordinateSet, .ready:
                self.isConnected = true
                self.endpointReachability = .reachable
            case .waitingForTunnel, .tcpConnect, .remotePairing:
                self.isConnected = false
                self.endpointReachability = failure.category == .pairingRejected
                    || failure.category == .remotePairingFailed
                    ? .reachable
                    : .unreachable
            }
            self.lastConnectionFailureCategory = Self.legacyCategory(for: failure.category)
            self.lastConnectionFailure = "\(failure.userMessage) \(failure.detail)"
        }
    }

    /// A repeated operation on the retained LocationSimulation channel failed,
    /// so the warm RemotePairing transport is no longer usable. This says
    /// nothing about whether a brand-new LocalDevVPN TCP connection would work;
    /// keep the independently measured endpoint diagnostic unchanged.
    func recordWarmSessionFailure(detail: String) {
        runOnMain {
            self.isConnected = false
            self.lastConnectionFailureCategory = .service
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

        guard !LocationSimulationSession.isOpen else {
            LogManager.shared.addInfoLog(
                "Fresh tunnel start skipped: the warm location-simulation session is still open."
            )
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
        let network = underlyingNetwork.rawValue
        let target = DeviceConnectionContext.targetIPAddress
        let timestamp = Date()
        let sequence = ColdBootstrapSequenceNumber.next()

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let outcome = Self.performBoundedStart(
                target: target,
                underlyingNetwork: network,
                timestamp: timestamp,
                sequence: sequence
            )

            DispatchQueue.main.async {
                self.finishStart(outcome, showErrorUI: showErrorUI)
            }
        }
    }

    private static func performBoundedStart(
        target: String,
        underlyingNetwork: String,
        timestamp: Date,
        sequence: UInt64
    ) -> StartOutcome {
        let startedAt = Date()
        var measurements: [ColdBootstrapStageMeasurement] = []
        var retryCount = 0

        while true {
            let attempt = retryCount + 1
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: .waitingForTunnel,
                elapsed: nil
            ))
            let operationStartedAt = Date()
            do {
                try JITEnableContext.shared.startTunnel()
                return StartOutcome(result: .success(()), trace: nil)
            } catch {
                let nsError = error as NSError
                let ffi = LocationBootstrapFFIError(
                    code: Int32(clamping: nsError.code),
                    subcode: Int32(clamping: nsError.userInfo["IdeviceFFISubcode"] as? Int ?? 0),
                    message: nsError.localizedDescription
                )
                let socketErrno = ColdBootstrapErrorClassifier.errno(from: ffi)
                let stage: ColdBootstrapStage = socketErrno == nil ? .remotePairing : .tcpConnect
                measurements.append(ColdBootstrapStageMeasurement(
                    attempt: attempt,
                    stage: stage,
                    elapsed: Date().timeIntervalSince(operationStartedAt)
                ))
                let failure = ColdBootstrapErrorClassifier.classify(
                    stage: stage,
                    statusCode: Int32(clamping: nsError.code),
                    ffi: ffi
                )
                let delays = ColdBootstrapRecoveryPolicy.retryDelays(
                    for: failure.category,
                    underlyingNetwork: underlyingNetwork
                )
                guard retryCount < delays.count else {
                    let trace = ColdBootstrapTrace(
                        sequence: sequence,
                        timestamp: timestamp,
                        targetHost: target,
                        targetPort: 49152,
                        underlyingNetwork: underlyingNetwork,
                        measurements: measurements,
                        retryCount: retryCount,
                        totalElapsed: Date().timeIntervalSince(startedAt),
                        failure: failure
                    )
                    return StartOutcome(result: .failure(nsError), trace: trace)
                }
                let delay = delays[retryCount]
                retryCount += 1
                LogManager.shared.addInfoLog(
                    "Initial RemotePairing retry \(retryCount) scheduled after \(Int(delay * 1_000)) ms for \(failure.category.displayName)."
                )
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    private func finishStart(_ outcome: StartOutcome, showErrorUI: Bool) {
        isStarting = false

        switch outcome.result {
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
            if let trace = outcome.trace,
               ColdBootstrapTraceOrdering.shouldReplace(
                   currentSequence: lastColdBootstrap?.sequence,
                   with: trace.sequence
               ) {
                lastColdBootstrap = trace
                if let failure = trace.failure {
                    coldBootstrapRetryGate.recordFinalFailure(
                        failure.category,
                        underlyingNetwork: trace.underlyingNetwork
                    )
                }
            }
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

        if error.code == -9
            || lastColdBootstrap?.failure?.category == .pairingRejected
            || lastColdBootstrap?.failure?.category == .pairingFileUnreadable {
            handleInvalidPairingFile()
            return
        }

        if let failure = lastColdBootstrap?.failure {
            let errnoLine = failure.errno.map { "\nerrno: \($0)" } ?? ""
            showAlert(
                title: failure.userTitle,
                message: "\(failure.userMessage)\n\nTarget: \(DeviceConnectionContext.targetIPAddress):49152\nStage: \(failure.stage.displayName)\nStatus: \(failure.statusCode)\(errnoLine)\n\nTechnical details:\n\(failure.detail)",
                showOk: false,
                showTryAgain: true
            ) { shouldTryAgain in
                if shouldTryAgain {
                    self.coldBootstrapRetryGate.meaningfulEvent(.userRetry)
                    startTunnelInBackground()
                }
            }
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
        if didChange { coldBootstrapRetryGate.meaningfulEvent(.pathChanged) }
        guard didChange,
              !isConnected,
              !isStarting,
              !LocationSimulationSession.isOpen,
              !LocationSimulationSession.isMaintained else { return }

        networkRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isConnected,
                  !self.isStarting,
                  !LocationSimulationSession.isOpen,
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

    private static func legacyCategory(
        for category: ColdBootstrapFailureCategory
    ) -> PhoneLocalConnectionFailureCategory {
        switch category {
        case .invalidTarget: return .invalidAddress
        case .localVPNUnavailable, .noRoute: return .noRoute
        case .connectionRefused: return .refused
        case .timeout: return .timedOut
        case .pairingRejected, .pairingFileUnreadable: return .pairing
        case .connectionReset, .remotePairingFailed, .rsdFailed, .dvtFailed,
             .ddiUnavailable, .coordinateSetFailed: return .service
        case .unknown: return .unknown
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
    let detail = BootstrapDiagnosticPrivacy.sanitize(error.localizedDescription)
    return "Tunnel connection failed for \(target): \(detail) (Domain: \(error.domain), Code: \(error.code))"
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

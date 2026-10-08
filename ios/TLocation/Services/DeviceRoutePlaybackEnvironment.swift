//
//  DeviceRoutePlaybackEnvironment.swift
//  TLocation
//
//  Adapts the route domain to the existing phone-local simulation session.
//

import Combine
import Foundation
import UIKit

struct DeviceRouteLocationSimulationSink: RouteLocationSimulationSink {
    private enum CoordinateOutcome: Sendable {
        case superseded
        case completed(result: LocationSimulationAttemptResult, reusedOpenSession: Bool)
    }

    func setCoordinate(
        _ coordinate: RoutePoint,
        lease: LocationSimulationProducerLease
    ) async throws {
        let pairingFilePath = PairingFileStore.prepareURL().path
        let deviceIP = DeviceConnectionContext.targetIPAddress
        let outcome: CoordinateOutcome = await runOnLocationCommandQueue {
            guard LocationSimulationOwnership.shared.isCurrent(lease) else {
                return .superseded
            }
            let reusedOpenSession = LocationSimulationSession.isOpen
            let result = simulate_location_detailed(
                deviceIP,
                coordinate.latitude,
                coordinate.longitude,
                pairingFilePath,
                underlyingNetwork: TunnelManager.shared.underlyingNetwork.rawValue
            )
            guard LocationSimulationOwnership.shared.isCurrent(lease) else {
                return .superseded
            }
            return .completed(result: result, reusedOpenSession: reusedOpenSession)
        }

        guard case .completed(let result, let reusedOpenSession) = outcome else {
            throw RoutePlaybackFailure(
                reason: .superseded,
                message: "A newer location mode took ownership of the simulation."
            )
        }
        TunnelManager.shared.recordSimulationResult(
            result,
            reusedOpenSession: reusedOpenSession
        )
        guard result.statusCode == 0 else {
            if let bootstrapError = result.coldBootstrapTrace?.failure {
                throw RoutePlaybackFailure(
                    reason: LTEPreparationRecoveryPolicy.shouldOffer(
                        trace: result.coldBootstrapTrace,
                        warmSessionOpen: LocationSimulationSession.isOpen
                    ) ? .lteSessionPreparationRequired : Self.failureReason(for: bootstrapError.category),
                    message: bootstrapError.userMessage
                )
            }
            throw Self.failure(for: result.statusCode, clearing: false)
        }
    }

    func clear() async throws {
        let code = await runOnLocationCommandQueue { clear_simulated_location() }
        guard code == 0 else { throw Self.failure(for: code, clearing: true) }
    }

    func disconnect() async throws {
        let code = await runOnLocationCommandQueue { disconnect_location_simulation_session() }
        guard code == 0 else { throw Self.failure(for: code, clearing: true) }
    }

    private func runOnLocationCommandQueue<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static func failure(for code: Int32, clearing: Bool) -> RoutePlaybackFailure {
        if clearing {
            return RoutePlaybackFailure(
                reason: .clearFailed,
                message: "Location Suite could not return to real GPS. The simulated-location session may already have ended."
            )
        }

        switch code {
        case 1:
            return RoutePlaybackFailure(
                reason: .tunnelUnavailable,
                message: "The target device address is invalid. Check it in Settings before playing the route."
            )
        case 2:
            return RoutePlaybackFailure(
                reason: .noPairingFile,
                message: "The pairing file could not be read. Import a fresh pairing file in Settings."
            )
        case 3, 9:
            return RoutePlaybackFailure(
                reason: .tunnelUnavailable,
                message: "Route playback lost the phone-local connection. Reconnect LocalDevVPN, then tap Retry before playing again."
            )
        case 10:
            return RoutePlaybackFailure(
                reason: .developerDiskImageUnavailable,
                message: "The Developer Disk Image is not ready. Reconnect the device and wait for setup to finish."
            )
        default:
            return RoutePlaybackFailure(
                reason: .sessionFailed,
                message: "The device stopped accepting route locations. Reconnect LocalDevVPN and confirm the Developer Disk Image is mounted."
            )
        }
    }

    private static func failureReason(
        for category: ColdBootstrapFailureCategory
    ) -> RoutePlaybackFailureReason {
        switch category {
        case .pairingRejected, .pairingFileUnreadable:
            return .noPairingFile
        case .ddiUnavailable:
            return .developerDiskImageUnavailable
        case .localVPNUnavailable, .noRoute, .connectionRefused, .timeout,
             .connectionReset, .remotePairingFailed, .rsdFailed, .invalidTarget:
            return .tunnelUnavailable
        case .dvtFailed, .coordinateSetFailed, .unknown:
            return .sessionFailed
        }
    }
}

private struct DeviceLocationSimulationSessionStatus: LocationSimulationSessionStatusProviding {
    var isSessionOpen: Bool { LocationSimulationSession.isOpen }
    var isSimulationActive: Bool { LocationSimulationSession.isActive }
}

enum LocationSimulationPreparationOutcome: Sendable {
    case ready(reusedOpenSession: Bool)
    case failed(LocationSimulationAttemptResult)
    /// Point, Route, or Disconnect advanced ownership while preparation was
    /// queued or inside its synchronous FFI call.
    case superseded
}

/// Coordinates the UI-facing prepare action with the same ownership generation,
/// command queue, handles, and idle keeper used by Point and Route.
@MainActor
final class LocationSimulationSessionPreparer: ObservableObject {
    static let shared = LocationSimulationSessionPreparer()

    @Published private(set) var isPreparing = false

    private enum QueueOutcome: Sendable {
        case ready(
            result: LocationSimulationAttemptResult,
            reusedOpenSession: Bool,
            preparationLease: LocationSimulationPreparationLease,
            idleLease: LocationSimulationIdleLease
        )
        case failed(
            result: LocationSimulationAttemptResult,
            preparationLease: LocationSimulationPreparationLease
        )
        case superseded(preparationLease: LocationSimulationPreparationLease)
    }

    private init() {}

    func prepare() async -> LocationSimulationPreparationOutcome {
        if isPreparing { return .superseded }

        let ownership = LocationSimulationOwnership.shared
        guard let preparationLease = ownership.beginPreparation() else {
            // An active producer or another preparation is authoritative. This
            // operation never steals a Point/Route lease merely to call it idle.
            return .superseded
        }

        isPreparing = true
        DeviceRoutePlaybackActivityManager.shared.simulationPreparationWillBegin(preparationLease)

        let deviceIP = DeviceConnectionContext.targetIPAddress
        let pairingFilePath = PairingFileStore.prepareURL().path
        let network = TunnelManager.shared.underlyingNetwork.rawValue

        let queueOutcome: QueueOutcome = await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                guard ownership.isCurrent(preparationLease) else {
                    continuation.resume(returning: .superseded(
                        preparationLease: preparationLease
                    ))
                    return
                }

                let reusedOpenSession = LocationSimulationSession.isOpen
                let result = prepare_location_simulation_session_detailed(
                    deviceIP,
                    pairingFilePath,
                    underlyingNetwork: network
                )

                guard ownership.isCurrent(preparationLease) else {
                    continuation.resume(returning: .superseded(
                        preparationLease: preparationLease
                    ))
                    return
                }

                if result.statusCode == 0,
                   let idleLease = ownership.finishPreparation(preparationLease) {
                    continuation.resume(returning: .ready(
                        result: result,
                        reusedOpenSession: reusedOpenSession,
                        preparationLease: preparationLease,
                        idleLease: idleLease
                    ))
                } else {
                    _ = ownership.cancelPreparation(preparationLease)
                    continuation.resume(returning: .failed(
                        result: result,
                        preparationLease: preparationLease
                    ))
                }
            }
        }

        isPreparing = false
        switch queueOutcome {
        case .ready(let result, let reused, let lease, let idleLease):
            guard DeviceRoutePlaybackActivityManager.shared.simulationPreparationDidSucceed(
                lease,
                idleLease: idleLease
            ) else {
                _ = DeviceRoutePlaybackActivityManager.shared.simulationPreparationDidFail(lease)
                return .superseded
            }
            TunnelManager.shared.recordPreparationResult(
                result,
                reusedOpenSession: reused
            )
            MountingProgress.shared.recordDeveloperServiceReady()
            return .ready(reusedOpenSession: reused)

        case .failed(let result, let lease):
            guard DeviceRoutePlaybackActivityManager.shared.simulationPreparationDidFail(lease) else {
                return .superseded
            }
            TunnelManager.shared.recordPreparationResult(
                result,
                reusedOpenSession: false
            )
            return .failed(result)

        case .superseded(let lease):
            _ = DeviceRoutePlaybackActivityManager.shared.simulationPreparationDidFail(lease)
            return .superseded
        }
    }
}

private final class DeviceWarmHeartbeatDriver: WarmLocationSimulationHeartbeatPerforming, @unchecked Sendable {
    func performHeartbeat(
        for lease: LocationSimulationIdleLease,
        completion: @escaping @Sendable (WarmLocationSimulationHeartbeatResult) -> Void
    ) {
        LocationSimulationCommandQueue.shared.async {
            guard LocationSimulationOwnership.shared.isCurrent(lease),
                  LocationSimulationSession.isOpen,
                  !LocationSimulationSession.isActive else {
                completion(.stale)
                return
            }

            let result = heartbeat_warm_location_simulation_session()
            guard LocationSimulationOwnership.shared.isCurrent(lease) else {
                completion(.stale)
                return
            }
            completion(
                result.succeeded
                    ? .succeeded(Date())
                    : .failed(result.detail)
            )
        }
    }

    func discardStaleSession(
        for lease: LocationSimulationIdleLease,
        reason: String,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        LocationSimulationCommandQueue.shared.async {
            // The Point/Route claim happens synchronously before its FFI block
            // is enqueued. Rechecking here prevents an old heartbeat verdict
            // from destroying the session a new producer has just claimed.
            guard LocationSimulationOwnership.shared.isCurrent(lease),
                  LocationSimulationSession.isOpen,
                  !LocationSimulationSession.isActive else {
                completion(false)
                return
            }

            discard_stale_location_simulation_session()
            TunnelManager.shared.recordWarmSessionFailure(
                detail: "Warm LocationSimulation heartbeat failed repeatedly: \(reason)"
            )
            completion(true)
        }
    }
}

@MainActor
private final class DeviceWarmHeartbeatCancellation: WarmLocationSimulationHeartbeatCancellation {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
private final class DeviceWarmHeartbeatScheduler: WarmLocationSimulationHeartbeatScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> WarmLocationSimulationHeartbeatCancellation {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return DeviceWarmHeartbeatCancellation(timer: timer)
    }
}

@MainActor
private final class DeviceLocationSimulationBackgroundActivity: LocationSimulationBackgroundActivityManaging {
    func requestStart() {
        LocationSimulationSession.setMaintained(true)
        BackgroundLocationManager.shared.requestStart()
    }

    func requestStop() {
        LocationSimulationSession.setMaintained(false)
        BackgroundLocationManager.shared.requestStop()
    }
}

@MainActor
final class DeviceRoutePlaybackActivityManager: RoutePlaybackActivityManaging {
    static let shared = DeviceRoutePlaybackActivityManager()

    let sessionKeeper: LocationSimulationSessionKeeper
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {
        sessionKeeper = LocationSimulationSessionKeeper(
            ownership: .shared,
            status: DeviceLocationSimulationSessionStatus(),
            heartbeat: DeviceWarmHeartbeatDriver(),
            scheduler: DeviceWarmHeartbeatScheduler(),
            backgroundActivity: DeviceLocationSimulationBackgroundActivity(),
            log: { LogManager.shared.addInfoLog($0) }
        )
    }

    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        guard LocationSimulationOwnership.shared.isCurrent(lease) else { return }
        sessionKeeper.producerDidTakeOwnership(lease)
        beginBackgroundTask()
    }

    func simulationPreparationWillBegin(_ lease: LocationSimulationPreparationLease) {
        sessionKeeper.preparationWillBegin(lease)
        beginBackgroundTask()
    }

    @discardableResult
    func simulationPreparationDidSucceed(
        _ lease: LocationSimulationPreparationLease,
        idleLease: LocationSimulationIdleLease
    ) -> Bool {
        let accepted = sessionKeeper.preparationDidSucceed(lease, idleLease: idleLease)
        if accepted { endBackgroundTask() }
        return accepted
    }

    @discardableResult
    func simulationPreparationDidFail(_ lease: LocationSimulationPreparationLease) -> Bool {
        let accepted = sessionKeeper.preparationDidFail(lease)
        if accepted { endBackgroundTask() }
        return accepted
    }

    func simulationDidEnd(
        _ lease: LocationSimulationProducerLease,
        reason: LocationSimulationProducerEndReason
    ) {
        // A prior producer may finish after point/route handoff. Its stale end
        // must not stop the successor's maintenance or disconnect its tunnel.
        guard sessionKeeper.producerDidEnd(lease, reason: reason) else { return }
        endBackgroundTask()
        if case .failure(connectionUnavailable: true) = reason {
            markTunnelDisconnected()
        }
    }

    func simulationSessionWillDisconnect() -> LocationSimulationDisconnectLease {
        let lease = sessionKeeper.sessionWillDisconnect()
        endBackgroundTask()
        return lease
    }

    func simulationSessionDidDisconnect(_ lease: LocationSimulationDisconnectLease) {
        sessionKeeper.sessionDidDisconnect(lease)
        endBackgroundTask()
    }

    func simulationSessionDidClose() {
        sessionKeeper.sessionDidClose()
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

extension RoutePlaybackController {
    static func deviceController() -> RoutePlaybackController {
        RoutePlaybackController(
            sink: DeviceRouteLocationSimulationSink(),
            activityManager: DeviceRoutePlaybackActivityManager.shared
        )
    }
}

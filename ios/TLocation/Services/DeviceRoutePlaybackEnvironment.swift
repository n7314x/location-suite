//
//  DeviceRoutePlaybackEnvironment.swift
//  TLocation
//
//  Adapts the route domain to the existing phone-local simulation session.
//

import Foundation
import UIKit

struct DeviceRouteLocationSimulationSink: RouteLocationSimulationSink {
    private enum CoordinateOutcome: Sendable {
        case superseded
        case completed(code: Int32, reusedOpenSession: Bool)
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
            let code = simulate_location(
                deviceIP,
                coordinate.latitude,
                coordinate.longitude,
                pairingFilePath
            )
            guard LocationSimulationOwnership.shared.isCurrent(lease) else {
                return .superseded
            }
            return .completed(code: code, reusedOpenSession: reusedOpenSession)
        }

        guard case .completed(let code, let reusedOpenSession) = outcome else {
            throw RoutePlaybackFailure(
                reason: .superseded,
                message: "A newer location mode took ownership of the simulation."
            )
        }
        guard code == 0 else {
            TunnelManager.shared.recordSimulationEndpointFailure(
                code: code,
                detail: "Route coordinate delivery failed with device code \(code)."
            )
            throw Self.failure(for: code, clearing: false)
        }
        TunnelManager.shared.recordSimulationCoordinateSuccess(
            reusedOpenSession: reusedOpenSession
        )
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
}

private struct DeviceLocationSimulationSessionStatus: LocationSimulationSessionStatusProviding {
    var isSessionOpen: Bool { LocationSimulationSession.isOpen }
    var isSimulationActive: Bool { LocationSimulationSession.isActive }
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
    private var sessionChangedObserver: NSObjectProtocol?

    private init() {
        sessionKeeper = LocationSimulationSessionKeeper(
            ownership: .shared,
            status: DeviceLocationSimulationSessionStatus(),
            heartbeat: DeviceWarmHeartbeatDriver(),
            scheduler: DeviceWarmHeartbeatScheduler(),
            backgroundActivity: DeviceLocationSimulationBackgroundActivity(),
            log: { LogManager.shared.addInfoLog($0) }
        )

        sessionChangedObserver = NotificationCenter.default.addObserver(
            forName: .locationSimulationSessionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A dead handle may close and rebuild within one serialized
            // simulate_location call. Only the settled closed level is final.
            guard !LocationSimulationSession.isOpen else { return }
            Task { @MainActor [weak self] in
                self?.sessionKeeper.sessionDidClose()
                self?.endBackgroundTask()
            }
        }
    }

    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        guard LocationSimulationOwnership.shared.isCurrent(lease) else { return }
        sessionKeeper.producerDidTakeOwnership(lease)
        beginBackgroundTask()
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

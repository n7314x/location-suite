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

@MainActor
final class DeviceRoutePlaybackActivityManager: RoutePlaybackActivityManaging {
    static let shared = DeviceRoutePlaybackActivityManager()

    private var activeLease: LocationSimulationProducerLease?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        guard LocationSimulationOwnership.shared.isCurrent(lease) else { return }
        let wasActive = activeLease != nil
        activeLease = lease
        if !wasActive {
            LocationSimulationSession.setMaintained(true)
            BackgroundLocationManager.shared.requestStart()
        }
        beginBackgroundTask()
    }

    func simulationDidEnd(
        _ lease: LocationSimulationProducerLease,
        connectionUnavailable: Bool
    ) {
        // A prior producer may finish after point/route handoff. Its stale end
        // must not stop the successor's maintenance or disconnect its tunnel.
        guard activeLease == lease else { return }
        activeLease = nil
        LocationSimulationSession.setMaintained(false)
        BackgroundLocationManager.shared.requestStop()
        endBackgroundTask()
        if connectionUnavailable {
            markTunnelDisconnected()
        }
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
            activityManager: DeviceRoutePlaybackActivityManager.shared,
            speedModel: .randomNatural
        )
    }
}

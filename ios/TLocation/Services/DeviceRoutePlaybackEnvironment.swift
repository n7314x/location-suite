//
//  DeviceRoutePlaybackEnvironment.swift
//  TLocation
//
//  Adapts the route domain to the existing phone-local simulation session.
//

import Foundation
import UIKit

struct DeviceRouteLocationSimulationSink: RouteLocationSimulationSink {
    func setCoordinate(_ coordinate: RoutePoint) async throws {
        let pairingFilePath = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: pairingFilePath) else {
            throw RoutePlaybackFailure(
                reason: .noPairingFile,
                message: "Import a pairing file before starting route playback."
            )
        }
        let deviceIP = DeviceConnectionContext.targetIPAddress
        let code = await runOnLocationCommandQueue {
            simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
        }
        guard code == 0 else { throw Self.failure(for: code, clearing: false) }
    }

    func clear() async throws {
        let code = await runOnLocationCommandQueue(clear_simulated_location)
        guard code == 0 else { throw Self.failure(for: code, clearing: true) }
    }

    private func runOnLocationCommandQueue(_ operation: @escaping () -> Int32) async -> Int32 {
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
    private var isActive = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func simulationDidStart() {
        guard !isActive else { return }
        isActive = true
        LocationSimulationSession.setMaintained(true)
        BackgroundLocationManager.shared.requestStart()
        beginBackgroundTask()
    }

    func simulationDidEnd(connectionUnavailable: Bool) {
        if isActive {
            isActive = false
            LocationSimulationSession.setMaintained(false)
            BackgroundLocationManager.shared.requestStop()
        }
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
            activityManager: DeviceRoutePlaybackActivityManager()
        )
    }
}

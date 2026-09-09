//
//  RoutePlaybackController.swift
//  TLocation
//

import Combine
import Foundation

enum RoutePlaybackFailureReason: Equatable, Sendable {
    case noPairingFile
    case tunnelUnavailable
    case developerDiskImageUnavailable
    case sessionFailed
    case interrupted
    case clearFailed
}

struct RoutePlaybackFailure: Error, Equatable, LocalizedError, Sendable {
    let reason: RoutePlaybackFailureReason
    let message: String

    var errorDescription: String? { message }
    var marksConnectionUnavailable: Bool { reason == .tunnelUnavailable }
}

struct RoutePlaybackError: Equatable, Sendable {
    let reason: RoutePlaybackFailureReason
    let message: String
}

enum RoutePlaybackState: Equatable, Sendable {
    case idle
    case ready
    case starting
    case playing
    case paused
    case stopping
    case completed
    case error(RoutePlaybackError)
}

protocol RouteLocationSimulationSink: Sendable {
    func setCoordinate(_ coordinate: RoutePoint) async throws
    func clear() async throws
}

@MainActor
protocol RoutePlaybackActivityManaging: AnyObject {
    func simulationDidStart()
    func simulationDidEnd(connectionUnavailable: Bool)
}

@MainActor
final class RoutePlaybackController: ObservableObject {
    static let updateInterval: TimeInterval = 1.0 / 3.0
    static let maintenanceInterval: TimeInterval = 4
    private static let maximumAdvanceInterval: TimeInterval = 1

    @Published private(set) var state: RoutePlaybackState = .idle
    @Published private(set) var metrics: RouteMetrics?
    @Published private(set) var isSimulationActive = false

    private(set) var route: LocationRoute?
    private var engine: RoutePlaybackEngine?
    private let sink: RouteLocationSimulationSink
    private let activityManager: RoutePlaybackActivityManaging
    private let automaticallySchedulesTicks: Bool
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var updateInFlight = false
    private var lastAdvanceTime: TimeInterval?
    private var lastDeviceUpdateTime: TimeInterval?
    private var heldCoordinate: RoutePoint?

    init(
        sink: RouteLocationSimulationSink,
        activityManager: RoutePlaybackActivityManaging,
        automaticallySchedulesTicks: Bool = true
    ) {
        self.sink = sink
        self.activityManager = activityManager
        self.automaticallySchedulesTicks = automaticallySchedulesTicks
    }

    var canEditRoute: Bool {
        switch state {
        case .starting, .playing, .paused, .stopping:
            return false
        case .idle, .ready, .completed, .error:
            return true
        }
    }

    var canStop: Bool {
        switch state {
        case .starting, .playing, .paused, .completed:
            return true
        case .idle, .ready, .stopping, .error:
            return isSimulationActive
        }
    }

    @discardableResult
    func prepare(_ newRoute: LocationRoute) -> Bool {
        guard canEditRoute else { return false }
        do {
            let newEngine = try RoutePlaybackEngine(route: newRoute)
            route = newRoute
            engine = newEngine
            metrics = newEngine.metrics
            state = .ready
            return true
        } catch {
            transitionToError(error, fallback: "This route cannot be played.")
            return false
        }
    }

    func removePreparedRoute() {
        guard canEditRoute else { return }
        route = nil
        engine = nil
        metrics = nil
        state = .idle
        if !isSimulationActive { invalidateTimer() }
    }

    func play(_ newRoute: LocationRoute) async {
        guard state != .starting, state != .playing, state != .paused, state != .stopping else { return }
        guard prepare(newRoute), let initialCoordinate = engine?.metrics.currentCoordinate else { return }

        generation &+= 1
        let run = generation
        state = .starting
        updateInFlight = true
        lastAdvanceTime = nil

        do {
            try await sink.setCoordinate(initialCoordinate)
            guard run == generation, state == .starting else { return }
            updateInFlight = false
            heldCoordinate = initialCoordinate
            isSimulationActive = true
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
            activityManager.simulationDidStart()
            state = .playing
            lastAdvanceTime = ProcessInfo.processInfo.systemUptime
            ensureTimerIfNeeded()
        } catch {
            guard run == generation else { return }
            updateInFlight = false
            failPlayback(with: error)
        }
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        lastAdvanceTime = nil
    }

    func resume() {
        guard state == .paused else { return }
        state = .playing
        lastAdvanceTime = ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    func stop() async -> Bool {
        guard canStop || state == .error else { return true }
        generation &+= 1
        let stopGeneration = generation
        state = .stopping
        updateInFlight = false
        lastAdvanceTime = nil

        do {
            try await sink.clear()
            guard stopGeneration == generation else { return false }
            finishStop(connectionUnavailable: false)
            return true
        } catch {
            guard stopGeneration == generation else { return false }
            let failure = normalizedFailure(error, fallback: "The simulated location could not be cleared.")
            finishStop(connectionUnavailable: failure.marksConnectionUnavailable)
            state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
            return false
        }
    }

    /// Cancels route ownership after another in-process feature has already
    /// changed or cleared the device session (for example a Shortcut). No FFI
    /// call is made here; the external operation remains authoritative.
    func relinquishWithoutClearing() {
        generation &+= 1
        updateInFlight = false
        lastAdvanceTime = nil
        heldCoordinate = nil
        if isSimulationActive {
            isSimulationActive = false
            activityManager.simulationDidEnd(connectionUnavailable: false)
        }
        resetToPreparedState()
    }

    /// Advances one controller tick. Kept internal so the no-device test target
    /// can drive time deterministically; production calls it from the timer.
    func advance(by requestedInterval: TimeInterval) async {
        guard state == .playing, !updateInFlight, var candidate = engine else { return }
        let interval = requestedInterval.isFinite
            ? min(max(requestedInterval, 0), Self.maximumAdvanceInterval)
            : 0
        let nextMetrics = candidate.advance(by: interval)
        let run = generation
        updateInFlight = true

        do {
            try await sink.setCoordinate(nextMetrics.currentCoordinate)
            guard run == generation else { return }
            updateInFlight = false
            guard state == .playing || state == .paused else { return }
            engine = candidate
            metrics = nextMetrics
            heldCoordinate = nextMetrics.currentCoordinate
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
            if candidate.isComplete {
                state = .completed
                lastAdvanceTime = nil
            }
        } catch {
            guard run == generation else { return }
            updateInFlight = false
            failPlayback(with: error)
        }
    }

    private func ensureTimerIfNeeded() {
        guard automaticallySchedulesTicks, timer == nil else { return }
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.timerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() async {
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .playing:
            let previous = lastAdvanceTime ?? now
            lastAdvanceTime = now
            await advance(by: now - previous)
        case .paused, .completed, .ready, .idle:
            guard isSimulationActive,
                  !updateInFlight,
                  let heldCoordinate,
                  now - (lastDeviceUpdateTime ?? 0) >= Self.maintenanceInterval else { return }
            await maintain(coordinate: heldCoordinate, run: generation)
        case .starting, .stopping, .error:
            break
        }
    }

    private func maintain(coordinate: RoutePoint, run: UInt64) async {
        updateInFlight = true
        do {
            try await sink.setCoordinate(coordinate)
            guard run == generation, isSimulationActive else { return }
            updateInFlight = false
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
        } catch {
            guard run == generation else { return }
            updateInFlight = false
            failPlayback(with: error)
        }
    }

    private func failPlayback(with error: Error) {
        let failure = normalizedFailure(error, fallback: "Route playback was interrupted.")
        generation &+= 1
        lastAdvanceTime = nil
        heldCoordinate = nil
        if isSimulationActive {
            isSimulationActive = false
        }
        activityManager.simulationDidEnd(connectionUnavailable: failure.marksConnectionUnavailable)
        state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
        if !isSimulationActive { invalidateTimer() }
    }

    private func transitionToError(_ error: Error, fallback: String) {
        let failure = normalizedFailure(error, fallback: fallback)
        state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
    }

    private func normalizedFailure(_ error: Error, fallback: String) -> RoutePlaybackFailure {
        if let failure = error as? RoutePlaybackFailure { return failure }
        return RoutePlaybackFailure(reason: .interrupted, message: fallback)
    }

    private func finishStop(connectionUnavailable: Bool) {
        heldCoordinate = nil
        lastDeviceUpdateTime = nil
        isSimulationActive = false
        activityManager.simulationDidEnd(connectionUnavailable: connectionUnavailable)
        resetToPreparedState()
        invalidateTimer()
    }

    private func resetToPreparedState() {
        if let route, let resetEngine = try? RoutePlaybackEngine(route: route) {
            engine = resetEngine
            metrics = resetEngine.metrics
            state = .ready
        } else {
            engine = nil
            metrics = nil
            state = .idle
        }
    }
}

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
    /// The command belonged to a producer that has already handed ownership to
    /// point mode or to a newer route generation.
    case superseded
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
    /// Route advancement has ended, but the exact fake coordinate and the
    /// location-simulation session remain deliberately alive.
    case stopped
    /// Device updates cannot currently be delivered. Distance and time are
    /// frozen while the existing timer retries only the last held coordinate.
    case connectionInterrupted(RoutePlaybackError)
    case completed
    /// The explicit Return to Real Location operation is in flight.
    case clearing
    case error(RoutePlaybackError)
}

extension RoutePlaybackState {
    var isConnectionInterrupted: Bool {
        if case .connectionInterrupted = self { return true }
        return false
    }
}

protocol RouteLocationSimulationSink: Sendable {
    /// Implementations must serialize set and clear operations in call order.
    /// That ordering is what lets a final hold update outrank an older route
    /// tick and lets an explicit clear outrank every older update.
    func setCoordinate(
        _ coordinate: RoutePoint,
        lease: LocationSimulationProducerLease
    ) async throws
    func clear() async throws
    func disconnect() async throws
}

@MainActor
protocol RoutePlaybackActivityManaging: AnyObject {
    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease)
    func simulationDidEnd(
        _ lease: LocationSimulationProducerLease,
        reason: LocationSimulationProducerEndReason
    )
    func simulationSessionWillDisconnect() -> LocationSimulationDisconnectLease
    func simulationSessionDidDisconnect(_ lease: LocationSimulationDisconnectLease)
}

@MainActor
final class RoutePlaybackController: ObservableObject {
    static let updateInterval: TimeInterval = 1.0 / 3.0
    static let maintenanceInterval: TimeInterval = 4
    private static let maximumAdvanceInterval: TimeInterval = 1

    @Published private(set) var state: RoutePlaybackState = .idle
    @Published private(set) var metrics: RouteMetrics?
    @Published private(set) var isSimulationActive = false
    @Published private(set) var speedMultiplier = 1.0

    private enum RecoveryState {
        case paused
        case stopped
        case completed
    }

    private(set) var route: LocationRoute?
    private var engine: RoutePlaybackEngine?
    private let sink: RouteLocationSimulationSink
    private let activityManager: RoutePlaybackActivityManaging
    private let automaticallySchedulesTicks: Bool
    private let speedModelOverride: MovementProfile?
    private let movementSeed: UInt64
    private var playbackOptions = RoutePlaybackOptions()
    private let ownership: LocationSimulationOwnership
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var updateInFlight = false
    private var lastAdvanceTime: TimeInterval?
    private var lastDeviceUpdateTime: TimeInterval?
    private var heldCoordinate: RoutePoint?
    private var recoveryState: RecoveryState?
    private var producerLease: LocationSimulationProducerLease?

    init(
        sink: RouteLocationSimulationSink,
        activityManager: RoutePlaybackActivityManaging,
        automaticallySchedulesTicks: Bool = true,
        speedModel: WalkingSpeedModel? = nil,
        ownership: LocationSimulationOwnership = .shared
    ) {
        self.sink = sink
        self.activityManager = activityManager
        self.automaticallySchedulesTicks = automaticallySchedulesTicks
        self.speedModelOverride = speedModel
        self.movementSeed = speedModel?.seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        self.ownership = ownership
    }

    var canEditRoute: Bool {
        switch state {
        case .starting, .playing, .paused, .connectionInterrupted, .clearing:
            return false
        case .idle, .ready, .stopped, .completed, .error:
            return true
        }
    }

    var canStopRoute: Bool {
        switch state {
        case .starting, .playing, .paused, .connectionInterrupted, .completed:
            return true
        case .idle, .ready, .stopped, .clearing, .error:
            return false
        }
    }

    var canReturnToRealLocation: Bool {
        if isSimulationActive { return true }
        switch state {
        case .starting, .playing, .paused, .stopped, .connectionInterrupted, .completed:
            return true
        case .idle, .ready, .clearing, .error:
            return false
        }
    }

    var canRelinquishWithoutClearing: Bool {
        switch state {
        case .starting, .clearing:
            return false
        case .idle, .ready, .playing, .paused, .stopped, .connectionInterrupted, .completed, .error:
            return true
        }
    }

    @discardableResult
    func prepare(_ newRoute: LocationRoute) -> Bool {
        guard canEditRoute else { return false }
        do {
            let newEngine = try RoutePlaybackEngine(
                route: newRoute,
                speedModel: speedModelOverride ?? MovementProfile.profile(for: newRoute.mode, seed: movementSeed),
                speedMultiplier: speedMultiplier,
                options: playbackOptions
            )
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

    func setSpeedMultiplier(
        _ requestedMultiplier: Double,
        mode requestedMode: RouteMovementMode? = nil
    ) {
        let mode = requestedMode ?? route?.mode ?? .walking
        let multiplier = MovementProfile.clampedMultiplier(requestedMultiplier, mode: mode)
        speedMultiplier = multiplier
        engine?.setSpeedMultiplier(multiplier)
        if let engine { metrics = engine.metrics }
    }

    func setLoopMode(_ mode: RouteLoopMode) {
        guard canEditRoute else { return }
        playbackOptions.loopMode = mode
        if let route { _ = prepare(route) }
    }

    func play(
        _ newRoute: LocationRoute,
        ownershipDidChange: (() -> Void)? = nil
    ) async {
        switch state {
        case .starting, .playing, .paused, .connectionInterrupted, .clearing:
            return
        case .idle, .ready, .stopped, .completed, .error:
            break
        }
        guard prepare(newRoute), let initialCoordinate = engine?.metrics.currentCoordinate else { return }

        generation &+= 1
        let run = generation
        let lease = ownership.claim(.route)
        producerLease = lease
        isSimulationActive = true
        activityManager.simulationDidTakeOwnership(lease)
        // Point mode retires its timer here, after the route lease and shared
        // maintenance ownership are already in place but before the first route
        // coordinate is enqueued. There is no unmaintained handoff window.
        ownershipDidChange?()
        state = .starting
        recoveryState = nil
        updateInFlight = true
        lastAdvanceTime = nil

        do {
            try await sink.setCoordinate(initialCoordinate, lease: lease)
            guard run == generation, state == .starting else { return }
            updateInFlight = false
            heldCoordinate = initialCoordinate
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
            state = .playing
            lastAdvanceTime = ProcessInfo.processInfo.systemUptime
            ensureTimerIfNeeded()
        } catch {
            guard run == generation else { return }
            updateInFlight = false
            failInitialPlayback(with: error)
        }
    }

    func pause() {
        guard state == .playing else { return }
        engine?.hold()
        if let engine { metrics = engine.metrics }
        state = .paused
        lastAdvanceTime = nil
    }

    func resume() {
        guard state == .paused || state == .stopped else { return }
        state = .playing
        recoveryState = nil
        lastAdvanceTime = ProcessInfo.processInfo.systemUptime
    }

    /// Ends movement while explicitly retaining the fake location. The final
    /// set is queued after any older in-flight tick, so the device settles at
    /// the exact coordinate represented by the last committed metrics.
    @discardableResult
    func stopRoute() async -> Bool {
        guard canStopRoute else { return state == .stopped }

        generation &+= 1
        let stopGeneration = generation
        engine?.hold()
        if let engine { metrics = engine.metrics }
        guard let coordinate = heldCoordinate ?? metrics?.currentCoordinate else {
            state = .error(RoutePlaybackError(
                reason: .interrupted,
                message: "The route had no coordinate to hold."
            ))
            return false
        }

        state = .stopped
        recoveryState = .stopped
        updateInFlight = true
        lastAdvanceTime = nil
        heldCoordinate = coordinate
        ensureTimerIfNeeded()

        do {
            guard let lease = producerLease else { return false }
            try await sink.setCoordinate(coordinate, lease: lease)
            guard stopGeneration == generation, state == .stopped else { return false }
            updateInFlight = false
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
            return true
        } catch {
            guard stopGeneration == generation else { return false }
            updateInFlight = false
            enterConnectionInterrupted(with: error, recovery: .stopped)
            return false
        }
    }

    /// The only route operation that invokes `clear()` and releases simulation
    /// ownership. Generation invalidation happens before the clear is enqueued;
    /// the serial sink then guarantees no older update can run after it.
    @discardableResult
    func returnToRealLocation() async -> Bool {
        guard canReturnToRealLocation else { return true }

        generation &+= 1
        let clearGeneration = generation
        let lease = producerLease
        ownership.invalidateAll()
        producerLease = nil
        state = .clearing
        recoveryState = nil
        updateInFlight = true
        lastAdvanceTime = nil

        do {
            try await sink.clear()
            guard clearGeneration == generation else { return false }
            updateInFlight = false
            finishClear(lease: lease, reason: .returnedToRealGPS)
            return true
        } catch {
            guard clearGeneration == generation else { return false }
            updateInFlight = false
            let failure = normalizedFailure(error, fallback: "The simulated location could not be cleared.")
            // A failed explicit clear must never start resending and accidentally
            // resurrect a simulation the user asked to end.
            finishClear(
                lease: lease,
                reason: .failure(connectionUnavailable: failure.marksConnectionUnavailable)
            )
            state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
            return false
        }
    }

    /// Clears any active fake coordinate and intentionally tears down the warm
    /// transport. This destructive lifecycle operation is exposed in Settings.
    @discardableResult
    func disconnectSession() async -> Bool {
        generation &+= 1
        let disconnectGeneration = generation
        let disconnectLease = activityManager.simulationSessionWillDisconnect()
        ownership.invalidateAll()
        producerLease = nil
        state = .clearing
        recoveryState = nil
        updateInFlight = true
        lastAdvanceTime = nil

        do {
            try await sink.disconnect()
            guard disconnectGeneration == generation else { return false }
            updateInFlight = false
            finishClear(lease: nil, reason: nil)
            activityManager.simulationSessionDidDisconnect(disconnectLease)
            return true
        } catch {
            guard disconnectGeneration == generation else { return false }
            updateInFlight = false
            let failure = normalizedFailure(
                error,
                fallback: "The session was disconnected, but real GPS could not be confirmed."
            )
            finishClear(lease: nil, reason: nil)
            activityManager.simulationSessionDidDisconnect(disconnectLease)
            state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
            return false
        }
    }

    /// Cancels route ownership after another in-process feature has already
    /// changed or cleared the device session (for example a Shortcut). No FFI
    /// call is made here; the external operation remains authoritative.
    func relinquishWithoutClearing() {
        generation &+= 1
        let lease = producerLease
        producerLease = nil
        if let lease { ownership.relinquish(lease) }
        updateInFlight = false
        lastAdvanceTime = nil
        heldCoordinate = nil
        recoveryState = nil
        if isSimulationActive, let lease {
            isSimulationActive = false
            activityManager.simulationDidEnd(lease, reason: .relinquished)
        } else {
            isSimulationActive = false
        }
        resetToPreparedState()
        invalidateTimer()
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
            guard let lease = producerLease else { return }
            try await sink.setCoordinate(nextMetrics.currentCoordinate, lease: lease)
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
            enterConnectionInterrupted(with: error, recovery: .paused)
        }
    }

    /// Deterministic test seam and the operation used by the production timer
    /// for paused/stopped/completed/interrupted keep-alives.
    func maintainHeldCoordinate() async {
        guard isSimulationActive,
              !updateInFlight,
              let heldCoordinate else { return }
        await maintain(coordinate: heldCoordinate, run: generation)
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
        case .paused, .stopped, .connectionInterrupted, .completed, .ready, .idle:
            guard isSimulationActive,
                  !updateInFlight,
                  now - (lastDeviceUpdateTime ?? 0) >= Self.maintenanceInterval else { return }
            await maintainHeldCoordinate()
        case .starting, .clearing, .error:
            break
        }
    }

    private func maintain(coordinate: RoutePoint, run: UInt64) async {
        guard let lease = producerLease else { return }
        updateInFlight = true
        do {
            try await sink.setCoordinate(coordinate, lease: lease)
            guard run == generation, isSimulationActive else { return }
            updateInFlight = false
            lastDeviceUpdateTime = ProcessInfo.processInfo.systemUptime
            if case .connectionInterrupted = state {
                restoreAfterConnectionRecovery()
            }
        } catch {
            guard run == generation else { return }
            updateInFlight = false
            let recovery = recoveryState ?? recoveryStateForCurrentState()
            enterConnectionInterrupted(with: error, recovery: recovery)
        }
    }

    private func enterConnectionInterrupted(with error: Error, recovery: RecoveryState) {
        let failure = normalizedFailure(error, fallback: "Route playback lost its device connection.")
        engine?.hold()
        if let engine { metrics = engine.metrics }
        recoveryState = recovery
        lastAdvanceTime = nil
        state = .connectionInterrupted(RoutePlaybackError(reason: failure.reason, message: failure.message))
        ensureTimerIfNeeded()
    }

    private func recoveryStateForCurrentState() -> RecoveryState {
        switch state {
        case .stopped: return .stopped
        case .completed: return .completed
        default: return .paused
        }
    }

    private func restoreAfterConnectionRecovery() {
        switch recoveryState ?? .paused {
        case .paused: state = .paused
        case .stopped: state = .stopped
        case .completed: state = .completed
        }
        recoveryState = nil
        lastAdvanceTime = nil
    }

    private func failInitialPlayback(with error: Error) {
        let failure = normalizedFailure(error, fallback: "Route playback could not start.")
        generation &+= 1
        lastAdvanceTime = nil
        heldCoordinate = nil
        recoveryState = nil
        let lease = producerLease
        producerLease = nil
        if let lease { ownership.relinquish(lease) }
        if isSimulationActive, let lease {
            isSimulationActive = false
            activityManager.simulationDidEnd(
                lease,
                reason: .failure(connectionUnavailable: failure.marksConnectionUnavailable)
            )
        } else {
            isSimulationActive = false
        }
        state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
        invalidateTimer()
    }

    private func transitionToError(_ error: Error, fallback: String) {
        let failure = normalizedFailure(error, fallback: fallback)
        state = .error(RoutePlaybackError(reason: failure.reason, message: failure.message))
    }

    private func normalizedFailure(_ error: Error, fallback: String) -> RoutePlaybackFailure {
        if let failure = error as? RoutePlaybackFailure { return failure }
        return RoutePlaybackFailure(reason: .interrupted, message: fallback)
    }

    private func finishClear(
        lease: LocationSimulationProducerLease?,
        reason: LocationSimulationProducerEndReason?
    ) {
        heldCoordinate = nil
        lastDeviceUpdateTime = nil
        recoveryState = nil
        if isSimulationActive, let lease, let reason {
            isSimulationActive = false
            activityManager.simulationDidEnd(
                lease,
                reason: reason
            )
        } else {
            isSimulationActive = false
        }
        resetToPreparedState()
        invalidateTimer()
    }

    private func resetToPreparedState() {
        if let route,
           let resetEngine = try? RoutePlaybackEngine(
               route: route,
               speedModel: speedModelOverride ?? MovementProfile.profile(for: route.mode, seed: movementSeed),
               speedMultiplier: speedMultiplier,
               options: playbackOptions
           ) {
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

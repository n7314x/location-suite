//
//  LocationSimulationSessionKeeper.swift
//  TLocation
//

import Combine
import Foundation

enum LocationSimulationSessionLifecycleState: String, Equatable, Sendable {
    case disconnected
    case activePoint
    case activeRoute
    case idleWarm
}

enum LocationSimulationProducerEndReason: Equatable, Sendable {
    /// The device acknowledged stopLocationSimulation and is back on real GPS.
    case returnedToRealGPS
    /// The producer ended without clearing (normally a superseded handoff).
    case relinquished
    /// A real device/transport command failed. The associated value preserves
    /// the caller's existing decision about the broader tunnel diagnostic.
    case failure(connectionUnavailable: Bool)
}

struct LocationSimulationDisconnectLease: Equatable, Sendable {
    let generation: UInt64
}

enum WarmLocationSimulationHeartbeatResult: Equatable, Sendable {
    case succeeded(Date)
    case failed(String)
    /// The idle ownership generation changed before the command ran or returned.
    case stale
}

protocol WarmLocationSimulationHeartbeatPerforming: Sendable {
    func performHeartbeat(
        for lease: LocationSimulationIdleLease,
        completion: @escaping @Sendable (WarmLocationSimulationHeartbeatResult) -> Void
    )

    /// Returns true only when this idle generation still owned the handles and
    /// they were actually destroyed.
    func discardStaleSession(
        for lease: LocationSimulationIdleLease,
        reason: String,
        completion: @escaping @Sendable (Bool) -> Void
    )
}

@MainActor
protocol WarmLocationSimulationHeartbeatCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol WarmLocationSimulationHeartbeatScheduling: AnyObject {
    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> WarmLocationSimulationHeartbeatCancellation
}

protocol LocationSimulationSessionStatusProviding: Sendable {
    var isSessionOpen: Bool { get }
    var isSimulationActive: Bool { get }
}

@MainActor
protocol LocationSimulationBackgroundActivityManaging: AnyObject {
    func requestStart()
    func requestStop()
}

/// Process-wide lifecycle owner for Point, Route, and the real-GPS warm idle
/// state. It deliberately owns no coordinate: an idle keeper can only issue
/// stopLocationSimulation heartbeats through an injected driver.
@MainActor
final class LocationSimulationSessionKeeper: ObservableObject {
    nonisolated static let heartbeatInterval: TimeInterval = 12
    nonisolated static let heartbeatFailureThreshold = 3
    private static let successfulHeartbeatLogInterval = 25

    @Published private(set) var state: LocationSimulationSessionLifecycleState = .disconnected
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var heartbeatFailureCount = 0
    private(set) var consecutiveHeartbeatFailures = 0

    var isIdleKeeperActive: Bool { state == .idleWarm }

    private let ownership: LocationSimulationOwnership
    private let status: LocationSimulationSessionStatusProviding
    private let heartbeat: WarmLocationSimulationHeartbeatPerforming
    private let scheduler: WarmLocationSimulationHeartbeatScheduling
    private let backgroundActivity: LocationSimulationBackgroundActivityManaging
    private let interval: TimeInterval
    private let failureThreshold: Int
    private let log: (String) -> Void

    private var activeLease: LocationSimulationProducerLease?
    private var idleLease: LocationSimulationIdleLease?
    private var preparationLease: LocationSimulationPreparationLease?
    private var timer: WarmLocationSimulationHeartbeatCancellation?
    private var ownsBackgroundActivity = false
    private var heartbeatInFlight = false
    private var lifecycleGeneration: UInt64 = 0
    private var successfulHeartbeatCount = 0
    private var hasStartedIdleKeeper = false
    private var staleCleanupScheduled = false

    init(
        ownership: LocationSimulationOwnership,
        status: LocationSimulationSessionStatusProviding,
        heartbeat: WarmLocationSimulationHeartbeatPerforming,
        scheduler: WarmLocationSimulationHeartbeatScheduling,
        backgroundActivity: LocationSimulationBackgroundActivityManaging,
        interval: TimeInterval = LocationSimulationSessionKeeper.heartbeatInterval,
        failureThreshold: Int = LocationSimulationSessionKeeper.heartbeatFailureThreshold,
        log: @escaping (String) -> Void = { _ in }
    ) {
        precondition(interval > 0)
        precondition(failureThreshold > 0)
        self.ownership = ownership
        self.status = status
        self.heartbeat = heartbeat
        self.scheduler = scheduler
        self.backgroundActivity = backgroundActivity
        self.interval = interval
        self.failureThreshold = failureThreshold
        self.log = log
    }

    func producerDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        guard ownership.isCurrent(lease) else { return }
        let wasIdleWarm = state == .idleWarm
        advanceLifecycle()
        activeLease = lease
        idleLease = nil
        preparationLease = nil
        staleCleanupScheduled = false
        consecutiveHeartbeatFailures = 0
        state = lease.producer == .point ? .activePoint : .activeRoute
        acquireBackgroundActivityIfNeeded()

        if wasIdleWarm {
            log("Warm session keeper paused for \(lease.producer == .point ? "Point" : "Route").")
        }
    }

    /// Returns false for a stale producer completion so its caller cannot end a
    /// successor's short transition task or alter connection diagnostics.
    @discardableResult
    func producerDidEnd(
        _ lease: LocationSimulationProducerLease,
        reason: LocationSimulationProducerEndReason
    ) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        advanceLifecycle()

        switch reason {
        case .returnedToRealGPS:
            startIdleKeeperAfterReturn()
        case .relinquished, .failure:
            stopLongLivedActivity(state: .disconnected)
        }
        return true
    }

    /// Holds the existing long-lived activity while a coordinate-free session
    /// open is queued. Lifecycle state remains disconnected until a real DVT
    /// handle exists; the preparation lease is the race guard during this gap.
    func preparationWillBegin(_ lease: LocationSimulationPreparationLease) {
        guard ownership.isCurrent(lease) else { return }
        advanceLifecycle()
        activeLease = nil
        idleLease = nil
        preparationLease = lease
        staleCleanupScheduled = false
        consecutiveHeartbeatFailures = 0
        state = .disconnected
        acquireBackgroundActivityIfNeeded()
        log("Preparing an idle LocationSimulation session.")
    }

    /// Transfers a successful preparation directly into the existing idleWarm
    /// lifecycle. No producer is invented and no coordinate becomes active.
    @discardableResult
    func preparationDidSucceed(
        _ lease: LocationSimulationPreparationLease,
        idleLease newIdleLease: LocationSimulationIdleLease
    ) -> Bool {
        guard preparationLease == lease,
              ownership.isCurrent(newIdleLease),
              status.isSessionOpen,
              !status.isSimulationActive else { return false }
        preparationLease = nil
        advanceLifecycle()
        startIdleKeeper(
            lease: newIdleLease,
            resumeLog: "Warm session keeper active for prepared LTE session."
        )
        return true
    }

    /// Balances the activity acquired before the command was queued. A stale
    /// completion is ignored because its Point/Route/Disconnect successor now
    /// owns that same activity lifecycle.
    @discardableResult
    func preparationDidFail(_ lease: LocationSimulationPreparationLease) -> Bool {
        guard preparationLease == lease else { return false }
        preparationLease = nil
        advanceLifecycle()
        stopLongLivedActivity(state: .disconnected)
        log("LocationSimulation session preparation failed; idle keeper was not started.")
        return true
    }

    /// Stops idle work before the destructive FFI command is queued. The token
    /// prevents its late completion from stopping a producer claimed meanwhile.
    func sessionWillDisconnect() -> LocationSimulationDisconnectLease {
        advanceLifecycle()
        activeLease = nil
        idleLease = nil
        preparationLease = nil
        staleCleanupScheduled = false
        consecutiveHeartbeatFailures = 0
        stopLongLivedActivity(state: .disconnected)
        log("Warm session keeper stopped for explicit Disconnect Session.")
        return LocationSimulationDisconnectLease(generation: lifecycleGeneration)
    }

    func sessionDidDisconnect(_ lease: LocationSimulationDisconnectLease) {
        guard lease.generation == lifecycleGeneration else { return }
        activeLease = nil
        idleLease = nil
        preparationLease = nil
        stopLongLivedActivity(state: .disconnected)
    }

    /// Called when the real FFI handle closes outside the idle failure verdict
    /// (for example an active Point update discovers a dead transport).
    func sessionDidClose() {
        advanceLifecycle()
        activeLease = nil
        idleLease = nil
        preparationLease = nil
        staleCleanupScheduled = false
        consecutiveHeartbeatFailures = 0
        stopLongLivedActivity(state: .disconnected)
    }

    private func startIdleKeeperAfterReturn() {
        guard status.isSessionOpen,
              !status.isSimulationActive,
              let lease = ownership.idleLease() else {
            stopLongLivedActivity(state: .disconnected)
            return
        }

        startIdleKeeper(
            lease: lease,
            resumeLog: "Warm session keeper resumed after Return."
        )
    }

    private func startIdleKeeper(
        lease: LocationSimulationIdleLease,
        resumeLog: String
    ) {
        idleLease = lease
        state = .idleWarm
        heartbeatInFlight = false
        staleCleanupScheduled = false
        consecutiveHeartbeatFailures = 0
        acquireBackgroundActivityIfNeeded()
        timer = scheduler.scheduleRepeating(every: interval) { [weak self] in
            self?.timerFired()
        }

        if !hasStartedIdleKeeper {
            hasStartedIdleKeeper = true
            log("Warm session keeper started.")
        }
        log(resumeLog)
    }

    private func timerFired() {
        guard state == .idleWarm,
              !heartbeatInFlight,
              !staleCleanupScheduled,
              let lease = idleLease,
              ownership.isCurrent(lease),
              status.isSessionOpen,
              !status.isSimulationActive else { return }

        heartbeatInFlight = true
        let generation = lifecycleGeneration
        heartbeat.performHeartbeat(for: lease) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.heartbeatCompleted(result, lease: lease, generation: generation)
            }
        }
    }

    private func heartbeatCompleted(
        _ result: WarmLocationSimulationHeartbeatResult,
        lease: LocationSimulationIdleLease,
        generation: UInt64
    ) {
        guard generation == lifecycleGeneration,
              state == .idleWarm,
              idleLease == lease,
              ownership.isCurrent(lease) else { return }
        heartbeatInFlight = false

        switch result {
        case .stale:
            return
        case .succeeded(let date):
            lastHeartbeat = date
            consecutiveHeartbeatFailures = 0
            successfulHeartbeatCount &+= 1
            if successfulHeartbeatCount == 1 ||
                successfulHeartbeatCount % Self.successfulHeartbeatLogInterval == 0 {
                log("Warm session heartbeat succeeded (\(successfulHeartbeatCount) total).")
            }
        case .failed(let detail):
            heartbeatFailureCount &+= 1
            consecutiveHeartbeatFailures &+= 1
            log(
                "Warm session heartbeat failed (\(consecutiveHeartbeatFailures) of \(failureThreshold)): \(detail)"
            )
            guard consecutiveHeartbeatFailures >= failureThreshold else { return }
            discardStaleSession(lease: lease, detail: detail)
        }
    }

    private func discardStaleSession(lease: LocationSimulationIdleLease, detail: String) {
        guard !staleCleanupScheduled else { return }
        staleCleanupScheduled = true
        timer?.cancel()
        timer = nil
        state = .disconnected
        releaseBackgroundActivityIfNeeded()
        log("Warm session heartbeat threshold reached; cleaning stale session handles.")

        let generation = lifecycleGeneration
        heartbeat.discardStaleSession(for: lease, reason: detail) { [weak self] didClean in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.lifecycleGeneration,
                      self.staleCleanupScheduled else { return }
                self.staleCleanupScheduled = false
                if didClean {
                    self.idleLease = nil
                    self.log("Stale warm LocationSimulation session cleaned up.")
                }
            }
        }
    }

    private func advanceLifecycle() {
        lifecycleGeneration &+= 1
        timer?.cancel()
        timer = nil
        heartbeatInFlight = false
    }

    private func acquireBackgroundActivityIfNeeded() {
        guard !ownsBackgroundActivity else { return }
        ownsBackgroundActivity = true
        backgroundActivity.requestStart()
    }

    private func releaseBackgroundActivityIfNeeded() {
        guard ownsBackgroundActivity else { return }
        ownsBackgroundActivity = false
        backgroundActivity.requestStop()
    }

    private func stopLongLivedActivity(state newState: LocationSimulationSessionLifecycleState) {
        timer?.cancel()
        timer = nil
        heartbeatInFlight = false
        state = newState
        releaseBackgroundActivityIfNeeded()
    }
}

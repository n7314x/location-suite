//
//  LocationSimulationOwnership.swift
//  TLocation
//

import Foundation

/// The single source that is currently allowed to send simulated coordinates.
///
/// Producer ownership is deliberately independent from the device session. A
/// point can hand its lease to a route (and back again) while `sessionOpen`
/// remains true. Return preserves it; only Disconnect Session closes it.
enum LocationSimulationProducer: Equatable, Sendable {
    case none
    case point
    case route
}

struct LocationSimulationProducerLease: Equatable, Sendable {
    let producer: LocationSimulationProducer
    fileprivate let generation: UInt64
}

/// A proof that no coordinate producer owned the shared session at a specific
/// ownership generation. Idle heartbeats carry this onto the command queue;
/// any later Point/Route claim invalidates it before the heartbeat can touch
/// the FFI.
struct LocationSimulationIdleLease: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Exclusive reservation for opening an idle session without claiming a
/// coordinate producer. Point, Route, Return, or Disconnect invalidates it by
/// advancing the same generation used by every other lifecycle command.
struct LocationSimulationPreparationLease: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Lock-guarded process-wide ownership for the shared location-simulation
/// handle. Callers capture a lease when they become the producer, then recheck
/// it on `LocationSimulationCommandQueue` immediately before touching the FFI.
/// Claiming a new producer invalidates every command queued by the old one.
final class LocationSimulationOwnership: @unchecked Sendable {
    static let shared = LocationSimulationOwnership()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var producer: LocationSimulationProducer = .none
    private var preparationInProgress = false
    private var sessionOpen = false

    init() {}

    @discardableResult
    func claim(_ newProducer: LocationSimulationProducer) -> LocationSimulationProducerLease {
        precondition(newProducer != .none, "none cannot produce coordinates")
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        producer = newProducer
        preparationInProgress = false
        return LocationSimulationProducerLease(producer: newProducer, generation: generation)
    }

    /// Relinquishes only the lease supplied. A stale producer cannot retire the
    /// producer that replaced it.
    @discardableResult
    func relinquish(_ lease: LocationSimulationProducerLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard producer == lease.producer, generation == lease.generation else { return false }
        generation &+= 1
        producer = .none
        preparationInProgress = false
        return true
    }

    /// Invalidates all coordinate producers before an explicit clear is queued.
    /// The previous lease is returned so its maintenance activity can be ended
    /// after the clear completes.
    @discardableResult
    func invalidateAll() -> LocationSimulationProducerLease? {
        lock.lock()
        defer { lock.unlock() }
        let previous = producer == .none
            ? nil
            : LocationSimulationProducerLease(producer: producer, generation: generation)
        generation &+= 1
        producer = .none
        preparationInProgress = false
        return previous
    }

    /// Reserves the no-producer generation before preparation is queued. A
    /// second preparation cannot start, and producer/disconnect claims can
    /// supersede this reservation through the normal generation mechanism.
    func beginPreparation() -> LocationSimulationPreparationLease? {
        lock.lock()
        defer { lock.unlock() }
        guard producer == .none, !preparationInProgress else { return nil }
        generation &+= 1
        preparationInProgress = true
        return LocationSimulationPreparationLease(generation: generation)
    }

    func isCurrent(_ lease: LocationSimulationPreparationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producer == .none
            && preparationInProgress
            && generation == lease.generation
    }

    /// Converts a successful preparation reservation into the idle lease the
    /// existing heartbeat keeper already understands.
    func finishPreparation(
        _ lease: LocationSimulationPreparationLease
    ) -> LocationSimulationIdleLease? {
        lock.lock()
        defer { lock.unlock() }
        guard producer == .none,
              preparationInProgress,
              generation == lease.generation else { return nil }
        preparationInProgress = false
        return LocationSimulationIdleLease(generation: generation)
    }

    @discardableResult
    func cancelPreparation(_ lease: LocationSimulationPreparationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard producer == .none,
              preparationInProgress,
              generation == lease.generation else { return false }
        preparationInProgress = false
        return true
    }

    func isCurrent(_ lease: LocationSimulationProducerLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producer == lease.producer && generation == lease.generation
    }

    /// Captures the current idle generation. A producer claim, another Return,
    /// or Disconnect Session all advance the generation and retire the lease.
    func idleLease() -> LocationSimulationIdleLease? {
        lock.lock()
        defer { lock.unlock() }
        guard producer == .none, !preparationInProgress else { return nil }
        return LocationSimulationIdleLease(generation: generation)
    }

    func isCurrent(_ lease: LocationSimulationIdleLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producer == .none
            && !preparationInProgress
            && generation == lease.generation
    }

    var currentProducer: LocationSimulationProducer {
        lock.lock()
        defer { lock.unlock() }
        return producer
    }

    var isSessionOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionOpen
    }

    /// Updated only by the FFI bridge when its real handle opens or closes.
    /// Producer handoffs never call this method.
    func setSessionOpen(_ isOpen: Bool) {
        lock.lock()
        sessionOpen = isOpen
        lock.unlock()
    }
}

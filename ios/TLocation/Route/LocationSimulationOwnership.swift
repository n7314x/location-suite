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

/// Lock-guarded process-wide ownership for the shared location-simulation
/// handle. Callers capture a lease when they become the producer, then recheck
/// it on `LocationSimulationCommandQueue` immediately before touching the FFI.
/// Claiming a new producer invalidates every command queued by the old one.
final class LocationSimulationOwnership: @unchecked Sendable {
    static let shared = LocationSimulationOwnership()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var producer: LocationSimulationProducer = .none
    private var sessionOpen = false

    init() {}

    @discardableResult
    func claim(_ newProducer: LocationSimulationProducer) -> LocationSimulationProducerLease {
        precondition(newProducer != .none, "none cannot produce coordinates")
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        producer = newProducer
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
        return previous
    }

    func isCurrent(_ lease: LocationSimulationProducerLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producer == lease.producer && generation == lease.generation
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

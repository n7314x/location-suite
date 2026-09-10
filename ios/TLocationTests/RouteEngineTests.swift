//
//  RouteEngineTests.swift
//  TLocationTests
//

import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import RouteEngine
#else
@testable import TLocation
#endif

private func point(_ latitude: Double, _ longitude: Double) throws -> RoutePoint {
    try RoutePoint(latitude: latitude, longitude: longitude)
}

private func route(_ points: [RoutePoint], id: String = "route_test") throws -> LocationRoute {
    try LocationRoute(id: id, points: points, metadata: RouteMetadata(source: .waypoint))
}

struct RouteContractTests {
    @Test func routeRequiresAtLeastTwoUsablePoints() throws {
        #expect(throws: RouteValidationError.tooFewPoints) {
            try route([point(40, -79)])
        }

        let duplicate = try point(40, -79)
        #expect(throws: RouteValidationError.tooFewUsablePoints) {
            try route([duplicate, duplicate])
        }
    }

    @Test func coordinatesAreValidatedWhenCreatedAndDecoded() throws {
        #expect(throws: RouteValidationError.invalidLatitude) {
            try point(90.1, 0)
        }
        #expect(throws: RouteValidationError.invalidLongitude) {
            try point(0, -Double.infinity)
        }

        let invalidJSON = Data(#"{"version":1,"id":"route_bad","mode":"walking","points":[{"latitude":0,"longitude":0},{"latitude":91,"longitude":1}],"speedProfile":"natural"}"#.utf8)
        #expect(throws: RouteValidationError.invalidLatitude) {
            try JSONDecoder().decode(LocationRoute.self, from: invalidJSON)
        }
    }

    @Test func jsonContractUsesPortableCamelCaseValues() throws {
        let value = try LocationRoute(
            id: "route_contract",
            name: "Morning Walk",
            points: [point(40.0001, -79.0001), point(40.0005, -79.0007)],
            metadata: RouteMetadata(createdAt: "2026-09-09T13:00:00Z", source: .waypoint)
        )
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["version"] as? Int == 1)
        #expect(object["id"] as? String == "route_contract")
        #expect(object["mode"] as? String == "walking")
        #expect(object["speedProfile"] as? String == "natural")
        #expect((object["points"] as? [Any])?.count == 2)
    }
}

struct RouteGeometryTests {
    private let start = try! RoutePoint(latitude: 0, longitude: 0)
    private let end = try! RoutePoint(latitude: 0, longitude: 0.001)

    @Test func calculatesGeographicDistance() throws {
        let geometry = try RouteGeometry(points: [start, end])
        #expect(abs(geometry.totalDistance - 111.195) < 0.15)
    }

    @Test func interpolationAtSegmentStartMidpointAndEnd() throws {
        let geometry = try RouteGeometry(points: [start, end])
        let atStart = geometry.position(atDistance: 0)
        let atMiddle = geometry.position(atDistance: geometry.totalDistance / 2)
        let atEnd = geometry.position(atDistance: geometry.totalDistance)

        #expect(atStart.coordinate == start)
        #expect(abs(atMiddle.coordinate.longitude - 0.0005) < 0.000_000_1)
        #expect(abs(atMiddle.coordinate.latitude) < 0.000_000_1)
        #expect(atEnd.coordinate == end)
    }

    @Test func progressesAcrossMultipleSegments() throws {
        let corner = try point(0, 0.001)
        let finish = try point(0.001, 0.001)
        let geometry = try RouteGeometry(points: [start, corner, finish])
        let secondSegment = geometry.position(atDistance: geometry.segments[0].length + geometry.segments[1].length / 2)

        #expect(secondSegment.segmentIndex == 1)
        #expect(abs(secondSegment.coordinate.latitude - 0.0005) < 0.000_000_1)
        #expect(abs(secondSegment.coordinate.longitude - 0.001) < 0.000_000_1)
    }

    @Test func duplicateAndVeryShortPointsAreRemovedSafely() throws {
        let subCentimetre = try point(0, 0.000_000_01)
        let geometry = try RouteGeometry(points: [start, start, subCentimetre, end])

        #expect(geometry.points.count == 2)
        #expect(geometry.segments.count == 1)
        #expect(geometry.totalDistance.isFinite)
        #expect(geometry.totalDistance > 100)
    }

    @Test func antimeridianInterpolationTakesTheShortPath() throws {
        let west = try point(0, 179.9)
        let east = try point(0, -179.9)
        let midpoint = RouteGeometry.interpolate(from: west, to: east, fraction: 0.5)
        #expect(abs(abs(midpoint.longitude) - 180) < 0.000_001)
    }

    @Test func interpolationNearThePoleAlwaysProducesAValidCoordinate() throws {
        let first = try point(89.999_999, -120)
        let second = try point(89.999_999, 120)
        let midpoint = RouteGeometry.interpolate(from: first, to: second, fraction: 0.5)

        #expect(midpoint.latitude.isFinite)
        #expect(midpoint.longitude.isFinite)
        #expect((-90...90).contains(midpoint.latitude))
        #expect((-180...180).contains(midpoint.longitude))
    }
}

struct WalkingSpeedModelTests {
    @Test func defaultMultiplierAndClampingAreSafe() throws {
        let value = try route([point(0, 0), point(0, 0.01)])
        var engine = try RoutePlaybackEngine(route: value)

        #expect(engine.speedMultiplier == 1)
        engine.setSpeedMultiplier(0.1)
        #expect(engine.speedMultiplier == 0.5)
        engine.setSpeedMultiplier(8)
        #expect(engine.speedMultiplier == 3)
        engine.setSpeedMultiplier(.nan)
        #expect(engine.speedMultiplier == 1)
    }

    @Test func seededVariationIsDeterministicAndBounded() {
        let first = WalkingSpeedModel(seed: 42)
        let second = WalkingSpeedModel(seed: 42)

        for step in 0...2_400 {
            let time = Double(step) * 0.1
            let a = first.variationFactor(at: time)
            let b = second.variationFactor(at: time)
            #expect(a == b)
            #expect(a >= first.minimumVariationFactor)
            #expect(a <= first.maximumVariationFactor)
            #expect(a.isFinite)
            #expect(a > 0)
        }
    }

    @Test func variationContainsSmoothSlowAndFastEvents() {
        let model = WalkingSpeedModel(seed: 0)
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var largestTickChange = 0.0
        var previous = model.variationFactor(at: 0)

        for step in 1...1_200 {
            let factor = model.variationFactor(at: Double(step) * 0.1)
            minimum = min(minimum, factor)
            maximum = max(maximum, factor)
            largestTickChange = max(largestTickChange, abs(factor - previous))
            previous = factor
        }

        #expect(minimum < 0.9)
        #expect(maximum > 1.1)
        #expect(largestTickChange < 0.02)
    }

    @Test func eventEnvelopeReturnsTowardTheTarget() {
        let model = WalkingSpeedModel(
            normalVariationFraction: 0,
            eventAmplitudeRange: 0.18...0.18,
            eventCycleDuration: 22,
            eventDurationRange: 8...8,
            seed: 0
        )
        let samples = stride(from: 0.0, through: 22.0, by: 0.05)
            .map { model.variationFactor(at: $0) }
        let lowestIndex = samples.indices.min(by: { samples[$0] < samples[$1] }) ?? 0

        #expect(samples[lowestIndex] < 0.83)
        #expect(abs(samples.last! - 1) < 0.000_001)
    }

    @Test func multiplierChangeUsesReasonableAccelerationAndChangesEta() throws {
        let value = try route([point(0, 0), point(0, 0.02)])
        let model = WalkingSpeedModel(normalVariationFraction: 0, eventAmplitudeRange: 0...0, seed: 5)
        var engine = try RoutePlaybackEngine(route: value, speedModel: model)

        for _ in 0..<30 { engine.advance(by: 0.1) }
        let before = engine.metrics
        engine.setSpeedMultiplier(3)
        let etaAfterSetting = engine.metrics.estimatedRemainingTime
        let firstFasterTick = engine.advance(by: 0.1)

        #expect(etaAfterSetting < before.estimatedRemainingTime / 2)
        #expect(firstFasterTick.currentSpeed > before.currentSpeed)
        #expect(firstFasterTick.currentSpeed - before.currentSpeed <= model.maximumAcceleration * 0.1 + 0.000_001)
    }

    @Test func naturalVariationNeverCreatesCoordinateJumps() throws {
        let value = try route([point(0, 0), point(0, 0.02)])
        let model = WalkingSpeedModel(seed: 92)
        var engine = try RoutePlaybackEngine(route: value, speedModel: model, speedMultiplier: 3)
        var previous = engine.metrics

        for _ in 0..<1_200 where !engine.isComplete {
            let current = engine.advance(by: 0.1)
            let distanceStep = current.distanceTraveled - previous.distanceTraveled
            #expect(distanceStep >= 0)
            #expect(distanceStep <= model.targetSpeed(multiplier: 3) * model.maximumVariationFactor * 0.1 + 0.000_001)
            #expect(current.currentSpeed.isFinite)
            #expect(current.currentSpeed >= 0)
            previous = current
        }
    }

    @Test func completionIsExactAndEtaNeverInvalid() throws {
        let shortRoute = try route([point(0, 0), point(0, 0.00001)])
        var engine = try RoutePlaybackEngine(route: shortRoute)
        let initial = engine.metrics
        for _ in 0..<200 where !engine.isComplete { engine.advance(by: 0.25) }
        let completed = engine.metrics

        #expect(initial.estimatedRemainingTime.isFinite)
        #expect(initial.estimatedRemainingTime >= 0)
        #expect(completed.progress == 1)
        #expect(completed.distanceRemaining == 0)
        #expect(completed.estimatedRemainingTime == 0)
        #expect(completed.currentCoordinate == shortRoute.points.last)
        #expect(completed.currentSpeed == 0)
    }
}

struct PhoneLocalConnectionPolicyTests {
    @Test func cellularIsNeverRejectedAsAnInterfacePolicy() {
        #expect(PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: true,
            underlyingNetwork: .cellular
        ))
        #expect(PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: true,
            underlyingNetwork: .unavailable
        ))
    }

    @Test func reachableEndpointIsAcceptedRegardlessOfNetworkType() {
        for network in [UnderlyingNetworkKind.wifi, .cellular, .other, .unavailable, .unknown] {
            #expect(PhoneLocalConnectionPolicy.shouldAttemptConnection(
                pairingFilePresent: true,
                underlyingNetwork: network
            ))
            #expect(PhoneLocalConnectionPolicy.isReady(
                endpointReachability: .reachable,
                remotePairingConnected: true
            ))
        }
    }

    @Test func unreachableEndpointIsNotReportedReady() {
        #expect(!PhoneLocalConnectionPolicy.isReady(
            endpointReachability: .unreachable,
            remotePairingConnected: false
        ))
        #expect(!PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: false,
            underlyingNetwork: .wifi
        ))
    }

    @Test func warmSessionOutranksFreshEndpointFailureOnCellular() {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let lease = ownership.claim(.point)
        #expect(PhoneLocalConnectionPolicy.isReady(
            endpointReachability: .unreachable,
            remotePairingConnected: false,
            simulationSessionOpen: true
        ))
        #expect(PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: true,
            underlyingNetwork: .wifi
        ))
        #expect(PhoneLocalConnectionPolicy.shouldAttemptConnection(
            pairingFilePresent: true,
            underlyingNetwork: .cellular
        ))
        #expect(ownership.isCurrent(lease))
        #expect(ownership.isSessionOpen)
    }

    @Test func trueWarmSessionLossRestoresHonestNotReadyState() {
        #expect(!PhoneLocalConnectionPolicy.isReady(
            endpointReachability: .unreachable,
            remotePairingConnected: false,
            simulationSessionOpen: false
        ))
    }
}

private actor FakeRouteSink: RouteLocationSimulationSink {
    private let ownership: LocationSimulationOwnership
    private(set) var coordinates: [RoutePoint] = []
    private(set) var clearCount = 0
    private(set) var disconnectCount = 0
    private(set) var sessionWasOpenForCoordinate: [Bool] = []
    private var nextFailure: RoutePlaybackFailure?
    private var blockNextUpdate = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(ownership: LocationSimulationOwnership) {
        self.ownership = ownership
    }

    func setCoordinate(
        _ coordinate: RoutePoint,
        lease: LocationSimulationProducerLease
    ) async throws {
        guard ownership.isCurrent(lease) else {
            throw RoutePlaybackFailure(reason: .superseded, message: "superseded")
        }
        // Once an FFI call has begun it may land before a takeover. The new
        // producer is serialized after it and therefore supplies the final
        // coordinate; a command that had not begun is rejected by the guard.
        coordinates.append(coordinate)
        sessionWasOpenForCoordinate.append(ownership.isSessionOpen)
        // A simulated FFI result belongs to the call that began with it. Capture
        // before suspension so a re-entrant successor cannot consume the prior
        // producer's queued failure.
        let failure = nextFailure
        nextFailure = nil
        if blockNextUpdate {
            blockNextUpdate = false
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        guard ownership.isCurrent(lease) else {
            throw RoutePlaybackFailure(reason: .superseded, message: "superseded")
        }
        if let failure {
            throw failure
        }
    }

    func clear() async throws {
        clearCount += 1
    }

    func disconnect() async throws {
        disconnectCount += 1
        ownership.setSessionOpen(false)
    }

    func failNextUpdate(_ failure: RoutePlaybackFailure) {
        nextFailure = failure
    }

    func armBlockedUpdate() {
        blockNextUpdate = true
    }

    func isBlocked() -> Bool { blockedContinuation != nil }

    func releaseBlockedUpdate() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

@MainActor
private final class FakeRouteActivityManager: RoutePlaybackActivityManaging {
    private(set) var starts = 0
    private(set) var ends = 0
    private(set) var connectionMarkedUnavailable = false
    private var activeLease: LocationSimulationProducerLease?

    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        if activeLease == nil { starts += 1 }
        activeLease = lease
    }

    func simulationDidEnd(
        _ lease: LocationSimulationProducerLease,
        connectionUnavailable: Bool
    ) {
        guard activeLease == lease else { return }
        activeLease = nil
        ends += 1
        connectionMarkedUnavailable = connectionMarkedUnavailable || connectionUnavailable
    }
}

@MainActor
struct RoutePlaybackControllerTests {
    private func makeController(
        ownership: LocationSimulationOwnership = LocationSimulationOwnership()
    ) -> (
        RoutePlaybackController,
        FakeRouteSink,
        FakeRouteActivityManager,
        LocationSimulationOwnership
    ) {
        let sink = FakeRouteSink(ownership: ownership)
        let activity = FakeRouteActivityManager()
        return (
            RoutePlaybackController(
                sink: sink,
                activityManager: activity,
                automaticallySchedulesTicks: false,
                speedModel: WalkingSpeedModel(seed: 7),
                ownership: ownership
            ),
            sink,
            activity,
            ownership
        )
    }

    private func standardRoute(id: String = "route_controller") throws -> LocationRoute {
        try route([point(40, -79), point(40, -78.999)], id: id)
    }

    @Test func pauseFreezesAndResumeContinuesExactProgress() async throws {
        let (controller, _, _, _) = makeController()
        await controller.play(try standardRoute())
        await controller.advance(by: 1)
        controller.pause()
        let paused = try #require(controller.metrics)

        await controller.advance(by: 1)
        #expect(controller.state == .paused)
        #expect(controller.metrics == paused)
        #expect(paused.currentSpeed == 0)

        controller.resume()
        await controller.advance(by: 1)
        #expect(controller.state == .playing)
        #expect((controller.metrics?.distanceTraveled ?? 0) > paused.distanceTraveled)
    }

    @Test func stopRouteHoldsExactCoordinateWithoutClearing() async throws {
        let (controller, sink, activity, _) = makeController()
        await controller.play(try standardRoute())
        await controller.advance(by: 1)
        let beforeStop = try #require(controller.metrics)
        let stopped = await controller.stopRoute()

        #expect(stopped)
        #expect(controller.state == .stopped)
        #expect(controller.isSimulationActive)
        #expect(controller.metrics?.currentCoordinate == beforeStop.currentCoordinate)
        #expect(controller.metrics?.distanceTraveled == beforeStop.distanceTraveled)
        #expect(controller.metrics?.elapsedTime == beforeStop.elapsedTime)
        #expect(controller.metrics?.currentSpeed == 0)
        let clearCount = await sink.clearCount
        let lastCoordinate = await sink.coordinates.last
        #expect(clearCount == 0)
        #expect(lastCoordinate == beforeStop.currentCoordinate)
        #expect(activity.starts == 1)
        #expect(activity.ends == 0)
    }

    @Test func stoppedKeepAliveResendsOnlyHeldCoordinateAndNeverAdvances() async throws {
        let (controller, sink, _, _) = makeController()
        await controller.play(try standardRoute())
        await controller.advance(by: 1)
        _ = await controller.stopRoute()
        let stopped = try #require(controller.metrics)
        let countBeforeMaintenance = await sink.coordinates.count

        await controller.maintainHeldCoordinate()

        let coordinateCount = await sink.coordinates.count
        let lastCoordinate = await sink.coordinates.last
        #expect(controller.state == .stopped)
        #expect(controller.metrics == stopped)
        #expect(coordinateCount == countBeforeMaintenance + 1)
        #expect(lastCoordinate == stopped.currentCoordinate)
    }

    @Test func resumeFromStoppedContinuesFromExactProgress() async throws {
        let (controller, _, _, _) = makeController()
        await controller.play(try standardRoute())
        await controller.advance(by: 1)
        _ = await controller.stopRoute()
        let stopped = try #require(controller.metrics)

        controller.resume()
        await controller.advance(by: 1)

        #expect(controller.state == .playing)
        #expect((controller.metrics?.distanceTraveled ?? 0) > stopped.distanceTraveled)
        #expect((controller.metrics?.elapsedTime ?? 0) > stopped.elapsedTime)
    }

    @Test func replayAfterStoppedStartsAtRouteBeginningWithoutClear() async throws {
        let (controller, sink, activity, _) = makeController()
        let value = try standardRoute()
        await controller.play(value)
        await controller.advance(by: 1)
        _ = await controller.stopRoute()

        await controller.play(value)

        let clearCount = await sink.clearCount
        #expect(controller.state == .playing)
        #expect(controller.metrics?.distanceTraveled == 0)
        #expect(controller.metrics?.currentCoordinate == value.points.first)
        #expect(clearCount == 0)
        #expect(activity.starts == 1)
    }

    @Test func returnToRealLocationClearsFromPlayingPausedStoppedAndCompleted() async throws {
        for sourceState in 0..<4 {
            let (controller, sink, activity, _) = makeController()
            let value = sourceState == 3
                ? try route([point(0, 0), point(0, 0.00001)], id: "route_clear_complete")
                : try standardRoute(id: "route_clear_\(sourceState)")
            await controller.play(value)

            if sourceState == 1 {
                controller.pause()
            } else if sourceState == 2 {
                _ = await controller.stopRoute()
            } else if sourceState == 3 {
                for _ in 0..<200 where controller.state == .playing {
                    await controller.advance(by: 0.25)
                }
                #expect(controller.state == .completed)
            }

            let returned = await controller.returnToRealLocation()
            let clearCount = await sink.clearCount

            #expect(returned)
            #expect(controller.state == .ready)
            #expect(!controller.isSimulationActive)
            #expect(clearCount == 1)
            #expect(activity.ends == 1)
        }
    }

    @Test func stopWinsAgainstAnOlderInFlightTickAndRestoresExactHold() async throws {
        let (controller, sink, _, _) = makeController()
        await controller.play(try standardRoute())
        let committed = try #require(controller.metrics)
        await sink.armBlockedUpdate()

        let oldTick = Task { await controller.advance(by: 1) }
        while !(await sink.isBlocked()) { await Task.yield() }
        let stop = Task { await controller.stopRoute() }
        await Task.yield()
        await sink.releaseBlockedUpdate()
        await oldTick.value

        let stopped = await stop.value
        let lastCoordinate = await sink.coordinates.last
        let clearCount = await sink.clearCount
        #expect(stopped)
        #expect(controller.state == .stopped)
        #expect(controller.metrics?.currentCoordinate == committed.currentCoordinate)
        #expect(controller.metrics?.distanceTraveled == committed.distanceTraveled)
        #expect(lastCoordinate == committed.currentCoordinate)
        #expect(clearCount == 0)
    }

    @Test func staleTickCannotResurrectAfterReturnToRealLocation() async throws {
        let (controller, sink, _, _) = makeController()
        await controller.play(try standardRoute())
        await sink.armBlockedUpdate()

        let oldTick = Task { await controller.advance(by: 1) }
        while !(await sink.isBlocked()) { await Task.yield() }
        let clear = Task { await controller.returnToRealLocation() }
        await Task.yield()
        await sink.releaseBlockedUpdate()
        await oldTick.value
        let returned = await clear.value
        #expect(returned)
        let coordinateCountAfterClear = await sink.coordinates.count

        await controller.advance(by: 1)
        await controller.maintainHeldCoordinate()

        let clearCount = await sink.clearCount
        let finalCoordinateCount = await sink.coordinates.count
        #expect(clearCount == 1)
        #expect(finalCoordinateCount == coordinateCountAfterClear)
        #expect(!controller.isSimulationActive)
        #expect(controller.state == .ready)
    }

    @Test func connectionFailureFreezesProgressRetriesHoldAndRecoversPaused() async throws {
        let (controller, sink, activity, _) = makeController()
        await controller.play(try standardRoute())
        let committed = try #require(controller.metrics)
        await sink.failNextUpdate(RoutePlaybackFailure(
            reason: .tunnelUnavailable,
            message: "Reconnect LocalDevVPN before resuming."
        ))

        await controller.advance(by: 1)

        guard case .connectionInterrupted(let error) = controller.state else {
            Issue.record("Expected a connection-interrupted hold")
            return
        }
        #expect(error.reason == .tunnelUnavailable)
        #expect(controller.metrics?.distanceTraveled == committed.distanceTraveled)
        #expect(controller.metrics?.elapsedTime == committed.elapsedTime)
        #expect(controller.isSimulationActive)
        #expect(activity.ends == 0)
        let clearCountAfterFailure = await sink.clearCount
        #expect(clearCountAfterFailure == 0)

        await controller.maintainHeldCoordinate()
        let lastCoordinate = await sink.coordinates.last
        #expect(controller.state == .paused)
        #expect(controller.metrics?.currentCoordinate == committed.currentCoordinate)
        #expect(lastCoordinate == committed.currentCoordinate)
    }

    @Test func reconnectDoesNotCreateDuplicateMaintenanceUpdates() async throws {
        let (controller, sink, _, _) = makeController()
        await controller.play(try standardRoute())
        _ = await controller.stopRoute()
        let before = await sink.coordinates.count
        await sink.armBlockedUpdate()

        let first = Task { await controller.maintainHeldCoordinate() }
        while !(await sink.isBlocked()) { await Task.yield() }
        let duplicate = Task { await controller.maintainHeldCoordinate() }
        await duplicate.value
        await sink.releaseBlockedUpdate()
        await first.value

        let coordinateCount = await sink.coordinates.count
        #expect(coordinateCount == before + 1)
        #expect(controller.state == .stopped)
    }

    @Test func completedRouteKeepsDestinationUntilExplicitReturn() async throws {
        let (controller, sink, _, _) = makeController()
        let value = try route([point(0, 0), point(0, 0.00001)], id: "route_complete")
        await controller.play(value)
        for _ in 0..<200 where controller.state == .playing {
            await controller.advance(by: 0.25)
        }

        #expect(controller.state == .completed)
        #expect(controller.metrics?.currentCoordinate == value.points.last)
        #expect(controller.isSimulationActive)
        let clearCount = await sink.clearCount
        #expect(clearCount == 0)

        await controller.maintainHeldCoordinate()
        let lastCoordinate = await sink.coordinates.last
        #expect(lastCoordinate == value.points.last)
    }

    @Test func pointToRouteReusesOpenSessionWithoutClear() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let pointLease = ownership.claim(.point)
        let (controller, sink, _, _) = makeController(ownership: ownership)

        await controller.play(try standardRoute()) {
            _ = ownership.relinquish(pointLease)
        }

        #expect(controller.state == .playing)
        #expect(ownership.currentProducer == .route)
        #expect(ownership.isSessionOpen)
        let clearCount = await sink.clearCount
        let openObservations = await sink.sessionWasOpenForCoordinate
        #expect(clearCount == 0)
        #expect(openObservations == [true])
    }

    @Test func routeToPointRelinquishesWithoutClearOrClosingSession() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let (controller, sink, _, _) = makeController(ownership: ownership)
        await controller.play(try standardRoute())

        let pointLease = ownership.claim(.point)
        controller.relinquishWithoutClearing()

        #expect(ownership.isCurrent(pointLease))
        #expect(ownership.currentProducer == .point)
        #expect(ownership.isSessionOpen)
        let clearCount = await sink.clearCount
        #expect(clearCount == 0)
    }

    @Test func completedRouteStartsDifferentRouteWithoutClear() async throws {
        let (controller, sink, _, ownership) = makeController()
        ownership.setSessionOpen(true)
        let first = try route([point(0, 0), point(0, 0.00001)], id: "route_a")
        let second = try route([point(1, 1), point(1, 1.001)], id: "route_b")
        await controller.play(first)
        for _ in 0..<200 where controller.state == .playing {
            await controller.advance(by: 0.25)
        }
        #expect(controller.state == .completed)

        await controller.play(second)

        #expect(controller.state == .playing)
        #expect(controller.metrics?.currentCoordinate == second.points.first)
        #expect(ownership.isSessionOpen)
        let clearCount = await sink.clearCount
        #expect(clearCount == 0)
    }

    @Test func stoppedRouteStartsDifferentRouteWithoutClear() async throws {
        let (controller, sink, _, ownership) = makeController()
        ownership.setSessionOpen(true)
        await controller.play(try standardRoute(id: "route_a"))
        _ = await controller.stopRoute()

        let second = try route([point(2, 2), point(2, 2.001)], id: "route_b")
        await controller.play(second)

        #expect(controller.state == .playing)
        #expect(controller.metrics?.currentCoordinate == second.points.first)
        #expect(ownership.isSessionOpen)
        let clearCount = await sink.clearCount
        #expect(clearCount == 0)
    }

    @Test func queuedPointTickCannotOverwriteRouteAfterTakeover() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let pointLease = ownership.claim(.point)
        let (controller, sink, _, _) = makeController(ownership: ownership)
        let oldPoint = try point(10, 10)
        await sink.armBlockedUpdate()
        let pointTick = Task {
            try? await sink.setCoordinate(oldPoint, lease: pointLease)
        }
        while !(await sink.isBlocked()) { await Task.yield() }

        await controller.play(try standardRoute())
        await sink.releaseBlockedUpdate()
        await pointTick.value

        let lastCoordinate = await sink.coordinates.last
        let clearCount = await sink.clearCount
        #expect(lastCoordinate == controller.metrics?.currentCoordinate)
        #expect(lastCoordinate != oldPoint)
        #expect(clearCount == 0)
    }

    @Test func queuedRouteTickCannotOverwritePointAfterTakeover() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let (controller, sink, activity, _) = makeController(ownership: ownership)
        await controller.play(try standardRoute())
        await sink.failNextUpdate(RoutePlaybackFailure(
            reason: .tunnelUnavailable,
            message: "stale route failure"
        ))
        await sink.armBlockedUpdate()
        let routeTick = Task { await controller.advance(by: 1) }
        while !(await sink.isBlocked()) { await Task.yield() }

        let pointLease = ownership.claim(.point)
        controller.relinquishWithoutClearing()
        let newPoint = try point(20, 20)
        try await sink.setCoordinate(newPoint, lease: pointLease)
        await sink.releaseBlockedUpdate()
        await routeTick.value

        let lastCoordinate = await sink.coordinates.last
        let clearCount = await sink.clearCount
        #expect(lastCoordinate == newPoint)
        #expect(!activity.connectionMarkedUnavailable)
        #expect(clearCount == 0)
    }

    @Test func explicitReturnClearsButPreservesWarmSession() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let (controller, sink, _, _) = makeController(ownership: ownership)
        await controller.play(try standardRoute())
        controller.pause()

        let countBeforeReturn = await sink.clearCount
        let returned = await controller.returnToRealLocation()
        let countAfterReturn = await sink.clearCount
        #expect(countBeforeReturn == 0)
        #expect(returned)
        #expect(ownership.isSessionOpen)
        #expect(countAfterReturn == 1)

        await controller.play(try standardRoute(id: "route_after_return"))
        #expect(controller.state == .playing)
        #expect(ownership.isSessionOpen)
    }

    @Test func returnFromPointInvalidatesProducerAndClearsExactlyOnce() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let pointLease = ownership.claim(.point)
        let sink = FakeRouteSink(ownership: ownership)

        let returnedLease = ownership.invalidateAll()
        try await sink.clear()

        let clearCount = await sink.clearCount
        #expect(returnedLease == pointLease)
        #expect(ownership.currentProducer == .none)
        #expect(ownership.isSessionOpen)
        #expect(clearCount == 1)
    }

    @Test func disconnectSessionFullyTearsDownAndRetiresProducer() async throws {
        let ownership = LocationSimulationOwnership()
        ownership.setSessionOpen(true)
        let (controller, sink, activity, _) = makeController(ownership: ownership)
        await controller.play(try standardRoute())

        let disconnected = await controller.disconnectSession()

        #expect(disconnected)
        #expect(!ownership.isSessionOpen)
        #expect(ownership.currentProducer == .none)
        #expect(!controller.isSimulationActive)
        #expect(activity.ends == 1)
        let disconnectCount = await sink.disconnectCount
        #expect(disconnectCount == 1)
    }
}

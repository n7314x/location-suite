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
}

struct WalkingPlaybackEngineTests {
    @Test func naturalWalkingRampsUpAndDeceleratesNearDestination() {
        let model = WalkingSpeedModel.natural
        let early = model.speed(elapsedTime: 0.5, distanceRemaining: 100)
        let cruise = model.speed(elapsedTime: 5, distanceRemaining: 100)
        let nearFinish = model.speed(elapsedTime: 5, distanceRemaining: 1)

        #expect(early > 0)
        #expect(early < cruise)
        #expect(cruise > 1.2 && cruise < 1.6)
        #expect(nearFinish < cruise)
        #expect(nearFinish > 0)
    }

    @Test func completionIsExactAndEtaNeverInvalid() throws {
        let shortRoute = try route([point(0, 0), point(0, 0.00001)])
        var engine = try RoutePlaybackEngine(route: shortRoute)
        let initial = engine.metrics
        let completed = engine.advance(by: 100)

        #expect(initial.estimatedRemainingTime.isFinite)
        #expect(initial.estimatedRemainingTime >= 0)
        #expect(completed.progress == 1)
        #expect(completed.distanceRemaining == 0)
        #expect(completed.estimatedRemainingTime == 0)
        #expect(completed.currentCoordinate == shortRoute.points.last)
        #expect(completed.currentSpeed == 0)
    }
}

private actor FakeRouteSink: RouteLocationSimulationSink {
    private(set) var coordinates: [RoutePoint] = []
    private(set) var clearCount = 0
    private var nextFailure: RoutePlaybackFailure?
    private var blockNextUpdate = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func setCoordinate(_ coordinate: RoutePoint) async throws {
        coordinates.append(coordinate)
        if blockNextUpdate {
            blockNextUpdate = false
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        if let failure = nextFailure {
            nextFailure = nil
            throw failure
        }
    }

    func clear() async throws {
        clearCount += 1
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

    func simulationDidStart() {
        starts += 1
    }

    func simulationDidEnd(connectionUnavailable: Bool) {
        ends += 1
        connectionMarkedUnavailable = connectionMarkedUnavailable || connectionUnavailable
    }
}

@MainActor
struct RoutePlaybackControllerTests {
    private func makeController() -> (RoutePlaybackController, FakeRouteSink, FakeRouteActivityManager) {
        let sink = FakeRouteSink()
        let activity = FakeRouteActivityManager()
        return (
            RoutePlaybackController(
                sink: sink,
                activityManager: activity,
                automaticallySchedulesTicks: false
            ),
            sink,
            activity
        )
    }

    private func standardRoute(id: String = "route_controller") throws -> LocationRoute {
        try route([point(40, -79), point(40, -78.999)], id: id)
    }

    @Test func pauseFreezesAndResumeContinuesExactProgress() async throws {
        let (controller, _, _) = makeController()
        let value = try standardRoute()
        await controller.play(value)
        await controller.advance(by: 1)
        let beforePause = try #require(controller.metrics)

        controller.pause()
        await controller.advance(by: 1)
        #expect(controller.state == .paused)
        #expect(controller.metrics == beforePause)

        controller.resume()
        await controller.advance(by: 1)
        #expect(controller.state == .playing)
        #expect((controller.metrics?.distanceTraveled ?? 0) > beforePause.distanceTraveled)
    }

    @Test func stopClearsAndResetsToReady() async throws {
        let (controller, sink, activity) = makeController()
        await controller.play(try standardRoute())
        let stopped = await controller.stop()

        #expect(stopped)
        #expect(controller.state == .ready)
        #expect(!controller.isSimulationActive)
        let clearCount = await sink.clearCount
        #expect(clearCount == 1)
        #expect(activity.starts == 1)
        #expect(activity.ends == 1)
    }

    @Test func completionHoldsDestinationUntilExplicitStop() async throws {
        let (controller, sink, _) = makeController()
        let value = try route([point(0, 0), point(0, 0.00001)], id: "route_complete")
        await controller.play(value)
        for _ in 0..<20 where controller.state == .playing {
            await controller.advance(by: 1)
        }

        #expect(controller.state == .completed)
        #expect(controller.metrics?.progress == 1)
        #expect(controller.metrics?.currentCoordinate == value.points.last)
        #expect(controller.isSimulationActive)
        let clearCountBeforeStop = await sink.clearCount
        #expect(clearCountBeforeStop == 0)

        let stopped = await controller.stop()
        let clearCountAfterStop = await sink.clearCount
        #expect(stopped)
        #expect(clearCountAfterStop == 1)
    }

    @Test func updateFailureStopsAdvancementAndEntersReadableError() async throws {
        let (controller, sink, activity) = makeController()
        await controller.play(try standardRoute())
        await sink.failNextUpdate(
            RoutePlaybackFailure(
                reason: .tunnelUnavailable,
                message: "Reconnect LocalDevVPN before playing again."
            )
        )
        await controller.advance(by: 1)

        guard case .error(let error) = controller.state else {
            Issue.record("Expected route playback error")
            return
        }
        #expect(error.reason == .tunnelUnavailable)
        #expect(error.message.contains("LocalDevVPN"))
        #expect(!controller.isSimulationActive)
        #expect(activity.connectionMarkedUnavailable)
    }

    @Test func stopWinsAgainstAnOlderInFlightUpdate() async throws {
        let (controller, sink, _) = makeController()
        await controller.play(try standardRoute())
        await sink.armBlockedUpdate()

        let oldUpdate = Task { await controller.advance(by: 1) }
        while !(await sink.isBlocked()) { await Task.yield() }
        let stop = Task { await controller.stop() }
        await Task.yield()
        await sink.releaseBlockedUpdate()
        await oldUpdate.value

        let stopped = await stop.value
        let clearCount = await sink.clearCount
        #expect(stopped)
        #expect(controller.state == .ready)
        #expect(!controller.isSimulationActive)
        #expect(clearCount == 1)
    }

    @Test func repeatedPlayStopCyclesHaveOneAuthoritativeLifecycle() async throws {
        let (controller, sink, activity) = makeController()
        let value = try standardRoute()

        for _ in 0..<3 {
            await controller.play(value)
            #expect(controller.state == .playing)
            let stopped = await controller.stop()
            #expect(stopped)
            #expect(controller.state == .ready)
        }

        let clearCount = await sink.clearCount
        #expect(clearCount == 3)
        #expect(activity.starts == 3)
        #expect(activity.ends == 3)
    }

    @Test func aNewRouteCanReplaceACompletedRouteWithoutClearingFirst() async throws {
        let (controller, sink, activity) = makeController()
        let first = try route([point(0, 0), point(0, 0.00001)], id: "route_first")
        let second = try route([point(1, 1), point(1, 1.001)], id: "route_second")

        await controller.play(first)
        for _ in 0..<20 where controller.state == .playing {
            await controller.advance(by: 1)
        }
        #expect(controller.state == .completed)

        await controller.play(second)
        #expect(controller.state == .playing)
        #expect(controller.route?.id == second.id)
        #expect(controller.metrics?.currentCoordinate == second.points.first)
        let clearCount = await sink.clearCount
        #expect(clearCount == 0)
        #expect(activity.starts == 1)
    }
}

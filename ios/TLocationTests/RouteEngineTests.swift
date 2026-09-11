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

struct RouteDocumentTests {
    private func document(
        id: String = "route_document",
        mode: RouteMovementMode = .walking,
        speed: Double = 1,
        resolved: Bool = true
    ) throws -> LocationRouteDocument {
        let anchors = [try point(40, -79), try point(40.001, -78.999)]
        let geometry = resolved
            ? try ResolvedRouteGeometry(
                points: [anchors[0], try point(40.0005, -78.9997), anchors[1]],
                expectedTravelTime: 90
            )
            : nil
        return try LocationRouteDocument(
            id: id,
            name: "Test Route",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_100),
            movementMode: mode,
            anchors: anchors,
            resolvedGeometry: geometry,
            defaultSpeedMultiplier: speed,
            source: RouteDocumentSourceMetadata(client: "ios")
        )
    }

    @Test func codableRoundTripPreservesGeometryModeSpeedAndVersion() throws {
        let value = try document(mode: .cycling, speed: 1.5)
        let data = try RouteDocumentCodec.encode(value)
        let decoded = try RouteDocumentCodec.decode(data)

        #expect(decoded == value)
        #expect(decoded.version == 1)
        #expect(decoded.movementMode == .cycling)
        #expect(decoded.defaultSpeedMultiplier == 1.5)
        #expect(decoded.resolvedGeometry?.points.count == 3)
        #expect(String(decoding: data, as: UTF8.self).contains("\n"))
    }

    @Test func malformedAndFutureDocumentsAreRejected() throws {
        #expect(throws: RouteDocumentError.malformedJSON) {
            try RouteDocumentCodec.decode(Data("not json".utf8))
        }
        let current = try document()
        var object = try #require(
            JSONSerialization.jsonObject(with: RouteDocumentCodec.encode(current)) as? [String: Any]
        )
        object["version"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RouteValidationError.unsupportedVersion(99)) {
            try RouteDocumentCodec.decode(future)
        }
    }

    @Test func reverseUpdatesAnchorsGeometryAndMetrics() throws {
        let value = try document()
        let reversed = try value.reversed(now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(reversed.anchors == Array(value.anchors.reversed()))
        #expect(reversed.resolvedGeometry?.points == value.resolvedGeometry.map { Array($0.points.reversed()) })
        #expect(reversed.distance == value.distance)
        #expect(reversed.modifiedAt > value.modifiedAt)
    }
}

struct RouteDocumentStoreTests {
    private func makeStore() -> RouteDocumentStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("location-suite-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("routes.json")
        return RouteDocumentStore(fileURL: url)
    }

    private func document(id: String, name: String = "Stored") throws -> LocationRouteDocument {
        try LocationRouteDocument(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            movementMode: .driving,
            anchors: [point(1, 1), point(1.01, 1.01)],
            resolvedGeometry: ResolvedRouteGeometry(
                points: [point(1, 1), point(1.005, 1.004), point(1.01, 1.01)]
            ),
            defaultSpeedMultiplier: 0.5
        )
    }

    @Test func saveLoadRenameDuplicateDeleteAndAtomicReplacement() async throws {
        let store = makeStore()
        let first = try document(id: "route_store_a")
        try await store.save(first)
        #expect(try await store.load() == [first])

        let renamed = try await store.rename(
            id: first.id,
            to: "Renamed",
            now: Date(timeIntervalSince1970: 1_800_000_200)
        )
        #expect(renamed.name == "Renamed")
        #expect(renamed.movementMode == .driving)
        #expect(renamed.defaultSpeedMultiplier == 0.5)
        #expect(renamed.resolvedGeometry != nil)

        let copy = try await store.duplicate(
            id: first.id,
            now: Date(timeIntervalSince1970: 1_800_000_300)
        )
        #expect(copy.id != first.id)
        #expect(copy.source?.originalIdentifier == first.id)
        #expect(try await store.load().count == 2)

        try await store.delete(id: copy.id)
        #expect(try await store.load() == [renamed])

        let replacement = try document(id: "route_store_b", name: "Replacement")
        try await store.replaceAll([replacement])
        #expect(try await store.load() == [replacement])
    }

    @Test func migratesLegacyTopLevelArrayIntoVersionedEnvelope() async throws {
        let store = makeStore()
        let value = try document(id: "route_legacy")
        let url = await store.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try RouteDocumentCodec.makeEncoder().encode([value]).write(to: url, options: .atomic)

        #expect(try await store.load() == [value])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        #expect((object["routes"] as? [Any])?.count == 1)
    }
}

private enum FakeDirectionsFailure: Error { case unavailable }

private actor FakeDirectionsProvider: RouteDirectionsProviding {
    private var segments: [Result<RouteDirectionsSegment, FakeDirectionsFailure>]

    init(_ segments: [Result<RouteDirectionsSegment, FakeDirectionsFailure>]) {
        self.segments = segments
    }

    func route(
        from start: RoutePoint,
        to end: RoutePoint,
        mode: RouteMovementMode
    ) async throws -> RouteDirectionsSegment {
        guard !segments.isEmpty else { throw FakeDirectionsFailure.unavailable }
        return try segments.removeFirst().get()
    }
}

private actor BlockingDirectionsProvider: RouteDirectionsProviding {
    private var continuation: CheckedContinuation<RouteDirectionsSegment, Never>?
    private var blocked = false

    func route(
        from start: RoutePoint,
        to end: RoutePoint,
        mode: RouteMovementMode
    ) async throws -> RouteDirectionsSegment {
        blocked = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func isBlocked() -> Bool { blocked }

    func release(_ segment: RouteDirectionsSegment) {
        continuation?.resume(returning: segment)
        continuation = nil
    }
}

struct RouteDirectionsTests {
    @Test func assemblesMultiAnchorRouteWithoutDuplicateBoundaries() async throws {
        let a = try point(0, 0)
        let b = try point(0, 0.001)
        let c = try point(0.001, 0.001)
        let provider = FakeDirectionsProvider([
            .success(RouteDirectionsSegment(points: [a, b], expectedTravelTime: 10)),
            .success(RouteDirectionsSegment(points: [b, c], expectedTravelTime: 20))
        ])
        let resolved = try await RouteDirectionsResolver().resolve(
            anchors: [a, b, c],
            mode: .walking,
            provider: provider
        )
        #expect(resolved.points == [a, b, c])
        #expect(resolved.expectedTravelTime == 30)
        #expect(resolved.distance > 200)
    }

    @Test func partialSegmentFailureIsReported() async throws {
        let a = try point(0, 0)
        let b = try point(0, 0.001)
        let c = try point(0.001, 0.001)
        let provider = FakeDirectionsProvider([
            .success(RouteDirectionsSegment(points: [a, b])),
            .failure(.unavailable)
        ])
        do {
            _ = try await RouteDirectionsResolver().resolve(
                anchors: [a, b, c],
                mode: .walking,
                provider: provider
            )
            Issue.record("Expected the second segment to fail")
        } catch let error as RouteDirectionsError {
            guard case .segmentFailed(let index, _) = error else {
                Issue.record("Expected a segment failure")
                return
            }
            #expect(index == 1)
        }
    }

    @Test func cancellationAndStaleResultAreIgnored() async throws {
        let a = try point(0, 0)
        let b = try point(0, 0.001)
        let segment = RouteDirectionsSegment(points: [a, b])

        let cancellationProvider = BlockingDirectionsProvider()
        let cancelled = Task {
            try await RouteDirectionsResolver().resolve(
                anchors: [a, b], mode: .walking, provider: cancellationProvider
            )
        }
        while !(await cancellationProvider.isBlocked()) { await Task.yield() }
        cancelled.cancel()
        await cancellationProvider.release(segment)
        do {
            _ = try await cancelled.value
            Issue.record("Expected cancellation")
        } catch let error as RouteDirectionsError {
            #expect(error == .cancelled)
        }

        let coordinator = RouteDirectionsCoordinator()
        let staleProvider = BlockingDirectionsProvider()
        let stale = Task {
            try await coordinator.resolve(anchors: [a, b], mode: .walking, provider: staleProvider)
        }
        while !(await staleProvider.isBlocked()) { await Task.yield() }
        await coordinator.cancel()
        await staleProvider.release(segment)
        do {
            _ = try await stale.value
            Issue.record("Expected stale result rejection")
        } catch let error as RouteDirectionsError {
            #expect(error == .superseded)
        }
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

struct MovementProfileTests {
    @Test func allModeProfilesStayFiniteBoundedAndSane() throws {
        for mode in RouteMovementMode.allCases {
            let profile = MovementProfile.profile(for: mode, seed: 44)
            #expect(profile.cruisingSpeed > 0)
            #expect(profile.maximumReasonableSpeed >= profile.cruisingSpeed)
            #expect(profile.maximumAcceleration > 0)
            #expect(profile.maximumDeceleration > 0)
            #expect(profile.clampedMultiplier(-10) == profile.multiplierRange.lowerBound)
            #expect(profile.clampedMultiplier(100) == profile.multiplierRange.upperBound)
            #expect(profile.clampedMultiplier(.nan) == 1)

            for step in 0...1_000 {
                let factor = profile.variationFactor(at: Double(step) * 0.1)
                let desired = profile.desiredSpeed(
                    elapsedTime: Double(step) * 0.1,
                    distanceRemaining: 1_000,
                    multiplier: profile.multiplierRange.upperBound
                )
                #expect(factor.isFinite)
                #expect(factor >= profile.minimumVariationFactor)
                #expect(factor <= profile.maximumVariationFactor)
                #expect(desired.isFinite)
                #expect(desired >= 0)
                #expect(desired <= profile.maximumReasonableSpeed)
            }
        }
    }

    @Test func cyclingAndDrivingAccelerateSmoothlyAndCompleteExactly() throws {
        for mode in [RouteMovementMode.cycling, .driving] {
            let value = try LocationRoute(
                id: "route_\(mode.rawValue)",
                mode: mode,
                points: [point(0, 0), point(0, 0.001)]
            )
            var engine = try RoutePlaybackEngine(route: value)
            let profile = engine.speedModel
            var prior = engine.metrics
            for _ in 0..<10_000 where !engine.isComplete {
                let next = engine.advance(by: 0.1)
                #expect(next.currentSpeed >= 0)
                #expect(next.currentSpeed.isFinite)
                #expect(next.distanceTraveled >= prior.distanceTraveled)
                #expect(next.distanceTraveled - prior.distanceTraveled <= profile.maximumReasonableSpeed * 0.1 + 0.001)
                #expect(next.currentSpeed - prior.currentSpeed <= profile.maximumAcceleration * 0.1 + 0.000_001)
                prior = next
            }
            #expect(engine.isComplete)
            #expect(engine.metrics.progress == 1)
            #expect(engine.metrics.currentCoordinate == value.points.last)
            #expect(engine.metrics.estimatedRemainingTime == 0)
        }
    }

    @Test func infiniteLoopPingPongsWithoutEndpointTeleport() throws {
        let value = try route([point(0, 0), point(0, 0.00001)], id: "route_loop")
        var engine = try RoutePlaybackEngine(
            route: value,
            options: RoutePlaybackOptions(loopMode: .infinite)
        )
        var positions: [RoutePoint] = [engine.metrics.currentCoordinate]
        for _ in 0..<400 where engine.metrics.completedPasses < 2 {
            positions.append(engine.advance(by: 0.25).currentCoordinate)
        }

        #expect(engine.metrics.completedPasses >= 2)
        #expect(!engine.isComplete)
        for pair in zip(positions, positions.dropFirst()) {
            #expect(RouteGeometry.distance(from: pair.0, to: pair.1) < 1)
        }
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
    private var disconnectGeneration: UInt64 = 0

    func simulationDidTakeOwnership(_ lease: LocationSimulationProducerLease) {
        if activeLease == nil { starts += 1 }
        activeLease = lease
    }

    func simulationDidEnd(
        _ lease: LocationSimulationProducerLease,
        reason: LocationSimulationProducerEndReason
    ) {
        guard activeLease == lease else { return }
        activeLease = nil
        ends += 1
        if case .failure(connectionUnavailable: true) = reason {
            connectionMarkedUnavailable = true
        }
    }

    func simulationSessionWillDisconnect() -> LocationSimulationDisconnectLease {
        disconnectGeneration &+= 1
        if activeLease != nil {
            activeLease = nil
            ends += 1
        }
        return LocationSimulationDisconnectLease(generation: disconnectGeneration)
    }

    func simulationSessionDidDisconnect(_ lease: LocationSimulationDisconnectLease) {
    }
}

private final class FakeSessionStatus: LocationSimulationSessionStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var active = false

    var isSessionOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    var isSimulationActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func set(open: Bool? = nil, active: Bool? = nil) {
        lock.lock()
        if let open { self.open = open }
        if let active { self.active = active }
        lock.unlock()
    }
}

private final class FakeWarmHeartbeatDriver: WarmLocationSimulationHeartbeatPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private let status: FakeSessionStatus
    private var completions: [@Sendable (WarmLocationSimulationHeartbeatResult) -> Void] = []
    private var heartbeatCalls = 0
    private var cleanupCalls = 0

    init(status: FakeSessionStatus) {
        self.status = status
    }

    func performHeartbeat(
        for lease: LocationSimulationIdleLease,
        completion: @escaping @Sendable (WarmLocationSimulationHeartbeatResult) -> Void
    ) {
        lock.lock()
        heartbeatCalls += 1
        completions.append(completion)
        lock.unlock()
    }

    func discardStaleSession(
        for lease: LocationSimulationIdleLease,
        reason: String,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        cleanupCalls += 1
        lock.unlock()
        status.set(open: false, active: false)
        completion(true)
    }

    func completeNext(_ result: WarmLocationSimulationHeartbeatResult) {
        lock.lock()
        let completion = completions.isEmpty ? nil : completions.removeFirst()
        lock.unlock()
        completion?(result)
    }

    var performCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return heartbeatCalls
    }

    var cleanupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanupCalls
    }
}

@MainActor
private final class FakeWarmHeartbeatCancellation: WarmLocationSimulationHeartbeatCancellation {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

@MainActor
private final class FakeWarmHeartbeatScheduler: WarmLocationSimulationHeartbeatScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancellationCount = 0

    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> WarmLocationSimulationHeartbeatCancellation {
        scheduleCount += 1
        self.action = action
        return FakeWarmHeartbeatCancellation { [weak self] in
            self?.cancellationCount += 1
            self?.action = nil
        }
    }

    func fire() {
        action?()
    }
}

@MainActor
private final class FakeBackgroundActivity: LocationSimulationBackgroundActivityManaging {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var balance = 0

    func requestStart() {
        startCount += 1
        balance += 1
    }

    func requestStop() {
        stopCount += 1
        balance -= 1
    }
}

@MainActor
struct LocationSimulationSessionKeeperTests {
    private typealias Harness = (
        keeper: LocationSimulationSessionKeeper,
        ownership: LocationSimulationOwnership,
        status: FakeSessionStatus,
        driver: FakeWarmHeartbeatDriver,
        scheduler: FakeWarmHeartbeatScheduler,
        activity: FakeBackgroundActivity
    )

    private func makeHarness() -> Harness {
        let ownership = LocationSimulationOwnership()
        let status = FakeSessionStatus()
        let driver = FakeWarmHeartbeatDriver(status: status)
        let scheduler = FakeWarmHeartbeatScheduler()
        let activity = FakeBackgroundActivity()
        let keeper = LocationSimulationSessionKeeper(
            ownership: ownership,
            status: status,
            heartbeat: driver,
            scheduler: scheduler,
            backgroundActivity: activity
        )
        return (keeper, ownership, status, driver, scheduler, activity)
    }

    private func beginProducer(
        _ producer: LocationSimulationProducer,
        in harness: Harness
    ) -> LocationSimulationProducerLease {
        let lease = harness.ownership.claim(producer)
        harness.status.set(open: true, active: true)
        harness.keeper.producerDidTakeOwnership(lease)
        return lease
    }

    private func returnToIdle(
        _ lease: LocationSimulationProducerLease,
        in harness: Harness
    ) {
        harness.ownership.invalidateAll()
        harness.status.set(open: true, active: false)
        harness.keeper.producerDidEnd(lease, reason: .returnedToRealGPS)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }

    @Test func returnLeavesSessionOpenAndStartsIdleKeeperWithoutClaimingProducer() {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)

        returnToIdle(point, in: harness)

        #expect(harness.status.isSessionOpen)
        #expect(!harness.status.isSimulationActive)
        #expect(harness.ownership.currentProducer == .none)
        #expect(harness.keeper.state == .idleWarm)
        #expect(harness.keeper.isIdleKeeperActive)
        #expect(harness.scheduler.scheduleCount == 1)
        #expect(harness.activity.balance == 1)
    }

    @Test func pointAcquisitionPausesIdleHeartbeat() {
        let harness = makeHarness()
        let firstPoint = beginProducer(.point, in: harness)
        returnToIdle(firstPoint, in: harness)

        let nextPoint = harness.ownership.claim(.point)
        harness.status.set(active: true)
        harness.keeper.producerDidTakeOwnership(nextPoint)
        harness.scheduler.fire()

        #expect(harness.keeper.state == .activePoint)
        #expect(harness.driver.performCount == 0)
        #expect(harness.activity.balance == 1)
    }

    @Test func routeAcquisitionPausesIdleHeartbeat() {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        returnToIdle(point, in: harness)

        let route = harness.ownership.claim(.route)
        harness.status.set(active: true)
        harness.keeper.producerDidTakeOwnership(route)
        harness.scheduler.fire()

        #expect(harness.keeper.state == .activeRoute)
        #expect(harness.driver.performCount == 0)
        #expect(harness.activity.balance == 1)
    }

    @Test func returningFromPointAndRouteResumesIdleKeeper() {
        for producer in [LocationSimulationProducer.point, .route] {
            let harness = makeHarness()
            let lease = beginProducer(producer, in: harness)

            returnToIdle(lease, in: harness)

            #expect(harness.keeper.state == .idleWarm)
            #expect(harness.scheduler.scheduleCount == 1)
            #expect(harness.activity.balance == 1)
        }
    }

    @Test func disconnectStopsKeeperAndClosesSession() {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        returnToIdle(point, in: harness)

        let disconnect = harness.keeper.sessionWillDisconnect()
        harness.ownership.invalidateAll()
        harness.status.set(open: false, active: false)
        harness.keeper.sessionDidDisconnect(disconnect)
        harness.scheduler.fire()

        #expect(harness.keeper.state == .disconnected)
        #expect(!harness.keeper.isIdleKeeperActive)
        #expect(!harness.status.isSessionOpen)
        #expect(harness.ownership.currentProducer == .none)
        #expect(harness.driver.performCount == 0)
        #expect(harness.activity.balance == 0)
        #expect(harness.activity.startCount == harness.activity.stopCount)
    }

    @Test func oneHeartbeatFailureDoesNotCloseSession() async {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        returnToIdle(point, in: harness)

        harness.scheduler.fire()
        harness.driver.completeNext(.failed("transient"))
        await settle()

        #expect(harness.status.isSessionOpen)
        #expect(harness.keeper.state == .idleWarm)
        #expect(harness.keeper.consecutiveHeartbeatFailures == 1)
        #expect(harness.keeper.heartbeatFailureCount == 1)
        #expect(harness.driver.cleanupCount == 0)
    }

    @Test func thresholdFailuresCleanStaleSessionExactlyOnce() async {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        returnToIdle(point, in: harness)

        for failure in 1...LocationSimulationSessionKeeper.heartbeatFailureThreshold {
            harness.scheduler.fire()
            harness.driver.completeNext(.failed("failure \(failure)"))
            await settle()
        }
        harness.scheduler.fire()
        await settle()

        #expect(!harness.status.isSessionOpen)
        #expect(harness.keeper.state == .disconnected)
        #expect(harness.driver.cleanupCount == 1)
        #expect(harness.activity.balance == 0)
    }

    @Test func successfulHeartbeatResetsFailureStreak() async {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        returnToIdle(point, in: harness)

        harness.scheduler.fire()
        harness.driver.completeNext(.failed("transient"))
        await settle()
        let heartbeatDate = Date(timeIntervalSince1970: 1_800_000_000)
        harness.scheduler.fire()
        harness.driver.completeNext(.succeeded(heartbeatDate))
        await settle()

        #expect(harness.keeper.consecutiveHeartbeatFailures == 0)
        #expect(harness.keeper.heartbeatFailureCount == 1)
        #expect(harness.keeper.lastHeartbeat == heartbeatDate)
        #expect(harness.driver.cleanupCount == 0)
    }

    @Test func staleHeartbeatCompletionAfterProducerTakeoverCannotCleanSession() async {
        let harness = makeHarness()
        let firstPoint = beginProducer(.point, in: harness)
        returnToIdle(firstPoint, in: harness)

        for _ in 0..<(LocationSimulationSessionKeeper.heartbeatFailureThreshold - 1) {
            harness.scheduler.fire()
            harness.driver.completeNext(.failed("earlier failure"))
            await settle()
        }
        harness.scheduler.fire()

        let route = harness.ownership.claim(.route)
        harness.status.set(active: true)
        harness.keeper.producerDidTakeOwnership(route)
        harness.driver.completeNext(.failed("late failure"))
        await settle()

        #expect(harness.keeper.state == .activeRoute)
        #expect(harness.ownership.isCurrent(route))
        #expect(harness.driver.cleanupCount == 0)
        #expect(
            harness.keeper.heartbeatFailureCount ==
                LocationSimulationSessionKeeper.heartbeatFailureThreshold - 1
        )
    }

    @Test func repeatedPointReturnCyclesDoNotLeakBackgroundActivity() {
        let harness = makeHarness()
        let first = beginProducer(.point, in: harness)
        returnToIdle(first, in: harness)

        let second = harness.ownership.claim(.point)
        harness.status.set(active: true)
        harness.keeper.producerDidTakeOwnership(second)
        returnToIdle(second, in: harness)

        let disconnect = harness.keeper.sessionWillDisconnect()
        harness.status.set(open: false, active: false)
        harness.keeper.sessionDidDisconnect(disconnect)

        #expect(harness.activity.startCount == 1)
        #expect(harness.activity.stopCount == 1)
        #expect(harness.activity.balance == 0)
    }

    @Test func routeReturnRouteReusesOpenSession() {
        let harness = makeHarness()
        let first = beginProducer(.route, in: harness)
        returnToIdle(first, in: harness)

        let second = harness.ownership.claim(.route)
        harness.status.set(active: true)
        harness.keeper.producerDidTakeOwnership(second)

        #expect(harness.status.isSessionOpen)
        #expect(harness.keeper.state == .activeRoute)
        #expect(harness.ownership.isCurrent(second))
        #expect(harness.activity.startCount == 1)
    }

    @Test func pointRoutePointHandoffsKeepOneActivityAndCurrentLease() {
        let harness = makeHarness()
        let point = beginProducer(.point, in: harness)
        let route = harness.ownership.claim(.route)
        harness.keeper.producerDidTakeOwnership(route)
        harness.keeper.producerDidEnd(point, reason: .relinquished)
        let finalPoint = harness.ownership.claim(.point)
        harness.keeper.producerDidTakeOwnership(finalPoint)
        harness.keeper.producerDidEnd(route, reason: .relinquished)

        #expect(harness.keeper.state == .activePoint)
        #expect(harness.ownership.isCurrent(finalPoint))
        #expect(harness.activity.startCount == 1)
        #expect(harness.activity.stopCount == 0)
        #expect(harness.activity.balance == 1)
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

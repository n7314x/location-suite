//
//  RouteDirections.swift
//  TLocation
//
//  Platform-neutral directions assembly. MapKit is an adapter in Services.
//

import Foundation

struct RouteDirectionsSegment: Equatable, Sendable {
    let points: [RoutePoint]
    let expectedTravelTime: TimeInterval?

    init(points: [RoutePoint], expectedTravelTime: TimeInterval? = nil) {
        self.points = points
        self.expectedTravelTime = expectedTravelTime
    }
}

struct ResolvedDirections: Equatable, Sendable {
    let points: [RoutePoint]
    let distance: Double
    let expectedTravelTime: TimeInterval?
}

protocol RouteDirectionsProviding: Sendable {
    func route(
        from start: RoutePoint,
        to end: RoutePoint,
        mode: RouteMovementMode
    ) async throws -> RouteDirectionsSegment
}

enum RouteDirectionsError: Error, Equatable, LocalizedError, Sendable {
    case segmentFailed(index: Int, message: String)
    case noRoute(index: Int)
    case cancelled
    case superseded

    var errorDescription: String? {
        switch self {
        case .segmentFailed(let index, let message):
            return "Could not resolve waypoint segment \(index + 1): \(message)"
        case .noRoute(let index):
            return "Apple Maps found no route for waypoint segment \(index + 1)."
        case .cancelled: return "Route resolution was cancelled."
        case .superseded: return "A newer route edit replaced this directions result."
        }
    }
}

struct RouteDirectionsResolver: Sendable {
    func resolve(
        anchors: [RoutePoint],
        mode: RouteMovementMode,
        provider: any RouteDirectionsProviding
    ) async throws -> ResolvedDirections {
        guard anchors.count >= 2 else { throw RouteValidationError.tooFewPoints }
        var combined: [RoutePoint] = []
        var expectedTime: TimeInterval = 0
        var hasExpectedTime = true

        for index in 0..<(anchors.count - 1) {
            if Task.isCancelled { throw RouteDirectionsError.cancelled }
            let segment: RouteDirectionsSegment
            do {
                segment = try await provider.route(
                    from: anchors[index],
                    to: anchors[index + 1],
                    mode: mode
                )
            } catch is CancellationError {
                throw RouteDirectionsError.cancelled
            } catch let error as RouteDirectionsError {
                switch error {
                case .noRoute:
                    throw RouteDirectionsError.noRoute(index: index)
                case .segmentFailed(_, let message):
                    throw RouteDirectionsError.segmentFailed(index: index, message: message)
                case .cancelled, .superseded:
                    throw error
                }
            } catch {
                throw RouteDirectionsError.segmentFailed(
                    index: index,
                    message: error.localizedDescription
                )
            }

            let points = RouteGeometry.normalized(segment.points)
            guard points.count >= 2 else { throw RouteDirectionsError.noRoute(index: index) }
            if let last = combined.last,
               let first = points.first,
               RouteGeometry.distance(from: last, to: first) < RouteGeometry.minimumSegmentLength {
                combined.append(contentsOf: points.dropFirst())
            } else {
                combined.append(contentsOf: points)
            }

            if let segmentTime = segment.expectedTravelTime,
               segmentTime.isFinite, segmentTime >= 0 {
                expectedTime += segmentTime
            } else {
                hasExpectedTime = false
            }
        }

        if Task.isCancelled { throw RouteDirectionsError.cancelled }
        let geometry = try RouteGeometry(points: combined)
        return ResolvedDirections(
            points: geometry.points,
            distance: geometry.totalDistance,
            expectedTravelTime: hasExpectedTime ? expectedTime : nil
        )
    }
}

actor RouteDirectionsCoordinator {
    private var generation: UInt64 = 0
    private let resolver = RouteDirectionsResolver()

    func resolve(
        anchors: [RoutePoint],
        mode: RouteMovementMode,
        provider: any RouteDirectionsProviding
    ) async throws -> ResolvedDirections {
        generation &+= 1
        let requestGeneration = generation
        let result = try await resolver.resolve(anchors: anchors, mode: mode, provider: provider)
        guard requestGeneration == generation else { throw RouteDirectionsError.superseded }
        return result
    }

    func cancel() {
        generation &+= 1
    }
}

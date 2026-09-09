//
//  RoutePlaybackEngine.swift
//  TLocation
//

import Foundation

struct RouteMetrics: Equatable, Sendable {
    let totalDistance: Double
    let distanceTraveled: Double
    let distanceRemaining: Double
    let progress: Double
    let elapsedTime: TimeInterval
    let estimatedRemainingTime: TimeInterval
    let currentSegment: Int
    let currentCoordinate: RoutePoint
    let currentSpeed: Double
}

struct RoutePlaybackEngine: Equatable, Sendable {
    let route: LocationRoute
    let geometry: RouteGeometry
    let speedModel: WalkingSpeedModel

    private(set) var distanceTraveled = 0.0
    private(set) var elapsedTime: TimeInterval = 0

    init(route: LocationRoute, speedModel: WalkingSpeedModel = .natural) throws {
        self.route = route
        self.geometry = try RouteGeometry(route: route)
        self.speedModel = speedModel
    }

    var isComplete: Bool { distanceTraveled >= geometry.totalDistance }

    var metrics: RouteMetrics {
        makeMetrics(currentSpeed: isComplete ? 0 : speedModel.speed(
            elapsedTime: elapsedTime,
            distanceRemaining: geometry.totalDistance - distanceTraveled
        ))
    }

    @discardableResult
    mutating func advance(by requestedInterval: TimeInterval) -> RouteMetrics {
        guard !isComplete else { return makeMetrics(currentSpeed: 0) }
        let interval = requestedInterval.isFinite ? max(requestedInterval, 0) : 0
        elapsedTime += interval

        let remaining = max(geometry.totalDistance - distanceTraveled, 0)
        let speed = speedModel.speed(elapsedTime: elapsedTime, distanceRemaining: remaining)
        let step = max(speed * interval, 0)
        // Finish exactly once the next update would reach/cross the destination,
        // or once only sub-GPS centimetres remain at the deceleration crawl.
        if step >= remaining || remaining <= max(0.05, step * 1.05) {
            distanceTraveled = geometry.totalDistance
            return makeMetrics(currentSpeed: 0)
        }

        distanceTraveled = min(distanceTraveled + step, geometry.totalDistance)
        return makeMetrics(currentSpeed: speed)
    }

    private func makeMetrics(currentSpeed: Double) -> RouteMetrics {
        let total = geometry.totalDistance
        let traveled = min(max(distanceTraveled, 0), total)
        let remaining = max(total - traveled, 0)
        let progress = total > 0 ? min(max(traveled / total, 0), 1) : 1
        let position = geometry.position(atDistance: traveled)
        let fallbackSpeed = max(speedModel.cruisingSpeed * 0.4, 0.1)
        let eta = remaining > 0 ? remaining / max(currentSpeed, fallbackSpeed) : 0

        return RouteMetrics(
            totalDistance: total,
            distanceTraveled: traveled,
            distanceRemaining: remaining,
            progress: progress,
            elapsedTime: max(elapsedTime, 0),
            estimatedRemainingTime: eta.isFinite ? max(eta, 0) : 0,
            currentSegment: position.segmentIndex,
            currentCoordinate: position.coordinate,
            currentSpeed: currentSpeed.isFinite ? max(currentSpeed, 0) : 0
        )
    }
}

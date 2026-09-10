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
    private(set) var speedMultiplier: Double
    private(set) var currentSpeed = 0.0

    init(
        route: LocationRoute,
        speedModel: WalkingSpeedModel = .natural,
        speedMultiplier: Double = 1
    ) throws {
        self.route = route
        self.geometry = try RouteGeometry(route: route)
        self.speedModel = speedModel
        self.speedMultiplier = WalkingSpeedModel.clampedMultiplier(speedMultiplier)
    }

    var isComplete: Bool { distanceTraveled >= geometry.totalDistance }

    var metrics: RouteMetrics { makeMetrics(currentSpeed: currentSpeed) }

    mutating func setSpeedMultiplier(_ value: Double) {
        speedMultiplier = WalkingSpeedModel.clampedMultiplier(value)
    }

    /// Playback time and distance stay frozen while velocity drops to zero.
    /// The next advance ramps up through the same acceleration limiter.
    mutating func hold() {
        currentSpeed = 0
    }

    @discardableResult
    mutating func advance(by requestedInterval: TimeInterval) -> RouteMetrics {
        guard !isComplete else {
            currentSpeed = 0
            return makeMetrics(currentSpeed: 0)
        }
        let interval = requestedInterval.isFinite ? max(requestedInterval, 0) : 0
        guard interval > 0 else { return makeMetrics(currentSpeed: currentSpeed) }
        elapsedTime += interval

        let remaining = max(geometry.totalDistance - distanceTraveled, 0)
        let desiredSpeed = speedModel.desiredSpeed(
            elapsedTime: elapsedTime,
            distanceRemaining: remaining,
            multiplier: speedMultiplier
        )
        currentSpeed = rateLimitedSpeed(toward: desiredSpeed, interval: interval)
        let step = max(currentSpeed * interval, 0)

        // Finish exactly once the next update would reach/cross the destination,
        // or once only sub-GPS centimetres remain at the deceleration crawl.
        if step >= remaining || remaining <= max(0.05, step * 1.05) {
            distanceTraveled = geometry.totalDistance
            currentSpeed = 0
            return makeMetrics(currentSpeed: 0)
        }

        distanceTraveled = min(distanceTraveled + step, geometry.totalDistance)
        return makeMetrics(currentSpeed: currentSpeed)
    }

    private func rateLimitedSpeed(toward desiredSpeed: Double, interval: TimeInterval) -> Double {
        let desired = desiredSpeed.isFinite ? max(desiredSpeed, 0) : 0
        let delta = desired - currentSpeed
        let maximumDelta = (delta >= 0 ? speedModel.maximumAcceleration : speedModel.maximumDeceleration)
            * interval
        let limitedDelta = min(max(delta, -maximumDelta), maximumDelta)
        let result = currentSpeed + limitedDelta
        return result.isFinite ? max(result, 0) : 0
    }

    private func makeMetrics(currentSpeed: Double) -> RouteMetrics {
        let total = geometry.totalDistance
        let traveled = min(max(distanceTraveled, 0), total)
        let remaining = max(total - traveled, 0)
        let progress = total > 0 ? min(max(traveled / total, 0), 1) : 1
        let position = geometry.position(atDistance: traveled)

        // ETA deliberately follows the selected long-term pace, not the current
        // event envelope or acceleration ramp, so a natural slowdown does not
        // make the label jump every third of a second.
        let etaReferenceSpeed = max(speedModel.targetSpeed(multiplier: speedMultiplier), 0.1)
        let eta = remaining > 0 ? remaining / etaReferenceSpeed : 0

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

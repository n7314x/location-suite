//
//  WalkingSpeedModel.swift
//  TLocation
//

import Foundation

struct WalkingSpeedModel: Equatable, Sendable {
    let cruisingSpeed: Double
    let accelerationDuration: TimeInterval
    let decelerationDistance: Double
    let variationFraction: Double

    static let natural = WalkingSpeedModel(
        cruisingSpeed: 1.4,
        accelerationDuration: 4,
        decelerationDistance: 6,
        variationFraction: 0.025
    )

    init(
        cruisingSpeed: Double,
        accelerationDuration: TimeInterval,
        decelerationDistance: Double,
        variationFraction: Double
    ) {
        self.cruisingSpeed = max(cruisingSpeed, 0.1)
        self.accelerationDuration = max(accelerationDuration, 0.1)
        self.decelerationDistance = max(decelerationDistance, 0.1)
        self.variationFraction = min(max(variationFraction, 0), 0.1)
    }

    func speed(elapsedTime: TimeInterval, distanceRemaining: Double) -> Double {
        guard distanceRemaining > 0 else { return 0 }

        let accelerationProgress = min(max(elapsedTime / accelerationDuration, 0), 1)
        let accelerationFactor = smoothStep(accelerationProgress)

        let decelerationProgress = min(max(distanceRemaining / decelerationDistance, 0), 1)
        // Retaining a gentle 15% crawl avoids an asymptotic approach that never
        // reaches the destination; the engine snaps only the final centimetres.
        let decelerationFactor = max(0.15, smoothStep(decelerationProgress))

        // A deterministic, low-amplitude variation keeps tests reproducible and
        // avoids the implausible jumps that random per-tick speed would create.
        let variation = 1 + variationFraction * sin(elapsedTime * 0.7)
        let speed = cruisingSpeed * min(accelerationFactor, decelerationFactor) * variation
        return speed.isFinite ? max(speed, 0) : 0
    }

    private func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}

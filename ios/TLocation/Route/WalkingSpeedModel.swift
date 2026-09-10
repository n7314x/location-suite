//
//  WalkingSpeedModel.swift
//  TLocation
//

import Foundation

/// A deterministic, continuously differentiable walking-pace profile.
///
/// Production controllers use a fresh random seed for each controller lifetime;
/// tests pass a known seed. Randomness selects phases, event timing, amplitude,
/// and event direction only. It is never applied to coordinates or sampled on a
/// per-tick basis, so the resulting velocity has no jitter.
struct WalkingSpeedModel: Equatable, Sendable {
    static let minimumMultiplier = 0.5
    static let maximumMultiplier = 3.0
    static let multiplierPresets = [0.5, 1.0, 1.5, 2.0, 3.0]

    let cruisingSpeed: Double
    let decelerationDistance: Double
    let normalVariationFraction: Double
    let eventAmplitudeRange: ClosedRange<Double>
    let eventCycleDuration: TimeInterval
    let eventDurationRange: ClosedRange<TimeInterval>
    let minimumVariationFactor: Double
    let maximumVariationFactor: Double
    let maximumAcceleration: Double
    let maximumDeceleration: Double
    let seed: UInt64

    static let natural = WalkingSpeedModel(seed: 0)

    static var randomNatural: WalkingSpeedModel {
        WalkingSpeedModel(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    init(
        cruisingSpeed: Double = 1.4,
        decelerationDistance: Double = 6,
        normalVariationFraction: Double = 0.045,
        eventAmplitudeRange: ClosedRange<Double> = 0.12...0.20,
        eventCycleDuration: TimeInterval = 22,
        eventDurationRange: ClosedRange<TimeInterval> = 6...9,
        minimumVariationFactor: Double = 0.72,
        maximumVariationFactor: Double = 1.28,
        maximumAcceleration: Double = 0.45,
        maximumDeceleration: Double = 0.55,
        seed: UInt64
    ) {
        self.cruisingSpeed = cruisingSpeed.isFinite ? max(cruisingSpeed, 0.1) : 1.4
        self.decelerationDistance = decelerationDistance.isFinite ? max(decelerationDistance, 0.1) : 6
        self.normalVariationFraction = normalVariationFraction.isFinite
            ? min(max(normalVariationFraction, 0), 0.1)
            : 0.045

        let eventLower = eventAmplitudeRange.lowerBound.isFinite
            ? min(max(eventAmplitudeRange.lowerBound, 0), 0.25)
            : 0.12
        let eventUpper = eventAmplitudeRange.upperBound.isFinite
            ? min(max(eventAmplitudeRange.upperBound, eventLower), 0.25)
            : max(eventLower, 0.20)
        self.eventAmplitudeRange = eventLower...eventUpper
        self.eventCycleDuration = eventCycleDuration.isFinite ? max(eventCycleDuration, 12) : 22

        let durationLower = eventDurationRange.lowerBound.isFinite
            ? max(eventDurationRange.lowerBound, 2)
            : 6
        let durationUpper = eventDurationRange.upperBound.isFinite
            ? max(eventDurationRange.upperBound, durationLower)
            : max(durationLower, 9)
        self.eventDurationRange = durationLower...durationUpper

        let lowerFactor = minimumVariationFactor.isFinite
            ? min(max(minimumVariationFactor, 0.5), 1)
            : 0.72
        let upperFactor = maximumVariationFactor.isFinite
            ? max(min(maximumVariationFactor, 1.5), 1)
            : 1.28
        self.minimumVariationFactor = lowerFactor
        self.maximumVariationFactor = upperFactor
        self.maximumAcceleration = maximumAcceleration.isFinite ? max(maximumAcceleration, 0.05) : 0.45
        self.maximumDeceleration = maximumDeceleration.isFinite ? max(maximumDeceleration, 0.05) : 0.55
        self.seed = seed
    }

    static func clampedMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, minimumMultiplier), maximumMultiplier)
    }

    /// The long-term selected pace. ETA uses this rather than the momentary
    /// variation so it responds to the speed control without bouncing per tick.
    func targetSpeed(multiplier: Double) -> Double {
        cruisingSpeed * Self.clampedMultiplier(multiplier)
    }

    /// Desired instantaneous speed before the engine applies acceleration and
    /// deceleration limits. Natural variation is velocity-only and bounded.
    func desiredSpeed(
        elapsedTime: TimeInterval,
        distanceRemaining: Double,
        multiplier: Double
    ) -> Double {
        guard distanceRemaining.isFinite, distanceRemaining > 0 else { return 0 }

        let remainingProgress = min(max(distanceRemaining / decelerationDistance, 0), 1)
        // Retaining a gentle crawl avoids an asymptotic approach. The engine
        // snaps only the final centimetres to the exact destination.
        let destinationFactor = max(0.15, smoothStep(remainingProgress))
        let desired = targetSpeed(multiplier: multiplier)
            * variationFactor(at: elapsedTime)
            * destinationFactor
        return desired.isFinite ? max(desired, 0) : 0
    }

    /// Smooth low-frequency drift plus one several-second event per cycle.
    /// Event signs alternate, guaranteeing both slow and fast periods over a
    /// sufficiently long walk while the seed varies their exact shape.
    func variationFactor(at requestedTime: TimeInterval) -> Double {
        let time = requestedTime.isFinite ? max(requestedTime, 0) : 0
        let phaseA = unitRandom(index: 0, salt: 0xA1) * 2 * Double.pi
        let phaseB = unitRandom(index: 0, salt: 0xB2) * 2 * Double.pi
        let normalWave = normalVariationFraction * (
            0.62 * sin(time * 0.31 + phaseA)
                + 0.38 * sin(time * 0.13 + phaseB)
        )

        let eventIndex = Int(floor(time / eventCycleDuration))
        let cycleStart = Double(eventIndex) * eventCycleDuration
        let startJitter = unitRandom(index: eventIndex, salt: 0xC3) * 3
        let eventStart = cycleStart + 4 + startJitter
        let durationUnit = unitRandom(index: eventIndex, salt: 0xD4)
        let duration = eventDurationRange.lowerBound
            + durationUnit * (eventDurationRange.upperBound - eventDurationRange.lowerBound)

        var eventVariation = 0.0
        if time >= eventStart, time <= eventStart + duration {
            let progress = (time - eventStart) / duration
            let envelope = pow(sin(Double.pi * progress), 2)
            let amplitudeUnit = unitRandom(index: eventIndex, salt: 0xE5)
            let amplitude = eventAmplitudeRange.lowerBound
                + amplitudeUnit * (eventAmplitudeRange.upperBound - eventAmplitudeRange.lowerBound)
            let seedParity = Int(seed & 1)
            let direction = (eventIndex + seedParity).isMultiple(of: 2) ? -1.0 : 1.0
            eventVariation = direction * amplitude * envelope
        }

        let factor = 1 + normalWave + eventVariation
        guard factor.isFinite else { return 1 }
        return min(max(factor, minimumVariationFactor), maximumVariationFactor)
    }

    private func unitRandom(index: Int, salt: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(index))
        value &+= seed
        value &+= salt &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }

    private func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}

//
//  WalkingSpeedModel.swift
//  TLocation
//

import Foundation

/// One shared, deterministic movement profile used by every route mode.
/// Variation changes velocity only; coordinates always stay on route geometry.
struct MovementProfile: Equatable, Sendable {
    let mode: RouteMovementMode
    let cruisingSpeed: Double
    let multiplierRange: ClosedRange<Double>
    let multiplierPresets: [Double]
    let decelerationDistance: Double
    let normalVariationFraction: Double
    let eventAmplitudeRange: ClosedRange<Double>
    let eventCycleDuration: TimeInterval
    let eventDurationRange: ClosedRange<TimeInterval>
    let minimumVariationFactor: Double
    let maximumVariationFactor: Double
    let maximumAcceleration: Double
    let maximumDeceleration: Double
    let maximumReasonableSpeed: Double
    let seed: UInt64

    static let minimumMultiplier = 0.5
    static let maximumMultiplier = 3.0
    static let multiplierPresets = [0.5, 1.0, 1.5, 2.0, 3.0]

    static let natural = MovementProfile(seed: 0)

    static var randomNatural: MovementProfile {
        MovementProfile(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    /// Backward-compatible walking initializer used by focused tests and older
    /// callers. Mode-specific production profiles come from `profile(for:)`.
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
        self.init(
            mode: .walking,
            cruisingSpeed: cruisingSpeed,
            multiplierRange: 0.5...3,
            multiplierPresets: [0.5, 1, 1.5, 2, 3],
            decelerationDistance: decelerationDistance,
            normalVariationFraction: normalVariationFraction,
            eventAmplitudeRange: eventAmplitudeRange,
            eventCycleDuration: eventCycleDuration,
            eventDurationRange: eventDurationRange,
            minimumVariationFactor: minimumVariationFactor,
            maximumVariationFactor: maximumVariationFactor,
            maximumAcceleration: maximumAcceleration,
            maximumDeceleration: maximumDeceleration,
            maximumReasonableSpeed: 5,
            seed: seed
        )
    }

    private init(
        mode: RouteMovementMode,
        cruisingSpeed: Double,
        multiplierRange: ClosedRange<Double>,
        multiplierPresets: [Double],
        decelerationDistance: Double,
        normalVariationFraction: Double,
        eventAmplitudeRange: ClosedRange<Double>,
        eventCycleDuration: TimeInterval,
        eventDurationRange: ClosedRange<TimeInterval>,
        minimumVariationFactor: Double,
        maximumVariationFactor: Double,
        maximumAcceleration: Double,
        maximumDeceleration: Double,
        maximumReasonableSpeed: Double,
        seed: UInt64
    ) {
        self.mode = mode
        self.cruisingSpeed = cruisingSpeed.isFinite ? max(cruisingSpeed, 0.1) : 1.4
        self.multiplierRange = multiplierRange
        self.multiplierPresets = multiplierPresets
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

        self.minimumVariationFactor = min(max(minimumVariationFactor, 0.5), 1)
        self.maximumVariationFactor = max(min(maximumVariationFactor, 1.5), 1)
        self.maximumAcceleration = maximumAcceleration.isFinite ? max(maximumAcceleration, 0.05) : 0.45
        self.maximumDeceleration = maximumDeceleration.isFinite ? max(maximumDeceleration, 0.05) : 0.55
        self.maximumReasonableSpeed = maximumReasonableSpeed.isFinite
            ? max(maximumReasonableSpeed, self.cruisingSpeed)
            : self.cruisingSpeed
        self.seed = seed
    }

    static func profile(for mode: RouteMovementMode, seed: UInt64 = 0) -> MovementProfile {
        switch mode {
        case .walking:
            return MovementProfile(seed: seed)
        case .cycling:
            return MovementProfile(
                mode: .cycling,
                cruisingSpeed: 5.5,
                multiplierRange: 0.5...3,
                multiplierPresets: [0.5, 1, 1.5, 2, 3],
                decelerationDistance: 22,
                normalVariationFraction: 0.055,
                eventAmplitudeRange: 0.08...0.14,
                eventCycleDuration: 28,
                eventDurationRange: 7...11,
                minimumVariationFactor: 0.78,
                maximumVariationFactor: 1.22,
                maximumAcceleration: 0.8,
                maximumDeceleration: 1.25,
                maximumReasonableSpeed: 16,
                seed: seed
            )
        case .driving:
            return MovementProfile(
                mode: .driving,
                cruisingSpeed: 13.9,
                multiplierRange: 0.25...2,
                multiplierPresets: [0.25, 0.5, 1, 1.5, 2],
                decelerationDistance: 90,
                normalVariationFraction: 0.018,
                eventAmplitudeRange: 0.035...0.07,
                eventCycleDuration: 34,
                eventDurationRange: 8...13,
                minimumVariationFactor: 0.88,
                maximumVariationFactor: 1.12,
                maximumAcceleration: 2.0,
                maximumDeceleration: 3.2,
                maximumReasonableSpeed: 38,
                seed: seed
            )
        }
    }

    static func multiplierRange(for mode: RouteMovementMode) -> ClosedRange<Double> {
        profile(for: mode).multiplierRange
    }

    static func clampedMultiplier(_ value: Double, mode: RouteMovementMode = .walking) -> Double {
        let range = multiplierRange(for: mode)
        guard value.isFinite else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func clampedMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, multiplierRange.lowerBound), multiplierRange.upperBound)
    }

    func targetSpeed(multiplier: Double) -> Double {
        min(cruisingSpeed * clampedMultiplier(multiplier), maximumReasonableSpeed)
    }

    func desiredSpeed(
        elapsedTime: TimeInterval,
        distanceRemaining: Double,
        multiplier: Double
    ) -> Double {
        guard distanceRemaining.isFinite, distanceRemaining > 0 else { return 0 }
        let remainingProgress = min(max(distanceRemaining / decelerationDistance, 0), 1)
        let destinationFactor = max(0.12, smoothStep(remainingProgress))
        let desired = targetSpeed(multiplier: multiplier)
            * variationFactor(at: elapsedTime)
            * destinationFactor
        return desired.isFinite ? min(max(desired, 0), maximumReasonableSpeed) : 0
    }

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
        let eventStart = cycleStart + 4 + unitRandom(index: eventIndex, salt: 0xC3) * 3
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

/// Source compatibility for the first route milestone and its tests.
typealias WalkingSpeedModel = MovementProfile

//
//  RouteGeometry.swift
//  TLocation
//

import Foundation

struct RoutePosition: Equatable, Sendable {
    let coordinate: RoutePoint
    let segmentIndex: Int
    let distanceFromStart: Double
}

struct RouteGeometry: Equatable, Sendable {
    /// Consecutive waypoints closer than this are one usable point. Five
    /// centimetres is well below GPS precision but safely above floating-point
    /// noise and eliminates zero-length divisions.
    static let minimumSegmentLength = 0.05
    static let earthRadius = 6_371_008.8

    struct Segment: Equatable, Sendable {
        let start: RoutePoint
        let end: RoutePoint
        let length: Double
        let cumulativeStart: Double

        var cumulativeEnd: Double { cumulativeStart + length }
    }

    let points: [RoutePoint]
    let segments: [Segment]
    let totalDistance: Double

    init(route: LocationRoute) throws {
        try self.init(points: route.points)
    }

    init(points: [RoutePoint]) throws {
        let normalizedPoints = Self.normalized(points)
        guard normalizedPoints.count >= 2 else {
            throw RouteValidationError.tooFewUsablePoints
        }

        var cumulative = 0.0
        var builtSegments: [Segment] = []
        builtSegments.reserveCapacity(normalizedPoints.count - 1)

        for index in 0..<(normalizedPoints.count - 1) {
            let start = normalizedPoints[index]
            let end = normalizedPoints[index + 1]
            let length = Self.distance(from: start, to: end)
            guard length.isFinite, length >= Self.minimumSegmentLength else { continue }
            builtSegments.append(
                Segment(start: start, end: end, length: length, cumulativeStart: cumulative)
            )
            cumulative += length
        }

        guard let first = builtSegments.first else {
            throw RouteValidationError.tooFewUsablePoints
        }
        var usablePoints = [first.start]
        usablePoints.append(contentsOf: builtSegments.map(\.end))

        self.points = usablePoints
        self.segments = builtSegments
        self.totalDistance = cumulative
    }

    static func normalized(_ points: [RoutePoint]) -> [RoutePoint] {
        var result: [RoutePoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            guard let previous = result.last else {
                result.append(point)
                continue
            }
            if distance(from: previous, to: point) >= minimumSegmentLength {
                result.append(point)
            }
        }
        return result
    }

    static func distance(from start: RoutePoint, to end: RoutePoint) -> Double {
        let latitude1 = radians(start.latitude)
        let latitude2 = radians(end.latitude)
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = shortestLongitudeDelta(
            from: radians(start.longitude),
            to: radians(end.longitude)
        )

        let sinLatitude = sin(deltaLatitude / 2)
        let sinLongitude = sin(deltaLongitude / 2)
        let haversine = sinLatitude * sinLatitude
            + cos(latitude1) * cos(latitude2) * sinLongitude * sinLongitude
        let centralAngle = 2 * atan2(sqrt(max(0, haversine)), sqrt(max(0, 1 - haversine)))
        return earthRadius * centralAngle
    }

    func position(atDistance requestedDistance: Double) -> RoutePosition {
        let finiteDistance = requestedDistance.isFinite ? requestedDistance : 0
        let distance = min(max(finiteDistance, 0), totalDistance)

        guard distance > 0 else {
            return RoutePosition(coordinate: points[0], segmentIndex: 0, distanceFromStart: 0)
        }
        guard distance < totalDistance else {
            return RoutePosition(
                coordinate: points[points.count - 1],
                segmentIndex: segments.count - 1,
                distanceFromStart: totalDistance
            )
        }

        let index = segments.firstIndex { distance <= $0.cumulativeEnd } ?? (segments.count - 1)
        let segment = segments[index]
        let fraction = min(max((distance - segment.cumulativeStart) / segment.length, 0), 1)
        return RoutePosition(
            coordinate: Self.interpolate(from: segment.start, to: segment.end, fraction: fraction),
            segmentIndex: index,
            distanceFromStart: distance
        )
    }

    /// Great-circle interpolation (spherical linear interpolation), including
    /// shortest-path longitude handling across the antimeridian.
    static func interpolate(from start: RoutePoint, to end: RoutePoint, fraction: Double) -> RoutePoint {
        let amount = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if amount == 0 { return start }
        if amount == 1 { return end }

        let startVector = unitVector(for: start)
        let endVector = unitVector(for: end)
        let dotProduct = min(max(dot(startVector, endVector), -1), 1)
        let angle = acos(dotProduct)
        let sine = sin(angle)

        if angle < 1e-12 || abs(sine) < 1e-12 {
            let latitude = start.latitude + (end.latitude - start.latitude) * amount
            let longitudeDelta = degrees(shortestLongitudeDelta(
                from: radians(start.longitude),
                to: radians(end.longitude)
            ))
            return validatedInterpolatedPoint(
                latitude: latitude,
                longitude: normalizedLongitude(start.longitude + longitudeDelta * amount),
                fallback: amount < 0.5 ? start : end
            )
        }

        let startWeight = sin((1 - amount) * angle) / sine
        let endWeight = sin(amount * angle) / sine
        let x = startWeight * startVector.x + endWeight * endVector.x
        let y = startWeight * startVector.y + endWeight * endVector.y
        let z = startWeight * startVector.z + endWeight * endVector.z
        let latitude = atan2(z, sqrt(x * x + y * y))
        let longitude = atan2(y, x)

        return validatedInterpolatedPoint(
            latitude: degrees(latitude),
            longitude: degrees(longitude),
            fallback: amount < 0.5 ? start : end
        )
    }

    private static func unitVector(for point: RoutePoint) -> (x: Double, y: Double, z: Double) {
        let latitude = radians(point.latitude)
        let longitude = radians(point.longitude)
        let latitudeCosine = cos(latitude)
        return (
            latitudeCosine * cos(longitude),
            latitudeCosine * sin(longitude),
            sin(latitude)
        )
    }

    private static func dot(
        _ left: (x: Double, y: Double, z: Double),
        _ right: (x: Double, y: Double, z: Double)
    ) -> Double {
        left.x * right.x + left.y * right.y + left.z * right.z
    }

    private static func shortestLongitudeDelta(from start: Double, to end: Double) -> Double {
        var delta = end - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var value = longitude
        while value > 180 { value -= 360 }
        while value < -180 { value += 360 }
        return value
    }

    /// `atan2` mathematically produces a latitude in -90...90, but floating
    /// point conversion at a pole can overshoot by a few ulps. Clamp that noise
    /// before passing through the same validation as every other route point;
    /// the fallback makes this total even if a future math change yields a
    /// non-finite value.
    private static func validatedInterpolatedPoint(
        latitude: Double,
        longitude: Double,
        fallback: RoutePoint
    ) -> RoutePoint {
        guard latitude.isFinite, longitude.isFinite else { return fallback }
        return (try? RoutePoint(
            latitude: min(max(latitude, -90), 90),
            longitude: min(max(longitude, -180), 180)
        )) ?? fallback
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

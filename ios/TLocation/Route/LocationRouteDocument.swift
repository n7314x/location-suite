//
//  LocationRouteDocument.swift
//  TLocation
//
//  Stable mobile/web interchange model. It intentionally contains no MapKit
//  types and is separate from the playback-only `LocationRoute`.
//

import Foundation

private enum RouteDocumentDate {
    /// JSONEncoder's stable ISO-8601 strategy writes whole seconds. Normalize at
    /// the model boundary so a freshly-created document and its decoded copy
    /// have identical values instead of differing only by discarded fractions.
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

struct RouteDocumentSourceMetadata: Codable, Equatable, Sendable {
    var client: String?
    var originalIdentifier: String?

    init(client: String? = nil, originalIdentifier: String? = nil) {
        self.client = client
        self.originalIdentifier = originalIdentifier
    }
}

struct ResolvedRouteGeometry: Codable, Equatable, Sendable {
    let points: [RoutePoint]
    let distance: Double
    let expectedTravelTime: TimeInterval?
    let provider: String
    let resolvedAt: Date

    init(
        points: [RoutePoint],
        distance: Double? = nil,
        expectedTravelTime: TimeInterval? = nil,
        provider: String = "mapKit",
        resolvedAt: Date = Date()
    ) throws {
        let geometry = try RouteGeometry(points: points)
        let measuredDistance = distance ?? geometry.totalDistance
        guard measuredDistance.isFinite, measuredDistance > 0,
              expectedTravelTime.map({ $0.isFinite && $0 >= 0 }) ?? true,
              !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouteValidationError.invalidResolvedGeometry
        }
        self.points = geometry.points
        self.distance = measuredDistance
        self.expectedTravelTime = expectedTravelTime
        self.provider = provider
        self.resolvedAt = RouteDocumentDate.normalized(resolvedAt)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            points: values.decode([RoutePoint].self, forKey: .points),
            distance: values.decode(Double.self, forKey: .distance),
            expectedTravelTime: values.decodeIfPresent(TimeInterval.self, forKey: .expectedTravelTime),
            provider: values.decode(String.self, forKey: .provider),
            resolvedAt: values.decode(Date.self, forKey: .resolvedAt)
        )
    }
}

struct LocationRouteDocument: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: String
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var movementMode: RouteMovementMode
    var anchors: [RoutePoint]
    var resolvedGeometry: ResolvedRouteGeometry?
    var defaultSpeedMultiplier: Double
    var source: RouteDocumentSourceMetadata?

    init(
        version: Int = Self.currentVersion,
        id: String = LocationRoute.makeIdentifier(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        movementMode: RouteMovementMode = .walking,
        anchors: [RoutePoint],
        resolvedGeometry: ResolvedRouteGeometry? = nil,
        defaultSpeedMultiplier: Double = 1,
        source: RouteDocumentSourceMetadata? = nil
    ) throws {
        guard version == Self.currentVersion else {
            throw RouteValidationError.unsupportedVersion(version)
        }
        guard LocationRoute.isValidIdentifier(id) else {
            throw RouteValidationError.invalidIdentifier
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
            throw RouteValidationError.invalidName
        }
        guard anchors.count >= 2 else { throw RouteValidationError.tooFewPoints }
        guard RouteGeometry.normalized(anchors).count >= 2 else {
            throw RouteValidationError.tooFewUsablePoints
        }
        let range = MovementProfile.multiplierRange(for: movementMode)
        guard defaultSpeedMultiplier.isFinite,
              range.contains(defaultSpeedMultiplier) else {
            throw RouteValidationError.invalidSpeedMultiplier
        }

        self.version = version
        self.id = id
        self.name = trimmedName
        self.createdAt = RouteDocumentDate.normalized(createdAt)
        self.modifiedAt = RouteDocumentDate.normalized(modifiedAt)
        self.movementMode = movementMode
        self.anchors = anchors
        self.resolvedGeometry = resolvedGeometry
        self.defaultSpeedMultiplier = defaultSpeedMultiplier
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: values.decode(Int.self, forKey: .version),
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            modifiedAt: values.decode(Date.self, forKey: .modifiedAt),
            movementMode: values.decode(RouteMovementMode.self, forKey: .movementMode),
            anchors: values.decode([RoutePoint].self, forKey: .anchors),
            resolvedGeometry: values.decodeIfPresent(ResolvedRouteGeometry.self, forKey: .resolvedGeometry),
            defaultSpeedMultiplier: values.decodeIfPresent(Double.self, forKey: .defaultSpeedMultiplier) ?? 1,
            source: values.decodeIfPresent(RouteDocumentSourceMetadata.self, forKey: .source)
        )
    }

    var distance: Double {
        resolvedGeometry?.distance ?? ((try? RouteGeometry(points: anchors).totalDistance) ?? 0)
    }

    var estimatedTravelTime: TimeInterval {
        if let expected = resolvedGeometry?.expectedTravelTime, expected > 0 {
            return expected / defaultSpeedMultiplier
        }
        let speed = MovementProfile.profile(for: movementMode).targetSpeed(
            multiplier: defaultSpeedMultiplier
        )
        return speed > 0 ? distance / speed : 0
    }

    func playbackRoute(useDirectFallback: Bool = false) throws -> LocationRoute {
        guard let points = resolvedGeometry?.points ?? (useDirectFallback ? anchors : nil) else {
            throw RouteDocumentError.unresolvedGeometry
        }
        return try LocationRoute(
            id: id,
            name: name,
            mode: movementMode,
            points: points,
            speedProfile: .natural,
            metadata: RouteMetadata(
                createdAt: ISO8601DateFormatter().string(from: createdAt),
                source: .waypoint
            )
        )
    }

    func reversed(now: Date = Date()) throws -> LocationRouteDocument {
        let reversedGeometry: ResolvedRouteGeometry?
        if let geometry = resolvedGeometry {
            reversedGeometry = try ResolvedRouteGeometry(
                points: Array(geometry.points.reversed()),
                distance: geometry.distance,
                expectedTravelTime: geometry.expectedTravelTime,
                provider: geometry.provider,
                resolvedAt: geometry.resolvedAt
            )
        } else {
            reversedGeometry = nil
        }
        return try LocationRouteDocument(
            version: version,
            id: id,
            name: name,
            createdAt: createdAt,
            modifiedAt: now,
            movementMode: movementMode,
            anchors: Array(anchors.reversed()),
            resolvedGeometry: reversedGeometry,
            defaultSpeedMultiplier: defaultSpeedMultiplier,
            source: source
        )
    }
}

enum RouteDocumentError: Error, Equatable, LocalizedError, Sendable {
    case malformedJSON
    case unresolvedGeometry
    case duplicateIdentifier
    case documentNotFound

    var errorDescription: String? {
        switch self {
        case .malformedJSON: return "This file is not a valid Location Suite route."
        case .unresolvedGeometry: return "Resolve this route before playing it, or explicitly choose straight-line fallback."
        case .duplicateIdentifier: return "The route library contains duplicate identifiers."
        case .documentNotFound: return "The saved route could not be found."
        }
    }
}

enum RouteDocumentCodec {
    static func encode(_ document: LocationRouteDocument) throws -> Data {
        try makeEncoder().encode(document)
    }

    static func decode(_ data: Data) throws -> LocationRouteDocument {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else {
            throw RouteDocumentError.malformedJSON
        }
        guard version == LocationRouteDocument.currentVersion else {
            throw RouteValidationError.unsupportedVersion(version)
        }
        return try makeDecoder().decode(LocationRouteDocument.self, from: data)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

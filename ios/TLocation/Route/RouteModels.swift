//
//  RouteModels.swift
//  TLocation
//
//  AGPL-3.0 derivative work; see the repository LICENSE and docs/UPSTREAM.md.
//

import Foundation

enum RouteMovementMode: String, Codable, CaseIterable, Sendable {
    case walking
}

enum RouteSpeedProfile: String, Codable, CaseIterable, Sendable {
    case natural
}

enum RouteSource: String, Codable, Sendable {
    case waypoint
}

struct RouteMetadata: Codable, Equatable, Sendable {
    var createdAt: String?
    var source: RouteSource?

    init(createdAt: String? = nil, source: RouteSource? = nil) {
        self.createdAt = createdAt
        self.source = source
    }
}

struct RoutePoint: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude) else {
            throw RouteValidationError.invalidLatitude
        }
        guard longitude.isFinite, (-180...180).contains(longitude) else {
            throw RouteValidationError.invalidLongitude
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        try self.init(latitude: latitude, longitude: longitude)
    }
}

enum RouteValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidIdentifier
    case invalidName
    case invalidLatitude
    case invalidLongitude
    case tooFewPoints
    case tooFewUsablePoints

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This route uses an unsupported version."
        case .invalidIdentifier:
            return "The route identifier is invalid."
        case .invalidName:
            return "The route name must contain 1 to 120 characters."
        case .invalidLatitude, .invalidLongitude:
            return "The route contains an invalid coordinate."
        case .tooFewPoints, .tooFewUsablePoints:
            return "Add at least two different waypoints before starting."
        }
    }
}

struct LocationRoute: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: String
    var name: String?
    let mode: RouteMovementMode
    let points: [RoutePoint]
    let speedProfile: RouteSpeedProfile
    var metadata: RouteMetadata?

    init(
        version: Int = LocationRoute.currentVersion,
        id: String = LocationRoute.makeIdentifier(),
        name: String? = nil,
        mode: RouteMovementMode = .walking,
        points: [RoutePoint],
        speedProfile: RouteSpeedProfile = .natural,
        metadata: RouteMetadata? = nil
    ) throws {
        guard version == Self.currentVersion else {
            throw RouteValidationError.unsupportedVersion(version)
        }
        guard Self.isValidIdentifier(id) else {
            throw RouteValidationError.invalidIdentifier
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 120 else {
                throw RouteValidationError.invalidName
            }
            self.name = trimmed
        } else {
            self.name = nil
        }
        guard points.count >= 2 else {
            throw RouteValidationError.tooFewPoints
        }
        guard RouteGeometry.normalized(points).count >= 2 else {
            throw RouteValidationError.tooFewUsablePoints
        }

        self.version = version
        self.id = id
        self.mode = mode
        self.points = points
        self.speedProfile = speedProfile
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            id: container.decode(String.self, forKey: .id),
            name: container.decodeIfPresent(String.self, forKey: .name),
            mode: container.decode(RouteMovementMode.self, forKey: .mode),
            points: container.decode([RoutePoint].self, forKey: .points),
            speedProfile: container.decode(RouteSpeedProfile.self, forKey: .speedProfile),
            metadata: container.decodeIfPresent(RouteMetadata.self, forKey: .metadata)
        )
    }

    static func makeIdentifier() -> String {
        "route_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        guard id.hasPrefix("route_"), id.count <= 100 else { return false }
        let suffix = id.dropFirst("route_".count)
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }
}

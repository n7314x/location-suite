import Foundation

struct RouteScheduleStep: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var routeID: String
    var pauseAfter: TimeInterval

    init(
        id: String = "step_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        routeID: String,
        pauseAfter: TimeInterval = 0
    ) throws {
        guard !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouteScheduleValidationError.missingRouteIdentifier
        }
        guard pauseAfter.isFinite, pauseAfter >= 0, pauseAfter <= 24 * 60 * 60 else {
            throw RouteScheduleValidationError.invalidPause
        }
        self.id = id
        self.routeID = routeID
        self.pauseAfter = pauseAfter
    }
}

struct RouteScheduleDocument: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: String
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var startAt: Date?
    var steps: [RouteScheduleStep]

    init(
        version: Int = Self.currentVersion,
        id: String = "schedule_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        startAt: Date? = nil,
        steps: [RouteScheduleStep]
    ) throws {
        guard version == Self.currentVersion else {
            throw RouteScheduleValidationError.unsupportedVersion(version)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw RouteScheduleValidationError.invalidName
        }
        guard !steps.isEmpty else {
            throw RouteScheduleValidationError.emptySchedule
        }
        self.version = version
        self.id = id
        self.name = trimmed
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.startAt = startAt
        self.steps = steps
    }
}

enum RouteScheduleValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidName
    case emptySchedule
    case invalidPause
    case missingRouteIdentifier
    case missingRoute(String)
    case unresolvedRoute(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This route schedule uses an unsupported version."
        case .invalidName:
            return "The schedule name must contain 1 to 120 characters."
        case .emptySchedule:
            return "Add at least one saved route to the schedule."
        case .invalidPause:
            return "A pause must be between 0 seconds and 24 hours."
        case .missingRouteIdentifier:
            return "A schedule step is missing its saved-route identifier."
        case .missingRoute(let id):
            return "The schedule refers to a saved route that no longer exists: \(id)"
        case .unresolvedRoute(let name):
            return "Resolve \(name) before using it in a schedule."
        }
    }
}

struct RouteScheduleJumpWarning: Equatable, Sendable {
    let fromRouteName: String
    let toRouteName: String
    let distance: Double
}

enum RouteScheduleValidator {
    static let jumpWarningDistance: Double = 100

    static func validate(
        _ schedule: RouteScheduleDocument,
        routes: [LocationRouteDocument]
    ) throws -> [RouteScheduleJumpWarning] {
        let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        var resolved: [LocationRouteDocument] = []

        for step in schedule.steps {
            guard let route = byID[step.routeID] else {
                throw RouteScheduleValidationError.missingRoute(step.routeID)
            }
            guard route.resolvedGeometry != nil else {
                throw RouteScheduleValidationError.unresolvedRoute(route.name)
            }
            guard step.pauseAfter.isFinite, step.pauseAfter >= 0, step.pauseAfter <= 24 * 60 * 60 else {
                throw RouteScheduleValidationError.invalidPause
            }
            resolved.append(route)
        }

        var warnings: [RouteScheduleJumpWarning] = []
        for pair in zip(resolved, resolved.dropFirst()) {
            guard let end = pair.0.resolvedGeometry?.points.last,
                  let start = pair.1.resolvedGeometry?.points.first else { continue }
            let distance = RouteGeometry.distance(from: end, to: start)
            if distance >= jumpWarningDistance {
                warnings.append(RouteScheduleJumpWarning(
                    fromRouteName: pair.0.name,
                    toRouteName: pair.1.name,
                    distance: distance
                ))
            }
        }
        return warnings
    }
}

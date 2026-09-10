//
//  RouteDocumentStore.swift
//  TLocation
//

import Foundation

struct LocationRouteLibraryFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    var routes: [LocationRouteDocument]

    init(version: Int = Self.currentVersion, routes: [LocationRouteDocument]) throws {
        guard version == Self.currentVersion else {
            throw RouteValidationError.unsupportedVersion(version)
        }
        guard Set(routes.map(\.id)).count == routes.count else {
            throw RouteDocumentError.duplicateIdentifier
        }
        self.version = version
        self.routes = routes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: values.decode(Int.self, forKey: .version),
            routes: values.decode([LocationRouteDocument].self, forKey: .routes)
        )
    }
}

actor RouteDocumentStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationStore(fileManager: FileManager = .default) -> RouteDocumentStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationSuite", isDirectory: true)
        return RouteDocumentStore(
            fileURL: root.appendingPathComponent("saved-routes-v1.json"),
            fileManager: fileManager
        )
    }

    func load() throws -> [LocationRouteDocument] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)

        do {
            let library = try RouteDocumentCodec.makeDecoder().decode(
                LocationRouteLibraryFile.self,
                from: data
            )
            return library.routes
        } catch let error as RouteValidationError {
            throw error
        } catch {
            // Migration seam for the earliest development builds, which stored a
            // top-level array before the versioned library envelope existed.
            if let legacy = try? RouteDocumentCodec.makeDecoder().decode(
                [LocationRouteDocument].self,
                from: data
            ) {
                try replaceAll(legacy)
                return legacy
            }
            throw RouteDocumentError.malformedJSON
        }
    }

    func save(_ document: LocationRouteDocument) throws {
        var routes = try load()
        if let index = routes.firstIndex(where: { $0.id == document.id }) {
            routes[index] = document
        } else {
            routes.append(document)
        }
        try replaceAll(routes)
    }

    @discardableResult
    func rename(id: String, to name: String, now: Date = Date()) throws -> LocationRouteDocument {
        var routes = try load()
        guard let index = routes.firstIndex(where: { $0.id == id }) else {
            throw RouteDocumentError.documentNotFound
        }
        let original = routes[index]
        let renamed = try LocationRouteDocument(
            id: original.id,
            name: name,
            createdAt: original.createdAt,
            modifiedAt: now,
            movementMode: original.movementMode,
            anchors: original.anchors,
            resolvedGeometry: original.resolvedGeometry,
            defaultSpeedMultiplier: original.defaultSpeedMultiplier,
            source: original.source
        )
        routes[index] = renamed
        try replaceAll(routes)
        return renamed
    }

    @discardableResult
    func duplicate(id: String, now: Date = Date()) throws -> LocationRouteDocument {
        var routes = try load()
        guard let original = routes.first(where: { $0.id == id }) else {
            throw RouteDocumentError.documentNotFound
        }
        let copy = try LocationRouteDocument(
            name: "\(original.name) Copy",
            createdAt: now,
            modifiedAt: now,
            movementMode: original.movementMode,
            anchors: original.anchors,
            resolvedGeometry: original.resolvedGeometry,
            defaultSpeedMultiplier: original.defaultSpeedMultiplier,
            source: RouteDocumentSourceMetadata(
                client: original.source?.client,
                originalIdentifier: original.id
            )
        )
        routes.append(copy)
        try replaceAll(routes)
        return copy
    }

    func delete(id: String) throws {
        var routes = try load()
        guard let index = routes.firstIndex(where: { $0.id == id }) else {
            throw RouteDocumentError.documentNotFound
        }
        routes.remove(at: index)
        try replaceAll(routes)
    }

    func replaceAll(_ routes: [LocationRouteDocument]) throws {
        let envelope = try LocationRouteLibraryFile(routes: routes)
        let data = try RouteDocumentCodec.makeEncoder().encode(envelope)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

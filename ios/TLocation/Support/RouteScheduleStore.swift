import Combine
import Foundation

private struct RouteScheduleLibraryFile: Codable {
    static let currentVersion = 1
    let version: Int
    var schedules: [RouteScheduleDocument]

    init(version: Int = Self.currentVersion, schedules: [RouteScheduleDocument]) throws {
        guard version == Self.currentVersion else {
            throw RouteScheduleValidationError.unsupportedVersion(version)
        }
        self.version = version
        self.schedules = schedules
    }
}

actor RouteScheduleStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationStore() -> RouteScheduleStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationSuite", isDirectory: true)
        return RouteScheduleStore(fileURL: root.appendingPathComponent("route-schedules-v1.json"))
    }

    func load() throws -> [RouteScheduleDocument] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = RouteDocumentCodec.makeDecoder()
        let envelope = try decoder.decode(RouteScheduleLibraryFile.self, from: data)
        guard envelope.version == RouteScheduleLibraryFile.currentVersion else {
            throw RouteScheduleValidationError.unsupportedVersion(envelope.version)
        }
        return envelope.schedules
    }

    func save(_ schedule: RouteScheduleDocument) throws {
        var schedules = try load()
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        try replaceAll(schedules)
    }

    func delete(id: String) throws {
        var schedules = try load()
        schedules.removeAll { $0.id == id }
        try replaceAll(schedules)
    }

    private func replaceAll(_ schedules: [RouteScheduleDocument]) throws {
        let envelope = try RouteScheduleLibraryFile(schedules: schedules)
        let data = try RouteDocumentCodec.makeEncoder().encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

@MainActor
final class RouteScheduleLibrary: ObservableObject {
    static let shared = RouteScheduleLibrary(store: .applicationStore())

    @Published private(set) var schedules: [RouteScheduleDocument] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store: RouteScheduleStore

    init(store: RouteScheduleStore) {
        self.store = store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            schedules = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ schedule: RouteScheduleDocument) async -> Bool {
        do {
            try await store.save(schedule)
            schedules = try await store.load()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(id: String) async {
        do {
            try await store.delete(id: id)
            schedules = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

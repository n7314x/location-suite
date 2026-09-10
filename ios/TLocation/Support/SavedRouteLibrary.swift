//
//  SavedRouteLibrary.swift
//  TLocation
//

import Foundation

@MainActor
final class SavedRouteLibrary: ObservableObject {
    static let shared = SavedRouteLibrary(store: .applicationStore())

    @Published private(set) var routes: [LocationRouteDocument] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store: RouteDocumentStore

    init(store: RouteDocumentStore) {
        self.store = store
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            routes = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ route: LocationRouteDocument) async -> Bool {
        do {
            try await store.save(route)
            routes = try await store.load()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importDocument(_ data: Data) async -> Bool {
        do {
            let route = try RouteDocumentCodec.decode(data)
            try await store.save(route)
            routes = try await store.load()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func rename(id: String, name: String) async {
        do {
            _ = try await store.rename(id: id, to: name)
            routes = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicate(id: String) async {
        do {
            _ = try await store.duplicate(id: id)
            routes = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) async {
        do {
            try await store.delete(id: id)
            routes = try await store.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

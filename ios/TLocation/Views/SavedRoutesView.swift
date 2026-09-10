//
//  SavedRoutesView.swift
//  TLocation
//

import SwiftUI
import UniformTypeIdentifiers

private struct RouteJSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw RouteDocumentError.malformedJSON
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum SavedRouteSort: String, CaseIterable, Identifiable {
    case recent
    case name
    var id: Self { self }
}

private enum SavedRoutePendingAlert {
    case rename(id: String)
    case error(message: String)

    var title: String {
        switch self {
        case .rename: return String(localized: "Rename Route")
        case .error: return String(localized: "Route Error")
        }
    }
}

struct SavedRoutesView: View {
    @ObservedObject var library: SavedRouteLibrary
    let onLoad: (LocationRouteDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sort: SavedRouteSort = .recent
    @State private var isImporting = false
    @State private var exportDocument: RouteJSONFileDocument?
    @State private var exportFilename = "location-route.json"
    @State private var isExporting = false
    @State private var pendingAlert: SavedRoutePendingAlert?
    @State private var renameText = ""

    private var displayedRoutes: [LocationRouteDocument] {
        switch sort {
        case .recent:
            return library.routes.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            return library.routes.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.isLoading && library.routes.isEmpty {
                    ProgressView("Loading routes…")
                } else if library.routes.isEmpty {
                    ContentUnavailableView(
                        "No Saved Routes",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("Create a route on the map, then choose Save Route from its menu.")
                    )
                } else {
                    List(displayedRoutes) { route in
                        Button {
                            onLoad(route)
                            dismiss()
                        } label: {
                            routeRow(route)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { routeMenu(route) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await library.delete(id: route.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Saved Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            Text("Recent").tag(SavedRouteSort.recent)
                            Text("Name").tag(SavedRouteSort.name)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Route", systemImage: "square.and.arrow.down")
                    }
                    Button("Done") { dismiss() }
                }
            }
            .task { await library.reload() }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task { _ = await library.importDocument(data) }
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                library.errorMessage = error.localizedDescription
            }
        }
        .alert(
            pendingAlert?.title ?? "",
            isPresented: Binding(
                get: { pendingAlert != nil },
                set: { if !$0 { pendingAlert = nil } }
            ),
            presenting: pendingAlert
        ) { alert in
            switch alert {
            case .rename(let id):
                TextField("Name", text: $renameText)
                Button("Rename") {
                    let name = renameText
                    pendingAlert = nil
                    Task { await library.rename(id: id, name: name) }
                }
                Button("Cancel", role: .cancel) { pendingAlert = nil }
            case .error:
                Button("OK", role: .cancel) {
                    library.errorMessage = nil
                    pendingAlert = nil
                }
            }
        } message: { alert in
            switch alert {
            case .rename:
                Text("Enter a new name for this route.")
            case .error(let message):
                Text(message)
            }
        }
        .onChange(of: library.errorMessage) { _, message in
            if let message { pendingAlert = .error(message: message) }
        }
    }

    private func routeRow(_ route: LocationRouteDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: route.movementMode.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(route.movementMode.title)
                    Text("•")
                    Text(Self.formattedDistance(route.distance))
                    Text("•")
                    Text(Self.formattedDuration(route.estimatedTravelTime))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func routeMenu(_ route: LocationRouteDocument) -> some View {
        Button {
            renameText = route.name
            pendingAlert = .rename(id: route.id)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await library.duplicate(id: route.id) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            do {
                exportDocument = RouteJSONFileDocument(data: try RouteDocumentCodec.encode(route))
                exportFilename = Self.safeFilename(route.name)
                isExporting = true
            } catch {
                library.errorMessage = error.localizedDescription
            }
        } label: {
            Label("Export to Files", systemImage: "square.and.arrow.up")
        }
        if let data = try? RouteDocumentCodec.encode(route),
           let json = String(data: data, encoding: .utf8) {
            ShareLink(item: json) {
                Label("Share JSON", systemImage: "square.and.arrow.up.on.square")
            }
        }
        Divider()
        Button(role: .destructive) {
            Task { await library.delete(id: route.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "location-route" : safe) + ".json"
    }

    private static func formattedDistance(_ meters: Double) -> String {
        meters < 1_000
            ? String(format: "%.0f m", meters)
            : String(format: "%.2f km", meters / 1_000)
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        return minutes < 60
            ? "\(minutes) min"
            : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

extension RouteMovementMode {
    var title: String {
        switch self {
        case .walking: return String(localized: "Walking")
        case .cycling: return String(localized: "Cycling")
        case .driving: return String(localized: "Driving")
        }
    }

    var systemImage: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }
}

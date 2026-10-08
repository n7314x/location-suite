import SwiftUI

struct RouteSchedulesView: View {
    @ObservedObject var library: RouteScheduleLibrary
    let routes: [LocationRouteDocument]
    @ObservedObject var runner: RouteScheduleRunner
    let onRun: (RouteScheduleDocument) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var editingID: String?
    @State private var name = ""
    @State private var startEnabled = false
    @State private var startAt = Date().addingTimeInterval(60)
    @State private var steps: [RouteScheduleStep] = []
    @State private var errorMessage: String?
    @State private var jumpMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !library.schedules.isEmpty {
                    Section("Saved Schedules") {
                        ForEach(library.schedules) { schedule in
                            Button {
                                load(schedule)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(schedule.name)
                                        .foregroundStyle(.primary)
                                    Text(summary(schedule))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await library.delete(id: schedule.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section(editingID == nil ? "New Schedule" : "Edit Schedule") {
                    TextField("Schedule Name", text: $name)

                    Toggle("Start at a specific time", isOn: $startEnabled)
                    if startEnabled {
                        DatePicker(
                            "Start",
                            selection: $startAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("Route Timeline") {
                    if steps.isEmpty {
                        Text("Add saved routes in the order they should run.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(index + 1). \(routeName(step.routeID))")
                                Spacer()
                                Button(role: .destructive) {
                                    steps.removeAll { $0.id == step.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }

                            Stepper(
                                value: pauseBinding(for: step.id),
                                in: 0...1_440,
                                step: 1
                            ) {
                                Text(
                                    pauseMinutes(step) == 0
                                        ? "No pause after route"
                                        : "Pause \(pauseMinutes(step)) min after route"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        steps.move(fromOffsets: source, toOffset: destination)
                    }

                    Menu {
                        ForEach(routes) { route in
                            Button(route.name) {
                                if let step = try? RouteScheduleStep(routeID: route.id) {
                                    steps.append(step)
                                }
                            }
                        }
                    } label: {
                        Label("Add Saved Route", systemImage: "plus")
                    }
                    .disabled(routes.isEmpty)
                }

                if let jumpMessage {
                    Section("Route Jump Warning") {
                        Text(jumpMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Save Schedule") {
                        save()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        steps.isEmpty
                    )

                    Button {
                        run()
                    } label: {
                        Label(
                            startEnabled && startAt > Date() ? "Arm Schedule" : "Run Schedule",
                            systemImage: "play.circle.fill"
                        )
                    }
                    .disabled(
                        runner.isRunning ||
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        steps.isEmpty
                    )

                    if runner.isRunning {
                        Button("Cancel Active Schedule", role: .destructive) {
                            runner.cancel()
                        }
                    }
                }

                Section("Current Automation") {
                    Text(runnerDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Route Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await library.reload() }
        }
    }

    private func load(_ schedule: RouteScheduleDocument) {
        editingID = schedule.id
        name = schedule.name
        startEnabled = schedule.startAt != nil
        startAt = schedule.startAt ?? Date().addingTimeInterval(60)
        steps = schedule.steps
        errorMessage = nil
        updateJumpWarning(for: schedule)
    }

    private func makeDocument() throws -> RouteScheduleDocument {
        try RouteScheduleDocument(
            id: editingID ?? "schedule_" + UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased(),
            name: name,
            createdAt: library.schedules.first(where: { $0.id == editingID })?.createdAt ?? Date(),
            modifiedAt: Date(),
            startAt: startEnabled ? startAt : nil,
            steps: steps
        )
    }

    private func save() {
        do {
            let document = try makeDocument()
            _ = try RouteScheduleValidator.validate(document, routes: routes)
            updateJumpWarning(for: document)
            Task {
                if await library.save(document) {
                    editingID = document.id
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run() {
        do {
            let document = try makeDocument()
            let warnings = try RouteScheduleValidator.validate(document, routes: routes)
            jumpMessage = warningText(warnings)
            errorMessage = nil
            Task { _ = await library.save(document) }
            onRun(document)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateJumpWarning(for schedule: RouteScheduleDocument) {
        do {
            jumpMessage = warningText(
                try RouteScheduleValidator.validate(schedule, routes: routes)
            )
        } catch {
            jumpMessage = nil
        }
    }

    private func warningText(_ warnings: [RouteScheduleJumpWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map {
            let meters = Int($0.distance.rounded())
            return "\($0.fromRouteName) → \($0.toRouteName): \(meters) m jump"
        }.joined(separator: "\n")
    }

    private func routeName(_ id: String) -> String {
        routes.first(where: { $0.id == id })?.name ?? "Missing Route"
    }

    private func pauseMinutes(_ step: RouteScheduleStep) -> Int {
        Int((step.pauseAfter / 60).rounded())
    }

    private func pauseBinding(for id: String) -> Binding<Int> {
        Binding(
            get: {
                guard let step = steps.first(where: { $0.id == id }) else { return 0 }
                return Int((step.pauseAfter / 60).rounded())
            },
            set: { minutes in
                guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
                steps[index].pauseAfter = TimeInterval(minutes * 60)
            }
        )
    }

    private func summary(_ schedule: RouteScheduleDocument) -> String {
        let routeCount = schedule.steps.count
        let pause = schedule.steps.reduce(0) { $0 + $1.pauseAfter }
        let pauseMinutes = Int((pause / 60).rounded())
        if let startAt = schedule.startAt {
            return "\(routeCount) routes • \(pauseMinutes) min pauses • \(startAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(routeCount) routes • \(pauseMinutes) min pauses"
    }

    private var runnerDescription: String {
        switch runner.state {
        case .idle:
            return "No schedule is active."
        case .waitingForStart(let date):
            return "Waiting until \(date.formatted(date: .abbreviated, time: .shortened))."
        case .startingStep(let index, let total, let routeName):
            return "Starting \(index)/\(total): \(routeName)"
        case .playingStep(let index, let total, let routeName):
            return "Playing \(index)/\(total): \(routeName)"
        case .waitingAfterStep(let index, let total, let until):
            return "Route \(index)/\(total) complete. Holding location until \(until.formatted(date: .omitted, time: .shortened))."
        case .completed:
            return "Schedule completed. The final simulated location remains held."
        case .cancelled:
            return "Schedule automation was cancelled."
        case .failed(let message):
            return "Schedule failed: \(message)"
        }
    }
}

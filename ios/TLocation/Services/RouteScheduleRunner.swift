import Combine
import Foundation

enum RouteScheduleRunState: Equatable {
    case idle
    case waitingForStart(Date)
    case startingStep(index: Int, total: Int, routeName: String)
    case playingStep(index: Int, total: Int, routeName: String)
    case waitingAfterStep(index: Int, total: Int, until: Date)
    case completed
    case cancelled
    case failed(String)
}

@MainActor
final class RouteScheduleRunner: ObservableObject {
    @Published private(set) var state: RouteScheduleRunState = .idle

    private var task: Task<Void, Never>?
    private var ownsBackgroundActivity = false

    var isRunning: Bool {
        switch state {
        case .waitingForStart, .startingStep, .playingStep, .waitingAfterStep:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }

    func start(
        _ schedule: RouteScheduleDocument,
        routes: [LocationRouteDocument],
        playback: RoutePlaybackController,
        ownershipDidChange: @escaping () -> Void
    ) {
        guard !isRunning else { return }

        do {
            _ = try RouteScheduleValidator.validate(schedule, routes: routes)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        acquireBackgroundActivity()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.releaseBackgroundActivity()
                self.task = nil
            }

            do {
                if let startAt = schedule.startAt, startAt > Date() {
                    self.state = .waitingForStart(startAt)
                    try await self.sleep(until: startAt)
                }

                for (offset, step) in schedule.steps.enumerated() {
                    try Task.checkCancellation()

                    guard let document = byID[step.routeID] else {
                        throw RouteScheduleValidationError.missingRoute(step.routeID)
                    }

                    let route = try document.playbackRoute()
                    playback.setLoopMode(.off)
                    playback.setSpeedMultiplier(
                        document.defaultSpeedMultiplier,
                        mode: document.movementMode
                    )

                    self.state = .startingStep(
                        index: offset + 1,
                        total: schedule.steps.count,
                        routeName: document.name
                    )

                    await playback.play(route, ownershipDidChange: ownershipDidChange)

                    guard playback.state == .playing || playback.state == .starting else {
                        if case .error(let error) = playback.state {
                            throw RouteScheduleRuntimeError.playback(error.message)
                        }
                        throw RouteScheduleRuntimeError.playback("The route could not start.")
                    }

                    self.state = .playingStep(
                        index: offset + 1,
                        total: schedule.steps.count,
                        routeName: document.name
                    )

                    try await self.waitForCompletion(playback)

                    let isLast = offset == schedule.steps.count - 1
                    if !isLast, step.pauseAfter > 0 {
                        let until = Date().addingTimeInterval(step.pauseAfter)
                        self.state = .waitingAfterStep(
                            index: offset + 1,
                            total: schedule.steps.count,
                            until: until
                        )
                        try await self.sleep(until: until)
                    }
                }

                self.state = .completed
            } catch is CancellationError {
                self.state = .cancelled
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        releaseBackgroundActivity()
        if isRunning {
            state = .cancelled
        }
    }

    private func waitForCompletion(_ playback: RoutePlaybackController) async throws {
        while true {
            try Task.checkCancellation()

            switch playback.state {
            case .completed:
                return
            case .error(let error):
                throw RouteScheduleRuntimeError.playback(error.message)
            case .stopped:
                throw RouteScheduleRuntimeError.playback("The scheduled route was stopped.")
            case .idle, .ready:
                throw RouteScheduleRuntimeError.playback(
                    "Scheduled playback ended before the route completed."
                )
            case .starting, .playing, .paused, .connectionInterrupted, .clearing:
                break
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func sleep(until date: Date) async throws {
        while date > Date() {
            try Task.checkCancellation()
            let seconds = min(max(date.timeIntervalSinceNow, 0), 30)
            if seconds <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func acquireBackgroundActivity() {
        guard !ownsBackgroundActivity else { return }
        ownsBackgroundActivity = true
        BackgroundLocationManager.shared.requestStart()
    }

    private func releaseBackgroundActivity() {
        guard ownsBackgroundActivity else { return }
        ownsBackgroundActivity = false
        BackgroundLocationManager.shared.requestStop()
    }
}

private enum RouteScheduleRuntimeError: LocalizedError {
    case playback(String)

    var errorDescription: String? {
        switch self {
        case .playback(let message):
            return message
        }
    }
}

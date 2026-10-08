import Foundation
import SwiftUI
import UIKit

private enum SetupStep: Int, CaseIterable {
    case welcome, requirements, pairing, preparation, connection, ready

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .requirements: return "Before you begin"
        case .pairing: return "Pair this iPhone"
        case .preparation: return "Prepare your session"
        case .connection: return "Connect to this device"
        case .ready: return "Ready"
        }
    }
}

struct SetupExperienceView: View {
    let pairingExists: Bool
    let isReady: Bool
    let pairingImportError: String?
    let onImportPairing: () -> Void
    let onRetryConnection: () -> Void
    let onOpenLocalDevVPN: () -> Void
    let onOpenSettings: () -> Void
    let onFinish: (Bool) -> Void

    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var preparer = LocationSimulationSessionPreparer.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: SetupStep
    @State private var preparationOutcome: String?
    @State private var preparationFailed = false
    @State private var sessionOpen = LocationSimulationSession.isOpen

    init(
        pairingExists: Bool,
        isReady: Bool,
        pairingImportError: String?,
        startsAtConnection: Bool,
        onImportPairing: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onOpenLocalDevVPN: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onFinish: @escaping (Bool) -> Void
    ) {
        self.pairingExists = pairingExists
        self.isReady = isReady
        self.pairingImportError = pairingImportError
        self.onImportPairing = onImportPairing
        self.onRetryConnection = onRetryConnection
        self.onOpenLocalDevVPN = onOpenLocalDevVPN
        self.onOpenSettings = onOpenSettings
        self.onFinish = onFinish
        _step = State(initialValue: startsAtConnection ? .connection : .welcome)
    }

    private var recovery: SetupRecovery? {
        SetupRecovery.recommendation(trace: tunnel.lastColdBootstrap, warmSessionOpen: sessionOpen)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    header
                    progress
                    stepContent
                        .id(step)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                    navigation
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 22)
                .padding(.top, 30)
                .padding(.bottom, 46)
                .frame(maxWidth: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationSimulationSessionChanged)) { _ in
            sessionOpen = LocationSimulationSession.isOpen
        }
        .onChange(of: pairingExists) { _, imported in
            if imported && step == .pairing { advance(to: .preparation) }
        }
        .onChange(of: isReady) { _, ready in
            if ready && step == .connection { advance(to: .ready) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.accentColor.gradient)
                Image(systemName: "location.north.circle.fill")
                    .foregroundStyle(.white).font(.title2)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Location Suite").font(.headline)
                Text("DEVICE SETUP").font(.caption2.weight(.semibold))
                    .tracking(1.4).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Settings")
        }
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(SetupStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(height: 4)
            }
        }
        .accessibilityLabel("Setup step \(step.rawValue + 1) of \(SetupStep.allCases.count): \(step.title)")
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: welcomeContent
        case .requirements: requirementsContent
        case .pairing: pairingContent
        case .preparation: preparationContent
        case .connection: connectionContent
        case .ready: readyContent
        }
    }

    private func introduction(_ eyebrow: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow).font(.caption2.weight(.bold)).tracking(1.4)
                .foregroundStyle(Color.accentColor)
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            Text(body).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 25) {
            introduction("WELCOME", "Your location workspace.",
                         "Location Suite connects to this iPhone so you can simulate a place, play a route, and understand the state of the session.")
            SetupGlassPanel {
                HStack(spacing: 17) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("One guided setup").font(.headline)
                        Text("Pairing, session preparation, connection, and developer services in a clear sequence.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var requirementsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction("REQUIREMENTS", "A few things first.",
                         "These components make the phone-local developer connection possible.")
            SetupGlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    requirement("iOS 17.4 or later", "The device and app must support the developer service path.", "iphone")
                    Divider()
                    requirement("Developer Mode", "Enable it in Settings > Privacy & Security if required.", "hammer")
                    Divider()
                    requirement("Pairing file", "Use a current pairing record created for this iPhone.", "doc.text")
                    Divider()
                    requirement("LocalDevVPN", "Connect its phone-local route before preparing or connecting.", "network")
                }
            }
            Text("A Wi-Fi cold connection is the known-good setup path. The initial DDI download needs a network connection. A retained session can continue on LTE; for a refused fresh LTE connection, this guide offers the documented Airplane Mode preparation flow.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func requirement(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
                .frame(width: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pairingContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction("PAIRING FILE", "Introduce this iPhone.",
                         "The pairing file lets RemotePairing authenticate with this device. Choose the file you created for this iPhone.")
            SetupGlassPanel {
                VStack(alignment: .leading, spacing: 15) {
                    Label(pairingExists ? "Pairing file imported" : "Waiting for pairing file",
                          systemImage: pairingExists ? "checkmark.seal.fill" : "doc.badge.plus")
                        .font(.headline)
                        .foregroundStyle(pairingExists ? Color.green : Color.primary)
                    if let pairingImportError {
                        Label(pairingImportError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(pairingExists ? "You can replace the file later in Settings." : "The file stays in this app's local storage for device connection.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button(pairingExists ? "Replace Pairing File" : "Import Pairing File", action: onImportPairing)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Link("How to create a pairing file", destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
                        .font(.footnote)
                }
            }
        }
    }

    private var preparationContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            introduction("PREPARE LTE SESSION", "Open a session before you simulate.",
                         "Preparation opens RemotePairing and LocationSimulation, then retains an idle session without setting a coordinate.")
            SetupGlassPanel {
                VStack(alignment: .leading, spacing: 15) {
                    SetupStatusRow(title: "LocalDevVPN route", detail: "Connect LocalDevVPN first.",
                                   complete: tunnel.endpointReachability == .reachable || tunnel.isConnected || sessionOpen,
                                   working: tunnel.endpointReachability == .checking)
                    SetupStatusRow(title: "Idle developer session", detail: sessionOpen ? "Session open and retained." : "Ready to prepare.",
                                   complete: sessionOpen, working: preparer.isPreparing)
                    if preparer.isPreparing {
                        Text("Opening transport and simulation service…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let preparationOutcome {
                        Label(preparationOutcome, systemImage: preparationFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(preparationFailed ? .orange : .green)
                    }
                    Button(action: prepareSession) {
                        if preparer.isPreparing {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(sessionOpen ? "Session Ready" : "Prepare LTE Session", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!pairingExists || sessionOpen || preparer.isPreparing || LocationSimulationSession.isActive)
                    if !tunnel.isConnected && !sessionOpen {
                        Button("Open LocalDevVPN", action: onOpenLocalDevVPN)
                            .buttonStyle(.bordered)
                    }
                }
            }
            Text("If a fresh connection is refused on LTE (TCP connect, errno 61), keep LocalDevVPN connected, turn on Airplane Mode, return here and prepare the session. Turn Airplane Mode off after it succeeds. Location Suite cannot change these network settings itself.")
                .font(.footnote).foregroundStyle(.secondary)
            if preparationFailed, let recovery {
                recoveryPanel(recovery)
            }
            SetupDiagnosticsView(sessionOpen: sessionOpen)
        }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            introduction("DEVICE CONNECTION", "See every layer come online.",
                         "The connection, developer image, and simulation service have separate states so you can see exactly where setup stops.")
            SetupGlassPanel {
                VStack(alignment: .leading, spacing: 13) {
                    SetupStatusRow(title: "Local route ready", detail: "LocalDevVPN endpoint",
                                   complete: tunnel.endpointReachability == .reachable || tunnel.isConnected || sessionOpen,
                                   working: tunnel.endpointReachability == .checking)
                    SetupStatusRow(title: "RemotePairing connected", detail: "Phone-local transport",
                                   complete: tunnel.isConnected || sessionOpen,
                                   working: tunnel.endpointReachability == .checking)
                    SetupStatusRow(title: "Developer services ready", detail: "Service discovery and mount",
                                   complete: mounting.coolisMounted || sessionOpen,
                                   working: mounting.mountingThread != nil)
                    SetupStatusRow(title: "DDI ready", detail: "Developer Disk Image",
                                   complete: mounting.coolisMounted || sessionOpen,
                                   working: mounting.mountingThread != nil)
                    SetupStatusRow(title: "Simulation service session", detail: sessionOpen ? "Open" : "Opens on preparation or first simulation",
                                   complete: sessionOpen,
                                   working: preparer.isPreparing)
                }
            }
            if !pairingExists {
                recoveryPanel(SetupRecovery(
                    title: "A pairing file is needed",
                    explanation: "Import the pairing record for this iPhone to start connecting.",
                    action: .importPairingFile
                ))
            } else if let recovery, !isReady && tunnel.endpointReachability != .checking {
                recoveryPanel(recovery)
            } else if !isReady && tunnel.endpointReachability == .unknown {
                Button("Open LocalDevVPN", action: onOpenLocalDevVPN)
                    .buttonStyle(.borderedProminent)
            }
            SetupDiagnosticsView(sessionOpen: sessionOpen)
            if !isReady {
                Button("Retry Connection", action: onRetryConnection)
                    .buttonStyle(.bordered)
                    .disabled(!pairingExists || preparer.isPreparing || tunnel.endpointReachability == .checking)
            }
        }
    }

    private func recoveryPanel(_ recovery: SetupRecovery) -> some View {
        SetupGlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                Label(recovery.title, systemImage: "exclamationmark.circle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(recovery.explanation).font(.subheadline).foregroundStyle(.secondary)
                Button(recovery.action.title) { perform(recovery.action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(preparer.isPreparing)
            }
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction("SETUP COMPLETE", "You're ready to simulate.",
                         "The device connection is ready. Choose a location or create a route on the map.")
            SetupGlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Connection ready", systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text(sessionOpen ? "An idle simulation service session is open." : "RemotePairing and DDI are ready. The simulation service opens when you start.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Choose Location") { onFinish(false) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Create Route") { onFinish(true) }
                        .buttonStyle(.bordered).controlSize(.large)
                    Button("Open Map") { onFinish(false) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            if step != .welcome && step != .ready {
                Button("Back") { advance(to: SetupStep(rawValue: step.rawValue - 1) ?? .welcome) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer()
            switch step {
            case .welcome, .requirements:
                Button("Continue") { advance(to: SetupStep(rawValue: step.rawValue + 1) ?? .pairing) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .pairing:
                Button("Continue") { advance(to: .preparation) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!pairingExists)
            case .preparation:
                Button(sessionOpen ? "Continue to Connection" : "Continue without Preparation") {
                    advance(to: .connection)
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!pairingExists || preparer.isPreparing)
            case .connection:
                Button("Continue") { advance(to: .ready) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!isReady)
            case .ready:
                EmptyView()
            }
        }
    }

    private func advance(to next: SetupStep) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
            step = next
        }
        Haptics.selection()
    }

    private func prepareSession() {
        guard pairingExists, !preparer.isPreparing, !LocationSimulationSession.isActive else { return }
        preparationOutcome = nil
        Task { @MainActor in
            let outcome = await preparer.prepare()
            switch outcome {
            case .ready:
                sessionOpen = LocationSimulationSession.isOpen
                preparationFailed = false
                preparationOutcome = "Session ready. If you enabled Airplane Mode, you can turn it off."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failed(let result):
                preparationFailed = true
                let failure = result.coldBootstrapTrace?.failure
                preparationOutcome = failure.map { "\($0.userTitle) at \($0.stage.displayName). Open details below." }
                    ?? "Session preparation failed (status \(result.statusCode))."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .superseded:
                preparationFailed = true
                preparationOutcome = "Another location or session action took priority."
            }
        }
    }

    private func perform(_ action: SetupRecoveryAction) {
        switch action {
        case .prepareLTESession: advance(to: .preparation)
        case .openLocalDevVPN: onOpenLocalDevVPN()
        case .importPairingFile: advance(to: .pairing); onImportPairing()
        case .openDeveloperSettings: onOpenSettings()
        case .retryConnection: onRetryConnection()
        }
    }
}

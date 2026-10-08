import Foundation
import SwiftUI

struct SetupDiagnosticsView: View {
    let sessionOpen: Bool
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared
    @ObservedObject private var keeper = DeviceRoutePlaybackActivityManager.shared.sessionKeeper
    @State private var detailsExpanded = false

    init(sessionOpen: Bool) {
        self.sessionOpen = sessionOpen
    }

    var body: some View {
        DisclosureGroup("Technical details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                detail("Network", tunnel.underlyingNetwork.rawValue)
                detail("Endpoint", tunnel.endpointReachability.rawValue)
                detail("Target", "\(DeviceConnectionContext.targetIPAddress):49152")
                detail("RemotePairing", tunnel.isConnected || sessionOpen ? "Connected" : "Not connected")
                detail("DDI", mounting.coolisMounted ? "Ready" : "Not ready")
                detail("Simulation session", sessionOpen ? "Open" : "Closed")
                detail("Simulation active", LocationSimulationSession.isActive ? "Yes" : "No")
                detail("Warm session", keeper.isIdleKeeperActive ? "Idle and retained" : keeper.state.rawValue)
                if let trace = tunnel.lastColdBootstrap {
                    detail("Cold bootstrap stage", trace.finalStage.displayName)
                    detail("Result", trace.resultDescription)
                    detail("Retries", String(trace.retryCount))
                    if let failure = trace.failure {
                        detail("Failure category", failure.category.displayName)
                        detail("Status", String(failure.statusCode))
                        detail("errno", failure.errno.map(String.init) ?? "Not available")
                        Text(failure.detail).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !trace.measurements.isEmpty {
                        detail("Stages", trace.measurements.map { measurement in
                            let elapsed = measurement.elapsed.map { String(format: "%.3fs", $0) } ?? "combined"
                            return "#\(measurement.attempt) \(measurement.stage.displayName): \(elapsed)"
                        }.joined(separator: "\n"))
                    }
                }
            }
            .padding(.top, 11)
        }
        .font(.subheadline)
        .tint(.primary)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.caption)
    }

}

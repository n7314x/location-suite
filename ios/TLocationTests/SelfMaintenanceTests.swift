import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import LocationSuiteCore
#else
@testable import TLocation
#endif

private final class FakeSecretStorage: SecretStorage, @unchecked Sendable {
    var values: [String: Data] = [:]

    func data(for account: String) throws -> Data? { values[account] }
    func set(_ data: Data, for account: String) throws { values[account] = data }
    func remove(account: String) throws { values.removeValue(forKey: account) }
}

struct SelfMaintenancePolicyTests {
    @Test func expiryThresholdStartsAt72Hours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base = SigningRefreshHistory.empty
        let decision: (TimeInterval) -> SigningAutoRefreshDecision = { remaining in
            SigningAutoRefreshPolicy.decision(
                enabled: true,
                expirationDate: now.addingTimeInterval(remaining),
                checkedAt: now,
                trustWindow: 6 * 60 * 60,
                hasAccountSessionOrRememberedPassword: true,
                hasSafeDeviceTransport: true,
                simulationActive: false,
                history: base,
                now: now
            )
        }
        #expect(decision(72 * 60 * 60 + 1) == .notDue)
        #expect(decision(72 * 60 * 60) == .attempt)
    }

    @Test func autoRefreshUsesCooldownAfterFailure() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = SigningRefreshHistory(
            lastAttempt: now.addingTimeInterval(-60),
            lastFailureCategory: .grandSlamUnavailable
        )
        #expect(SigningAutoRefreshPolicy.decision(
            enabled: true,
            expirationDate: now.addingTimeInterval(24 * 60 * 60),
            checkedAt: now,
            trustWindow: 6 * 60 * 60,
            hasAccountSessionOrRememberedPassword: true,
            hasSafeDeviceTransport: true,
            simulationActive: false,
            history: history,
            now: now
        ) == .cooldown)
    }

    @Test func onlyAnActualLaterDeviceExpiryPassesVerification() {
        let before = Date(timeIntervalSince1970: 100)
        let after = Date(timeIntervalSince1970: 200)
        #expect(SigningRefreshVerifier.verify(before: before, after: after) == .verified(before: before, after: after))
        #expect(SigningRefreshVerifier.verify(before: before, after: before) == .didNotIncrease(before: before, after: before))
        #expect(SigningRefreshVerifier.verify(before: nil, after: after) == .missingBefore)
        #expect(SigningRefreshVerifier.verify(before: before, after: nil) == .missingAfter)
    }

    @Test func failureDoesNotOverwriteLastGoodExpiryOrSuccess() {
        let oldSuccess = Date(timeIntervalSince1970: 1_000)
        let goodExpiry = Date(timeIntervalSince1970: 2_000)
        let previous = SigningRefreshHistory(
            lastAttempt: oldSuccess,
            lastSuccess: oldSuccess,
            actualExpiryBefore: Date(timeIntervalSince1970: 1_500),
            actualExpiryAfter: goodExpiry
        )
        let failed = SigningRefreshHistoryReducer.failure(
            previous: previous,
            attemptedAt: Date(timeIntervalSince1970: 1_100),
            category: .grandSlamUnavailable,
            observedBefore: nil
        )
        #expect(failed.lastSuccess == oldSuccess)
        #expect(failed.actualExpiryAfter == goodExpiry)
        #expect(failed.lastFailureCategory == .grandSlamUnavailable)
    }

    @Test func appleOutagePreservesWorkingState() {
        let goodExpiry = Date(timeIntervalSince1970: 2_000)
        let previous = SigningRefreshHistory(lastSuccess: Date(timeIntervalSince1970: 1_000), actualExpiryAfter: goodExpiry)
        let failed = SigningRefreshHistoryReducer.failure(
            previous: previous,
            attemptedAt: Date(timeIntervalSince1970: 1_100),
            category: .anisetteUnavailable,
            observedBefore: nil
        )
        #expect(failed.actualExpiryAfter == goodExpiry)
        #expect(failed.lastSuccess == previous.lastSuccess)
    }

    @Test func certificatePolicyReusesAndNeverRevokes() {
        #expect(CertificateReusePolicy.action(hasMatchingIdentity: true, hasCapacity: false) == .reuseExisting)
        #expect(CertificateReusePolicy.action(hasMatchingIdentity: false, hasCapacity: true) == .create)
        #expect(CertificateReusePolicy.action(hasMatchingIdentity: false, hasCapacity: false) == .stopAtLimit)
    }

    @Test func twoFactorStateMachineSupportsSubmitAndCancellation() {
        let waiting = TwoFactorStateMachine.reduce(.idle, .requested)
        #expect(waiting == .waiting)
        #expect(TwoFactorStateMachine.reduce(waiting, .cancel) == .cancelled)
        let submitted = TwoFactorStateMachine.reduce(waiting, .codeSubmitted)
        #expect(TwoFactorStateMachine.reduce(submitted, .accepted) == .completed)
    }

    @Test func fakeSecretStorageRoundTripsAndDeletes() throws {
        let storage = FakeSecretStorage()
        let secret = Data("not-for-defaults".utf8)
        try storage.set(secret, for: "apple-password")
        #expect(try storage.data(for: "apple-password") == secret)
        try storage.remove(account: "apple-password")
        #expect(try storage.data(for: "apple-password") == nil)
    }

    @Test func operationGateRejectsDuplicateMaintenance() {
        let gate = MaintenanceOperationGate()
        #expect(gate.begin())
        #expect(!gate.begin())
        gate.end()
        #expect(gate.begin())
        gate.end()
    }

    @Test func activeSimulationBlocksAndWarmIdleSessionIsReused() {
        #expect(MaintenanceTransportPlanner.plan(
            warmSessionOpen: true,
            simulationActive: true,
            existingTunnelAvailable: true,
            cellular: true
        ) == .blockedBySimulation)
        #expect(MaintenanceTransportPlanner.plan(
            warmSessionOpen: true,
            simulationActive: false,
            existingTunnelAvailable: false,
            cellular: true
        ) == .reuseWarmSession)
    }

    @Test func transportPlannerNeverDestroysWarmSessionForRefresh() {
        let plan = MaintenanceTransportPlanner.plan(
            warmSessionOpen: true,
            simulationActive: false,
            existingTunnelAvailable: false,
            cellular: true
        )
        #expect(plan == .reuseWarmSession)
    }

    @Test func diagnosticRedactionRemovesKnownSecretsAndTokens() {
        let value = "password=hunter2 github_pat_ABC123 token=secret-value coordinates=40.1, -73.9"
        let redacted = SensitiveDiagnosticRedactor.redact(value, knownSecrets: ["hunter2"])
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("github_pat_ABC123"))
        #expect(!redacted.contains("secret-value"))
        #expect(!redacted.contains("40.1"))
    }

    @Test func reminderDatesAre72Then48Then24HoursBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = now.addingTimeInterval(8 * 24 * 60 * 60)
        let dates = SigningReminderSchedule.dates(expirationDate: expiry, now: now)
        #expect(dates == [72, 48, 24].map { expiry.addingTimeInterval(-Double($0) * 60 * 60) })
    }
}

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
    @Test func signingCorePanicCategoryDecodesWithoutCollapsingToUnknown() throws {
        let payload = #"{"category":"signingCorePanic","message":"Signing core panic during appleLogin."}"#
        let error = try JSONDecoder().decode(SelfMaintenanceError.self, from: Data(payload.utf8))
        #expect(error.category == .signingCorePanic)
        #expect(error.stage == nil)
        #expect(error.message == "Signing core panic during appleLogin.")
    }

    @Test func stageAwareFFIErrorDecodesAndRoundTrips() throws {
        let payload = #"{"category":"developerSessionFailed","stage":"developerSession","message":"Failed to get xcode token from Apple account"}"#
        let decoded = try JSONDecoder().decode(SelfMaintenanceError.self, from: Data(payload.utf8))
        #expect(decoded.category == .developerSessionFailed)
        #expect(decoded.stage == "developerSession")
        #expect(decoded.message == "Failed to get xcode token from Apple account")

        let roundTripped = try JSONDecoder().decode(
            SelfMaintenanceError.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped == decoded)
    }

    @Test func stageSpecificTechnicalDetailIsVisibleAndUseful() {
        let error = SelfMaintenanceError(
            category: .developerSessionFailed,
            stage: "developerSession",
            message: "Failed to get xcode token from Apple account"
        )
        #expect(error.userFacingSummary == "Could not create the Apple developer session.")
        #expect(error.technicalDetail == "Failed to get xcode token from Apple account")
        #expect(error.hasDistinctTechnicalDetail)
    }

    @Test func nestedTechnicalDetailPreservesSafeCauseLines() {
        let chain = "Failed to log in to Apple ID\nCause: GrandSlam returned HTTP 503"
        let error = SelfMaintenanceError(
            category: .grandSlamUnavailable,
            stage: "appleLogin",
            message: chain
        )
        #expect(error.userFacingSummary == "Apple signing services are temporarily unavailable.")
        #expect(error.technicalDetail == chain)
        #expect(error.hasDistinctTechnicalDetail)
        #expect(error.safeSignInLogMessage.contains(chain))
    }

    @Test func emptyErrorMessageGetsAUsefulFallback() {
        let error = SelfMaintenanceError(
            category: .developerSessionFailed,
            stage: "developerSession",
            message: "  \n"
        )
        #expect(error.technicalDetail == "Could not create the Apple developer session.")
        #expect(!error.hasDistinctTechnicalDetail)
    }

    @Test func signInDiagnosticAndLogLineRedactSecrets() {
        let raw = "person@example.com password=hunter2 token=opaque-value 123456 response body: private data"
        let error = SelfMaintenanceError(
            category: .developerSessionFailed,
            stage: "developerSession",
            message: SensitiveDiagnosticRedactor.sanitizedSingleLine(
                raw,
                knownSecrets: ["hunter2"]
            )
        )
        let values = [error.technicalDetail, error.safeSignInLogMessage]
        for value in values {
            #expect(!value.contains("person@example.com"))
            #expect(!value.contains("hunter2"))
            #expect(!value.contains("opaque-value"))
            #expect(!value.contains("123456"))
            #expect(!value.contains("private data"))
        }
        #expect(error.safeSignInLogMessage.contains("stage=developerSession"))
        #expect(error.safeSignInLogMessage.contains("category=developerSessionFailed"))
    }

    @Test func signInChainRedactionPreservesCausesAndSuppressesBodies() {
        let raw = """
        Failed to log in person@example.com
        Cause: authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
        Cause: token=opaque-value password=hunter2 code 123456
        Cause: password="two word secret"
        Cause: malformed response body: {"secret":"private"}
        """
        let chain = SensitiveDiagnosticRedactor.sanitizedChain(
            raw,
            knownSecrets: ["hunter2"]
        )
        #expect(chain.components(separatedBy: .newlines).count == 4)
        #expect(!chain.contains("person@example.com"))
        #expect(!chain.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!chain.contains("opaque-value"))
        #expect(!chain.contains("hunter2"))
        #expect(!chain.contains("two word secret"))
        #expect(!chain.contains("123456"))
        #expect(!chain.contains("private"))
        #expect(chain.contains("Cause: malformed"))
    }

    @Test func signInChainRedactionSuppressesPairingAndDeviceIdentifiers() {
        let raw = """
        Failed to parse pairing data: HostID=private
        Cause: device_id=short-device-id serial_number=short-serial dsid=1234567890
        """
        let chain = SensitiveDiagnosticRedactor.sanitizedChain(raw)
        #expect(chain.contains("Failed to parse"))
        #expect(!chain.contains("HostID"))
        #expect(!chain.contains("short-device-id"))
        #expect(!chain.contains("short-serial"))
        #expect(!chain.contains("1234567890"))
    }

    @Test func signInChainRedactionIsBounded() {
        let raw = (0..<20)
            .map { "Cause: context-\($0)-" + String(repeating: "x", count: 300) }
            .joined(separator: "\n")
        let chain = SensitiveDiagnosticRedactor.sanitizedChain(raw)
        #expect(chain.components(separatedBy: .newlines).count <= 8)
        #expect(chain.count <= 1_200)
        #expect(chain.components(separatedBy: .newlines).allSatisfy { $0.count <= 240 })
    }

    @Test func normalSignInSuccessPayloadStillDecodes() throws {
        let payload = #"{"anisetteEndpoint":"https://anisette.invalid","teams":[{"identifier":"TEAM123","name":"Personal Team","teamType":"Individual","status":"active"}]}"#
        let summary = try JSONDecoder().decode(AccountSignInSummary.self, from: Data(payload.utf8))
        #expect(summary.anisetteEndpoint == "https://anisette.invalid")
        #expect(summary.teams.map(\.identifier) == ["TEAM123"])
    }

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

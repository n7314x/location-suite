import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import LocationSuiteCore
#else
@testable import TLocation
#endif

private func classified(
    _ stage: ColdBootstrapStage,
    _ message: String,
    status: Int32 = 3,
    code: Int32 = 3,
    subcode: Int32 = 0
) -> LocationBootstrapError {
    ColdBootstrapErrorClassifier.classify(
        stage: stage,
        statusCode: status,
        ffi: LocationBootstrapFFIError(code: code, subcode: subcode, message: message)
    )
}

struct ColdBootstrapClassificationTests {
    @Test func refusalClassificationPreservesErrno() {
        let error = classified(.tcpConnect, "connect: Connection refused (os error 61)")
        #expect(error.category == .connectionRefused)
        #expect(error.errno == 61)
        #expect(error.statusCode == 3)
    }

    @Test func noRouteClassification() {
        #expect(classified(.tcpConnect, "connect: No route to host (os error 65)").category == .noRoute)
    }

    @Test func timeoutClassification() {
        #expect(classified(.tcpConnect, "operation timed out (os error 60)").category == .timeout)
    }

    @Test func connectionResetClassification() {
        #expect(classified(.tcpConnect, "Connection reset by peer", subcode: 54).category == .connectionReset)
    }

    @Test func pairingFailureClassification() {
        #expect(classified(.remotePairing, "pair verification rejected").category == .pairingRejected)
    }

    @Test func rsdFailureClassification() {
        #expect(classified(.rsdConnect, "channel closed", status: 9).category == .rsdFailed)
    }

    @Test func dvtFailureIsNotAutomaticallyCalledDDI() {
        #expect(classified(.locationSimulationChannel, "DVT channel unavailable", status: 10).category == .dvtFailed)
    }

    @Test func ddiFailureRequiresActualDDIEvidence() {
        #expect(classified(.locationSimulationChannel, "Developer Disk Image not mounted", status: 10).category == .ddiUnavailable)
    }

    @Test func coordinateFailureClassification() {
        #expect(classified(.coordinateSet, "service rejected request", status: 11).category == .coordinateSetFailed)
    }

    @Test func successfulStageSequenceReachesReadyInOrder() {
        let measurements = ColdBootstrapStageSequence.successful.map {
            ColdBootstrapStageMeasurement(attempt: 1, stage: $0, elapsed: nil)
        }
        #expect(ColdBootstrapStageSequence.isSuccessful(measurements))
    }
}

struct ColdBootstrapRecoveryTests {
    @Test func noRouteAndTimeoutUseTheFullBoundedSchedule() {
        let expected = [0.150, 0.300, 0.600, 1.200]
        #expect(ColdBootstrapRecoveryPolicy.retryDelays(for: .noRoute, underlyingNetwork: "Cellular") == expected)
        #expect(ColdBootstrapRecoveryPolicy.retryDelays(for: .timeout, underlyingNetwork: "Wi-Fi") == expected)
    }

    @Test func stableCellularRefusalStopsAfterOneRetry() {
        #expect(ColdBootstrapRecoveryPolicy.retryDelays(
            for: .connectionRefused,
            underlyingNetwork: "Cellular"
        ) == [0.150])
    }

    @Test func pathChangeAndUserActionPermitRetryAgain() {
        var gate = ColdBootstrapRetryGate()
        gate.recordFinalFailure(.connectionRefused, underlyingNetwork: "Cellular")
        #expect(gate.blocksAutomaticRetry)
        gate.meaningfulEvent(.pathChanged)
        #expect(!gate.blocksAutomaticRetry)
        gate.recordFinalFailure(.connectionRefused, underlyingNetwork: "Cellular")
        gate.meaningfulEvent(.userRetry)
        #expect(!gate.blocksAutomaticRetry)
    }

    @Test func nonTransientFailuresDoNotRetry() {
        for category in [
            ColdBootstrapFailureCategory.pairingRejected,
            .dvtFailed,
            .ddiUnavailable,
            .coordinateSetFailed,
        ] {
            #expect(ColdBootstrapRecoveryPolicy.retryDelays(
                for: category,
                underlyingNetwork: "Cellular"
            ).isEmpty)
        }
    }

    @Test func warmSessionSkipsColdBootstrapAndDisposableProbe() {
        #expect(!ColdBootstrapSafetyPolicy.shouldStartColdBootstrap(
            warmSessionOpen: true,
            warmSessionMaintained: true
        ))
        #expect(!ColdBootstrapSafetyPolicy.permitsDisposableTCPProbe)
        #expect(ColdBootstrapSafetyPolicy.shouldStartColdBootstrap(
            warmSessionOpen: false,
            warmSessionMaintained: false
        ))
    }

    @Test func staleFailureCannotReplaceNewerSuccessfulTrace() {
        #expect(ColdBootstrapTraceOrdering.shouldReplace(currentSequence: 20, with: 21))
        #expect(!ColdBootstrapTraceOrdering.shouldReplace(currentSequence: 21, with: 20))
    }
}

struct ColdBootstrapPrivacyTests {
    @Test func diagnosticsRemoveCoordinatesPairingPathsAndSecrets() {
        let raw = "failed at 40.440000, -79.990000 using /var/mobile/Documents/pairing.plist private_key=abc123"
        let sanitized = BootstrapDiagnosticPrivacy.sanitize(raw)
        #expect(!sanitized.contains("40.440000"))
        #expect(!sanitized.contains("pairing.plist"))
        #expect(!sanitized.contains("abc123"))
        #expect(sanitized.contains("<redacted coordinate>"))
    }
}

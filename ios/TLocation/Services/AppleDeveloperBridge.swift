import Combine
import Foundation
import LocationSelfMaintenance

final class TwoFactorPromptCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = TwoFactorPromptCoordinator()

    @Published private(set) var isPresenting = false
    @Published private(set) var state: TwoFactorState = .idle
    @Published private(set) var validationMessage: String?

    private let condition = NSCondition()
    private var response: String?
    private var cancelled = false

    private init() {}

    /// Called synchronously by Rust on the dedicated account queue. Only the
    /// published presentation state crosses to the main thread; the code stays
    /// in this condition variable long enough to be copied into Rust and is
    /// never logged or persisted.
    func waitForCode() -> String? {
        condition.lock()
        response = nil
        cancelled = false
        condition.unlock()

        DispatchQueue.main.async {
            self.state = TwoFactorStateMachine.reduce(.idle, .requested)
            self.validationMessage = nil
            self.isPresenting = true
        }

        condition.lock()
        while response == nil && !cancelled {
            condition.wait()
        }
        let code = cancelled ? nil : response
        response = nil
        condition.unlock()
        return code
    }

    func submit(_ value: String) {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            validationMessage = "Enter the six-digit verification code."
            return
        }
        condition.lock()
        response = code
        condition.signal()
        condition.unlock()
        state = TwoFactorStateMachine.reduce(state, .codeSubmitted)
        validationMessage = nil
        isPresenting = false
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.signal()
        condition.unlock()
        state = TwoFactorStateMachine.reduce(state, .cancel)
        validationMessage = nil
        isPresenting = false
    }

    func finish(success: Bool) {
        DispatchQueue.main.async {
            if success, self.state == .submitted {
                self.state = TwoFactorStateMachine.reduce(self.state, .accepted)
            } else if !success, self.state == .waiting {
                self.state = .cancelled
            }
            self.isPresenting = false
        }
    }
}

@_cdecl("locationSuiteTwoFactorCallback")
private func locationSuiteTwoFactorCallback(
    context: UnsafeMutableRawPointer?,
    output: UnsafeMutablePointer<CChar>?,
    capacity: Int
) -> Int32 {
    guard let context, let output, capacity > 1 else { return 0 }
    let coordinator = Unmanaged<TwoFactorPromptCoordinator>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard let code = coordinator.waitForCode() else { return 0 }
    let bytes = Array(code.utf8CString)
    guard bytes.count <= capacity else { return 0 }
    bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        output.initialize(from: baseAddress, count: buffer.count)
    }
    return 1
}

final class AppleDeveloperSessionHandle: @unchecked Sendable {
    fileprivate let raw: OpaquePointer

    fileprivate init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        ls_account_session_free(raw)
    }
}

struct AppleDeveloperSignInResult: Sendable {
    let session: AppleDeveloperSessionHandle
    let summary: AccountSignInSummary
}

enum AppleDeveloperBridge {
    static func signIn(
        appleID: String,
        password: String,
        anisetteEndpoints: [URL],
        storageDirectory: URL,
        timeout: TimeInterval,
        twoFactor: TwoFactorPromptCoordinator = .shared
    ) throws -> AppleDeveloperSignInResult {
        let endpoints = anisetteEndpoints.map(\.absoluteString)
        let endpointsData = try JSONEncoder().encode(endpoints)
        guard let endpointsJSON = String(data: endpointsData, encoding: .utf8) else {
            throw SelfMaintenanceError(category: .anisetteUnavailable, message: "The anisette endpoint list is invalid.")
        }

        var session: OpaquePointer?
        var summaryPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let callbackContext = Unmanaged.passUnretained(twoFactor).toOpaque()

        let status = appleID.withCString { appleIDPointer in
            password.withCString { passwordPointer in
                endpointsJSON.withCString { endpointPointer in
                    storageDirectory.path.withCString { storagePointer in
                        ls_apple_sign_in(
                            appleIDPointer,
                            passwordPointer,
                            endpointPointer,
                            storagePointer,
                            UInt32(timeout.rounded(.up)),
                            locationSuiteTwoFactorCallback,
                            callbackContext,
                            &session,
                            &summaryPointer,
                            &errorPointer
                        )
                    }
                }
            }
        }

        defer {
            if let summaryPointer { ls_string_free(summaryPointer) }
            if let errorPointer { ls_string_free(errorPointer) }
        }
        twoFactor.finish(success: status == 0)

        guard status == 0, let session, let summaryPointer else {
            throw decodeError(errorPointer, knownSecrets: [appleID, password])
        }
        let data = Data(String(cString: summaryPointer).utf8)
        do {
            let summary = try JSONDecoder().decode(AccountSignInSummary.self, from: data)
            return AppleDeveloperSignInResult(
                session: AppleDeveloperSessionHandle(raw: session),
                summary: summary
            )
        } catch {
            ls_account_session_free(session)
            throw SelfMaintenanceError(
                category: .developerSessionFailed,
                stage: "buildingResult",
                message: "The developer-session response could not be read."
            )
        }
    }

    static func selectTeam(_ identifier: String, session: AppleDeveloperSessionHandle) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = identifier.withCString {
            ls_account_select_team(session.raw, $0, &errorPointer)
        }
        defer { if let errorPointer { ls_string_free(errorPointer) } }
        guard status == 0 else { throw decodeError(errorPointer) }
    }

    static func refreshProfile(
        session: AppleDeveloperSessionHandle,
        device: MaintenanceDeviceIdentity,
        portalBundleIdentifier: String
    ) throws -> Data {
        var profile = LSByteBuffer(bytes: nil, length: 0)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = device.udid.withCString { udidPointer in
            device.name.withCString { namePointer in
                portalBundleIdentifier.withCString { bundlePointer in
                    ls_refresh_profile(
                        session.raw,
                        udidPointer,
                        namePointer,
                        bundlePointer,
                        &profile,
                        &errorPointer
                    )
                }
            }
        }
        defer {
            if let errorPointer { ls_string_free(errorPointer) }
            ls_byte_buffer_free(profile)
        }
        guard status == 0, let bytes = profile.bytes, profile.length > 0 else {
            throw decodeError(errorPointer)
        }
        return Data(bytes: bytes, count: profile.length)
    }

    private static func decodeError(
        _ pointer: UnsafeMutablePointer<CChar>?,
        knownSecrets: [String] = []
    ) -> SelfMaintenanceError {
        guard let pointer else {
            return SelfMaintenanceError(category: .unknown, message: "The self-maintenance operation failed.")
        }
        let payload = String(cString: pointer)
        guard let data = payload.data(using: .utf8),
              let error = try? JSONDecoder().decode(SelfMaintenanceError.self, from: data) else {
            return SelfMaintenanceError(category: .unknown, message: "The self-maintenance operation failed.")
        }
        let message = SensitiveDiagnosticRedactor.sanitizedChain(
            error.message,
            knownSecrets: knownSecrets,
            fallback: error.userFacingSummary
        )
        return SelfMaintenanceError(
            category: error.category,
            stage: error.stage,
            message: message
        )
    }
}

//
//  IdeviceFFIBridge.swift
//  TLocation
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import idevice

private enum IdeviceBridge {
    static func makeError(
        domain: String = "TLocation",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    /// Reads an FFI error for logging *without* freeing it, so the existing
    /// `idevice_error_free` call on each path stays exactly where it is and
    /// ownership is unchanged. Purely for diagnostics.
    static func detail(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?) -> String {
        guard let ffiError else { return "libidevice reported no detail" }
        let message = string(from: ffiError.pointee.message) ?? "no message"
        return "libidevice code \(ffiError.pointee.code): \(message)"
    }

    static func snapshot(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?) -> LocationBootstrapFFIError? {
        guard let ffiError else { return nil }
        return LocationBootstrapFFIError(
            code: ffiError.pointee.code,
            subcode: ffiError.pointee.sub_code,
            message: string(from: ffiError.pointee.message) ?? "libidevice reported no detail"
        )
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "TLocation"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let message = string(from: ffiError.pointee.message) ?? fallback
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "TLocation",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "TLocation",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func activeTunnelHandles(for context: JITEnableContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "Tunnel is not connected")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension JITEnableContext {
    func getMountedDeviceCount() throws -> Int {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { client in
                var devices: UnsafeMutablePointer<plist_t?>?
                var deviceCount = 0
                if let ffiError = image_mounter_copy_devices(client, &devices, &deviceCount) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch mounted devices")
                }

                if let devices {
                    for index in 0..<deviceCount {
                        plist_free(devices[index])
                    }
                    idevice_data_free(
                        UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                        UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                    )
                }

                return deviceCount
            }
        }
    }

    /// Every provisioning profile installed on this device, as raw CMS blobs.
    ///
    /// Read-only, and deliberately the *only* misagent call in the app: nothing
    /// here installs (`misagent_install`) or removes (`misagent_remove`) a
    /// profile. These are the profiles iOS itself validates against, which is why
    /// they are worth reading — unlike the bundle's `embedded.mobileprovision`,
    /// they move when SideStore refreshes the app.
    ///
    /// Ownership, straight from `idevice.h`:
    ///
    /// * `misagent_copy_all` returns an `IdeviceFfiError *` on failure and NULL on
    ///   success, so on failure the three out-params are never written. They are
    ///   `nil`/`0`-initialised here and the `defer` that frees them is installed
    ///   *after* the error check, so the failure path frees nothing that was
    ///   never handed over — only the error itself, via `consumeFFIError`.
    /// * On success it hands over two parallel arrays of `out_count` entries: the
    ///   profile buffers and their lengths. Both, and every buffer in them, are
    ///   freed by exactly one `misagent_free_profiles(profiles, lens, count)` —
    ///   documented as "Must only be called with values returned from
    ///   `misagent_copy_all`", so the individual buffers are never freed
    ///   separately and the call is skipped entirely unless both arrays came
    ///   back, which is the only shape that function is allowed to receive.
    /// * `Data(bytes:count:)` copies, so the returned values outlive the free.
    /// * The client handle is freed by `misagent_client_free` on every path,
    ///   through `withConnectedClient`'s `cleanup`.
    func fetchAllProvisioningProfiles() throws -> [Data] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                var profileLengths: UnsafeMutablePointer<Int>?
                var profileCount = 0

                if let ffiError = misagent_copy_all(misagentClient, &profilePointers, &profileLengths, &profileCount) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to fetch provisioning profiles",
                        domain: "profiles"
                    )
                }

                defer {
                    if let profilePointers, let profileLengths {
                        misagent_free_profiles(profilePointers, profileLengths, profileCount)
                    }
                }

                guard let profilePointers, let profileLengths else { return [] }

                var result: [Data] = []
                result.reserveCapacity(profileCount)

                for index in 0..<profileCount {
                    guard let bytes = profilePointers[index] else { continue }
                    result.append(Data(bytes: bytes, count: profileLengths[index]))
                }

                return result
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }

                defer {
                    if let uniqueChipIDPlist {
                        plist_free(uniqueChipIDPlist)
                    }
                }

                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                        manifestData.withUnsafeBytes { manifestBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                            image_mounter_mount_personalized_with_callback_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID,
                                progressCallback,
                                nil
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

struct WarmLocationSimulationFFIResult: Sendable {
    let succeeded: Bool
    let detail: String
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        // `location_simulation_new` borrows its RemoteServerClient. Release the
        // borrowing child first, then its server and RSD transport parents.
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        // Every destructive teardown goes through here — rebuild failures and
        // explicit Disconnect Session — so both service and activity retract.
        LocationSimulationSession.set(active: false)
        LocationSimulationSession.set(open: false)
    }
}

/// What the app currently holds on the device's location-simulation service:
/// whether a session is *open*, and whether anything is *maintaining* it.
///
/// `isOpen` is a lock-guarded mirror of
/// `LocationSimulationState.locationSimulation != nil`, maintained by the two
/// places that change it (a successful `location_simulation_new`, and
/// `LocationSimulationState.cleanup()`), both of which only ever run on
/// `LocationSimulationCommandQueue`. The handles themselves stay confined to
/// that queue; this exposes plain `Bool`s so code on any thread — notably the
/// scene-phase handler in `TLocationApp`, which runs on the main thread and
/// cannot block — can ask the question without touching a pointer.
///
/// `isMaintained` is the other half of the answer, owned by the process-wide
/// `LocationSimulationSessionKeeper`. It covers both an active producer and an
/// idle warm session whose heartbeat/background-location activity is running.
/// The two deliberately differ:
///
/// * open but not maintained — a handle exists but no lifecycle owner is
///   keeping the process/channel alive (for example an older external caller).
/// * maintained but not open — a producer has claimed ownership and is about to
///   build the first session. The foreground tunnel rebuild in `TLocationApp`
///   must stay out of that window, which is invisible to `isOpen` alone.
///
/// Both retractions post ``Notification/Name/locationSimulationSessionEnded`` so
/// the work that stands down while a simulation is in progress can run the
/// moment it is not, instead of waiting for another background → foreground
/// round trip. Posting is a strict edge (true → false), never a level, so it
/// cannot repeat.
enum LocationSimulationSession {
    private static let lock = NSLock()
    private static var open = false
    private static var active = false
    private static var maintained = false

    static var isOpen: Bool {
        LocationSimulationOwnership.shared.isSessionOpen
    }

    static var isMaintained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return maintained
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Called by the process-wide lifecycle manager as its single balanced
    /// long-lived activity starts and stops.
    static func setMaintained(_ newValue: Bool) {
        lock.lock()
        let didRetract = maintained && !newValue
        maintained = newValue
        lock.unlock()

        if didRetract { postSessionEnded() }
    }

    fileprivate static func set(open newValue: Bool) {
        lock.lock()
        let didChange = open != newValue
        let didClose = open && !newValue
        open = newValue
        lock.unlock()

        LocationSimulationOwnership.shared.setSessionOpen(newValue)
        if didChange { postSessionChanged() }
        if didClose { postSessionEnded() }
    }

    fileprivate static func set(active newValue: Bool) {
        lock.lock()
        let didChange = active != newValue
        active = newValue
        lock.unlock()

        if didChange { postSessionChanged() }
    }

    /// Posted off the lock (a notification handler must never run under it) and
    /// on the main thread, which is where every observer of it lives.
    private static func postSessionEnded() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .locationSimulationSessionEnded, object: nil)
        }
    }

    private static func postSessionChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .locationSimulationSessionChanged, object: nil)
        }
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "vn.truongkma.tlocation.location-sim", qos: .userInitiated)
}

/// Backward-compatible status-only entry point. New in-app callers use the
/// detailed form below so stage, errno, and bounded retry evidence are retained.
func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    simulate_location_detailed(
        deviceIP,
        latitude,
        longitude,
        pairingFile,
        underlyingNetwork: "Unknown"
    ).statusCode
}

func simulate_location_detailed(
    _ deviceIP: String,
    _ latitude: Double,
    _ longitude: Double,
    _ pairingFile: String,
    underlyingNetwork: String
) -> LocationSimulationAttemptResult {
    perform_location_simulation_bootstrap_detailed(
        deviceIP,
        pairingFile,
        underlyingNetwork: underlyingNetwork,
        operation: .coordinate(latitude: latitude, longitude: longitude)
    )
}

/// Opens and retains the complete phone-local LocationSimulation service stack
/// without ever setting a coordinate. Callers must serialize this on
/// `LocationSimulationCommandQueue` and transfer a current idle ownership lease
/// to the warm-session keeper after success.
func prepare_location_simulation_session_detailed(
    _ deviceIP: String,
    _ pairingFile: String,
    underlyingNetwork: String
) -> LocationSimulationAttemptResult {
    perform_location_simulation_bootstrap_detailed(
        deviceIP,
        pairingFile,
        underlyingNetwork: underlyingNetwork,
        operation: .prepareSession
    )
}

private enum LocationSimulationBootstrapOperation {
    case prepareSession
    case coordinate(latitude: Double, longitude: Double)

    var diagnosticOperation: ColdBootstrapOperation {
        switch self {
        case .prepareSession: return .sessionPreparation
        case .coordinate: return .coordinateSimulation
        }
    }
}

private func perform_location_simulation_bootstrap_detailed(
    _ deviceIP: String,
    _ pairingFile: String,
    underlyingNetwork: String,
    operation: LocationSimulationBootstrapOperation
) -> LocationSimulationAttemptResult {
    if let locationSimulation = LocationSimulationState.locationSimulation {
        guard case .coordinate(let latitude, let longitude) = operation else {
            // The retained handle is the prepared service session. Reusing it
            // must not issue even a coordinate-free service command: the
            // existing idle keeper already owns heartbeat validation.
            return LocationSimulationAttemptResult(
                statusCode: LocationSimulationStatus.ok,
                coldBootstrapTrace: nil
            )
        }

        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            // Not an error yet: the code below rebuilds the session from
            // scratch and either succeeds or logs why it did not. Worth a line
            // regardless, because a session that keeps dying mid-simulation is
            // invisible otherwise — every rebuild looks like a fresh start.
            LogManager.shared.addWarningLog(
                "simulate_location: the open session rejected the update (\(IdeviceBridge.detail(from: ffiError))); rebuilding it"
            )
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            LocationSimulationSession.set(active: true)
            // A warm update is deliberately absent from cold diagnostics. It is
            // stronger evidence than a fresh probe and must never be disrupted by one.
            return LocationSimulationAttemptResult(
                statusCode: LocationSimulationStatus.ok,
                coldBootstrapTrace: nil
            )
        }
    }

    let sequence = ColdBootstrapSequenceNumber.next()
    let timestamp = Date()
    let startedAt = Date()
    var measurements: [ColdBootstrapStageMeasurement] = []
    var retryCount = 0

    func result(
        statusCode: Int32,
        failure: LocationBootstrapError?
    ) -> LocationSimulationAttemptResult {
        LocationSimulationAttemptResult(
            statusCode: statusCode,
            coldBootstrapTrace: ColdBootstrapTrace(
                sequence: sequence,
                timestamp: timestamp,
                targetHost: deviceIP,
                targetPort: 49152,
                underlyingNetwork: underlyingNetwork,
                operation: operation.diagnosticOperation,
                measurements: measurements,
                retryCount: retryCount,
                totalElapsed: Date().timeIntervalSince(startedAt),
                failure: failure
            )
        )
    }

    func directFailure(
        stage: ColdBootstrapStage,
        statusCode: Int32,
        category: ColdBootstrapFailureCategory,
        detail: String,
        ffi: LocationBootstrapFFIError? = nil
    ) -> LocationBootstrapError {
        LocationBootstrapError(
            stage: stage,
            statusCode: statusCode,
            ffiCode: ffi?.code,
            ffiSubcode: ffi?.subcode,
            errno: ColdBootstrapErrorClassifier.errno(from: ffi),
            category: category,
            detail: BootstrapDiagnosticPrivacy.sanitize(detail)
        )
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        LocationSimulationState.cleanup()
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.invalidIP)): “\(deviceIP)” is not a valid IPv4 address. Check the target device IP in Settings."
        )
        let failure = directFailure(
            stage: .waitingForTunnel,
            statusCode: LocationSimulationStatus.invalidIP,
            category: .invalidTarget,
            detail: "The configured target is not a valid IPv4 address."
        )
        return result(statusCode: LocationSimulationStatus.invalidIP, failure: failure)
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        let ffi = IdeviceBridge.snapshot(from: pairingError)
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.pairingRead)): could not read the pairing file — \(BootstrapDiagnosticPrivacy.sanitize(ffi?.message ?? "no upstream detail"))"
        )
        idevice_error_free(pairingError)
        LocationSimulationState.cleanup()
        let failure = directFailure(
            stage: .remotePairing,
            statusCode: LocationSimulationStatus.pairingRead,
            category: .pairingFileUnreadable,
            detail: ffi?.message ?? "The pairing file could not be read.",
            ffi: ffi
        )
        return result(statusCode: LocationSimulationStatus.pairingRead, failure: failure)
    }

    guard let pairingHandle else {
        LocationSimulationState.cleanup()
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.pairingRead)): reading the pairing file reported success but returned no handle"
        )
        let failure = directFailure(
            stage: .remotePairing,
            statusCode: LocationSimulationStatus.pairingRead,
            category: .pairingFileUnreadable,
            detail: "Reading the pairing file returned no handle."
        )
        return result(statusCode: LocationSimulationStatus.pairingRead, failure: failure)
    }

    defer { rp_pairing_file_free(pairingHandle) }

    while true {
        let attempt = retryCount + 1
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .waitingForTunnel,
            elapsed: nil
        ))

        let providerStartedAt = Date()
        let providerError = RemotePairingHandshakeGate.withLock {
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        "TLocationSimulation",
                        pairingHandle,
                        nil,
                        nil,
                        &LocationSimulationState.adapter,
                        &LocationSimulationState.handshake
                    )
                }
            }
        }

        if let providerError {
            let ffi = IdeviceBridge.snapshot(from: providerError)
            let socketErrno = ColdBootstrapErrorClassifier.errno(from: ffi)
            let stage: ColdBootstrapStage = socketErrno == nil ? .remotePairing : .tcpConnect
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: stage,
                elapsed: Date().timeIntervalSince(providerStartedAt)
            ))
            let failure = ColdBootstrapErrorClassifier.classify(
                stage: stage,
                statusCode: LocationSimulationStatus.providerCreate,
                ffi: ffi
            )
            LogManager.shared.addErrorLog(
                "Cold bootstrap attempt \(attempt) failed at \(stage.displayName) for \(deviceIP):49152 — \(failure.detail)"
            )
            idevice_error_free(providerError)
            LocationSimulationState.cleanup()

            let delays = ColdBootstrapRecoveryPolicy.retryDelays(
                for: failure.category,
                underlyingNetwork: underlyingNetwork
            )
            guard retryCount < delays.count else {
                return result(statusCode: LocationSimulationStatus.providerCreate, failure: failure)
            }
            let delay = delays[retryCount]
            retryCount += 1
            LogManager.shared.addInfoLog(
                "Cold bootstrap retry \(retryCount) scheduled after \(Int(delay * 1_000)) ms for \(failure.category.displayName)."
            )
            Thread.sleep(forTimeInterval: delay)
            continue
        }

        guard LocationSimulationState.adapter != nil,
              LocationSimulationState.handshake != nil else {
            let failure = directFailure(
                stage: .remotePairing,
                statusCode: LocationSimulationStatus.providerCreate,
                category: .remotePairingFailed,
                detail: "RemotePairing reported success without returning complete transport handles."
            )
            LocationSimulationState.cleanup()
            return result(statusCode: LocationSimulationStatus.providerCreate, failure: failure)
        }

        // Upstream exposes tunnel_create_rppairing as one synchronous call. Its
        // success proves TCP connected and pairing authenticated, but does not
        // expose their timing boundary, so TCP is recorded without invented time.
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .tcpConnect,
            elapsed: nil
        ))
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .remotePairing,
            elapsed: Date().timeIntervalSince(providerStartedAt)
        ))

        let rsdStartedAt = Date()
        let remoteServerError = remote_server_connect_rsd(
            LocationSimulationState.adapter,
            LocationSimulationState.handshake,
            &LocationSimulationState.remoteServer
        )
        if let remoteServerError {
            let ffi = IdeviceBridge.snapshot(from: remoteServerError)
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: .rsdConnect,
                elapsed: Date().timeIntervalSince(rsdStartedAt)
            ))
            let failure = ColdBootstrapErrorClassifier.classify(
                stage: .rsdConnect,
                statusCode: LocationSimulationStatus.remoteServer,
                ffi: ffi
            )
            LogManager.shared.addErrorLog(
                "Cold bootstrap attempt \(attempt) failed at RSD — \(failure.detail)"
            )
            idevice_error_free(remoteServerError)
            LocationSimulationState.cleanup()
            let delays = ColdBootstrapRecoveryPolicy.retryDelays(
                for: failure.category,
                underlyingNetwork: underlyingNetwork
            )
            guard retryCount < delays.count else {
                return result(statusCode: LocationSimulationStatus.remoteServer, failure: failure)
            }
            let delay = delays[retryCount]
            retryCount += 1
            Thread.sleep(forTimeInterval: delay)
            continue
        }
        guard LocationSimulationState.remoteServer != nil else {
            let failure = directFailure(
                stage: .rsdConnect,
                statusCode: LocationSimulationStatus.remoteServer,
                category: .rsdFailed,
                detail: "RSD reported success without returning a RemoteServer handle."
            )
            LocationSimulationState.cleanup()
            return result(statusCode: LocationSimulationStatus.remoteServer, failure: failure)
        }
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .rsdConnect,
            elapsed: Date().timeIntervalSince(rsdStartedAt)
        ))

        let channelStartedAt = Date()
        let locationSimulationError = location_simulation_new(
            LocationSimulationState.remoteServer,
            &LocationSimulationState.locationSimulation
        )
        if let locationSimulationError {
            let ffi = IdeviceBridge.snapshot(from: locationSimulationError)
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: .locationSimulationChannel,
                elapsed: Date().timeIntervalSince(channelStartedAt)
            ))
            let failure = ColdBootstrapErrorClassifier.classify(
                stage: .locationSimulationChannel,
                statusCode: LocationSimulationStatus.locationSimulation,
                ffi: ffi
            )
            LogManager.shared.addErrorLog(
                "Cold bootstrap attempt \(attempt) failed opening DVT LocationSimulation — \(failure.detail)"
            )
            idevice_error_free(locationSimulationError)
            LocationSimulationState.cleanup()
            return result(statusCode: LocationSimulationStatus.locationSimulation, failure: failure)
        }
        guard LocationSimulationState.locationSimulation != nil else {
            let failure = directFailure(
                stage: .locationSimulationChannel,
                statusCode: LocationSimulationStatus.locationSimulation,
                category: .dvtFailed,
                detail: "DVT reported success without returning a LocationSimulation handle."
            )
            LocationSimulationState.cleanup()
            return result(statusCode: LocationSimulationStatus.locationSimulation, failure: failure)
        }
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .locationSimulationChannel,
            elapsed: Date().timeIntervalSince(channelStartedAt)
        ))

        // Confirmed against jkcoxson/idevice's Rust FFI implementation: this call
        // obtains `&mut (*server).0`; it does not consume the server's Box. Retain
        // the pointer and free it exactly once after the borrowing child.

        // The session handle now exists. Published here rather than after the
        // `location_simulation_set` below because from this point on there is
        // something to tear down: if the set fails, `cleanup()` retracts the flag on
        // its way out, so the two can never disagree.
        LocationSimulationSession.set(open: true)

        if case .prepareSession = operation {
            // Preparation deliberately stops here. In particular, do not call
            // location_simulation_set or manufacture a coordinateSet stage.
            LocationSimulationSession.set(active: false)
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: .ready,
                elapsed: nil
            ))
            LogManager.shared.addInfoLog(
                "prepare_location_simulation_session: cold bootstrap reached Ready on attempt \(attempt) without setting a coordinate"
            )
            return result(statusCode: LocationSimulationStatus.ok, failure: nil)
        }

        guard case .coordinate(let latitude, let longitude) = operation else {
            preconditionFailure("Unhandled location simulation bootstrap operation")
        }

        let coordinateStartedAt = Date()
        let locationSetError = location_simulation_set(
            LocationSimulationState.locationSimulation,
            latitude,
            longitude
        )
        if let locationSetError {
            let ffi = IdeviceBridge.snapshot(from: locationSetError)
            measurements.append(ColdBootstrapStageMeasurement(
                attempt: attempt,
                stage: .coordinateSet,
                elapsed: Date().timeIntervalSince(coordinateStartedAt)
            ))
            let failure = ColdBootstrapErrorClassifier.classify(
                stage: .coordinateSet,
                statusCode: LocationSimulationStatus.locationSet,
                ffi: ffi
            )
            // The coordinate is deliberately never written to the log.
            LogManager.shared.addErrorLog(
                "Cold bootstrap attempt \(attempt) failed setting the coordinate — \(failure.detail)"
            )
            idevice_error_free(locationSetError)
            LocationSimulationState.cleanup()
            return result(statusCode: LocationSimulationStatus.locationSet, failure: failure)
        }
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .coordinateSet,
            elapsed: Date().timeIntervalSince(coordinateStartedAt)
        ))

        LocationSimulationSession.set(active: true)
        measurements.append(ColdBootstrapStageMeasurement(
            attempt: attempt,
            stage: .ready,
            elapsed: nil
        ))

        // Only the freshly built session is logged. The warm early return above
        // stays silent, so this marks a user action or authoritative rebuild.
        LogManager.shared.addInfoLog(
            "simulate_location: cold bootstrap reached Ready on attempt \(attempt)"
        )

        return result(statusCode: LocationSimulationStatus.ok, failure: nil)
    }
}

/// Returns to real GPS while preserving the proven warm DVT/RSD transport and
/// LocationSimulation channel. Upstream waits for the clear reply and leaves
/// this handle valid for a later `set`.
func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        LogManager.shared.addErrorLog(
            "clear_simulated_location failed (code \(LocationSimulationStatus.locationClear)): there is no open location-simulation session to clear"
        )
        return LocationSimulationStatus.locationClear
    }

    if let ffiError = location_simulation_clear(locationSimulation) {
        LogManager.shared.addErrorLog(
            "clear_simulated_location failed (code \(LocationSimulationStatus.locationClear)): the device rejected the clear — \(IdeviceBridge.detail(from: ffiError))"
        )
        idevice_error_free(ffiError)
        // A failed real service operation is authoritative evidence that this
        // warm session is no longer usable.
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationClear
    }

    LocationSimulationSession.set(active: false)

    LogManager.shared.addInfoLog(
        "clear_simulated_location: the device accepted the clear; warm session retained"
    )

    return LocationSimulationStatus.ok
}

/// Idle-only keepalive for the already-open DVT LocationSimulation channel.
///
/// The upstream Rust client implements `clear` by calling
/// `stopLocationSimulation`, reading its reply, and retaining both the channel
/// and client. Repeating it while already on real GPS is therefore the smallest
/// operation that proves this exact channel is alive without ever supplying a
/// coordinate. Unlike the user-facing clear above, one failure does not destroy
/// the handles: the session keeper applies its deterministic transient-failure
/// threshold and calls `discard_stale_location_simulation_session` only after
/// the threshold is reached.
func heartbeat_warm_location_simulation_session() -> WarmLocationSimulationFFIResult {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return WarmLocationSimulationFFIResult(
            succeeded: false,
            detail: "There is no retained LocationSimulation handle."
        )
    }

    if let ffiError = location_simulation_clear(locationSimulation) {
        let detail = IdeviceBridge.detail(from: ffiError)
        idevice_error_free(ffiError)
        return WarmLocationSimulationFFIResult(succeeded: false, detail: detail)
    }

    // A heartbeat is only eligible while this is already false. Keep the
    // mirror authoritative even if a future upstream implementation changes.
    LocationSimulationSession.set(active: false)
    return WarmLocationSimulationFFIResult(succeeded: true, detail: "")
}

/// Destructive half of the idle heartbeat failure verdict. This must only be
/// called on `LocationSimulationCommandQueue` after its idle generation has
/// been revalidated.
func discard_stale_location_simulation_session() {
    LocationSimulationState.cleanup()
}

/// Intentionally destroys the warm connection. If a fake coordinate is active,
/// ask the device to restore real GPS first; resources are released either way.
func disconnect_location_simulation_session() -> Int32 {
    var result = LocationSimulationStatus.ok
    if LocationSimulationSession.isActive,
       let locationSimulation = LocationSimulationState.locationSimulation,
       let ffiError = location_simulation_clear(locationSimulation) {
        LogManager.shared.addErrorLog(
            "disconnect_location_simulation_session: clear failed before teardown — \(IdeviceBridge.detail(from: ffiError))"
        )
        idevice_error_free(ffiError)
        result = LocationSimulationStatus.locationClear
    }

    LocationSimulationState.cleanup()
    LogManager.shared.addInfoLog(
        result == LocationSimulationStatus.ok
            ? "disconnect_location_simulation_session: session disconnected"
            : "disconnect_location_simulation_session: session disconnected after clear failure"
    )
    return result
}

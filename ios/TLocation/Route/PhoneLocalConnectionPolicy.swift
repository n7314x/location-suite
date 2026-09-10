//
//  PhoneLocalConnectionPolicy.swift
//  TLocation
//

import Foundation

enum UnderlyingNetworkKind: String, Equatable, Sendable {
    case wifi = "Wi-Fi"
    case cellular = "Cellular"
    case other = "Other"
    case unavailable = "Unavailable"
    case unknown = "Unknown"
}

enum EndpointReachability: String, Equatable, Sendable {
    case unknown = "Unknown"
    case checking = "Checking"
    case reachable = "Yes"
    case unreachable = "No"
}

enum PhoneLocalConnectionFailureCategory: String, Equatable, Sendable {
    case invalidAddress = "Invalid target address"
    case noRoute = "No route to endpoint"
    case refused = "Endpoint refused connection"
    case timedOut = "Endpoint timed out"
    case pairing = "RemotePairing authentication"
    case service = "Developer service"
    case unknown = "Other"
}

/// Central policy: interface type is diagnostic context, never permission.
/// A cellular path is allowed to attempt and use RemotePairing exactly like a
/// Wi-Fi path; only the actual endpoint/handshake result decides readiness.
enum PhoneLocalConnectionPolicy {
    static func shouldAttemptConnection(
        pairingFilePresent: Bool,
        underlyingNetwork: UnderlyingNetworkKind
    ) -> Bool {
        pairingFilePresent
    }

    static func isReady(
        endpointReachability: EndpointReachability,
        remotePairingConnected: Bool
    ) -> Bool {
        endpointReachability == .reachable && remotePairingConnected
    }
}

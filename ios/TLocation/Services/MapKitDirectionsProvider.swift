//
//  MapKitDirectionsProvider.swift
//  TLocation
//

import CoreLocation
import Foundation
import MapKit

/// Apple Maps adapter for the platform-neutral directions resolver.
final class MapKitDirectionsProvider: RouteDirectionsProviding, @unchecked Sendable {
    func route(
        from start: RoutePoint,
        to end: RoutePoint,
        mode: RouteMovementMode
    ) async throws -> RouteDirectionsSegment {
        let request = MKDirections.Request()
        request.source = mapItem(for: start)
        request.destination = mapItem(for: end)
        request.transportType = transportType(for: mode)
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: {
            directions.cancel()
        }
        guard let route = response.routes.first else {
            throw RouteDirectionsError.noRoute(index: 0)
        }

        let polyline = route.polyline
        var coordinates = Array(
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(
            &coordinates,
            range: NSRange(location: 0, length: polyline.pointCount)
        )
        let points = try coordinates.map {
            try RoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        return RouteDirectionsSegment(
            points: points,
            expectedTravelTime: route.expectedTravelTime
        )
    }

    private func transportType(for mode: RouteMovementMode) -> MKDirectionsTransportType {
        switch mode {
        case .walking: return .walking
        case .cycling: return .cycling
        case .driving: return .automobile
        }
    }

    private func mapItem(for point: RoutePoint) -> MKMapItem {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        if #available(iOS 26, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }
}

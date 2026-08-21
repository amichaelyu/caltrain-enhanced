//
//  TravelTimeService.swift
//  caltrain-enhanced
//
//  Travel-time estimates to the station using the Apple Maps (MapKit) directions API.
//

import Foundation
import MapKit
import CoreLocation

struct TravelTimes: Codable, Equatable {
    let stationName: String
    let walkingMinutes: Int
    let bikingMinutes: Int
    let drivingMinutes: Int
    let distanceMeters: Double
    let timestamp: Date

    var distanceMiles: Double { distanceMeters * 0.000621371 }
}

final class TravelTimeService {
    static let shared = TravelTimeService()

    /// How long a cached result stays fresh. Apple Maps requests are rate-limited and
    /// costly for a widget, so we reuse recent results for the same station.
    private let cacheMaxAge: TimeInterval = 15 * 60

    // Typical urban cycling speed (~14.5 km/h). MKDirections has no cycling mode, so we
    // derive a biking estimate from the real walking-route distance returned by Apple Maps.
    private let cyclingSpeedMetersPerSecond = 4.0

    private func cacheKey(_ station: String) -> String { "travelTimes.\(station)" }

    /// Last cached travel times for a station, if still fresh.
    func cachedTravelTimes(for stationName: String) -> TravelTimes? {
        guard let data = SharedConstants.sharedDefaults?.data(forKey: cacheKey(stationName)),
              let times = try? JSONDecoder().decode(TravelTimes.self, from: data),
              times.stationName == stationName,
              Date().timeIntervalSince(times.timestamp) < cacheMaxAge
        else { return nil }
        return times
    }

    /// Fetches walking, driving and biking travel times from the origin to the station.
    /// Uses a fresh cached value when available unless `forceRefresh` is set.
    @discardableResult
    func travelTimes(from origin: CLLocationCoordinate2D,
                     to station: CaltrainStation,
                     forceRefresh: Bool = false) async -> TravelTimes? {
        if !forceRefresh, let cached = cachedTravelTimes(for: station.name) {
            return cached
        }

        async let walkRouteTask = route(from: origin, to: station.coordinate, transport: .walking)
        async let driveRouteTask = route(from: origin, to: station.coordinate, transport: .automobile)
        let (walkRoute, driveRoute) = await (walkRouteTask, driveRouteTask)

        guard walkRoute != nil || driveRoute != nil else { return nil }

        let distance = walkRoute?.distance ?? driveRoute?.distance ?? 0
        let walkSeconds = walkRoute?.expectedTravelTime ?? (distance / 1.35) // ~1.35 m/s walking
        let driveSeconds = driveRoute?.expectedTravelTime ?? (distance / 11.0) // ~40 km/h fallback
        let bikeSeconds = distance / cyclingSpeedMetersPerSecond

        let times = TravelTimes(
            stationName: station.name,
            walkingMinutes: minutes(walkSeconds),
            bikingMinutes: minutes(bikeSeconds),
            drivingMinutes: minutes(driveSeconds),
            distanceMeters: distance,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(times) {
            SharedConstants.sharedDefaults?.set(data, forKey: cacheKey(station.name))
        }
        return times
    }

    /// Route geometry for drawing the path to the station on a map. MKDirections has no
    /// cycling mode, so cycling reuses the walking path.
    func routeGeometry(from origin: CLLocationCoordinate2D,
                       to station: CaltrainStation,
                       mode: TravelMode) async -> MKRoute? {
        await route(from: origin,
                    to: station.coordinate,
                    transport: mode == .driving ? .automobile : .walking)
    }

    private func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    private func route(from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D,
                       transport: MKDirectionsTransportType) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = transport
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        let response = try? await directions.calculate()
        return response?.routes.first
    }
}

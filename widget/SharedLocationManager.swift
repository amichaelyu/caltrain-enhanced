//
//  SharedLocationManager.swift
//  widget
//
//  Created by Michael Yu on 6/14/25.
//
//  Single source of truth for location shared between the app and the widget.
//  The app requests location and writes the nearest station + coordinate into the
//  shared App Group container; the widget reads that cache (and may request a fresh
//  fix when it has authorization).
//

import Foundation
import CoreLocation
import Combine

final class SharedLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SharedLocationManager()

    /// How far the user must move before a fix is republished. A minute of walking is
    /// ~80 m, so anything finer changes no displayed number and only buys GPS jitter.
    private static let publishThresholdMeters: CLLocationDistance = 75

    /// Fixes vaguer than this are dropped — a 2 km-accurate cell-tower fix can name the
    /// wrong station outright.
    private static let worstUsableAccuracyMeters: CLLocationDistance = 500

    private let manager = CLLocationManager()
    private var defaults: UserDefaults? { SharedConstants.sharedDefaults }
    private var oneShotCompletion: ((CaltrainStation?) -> Void)?

    /// Last fix we published, kept separately from `userLocation` so the threshold check
    /// never reads a value that's mid-hop to the main queue.
    private var lastPublishedLocation: CLLocation?

    @Published private(set) var userLocation: CLLocation?
    @Published private(set) var nearestStation: CaltrainStation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Suppress callbacks while the user is stationary; this is the single biggest
        // power lever, since it lets the system idle the sensor between real moves.
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        nearestStation = getStoredNearestStation()
        userLocation = getStoredLocation()
        lastPublishedLocation = userLocation
    }

    // MARK: - App usage

    /// Requests permission if needed and asks for a one-shot location fix.
    func requestLocation() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    // MARK: - Widget usage

    func getStoredNearestStation() -> CaltrainStation? {
        guard let data = defaults?.data(forKey: SharedConstants.nearestStationKey),
              let station = try? JSONDecoder().decode(CaltrainStation.self, from: data)
        else { return nil }
        return station
    }

    func getStoredLocation() -> CLLocation? {
        guard let dict = defaults?.dictionary(forKey: SharedConstants.lastKnownLocationKey),
              let lat = dict["latitude"] as? Double,
              let lon = dict["longitude"] as? Double
        else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    func isLocationDataFresh(maxAge: TimeInterval = 600) -> Bool {
        guard let last = defaults?.object(forKey: SharedConstants.lastLocationUpdateKey) as? Date
        else { return false }
        return Date().timeIntervalSince(last) < maxAge
    }

    /// Widget entry point: prefers a fresh fix when authorized, otherwise the cached station.
    func getCurrentNearestStation(completion: @escaping (CaltrainStation?) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            oneShotCompletion = completion
            manager.requestLocation()
        default:
            completion(getStoredNearestStation())
        }
    }

    // MARK: - Persistence

    private func store(location: CLLocation, station: CaltrainStation?) {
        guard let station, let data = try? JSONEncoder().encode(station) else { return }
        defaults?.set(data, forKey: SharedConstants.nearestStationKey)
        defaults?.set(station.name, forKey: SharedConstants.lastKnownStationKey)
        defaults?.set(["latitude": location.coordinate.latitude,
                       "longitude": location.coordinate.longitude],
                      forKey: SharedConstants.lastKnownLocationKey)
        defaults?.set(Date(), forKey: SharedConstants.lastLocationUpdateKey)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let station = CaltrainStations.shared.nearestStation(to: location)

        // Republish only on real movement. Everything downstream — nearest station, the
        // departure board, the route map, the travel-time fetch — keys off `userLocation`,
        // so gating here is what keeps a drifting GPS from spraying network requests.
        if shouldPublish(location) {
            lastPublishedLocation = location
            store(location: location, station: station)
            DispatchQueue.main.async {
                self.userLocation = location
                self.nearestStation = station
            }
        }

        // A pending one-shot always gets an answer, published or not.
        if let completion = oneShotCompletion {
            oneShotCompletion = nil
            completion(station ?? getStoredNearestStation())
        }
    }

    private func shouldPublish(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.worstUsableAccuracyMeters
        else { return false }
        guard let last = lastPublishedLocation else { return true }
        return location.distance(from: last) >= Self.publishThresholdMeters
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        oneShotCompletion?(getStoredNearestStation())
        oneShotCompletion = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.authorizationStatus = manager.authorizationStatus }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }
}

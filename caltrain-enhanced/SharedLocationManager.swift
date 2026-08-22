//
//  SharedLocationManager.swift
//  caltrain-enhanced
//
//  Created by Michael Yu on 6/14/25.
//
//  Single source of truth for location shared between the app and the widget.
//  The app requests location and writes the nearest station + coordinate into the
//  shared App Group container; the widget reads that cache (and may request a fresh
//  fix when it has authorization).
//
//  Power budget: tracking is foreground-only and deliberately coarse. 100 m accuracy is
//  plenty to pick between Caltrain stops (~2 km apart), a distance filter means standing
//  still costs no callbacks, and there is no background location mode — leaving the app
//  shuts the sensor off. Fixes are only republished after a real move, so a jittering GPS
//  can't cascade into MapKit route requests downstream.

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

    /// Whether the app has asked to track (intent) vs. whether CoreLocation is actually
    /// running (fact). They diverge while authorization is still pending.
    private var wantsTracking = false
    private var isTracking = false

    /// Last fix we published, kept separately from `userLocation` so the threshold check
    /// never reads a value that's mid-hop to the main queue.
    private var lastPublishedLocation: CLLocation?

    @Published private(set) var userLocation: CLLocation?
    @Published private(set) var nearestStation: CaltrainStation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    /// Station the user picked by hand. Overrides `nearestStation` until cleared, and
    /// survives relaunches so a deliberate choice isn't undone by the next location fix.
    @Published private(set) var pickedStation: CaltrainStation?

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
        pickedStation = getStoredPickedStation()
    }

    // MARK: - Active station

    /// The station the app should show: an explicit pick wins over the nearest one.
    var activeStation: CaltrainStation? { pickedStation ?? nearestStation }

    var isUsingPickedStation: Bool { pickedStation != nil }

    func selectStation(_ station: CaltrainStation) {
        pickedStation = station
        guard let data = try? JSONEncoder().encode(station) else { return }
        defaults?.set(data, forKey: SharedConstants.selectedStationKey)
    }

    /// Drops the manual pick and falls back to whatever station is nearest.
    func useNearestStation() {
        pickedStation = nil
        defaults?.removeObject(forKey: SharedConstants.selectedStationKey)
        // Recompute from the fix already in hand so the switch is instant. Only pay for a
        // new fix when we aren't already tracking (mixing `requestLocation` into an active
        // `startUpdatingLocation` session is an error).
        if let location = userLocation {
            nearestStation = CaltrainStations.shared.nearestStation(to: location)
        }
        if !isTracking { requestLocation() }
    }

    private func getStoredPickedStation() -> CaltrainStation? {
        guard let data = defaults?.data(forKey: SharedConstants.selectedStationKey),
              let station = try? JSONDecoder().decode(CaltrainStation.self, from: data)
        else { return nil }
        return station
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

    /// Begins following the user while the app is on screen. Call `stopTracking()` when the
    /// scene leaves the foreground — there is no background location entitlement, so an
    /// un-stopped session would keep the sensor alive with nobody looking at the result.
    func startTracking() {
        wantsTracking = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        resolveTracking()
    }

    func stopTracking() {
        wantsTracking = false
        resolveTracking()
    }

    /// Brings CoreLocation in line with `wantsTracking` and the current authorization.
    private func resolveTracking() {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        switch (wantsTracking && authorized, isTracking) {
        case (true, false):
            isTracking = true
            // Delivers the last-known fix straight away, so the first frame isn't empty.
            manager.startUpdatingLocation()
        case (false, true):
            isTracking = false
            manager.stopUpdatingLocation()
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
        let wasTracking = isTracking
        resolveTracking()
        // Permission just landed and nobody wants a stream: take a single fix instead.
        if !isTracking && !wasTracking,
           manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

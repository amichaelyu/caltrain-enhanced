//
//  MapsLauncher.swift
//  caltrain-enhanced
//
//  Hands off turn-by-turn navigation to the user's preferred maps app.
//

import Foundation
import MapKit
import UIKit

enum MapsProvider: String, CaseIterable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Maps"
        case .google: "Google Maps"
        }
    }

    /// Key backing `@AppStorage` for the user's choice. Apple Maps is the default.
    static let storageKey = "mapsProvider"
}

enum TravelMode {
    case walking
    case cycling
    case driving

    var appleDirectionsMode: String {
        switch self {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        case .driving: MKLaunchOptionsDirectionsModeDriving
        }
    }

    var googleDirectionsMode: String {
        switch self {
        case .walking: "walking"
        case .cycling: "bicycling"
        case .driving: "driving"
        }
    }
}

enum MapsLauncher {
    /// Opens directions from the user's current location to `station` in `provider`.
    static func openDirections(to station: CaltrainStation,
                               mode: TravelMode,
                               using provider: MapsProvider) {
        switch provider {
        case .apple:
            openInAppleMaps(station: station, mode: mode)
        case .google:
            openInGoogleMaps(station: station, mode: mode)
        }
    }

    private static func openInAppleMaps(station: CaltrainStation, mode: TravelMode) {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        destination.name = "\(station.name) Caltrain"
        MKMapItem.openMaps(
            with: [MKMapItem.forCurrentLocation(), destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.appleDirectionsMode]
        )
    }

    private static func openInGoogleMaps(station: CaltrainStation, mode: TravelMode) {
        let coordinate = "\(station.coordinate.latitude),\(station.coordinate.longitude)"

        // Try the Google Maps app first. `open` reports failure without needing a
        // LSApplicationQueriesSchemes declaration, so we fall back to the web route.
        guard let appURL = URL(string: "comgooglemaps://?daddr=\(coordinate)&directionsmode=\(mode.googleDirectionsMode)") else {
            openGoogleMapsOnWeb(coordinate: coordinate, mode: mode)
            return
        }

        UIApplication.shared.open(appURL, options: [:]) { opened in
            if !opened { openGoogleMapsOnWeb(coordinate: coordinate, mode: mode) }
        }
    }

    private static func openGoogleMapsOnWeb(coordinate: String, mode: TravelMode) {
        guard let url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(coordinate)&travelmode=\(mode.googleDirectionsMode)") else { return }
        UIApplication.shared.open(url)
    }
}

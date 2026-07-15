//
//  SharedConstants.swift
//  widget
//
//  Created by Michael Yu on 6/14/25.
//

import Foundation

enum SharedConstants {
    // App Group identifier — must match the App Groups entitlement on both targets.
    static let appGroupIdentifier = "group.com.michaelyu.caltrain-enhanced"

    // Shared UserDefaults keys
    static let nearestStationKey = "nearestStation"          // encoded CaltrainStation
    static let lastKnownStationKey = "lastKnownStation"      // station name string
    static let lastKnownLocationKey = "lastKnownLocation"    // [latitude, longitude]
    static let lastLocationUpdateKey = "lastLocationUpdate"  // Date

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}

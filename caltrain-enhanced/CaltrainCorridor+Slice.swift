//
//  CaltrainCorridor+Slice.swift
//  caltrain-enhanced
//
//  Cutting the corridor centreline down to the bit you care about: the track between two
//  platforms, and points along it. Hand-written; the data next door is generated.
//

import Foundation
import CoreLocation

extension CaltrainCorridor {

    /// The track between two platforms, in travel order. Nil for a station the corridor
    /// doesn't know, which leaves callers to fall back to a straight line.
    static func track(from origin: String, to destination: String) -> [CLLocationCoordinate2D]? {
        guard let a = vertices[origin], let b = vertices[destination],
              path.indices.contains(a), path.indices.contains(b) else { return nil }
        let slice = Array(path[min(a, b)...max(a, b)])
        return a <= b ? slice : slice.reversed()
    }

    /// The first `fraction` of that track by distance, ending exactly on the point that
    /// far along — so a train drawn at the end of it sits on the rails, not on a chord
    /// between two stations.
    static func track(from origin: String,
                      to destination: String,
                      upTo fraction: Double) -> [CLLocationCoordinate2D]? {
        guard let full = track(from: origin, to: destination), full.count >= 2 else { return nil }

        let legs = zip(full, full.dropFirst()).map(meters)
        let target = legs.reduce(0, +) * min(max(fraction, 0), 1)
        guard target > 0 else { return [full[0]] }

        var walked: Double = 0
        for (index, leg) in legs.enumerated() {
            guard walked + leg >= target else {
                walked += leg
                continue
            }
            let within = leg > 0 ? (target - walked) / leg : 0
            return Array(full.prefix(index + 1)) + [interpolate(full[index], full[index + 1], within)]
        }
        return full
    }

    /// The point `fraction` of the way from one platform to the next.
    static func point(from origin: String,
                      to destination: String,
                      fraction: Double) -> CLLocationCoordinate2D? {
        track(from: origin, to: destination, upTo: fraction)?.last
    }

    /// Flat-earth distance. Over one leg of track the curvature error is centimetres.
    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * metersPerDegreeLon
        let dy = (b.latitude - a.latitude) * metersPerDegreeLat
        return (dx * dx + dy * dy).squareRoot()
    }

    static func interpolate(_ a: CLLocationCoordinate2D,
                            _ b: CLLocationCoordinate2D,
                            _ fraction: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                               longitude: a.longitude + (b.longitude - a.longitude) * fraction)
    }
}

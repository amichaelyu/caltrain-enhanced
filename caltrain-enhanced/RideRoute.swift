//
//  RideRoute.swift
//  caltrain-enhanced
//
//  A ride drawn as one line along the real track, boarding platform to the stop you get
//  off at, measured in metres so the map can cut it anywhere: the part already ridden,
//  and the pulses running on ahead toward your stop.
//

import Foundation
import CoreLocation

struct RideRoute {
    let coordinates: [CLLocationCoordinate2D]
    /// Metres from the start to each coordinate.
    private let distances: [Double]

    var length: Double { distances.last ?? 0 }

    /// Stitched leg by leg through the stations, in travel order. Legs the corridor
    /// doesn't know become a straight hop rather than a gap.
    init(stations: [CaltrainStation]) {
        var coordinates: [CLLocationCoordinate2D] = []
        for (a, b) in zip(stations, stations.dropFirst()) {
            let leg = CaltrainCorridor.track(from: a.name, to: b.name) ?? [a.coordinate, b.coordinate]
            coordinates += coordinates.isEmpty ? leg : Array(leg.dropFirst())
        }
        if coordinates.isEmpty { coordinates = stations.map(\.coordinate) }
        self.coordinates = coordinates

        var distances: [Double] = [0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            distances.append(distances[distances.count - 1] + Self.meters(a, b))
        }
        self.distances = distances
    }

    /// The stretch between two distances along the route, ending exactly on both.
    func slice(from start: Double, to end: Double) -> [CLLocationCoordinate2D] {
        let lo = min(max(start, 0), length), hi = min(max(end, 0), length)
        guard hi > lo, coordinates.count >= 2 else { return [] }
        var out = [point(at: lo)]
        for (index, distance) in distances.enumerated() where distance > lo && distance < hi {
            out.append(coordinates[index])
        }
        out.append(point(at: hi))
        return out
    }

    func point(at distance: Double) -> CLLocationCoordinate2D {
        guard let first = coordinates.first else { return CLLocationCoordinate2D() }
        guard distance > 0 else { return first }
        for index in 1..<distances.count where distances[index] >= distance {
            let leg = distances[index] - distances[index - 1]
            let t = leg > 0 ? (distance - distances[index - 1]) / leg : 0
            return CaltrainCorridor.interpolate(coordinates[index - 1], coordinates[index], t)
        }
        return coordinates[coordinates.count - 1]
    }

    /// How far along the route the closest point to `coordinate` is.
    func distance(of coordinate: CLLocationCoordinate2D) -> Double {
        var best = (meters: Double.infinity, along: 0.0)
        for index in 1..<max(coordinates.count, 1) {
            let a = coordinates[index - 1], b = coordinates[index]
            // Flat projection onto the leg; over a few hundred metres that's exact enough.
            let scale = cos(a.latitude * .pi / 180)
            let ax = a.longitude * scale, ay = a.latitude
            let bx = b.longitude * scale, by = b.latitude
            let px = coordinate.longitude * scale, py = coordinate.latitude
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1) : 0
            let nearest = CaltrainCorridor.interpolate(a, b, t)
            let off = Self.meters(nearest, coordinate)
            if off < best.meters {
                best = (off, distances[index - 1] + (distances[index] - distances[index - 1]) * t)
            }
        }
        return best.along
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let dy = (b.latitude - a.latitude) * 111_320
        return (dx * dx + dy * dy).squareRoot()
    }
}

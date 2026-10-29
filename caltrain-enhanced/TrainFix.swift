//
//  TrainFix.swift
//  caltrain-enhanced
//
//  Where one train is right now: every puck on the Map tab and the train sheet's
//  "between X and Y". The same estimator a trip uses, run over the train's whole run
//  instead of from a boarding station, so every screen puts a train in the same place.
//

import Foundation
import CoreLocation

struct TrainFix: Identifiable {
    let run: RideItinerary
    let estimate: RideEstimate
    let placement: RidePlacement
    let coordinate: CLLocationCoordinate2D

    var id: String { "\(run.trainNumber)-\(run.northbound ? "N" : "S")" }

    /// The furthest each run has been drawn: the stop behind it and how far past. Keyed by
    /// run, so tomorrow's train of the same number starts from its own origin.
    private static var furthest: [String: (station: String, fraction: Double)] = [:]

    /// Nil before the train is due out of its origin: it isn't anywhere on the line yet.
    init?(run: RideItinerary, live: LiveTrain?, now: Date) {
        let estimate = RideEstimator.estimate(for: run, userLocation: nil, live: live, now: now)
        guard var placement = estimate.placement(at: now) else { return nil }
        let stops = estimate.stops

        // Trains don't reverse. A fresh fix landing behind where the last one was carried
        // to holds the train there until it catches up, rather than drawing it backwards.
        let key = "\(run.trainNumber)-\(run.northbound ? "N" : "S")-\(run.origin?.scheduled.timeIntervalSince1970 ?? 0)"
        if let furthest = Self.furthest[key],
           let index = stops.firstIndex(where: { $0.station.name == furthest.station }),
           index < stops.count - 1,
           (index, furthest.fraction) > (placement.segmentIndex, placement.fraction) {
            placement = RidePlacement(segmentIndex: index, fraction: furthest.fraction, source: placement.source)
        } else {
            Self.furthest[key] = (stops[placement.segmentIndex].station.name, placement.fraction)
        }


        let from = stops[placement.segmentIndex].station
        let to = stops[min(placement.segmentIndex + 1, stops.count - 1)].station

        self.run = run
        self.estimate = estimate
        self.placement = placement
        self.coordinate = CaltrainCorridor.point(from: from.name, to: to.name, fraction: placement.fraction)
            ?? CaltrainCorridor.interpolate(from.coordinate, to.coordinate, placement.fraction)
    }

    var isLive: Bool { placement.isLive }

    /// Past its projected arrival at the end of the line.
    func hasFinished(at now: Date) -> Bool {
        guard let last = estimate.stops.last else { return true }
        return now >= last.projected
    }

    /// Close enough to the stop behind it to call it there rather than between.
    private var isAtStop: Bool { placement.fraction < 0.05 }

    /// "At Hillsdale" or "Between Hillsdale and Belmont".
    var whereabouts: String {
        let stops = estimate.stops
        let behind = stops[placement.segmentIndex].station.name
        guard placement.segmentIndex + 1 < stops.count else { return "At \(behind)" }
        let ahead = stops[placement.segmentIndex + 1].station.name
        if placement.fraction >= 1 { return "At \(ahead)" }
        return isAtStop ? "At \(behind)" : "Between \(behind) and \(ahead)"
    }

    /// Stops the train still has to make up to and including `stationName`. Nil once it's
    /// there or past it.
    func stopsAway(from stationName: String) -> Int? {
        guard let target = run.index(of: stationName) else { return nil }
        let away = target - placement.segmentIndex
        guard away > 1 || (away == 1 && placement.fraction < 1) else { return nil }
        return away
    }
}

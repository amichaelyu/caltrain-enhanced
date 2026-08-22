//
//  RideModels.swift
//  caltrain-enhanced
//
//  The Ride tab's model. A ride is one train's run from the station you boarded at,
//  and every estimate on the page comes from two things: the scheduled deltas between
//  that train's stops, and where your phone says you are along the line. Matching your
//  position to the corridor tells us how far behind schedule the train is running, and
//  that one offset shifts every downstream stop. No live feed needed.
//

import Foundation
import CoreLocation
import Combine

// MARK: - Itinerary

/// One scheduled stop, resolved to an absolute wall-clock date.
struct RideStop: Identifiable {
    let station: CaltrainStation
    let scheduled: Date

    var id: String { station.name }
}

/// A single train's run in travel order, starting at the station the rider boarded.
/// The boarding station is always `stops.first` — the ride reads top-down from where
/// you got on, never from the start of the line.
struct RideItinerary {
    let trainNumber: String
    let trainType: String?
    let northbound: Bool
    let stops: [RideStop]

    var origin: RideStop? { stops.first }
    var terminus: RideStop? { stops.last }

    func index(of stationName: String) -> Int? {
        stops.firstIndex { $0.station.name.caseInsensitiveCompare(stationName) == .orderedSame }
    }

    func contains(_ stationName: String) -> Bool { index(of: stationName) != nil }
}

// MARK: - Estimates

/// Where the rider is along the line: between `segmentIndex` and the stop after it.
struct RidePosition {
    /// Index of the stop just behind the rider.
    let segmentIndex: Int
    /// 0 at `segmentIndex`, 1 at the next stop.
    let fraction: Double
    /// Perpendicular distance to the segment — how much to trust the match.
    let metersFromLine: CLLocationDistance
}

struct RideStopEstimate: Identifiable {
    let station: CaltrainStation
    let scheduled: Date
    /// `scheduled` shifted by however late the train is running.
    let projected: Date
    /// Scheduled minutes from the previous stop: the delta this whole page is built on.
    let minutesFromPrevious: Int?
    /// Scheduled minutes since leaving the boarding station.
    let minutesFromOrigin: Int
    let hasPassed: Bool

    var id: String { station.name }

    func minutesAway(from now: Date) -> Int {
        max(0, Int((projected.timeIntervalSince(now) / 60).rounded()))
    }
}

struct RideEstimate {
    let stops: [RideStopEstimate]
    /// How far behind schedule the train is running. Never negative — see `RideEstimator`.
    let delaySeconds: TimeInterval
    /// Non-nil only when the rider's location could be matched to this train's corridor.
    let position: RidePosition?

    /// True when the numbers are anchored to the rider's position rather than the
    /// timetable alone.
    var isLive: Bool { position != nil }

    var delayMinutes: Int { Int((delaySeconds / 60).rounded()) }

    var nextStop: RideStopEstimate? { stops.first { !$0.hasPassed } }

    func stop(named name: String?) -> RideStopEstimate? {
        guard let name else { return nil }
        return stops.first { $0.station.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func index(of name: String?) -> Int? {
        guard let name else { return nil }
        return stops.firstIndex { $0.station.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

enum RideEstimator {

    /// How far off the line a fix can be and still be read as "on this train". Generous
    /// enough for a wide corridor and a coarse fix, tight enough that sitting at home in
    /// the next town over doesn't get mistaken for riding.
    private static let corridorMeters: CLLocationDistance = 1500

    /// Cap on the inferred delay. Beyond this the position match is more likely wrong
    /// than the train is late.
    private static let maxDelaySeconds: TimeInterval = 45 * 60

    /// Projects the schedule forward from wherever the rider actually is.
    static func estimate(for itinerary: RideItinerary,
                         userLocation: CLLocation?,
                         now: Date = Date()) -> RideEstimate {

        // Before the train is due out of the boarding station the ride hasn't started, so
        // wherever the rider happens to be says nothing about it — a fix up the line would
        // otherwise mark stops passed on a train still sitting at the platform.
        let hasLeft = itinerary.origin.map { now >= $0.scheduled } ?? false
        let position = hasLeft ? userLocation.flatMap { locate($0, on: itinerary) } : nil
        let delay = position.map { delaySeconds(at: $0, on: itinerary, now: now) } ?? 0

        let originScheduled = itinerary.origin?.scheduled
        var previous: Date?
        var stops: [RideStopEstimate] = []

        for (index, stop) in itinerary.stops.enumerated() {
            let projected = stop.scheduled.addingTimeInterval(delay)
            // Behind you either because its (shifted) time has gone, or because your
            // position is already down the line from it.
            let passedByPosition = position.map { index < $0.segmentIndex } ?? false
            let atOrBeyond = position.map { index == $0.segmentIndex && $0.fraction > 0.97 } ?? false

            stops.append(RideStopEstimate(
                station: stop.station,
                scheduled: stop.scheduled,
                projected: projected,
                minutesFromPrevious: previous.map { minutes(from: $0, to: stop.scheduled) },
                minutesFromOrigin: originScheduled.map { minutes(from: $0, to: stop.scheduled) } ?? 0,
                hasPassed: projected <= now || passedByPosition || atOrBeyond
            ))
            previous = stop.scheduled
        }

        return RideEstimate(stops: stops, delaySeconds: delay, position: position)
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 60).rounded())
    }

    /// Lateness implied by the rider's position: the schedule says they should be at this
    /// point on the line at one time, and it is actually another.
    ///
    /// Clamped at zero deliberately. A rider standing on the platform before departure is
    /// "ahead of" the schedule by every measure, and trains almost never run early, so a
    /// negative offset is far more likely to be a waiting rider than a fast train.
    private static func delaySeconds(at position: RidePosition,
                                     on itinerary: RideItinerary,
                                     now: Date) -> TimeInterval {
        let stops = itinerary.stops
        guard position.segmentIndex + 1 < stops.count else { return 0 }
        let from = stops[position.segmentIndex].scheduled
        let to = stops[position.segmentIndex + 1].scheduled
        let implied = from.addingTimeInterval(to.timeIntervalSince(from) * position.fraction)
        return min(max(0, now.timeIntervalSince(implied)), maxDelaySeconds)
    }

    /// Finds the leg of the run the rider is on, by taking the closest segment between
    /// consecutive stops. Returns nil when no leg is close enough to believe.
    private static func locate(_ location: CLLocation, on itinerary: RideItinerary) -> RidePosition? {
        let stops = itinerary.stops
        guard stops.count >= 2 else { return nil }

        var best: RidePosition?
        for index in 0..<(stops.count - 1) {
            let projection = project(location.coordinate,
                                     onto: stops[index].station.coordinate,
                                     stops[index + 1].station.coordinate)
            if best == nil || projection.meters < best!.metersFromLine {
                best = RidePosition(segmentIndex: index,
                                    fraction: projection.fraction,
                                    metersFromLine: projection.meters)
            }
        }

        guard let best, best.metersFromLine <= corridorMeters else { return nil }
        return best
    }

    /// Perpendicular projection of `point` onto the segment `a`–`b`, in a local flat-earth
    /// frame around `a`. Over a few kilometres of track the curvature error is metres.
    private static func project(_ point: CLLocationCoordinate2D,
                               onto a: CLLocationCoordinate2D,
                               _ b: CLLocationCoordinate2D) -> (fraction: Double, meters: Double) {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(a.latitude * .pi / 180)

        let bx = (b.longitude - a.longitude) * metersPerDegreeLon
        let by = (b.latitude - a.latitude) * metersPerDegreeLat
        let px = (point.longitude - a.longitude) * metersPerDegreeLon
        let py = (point.latitude - a.latitude) * metersPerDegreeLat

        let lengthSquared = bx * bx + by * by
        guard lengthSquared > 0 else { return (0, sqrt(px * px + py * py)) }

        let fraction = min(max((px * bx + py * by) / lengthSquared, 0), 1)
        let dx = px - bx * fraction
        let dy = py - by * fraction
        return (fraction, sqrt(dx * dx + dy * dy))
    }
}

// MARK: - Formatting

enum RideFormat {
    /// Locale-aware clock time for a resolved stop date.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Session

/// The ride the app is currently following: which train, where it was boarded, and where
/// the rider is getting off. Lives above the tabs so picking a train on Plan is the same
/// act as starting a ride.
final class RideSession: ObservableObject {
    @Published private(set) var trainNumber: String?
    @Published private(set) var originName: String?
    @Published private(set) var northbound = true
    @Published var destinationName: String?

    var isActive: Bool { trainNumber != nil }

    /// Boards a train. `destinationName` nil means "keep whatever stop I already chose",
    /// which is what lets the Plan tab hand over a train and a destination in one tap.
    func start(trainNumber: String,
               from originName: String,
               northbound: Bool,
               destinationName: String? = nil) {
        self.trainNumber = trainNumber
        self.originName = originName
        self.northbound = northbound
        if let destinationName { self.destinationName = destinationName }

        // A stop the new train never reaches would sit there as a dead estimate.
        if let chosen = self.destinationName,
           CaltrainService.shared.itinerary(trainNumber: trainNumber,
                                            northbound: northbound,
                                            boardingAt: originName)?.contains(chosen) != true {
            self.destinationName = nil
        }
    }

    func end() {
        trainNumber = nil
        originName = nil
        destinationName = nil
    }
}

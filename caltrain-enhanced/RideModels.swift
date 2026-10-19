//
//  RideModels.swift
//  caltrain-enhanced
//
//  The trip model. A ride is one train's run from the station you boarded at.
//  When 511's live feed is tracking the train, its predictions drive every stop. Without
//  it, estimates come from the scheduled deltas between stops plus where your phone says
//  you are along the line: matching your position to the corridor tells us how far behind
//  schedule the train is running, and that one offset shifts every downstream stop.
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

/// What the numbers on the page are anchored to, best first.
enum RideSource {
    /// 511's live predictions for this train.
    case feed
    /// The rider's own location matched to the corridor.
    case location
    /// The printed schedule and nothing else.
    case timetable
}

/// Where the train is along the line: between `segmentIndex` and the stop after it.
struct RidePosition {
    /// Index of the stop just behind the train.
    let segmentIndex: Int
    /// 0 at `segmentIndex`, 1 at the next stop.
    let fraction: Double
    /// Perpendicular distance to the segment — how much to trust the match.
    let metersFromLine: CLLocationDistance
    /// Whose fix this is: the rider's phone (`.location`) or the train's own (`.feed`).
    let source: RideSource
    /// When the fix was taken. The train has moved on since, and `placement(at:)` carries
    /// it forward from here.
    let recordedAt: Date
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
    /// How far behind schedule the train is running. From the feed this can dip slightly
    /// negative; from a location fix it never does — see `RideEstimator`.
    let delaySeconds: TimeInterval
    /// Non-nil only when a fix — the train's or the rider's — matched this run's corridor.
    let position: RidePosition?
    let source: RideSource

    /// True when the numbers are anchored to something real rather than the timetable
    /// alone.
    var isLive: Bool { source != .timetable }

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

    /// How far off the line a fix can be and still be read as "on this train". Measured
    /// against the real track geometry, so a fix on a train lands within a hundred metres
    /// or so; the slack here is for a coarse fix, not for the shape of the corridor.
    private static let corridorMeters: CLLocationDistance = 1000

    /// Cap on the inferred delay. Beyond this the position match is more likely wrong
    /// than the train is late.
    private static let maxDelaySeconds: TimeInterval = 45 * 60

    /// How close the rider's fix has to be to the train's own to count as aboard it. The
    /// feed's position lags by up to a minute, so this is generous.
    private static let aboardMeters: CLLocationDistance = 2500

    /// The live feed's predictions when it's tracking this train; otherwise the schedule
    /// projected forward from wherever the rider actually is.
    static func estimate(for itinerary: RideItinerary,
                         userLocation: CLLocation?,
                         live: LiveTrain? = nil,
                         now: Date = Date()) -> RideEstimate {
        if let live, let estimate = estimate(for: itinerary, live: live, userLocation: userLocation, now: now) {
            return estimate
        }

        // Before the train is due out of the boarding station the ride hasn't started, so
        // wherever the rider happens to be says nothing about it — a fix up the line would
        // otherwise mark stops passed on a train still sitting at the platform.
        let hasLeft = itinerary.origin.map { now >= $0.scheduled } ?? false
        let position = hasLeft ? userLocation.flatMap { locate($0, on: itinerary, source: .location) } : nil
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

        return RideEstimate(stops: stops, delaySeconds: delay, position: position,
                            source: position == nil ? .timetable : .location)
    }

    /// The ride as 511 sees it. The feed lists only the stops a train has still to make, so
    /// the first of ours it lists is the train's next stop, and everything before it is
    /// behind it. Nil when none of our stops are listed — not running, or only the
    /// terminus left, which 511 doesn't predict — so the caller falls back.
    private static func estimate(for itinerary: RideItinerary,
                                 live: LiveTrain,
                                 userLocation: CLLocation?,
                                 now: Date) -> RideEstimate? {
        let stops = itinerary.stops
        guard let next = stops.firstIndex(where: { live.stop(named: $0.station.name) != nil }),
              let nextCall = live.stop(named: stops[next].station.name)
        else { return nil }

        // Carried onto the stops the feed doesn't predict: the ones behind the train, and
        // the terminus.
        let delay = nextCall.delay

        // Only once the train is out of the boarding station is there a leg to place it on.
        // Either fix has to put it on the leg the feed says it's on, or it's a stale or
        // wandering fix and the clock places it instead.
        var position: RidePosition?
        if next > 0 {
            let train = live.coordinate.map {
                CLLocation(coordinate: $0, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: -1,
                           timestamp: live.recordedAt ?? now)
            }
            let rider = userLocation.flatMap { fix in
                // The rider's phone is fresher than the feed, but only says anything about
                // the train if they're actually on it.
                train.map { fix.distance(from: $0) <= aboardMeters } == true
                    ? locate(fix, on: itinerary, source: .location) : nil
            }
            position = [rider, train.flatMap { locate($0, on: itinerary, source: .feed) }]
                .compactMap { $0 }
                .first { $0.segmentIndex == next - 1 }
        }

        let originScheduled = itinerary.origin?.scheduled
        var previous: Date?
        var estimates: [RideStopEstimate] = []

        for (index, stop) in stops.enumerated() {
            let projected = live.stop(named: stop.station.name)?.expected
                ?? stop.scheduled.addingTimeInterval(delay)
            estimates.append(RideStopEstimate(
                station: stop.station,
                scheduled: stop.scheduled,
                projected: projected,
                minutesFromPrevious: previous.map { minutes(from: $0, to: stop.scheduled) },
                minutesFromOrigin: originScheduled.map { minutes(from: $0, to: stop.scheduled) } ?? 0,
                hasPassed: index < next || projected <= now
            ))
            previous = stop.scheduled
        }

        return RideEstimate(stops: estimates, delaySeconds: delay, position: position, source: .feed)
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

    /// Finds the leg of the run a fix is on, by taking the closest leg of track.
    /// Returns nil when no leg is close enough to believe.
    private static func locate(_ location: CLLocation,
                               on itinerary: RideItinerary,
                               source: RideSource) -> RidePosition? {
        let stops = itinerary.stops
        guard stops.count >= 2 else { return nil }

        var best: RidePosition?
        for index in 0..<(stops.count - 1) {
            let from = stops[index].station
            let to = stops[index + 1].station
            // The real corridor where we have it: matching against the track rather than
            // the chord between platforms is the difference between a believable fix and
            // a kilometre of error wherever the line bends.
            let track = CaltrainCorridor.track(from: from.name, to: to.name)
                ?? [from.coordinate, to.coordinate]
            let projection = project(location.coordinate, onto: track)
            if best == nil || projection.meters < best!.metersFromLine {
                best = RidePosition(segmentIndex: index,
                                    fraction: projection.fraction,
                                    metersFromLine: projection.meters,
                                    source: source,
                                    recordedAt: location.timestamp)
            }
        }

        guard let best, best.metersFromLine <= corridorMeters else { return nil }
        return best
    }

    /// Closest point on a polyline: how far along it the rider is, as a fraction of the
    /// leg's length, and how far off it they are.
    private static func project(_ point: CLLocationCoordinate2D,
                                onto polyline: [CLLocationCoordinate2D]) -> (fraction: Double, meters: Double) {
        guard polyline.count >= 2 else { return (0, .greatestFiniteMagnitude) }

        var closest = (along: 0.0, meters: Double.greatestFiniteMagnitude)
        var walked: Double = 0
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let length = meters(a, b)
            let hit = project(point, onto: a, b)
            if hit.meters < closest.meters {
                closest = (walked + length * hit.fraction, hit.meters)
            }
            walked += length
        }

        guard walked > 0 else { return (0, closest.meters) }
        return (min(max(closest.along / walked, 0), 1), closest.meters)
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * metersPerDegreeLon
        let dy = (b.latitude - a.latitude) * metersPerDegreeLat
        return (dx * dx + dy * dy).squareRoot()
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

// MARK: - Drawing position

/// Where the train sits along the run: the stop just behind it, plus how far it has got
/// towards the next one. Two ways to arrive at one, in order of preference — a fix (the
/// rider's or the train's) matched to the corridor, or, failing that, plain interpolation
/// of the projected times.
struct RidePlacement {
    let segmentIndex: Int
    /// 0 at `segmentIndex`, 1 at the stop after it.
    let fraction: Double
    /// `.timetable` only when nothing live went into it: interpolating 511's predicted
    /// times still counts as `.feed`.
    let source: RideSource

    var isLive: Bool { source != .timetable }
}

extension RideEstimate {

    /// Nil until the train is due out of the boarding station: before that there is
    /// nothing moving to draw, just a rider on a platform.
    func placement(at now: Date) -> RidePlacement? {
        guard stops.count >= 2, let origin = stops.first, now >= origin.scheduled else { return nil }

        // A fix close enough to the line to be believed wins: it knows about delays the
        // timetable can't.
        if let position, position.segmentIndex + 1 < stops.count {
            return RidePlacement(segmentIndex: position.segmentIndex,
                                 fraction: extrapolated(position, to: now),
                                 source: position.source)
        }

        let clockSource: RideSource = source == .feed ? .feed : .timetable

        // Otherwise walk the projected times and find the leg `now` falls inside.
        for index in 0..<(stops.count - 1) {
            let departure = stops[index].projected
            let next = stops[index + 1].projected
            guard now < next else { continue }
            // Standing at the next platform until its time comes round.
            let arrival = arrivalTime(atStopAfter: index)
            guard now < arrival else {
                return RidePlacement(segmentIndex: index, fraction: 1, source: clockSource)
            }
            let travel = arrival.timeIntervalSince(departure)
            let fraction = travel > 0 ? now.timeIntervalSince(departure) / travel : 0
            return RidePlacement(segmentIndex: index,
                                 fraction: min(max(fraction, 0), 1),
                                 source: clockSource)
        }

        // Past the last stop on the run.
        return RidePlacement(segmentIndex: stops.count - 2, fraction: 1, source: clockSource)
    }

    /// How long a train stands at a platform. The timetable and 511 give one time per
    /// stop, and it's when the train leaves; it pulls in about this much earlier.
    private static let dwell: TimeInterval = 45

    private static let minimumPullIn: TimeInterval = 30

    /// When the train pulls into the stop after `index`: a dwell before its listed time,
    /// but never more than a third of a short leg, so the train still visibly moves.
    private func arrivalTime(atStopAfter index: Int) -> Date {
        let departure = stops[index].projected
        let next = stops[index + 1].projected
        let leg = max(next.timeIntervalSince(departure), 0)
        return next.addingTimeInterval(-min(Self.dwell, leg / 3))
    }

    /// A fix says where the train was when it was taken, and 511's can be a minute or two
    /// old. Carry it on toward the next stop at the pace that gets it there at its
    /// projected time, and hold it at the platform until a newer fix says it has left.
    private func extrapolated(_ position: RidePosition, to now: Date) -> Double {
        let elapsed = now.timeIntervalSince(position.recordedAt)
        // A train running later than even 511's prediction would otherwise have no time
        // left to cover the rest of the leg, and freeze short of the platform until the
        // next fix. Give it at least this long to pull in.
        let remaining = max(arrivalTime(atStopAfter: position.segmentIndex).timeIntervalSince(position.recordedAt),
                            Self.minimumPullIn)
        guard elapsed > 0 else { return position.fraction }
        return min(1, position.fraction + (1 - position.fraction) * elapsed / remaining)
    }
}

// MARK: - Formatting

enum RideFormat {
    /// Locale-aware clock time for a resolved stop date.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// The same time split in two, so a column of them can line its digits up and set
    /// the AM/PM small. `meridiem` is nil on a 24-hour clock, where there isn't one.
    static func clockParts(_ date: Date) -> (time: String, meridiem: String?) {
        let meridiem = meridiemFormatter.string(from: date)
        guard !meridiem.isEmpty else {
            return (date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()), nil)
        }
        return (date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()), meridiem)
    }

    /// Yields "" wherever the locale's clock has no AM/PM to show.
    private static let meridiemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("a")
        return formatter
    }()
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

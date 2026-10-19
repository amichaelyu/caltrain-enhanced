//
//  CaltrainModels.swift
//  caltrain-enhanced
//
//  Created by Michael Yu on 6/14/25.
//

import Foundation
import CoreLocation

// MARK: - Schedule data models

struct CaltrainSchedule: Codable {
    let serviceType: String
    let direction: String
    let trains: [Train]

    enum CodingKeys: String, CodingKey {
        case serviceType = "service_type"
        case direction
        case trains
    }
}

struct Train: Codable {
    let trainNo: String
    let type: String?
    let stops: [String: String]   // station name -> "HH:mm" (24h, service-day local time)

    enum CodingKeys: String, CodingKey {
        case trainNo = "train_no"
        case type
        case stops
    }
}

struct CaltrainStation: Codable {
    let name: String
    let coordinate: CLLocationCoordinate2D

    enum CodingKeys: String, CodingKey {
        case name
        case latitude
        case longitude
    }

    init(name: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.coordinate = coordinate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

struct NextTrainInfo: Identifiable {
    let id = UUID()
    let trainNumber: String
    let trainType: String?
    let stationName: String
    let minutesUntilArrival: Int
    let arrivalTime: String        // display formatted, e.g. "5:07 AM"
    let arrivalDate: Date
    let direction: String
    /// 511's prediction for this stop, when the feed is tracking the train.
    var expectedDate: Date? = nil

    /// The time to count down to: 511's when there is one, the timetable's otherwise.
    var departureDate: Date { expectedDate ?? arrivalDate }

    /// True when 511 puts it in a different minute from the printed time.
    var isOffSchedule: Bool {
        guard let expectedDate else { return false }
        let minute = { (date: Date) in Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down)) }
        return minute(expectedDate) != minute(arrivalDate)
    }
}

/// Which timetable is in force. Caltrain runs one schedule Monday–Friday and another
/// at weekends; the sheet can show either.
enum ServiceDay: Identifiable, CaseIterable {
    case weekday, weekend

    var id: Self { self }
    var label: String { self == .weekday ? "Weekday" : "Weekend" }
    var isWeekend: Bool { self == .weekend }
}

/// One column of the timetable grid: a single train and its stop times.
struct TimetableTrain: Identifiable {
    let id = UUID()
    let trainNumber: String
    let trainType: String?
    let departureTime: String              // display time at the reference station
    let times: [String: String]            // station name -> display time
    /// True only when viewing today's service and this train has already left the
    /// reference station. Always false for the schedule that is not running today.
    let hasDeparted: Bool
}

/// Stations down, trains across — the shape of a printed Caltrain timetable.
struct TimetableGrid {
    /// Stations in travel order for this direction, limited to ones these trains serve.
    let stations: [String]
    /// Upcoming trains from the reference station, soonest first.
    let trains: [TimetableTrain]
}

struct BidirectionalTrainInfo {
    let northbound: NextTrainInfo?
    let southbound: NextTrainInfo?
}

// MARK: - Stations

final class CaltrainStations {
    static let shared = CaltrainStations()

    // Names MUST match the station keys used in the embedded schedule data exactly,
    // otherwise schedule lookups by station name will silently fail.
    let stations: [CaltrainStation] = [
        CaltrainStation(name: "San Francisco", coordinate: CLLocationCoordinate2D(latitude: 37.7764, longitude: -122.3943)),
        CaltrainStation(name: "22nd Street", coordinate: CLLocationCoordinate2D(latitude: 37.7573, longitude: -122.3924)),
        CaltrainStation(name: "Bayshore", coordinate: CLLocationCoordinate2D(latitude: 37.7096, longitude: -122.4014)),
        CaltrainStation(name: "S. San Francisco", coordinate: CLLocationCoordinate2D(latitude: 37.6549, longitude: -122.4061)),
        CaltrainStation(name: "San Bruno", coordinate: CLLocationCoordinate2D(latitude: 37.6303, longitude: -122.4111)),
        CaltrainStation(name: "Millbrae", coordinate: CLLocationCoordinate2D(latitude: 37.5996, longitude: -122.3869)),
        CaltrainStation(name: "Broadway", coordinate: CLLocationCoordinate2D(latitude: 37.5878, longitude: -122.3625)),
        CaltrainStation(name: "Burlingame", coordinate: CLLocationCoordinate2D(latitude: 37.5792, longitude: -122.3448)),
        CaltrainStation(name: "San Mateo", coordinate: CLLocationCoordinate2D(latitude: 37.5688, longitude: -122.3239)),
        CaltrainStation(name: "Hayward Park", coordinate: CLLocationCoordinate2D(latitude: 37.5531, longitude: -122.3092)),
        CaltrainStation(name: "Hillsdale", coordinate: CLLocationCoordinate2D(latitude: 37.5417, longitude: -122.3010)),
        CaltrainStation(name: "Belmont", coordinate: CLLocationCoordinate2D(latitude: 37.5206, longitude: -122.2758)),
        CaltrainStation(name: "San Carlos", coordinate: CLLocationCoordinate2D(latitude: 37.5073, longitude: -122.2608)),
        CaltrainStation(name: "Redwood City", coordinate: CLLocationCoordinate2D(latitude: 37.4855, longitude: -122.2317)),
        CaltrainStation(name: "Menlo Park", coordinate: CLLocationCoordinate2D(latitude: 37.4544, longitude: -122.1825)),
        CaltrainStation(name: "Palo Alto", coordinate: CLLocationCoordinate2D(latitude: 37.4430, longitude: -122.1649)),
        CaltrainStation(name: "California Avenue", coordinate: CLLocationCoordinate2D(latitude: 37.4294, longitude: -122.1426)),
        CaltrainStation(name: "San Antonio", coordinate: CLLocationCoordinate2D(latitude: 37.4065, longitude: -122.1072)),
        CaltrainStation(name: "Mountain View", coordinate: CLLocationCoordinate2D(latitude: 37.3943, longitude: -122.0762)),
        CaltrainStation(name: "Sunnyvale", coordinate: CLLocationCoordinate2D(latitude: 37.3781, longitude: -122.0297)),
        CaltrainStation(name: "Lawrence", coordinate: CLLocationCoordinate2D(latitude: 37.3707, longitude: -121.9961)),
        CaltrainStation(name: "Santa Clara", coordinate: CLLocationCoordinate2D(latitude: 37.3530, longitude: -121.9357)),
        CaltrainStation(name: "College Park", coordinate: CLLocationCoordinate2D(latitude: 37.3423, longitude: -121.9160)),
        CaltrainStation(name: "San Jose Diridon", coordinate: CLLocationCoordinate2D(latitude: 37.3298, longitude: -121.9026)),
        CaltrainStation(name: "Tamien", coordinate: CLLocationCoordinate2D(latitude: 37.3117, longitude: -121.8841)),
        CaltrainStation(name: "Capitol", coordinate: CLLocationCoordinate2D(latitude: 37.2840, longitude: -121.8418)),
        CaltrainStation(name: "Blossom Hill", coordinate: CLLocationCoordinate2D(latitude: 37.2527, longitude: -121.7982)),
        CaltrainStation(name: "Morgan Hill", coordinate: CLLocationCoordinate2D(latitude: 37.1299, longitude: -121.6504)),
        CaltrainStation(name: "San Martin", coordinate: CLLocationCoordinate2D(latitude: 37.0851, longitude: -121.6106)),
        CaltrainStation(name: "Gilroy", coordinate: CLLocationCoordinate2D(latitude: 37.0034, longitude: -121.5668))
    ]

    func nearestStation(to location: CLLocation) -> CaltrainStation? {
        stations.min { location.distance(from: $0.location) < location.distance(from: $1.location) }
    }

    func station(named name: String) -> CaltrainStation? {
        stations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Schedule service

final class CaltrainService {
    static let shared = CaltrainService()

    private var schedules: [CaltrainSchedule] = []

    init() {
        loadFullScheduleData()
    }

    func setScheduleData(_ data: [CaltrainSchedule]) {
        self.schedules = data
    }

    /// Next train in each direction from the given station.
    func nextTrainsBothDirections(from stationName: String, currentTime: Date = Date()) -> BidirectionalTrainInfo {
        let (north, south) = upcomingTrains(from: stationName, currentTime: currentTime, limit: 1)
        return BidirectionalTrainInfo(northbound: north.first, southbound: south.first)
    }

    /// Upcoming trains in each direction, soonest first.
    func upcomingTrains(from stationName: String, currentTime: Date = Date(), limit: Int = 8)
        -> (northbound: [NextTrainInfo], southbound: [NextTrainInfo]) {

        var northbound: [NextTrainInfo] = []
        var southbound: [NextTrainInfo] = []

        for schedule in schedules {
            let isNorth = schedule.direction.localizedCaseInsensitiveContains("North")
            for train in schedule.trains {
                guard let timeStr = train.stops[stationName],
                      let date = nextOccurrence(timeOfDay: timeStr, after: currentTime, serviceType: schedule.serviceType)
                else { continue }

                let info = NextTrainInfo(
                    trainNumber: train.trainNo,
                    trainType: train.type,
                    stationName: stationName,
                    minutesUntilArrival: max(0, Int(date.timeIntervalSince(currentTime) / 60)),
                    arrivalTime: Self.displayTime(timeStr),
                    arrivalDate: date,
                    direction: schedule.direction
                )
                if isNorth { northbound.append(info) } else { southbound.append(info) }
            }
        }

        northbound.sort { $0.arrivalDate < $1.arrivalDate }
        southbound.sort { $0.arrivalDate < $1.arrivalDate }
        return (Array(northbound.prefix(limit)), Array(southbound.prefix(limit)))
    }

    /// Every train of `serviceDay` in one direction that stops at `stationName`, each
    /// carrying its stop times, plus the stations ahead in travel order. Trains that have
    /// already left are kept and flagged `hasDeparted` so the sheet can grey them out.
    func timetableGrid(from stationName: String,
                       northbound: Bool,
                       serviceDay: ServiceDay,
                       at date: Date = Date()) -> TimetableGrid {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let nowMinutes = Self.serviceMinutes(hour: hour, minute: minute)
        // "Already departed" only means anything for the schedule running today.
        let isToday = serviceDay == Self.currentServiceDay(for: date)

        var columns: [(minutes: Int, train: TimetableTrain)] = []
        for schedule in schedules {
            guard schedule.serviceType.localizedCaseInsensitiveContains("WEEKEND") == serviceDay.isWeekend,
                  schedule.direction.localizedCaseInsensitiveContains("North") == northbound
            else { continue }

            for train in schedule.trains {
                guard let timeStr = train.stops[stationName],
                      let (h, m) = Self.parseTime(timeStr) else { continue }
                let minutes = Self.serviceMinutes(hour: h, minute: m)

                columns.append((minutes, TimetableTrain(
                    trainNumber: train.trainNo,
                    trainType: train.type,
                    departureTime: Self.displayTime(timeStr),
                    times: train.stops.mapValues(Self.displayTime),
                    hasDeparted: isToday && minutes <= nowMinutes
                )))
            }
        }

        let trains = columns.sorted { $0.minutes < $1.minutes }.map(\.train)

        // The canonical station list runs north to south, so southbound reads as-is.
        let allNames = CaltrainStations.shared.stations.map(\.name)
        let ordered = northbound ? allNames.reversed().map { $0 } : allNames
        // Only what is still ahead: stations behind the rider are already-passed times.
        let ahead: [String]
        if let start = ordered.firstIndex(where: { $0.caseInsensitiveCompare(stationName) == .orderedSame }) {
            ahead = Array(ordered[start...])
        } else {
            ahead = ordered
        }
        // Drop stations none of these trains touch, rather than showing rows of dashes.
        let served = ahead.filter { name in trains.contains { $0.times[name] != nil } }

        return TimetableGrid(stations: served, trains: trains)
    }

    /// Which schedule is running right now — before ~3am we are still on the previous
    /// operating day, so a 1am Saturday train runs on Friday's weekday schedule.
    static func currentServiceDay(for date: Date = Date()) -> ServiceDay {
        runsWeekendSchedule(operatingDay(for: date)) ? .weekend : .weekday
    }

    // MARK: Holidays

    /// Caltrain runs its weekend timetable on holidays. The dates come from the live feed
    /// and are kept across launches, so a holiday still reads right offline.
    private static let holidaysKey = "caltrainHolidays"
    private(set) static var holidays = Set(UserDefaults.standard.stringArray(forKey: holidaysKey) ?? [])

    static func setHolidays(_ dates: Set<String>) {
        guard dates != holidays else { return }
        holidays = dates
        UserDefaults.standard.set(dates.sorted(), forKey: holidaysKey)
    }

    /// The feed's dates are Pacific calendar days, whatever zone the phone is in.
    private static let holidayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func runsWeekendSchedule(_ operatingDay: Date) -> Bool {
        Calendar.current.isDateInWeekend(operatingDay)
            || holidays.contains(holidayFormatter.string(from: operatingDay))
    }

    /// Stop times before this hour physically occur the day *after* their operating day.
    private static let serviceDayStartHour = 3

    private static func operatingDay(for date: Date) -> Date {
        let calendar = Calendar.current
        guard calendar.component(.hour, from: date) < serviceDayStartHour else { return date }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    /// Minutes since the start of the operating day. Post-midnight stops get +24h so
    /// they sort after the late-evening trains instead of jumping to the top.
    private static func serviceMinutes(hour: Int, minute: Int) -> Int {
        (hour < serviceDayStartHour ? hour + 24 : hour) * 60 + minute
    }

    private static func parseTime(_ hhmm: String) -> (hour: Int, minute: Int)? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return (hour, minute)
    }

    /// Finds the soonest future wall-clock occurrence of a scheduled stop time, limited to
    /// the operating day we are currently in. Tomorrow morning's trains are deliberately
    /// not returned — at 1am the honest answer is "no more trains", not a 5am departure
    /// five hours out.
    private func nextOccurrence(timeOfDay: String, after now: Date, serviceType: String) -> Date? {
        guard let (hour, minute) = Self.parseTime(timeOfDay) else { return nil }

        let calendar = Calendar.current
        let wantsWeekend = serviceType.localizedCaseInsensitiveContains("WEEKEND")
        let isAfterMidnight = hour < Self.serviceDayStartHour
        let startOfToday = calendar.startOfDay(for: now)
        let currentOperatingDay = Self.operatingDay(for: now)

        // Only today and tomorrow physically: a post-midnight stop on today's operating
        // day lands on tomorrow's calendar date.
        for dayOffset in 0...1 {
            guard let physicalDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let operatingDay = isAfterMidnight
                ? calendar.date(byAdding: .day, value: -1, to: physicalDay) ?? physicalDay
                : physicalDay
            guard calendar.isDate(operatingDay, inSameDayAs: currentOperatingDay) else { continue }
            guard Self.runsWeekendSchedule(operatingDay) == wantsWeekend else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: physicalDay)
            comps.hour = hour
            comps.minute = minute
            guard let candidate = calendar.date(from: comps) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    static func displayTime(_ hhmm: String) -> String {
        guard let (hour, minute) = parseTime(hhmm) else { return hhmm }
        let period = hour < 12 ? "AM" : "PM"
        var h12 = hour % 12
        if h12 == 0 { h12 = 12 }
        return String(format: "%d:%02d %@", h12, minute, period)
    }
}

// MARK: - Ride support

extension CaltrainService {

    /// Absolute wall-clock date for a `HH:mm` stop time on the operating day containing
    /// `date`. Post-midnight stops land on the next calendar day, which is what makes a
    /// 23:50 departure and a 00:20 arrival sort — and subtract — correctly.
    static func absoluteDate(forStopTime hhmm: String, operatingDayContaining date: Date) -> Date? {
        guard let (hour, minute) = parseTime(hhmm) else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: operatingDay(for: date))
        return calendar.date(byAdding: .minute, value: serviceMinutes(hour: hour, minute: minute), to: start)
    }

    /// Trains at `stationName` the rider could plausibly be aboard right now: everything
    /// still to come, plus anything that left within `recentWindow`, so the train you just
    /// boarded is still on the list. `minutesUntilArrival` goes negative for those.
    func rideCandidates(from stationName: String,
                        northbound: Bool,
                        at date: Date = Date(),
                        recentWindow: TimeInterval = 45 * 60) -> [NextTrainInfo] {

        let serviceDay = Self.currentServiceDay(for: date)
        var candidates: [NextTrainInfo] = []

        for schedule in schedules {
            guard schedule.serviceType.localizedCaseInsensitiveContains("WEEKEND") == serviceDay.isWeekend,
                  schedule.direction.localizedCaseInsensitiveContains("North") == northbound
            else { continue }

            for train in schedule.trains {
                guard let timeStr = train.stops[stationName],
                      let when = Self.absoluteDate(forStopTime: timeStr, operatingDayContaining: date),
                      when >= date.addingTimeInterval(-recentWindow)
                else { continue }

                candidates.append(NextTrainInfo(
                    trainNumber: train.trainNo,
                    trainType: train.type,
                    stationName: stationName,
                    minutesUntilArrival: Int((when.timeIntervalSince(date) / 60).rounded(.down)),
                    arrivalTime: Self.displayTime(timeStr),
                    arrivalDate: when,
                    direction: schedule.direction
                ))
            }
        }

        return candidates.sorted { $0.arrivalDate < $1.arrivalDate }
    }

    /// One train's remaining run, from `stationName` onward in travel order. Stations
    /// behind the boarding point are dropped, so the station you got on at is always the
    /// first stop of the ride.
    func itinerary(trainNumber: String,
                   northbound: Bool,
                   boardingAt stationName: String,
                   at date: Date = Date()) -> RideItinerary? {
        run(trainNumber: trainNumber, northbound: northbound, from: stationName, at: date)
    }

    /// A train's whole run, origin to terminus.
    func run(trainNumber: String, northbound: Bool, at date: Date = Date()) -> RideItinerary? {
        run(trainNumber: trainNumber, northbound: northbound, from: nil, at: date)
    }

    /// Every run on the current timetable that could be out on the line at `date`: past
    /// its printed departure, and not more than `slack` past its printed arrival, so a
    /// late train isn't dropped the minute it should have finished.
    func runs(at date: Date = Date(), slack: TimeInterval = 30 * 60) -> [RideItinerary] {
        let serviceDay = Self.currentServiceDay(for: date)
        var out: [RideItinerary] = []
        for schedule in schedules
        where schedule.serviceType.localizedCaseInsensitiveContains("WEEKEND") == serviceDay.isWeekend {
            let northbound = schedule.direction.localizedCaseInsensitiveContains("North")
            for train in schedule.trains {
                guard let run = Self.run(of: train, northbound: northbound, from: nil, at: date),
                      let origin = run.origin, let terminus = run.terminus,
                      origin.scheduled <= date,
                      date <= terminus.scheduled.addingTimeInterval(slack)
                else { continue }
                out.append(run)
            }
        }
        return out
    }

    /// `stationName` nil starts the run at the train's origin.
    private func run(trainNumber: String,
                     northbound: Bool,
                     from stationName: String?,
                     at date: Date) -> RideItinerary? {
        let serviceDay = Self.currentServiceDay(for: date)

        for schedule in schedules {
            guard schedule.serviceType.localizedCaseInsensitiveContains("WEEKEND") == serviceDay.isWeekend,
                  schedule.direction.localizedCaseInsensitiveContains("North") == northbound,
                  let train = schedule.trains.first(where: { $0.trainNo == trainNumber }),
                  let run = Self.run(of: train, northbound: northbound, from: stationName, at: date)
            else { continue }
            return run
        }

        return nil
    }

    private static func run(of train: Train,
                            northbound: Bool,
                            from stationName: String?,
                            at date: Date) -> RideItinerary? {
        if let stationName, train.stops[stationName] == nil { return nil }

        // The canonical list runs north to south, so southbound reads as-is.
        let allNames = CaltrainStations.shared.stations.map(\.name)
        let ordered = northbound ? allNames.reversed().map { $0 } : allNames
        let start: Int
        if let stationName {
            guard let index = ordered.firstIndex(where: { $0.caseInsensitiveCompare(stationName) == .orderedSame })
            else { return nil }
            start = index
        } else {
            start = 0
        }

        let stops: [RideStop] = ordered[start...].compactMap { name in
            guard let timeStr = train.stops[name],
                  let station = CaltrainStations.shared.station(named: name),
                  let when = absoluteDate(forStopTime: timeStr, operatingDayContaining: date)
            else { return nil }
            return RideStop(station: station, scheduled: when)
        }

        guard !stops.isEmpty else { return nil }
        return RideItinerary(trainNumber: train.trainNo,
                             trainType: train.type,
                             northbound: northbound,
                             stops: stops)
    }
}

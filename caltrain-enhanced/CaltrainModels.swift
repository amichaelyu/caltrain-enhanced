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
}

/// One column of the timetable grid: a single train and its stop times.
struct TimetableTrain: Identifiable {
    let id = UUID()
    let trainNumber: String
    let trainType: String?
    let departureTime: String              // display time at the reference station
    let times: [String: String]            // station name -> display time
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
        CaltrainStation(name: "22nd Street", coordinate: CLLocationCoordinate2D(latitude: 37.7574, longitude: -122.3892)),
        CaltrainStation(name: "Bayshore", coordinate: CLLocationCoordinate2D(latitude: 37.7096, longitude: -122.4014)),
        CaltrainStation(name: "S. San Francisco", coordinate: CLLocationCoordinate2D(latitude: 37.6644, longitude: -122.4076)),
        CaltrainStation(name: "San Bruno", coordinate: CLLocationCoordinate2D(latitude: 37.6303, longitude: -122.4111)),
        CaltrainStation(name: "Millbrae", coordinate: CLLocationCoordinate2D(latitude: 37.5996, longitude: -122.3869)),
        CaltrainStation(name: "Broadway", coordinate: CLLocationCoordinate2D(latitude: 37.5878, longitude: -122.3625)),
        CaltrainStation(name: "Burlingame", coordinate: CLLocationCoordinate2D(latitude: 37.5792, longitude: -122.3448)),
        CaltrainStation(name: "San Mateo", coordinate: CLLocationCoordinate2D(latitude: 37.5688, longitude: -122.3239)),
        CaltrainStation(name: "Hayward Park", coordinate: CLLocationCoordinate2D(latitude: 37.5531, longitude: -122.3092)),
        CaltrainStation(name: "Hillsdale", coordinate: CLLocationCoordinate2D(latitude: 37.5377, longitude: -122.2977)),
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
        CaltrainStation(name: "Capitol", coordinate: CLLocationCoordinate2D(latitude: 37.2874, longitude: -121.8425)),
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

    /// Upcoming trains from `stationName` in one direction, each carrying its stop times,
    /// plus the stations ahead in travel order. Trains that have already left the
    /// reference station are excluded, as are stations the trains have already passed.
    func timetableGrid(from stationName: String,
                       northbound: Bool,
                       at date: Date = Date(),
                       maxTrains: Int = 12) -> TimetableGrid {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let wantsWeekend = calendar.isDateInWeekend(Self.operatingDay(for: date))
        let nowMinutes = Self.serviceMinutes(hour: hour, minute: minute)

        var columns: [(minutes: Int, train: TimetableTrain)] = []
        for schedule in schedules {
            guard schedule.serviceType.localizedCaseInsensitiveContains("WEEKEND") == wantsWeekend,
                  schedule.direction.localizedCaseInsensitiveContains("North") == northbound
            else { continue }

            for train in schedule.trains {
                guard let timeStr = train.stops[stationName],
                      let (h, m) = Self.parseTime(timeStr) else { continue }
                let minutes = Self.serviceMinutes(hour: h, minute: m)
                guard minutes > nowMinutes else { continue }   // already gone from this station

                columns.append((minutes, TimetableTrain(
                    trainNumber: train.trainNo,
                    trainType: train.type,
                    departureTime: Self.displayTime(timeStr),
                    times: train.stops.mapValues(Self.displayTime)
                )))
            }
        }

        let trains = columns.sorted { $0.minutes < $1.minutes }
            .prefix(maxTrains)
            .map(\.train)

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

    /// Which service is running right now — before ~3am we are still on the previous
    /// operating day, so a 1am Saturday train runs on Friday's weekday schedule.
    static func serviceLabel(for date: Date = Date()) -> String {
        Calendar.current.isDateInWeekend(operatingDay(for: date)) ? "Weekend service" : "Weekday service"
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

    /// Finds the soonest future wall-clock occurrence of a scheduled stop time,
    /// respecting weekday/weekend service and trains that cross midnight.
    private func nextOccurrence(timeOfDay: String, after now: Date, serviceType: String) -> Date? {
        guard let (hour, minute) = Self.parseTime(timeOfDay) else { return nil }

        let calendar = Calendar.current
        let wantsWeekend = serviceType.localizedCaseInsensitiveContains("WEEKEND")
        let isAfterMidnight = hour < Self.serviceDayStartHour
        let startOfToday = calendar.startOfDay(for: now)

        for dayOffset in 0...2 {
            guard let physicalDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let operatingDay = isAfterMidnight
                ? calendar.date(byAdding: .day, value: -1, to: physicalDay) ?? physicalDay
                : physicalDay
            guard calendar.isDateInWeekend(operatingDay) == wantsWeekend else { continue }

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

//
//  CaltrainLiveService.swift
//  caltrain-enhanced
//
//  Live predictions for every Caltrain on the line, from 511.org by way of
//  www.yumichael.com/api/caltrain. The app never calls 511 itself: its key is rate-limited
//  per key, not per device, so the site's worker fetches every 15s for everyone and
//  this just reads the result. Data provided by 511.org.
//

import Foundation
import CoreLocation
import Combine

// MARK: - Feed

struct LiveFeed: Decodable {
    /// When 511 produced the data.
    let updated: Date
    /// When the worker fetched it from 511.
    let fetched: Date
    let trains: [LiveTrain]
    /// Alerts that haven't ended yet. Optional so a worker that predates them still decodes.
    let alerts: [LiveAlert]?
    /// "yyyy-MM-dd" (Pacific) dates that run the holiday schedule.
    let holidays: [String]?
}

/// A 511 service alert: a delay, a cancellation, track work, an elevator out.
struct LiveAlert: Decodable, Identifiable {
    struct Period: Decodable {
        let start: Date?
        let end: Date?
    }

    let id: String
    let header: String
    let description: String?
    let url: String?
    /// GTFS-Realtime enum names, e.g. "CONSTRUCTION" and "SIGNIFICANT_DELAYS".
    let cause: String?
    let effect: String?
    /// Empty means always in force; a nil bound is open-ended.
    let periods: [Period]
    let trains: [String]
    let stations: [String]
    let lines: [String]

    func isActive(at now: Date) -> Bool {
        periods.isEmpty || periods.contains { period in
            (period.start.map { $0 <= now } ?? true) && (period.end.map { now < $0 } ?? true)
        }
    }

    /// A train named by a no-service alert isn't running, whatever the timetable says.
    var cancelsTrains: Bool { effect == "NO_SERVICE" && !trains.isEmpty }

    /// Plain words for the effect; nil for the catch-alls not worth a label.
    var effectLabel: String? {
        switch effect {
        case "NO_SERVICE": "No service"
        case "REDUCED_SERVICE": "Reduced service"
        case "SIGNIFICANT_DELAYS": "Delays"
        case "DETOUR": "Detour"
        case "ADDITIONAL_SERVICE": "Extra service"
        case "MODIFIED_SERVICE": "Modified service"
        case "STOP_MOVED": "Stop moved"
        case "ACCESSIBILITY_ISSUE": "Accessibility"
        default: nil
        }
    }

    func mentions(station: String) -> Bool {
        stations.contains { $0.caseInsensitiveCompare(station) == .orderedSame }
    }
}

/// One train in service: its remaining stops, soonest first. Stops it has already made are
/// gone from the list, and so is the terminus — 511 only predicts departures.
struct LiveTrain: Decodable {
    let train: String
    let direction: String
    let latitude: Double?
    let longitude: Double?
    let stops: [LiveStop]
    /// When this position was current. The feed has no per-train time, so it's stamped
    /// with the first snapshot that put the train here.
    var recordedAt: Date?

    var northbound: Bool { direction == "N" }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func stop(named name: String) -> LiveStop? {
        stops.first { $0.station.caseInsensitiveCompare(name) == .orderedSame }
    }
}

struct LiveStop: Decodable {
    /// Already spelled the way `CaltrainStations` spells it.
    let station: String
    /// Predicted departure. Nil until the train is tracked, e.g. before it leaves its origin.
    let expected: Date?
    /// Predicted arrival, usually a minute before `expected`. Nil when 511 doesn't give one.
    let arrival: Date?
}

// MARK: - Service

@MainActor
final class CaltrainLiveService: ObservableObject {
    static let shared = CaltrainLiveService()

    private static let endpoint = URL(string: "https://www.yumichael.com/api/caltrain")!

    /// The worker refreshes trips every 15s, so polling faster just re-reads its cache.
    private static let pollInterval: Duration = .seconds(15)

    /// Past this a snapshot is history, not a prediction, and the ride page goes back to
    /// the timetable rather than trusting it.
    private static let maxAge: TimeInterval = 5 * 60

    @Published private(set) var feed: LiveFeed?

    /// Each train's position and the first snapshot it appeared in. 511 restamps every
    /// snapshot, but a train's position can sit unchanged in them for minutes; stamping it
    /// with the latest one makes a stale fix look fresh, and the train is carried forward
    /// from it, then snapped back when the next snapshot repeats it.
    private var sightings: [String: (latitude: Double?, longitude: Double?, since: Date)] = [:]

    private var pollTask: Task<Void, Never>?
    /// Every screen that wants the feed right now. Polling runs while any of them do, so
    /// one tab disappearing can't switch it off under another that just appeared.
    private var clients: Set<String> = []

    /// Polls until every client has called `stop(for:)`. Safe to call repeatedly.
    func start(for client: String) {
        clients.insert(client)
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop(for client: String) {
        clients.remove(client)
        guard clients.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// The live run for a timetable train, if it's in service and the data is fresh.
    func train(_ number: String, northbound: Bool, at now: Date = Date()) -> LiveTrain? {
        guard let feed, now.timeIntervalSince(feed.fetched) < Self.maxAge else { return nil }
        guard var train = feed.trains.first(where: { $0.train == number && $0.northbound == northbound })
        else { return nil }
        // A next stop due this long ago means 511 stopped updating the train, not that it's
        // standing there: a train held that long gets fresh predictions.
        if let due = train.stops.first?.expected, now.timeIntervalSince(due) > Self.maxAge { return nil }
        train.recordedAt = sightings[Self.key(number, northbound: northbound)]?.since ?? feed.updated
        return train
    }

    private static func key(_ number: String, northbound: Bool) -> String {
        "\(number)-\(northbound ? "N" : "S")"
    }

    /// Alerts in force right now. Unlike predictions these don't go stale with the
    /// snapshot: an alert carries its own end time.
    func activeAlerts(at now: Date = Date()) -> [LiveAlert] {
        (feed?.alerts ?? []).filter { $0.isActive(at: now) }
    }

    func isCancelled(_ trainNumber: String, at now: Date = Date()) -> Bool {
        activeAlerts(at: now).contains { $0.cancelsTrains && $0.trains.contains(trainNumber) }
    }

    private func refresh() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.endpoint)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let feed = try Self.decoder.decode(LiveFeed.self, from: data)
            if let holidays = feed.holidays {
                CaltrainService.setHolidays(Set(holidays))
            }
            var sightings: [String: (latitude: Double?, longitude: Double?, since: Date)] = [:]
            for train in feed.trains {
                let key = Self.key(train.train, northbound: train.northbound)
                if let seen = self.sightings[key], seen.latitude == train.latitude, seen.longitude == train.longitude {
                    sightings[key] = seen
                } else {
                    sightings[key] = (train.latitude, train.longitude, feed.updated)
                }
            }
            self.sightings = sightings
            self.feed = feed
        } catch {
            // Keep the last snapshot; `maxAge` retires it if the outage lasts.
        }
    }

    /// The worker passes 511's timestamps through as-is (whole seconds) and stamps its own
    /// with milliseconds, so accept both.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = (try? fractional.parse(string)) ?? (try? whole.parse(string)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Bad date \(string)"))
            }
            return date
        }
        return decoder
    }()
}

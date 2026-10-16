//
//  CaltrainLiveService.swift
//  caltrain-enhanced
//
//  Live predictions for every Caltrain on the line, from 511.org by way of
//  www.yumichael.com/api/caltrain. The app never calls 511 itself: its key is rate-limited
//  per key, not per device, so the site's worker fetches once a minute for everyone and
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
}

/// One train in service: its remaining stops, soonest first. Stops it has already made are
/// gone from the list, and so is the terminus — 511 only predicts departures.
struct LiveTrain: Decodable {
    let train: String
    let direction: String
    let latitude: Double?
    let longitude: Double?
    let stops: [LiveStop]

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
    let aimed: Date
    /// Nil until the train is tracked, e.g. before it leaves its origin.
    let expected: Date?

    /// How late the prediction runs against 511's own schedule. Negative when early.
    var delay: TimeInterval { expected.map { $0.timeIntervalSince(aimed) } ?? 0 }
}

// MARK: - Service

@MainActor
final class CaltrainLiveService: ObservableObject {
    static let shared = CaltrainLiveService()

    private static let endpoint = URL(string: "https://www.yumichael.com/api/caltrain")!

    /// The worker refreshes once a minute, so polling faster just re-reads its cache.
    private static let pollInterval: Duration = .seconds(60)

    /// Past this a snapshot is history, not a prediction, and the ride page goes back to
    /// the timetable rather than trusting it.
    private static let maxAge: TimeInterval = 5 * 60

    @Published private(set) var feed: LiveFeed?

    private var pollTask: Task<Void, Never>?

    /// Polls until `stop()`. Safe to call repeatedly.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The live run for a timetable train, if it's in service and the data is fresh.
    func train(_ number: String, northbound: Bool, at now: Date = Date()) -> LiveTrain? {
        guard let feed, now.timeIntervalSince(feed.fetched) < Self.maxAge else { return nil }
        return feed.trains.first { $0.train == number && $0.northbound == northbound }
    }

    private func refresh() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.endpoint)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            feed = try Self.decoder.decode(LiveFeed.self, from: data)
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

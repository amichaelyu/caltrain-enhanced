//
//  widget.swift
//  widget
//
//  Created by Michael Yu on 6/13/25.
//

import WidgetKit
import SwiftUI
import CoreLocation

// MARK: - Design tokens

extension Color {
    static let caltrainRed = Color(red: 0.796, green: 0.125, blue: 0.180) // #CB202E
}

// MARK: - Timeline provider

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            configuration: ConfigurationAppIntent(),
            northbound: NextTrainInfo(trainNumber: "123", trainType: "Local Weekday",
                                      stationName: "Palo Alto", minutesUntilArrival: 5,
                                      arrivalTime: "2:15 PM", arrivalDate: Date(),
                                      direction: "Northbound to San Francisco"),
            southbound: NextTrainInfo(trainNumber: "456", trainType: "Limited",
                                      stationName: "Palo Alto", minutesUntilArrival: 8,
                                      arrivalTime: "2:23 PM", arrivalDate: Date(),
                                      direction: "Southbound to San Jose / Gilroy"),
            travelTimes: nil,
            stationName: "Palo Alto",
            error: nil
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        await makeEntry(date: Date(), configuration: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        let entry = await makeEntry(date: Date(), configuration: configuration)
        // Refresh every minute so the countdown stays accurate.
        let next = Calendar.current.date(byAdding: .minute, value: 1, to: entry.date) ?? entry.date
        return Timeline(entries: [entry], policy: .after(next))
    }

    // MARK: Data assembly

    private func makeEntry(date: Date, configuration: ConfigurationAppIntent) async -> SimpleEntry {
        let nearest = await currentNearestStation()

        let fallbackName: String = nearest?.name
            ?? SharedConstants.sharedDefaults?.string(forKey: SharedConstants.lastKnownStationKey)
            ?? "Palo Alto"
        let northStationName: String = configuration.northboundStation?.id ?? fallbackName
        let southStationName: String = configuration.southboundStation?.id ?? fallbackName

        let north = CaltrainService.shared.nextTrainsBothDirections(from: northStationName, currentTime: date).northbound
        let south = CaltrainService.shared.nextTrainsBothDirections(from: southStationName, currentTime: date).southbound

        // Travel time to the primary (nearest / northbound) station from the last known location.
        let primaryStation = nearest ?? CaltrainStations.shared.station(named: northStationName)
        var travel: TravelTimes?
        if let station = primaryStation, let origin = SharedLocationManager.shared.getStoredLocation()?.coordinate {
            travel = await TravelTimeService.shared.travelTimes(from: origin, to: station)
        }

        let headerName: String = nearest?.name ?? northStationName
        let error: String? = (north == nil && south == nil) ? "No upcoming trains" : nil

        return SimpleEntry(
            date: date,
            configuration: configuration,
            northbound: north,
            southbound: south,
            travelTimes: travel,
            stationName: headerName,
            error: error
        )
    }

    private func currentNearestStation() async -> CaltrainStation? {
        if SharedLocationManager.shared.isLocationDataFresh(),
           let cached = SharedLocationManager.shared.getStoredNearestStation() {
            return cached
        }
        return await withCheckedContinuation { continuation in
            SharedLocationManager.shared.getCurrentNearestStation { station in
                continuation.resume(returning: station)
            }
        }
    }
}

// MARK: - Entry

struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let northbound: NextTrainInfo?
    let southbound: NextTrainInfo?
    let travelTimes: TravelTimes?
    let stationName: String?
    let error: String?
}

// MARK: - Views

struct widgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

private struct WidgetHeader: View {
    let stationName: String?
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "location.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.caltrainRed)
            Text(stationName ?? "Caltrain")
                .font(.caption2)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DirectionLine: View {
    let systemImage: String
    let train: NextTrainInfo?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if let train {
                Text(train.minutesUntilArrival == 0 ? "Now" : "\(train.minutesUntilArrival)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(train.minutesUntilArrival <= 5 ? Color.caltrainRed : .primary)
                if train.minutesUntilArrival != 0 {
                    Text("min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(train.arrivalTime)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 20, weight: .light, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("No train")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TravelLine: View {
    let times: TravelTimes?
    var body: some View {
        HStack(spacing: 12) {
            travelItem("figure.walk", times?.walkingMinutes)
            travelItem("bicycle", times?.bikingMinutes)
            travelItem("car.fill", times?.drivingMinutes)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func travelItem(_ symbol: String, _ minutes: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(minutes.map { "\($0)" } ?? "—")
                .font(.caption2)
                .monospacedDigit()
        }
    }
}

private struct SmallWidgetView: View {
    let entry: SimpleEntry

    // Pick the sooner of the two directions for the hero.
    private var soonest: (String, NextTrainInfo)? {
        let candidates = [("arrow.up", entry.northbound), ("arrow.down", entry.southbound)]
            .compactMap { (img, t) in t.map { (img, $0) } }
        return candidates.min { $0.1.arrivalDate < $1.1.arrivalDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(stationName: entry.stationName)
            Spacer(minLength: 0)
            if let (image, train) = soonest {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: image).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    Text(train.minutesUntilArrival == 0 ? "Now" : "\(train.minutesUntilArrival)")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(train.minutesUntilArrival <= 5 ? Color.caltrainRed : .primary)
                    if train.minutesUntilArrival != 0 {
                        Text("min").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(train.arrivalTime) · #\(train.trainNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.error ?? "No trains")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            TravelLine(times: entry.travelTimes)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(stationName: entry.stationName)

            if entry.northbound == nil && entry.southbound == nil {
                Spacer(minLength: 0)
                Text(entry.error ?? "No upcoming trains")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                DirectionLine(systemImage: "arrow.up", train: entry.northbound)
                DirectionLine(systemImage: "arrow.down", train: entry.southbound)
            }

            Spacer(minLength: 0)
            Divider().overlay(Color.primary.opacity(0.08))
            TravelLine(times: entry.travelTimes)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widget

struct widget: Widget {
    let kind: String = "widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            widgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Caltrain")
        .description("Next train each way from your nearest station, with time to get there.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    widget()
} timeline: {
    SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        northbound: NextTrainInfo(trainNumber: "123", trainType: "Local Weekday", stationName: "Palo Alto",
                                  minutesUntilArrival: 4, arrivalTime: "2:15 PM", arrivalDate: .now,
                                  direction: "Northbound to San Francisco"),
        southbound: NextTrainInfo(trainNumber: "456", trainType: "Limited", stationName: "Palo Alto",
                                  minutesUntilArrival: 12, arrivalTime: "2:27 PM", arrivalDate: .now,
                                  direction: "Southbound to San Jose / Gilroy"),
        travelTimes: TravelTimes(stationName: "Palo Alto", walkingMinutes: 11, bikingMinutes: 4,
                                 drivingMinutes: 3, distanceMeters: 900, timestamp: .now),
        stationName: "Palo Alto",
        error: nil
    )
}

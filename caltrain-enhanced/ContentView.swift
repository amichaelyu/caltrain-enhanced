//
//  ContentView.swift
//  caltrain-enhanced
//
//  Created by Michael Yu on 6/13/25.
//

import SwiftUI
import CoreLocation

// MARK: - Design tokens

extension Color {
    /// Restrained Caltrain red — the single accent in an otherwise monochrome UI.
    static let caltrainRed = Color(red: 0.84, green: 0.0, blue: 0.11)
}

private enum Metrics {
    static let cardCorner: CGFloat = 16
    static let hairline: CGFloat = 0.5
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject private var location = SharedLocationManager.shared

    @State private var northbound: [NextTrainInfo] = []
    @State private var southbound: [NextTrainInfo] = []
    @State private var travelTimes: TravelTimes?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if location.isDenied {
                    permissionCard
                } else if let station = location.nearestStation {
                    DepartureBoard(northbound: northbound.first, southbound: southbound.first)

                    TravelTimesStrip(times: travelTimes,
                                     hasLocation: location.userLocation != nil,
                                     stationName: station.name)

                    upcomingSection
                } else {
                    loadingCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            location.requestLocation()
            location.startContinuousLocationUpdates()
            refreshTrains()
        }
        .onReceive(ticker) { date in
            now = date
            refreshTrains()
        }
        .onChange(of: location.nearestStation?.name) {
            refreshTrains()
        }
        .task(id: location.nearestStation?.name) {
            await loadTravelTimes()
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caltrain")
                .font(.caption)
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.caltrainRed)
                Text(location.nearestStation?.name ?? "Locating…")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Later departures")

            HStack(alignment: .top, spacing: 12) {
                UpcomingColumn(title: "Northbound", systemImage: "arrow.up",
                               trains: Array(northbound.dropFirst().prefix(4)))
                UpcomingColumn(title: "Southbound", systemImage: "arrow.down",
                               trains: Array(southbound.dropFirst().prefix(4)))
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Finding the nearest station…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .cardBackground()
    }

    private var permissionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash")
                .font(.system(size: 28))
                .foregroundStyle(Color.caltrainRed)
            Text("Location access is off")
                .font(.headline)
            Text("Turn on location to see the nearest station and your next trains.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.caltrainRed)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardBackground()
    }

    // MARK: Data

    private func refreshTrains() {
        guard let station = location.nearestStation else { return }
        let upcoming = CaltrainService.shared.upcomingTrains(from: station.name, currentTime: Date())
        northbound = upcoming.northbound
        southbound = upcoming.southbound
    }

    private func loadTravelTimes() async {
        guard let station = location.nearestStation,
              let origin = location.userLocation?.coordinate else { return }
        let result = await TravelTimeService.shared.travelTimes(from: origin, to: station)
        await MainActor.run { self.travelTimes = result }
    }
}

// MARK: - Departure board (hero)

private struct DepartureBoard: View {
    let northbound: NextTrainInfo?
    let southbound: NextTrainInfo?

    var body: some View {
        VStack(spacing: 0) {
            DepartureRow(direction: "Northbound", destination: "San Francisco",
                         systemImage: "arrow.up", train: northbound)
            Divider().overlay(Color.primary.opacity(0.08))
            DepartureRow(direction: "Southbound", destination: "San Jose",
                         systemImage: "arrow.down", train: southbound)
        }
        .cardBackground()
    }
}

private struct DepartureRow: View {
    let direction: String
    let destination: String
    let systemImage: String
    let train: NextTrainInfo?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(direction)
                        .font(.caption)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
                .foregroundStyle(.secondary)

                Text(destination)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                if let train {
                    Text("\(train.arrivalTime) · #\(train.trainNumber)\(train.trainType.map { " · \(shortType($0))" } ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No more trains today")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            countdown
        }
        .padding(20)
    }

    @ViewBuilder private var countdown: some View {
        if let train {
            VStack(alignment: .trailing, spacing: 0) {
                Text(train.minutesUntilArrival == 0 ? "Now" : "\(train.minutesUntilArrival)")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(train.minutesUntilArrival <= 5 ? Color.caltrainRed : .primary)
                if train.minutesUntilArrival != 0 {
                    Text("min")
                        .font(.caption2)
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        } else {
            Text("—")
                .font(.system(size: 40, weight: .light, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private func shortType(_ type: String) -> String {
        if type.localizedCaseInsensitiveContains("Express") { return "Express" }
        if type.localizedCaseInsensitiveContains("Limited") { return "Limited" }
        if type.localizedCaseInsensitiveContains("South County") { return "S. County" }
        return "Local"
    }
}

// MARK: - Travel times

private struct TravelTimesStrip: View {
    let times: TravelTimes?
    let hasLocation: Bool
    let stationName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Getting to the station")
                Spacer()
                if let times {
                    Text(String(format: "%.1f mi", times.distanceMiles))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                TravelTile(systemImage: "figure.walk", label: "Walk", minutes: times?.walkingMinutes)
                TravelTile(systemImage: "bicycle", label: "Bike", minutes: times?.bikingMinutes)
                TravelTile(systemImage: "car.fill", label: "Drive", minutes: times?.drivingMinutes)
            }
        }
    }
}

private struct TravelTile: View {
    let systemImage: String
    let label: String
    let minutes: Int?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.primary)
            if let minutes {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(minutes)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .light, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Text(label)
                .font(.caption2)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .cardBackground()
    }
}

// MARK: - Upcoming list

private struct UpcomingColumn: View {
    let title: String
    let systemImage: String
    let trains: [NextTrainInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title).font(.caption).textCase(.uppercase).tracking(1)
            }
            .foregroundStyle(.secondary)

            if trains.isEmpty {
                Text("—").foregroundStyle(.tertiary).font(.subheadline)
            } else {
                ForEach(trains) { train in
                    HStack {
                        Text(train.arrivalTime)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Spacer(minLength: 6)
                        Text("\(train.minutesUntilArrival)m")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

// MARK: - Shared bits

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    func cardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

#Preview {
    ContentView()
}

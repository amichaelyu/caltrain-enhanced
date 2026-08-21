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

/// Service tier, derived from the timetable's free-form `type` string. The embedded
/// schedule only ever uses "Local Weekday"/"Local Weekend", "Limited", "Express" and
/// "South County" — anything unrecognized falls back to Local.
enum TrainClass {
    case express, limited, southCounty, local

    init(_ rawType: String?) {
        guard let rawType else { self = .local; return }
        if rawType.localizedCaseInsensitiveContains("Express") { self = .express }
        else if rawType.localizedCaseInsensitiveContains("Limited") { self = .limited }
        else if rawType.localizedCaseInsensitiveContains("South County") { self = .southCounty }
        else { self = .local }
    }

    var label: String {
        switch self {
        case .express: "Express"
        case .limited: "Limited"
        case .southCounty: "S. County"
        case .local: "Local"
        }
    }

    var color: Color {
        switch self {
        case .express: Color.caltrainRed
        case .limited: Color(red: 0.16, green: 0.58, blue: 0.85)
        case .southCounty: Color(red: 0.90, green: 0.49, blue: 0.07)
        case .local: Color.secondary
        }
    }
}

/// Tinted pill marking a train's service tier. Uses a translucent fill rather than a
/// solid one so it reads the same in light and dark mode.
private struct TrainTypeBadge: View {
    let trainClass: TrainClass

    var body: some View {
        Text(trainClass.label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(trainClass.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(trainClass.color.opacity(0.14)))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(trainClass.color.opacity(0.30), lineWidth: Metrics.hairline))
    }
}

/// Bare color dot for the narrow "Later departures" columns, where a labeled pill
/// eats enough width to wrap the departure time onto two lines.
private struct TrainTypeDot: View {
    let trainClass: TrainClass

    var body: some View {
        Circle()
            .fill(trainClass.color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject private var location = SharedLocationManager.shared

    @State private var northbound: [NextTrainInfo] = []
    @State private var southbound: [NextTrainInfo] = []
    @State private var travelTimes: TravelTimes?
    @State private var now = Date()
    @State private var showSettings = false

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if location.isDenied {
                    permissionCard
                } else if let station = location.nearestStation {
                    DepartureBoard(northbound: northbound.first, southbound: southbound.first)

                    TravelTimesStrip(times: travelTimes, station: station)

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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
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
        HStack(alignment: .top, spacing: 12) {
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

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(Color(.secondarySystemGroupedBackground))
                    )
            }
            .accessibilityLabel("Settings")
        }
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
                    HStack(spacing: 7) {
                        Text("\(train.arrivalTime) · #\(train.trainNumber)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TrainTypeBadge(trainClass: TrainClass(train.trainType))
                    }
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
}

// MARK: - Travel times

private struct TravelTimesStrip: View {
    let times: TravelTimes?
    let station: CaltrainStation

    @AppStorage(MapsProvider.storageKey) private var mapsProviderRaw = MapsProvider.apple.rawValue

    private var provider: MapsProvider {
        MapsProvider(rawValue: mapsProviderRaw) ?? .apple
    }

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
                TravelTile(systemImage: "figure.walk", label: "Walk",
                           minutes: times?.walkingMinutes, action: { navigate(.walking) })
                TravelTile(systemImage: "bicycle", label: "Bike",
                           minutes: times?.bikingMinutes, action: { navigate(.cycling) })
                TravelTile(systemImage: "car.fill", label: "Drive",
                           minutes: times?.drivingMinutes, action: { navigate(.driving) })
            }
        }
    }

    private func navigate(_ mode: TravelMode) {
        MapsLauncher.openDirections(to: station, mode: mode, using: provider)
    }
}

private struct TravelTile: View {
    let systemImage: String
    let label: String
    let minutes: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) { tile }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) directions to the station")
    }

    private var tile: some View {
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
                    HStack(spacing: 6) {
                        TrainTypeDot(trainClass: TrainClass(train.trainType))
                        Text(train.arrivalTime)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
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

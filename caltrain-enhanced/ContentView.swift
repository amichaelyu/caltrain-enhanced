//
//  ContentView.swift
//  caltrain-enhanced
//
//  Created by Michael Yu on 6/13/25.
//

import SwiftUI
import CoreLocation
import UIKit

// MARK: - Design tokens

extension Color {
    /// Restrained Caltrain red — the single accent in an otherwise monochrome UI.
    static let caltrainRed = Color(red: 0.796, green: 0.125, blue: 0.180) // #CB202E
}

private enum Metrics {
    static let cardCorner: CGFloat = 16
    static let hairline: CGFloat = 0.5
}

/// Service tier, derived from the timetable's free-form `type` string. The embedded
/// schedule only ever uses "Local Weekday"/"Local Weekend", "Limited", "Express" and
/// "South County" — anything unrecognized falls back to Local.
enum TrainClass: CaseIterable, Identifiable {
    case express, limited, southCounty, local

    var id: Self { self }

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

    /// Three-letter form, for the narrow timetable column headers.
    var shortLabel: String {
        switch self {
        case .express: "EXP"
        case .limited: "LTD"
        case .southCounty: "SC"
        case .local: "LOC"
        }
    }

    /// One-line plain-English gloss, used by the Settings color key.
    var description: String {
        switch self {
        case .express: "Skips most stops. Fastest end to end."
        case .limited: "Skips some of the smaller stops."
        case .southCounty: "Runs south of San Jose Diridon."
        case .local: "Stops at every station."
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
struct TrainTypeBadge: View {
    let trainClass: TrainClass
    var compact: Bool = false

    var body: some View {
        Text(compact ? trainClass.shortLabel : trainClass.label)
            .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(trainClass.color)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
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

/// A travel direction. Owns the labels that the hero board, the "Later departures"
/// columns and the timetable sheet all need to agree on.
enum TimetableDirection: Identifiable {
    case northbound, southbound

    var id: Self { self }
    var isNorth: Bool { self == .northbound }
    var flipped: TimetableDirection { isNorth ? .southbound : .northbound }
    var title: String { isNorth ? "Northbound" : "Southbound" }
    var destination: String { isNorth ? "San Francisco" : "San Jose" }
    var systemImage: String { isNorth ? "arrow.up" : "arrow.down" }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject private var location = SharedLocationManager.shared

    @State private var northbound: [NextTrainInfo] = []
    @State private var southbound: [NextTrainInfo] = []
    @State private var travelTimes: TravelTimes?
    @State private var now = Date()
    @State private var showSettings = false
    @State private var isEditingStation = false
    @State private var stationQuery = ""
    @State private var stationQueryEdited = false
    @FocusState private var stationFieldFocused: Bool
    @State private var timetableDirection: TimetableDirection?
    @State private var direction: TimetableDirection = .northbound

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if isEditingStation {
                    StationSuggestions(matches: suggestions,
                                       activeName: location.activeStation?.name,
                                       nearestName: location.nearestStation?.name,
                                       onSelect: select)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let station = location.activeStation {
                    ZStack {
                        DepartureBoard(direction: direction,
                                       trains: direction.isNorth ? northbound : southbound,
                                       onToggle: flipDirection,
                                       onOpenTimetable: { timetableDirection = direction })
                            .id(direction)
                            // Northbound arrives from the right, southbound from the left;
                            // the outgoing card leaves by the opposite edge.
                            .transition(.asymmetric(
                                insertion: .move(edge: direction.isNorth ? .trailing : .leading),
                                removal: .move(edge: direction.isNorth ? .leading : .trailing)
                            ))
                    }
                    .clipped()

                    TravelTimesStrip(times: travelTimes, station: station)
                } else if location.isDenied {
                    permissionCard
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
        .sheet(item: $timetableDirection) { direction in
            TimetableSheet(direction: direction,
                           stationName: location.activeStation?.name ?? "")
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
        .onChange(of: location.activeStation?.name) {
            refreshTrains()
        }
        .task(id: location.activeStation?.name) {
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

                if isEditingStation {
                    stationField
                } else {
                    stationName
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isEditingStation {
                Button("Cancel") { endEditingStation() }
                    .font(.subheadline)
                    .tint(Color.caltrainRed)
                    .padding(.top, 6)
            } else {
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
    }

    /// The station name doubles as the search field: tapping it turns the same text
    /// editable in place rather than opening a separate screen.
    private var stationName: some View {
        Button { beginEditingStation() } label: {
            HStack(spacing: 8) {
                // A pin means "you picked this"; the arrow means "this is where you are".
                Image(systemName: location.isUsingPickedStation ? "mappin.circle.fill" : "location.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.caltrainRed)
                Text(location.activeStation?.name ?? "Locating…")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Station: \(location.activeStation?.name ?? "locating")")
        .accessibilityHint("Edit to search for another station")
    }

    private var stationField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.caltrainRed)

            TextField("Station", text: $stationQuery)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($stationFieldFocused)
                // Return takes the top suggestion, so "moun" + return is enough.
                .onSubmit { if let best = suggestions.first { select(best.station) } }
                .onChange(of: stationQuery) { _, newValue in
                    if newValue != (location.activeStation?.name ?? "") { stationQueryEdited = true }
                }
                // The name arrives pre-filled and selected, so the first keystroke
                // replaces it instead of appending to it.
                .onReceive(NotificationCenter.default
                    .publisher(for: UITextField.textDidBeginEditingNotification)) { note in
                        (note.object as? UITextField)?.selectAll(nil)
                    }

            if !stationQuery.isEmpty {
                Button {
                    stationQuery = ""
                    stationQueryEdited = true
                    stationFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear")
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

            Button("Choose a station instead") { beginEditingStation() }
                .font(.subheadline)
                .tint(Color.caltrainRed)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardBackground()
    }

    // MARK: Data

    private func flipDirection() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            direction = direction.flipped
        }
    }

    /// Suggestions for the current query. Until the first keystroke the field still
    /// holds the current station, so show the whole line rather than a list of one.
    private var suggestions: [StationMatch] {
        stationQueryEdited
            ? StationSearch.matches(for: stationQuery, from: location.userLocation)
            : StationSearch.allStations(from: location.userLocation)
    }

    private func beginEditingStation() {
        stationQuery = location.activeStation?.name ?? ""
        stationQueryEdited = false
        withAnimation(.easeInOut(duration: 0.2)) { isEditingStation = true }
        stationFieldFocused = true
    }

    private func endEditingStation() {
        stationFieldFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isEditingStation = false }
    }

    private func select(_ station: CaltrainStation) {
        // The arrow-marked row is the station you're actually at, so choosing it means
        // "follow my location again" rather than pinning that one station.
        if station.name == location.nearestStation?.name {
            location.useNearestStation()
        } else {
            location.selectStation(station)
        }
        endEditingStation()
    }

    private func refreshTrains() {
        guard let station = location.activeStation else { return }
        let upcoming = CaltrainService.shared.upcomingTrains(from: station.name, currentTime: Date())
        northbound = upcoming.northbound
        southbound = upcoming.southbound
    }

    private func loadTravelTimes() async {
        guard let station = location.activeStation,
              let origin = location.userLocation?.coordinate else { return }
        let result = await TravelTimeService.shared.travelTimes(from: origin, to: station)
        await MainActor.run { self.travelTimes = result }
    }
}

// MARK: - Departure board (hero)

private struct DepartureBoard: View {
    let direction: TimetableDirection
    let trains: [NextTrainInfo]
    let onToggle: () -> Void
    let onOpenTimetable: () -> Void

    private var next: NextTrainInfo? { trains.first }
    /// The two departures after the one in the hero row.
    private var following: [NextTrainInfo] { Array(trains.dropFirst().prefix(2)) }

    var body: some View {
        VStack(spacing: 0) {
            directionToggle

            DepartureRow(direction: direction, train: next)

            if !following.isEmpty {
                hairline
                followingRows
            }

            hairline
            timetableLink
        }
        .cardBackground()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: Metrics.hairline)
    }

    /// Tapping anywhere on this bar flips the direction, sliding this card out and the
    /// other one in from the opposite edge.
    private var directionToggle: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: direction.systemImage)
                    .font(.system(size: 13, weight: .bold))

                Text(direction.title)
                    .font(.caption)
                    .textCase(.uppercase)
                    .tracking(1.2)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(7)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(direction.title). Tap to show \(direction.flipped.title)")
    }

    private var followingRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Then")
                .font(.caption2)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(.tertiary)

            ForEach(following) { train in
                HStack(spacing: 8) {
                    TrainTypeDot(trainClass: TrainClass(train.trainType))

                    Text(train.arrivalTime)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("#\(train.trainNumber)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 6)

                    Text("\(train.minutesUntilArrival) min")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var timetableLink: some View {
        Button(action: onOpenTimetable) {
            HStack(spacing: 6) {
                Text("Full timetable")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every \(direction.title.lowercased()) departure ahead")
    }
}

private struct DepartureRow: View {
    let direction: TimetableDirection
    let train: NextTrainInfo?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(direction.destination)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

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
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 18)
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

// MARK: - Full timetable sheet

/// Stations down, trains across — a printed-timetable view of the upcoming trains from
/// the current station, opened by tapping a direction.
private struct TimetableSheet: View {
    let direction: TimetableDirection
    let stationName: String

    @Environment(\.dismiss) private var dismiss

    private let grid: TimetableGrid

    /// Three train columns plus the station name fill the width exactly, on any device.
    private let visibleTrainColumns: CGFloat = 3
    private let rowHeight: CGFloat = 48

    init(direction: TimetableDirection, stationName: String) {
        self.direction = direction
        self.stationName = stationName
        self.grid = CaltrainService.shared.timetableGrid(from: stationName,
                                                         northbound: direction.isNorth)
    }

    var body: some View {
        NavigationStack {
            Group {
                if grid.trains.isEmpty {
                    emptyState
                } else {
                    table
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(direction.title) · \(stationName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Horizontal outside, vertical inside: the train headers pin to the top while the
    // whole grid — headers included — pans sideways as one piece.
    private var table: some View {
        GeometryReader { geo in
            let stationWidth = min(max(geo.size.width * 0.30, 116), 156)
            let trainWidth = (geo.size.width - stationWidth) / visibleTrainColumns

            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(grid.stations.enumerated()), id: \.element) { index, station in
                                stationRow(station, index: index,
                                           stationWidth: stationWidth, trainWidth: trainWidth)
                            }
                        } header: {
                            headerRow(stationWidth: stationWidth, trainWidth: trainWidth)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func headerRow(stationWidth: CGFloat, trainWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(CaltrainService.serviceLabel())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .frame(width: stationWidth, alignment: .leading)

            ForEach(grid.trains) { train in
                VStack(spacing: 5) {
                    // The wider columns leave room for the full type label.
                    TrainTypeBadge(trainClass: TrainClass(train.trainType))
                    Text("#\(train.trainNumber)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: trainWidth)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: Metrics.hairline)
        }
    }

    private func stationRow(_ station: String, index: Int,
                            stationWidth: CGFloat, trainWidth: CGFloat) -> some View {
        let isCurrent = station.caseInsensitiveCompare(stationName) == .orderedSame

        return HStack(spacing: 0) {
            Text(station)
                .font(.system(size: 16, weight: isCurrent ? .bold : .regular))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .frame(width: stationWidth, alignment: .leading)

            ForEach(grid.trains) { train in
                Text(train.times[station] ?? "—")
                    .font(.system(size: 17, weight: isCurrent ? .semibold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(train.times[station] == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: trainWidth)
            }
        }
        .frame(height: rowHeight)
        .background(rowBackground(isCurrent: isCurrent, index: index))
    }

    private func rowBackground(isCurrent: Bool, index: Int) -> Color {
        if isCurrent { return Color.caltrainRed.opacity(0.10) }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No more \(direction.title.lowercased()) trains")
                .font(.headline)
            Text("Nothing else scheduled from \(stationName) today.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared bits

struct SectionLabel: View {
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

extension View {
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

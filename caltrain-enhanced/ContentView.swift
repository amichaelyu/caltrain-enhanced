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

// MARK: - Transitions

/// Reveals a view top-down, as if it were unrolling out from whatever sits
/// directly above it. The mask (not the content) is what scales, so rows keep
/// their real height instead of squashing on the way in.
private struct UnrollModifier: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .mask(alignment: .top) {
                Rectangle().scaleEffect(x: 1, y: progress, anchor: .top)
            }
            .opacity(progress)
            .offset(y: -12 * (1 - progress))
    }
}

extension AnyTransition {
    /// Unrolls downward from the top edge of its own slot.
    static var unrollDown: AnyTransition {
        .modifier(active: UnrollModifier(progress: 0),
                  identity: UnrollModifier(progress: 1))
    }
}

// MARK: - Root

struct ContentView: View {
    /// Owned by the tab container so the Ride tab opens on the direction you were reading.
    @Binding var direction: TimetableDirection
    /// Called with a train and the stop the rider is getting off at, which together are
    /// everything the Ride tab needs.
    var onStartRide: (String, String) -> Void = { _, _ in }

    @ObservedObject private var location = SharedLocationManager.shared
    @ObservedObject private var live = CaltrainLiveService.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isVisible = false
    @State private var northbound: [NextTrainInfo] = []
    @State private var southbound: [NextTrainInfo] = []
    @State private var travelTimes: TravelTimes?
    @State private var now = Date()
    @State private var showSettings = false
    @State private var showAlerts = false
    @State private var isEditingStation = false
    @State private var stationQuery = ""
    @State private var stationQueryEdited = false
    @FocusState private var stationFieldFocused: Bool
    @State private var showTimetable = false
    @State private var destinationRequest: DestinationRequest?

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
                        .transition(.unrollDown)
                }

                let alerts = sortedAlerts(live.activeAlerts(at: now), for: location.activeStation?.name)
                if !alerts.isEmpty && !isEditingStation {
                    AlertBanner(alerts: alerts) { showAlerts = true }
                }

                if let station = location.activeStation {
                    ZStack {
                        DepartureBoard(direction: direction,
                                       trains: direction.isNorth ? northbound : southbound,
                                       onToggle: flipDirection,
                                       onOpenTimetable: { showTimetable = true },
                                       onChooseDestination: chooseDestination)
                            .id(direction)
                            // Northbound arrives from the right, southbound from the left;
                            // the outgoing card leaves by the opposite edge.
                            .transition(.asymmetric(
                                insertion: .move(edge: direction.isNorth ? .trailing : .leading),
                                removal: .move(edge: direction.isNorth ? .leading : .trailing)
                            ))
                    }
                    .clipped()

                    TravelTimesStrip(times: travelTimes,
                                     station: station,
                                     origin: location.userLocation?.coordinate)
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
        .sheet(isPresented: $showAlerts) {
            AlertsSheet(stationName: location.activeStation?.name)
        }
        // The sheet edits `direction` through a binding, so flipping the timetable also
        // flips the board behind it.
        .sheet(item: $destinationRequest) { request in
            if let itinerary = request.itinerary {
                RideDestinationPickerSheet(itinerary: itinerary, selected: nil) { stopName in
                    onStartRide(request.trainNumber, stopName)
                }
            }
        }
        .sheet(isPresented: $showTimetable) {
            TimetableSheet(direction: $direction,
                           stationName: location.activeStation?.name ?? "",
                           onStartRide: onStartRide)
        }
        // Location follows the scene, not the view: tracking only runs while the app is
        // actually on screen, and the clock stops ticking behind a backgrounded app.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                location.startTracking()
                refreshTrains()
            } else {
                location.stopTracking()
            }
            updateLiveFeed()
        }
        .onAppear { isVisible = true; updateLiveFeed() }
        .onDisappear { isVisible = false; updateLiveFeed() }
        .onReceive(live.$feed) { _ in refreshTrains() }
        .onReceive(ticker) { date in
            guard scenePhase == .active else { return }
            now = date
            refreshTrains()
        }
        .onChange(of: location.activeStation?.name) {
            refreshTrains()
        }
        // Keyed on the origin as well as the station, so walking toward the platform
        // actually revises the estimate. Fixes are thresholded upstream, so this only
        // re-fires on real movement.
        .task(id: routeKey) {
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
                AlertsButton(count: live.activeAlerts(at: now).count) { showAlerts = true }

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

    private func chooseDestination(_ trainNumber: String) {
        guard let station = location.activeStation else { return }
        destinationRequest = DestinationRequest(trainNumber: trainNumber,
                                                originName: station.name,
                                                northbound: direction.isNorth)
    }

    /// How far back to look for a train whose printed time has passed but which 511 says
    /// hasn't left yet.
    private static let lateWindow: TimeInterval = 30 * 60

    private func refreshTrains() {
        guard let station = location.activeStation else { return }
        let date = Date()
        let upcoming = CaltrainService.shared.upcomingTrains(from: station.name,
                                                             currentTime: date.addingTimeInterval(-Self.lateWindow),
                                                             limit: 16)
        northbound = board(upcoming.northbound, northbound: true, at: date)
        southbound = board(upcoming.southbound, northbound: false, at: date)
    }

    /// Puts 511's prediction on each departure and keeps the ones still to leave: a late
    /// train stays on the board past its printed time, and one that's gone drops off.
    private func board(_ trains: [NextTrainInfo], northbound: Bool, at date: Date) -> [NextTrainInfo] {
        let departures = trains.compactMap { train -> NextTrainInfo? in
            guard !live.isCancelled(train.trainNumber, at: date) else { return nil }
            let expected = live.train(train.trainNumber, northbound: northbound, at: date)?
                .stop(named: train.stationName)?.expected
            let when = expected ?? train.arrivalDate
            guard when > date else { return nil }
            return NextTrainInfo(trainNumber: train.trainNumber,
                                 trainType: train.trainType,
                                 stationName: train.stationName,
                                 minutesUntilArrival: max(0, Int(when.timeIntervalSince(date) / 60)),
                                 arrivalTime: train.arrivalTime,
                                 arrivalDate: train.arrivalDate,
                                 direction: train.direction,
                                 expectedDate: expected)
        }
        return Array(departures.sorted { $0.departureDate < $1.departureDate }.prefix(8))
    }

    /// Only poll while the board is on screen.
    private func updateLiveFeed() {
        if scenePhase == .active && isVisible {
            live.start(for: "plan")
        } else {
            live.stop(for: "plan")
        }
    }

    /// Identity for the travel-time fetch: the station plus the published origin. Rounded
    /// to ~11 m purely to keep the key stable against float noise.
    private var routeKey: String {
        let station = location.activeStation?.name ?? "-"
        guard let origin = location.userLocation?.coordinate else { return station }
        return String(format: "%@|%.4f,%.4f", station, origin.latitude, origin.longitude)
    }

    private func loadTravelTimes() async {
        guard let station = location.activeStation else { return }
        guard let origin = location.userLocation?.coordinate else {
            // No fix yet — show the last known estimate rather than an empty strip.
            travelTimes = TravelTimeService.shared.cachedTravelTimes(for: station.name)
            return
        }
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
    let onChooseDestination: (String) -> Void

    private var next: NextTrainInfo? { trains.first }
    /// The two departures after the one in the hero row.
    private var following: [NextTrainInfo] { Array(trains.dropFirst().prefix(2)) }

    var body: some View {
        VStack(spacing: 0) {
            directionToggle

            Button { if let next { onChooseDestination(next.trainNumber) } } label: {
                DepartureRow(direction: direction, train: next)
            }
            .buttonStyle(.plain)
            .disabled(next == nil)

            if !following.isEmpty {
                hairline
                followingRows
            }

            if let next {
                hairline
                rideLink(next)
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
                Button { onChooseDestination(train.trainNumber) } label: {
                HStack(spacing: 8) {
                    TrainTypeDot(trainClass: TrainClass(train.trainType))

                    DepartureClock(train: train, size: 16)

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
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Track this train on the Ride tab")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// A board can say when a train leaves but not where you're going, so that's the one
    /// thing it asks — and the answer is enough to start following the ride.
    private func rideLink(_ train: NextTrainInfo) -> some View {
        Button { onChooseDestination(train.trainNumber) } label: {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.caltrainRed)
                Text("Going to…")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose the station you're getting off at")
        .accessibilityHint("Opens the stops on train \(train.trainNumber), then follows the ride")
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

/// A departure's time. When 511 has it leaving in a different minute, its time leads in
/// red with the printed one struck through beside it.
private struct DepartureClock: View {
    let train: NextTrainInfo
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let expected = train.expectedDate, train.isOffSchedule {
                Text(RideFormat.clock(expected))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.caltrainRed)
                Text(train.arrivalTime)
                    .font(.system(size: size * 0.8, design: .rounded))
                    .strikethrough()
                    .foregroundStyle(.tertiary)
            } else {
                Text(train.arrivalTime)
                    .font(.system(size: size, weight: size > 14 ? .medium : .regular, design: .rounded))
                    .foregroundStyle(size > 14 ? .primary : .secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(train.isOffSchedule
                            ? "\(RideFormat.clock(train.departureDate)), scheduled \(train.arrivalTime)"
                            : train.arrivalTime)
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
                        DepartureClock(train: train, size: 13)
                        Text("· #\(train.trainNumber)")
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
    let origin: CLLocationCoordinate2D?

    @AppStorage(MapsProvider.storageKey) private var mapsProviderRaw = MapsProvider.apple.rawValue
    @State private var mode: TravelMode = .walking

    private var provider: MapsProvider {
        MapsProvider(rawValue: mapsProviderRaw) ?? .apple
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Directions")
                Spacer()
                if let times {
                    Text(String(format: "%.1f mi", times.distanceMiles))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            StationRouteMap(station: station,
                            origin: origin,
                            mode: mode,
                            onTap: { navigate(mode) })

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { candidate in
                    TravelTile(mode: candidate,
                               minutes: minutes(for: candidate),
                               isSelected: candidate == mode,
                               action: { select(candidate) })
                }
            }
        }
    }

    private func minutes(for mode: TravelMode) -> Int? {
        switch mode {
        case .walking: times?.walkingMinutes
        case .cycling: times?.bikingMinutes
        case .driving: times?.drivingMinutes
        }
    }

    /// Picking a mode only redraws the route on the map. Handing off to the maps app is
    /// the map's own job, so tapping a tile twice never leaves the app.
    private func select(_ candidate: TravelMode) {
        guard candidate != mode else { return }
        withAnimation(.easeInOut(duration: 0.2)) { mode = candidate }
    }

    private func navigate(_ mode: TravelMode) {
        MapsLauncher.openDirections(to: station, mode: mode, using: provider)
    }
}

/// Mode selector under the map. Same tile as before the map existed; the mode whose
/// route is currently drawn is filled rather than card-colored.
private struct TravelTile: View {
    let mode: TravelMode
    let minutes: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { tile }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the \(mode.label.lowercased()) route to the station")
            .accessibilityValue(minutes.map { "\($0) minutes" } ?? "Unknown")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// One line, not three: the glyph already says which mode this is, so the written
    /// label was costing height the map could use.
    private var tile: some View {
        HStack(spacing: 5) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 13))
            if let minutes {
                Text("\(minutes)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("min")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .light, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color(.tertiaryLabel))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.caltrainRed : Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Full timetable sheet

/// Stations down, trains across — a printed-timetable view of the upcoming trains from
/// the current station, opened by tapping a direction.
/// One time in the timetable. Black from the printed schedule; red for a train 511 is
/// tracking, showing 511's estimate with the printed time struck through under it when the
/// two differ.
private struct TimetableCell: View {
    let scheduled: String?
    let expected: Date?
    let isLive: Bool
    let isCurrent: Bool

    var body: some View {
        let estimate = expected.map(RideFormat.clock)
        VStack(spacing: 0) {
            Text(estimate ?? scheduled ?? "—")
                .font(.system(size: 17, weight: isCurrent || isLive ? .semibold : .regular, design: .rounded))
                .foregroundStyle(scheduled == nil ? AnyShapeStyle(.tertiary)
                                 : isLive ? AnyShapeStyle(Color.caltrainRed) : AnyShapeStyle(.primary))
            if let estimate, let scheduled, estimate != scheduled {
                Text(scheduled)
                    .font(.system(size: 11, design: .rounded))
                    .strikethrough()
                    .foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct TimetableSheet: View {
    let stationName: String
    let onStartRide: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var live = CaltrainLiveService.shared

    @Binding var direction: TimetableDirection
    @State private var serviceDay: ServiceDay
    @State private var grid: TimetableGrid
    /// The grid's horizontal scroll offset, mirrored into the fixed header row so the
    /// train numbers stay over the columns they label.
    @State private var scrollX: CGFloat = 0

    /// Three train columns plus the station name fill the width exactly, on any device.
    private let visibleTrainColumns: CGFloat = 3
    private let rowHeight: CGFloat = 48
    private let headerHeight: CGFloat = 64

    init(direction: Binding<TimetableDirection>,
         stationName: String,
         onStartRide: @escaping (String, String) -> Void) {
        self.stationName = stationName
        self.onStartRide = onStartRide
        let day = CaltrainService.currentServiceDay()
        _direction = direction
        _serviceDay = State(initialValue: day)
        _grid = State(initialValue: CaltrainService.shared.timetableGrid(
            from: stationName, northbound: direction.wrappedValue.isNorth, serviceDay: day))
    }

    private func reloadGrid() {
        grid = CaltrainService.shared.timetableGrid(from: stationName,
                                                    northbound: direction.isNorth,
                                                    serviceDay: serviceDay)
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
            .safeAreaInset(edge: .top, spacing: 0) { controlBar }
            .navigationTitle(stationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { live.start(for: "timetable") }
        .onDisappear { live.stop(for: "timetable") }
    }

    /// 511's run for a column, when it's tracking that train today. The other day's
    /// schedule never has one.
    private func liveTrain(_ train: TimetableTrain) -> LiveTrain? {
        guard serviceDay == CaltrainService.currentServiceDay() else { return nil }
        return live.train(train.trainNumber, northbound: direction.isNorth)
    }

    /// Named by a no-service alert today.
    private func isCancelled(_ train: TimetableTrain) -> Bool {
        serviceDay == CaltrainService.currentServiceDay() && live.isCancelled(train.trainNumber)
    }

    /// Dimmed once it's left here, unless 511 says it's still on its way.
    private func isGone(_ train: TimetableTrain, live liveTrain: LiveTrain?) -> Bool {
        train.hasDeparted && liveTrain?.stop(named: stationName)?.expected == nil
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                // No crossfade: swap the grid outright.
                withoutAnimation { direction = direction.flipped }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: direction.systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(direction.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Switches to \(direction.flipped.title)")

            Spacer(minLength: 8)

            Picker("Schedule", selection: $serviceDay) {
                ForEach(ServiceDay.allCases) { day in
                    Text(day.label).tag(day)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Frozen panes: the station column and the header row never move. Only the block of
    /// times scrolls, and the header mirrors its horizontal offset so labels stay aligned.
    private var table: some View {
        GeometryReader { geo in
            let stationWidth = min(max(geo.size.width * 0.30, 116), 156)
            let viewportWidth = geo.size.width - stationWidth
            let trainWidth = viewportWidth / visibleTrainColumns

            VStack(spacing: 0) {
                headerBar(stationWidth: stationWidth,
                          viewportWidth: viewportWidth,
                          trainWidth: trainWidth)

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        stationColumn(width: stationWidth)

                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                trainColumns(trainWidth: trainWidth)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                                geometry.contentOffset.x
                            } action: { _, newValue in
                                scrollX = newValue
                            }
                            .onAppear { scrollToNextTrain(proxy) }
                            .onChange(of: serviceDay) {
                                withoutAnimation { reloadGrid() }
                                scrollToNextTrain(proxy)
                            }
                            .onChange(of: direction) {
                                withoutAnimation { reloadGrid() }
                                scrollToNextTrain(proxy)
                            }
                        }
                        .frame(height: rowHeight * CGFloat(grid.stations.count))
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// Past trains stay in the grid to the left, so open on the next one instead of on
    /// the first departure of the day. Deferred a runloop turn so the columns exist.
    private func scrollToNextTrain(_ proxy: ScrollViewProxy) {
        guard let target = grid.trains.first(where: { !$0.hasDeparted }) ?? grid.trains.first
        else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: .leading)
        }
    }

    private func headerBar(stationWidth: CGFloat, viewportWidth: CGFloat, trainWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Station")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(width: stationWidth, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(grid.trains) { train in
                    let liveTrain = liveTrain(train)
                    let cancelled = isCancelled(train)
                    VStack(spacing: 5) {
                        TrainTypeBadge(trainClass: TrainClass(train.trainType))
                        HStack(spacing: 3) {
                            if liveTrain != nil {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Text("#\(train.trainNumber)")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .strikethrough(cancelled)
                        }
                        .foregroundStyle(liveTrain != nil ? AnyShapeStyle(Color.caltrainRed) : AnyShapeStyle(.secondary))
                    }
                    .frame(width: trainWidth)
                    .opacity(isGone(train, live: liveTrain) || cancelled ? departedOpacity : 1)
                    .accessibilityLabel(cancelled ? "Train \(train.trainNumber), cancelled" : "Train \(train.trainNumber)")
                }
            }
            .offset(x: -scrollX)
            // Clipped to the grid's viewport so no column slides under the station column.
            .frame(width: viewportWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: headerHeight)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: Metrics.hairline)
        }
    }

    private func stationColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(grid.stations.enumerated()), id: \.element) { index, station in
                let isCurrent = isCurrentStation(station)
                Text(station)
                    .font(.system(size: 16, weight: isCurrent ? .bold : .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .frame(width: width, height: rowHeight, alignment: .leading)
                    .background(rowBackground(isCurrent: isCurrent, index: index))
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: Metrics.hairline)
        }
    }

    /// Column-major so each train column carries an id that scrollTo can target.
    private func trainColumns(trainWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(grid.trains) { train in
                let liveTrain = liveTrain(train)
                let gone = isGone(train, live: liveTrain) || isCancelled(train)
                VStack(spacing: 0) {
                    ForEach(Array(grid.stations.enumerated()), id: \.element) { index, station in
                        let isCurrent = isCurrentStation(station)
                        let expected = liveTrain?.stop(named: station)?.expected
                        // A cell names a train and a station, which is exactly a ride:
                        // this train, off at that stop.
                        Button {
                            onStartRide(train.trainNumber, station)
                            dismiss()
                        } label: {
                            TimetableCell(scheduled: train.times[station],
                                          expected: expected,
                                          isLive: liveTrain != nil,
                                          isCurrent: isCurrent)
                                .opacity(gone ? departedOpacity : 1)
                                .frame(width: trainWidth, height: rowHeight)
                                .background(rowBackground(isCurrent: isCurrent, index: index))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(train.times[station] == nil)
                        .accessibilityLabel("\(station), \(expected.map { "expected \(RideFormat.clock($0)), scheduled " } ?? "")\(train.times[station] ?? "no service"), train \(train.trainNumber)")
                        .accessibilityHint("Ride this train and get off here")
                    }
                }
                .id(train.id)
            }
        }
    }

    private func isCurrentStation(_ station: String) -> Bool {
        station.caseInsensitiveCompare(stationName) == .orderedSame
    }

    /// Trains that have already left this station are dimmed rather than dropped.
    private var departedOpacity: Double { 0.32 }

    private func rowBackground(isCurrent: Bool, index: Int) -> Color {
        if isCurrent { return Color.caltrainRed.opacity(0.10) }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No \(direction.title.lowercased()) service")
                .font(.headline)
            Text("Nothing runs from \(stationName) on the \(serviceDay.label.lowercased()) schedule.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared bits

/// Applies a state change with any ambient animation suppressed, so dependent views
/// swap in a single frame instead of crossfading.
private func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

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

/// A pending "where are you getting off?" question about one train from one station.
private struct DestinationRequest: Identifiable {
    let trainNumber: String
    let originName: String
    let northbound: Bool

    var id: String { "\(trainNumber)@\(originName)" }

    var itinerary: RideItinerary? {
        CaltrainService.shared.itinerary(trainNumber: trainNumber,
                                         northbound: northbound,
                                         boardingAt: originName)
    }
}

#Preview {
    ContentView(direction: .constant(.northbound))
}

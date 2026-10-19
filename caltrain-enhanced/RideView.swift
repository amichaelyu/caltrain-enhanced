//
//  RideView.swift
//  caltrain-enhanced
//
//  The Ride tab: you tell it which train you're on, it draws the rest of the run as a
//  line down the page. Times come from the timetable's stop-to-stop deltas, shifted by
//  however late your own position says the train is running.
//

import SwiftUI
import CoreLocation

// MARK: - Root

struct RideView: View {
    @EnvironmentObject private var ride: RideSession
    @ObservedObject private var location = SharedLocationManager.shared
    @ObservedObject private var live = CaltrainLiveService.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Shared with the Plan tab, so the direction you were browsing is the direction the
    /// train picker opens on.
    @Binding var direction: TimetableDirection

    @State private var now = Date()
    @State private var showTrainPicker = false
    @State private var showDestinationPicker = false

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var itinerary: RideItinerary? {
        guard let trainNumber = ride.trainNumber, let origin = ride.originName else { return nil }
        return CaltrainService.shared.itinerary(trainNumber: trainNumber,
                                                northbound: ride.northbound,
                                                boardingAt: origin,
                                                at: now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let itinerary {
                        let estimate = RideEstimator.estimate(for: itinerary,
                                                              userLocation: location.userLocation,
                                                              live: live.train(itinerary.trainNumber,
                                                                               northbound: itinerary.northbound,
                                                                               at: now),
                                                              now: now)
                        RideDestinationCard(estimate: estimate,
                                            destinationName: ride.destinationName,
                                            now: now,
                                            onPick: { showDestinationPicker = true })

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("On the line")
                            RideMap(estimate: estimate,
                                    destinationName: ride.destinationName,
                                    now: now,
                                    onSelect: setDestination)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                SectionLabel("The run")
                                Spacer()
                                RideStatusPill(estimate: estimate)
                            }
                            RideTimeline(estimate: estimate,
                                         destinationName: ride.destinationName,
                                         now: now,
                                         onSelect: setDestination)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let itinerary {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("End", role: .destructive) { ride.end() }
                            .tint(Color.caltrainRed)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        RideTrainTile(itinerary: itinerary) { showTrainPicker = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showTrainPicker) {
            TrainPickerSheet(stationName: location.activeStation?.name ?? "",
                             direction: $direction,
                             selected: ride.trainNumber,
                             onSelect: startRide)
        }
        .sheet(isPresented: $showDestinationPicker) {
            if let itinerary {
                RideDestinationPickerSheet(itinerary: itinerary,
                                           selected: ride.destinationName,
                                           onSelect: setDestination)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                location.startTracking()
                now = Date()
            } else {
                location.stopTracking()
            }
            updateLiveFeed()
        }
        .onChange(of: ride.isActive) { _, _ in updateLiveFeed() }
        .onReceive(ticker) { date in
            guard scenePhase == .active else { return }
            now = date
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tram.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.caltrainRed)

            Text("Which train are you on?")
                .font(.headline)

            Text(location.activeStation.map { "Pick a departure from \($0.name) and this page counts down every stop ahead of you." }
                 ?? "Finding the nearest station…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showTrainPicker = true
            } label: {
                Text("Choose your train")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.caltrainRed)
            .disabled(location.activeStation == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .cardBackground()
    }

    /// Only poll while there's a ride on screen to put the predictions on.
    private func updateLiveFeed() {
        if scenePhase == .active && ride.isActive {
            live.start(for: "ride")
        } else {
            live.stop(for: "ride")
        }
    }

    private func startRide(_ trainNumber: String) {
        guard let station = location.activeStation else { return }
        ride.start(trainNumber: trainNumber, from: station.name, northbound: direction.isNorth)
    }

    private func setDestination(_ stationName: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            // Tapping the stop you already chose clears it, so it doubles as a toggle.
            ride.destinationName = ride.destinationName == stationName ? nil : stationName
        }
    }
}

// MARK: - Train tile

/// The whole "which train am I on" card, boiled down to something that fits beside the
/// title: number, class, direction. Tap to swap trains.
private struct RideTrainTile: View {
    let itinerary: RideItinerary
    let onTap: () -> Void

    private var trainClass: TrainClass { TrainClass(itinerary.trainType) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: itinerary.northbound ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .black))
                Text("#\(itinerary.trainNumber)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(.secondaryLabel))
                Text(trainClass.shortLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(trainClass.color)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Train \(itinerary.trainNumber), \(trainClass.label), \(itinerary.northbound ? "northbound" : "southbound")")
        .accessibilityHint("Choose a different train")
    }
}

// MARK: - Status

/// On time or not, and whether that's 511, your phone, or just the timetable talking.
private struct RideStatusPill: View {
    let estimate: RideEstimate

    private var icon: String {
        switch estimate.source {
        case .feed: "dot.radiowaves.left.and.right"
        case .location: "location.fill"
        case .timetable: "clock"
        }
    }

    private var sourceDescription: String {
        switch estimate.source {
        case .feed: "live from 511.org"
        case .location: "tracked from your location"
        case .timetable: "timetable only"
        }
    }

    var body: some View {
        let late = estimate.delayMinutes
        // The feed runs a few seconds early as often as late; early reads as on time.
        let onTime = late <= 0
        let color = onTime ? Color.secondary : Color.caltrainRed
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(onTime ? (estimate.isLive ? "On time" : "On schedule") : "\(late) min late")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
        .accessibilityLabel(estimate.isLive
                            ? (onTime ? "On time, \(sourceDescription)" : "\(late) minutes late, \(sourceDescription)")
                            : "Timetable only, no live data yet")
    }
}

// MARK: - Destination

/// The one number a rider actually wants: how long until their stop.
private struct RideDestinationCard: View {
    let estimate: RideEstimate
    let destinationName: String?
    let now: Date
    let onPick: () -> Void

    var body: some View {
        if let destination = estimate.stop(named: destinationName) {
            Button(action: onPick) { arrival(destination) }
                .buttonStyle(.plain)
                .accessibilityHint("Change the stop you're getting off at")
        } else {
            prompt
        }
    }

    private func arrival(_ destination: RideStopEstimate) -> some View {
        let minutes = destination.minutesAway(from: now)
        // Stops still ahead of you, counting the one you get off at.
        let remaining = estimate.stops
            .dropFirst()
            .prefix(while: { $0.id != destination.id })
            .filter { !$0.hasPassed }
            .count + 1

        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Getting off at")

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(destination.station.name)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }

                    Text(destination.hasPassed
                         ? "Arrived \(RideFormat.clock(destination.projected))"
                         : "Arrives \(RideFormat.clock(destination.projected)) · \(remaining) stop\(remaining == 1 ? "" : "s") to go")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                if destination.hasPassed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.caltrainRed)
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(minutes == 0 ? "Now" : "\(minutes)")
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(minutes <= 5 ? Color.caltrainRed : .primary)
                        if minutes != 0 {
                            Text("min")
                                .font(.caption2)
                                .textCase(.uppercase)
                                .tracking(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .contentShape(Rectangle())
        .cardBackground()
    }

    private var prompt: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.caltrainRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set your destination")
                        .font(.subheadline.weight(.semibold))
                    Text("Or tap any stop below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardBackground()
    }

}

// MARK: - Timeline

/// The run as a line: boarding station pinned at the top, every stop below it with the
/// scheduled gap between them and a marker for where the train is right now.
private struct RideTimeline: View {
    let estimate: RideEstimate
    let destinationName: String?
    let now: Date
    let onSelect: (String) -> Void

    private let rowHeight: CGFloat = 52
    private let connectorHeight: CGFloat = 28
    private let timeWidth: CGFloat = 62
    private let timeGap: CGFloat = 10
    private let railWidth: CGFloat = 30

    /// Nothing past your stop is part of your ride, so the line ends there.
    private var stops: [RideStopEstimate] {
        guard let last = destinationIndex else { return estimate.stops }
        return Array(estimate.stops.prefix(last + 1))
    }

    private var destinationIndex: Int? { estimate.index(of: destinationName) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: timeWidth + timeGap, height: 1)
                rail
            }
            rows
            puckLayer
        }
        .padding(.vertical, 4)
        .cardBackground()
    }

    // MARK: Rail

    /// Drawn as one continuous line behind the rows: the part already travelled is solid,
    /// the part still to ride is tinted, anything past your stop is grey.
    private var rail: some View {
        let top = center(0)
        let bottom = center(max(stops.count - 1, 0))
        let destinationY = destinationIndex.map(center) ?? bottom

        return ZStack(alignment: .top) {
            segment(from: top, to: bottom, color: Color.primary.opacity(0.10))
            segment(from: top, to: destinationY, color: Color.caltrainRed.opacity(0.30))
            if let travelled = positionY {
                segment(from: top, to: min(travelled, destinationY), color: Color.caltrainRed)
            }
        }
        .frame(width: railWidth, height: totalHeight, alignment: .top)
    }

    /// Its own layer above the rows, so a station dot never paints over the train.
    @ViewBuilder
    private var puckLayer: some View {
        if let travelled = positionY {
            HStack(spacing: 0) {
                Color.clear.frame(width: timeWidth + timeGap, height: 1)
                trainPuck
                    .offset(y: travelled - 11)
                    .frame(width: railWidth, height: totalHeight, alignment: .top)
            }
            .allowsHitTesting(false)
        }
    }

    private func segment(from start: CGFloat, to end: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 3, height: max(0, end - start))
            .offset(y: start)
    }

    private var trainPuck: some View {
        Image(systemName: "tram.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.caltrainRed))
            .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
    }

    /// Vertical position of the train, interpolated within the leg it is on — same
    /// `RidePlacement` the map draws from, so the two never disagree. Nil until the ride
    /// is actually under way: before departure there's nothing to mark but the station
    /// you're standing in.
    private var positionY: CGFloat? {
        guard stops.first?.hasPassed == true else { return nil }
        guard let placement = estimate.placement(at: now), placement.segmentIndex + 1 < stops.count else {
            // Nothing to interpolate within: fall back to the last stop behind us.
            guard let lastPassed = stops.lastIndex(where: { $0.hasPassed }) else { return nil }
            return center(lastPassed)
        }
        let from = center(placement.segmentIndex)
        let to = center(placement.segmentIndex + 1)
        return from + (to - from) * placement.fraction
    }

    private func center(_ index: Int) -> CGFloat {
        CGFloat(index) * (rowHeight + connectorHeight) + rowHeight / 2
    }

    private var totalHeight: CGFloat {
        CGFloat(stops.count) * rowHeight + CGFloat(max(stops.count - 1, 0)) * connectorHeight
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                row(index: index, stop: stop)
                if index < stops.count - 1 {
                    connector(to: stops[index + 1])
                }
            }
        }
    }

    private func row(index: Int, stop: RideStopEstimate) -> some View {
        let isDestination = index == destinationIndex
        let isBoarding = index == 0
        return Button { onSelect(stop.station.name) } label: {
            HStack(spacing: 0) {
                clock(stop)
                    .frame(width: timeWidth, alignment: .trailing)
                    .padding(.trailing, timeGap)

                dot(index: index, stop: stop, isDestination: isDestination)
                    .frame(width: railWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.station.name)
                        .font(.system(size: 16,
                                      weight: isDestination ? .bold : (isBoarding ? .semibold : .regular),
                                      design: .rounded))
                        .foregroundStyle(stop.hasPassed && !isDestination ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if isBoarding {
                        Text("Boarded here")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if isDestination {
                        Text("Your stop")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.caltrainRed)
                    }
                }
                .padding(.leading, 4)

                Spacer(minLength: 8)

                trailing(stop: stop, isDestination: isDestination)
            }
            .padding(.trailing, 16)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RideFormat.clock(stop.projected) == RideFormat.clock(stop.scheduled)
                            ? "\(stop.station.name), \(RideFormat.clock(stop.projected))"
                            : "\(stop.station.name), \(RideFormat.clock(stop.projected)), scheduled \(RideFormat.clock(stop.scheduled))")
        .accessibilityHint(isDestination ? "Your stop. Tap to clear" : "Tap to get off here")
    }

    /// Digits at full size with the AM/PM tucked in small beside them: at 14pt an
    /// "11:05 PM" wouldn't fit the column, and truncating a time is worse than shrinking
    /// the half of it you can infer.
    ///
    /// When the projection has moved off the timetable, the scheduled time sits struck
    /// through underneath, so you can see what the live time is measured against.
    private func clock(_ stop: RideStopEstimate) -> some View {
        let parts = RideFormat.clockParts(stop.projected)
        let scheduled = RideFormat.clockParts(stop.scheduled)
        let moved = scheduled.time != parts.time || scheduled.meridiem != parts.meridiem
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.time)
                .font(.system(size: 14, weight: stop.hasPassed ? .regular : .semibold, design: .rounded))
                .monospacedDigit()
            if let meridiem = parts.meridiem {
                Text(meridiem)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(stop.hasPassed ? AnyShapeStyle(.tertiary)
                         : moved ? AnyShapeStyle(Color.caltrainRed) : AnyShapeStyle(.primary))
        // Hung below without taking up layout, so the live time stays level with the
        // station name and the dot.
        .overlay(alignment: .bottomTrailing) {
            if moved {
                Text(scheduled.time)
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(y: 14)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func trailing(stop: RideStopEstimate, isDestination: Bool) -> some View {
        if stop.hasPassed {
            Text("passed")
                .font(.caption2)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
        } else {
            Text("in \(stop.minutesAway(from: now)) min")
                .font(.system(size: 13, weight: isDestination ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isDestination ? Color.caltrainRed : .secondary)
        }
    }

    private func dot(index: Int, stop: RideStopEstimate, isDestination: Bool) -> some View {
        ZStack {
            if isDestination {
                Circle()
                    .fill(Color.caltrainRed)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 6, height: 6)
            } else if stop.hasPassed {
                Circle()
                    .fill(Color.caltrainRed.opacity(0.45))
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 11, height: 11)
                Circle()
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 2)
                    .frame(width: 11, height: 11)
            }
        }
    }

    /// The scheduled gap to the next stop — the delta every estimate on this page is
    /// built from, shown where it belongs: on the line between the two stops.
    private func connector(to next: RideStopEstimate) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeWidth + timeGap + railWidth, height: 1)
            if let minutes = next.minutesFromPrevious {
                Text("\(minutes) min")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(height: connectorHeight)
    }
}

// MARK: - Pickers

/// Departures from the Plan tab's station, including ones that have just left — the
/// train you boarded two minutes ago is exactly the one you're looking for.
private struct TrainPickerSheet: View {
    let stationName: String
    @Binding var direction: TimetableDirection
    let selected: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()

    private var candidates: [NextTrainInfo] {
        CaltrainService.shared.rideCandidates(from: stationName,
                                              northbound: direction.isNorth,
                                              at: now)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Direction", selection: $direction) {
                        Text("Northbound").tag(TimetableDirection.northbound)
                        Text("Southbound").tag(TimetableDirection.southbound)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if candidates.isEmpty {
                        Text("No more \(direction.title.lowercased()) trains from \(stationName) today.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { train in
                            Button {
                                onSelect(train.trainNumber)
                                dismiss()
                            } label: {
                                row(train)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Departing \(stationName)")
                } footer: {
                    Text("Trains that left within the last 45 minutes are listed too, so you can pick the one you're already on.")
                }
            }
            .navigationTitle("Your train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ train: NextTrainInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(train.arrivalTime)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    TrainTypeBadge(trainClass: TrainClass(train.trainType))
                }
                Text("#\(train.trainNumber)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(departureLabel(train))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(train.minutesUntilArrival < 0 ? .tertiary : .secondary)

            if train.trainNumber == selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.caltrainRed)
            }
        }
        .contentShape(Rectangle())
    }

    private func departureLabel(_ train: NextTrainInfo) -> String {
        let minutes = train.minutesUntilArrival
        if minutes < 0 { return "\(-minutes) min ago" }
        return minutes == 0 ? "now" : "in \(minutes) min"
    }
}

/// Every stop still ahead on this train.
struct RideDestinationPickerSheet: View {
    let itinerary: RideItinerary
    let selected: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(itinerary.stops.dropFirst()) { stop in
                        Button {
                            onSelect(stop.station.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(stop.station.name)
                                    .font(.system(size: 16, design: .rounded))
                                Spacer(minLength: 8)
                                Text(RideFormat.clock(stop.scheduled))
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                if stop.station.name == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.caltrainRed)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Stops on #\(itinerary.trainNumber)")
                }
            }
            .navigationTitle("Getting off at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    RideView(direction: .constant(.northbound))
        .environmentObject(RideSession())
}

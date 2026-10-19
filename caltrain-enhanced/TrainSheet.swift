//
//  TrainSheet.swift
//  caltrain-enhanced
//
//  One train, start to finish: where it is, whether it's late, and every stop with its
//  printed and live times. Opened from a train on the map or a departure on Plan. "Hop
//  on" starts a trip to the end of the line; tapping a stop makes that your stop instead.
//

import SwiftUI

/// A train by number and direction: enough to find its run and its 511 data.
struct TrainRef: Identifiable, Hashable {
    let trainNumber: String
    let northbound: Bool

    /// Same form as `TrainFix.id`, so a map selection maps straight onto one.
    var id: String { "\(trainNumber)-\(northbound ? "N" : "S")" }

    init(trainNumber: String, northbound: Bool) {
        self.trainNumber = trainNumber
        self.northbound = northbound
    }

    init?(id: String) {
        let parts = id.split(separator: "-")
        guard parts.count == 2 else { return nil }
        self.init(trainNumber: String(parts[0]), northbound: parts[1] == "N")
    }
}

struct TrainSheet: View {
    let train: TrainRef
    /// The station you're at, if it's one this train still calls at: where "Hop on"
    /// boards you. Otherwise you board at the train's next stop.
    let boardingHint: String?
    /// Starts a trip on this train: boarding station, then the stop you get off at.
    let onHopOn: (String, String) -> Void

    @EnvironmentObject private var ride: RideSession
    @ObservedObject private var live = CaltrainLiveService.shared
    @ObservedObject private var location = SharedLocationManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let run = CaltrainService.shared.run(trainNumber: train.trainNumber,
                                                northbound: train.northbound,
                                                at: now) {
            let liveTrain = live.train(train.trainNumber, northbound: train.northbound, at: now)
            let estimate = RideEstimator.estimate(for: run, userLocation: nil, live: liveTrain, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(run: run, estimate: estimate, live: liveTrain, now: now)
                    if isRiding {
                        tripCard(now: now)
                    } else if let origin = boarding(in: estimate), let terminus = run.terminus {
                        hopOnButton(origin: origin, destination: terminus.station.name)
                    }
                    stops(estimate: estimate, now: now)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            Text("Train #\(train.trainNumber) isn't on today's timetable.")
                .foregroundStyle(.secondary)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isRiding: Bool {
        ride.trainNumber == train.trainNumber && ride.northbound == train.northbound
    }

    // MARK: Header

    private func header(run: RideItinerary, estimate: RideEstimate, live liveTrain: LiveTrain?, now: Date) -> some View {
        let cancelled = live.isCancelled(train.trainNumber, at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(train.trainNumber)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .strikethrough(cancelled)
                TrainTypeBadge(trainClass: TrainClass(run.trainType))
                Spacer(minLength: 8)
                if cancelled {
                    Text("Cancelled")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.alertAmber)
                } else {
                    TrainStatusPill(estimate: estimate)
                }
            }

            Text("\(train.northbound ? "Northbound" : "Southbound") to \(run.terminus?.station.name ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let whereabouts = whereabouts(run: run, live: liveTrain, now: now) {
                Text(whereabouts)
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private func whereabouts(run: RideItinerary, live liveTrain: LiveTrain?, now: Date) -> String? {
        if let fix = TrainFix(run: run, live: liveTrain, now: now) {
            return fix.hasFinished(at: now) ? "Arrived at \(run.terminus?.station.name ?? "the end of the line")" : fix.whereabouts
        }
        guard let origin = run.origin else { return nil }
        return "Leaves \(origin.station.name) at \(RideFormat.clock(origin.scheduled))"
    }

    // MARK: Trip

    /// Where "Hop on" boards you: your station if the train still calls there before
    /// the end of the line, otherwise the stop it's coming up to — you're on it already.
    private func boarding(in estimate: RideEstimate) -> String? {
        let ahead = Array(estimate.stops.filter { !$0.hasPassed }.dropLast())
        if let hint = boardingHint,
           ahead.contains(where: { $0.station.name.caseInsensitiveCompare(hint) == .orderedSame }) {
            return hint
        }
        return ahead.first?.station.name
    }

    private func hopOnButton(origin: String, destination: String) -> some View {
        Button { onHopOn(origin, destination) } label: {
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                Text("Hop on")
                Spacer(minLength: 8)
                Text("\(origin) → \(destination)")
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.85)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.caltrainRed))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Follows this train to \(destination). Tap a stop below to get off somewhere else.")
    }

    /// The trip you're on: how long to your stop, and a way out.
    @ViewBuilder
    private func tripCard(now: Date) -> some View {
        if let origin = ride.originName,
           let itinerary = CaltrainService.shared.itinerary(trainNumber: train.trainNumber,
                                                            northbound: train.northbound,
                                                            boardingAt: origin,
                                                            at: now) {
            let estimate = RideEstimator.estimate(for: itinerary,
                                                  userLocation: location.userLocation,
                                                  live: live.train(train.trainNumber, northbound: train.northbound, at: now),
                                                  now: now)
            let destination = estimate.stop(named: ride.destinationName)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Getting off at")
                    Text(destination?.station.name ?? "Tap a stop below")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if let destination {
                        Text(destination.hasPassed
                             ? "Arrived \(RideFormat.clock(destination.projected))"
                             : "Arrives \(RideFormat.clock(destination.projected))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let destination, !destination.hasPassed {
                    let minutes = destination.minutesAway(from: now)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(minutes == 0 ? "Now" : "\(minutes)")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(minutes <= 5 ? Color.caltrainRed : .primary)
                        if minutes != 0 {
                            Text("min")
                                .font(.caption2)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .cardBackground()

            Button(role: .destructive) { ride.end() } label: {
                Text("End trip")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Color.caltrainRed)
        }
    }

    // MARK: Stops

    private func stops(estimate: RideEstimate, now: Date) -> some View {
        let origin = isRiding ? ride.originName : boarding(in: estimate)
        let originIndex = origin.flatMap { estimate.index(of: $0) }
        // On a trip only what's still ahead of you matters; otherwise the whole run.
        let shown = estimate.stops.enumerated().filter { index, stop in
            !isRiding || (!isBehind(stop, now: now) && originIndex.map { index >= $0 } != false)
        }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(isRiding ? "Stops ahead" : "Stops")
            VStack(spacing: 0) {
                ForEach(shown, id: \.element.id) { index, stop in
                    // Somewhere you could get off: after where you board, not behind the train.
                    let canAlight = !stop.hasPassed && originIndex.map { index > $0 } == true
                    Button {
                        guard let origin else { return }
                        if isRiding {
                            ride.destinationName = stop.station.name
                        } else {
                            onHopOn(origin, stop.station.name)
                        }
                    } label: {
                        stopRow(stop, estimate: estimate, isBoarding: index == originIndex,
                                isBehind: isBehind(stop, now: now))
                    }
                    .buttonStyle(.plain)
                    // Ignoring taps rather than `.disabled`, which would dim the row: the
                    // boarding stop isn't somewhere to get off, but it isn't behind you either.
                    .allowsHitTesting(canAlight)
                    .accessibilityHint(canAlight ? "Get off here" : "")
                    if index != shown.last?.offset {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 34)
                    }
                }
            }
            .padding(.vertical, 4)
            .cardBackground()

            Text("Tap a stop to get off there.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    /// How long a stop stays in full colour after its time. The train may be standing
    /// there or only just gone, and riders still glance back at it.
    private static let behindAfter: TimeInterval = 5 * 60

    /// Greyed out, and dropped from a trip's list, only once it's well behind.
    private func isBehind(_ stop: RideStopEstimate, now: Date) -> Bool {
        stop.hasPassed && now >= stop.projected.addingTimeInterval(Self.behindAfter)
    }

    private func stopRow(_ stop: RideStopEstimate, estimate: RideEstimate, isBoarding: Bool, isBehind: Bool) -> some View {
        let isDestination = isRiding && stop.station.name == ride.destinationName
        let projected = RideFormat.clock(stop.projected)
        let scheduled = RideFormat.clock(stop.scheduled)
        let moved = projected != scheduled
        return HStack(spacing: 10) {
            Circle()
                .fill(isBehind ? Color.caltrainRed.opacity(0.4)
                      : isDestination ? Color.caltrainRed : Color(.systemBackground))
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(isBehind || isDestination ? .clear : Color.primary.opacity(0.35),
                                               lineWidth: 2))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(stop.station.name)
                    .font(.system(size: 16, weight: isDestination || isBoarding ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isBehind ? .secondary : .primary)
                if isDestination || isBoarding {
                    Text(isDestination ? "Your stop" : "Boarding")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.caltrainRed)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(projected)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(isBehind ? AnyShapeStyle(.tertiary)
                                     : estimate.isLive ? AnyShapeStyle(Color.caltrainRed) : AnyShapeStyle(.primary))
                if moved {
                    Text(scheduled)
                        .font(.system(size: 11, design: .rounded))
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status

/// On time or not, and whether that's 511, your phone, or just the timetable talking.
struct TrainStatusPill: View {
    let estimate: RideEstimate

    var body: some View {
        let late = estimate.delayMinutes
        // The feed runs a few seconds early as often as late; early reads as on time.
        let onTime = late <= 0
        let color = onTime ? Color.secondary : Color.caltrainRed
        HStack(spacing: 5) {
            Image(systemName: estimate.source == .feed ? "dot.radiowaves.left.and.right"
                  : estimate.source == .location ? "location.fill" : "clock")
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
                            ? (onTime ? "On time, live" : "\(late) minutes late, live")
                            : "Timetable only, no live data yet")
    }
}

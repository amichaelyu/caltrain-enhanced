//
//  TrainMapView.swift
//  caltrain-enhanced
//
//  Every train on the line at once. Each one sits where 511 says it is when the feed is
//  tracking it, and where the timetable says it should be when it isn't; the puck's
//  colour says which. On a trip it's also the ride view: your stretch of line drawn in,
//  the part behind you solid, pulses running on ahead to your stop.
//

import SwiftUI
import MapKit

struct TrainMapView: View {
    @EnvironmentObject private var ride: RideSession
    @ObservedObject private var live = CaltrainLiveService.shared
    @ObservedObject private var location = SharedLocationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var isVisible = false
    @State private var selectedID: String?
    @State private var camera: MapCameraPosition = .rect(TrainMapView.corridorRect)

    /// Where every train is as of the last tick.
    @State private var fixes: [TrainFix] = []
    /// Where each train was drawn when that tick landed: the start of its glide.
    @State private var glideStart: [String: CLLocationCoordinate2D] = [:]
    /// Where each glide ends: the train's new position, unless that's further than a
    /// train could go in a tick, in which case the glide only goes that far toward it.
    @State private var glideEnd: [String: CLLocationCoordinate2D] = [:]
    /// The line from the trip's train to your boarding stop while it's still on its way.
    @State private var approach: RideRoute?
    @State private var tickDate = Date()
    /// The trip's stretch of line, boarding platform to your stop. Nil off a trip.
    @State private var trip: RideRoute?

    /// Positions are worked out once a second; the map redraws every frame in between,
    /// sliding each train from where it was drawn to where it now is. MapKit won't
    /// animate an annotation's coordinate on its own, so this is what makes it glide.
    private static let tick: TimeInterval = 1
    private let ticker = Timer.publish(every: TrainMapView.tick, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.animation(paused: scenePhase != .active)) { context in
            map(at: context.date)
        }
        .safeAreaInset(edge: .top) { summary(fixes) }
        .safeAreaInset(edge: .bottom) {
            // The trip, when its sheet is put away: tap to bring it back.
            if let rideID, selectedID == nil {
                tripBanner { selectedID = rideID }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        // Drag it up for every stop; the map stays live behind it at the smaller sizes.
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let train = selectedID.flatMap(TrainRef.init(id:)) {
                TrainSheet(train: train, boardingHint: location.activeStation?.name) { origin, destination in
                    ride.start(trainNumber: train.trainNumber, from: origin,
                               northbound: train.northbound, destinationName: destination)
                }
                .environmentObject(ride)
                .presentationDetents([.height(250), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
        }
        .onChange(of: rideKey, initial: true) { _, _ in startTrip() }
        .onChange(of: ride.destinationName) { _, _ in trip = makeTrip() }
        .onReceive(ticker) { date in
            guard scenePhase == .active else { return }
            advance(to: date)
        }
        .onChange(of: scenePhase, initial: true) { _, _ in
            advance(to: Date(), glide: false)
            updateLiveFeed()
        }
        .onAppear { isVisible = true; advance(to: Date(), glide: false); updateLiveFeed() }
        .onDisappear { isVisible = false; updateLiveFeed() }
    }

    private func map(at date: Date) -> some View {
        Map(position: $camera, selection: $selectedID) {
            MapPolyline(coordinates: CaltrainCorridor.path)
                .stroke(Color.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            ForEach(CaltrainStations.shared.stations, id: \.name) { station in
                Annotation(station.name, coordinate: station.coordinate, anchor: .center) {
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 2))
                }
            }

            if let trip {
                tripTrail(trip, at: date)
            }

            // Still coming to get you: a dotted line from the train to your platform.
            if let approach, let rideID, let fix = fixes.first(where: { $0.id == rideID }) {
                let line = approach.slice(from: approach.distance(of: drawnCoordinate(fix, at: tickDate)),
                                          to: approach.length)
                if line.count >= 2 {
                    MapPolyline(coordinates: line)
                        .stroke(rideTint.opacity(colorScheme == .dark ? 0.6 : 0.5),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 9]))
                }
            }

            if let destination = ride.destinationName.flatMap(CaltrainStations.shared.station(named:)), rideID != nil {
                Annotation(destination.name, coordinate: destination.coordinate, anchor: .center) {
                    ZStack {
                        Circle().fill(rideTint).frame(width: 20, height: 20)
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color.onDirection(northbound: ride.northbound))
                    }
                    .shadow(radius: 1, y: 0.5)
                }
            }

            UserAnnotation()

            ForEach(fixes) { fix in
                // Anchored by its foot, so the number floats above the line instead of
                // sitting on a station's dot.
                Annotation("#\(fix.run.trainNumber)", coordinate: drawnCoordinate(fix, at: date), anchor: .bottom) {
                    MapTrainPuck(fix: fix, isSelected: fix.id == selectedID)
                }
                .annotationTitles(.hidden)
                .tag(fix.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    // MARK: Trip

    private var rideID: String? {
        ride.trainNumber.map { TrainRef(trainNumber: $0, northbound: ride.northbound).id }
    }

    private var rideKey: String {
        "\(rideID ?? "-")|\(ride.originName ?? "-")"
    }

    /// A new trip opens its train's sheet and frames the stretch you're riding.
    private func startTrip() {
        trip = makeTrip()
        guard let rideID else { return }
        selectedID = rideID
        if let trip, let rect = Self.boundingRect(trip.coordinates) {
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .rect(rect.insetBy(dx: -rect.size.width * 0.35, dy: -rect.size.height * 0.35))
            }
        }
    }

    private func makeTrip() -> RideRoute? {
        guard let train = ride.trainNumber, let origin = ride.originName,
              let itinerary = CaltrainService.shared.itinerary(trainNumber: train,
                                                               northbound: ride.northbound,
                                                               boardingAt: origin)
        else { return nil }
        let end = itinerary.index(of: ride.destinationName ?? "") ?? itinerary.stops.count - 1
        return RideRoute(stations: itinerary.stops.prefix(end + 1).map(\.station))
    }

    /// How long one pulse takes to run from the train to your stop.
    private static let pulsePeriod: TimeInterval = 2.4

    /// The trip's train's colour.
    private var rideTint: Color { .direction(northbound: ride.northbound) }

    /// Your stretch of line: faint ahead, solid behind the train, and pulses running on
    /// toward your stop. The lines only change once a tick: MapKit draws lines in tiles in
    /// the background, and redrawing them every frame left blurry blobs where it couldn't
    /// keep up. The pulses are beads riding on the line, which it can move every frame.
    @MapContentBuilder
    private func tripTrail(_ trip: RideRoute, at date: Date) -> some MapContent {
        let done = rideTrainDistance(on: trip, at: tickDate)
        let style = StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)

        MapPolyline(coordinates: trip.coordinates)
            .stroke(rideTint.opacity(colorScheme == .dark ? 0.45 : 0.32), style: style)

        let ridden = trip.slice(from: 0, to: done)
        if ridden.count >= 2 {
            MapPolyline(coordinates: ridden).stroke(rideTint, style: style)
        }

        ForEach(beads(on: trip, done: done, at: date)) { bead in
            Annotation("", coordinate: bead.coordinate, anchor: .center) {
                Circle()
                    .fill(rideTint.opacity(bead.strength * (colorScheme == .dark ? 0.5 : 0.4)))
                    .frame(width: bead.size, height: bead.size)
                    .allowsHitTesting(false)
            }
            .annotationTitles(.hidden)
        }
    }

    private struct Bead: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        /// 1 at the head of a pulse, fading toward its tail.
        let strength: Double
        let size: CGFloat
    }

    /// Two pulses half a period apart, each a head bead and a short fading tail, running
    /// from the train (or your platform, before it's there) to your stop.
    private func beads(on trip: RideRoute, done: Double, at date: Date) -> [Bead] {
        let remaining = trip.length - done
        guard remaining > 1 else { return [] }
        let tail = max(remaining * 0.15, 250)
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.pulsePeriod)
            / Self.pulsePeriod
        var beads: [Bead] = []
        for pulse in 0..<2 {
            let t = (phase + Double(pulse) / 2).truncatingRemainder(dividingBy: 1)
            let head = done + (remaining + tail) * t
            for step in 0..<4 {
                let at = head - tail * Double(step) / 4
                guard at > done, at < trip.length else { continue }
                let strength = 1 - Double(step) / 4
                beads.append(Bead(id: pulse * 4 + step,
                                  coordinate: trip.point(at: at),
                                  strength: strength,
                                  size: 5 + 3 * strength))
            }
        }
        return beads
    }

    /// How far along your stretch the ride's train is drawn. Zero until it reaches your
    /// boarding platform.
    private func rideTrainDistance(on trip: RideRoute, at date: Date) -> Double {
        guard let rideID, let fix = fixes.first(where: { $0.id == rideID }),
              let origin = ride.originName, let boardIndex = fix.run.index(of: origin)
        else { return 0 }
        // Still short of where you board: nothing ridden yet.
        let placement = fix.placement
        guard placement.segmentIndex > boardIndex
                || (placement.segmentIndex == boardIndex && placement.fraction > 0)
        else { return 0 }
        return trip.distance(of: drawnCoordinate(fix, at: date))
    }

    private func tripBanner(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .foregroundStyle(rideTint)
                Text("#\(ride.trainNumber ?? "")\(ride.destinationName.map { " to \($0)" } ?? "")")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your trip on train \(ride.trainNumber ?? ""). Shows its stops")
    }

    private static func boundingRect(_ coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return nil }
        return points.reduce(MKMapRect(origin: first, size: MKMapSize(width: 1, height: 1))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1)))
        }
    }

    // MARK: Motion

    private func currentFixes(at date: Date) -> [TrainFix] {
        CaltrainService.shared.runs(at: date).compactMap { run in
            guard !live.isCancelled(run.trainNumber, at: date) else { return nil }
            return TrainFix(run: run,
                            live: live.train(run.trainNumber, northbound: run.northbound, at: date),
                            now: date)
        }
        .filter { !$0.hasFinished(at: date) }
    }

    /// Starts each glide from wherever the train is drawn right now, so a late tick or a
    /// fresh 511 fix bends its path instead of making it jump.
    private func advance(to date: Date, glide: Bool = true) {
        glideStart = glide
            ? Dictionary(fixes.map { ($0.id, drawnCoordinate($0, at: date)) }, uniquingKeysWith: { a, _ in a })
            : [:]
        fixes = currentFixes(at: date)
        glideEnd = Dictionary(fixes.compactMap { fix in
            glideStart[fix.id].map { (fix.id, Self.capped(from: $0, toward: fix.coordinate)) }
        }, uniquingKeysWith: { a, _ in a })
        approach = makeApproach()
        tickDate = date
    }

    /// Fastest a correction may move a train, in metres per second. A fresh 511 fix that
    /// disagrees with the estimate is caught up with at about train speed over a few
    /// seconds, instead of in one lurch.
    private static let catchUpSpeed: Double = 70

    private static func capped(from start: CLLocationCoordinate2D,
                               toward target: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let gap = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        let step = catchUpSpeed * tick
        guard gap > step else { return target }
        return CaltrainCorridor.interpolate(start, target, step / gap)
    }

    /// The trip's train's stretch from the stop behind it to your boarding stop. Nil once
    /// it's there, or off a trip.
    private func makeApproach() -> RideRoute? {
        guard let rideID, let fix = fixes.first(where: { $0.id == rideID }),
              let origin = ride.originName, let boardIndex = fix.run.index(of: origin),
              fix.placement.segmentIndex < boardIndex,
              !(fix.placement.segmentIndex == boardIndex - 1 && fix.placement.fraction >= 1)
        else { return nil }
        return RideRoute(stations: fix.run.stops[fix.placement.segmentIndex...boardIndex].map(\.station))
    }

    private func drawnCoordinate(_ fix: TrainFix, at date: Date) -> CLLocationCoordinate2D {
        guard let start = glideStart[fix.id] else { return fix.coordinate }
        let t = min(max(date.timeIntervalSince(tickDate) / Self.tick, 0), 1)
        return CaltrainCorridor.interpolate(start, glideEnd[fix.id] ?? fix.coordinate, t)
    }

    /// Count of trains out, and how many of them 511 is actually tracking. 511's
    /// attribution lives in Settings.
    private func summary(_ fixes: [TrainFix]) -> some View {
        let tracked = fixes.filter(\.isLive).count
        return HStack(spacing: 6) {
            Image(systemName: tracked > 0 ? "dot.radiowaves.left.and.right" : "clock")
                .font(.system(size: 10, weight: .bold))
            Text(fixes.isEmpty
                 ? "No trains running"
                 : "\(fixes.count) \(fixes.count == 1 ? "train" : "trains") · \(tracked) live")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tracked > 0 ? Color.caltrainRed : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func updateLiveFeed() {
        if scenePhase == .active && isVisible {
            live.start(for: "map")
        } else {
            live.stop(for: "map")
        }
    }

    /// The whole corridor, with a little room either side.
    private static let corridorRect: MKMapRect = {
        guard let rect = boundingRect(CaltrainCorridor.path) else { return .world }
        return rect.insetBy(dx: -rect.size.width * 0.3, dy: -rect.size.height * 0.05)
    }()
}

// MARK: - Puck

/// Train number with an arrow for its direction, in the direction's colour: solid when
/// 511 placed it, faded when only the timetable did.
private struct MapTrainPuck: View {
    let fix: TrainFix
    let isSelected: Bool

    var body: some View {
        // Direction picks the colour; a train only the timetable is placing is faded.
        let color = Color.direction(northbound: fix.run.northbound).opacity(fix.isLive ? 1 : 0.45)
        VStack(spacing: 0) {
            label(color)
            // Stem down to where the train actually is.
            Rectangle().fill(color).frame(width: 2, height: 6)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
        }
        .shadow(radius: 2, y: 1)
    }

    private func label(_ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: fix.run.northbound ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .black))
            Text(fix.run.trainNumber)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Color.onDirection(northbound: fix.run.northbound))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color))
        .overlay(Capsule().strokeBorder(Color(.systemBackground), lineWidth: isSelected ? 2.5 : 1.5))
        .scaleEffect(isSelected ? 1.25 : 1, anchor: .bottom)
    }
}

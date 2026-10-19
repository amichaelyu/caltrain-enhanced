//
//  TrainMapView.swift
//  caltrain-enhanced
//
//  Every train on the line at once. Each one sits where 511 says it is when the feed is
//  tracking it, and where the timetable says it should be when it isn't; the puck's
//  colour says which.
//

import SwiftUI
import MapKit

struct TrainMapView: View {
    @ObservedObject private var live = CaltrainLiveService.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var now = Date()
    @State private var isVisible = false
    @State private var selectedID: String?
    @State private var camera: MapCameraPosition = .rect(TrainMapView.corridorRect)

    /// Fast enough that a timetable-placed train visibly creeps along between feed polls.
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var fixes: [TrainFix] {
        CaltrainService.shared.runs(at: now).compactMap { run in
            TrainFix(run: run,
                     live: live.train(run.trainNumber, northbound: run.northbound, at: now),
                     now: now)
        }
        .filter { !$0.hasFinished(at: now) }
    }

    var body: some View {
        let fixes = fixes
        let selected = fixes.first { $0.id == selectedID }

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

            UserAnnotation()

            ForEach(fixes) { fix in
                // Anchored by its foot, so the number floats above the line instead of
                // sitting on a station's dot.
                Annotation("#\(fix.run.trainNumber)", coordinate: fix.coordinate, anchor: .bottom) {
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
        .safeAreaInset(edge: .top) { summary(fixes) }
        .safeAreaInset(edge: .bottom) {
            if let selected {
                TrainDetailCard(fix: selected) { selectedID = nil }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedID)
        .onReceive(ticker) { date in
            guard scenePhase == .active else { return }
            now = date
        }
        .onChange(of: scenePhase, initial: true) { _, _ in
            now = Date()
            updateLiveFeed()
        }
        .onAppear { isVisible = true; now = Date(); updateLiveFeed() }
        .onDisappear { isVisible = false; updateLiveFeed() }
    }

    /// Count of trains out, and how many of them 511 is actually tracking. The 511 wording
    /// doubles as the attribution their data terms ask for.
    private func summary(_ fixes: [TrainFix]) -> some View {
        let tracked = fixes.filter(\.isLive).count
        return HStack(spacing: 6) {
            Image(systemName: tracked > 0 ? "dot.radiowaves.left.and.right" : "clock")
                .font(.system(size: 10, weight: .bold))
            Text(fixes.isEmpty
                 ? "No trains running"
                 : "\(fixes.count) \(fixes.count == 1 ? "train" : "trains") · \(tracked) live from 511.org")
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
        let points = CaltrainCorridor.path.map(MKMapPoint.init)
        guard let first = points.first else { return .world }
        let rect = points.reduce(MKMapRect(origin: first, size: MKMapSize(width: 1, height: 1))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1)))
        }
        return rect.insetBy(dx: -rect.size.width * 0.3, dy: -rect.size.height * 0.05)
    }()
}

// MARK: - Puck

/// Train number with an arrow for its direction. Red when 511 placed it, grey when the
/// timetable did.
private struct MapTrainPuck: View {
    let fix: TrainFix
    let isSelected: Bool

    var body: some View {
        let color = fix.isLive ? Color.caltrainRed : Color.gray
        VStack(spacing: 0) {
            label(color)
            // Stem down to where the train actually is.
            Rectangle().fill(color).frame(width: 2, height: 6)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
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
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color))
        .overlay(Capsule().strokeBorder(.white, lineWidth: isSelected ? 2.5 : 1.5))
        .scaleEffect(isSelected ? 1.25 : 1, anchor: .bottom)
    }
}

// MARK: - Detail

private struct TrainDetailCard: View {
    let fix: TrainFix
    let onClose: () -> Void

    private var lateness: String {
        let late = fix.estimate.delayMinutes
        guard fix.estimate.isLive else { return "Timetable only" }
        return late <= 0 ? "On time" : "\(late) min late"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(fix.run.trainNumber)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                TrainTypeBadge(trainClass: TrainClass(fix.run.trainType))
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .padding(7)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text("\(fix.run.northbound ? "Northbound" : "Southbound") to \(fix.run.terminus?.station.name ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(fix.whereabouts)
                .font(.subheadline.weight(.medium))

            HStack(spacing: 4) {
                Image(systemName: fix.isLive ? "dot.radiowaves.left.and.right" : "clock")
                    .font(.system(size: 9, weight: .bold))
                Text(fix.isLive ? "\(lateness) · live from 511.org" : lateness)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(fix.isLive && fix.estimate.delayMinutes > 0 ? Color.caltrainRed : .secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

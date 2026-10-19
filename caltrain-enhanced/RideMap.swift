//
//  RideMap.swift
//  caltrain-enhanced
//
//  The ride drawn on a map instead of down the page: every stop on the run as a point,
//  the line between them, and the train somewhere along it. Where the train sits comes
//  from your own location when you're close enough to the corridor to be believed, and
//  from the projected times when you aren't. The line itself is the real corridor
//  centreline out of `CaltrainCorridor`, not a chord between platforms.
//

import SwiftUI
import MapKit
import CoreLocation

struct RideMap: View {
    let estimate: RideEstimate
    /// Where to draw the train; eased by the caller so it glides between fixes.
    let placement: RidePlacement?
    let destinationName: String?
    let now: Date
    let onSelect: (String) -> Void

    @State private var camera: MapCameraPosition = .automatic
    /// The camera as the rider last left it, so following re-centres without undoing
    /// their zoom.
    @State private var lastCamera: MapCamera?
    /// Follow the train, or hold still on the whole run.
    @State private var followsTrain = true

    private var stops: [RideStopEstimate] { estimate.stops }
    private var destinationIndex: Int? { estimate.index(of: destinationName) }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            // The whole run, faint, so you can see where the train is headed.
            line(track(through: stops), color: .primary.opacity(0.16), width: 4)

            if let destinationIndex {
                line(track(through: Array(stops.prefix(destinationIndex + 1))),
                     color: Color.caltrainRed.opacity(0.35), width: 5)
            }

            // Boarding station up to the train: the part of the ride already behind you.
            line(travelled, color: Color.caltrainRed, width: 5)

            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                Annotation(stop.station.name, coordinate: stop.station.coordinate, anchor: .center) {
                    Button { onSelect(stop.station.name) } label: {
                        StopDot(stop: stop,
                                isDestination: index == destinationIndex,
                                isBoarding: index == 0)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(labelled(index: index) ? .automatic : .hidden)
            }

            if let coordinate = trainCoordinate {
                Annotation("Train", coordinate: coordinate, anchor: .center) {
                    TrainPuck(isLive: placement?.isLive == true)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) { followButton }
        .overlay(alignment: .bottomLeading) { sourceBadge }
        .onMapCameraChange(frequency: .onEnd) { context in lastCamera = context.camera }
        .onChange(of: cameraKey, initial: true) { old, new in
            // Mode switches get an eased move; following a moving train inherits the
            // tick's linear animation so the camera glides with it.
            frame(eased: old.split(separator: "|").first != new.split(separator: "|").first || lastCamera == nil)
        }
        .accessibilityLabel("Map of the run, train placed \(sourceLabel.lowercased())")
    }

    // MARK: Geometry

    /// Track through a run of stops, stitched leg by leg. Legs the corridor doesn't
    /// recognise degrade to a straight hop rather than dropping out of the line.
    private func track(through stops: [RideStopEstimate]) -> [CLLocationCoordinate2D] {
        guard stops.count >= 2 else { return stops.map(\.station.coordinate) }
        return zip(stops, stops.dropFirst()).reduce(into: [CLLocationCoordinate2D]()) { out, pair in
            let (a, b) = pair
            let leg = CaltrainCorridor.track(from: a.station.name, to: b.station.name)
                ?? [a.station.coordinate, b.station.coordinate]
            out += out.isEmpty ? leg : Array(leg.dropFirst())
        }
    }

    /// Boarding station up to wherever the train is, following the rails on the leg it's
    /// halfway through. Empty before the train has left, which is what puts the puck back
    /// at the platform.
    private var travelled: [CLLocationCoordinate2D] {
        guard let placement else { return [] }
        var out = track(through: Array(stops.prefix(placement.segmentIndex + 1)))
        guard placement.segmentIndex + 1 < stops.count else { return out }

        let from = stops[placement.segmentIndex].station
        let to = stops[placement.segmentIndex + 1].station
        let leg = CaltrainCorridor.track(from: from.name, to: to.name, upTo: placement.fraction)
            ?? [from.coordinate,
                CaltrainCorridor.interpolate(from.coordinate, to.coordinate, placement.fraction)]
        out += leg.dropFirst()
        return out
    }

    /// Where to draw the train: the far end of the track it has covered, or the boarding
    /// platform before departure.
    private var trainCoordinate: CLLocationCoordinate2D? {
        travelled.last ?? stops.first?.station.coordinate
    }

    /// Names on the map for the ends of the ride only; the rest would just collide.
    private func labelled(index: Int) -> Bool {
        index == 0 || index == destinationIndex || (destinationIndex == nil && index == stops.count - 1)
    }

    @MapContentBuilder
    private func line(_ coordinates: [CLLocationCoordinate2D], color: Color, width: CGFloat) -> some MapContent {
        if coordinates.count >= 2 {
            MapPolyline(coordinates: coordinates)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Camera

    /// Recentre whenever the drawn train moves a metre or so, which while it glides is
    /// most frames, so the camera rides along with it. The whole-run view only reframes
    /// when the run itself changes, so it leaves the rider's zoom alone.
    private var cameraKey: String {
        let mode = followsTrain ? "follow" : "run"
        guard followsTrain else { return "\(mode)|\(destinationName ?? "-")" }
        guard let coordinate = trainCoordinate else { return "\(mode)|-" }
        return String(format: "%@|%.5f,%.5f|%@", mode, coordinate.latitude, coordinate.longitude,
                      destinationName ?? "-")
    }

    private func frame(eased: Bool) {
        let target: MapCameraPosition
        if followsTrain, let coordinate = trainCoordinate {
            if let lastCamera {
                target = .camera(MapCamera(centerCoordinate: coordinate,
                                           distance: lastCamera.distance,
                                           heading: lastCamera.heading,
                                           pitch: lastCamera.pitch))
            } else {
                target = .region(MKCoordinateRegion(center: coordinate,
                                                    latitudinalMeters: 5_000,
                                                    longitudinalMeters: 5_000))
            }
        } else {
            let shown = destinationIndex.map { Array(stops.prefix($0 + 1)) } ?? stops
            guard let rect = boundingRect(track(through: shown)) else { return }
            target = .rect(rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2))
        }
        if eased {
            withAnimation(.easeInOut(duration: 0.4)) { camera = target }
        } else {
            camera = target
        }
    }

    private func boundingRect(_ coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        return MKMapRect(x: minX, y: minY,
                         width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    // MARK: Chrome

    private var followButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { followsTrain.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: followsTrain ? "location.fill" : "arrow.up.left.and.arrow.down.right")
                Text(followsTrain ? "Following" : "Whole run")
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityHint(followsTrain ? "Show the whole run" : "Follow the train")
    }

    /// Says plainly whether the puck is 511, your phone, or the timetable, so a train drawn
    /// in the wrong place is never mistaken for a fact. 511's attribution lives in Settings.
    private var sourceLabel: String {
        switch placement?.source ?? estimate.source {
        case .feed: "Live"
        case .location: "From your location"
        case .timetable: "From the timetable"
        }
    }

    private var sourceBadge: some View {
        let source = placement?.source ?? estimate.source
        let live = source != .timetable
        return HStack(spacing: 4) {
            Image(systemName: source == .location ? "location.fill"
                  : live ? "dot.radiowaves.left.and.right" : "clock")
            Text(sourceLabel)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(live ? Color.caltrainRed : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
    }
}

// MARK: - Markers

private struct StopDot: View {
    let stop: RideStopEstimate
    let isDestination: Bool
    let isBoarding: Bool

    var body: some View {
        ZStack {
            if isDestination {
                Circle().fill(Color.caltrainRed).frame(width: 18, height: 18)
                Image(systemName: "flag.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white)
            } else if isBoarding {
                Circle().fill(Color.caltrainRed.opacity(0.85)).frame(width: 13, height: 13)
                Circle().fill(.white).frame(width: 5, height: 5)
            } else {
                Circle()
                    .fill(stop.hasPassed ? Color.caltrainRed.opacity(0.45) : Color(.systemBackground))
                    .frame(width: 11, height: 11)
                Circle()
                    .strokeBorder(stop.hasPassed ? Color.clear : Color.primary.opacity(0.35), lineWidth: 2)
                    .frame(width: 11, height: 11)
            }
        }
        .shadow(radius: 1, y: 0.5)
        // A dot this small is unhittable; the tap target is bigger than the drawing.
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }
}

private struct TrainPuck: View {
    let isLive: Bool

    var body: some View {
        Image(systemName: "tram.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.caltrainRed))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .overlay {
                if isLive {
                    Circle().stroke(Color.caltrainRed.opacity(0.35), lineWidth: 6).scaleEffect(1.5)
                }
            }
            .shadow(radius: 3, y: 1)
    }
}

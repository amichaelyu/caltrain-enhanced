//
//  StationRouteMap.swift
//  caltrain-enhanced
//
//  A small non-interactive map showing the path from the user's location to the
//  station. Tapping it hands off to the user's preferred maps app.
//

import SwiftUI
import MapKit
import CoreLocation

struct StationRouteMap: View {
    let station: CaltrainStation
    let origin: CLLocationCoordinate2D?
    let mode: TravelMode
    let onTap: () -> Void

    @State private var route: MKRoute?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            if let route {
                MapPolyline(route)
                    .stroke(Color.caltrainRed,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let origin {
                Annotation("You", coordinate: origin) { originDot }
                    .annotationTitles(.hidden)
            }
            Annotation(station.name, coordinate: station.coordinate) { stationPin }
                .annotationTitles(.hidden)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) { directionsBadge }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement()
        .accessibilityLabel("Map of the route to \(station.name). Tap for directions.")
        .task(id: taskKey) { await loadRoute() }
    }

    /// Refetch whenever the mode, the station or the origin changes. Movement is already
    /// thresholded where fixes are published, and repeat lookups hit the route cache, so
    /// this can track the origin directly instead of coarsening it a second time.
    private var taskKey: String {
        let lat = origin.map { String(format: "%.4f", $0.latitude) } ?? "-"
        let lon = origin.map { String(format: "%.4f", $0.longitude) } ?? "-"
        return "\(station.name)|\(mode)|\(lat),\(lon)"
    }

    private var originDot: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 0.5)
    }

    private var stationPin: some View {
        Image(systemName: "tram.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(Circle().fill(Color.caltrainRed))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 0.5)
    }

    private var directionsBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
            Text("Directions")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
    }

    private func loadRoute() async {
        guard let origin else {
            route = nil
            frame(nil)
            return
        }
        let fetched = await TravelTimeService.shared.routeGeometry(from: origin,
                                                                  to: station,
                                                                  mode: mode)
        route = fetched
        frame(fetched)
    }

    /// Fits the camera to the route, or to the two endpoints when no route came back.
    private func frame(_ route: MKRoute?) {
        let rect: MKMapRect
        if let route {
            rect = route.polyline.boundingMapRect
        } else if let origin {
            rect = MKMapRect(from: origin, to: station.coordinate)
        } else {
            camera = .region(MKCoordinateRegion(center: station.coordinate,
                                                latitudinalMeters: 800,
                                                longitudinalMeters: 800))
            return
        }
        // Pad so the endpoint markers aren't clipped by the card's edges.
        let padded = rect.insetBy(dx: -rect.size.width * 0.25,
                                  dy: -rect.size.height * 0.25)
        withAnimation(.easeInOut(duration: 0.35)) { camera = .rect(padded) }
    }
}

private extension MKMapRect {
    /// The smallest rect containing both coordinates.
    init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        let a = MKMapPoint(from)
        let b = MKMapPoint(to)
        self.init(x: min(a.x, b.x),
                  y: min(a.y, b.y),
                  width: max(abs(a.x - b.x), 1),
                  height: max(abs(a.y - b.y), 1))
    }
}

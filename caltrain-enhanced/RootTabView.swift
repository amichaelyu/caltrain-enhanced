//
//  RootTabView.swift
//  caltrain-enhanced
//
//  Two tabs, one shared idea of the trip: Plan is "when does a train leave", Map is
//  "where is everything, and where am I on the one I'm on". Direction and the trip live
//  here so picking a stop on Plan is the same act as starting a trip.
//

import SwiftUI

struct RootTabView: View {
    private enum Tab {
        case plan, map
    }

    @StateObject private var ride = RideSession()

    @State private var selection: Tab = .plan
    @State private var direction: TimetableDirection = .northbound

    var body: some View {
        TabView(selection: $selection) {
            ContentView(direction: $direction, onStartRide: startRide)
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(Tab.plan)

            TrainMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
        }
        .environmentObject(ride)
        .tint(Color.caltrainRed)
    }

    /// A trip is a train, where you board and where you get off. Starting one hands you
    /// to the map, which follows it.
    private func startRide(_ train: TrainRef, _ origin: String, _ destination: String) {
        ride.start(trainNumber: train.trainNumber,
                   from: origin,
                   northbound: train.northbound,
                   destinationName: destination)
        selection = .map
    }
}

#Preview {
    RootTabView()
}

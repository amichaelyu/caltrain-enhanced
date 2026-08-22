//
//  RootTabView.swift
//  caltrain-enhanced
//
//  Two tabs, one shared idea of the trip: Plan is "when does a train leave", Ride is
//  "where am I on the one I'm on". Direction and the ride itself live here so tapping a
//  departure on Plan is the same act as starting a ride.
//

import SwiftUI

struct RootTabView: View {
    private enum Tab {
        case plan, ride
    }

    @StateObject private var ride = RideSession()
    @ObservedObject private var location = SharedLocationManager.shared

    @State private var selection: Tab = .plan
    @State private var direction: TimetableDirection = .northbound

    var body: some View {
        TabView(selection: $selection) {
            ContentView(direction: $direction, onStartRide: startRide)
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(Tab.plan)

            RideView(direction: $direction)
                .tabItem { Label("Ride", systemImage: "tram.fill") }
                .tag(Tab.ride)
        }
        .environmentObject(ride)
        .tint(Color.caltrainRed)
    }

    /// Naming a train and a stop on Plan is the whole of a ride, so it boards there and
    /// hands the rider straight to the Ride tab.
    private func startRide(_ trainNumber: String, _ destinationName: String) {
        guard let station = location.activeStation else { return }
        ride.start(trainNumber: trainNumber,
                   from: station.name,
                   northbound: direction.isNorth,
                   destinationName: destinationName)
        selection = .ride
    }
}

#Preview {
    RootTabView()
}

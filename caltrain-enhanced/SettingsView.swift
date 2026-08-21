//
//  SettingsView.swift
//  caltrain-enhanced
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(MapsProvider.storageKey) private var mapsProviderRaw = MapsProvider.apple.rawValue
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var location = SharedLocationManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Navigate with", selection: $mapsProviderRaw) {
                        ForEach(MapsProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                } header: {
                    Text("Directions")
                } footer: {
                    Text("Tapping Walk, Bike or Drive opens directions to the nearest station in this app. If Google Maps isn't installed, directions open in the browser.")
                }

                Section("Location") {
                    LabeledContent("Nearest station",
                                   value: location.nearestStation?.name ?? "Locating…")

                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
}

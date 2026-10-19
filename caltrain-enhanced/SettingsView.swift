//
//  SettingsView.swift
//  caltrain-enhanced
//

import CoreLocation
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
                    Text("Tapping the route map opens directions to the station in this app. If Google Maps isn't installed, directions open in the browser.")
                }

                Section("Service tiers") {
                    ForEach(TrainClass.allCases) { trainClass in
                        keyRow(description: trainClass.description) {
                            TrainTypeBadge(trainClass: trainClass).fixedSize()
                        }
                    }
                }

                Section {
                    keyRow(description: "Northbound train. Red on the board, the timetable and the map.") {
                        sampleTime("7:42", style: Color.direction(northbound: true), bold: true, live: true)
                    }
                    keyRow(description: "Southbound train. Black, or white in dark mode.") {
                        sampleTime("7:42", style: Color.direction(northbound: false), bold: true, live: true)
                    }
                    keyRow(description: "The live icon: an estimate from 511.org. Without it, the printed timetable.") {
                        sampleTime("7:38", style: Color.primary)
                    }
                    keyRow(description: "Printed time, shown when the estimate differs from it.") {
                        sampleTime("7:38", style: Color.secondary, struck: true)
                    }
                } header: {
                    Text("Times")
                } footer: {
                    Text("Live data provided by 511.org.")
                }

                Section("Location") {
                    LabeledContent("Permission", value: Self.permissionLabel(location.authorizationStatus))

                    // Only worth offering a fix when there is something to fix.
                    switch location.authorizationStatus {
                    case .notDetermined:
                        Button("Allow Location Access") { location.requestLocation() }
                    case .denied, .restricted:
                        Button("Enable in iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("© \(Self.currentYear) Michael Yu")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
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

    /// One legend line: a fixed-width marker gutter so every description starts at the
    /// same x, then the description taking the remaining width.
    private func keyRow<Marker: View>(description: String,
                                      @ViewBuilder marker: () -> Marker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            marker()
                .frame(width: Self.markerWidth, alignment: .leading)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private func sampleTime(_ time: String, style: Color, bold: Bool = false, struck: Bool = false,
                            live: Bool = false) -> some View {
        HStack(spacing: 3) {
            if live {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(time)
                .font(.system(size: 16, weight: bold ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .strikethrough(struck)
        }
        .foregroundStyle(style)
        .accessibilityHidden(true)
    }

    /// Wide enough for the longest badge ("S. COUNTY") so none of them get clamped.
    private static let markerWidth: CGFloat = 78

    private static func permissionLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: "Enabled"
        case .denied, .restricted: "Disabled"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    /// Read at render time so the notice never goes stale.
    private static var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
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

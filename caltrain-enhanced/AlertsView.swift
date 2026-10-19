//
//  AlertsView.swift
//  caltrain-enhanced
//
//  511's service alerts: a banner on Plan when any are in force, and the full list
//  behind the button beside Settings. Alerts that name your station come first.
//

import SwiftUI

extension Color {
    /// Alerts get their own colour so they never read as a live time (red) or a train tier.
    static let alertAmber = Color(red: 0.93, green: 0.55, blue: 0.0)
}

/// Alerts touching `stationName` first, then the rest in feed order.
func sortedAlerts(_ alerts: [LiveAlert], for stationName: String?) -> [LiveAlert] {
    guard let stationName else { return alerts }
    let (mine, others) = alerts.reduce(into: ([LiveAlert](), [LiveAlert]())) { out, alert in
        if alert.mentions(station: stationName) { out.0.append(alert) } else { out.1.append(alert) }
    }
    return mine + others
}

// MARK: - Toolbar button

struct AlertsButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: count > 0 ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(count > 0 ? Color.alertAmber : .secondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.alertAmber))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityLabel(count == 0 ? "Alerts, none" : "Alerts, \(count) active")
    }
}

// MARK: - Banner

/// The first alert, shown on Plan whenever any are in force. Tapping opens the list.
struct AlertBanner: View {
    let alerts: [LiveAlert]
    let action: () -> Void

    var body: some View {
        if let first = alerts.first {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.alertAmber)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        if let label = first.effectLabel {
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.8)
                                .foregroundStyle(Color.alertAmber)
                        }
                        Text(first.header)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        if alerts.count > 1 {
                            Text("+\(alerts.count - 1) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.alertAmber.opacity(0.12))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all service alerts")
        }
    }
}

// MARK: - List

struct AlertsSheet: View {
    let stationName: String?

    @ObservedObject private var live = CaltrainLiveService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let alerts = sortedAlerts(live.activeAlerts(), for: stationName)
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No service alerts")
                            .font(.headline)
                        Text("Caltrain hasn't posted anything that affects service right now.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(alerts) { alert in
                        AlertRow(alert: alert, isLocal: stationName.map(alert.mentions(station:)) ?? false)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AlertRow: View {
    let alert: LiveAlert
    let isLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let label = alert.effectLabel {
                    Text(label)
                        .foregroundStyle(Color.alertAmber)
                }
                if isLocal {
                    Text("Your station")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)

            Text(alert.header)
                .font(.body.weight(.semibold))

            if let description = alert.description, !description.isEmpty, description != alert.header {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let scope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let period {
                Label(period, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let link = alert.url.flatMap(URL.init(string:)) {
                Link("More from Caltrain", destination: link)
                    .font(.subheadline.weight(.medium))
                    .tint(Color.caltrainRed)
            }
        }
        .padding(.vertical, 4)
    }

    /// What it affects, as plainly as the feed says it.
    private var scope: String? {
        var parts: [String] = []
        if !alert.trains.isEmpty {
            parts.append((alert.trains.count == 1 ? "Train " : "Trains ") + alert.trains.map { "#\($0)" }.joined(separator: ", "))
        }
        if !alert.stations.isEmpty { parts.append(alert.stations.joined(separator: ", ")) }
        if !alert.lines.isEmpty { parts.append(alert.lines.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The window in force now, or the next one: "Until Sat 6:00 PM".
    private var period: String? {
        let now = Date()
        guard let current = alert.periods.first(where: { ($0.end ?? .distantFuture) > now }) else { return nil }
        let format = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        switch (current.start, current.end) {
        case let (start?, end?) where start > now:
            return "\(start.formatted(format)) – \(end.formatted(format))"
        case let (start?, nil) where start > now:
            return "From \(start.formatted(format))"
        case let (_, end?):
            return "Until \(end.formatted(format))"
        default:
            return nil
        }
    }
}

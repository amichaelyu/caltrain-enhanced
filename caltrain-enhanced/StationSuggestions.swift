//
//  StationSuggestions.swift
//  caltrain-enhanced
//
//  Autocomplete list that drops in under the editable station name in the header.
//

import SwiftUI
import CoreLocation

struct StationSuggestions: View {
    let matches: [StationMatch]
    let activeName: String?
    let nearestName: String?
    let onSelect: (CaltrainStation) -> Void

    /// A dropdown, not a browser — enough rows to choose from without a nested scroll.
    private static let maxRows = 6

    private var visible: [StationMatch] { Array(matches.prefix(Self.maxRows)) }

    var body: some View {
        VStack(spacing: 0) {
            if visible.isEmpty {
                Text("No matching station")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, match in
                    Button { onSelect(match.station) } label: {
                        row(match, isTop: index == 0)
                    }
                    .buttonStyle(.plain)

                    if index != visible.count - 1 { divider }
                }
            }
        }
        .cardBackground()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row(_ match: StationMatch, isTop: Bool) -> some View {
        let isNearest = match.station.name == nearestName

        return HStack(spacing: 12) {
            Image(systemName: isNearest ? "location.fill" : "tram.fill")
                .font(.system(size: 12))
                .foregroundStyle(isNearest ? Color.caltrainRed : .secondary)
                .frame(width: 20)

            // The best match is the one Return commits, so it carries the weight.
            Text(match.station.name)
                .font(.system(size: 17, weight: isTop ? .semibold : .regular, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            if let meters = match.metersAway {
                Text(StationSearch.distanceLabel(meters))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if match.station.name == activeName {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.caltrainRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

//
//  StationSearch.swift
//  caltrain-enhanced
//
//  Type-to-search over the station list, backing the editable station name in the
//  header. Ranks best-match-first so the top suggestion is always the obvious choice.
//

import Foundation
import CoreLocation

/// A station scored against a typed query. Lower `rank` is a better match; ties break
/// on distance, so "san" surfaces the closest San-something first.
struct StationMatch: Identifiable {
    let station: CaltrainStation
    let rank: Int
    let metersAway: CLLocationDistance?

    var id: String { station.name }
}

enum StationSearch {
    /// Nicknames and spellings riders type that don't appear in the official names.
    private static let aliases: [String: [String]] = [
        "San Francisco": ["sf", "san fran", "frisco", "fourth and king", "4th and king"],
        "22nd Street": ["22nd", "twenty second"],
        "S. San Francisco": ["south san francisco", "south sf", "ssf"],
        "Millbrae": ["sfo", "airport", "bart"],
        "Redwood City": ["rwc"],
        "Palo Alto": ["pa", "stanford", "university ave"],
        "California Avenue": ["cal ave", "california ave"],
        "Mountain View": ["mv"],
        "San Jose Diridon": ["sj", "san jose", "diridon", "downtown san jose"],
        "College Park": ["scu"],
        "Santa Clara": ["scu", "levis"],
    ]

    /// Case- and punctuation-insensitive: "S. San Francisco" indexes as "s san francisco".
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Every station, nearest first when the user's location is known.
    static func allStations(from userLocation: CLLocation?) -> [StationMatch] {
        let all = CaltrainStations.shared.stations.map {
            StationMatch(station: $0, rank: 0, metersAway: userLocation?.distance(from: $0.location))
        }
        guard userLocation != nil else { return all }   // otherwise keep north-to-south order
        return all.sorted { ($0.metersAway ?? .greatestFiniteMagnitude) < ($1.metersAway ?? .greatestFiniteMagnitude) }
    }

    static func matches(for query: String, from userLocation: CLLocation?) -> [StationMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allStations(from: userLocation) }

        let needle = normalize(trimmed)
        let found = CaltrainStations.shared.stations.compactMap { station -> StationMatch? in
            guard let rank = rank(station: station, needle: needle) else { return nil }
            return StationMatch(station: station, rank: rank,
                                metersAway: userLocation?.distance(from: station.location))
        }

        return found.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let l = lhs.metersAway ?? .greatestFiniteMagnitude
            let r = rhs.metersAway ?? .greatestFiniteMagnitude
            if l != r { return l < r }
            return lhs.station.name < rhs.station.name
        }
    }

    private static func rank(station: CaltrainStation, needle: String) -> Int? {
        let name = normalize(station.name)
        let words = name.split(separator: " ").map(String.init)

        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if name.contains(needle) { return 3 }

        // Initials: "sjd" -> San Jose Diridon.
        let initials = words.compactMap(\.first).map(String.init).joined()
        if initials.hasPrefix(needle) { return 4 }

        if let alias = aliases[station.name],
           alias.contains(where: { normalize($0).hasPrefix(needle) || needle.hasPrefix(normalize($0)) }) {
            return 5
        }

        // Last resort: the typed letters appear in order ("mtnvw" -> Mountain View).
        if isSubsequence(needle.replacingOccurrences(of: " ", with: ""),
                         of: name.replacingOccurrences(of: " ", with: "")) { return 6 }

        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var remaining = Array(needle)
        for character in haystack where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }

    static func distanceLabel(_ meters: CLLocationDistance) -> String {
        let miles = meters / 1609.344
        return miles < 10 ? String(format: "%.1f mi away", miles) : String(format: "%.0f mi away", miles)
    }
}

//
//  AppIntent.swift
//  widget
//
//  Created by Michael Yu on 6/13/25.
//

import WidgetKit
import AppIntents

struct StationEntity: AppEntity {
    let id: String
    let displayRepresentation: DisplayRepresentation
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Caltrain Station"
    static var defaultQuery = StationQuery()
    
    init(id: String, name: String) {
        self.id = id
        self.displayRepresentation = DisplayRepresentation(title: "\(name)")
    }
}

struct StationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        return caltrainStations.filter { identifiers.contains($0.id) }
    }
    
    func suggestedEntities() async throws -> [StationEntity] {
        return caltrainStations // Show all stations
    }
    
    func defaultResult() async -> StationEntity? {
        return caltrainStations.first { $0.id == "Palo Alto" }
    }
    
    private var caltrainStations: [StationEntity] {
        return [
            StationEntity(id: "San Francisco", name: "San Francisco"),
            StationEntity(id: "22nd Street", name: "22nd Street"),
            StationEntity(id: "Bayshore", name: "Bayshore"),
            StationEntity(id: "S. San Francisco", name: "S. San Francisco"),
            StationEntity(id: "San Bruno", name: "San Bruno"),
            StationEntity(id: "Millbrae", name: "Millbrae"),
            StationEntity(id: "Broadway", name: "Broadway"),
            StationEntity(id: "Burlingame", name: "Burlingame"),
            StationEntity(id: "San Mateo", name: "San Mateo"),
            StationEntity(id: "Hayward Park", name: "Hayward Park"),
            StationEntity(id: "Hillsdale", name: "Hillsdale"),
            StationEntity(id: "Belmont", name: "Belmont"),
            StationEntity(id: "San Carlos", name: "San Carlos"),
            StationEntity(id: "Redwood City", name: "Redwood City"),
            StationEntity(id: "Menlo Park", name: "Menlo Park"),
            StationEntity(id: "Palo Alto", name: "Palo Alto"),
            StationEntity(id: "California Avenue", name: "California Avenue"),
            StationEntity(id: "San Antonio", name: "San Antonio"),
            StationEntity(id: "Mountain View", name: "Mountain View"),
            StationEntity(id: "Sunnyvale", name: "Sunnyvale"),
            StationEntity(id: "Lawrence", name: "Lawrence"),
            StationEntity(id: "Santa Clara", name: "Santa Clara"),
            StationEntity(id: "San Jose Diridon", name: "San Jose Diridon"),
            StationEntity(id: "Tamien", name: "Tamien"),
            StationEntity(id: "Capitol", name: "Capitol"),
            StationEntity(id: "Blossom Hill", name: "Blossom Hill"),
            StationEntity(id: "Morgan Hill", name: "Morgan Hill"),
            StationEntity(id: "San Martin", name: "San Martin"),
            StationEntity(id: "Gilroy", name: "Gilroy")
        ]
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Caltrain Widget" }
    static var description: IntentDescription { "Shows next train departures. Choose different stations for each direction or leave empty to use your current location." }
    
    @Parameter(title: "Northbound Station", description: "Station for northbound trains (leave empty for nearest)")
    var northboundStation: StationEntity?
    
    @Parameter(title: "Southbound Station", description: "Station for southbound trains (leave empty for nearest)")
    var southboundStation: StationEntity?
    
    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$northboundStation
            \.$southboundStation
        }
    }
}

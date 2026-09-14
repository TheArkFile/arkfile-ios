// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// A curated navigation link into ArkFile's authored Survival Guide.
///
/// These values contain navigation copy only. They never synthesize emergency
/// instructions from forecast or alert text.
struct ArkFileWeatherPreparednessLink: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let copy: String
    let sectionID: String
    let blockID: String

    #if os(iOS)
    var survivalGuideTarget: ArkFileSurvivalGuideTarget {
        ArkFileSurvivalGuideTarget(
            sectionID: sectionID,
            blockID: blockID
        )
    }
    #endif
}

enum ArkFileWeatherPreparednessLinks {
    static func links(
        for alert: ArkFileWeatherAlert
    ) -> [ArkFileWeatherPreparednessLink] {
        links(forEventNames: [alert.event])
    }

    static func links(
        for alerts: [ArkFileWeatherAlert]
    ) -> [ArkFileWeatherPreparednessLink] {
        links(forEventNames: alerts.map(\.event))
    }

    static func links(
        forEventName eventName: String
    ) -> [ArkFileWeatherPreparednessLink] {
        links(forEventNames: [eventName])
    }

    static func links(
        forEventNames eventNames: [String]
    ) -> [ArkFileWeatherPreparednessLink] {
        guard !eventNames.isEmpty else { return [] }
        let normalizedEvents = eventNames.map(normalize)
        var detectedCategories = Set<Category>()
        for event in normalizedEvents {
            detectedCategories.formUnion(categories(for: event))
        }

        var result: [ArkFileWeatherPreparednessLink] = []
        for category in Category.hazardOrder
            where detectedCategories.contains(category) {
            result.append(contentsOf: links(for: category))
        }
        if normalizedEvents.contains(where: {
            containsAny($0, ["watch", "warning", "advisory"])
        }) {
            result.append(watchVersusWarning)
        }

        // Every official alert, including an unknown event name, gets the
        // authored communications links. Never infer safety from a missing map.
        result.append(redundantAlerts)
        result.append(rumorControl)
        result.append(noaaWeatherRadio)
        return deduplicated(result)
    }

    private enum Category: Hashable {
        case heat
        case coldOrWinter
        case flood
        case tornadoWindOrHurricane
        case wildfireOrSmoke
        case fireWeatherOrDrought
        case power

        static let hazardOrder: [Self] = [
            .heat,
            .coldOrWinter,
            .flood,
            .tornadoWindOrHurricane,
            .wildfireOrSmoke,
            .fireWeatherOrDrought,
            .power
        ]
    }

    private static func categories(for event: String) -> Set<Category> {
        var result = Set<Category>()
        if containsAny(event, [
            "excessive heat",
            "extreme heat",
            "heat advisory",
            "heat watch",
            "heat warning"
        ]) {
            result.insert(.heat)
        }
        if containsAny(event, [
            "winter",
            "blizzard",
            "snow",
            "ice storm",
            "freezing",
            "freeze",
            "extreme cold",
            "wind chill",
            "sleet"
        ]) {
            result.insert(.coldOrWinter)
        }
        if containsAny(event, [
            "flood",
            "storm surge",
            "tsunami"
        ]) {
            result.insert(.flood)
        }
        if containsAny(event, [
            "tornado",
            "hurricane",
            "tropical storm",
            "severe thunderstorm",
            "extreme wind",
            "high wind",
            "derecho",
            "dust storm"
        ]) {
            result.insert(.tornadoWindOrHurricane)
        }
        if containsAny(event, [
            "wildfire",
            "fire warning",
            "dense smoke",
            "smoke advisory",
            "air quality alert"
        ]) {
            result.insert(.wildfireOrSmoke)
        }
        if containsAny(event, [
            "red flag",
            "fire weather",
            "drought"
        ]) {
            result.insert(.fireWeatherOrDrought)
        }
        if containsAny(event, [
            "power outage",
            "blackout",
            "utility emergency"
        ]) {
            result.insert(.power)
        }
        return result
    }

    private static func links(
        for category: Category
    ) -> [ArkFileWeatherPreparednessLink] {
        switch category {
        case .heat:
            [stayingCool, heatStroke, dehydration]
        case .coldOrWinter:
            [warmRoom, hypothermia, vehicleHazards]
        case .flood:
            [
                hazardActions,
                vehicleHazards,
                sanitationFlood,
                chemicalWater,
                boilWater
            ]
        case .tornadoWindOrHurricane:
            [hazardShelter, hazardActions, homeAndWorkHazards, vehicleHazards]
        case .wildfireOrSmoke:
            [hazardShelter, hazardActions, homeAndWorkHazards, vehicleHazards]
        case .fireWeatherOrDrought:
            [doNotLightFire, hazardActions, homeAndWorkHazards, dehydration]
        case .power:
            [powerPriorities, powerTriage, generatorSafety]
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func containsAny(
        _ value: String,
        _ terms: [String]
    ) -> Bool {
        terms.contains { value.contains($0) }
    }

    private static func deduplicated(
        _ links: [ArkFileWeatherPreparednessLink]
    ) -> [ArkFileWeatherPreparednessLink] {
        var seen = Set<String>()
        return links.filter { seen.insert($0.id).inserted }
    }

    private static let stayingCool = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-shelter-cooling",
        title: "Staying cool",
        copy: "Opens ArkFile's saved cooling checklist.",
        sectionID: "shelter",
        blockID: "shelter-cooling"
    )

    private static let heatStroke = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-medical-heat-stroke",
        title: "Heat illness",
        copy: "Opens the authored heat-stroke section in the Survival Guide.",
        sectionID: "medical",
        blockID: "medical-heat-stroke"
    )

    private static let dehydration = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-water-dehydration",
        title: "Dehydration signs",
        copy: "Opens ArkFile's saved dehydration reference.",
        sectionID: "water",
        blockID: "water-dehydration"
    )

    private static let warmRoom = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-shelter-warm-room",
        title: "Warm-room planning",
        copy: "Opens ArkFile's saved warm-room checklist.",
        sectionID: "shelter",
        blockID: "shelter-warm-room"
    )

    private static let hypothermia = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-medical-hypothermia",
        title: "Cold illness",
        copy: "Opens the authored hypothermia section in the Survival Guide.",
        sectionID: "medical",
        blockID: "medical-hypothermia"
    )

    private static let hazardActions = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-hazards-actions",
        title: "Hazard actions",
        copy: "Opens ArkFile's authored regional-hazard checklist.",
        sectionID: "hazards",
        blockID: "hazards-actions"
    )

    private static let hazardShelter = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-shelter-hazards",
        title: "Shelter by hazard",
        copy: "Opens the saved shelter-by-hazard checklist.",
        sectionID: "shelter",
        blockID: "shelter-hazards"
    )

    private static let homeAndWorkHazards = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-hazards-homework",
        title: "Home and work hazards",
        copy: "Opens ArkFile's authored hazard planning checklist.",
        sectionID: "hazards",
        blockID: "hazards-homework"
    )

    private static let vehicleHazards = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-vehicle-hazards",
        title: "Vehicle hazard rules",
        copy: "Opens ArkFile's authored vehicle-hazard section.",
        sectionID: "vehicle",
        blockID: "vehicle-hazards"
    )

    private static let boilWater = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-water-boil-advisory",
        title: "Water advisory checklist",
        copy: "Opens the saved checklist to use if local officials issue a boil-water advisory.",
        sectionID: "water",
        blockID: "water-boil-advisory"
    )

    private static let chemicalWater = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-water-chemicals",
        title: "Chemical contamination warning",
        copy: "Opens ArkFile's saved warning about treatment limits.",
        sectionID: "water",
        blockID: "water-chemicals"
    )

    private static let sanitationFlood = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-sanitation-flood",
        title: "Floodwater and sewage",
        copy: "Opens ArkFile's authored flood-cleanup health reference.",
        sectionID: "sanitation",
        blockID: "sanitation-flood"
    )

    private static let doNotLightFire = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-fire-do-not",
        title: "Fire restrictions",
        copy: "Opens ArkFile's authored do-not-light-a-fire checklist.",
        sectionID: "fire",
        blockID: "fire-do-not"
    )

    private static let powerPriorities = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-power-priority",
        title: "Power priorities",
        copy: "Opens the saved limited-power priority order.",
        sectionID: "power",
        blockID: "power-priority"
    )

    private static let generatorSafety = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-power-generator",
        title: "Generator safety",
        copy: "Opens ArkFile's authored generator-safety section.",
        sectionID: "power",
        blockID: "power-generator"
    )

    private static let powerTriage = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-power-triage",
        title: "Limited-power triage",
        copy: "Opens ArkFile's saved load-priority checklist.",
        sectionID: "power",
        blockID: "power-triage"
    )

    private static let watchVersusWarning = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-watch-warning",
        title: "Watch vs. warning",
        copy: "Opens ArkFile's saved explanation of official alert terms.",
        sectionID: "hazards",
        blockID: "hazards-watch-warning"
    )

    private static let redundantAlerts = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-comms-alerts",
        title: "Redundant alerts",
        copy: "Opens the saved checklist for multiple official alert sources.",
        sectionID: "communications",
        blockID: "comms-alerts"
    )

    private static let rumorControl = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-comms-rumors",
        title: "Rumor control",
        copy: "Opens ArkFile's saved source-verification checklist.",
        sectionID: "communications",
        blockID: "comms-rumors"
    )

    private static let noaaWeatherRadio = ArkFileWeatherPreparednessLink(
        id: "weather-preparedness-comms-noaa",
        title: "NOAA Weather Radio",
        copy: "Opens ArkFile's saved receiver and SAME setup notes.",
        sectionID: "communications",
        blockID: "comms-noaa"
    )
}

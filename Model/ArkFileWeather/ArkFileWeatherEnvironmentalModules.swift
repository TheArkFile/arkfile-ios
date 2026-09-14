// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileWeatherEnvironmentalModule: String, CaseIterable, Identifiable, Sendable {
    case airQualityAndSmoke
    case riverConditions
    case drought

    var id: String { rawValue }
}

enum ArkFileWeatherEnvironmentalReleaseState: String, Equatable, Sendable {
    case available
    case heldForProviderApproval
}

struct ArkFileWeatherEnvironmentalModuleDescriptor: Equatable, Sendable {
    let module: ArkFileWeatherEnvironmentalModule
    let title: String
    let systemImage: String
    let sourceName: String
    let releaseState: ArkFileWeatherEnvironmentalReleaseState
    let limitation: String
}

enum ArkFileWeatherEnvironmentalModuleRegistry {
    /// A feature flag alone is never sufficient to advertise a module. This
    /// capability remains false until a provider, cache, disclosure, and
    /// module-specific release checks actually ship.
    static func hasProviderCapability(
        for module: ArkFileWeatherEnvironmentalModule
    ) -> Bool {
        switch module {
        case .airQualityAndSmoke, .riverConditions, .drought:
            false
        }
    }

    /// Optional modules are explicit capability gates. A disabled module never
    /// makes a network request and cannot block the NWS core briefing.
    static func descriptor(
        for module: ArkFileWeatherEnvironmentalModule
    ) -> ArkFileWeatherEnvironmentalModuleDescriptor {
        switch module {
        case .airQualityAndSmoke:
            let isAvailable = FeatureFlags.savedWeatherAirQuality
                && hasProviderCapability(for: module)
            return ArkFileWeatherEnvironmentalModuleDescriptor(
                module: module,
                title: "Air Quality & Smoke",
                systemImage: "aqi.medium",
                sourceName: "AirNow / NOAA",
                releaseState: isAvailable
                    ? .available
                    : .heldForProviderApproval,
                limitation: isAvailable
                    ? "AirNow observations are preliminary and may change."
                    : "Held until current AirNow access, endpoint, attribution, and data-quality requirements are approved."
            )
        case .riverConditions:
            let isAvailable = FeatureFlags.savedWeatherRiverGauges
                && hasProviderCapability(for: module)
            return ArkFileWeatherEnvironmentalModuleDescriptor(
                module: module,
                title: "River Conditions",
                systemImage: "water.waves",
                sourceName: "NOAA National Water Prediction Service",
                releaseState: isAvailable
                    ? .available
                    : .heldForProviderApproval,
                limitation: isAvailable
                    ? "A user-selected gauge does not determine whether an exact location is safe."
                    : "Held until explicit gauge selection, threshold semantics, and physical-device coverage checks are complete."
            )
        case .drought:
            let isAvailable = FeatureFlags.savedWeatherDrought
                && hasProviderCapability(for: module)
            return ArkFileWeatherEnvironmentalModuleDescriptor(
                module: module,
                title: "Drought",
                systemImage: "sun.max.trianglebadge.exclamationmark",
                sourceName: "U.S. Drought Monitor",
                releaseState: isAvailable
                    ? .available
                    : .heldForProviderApproval,
                limitation: isAvailable
                    ? "Weekly regional conditions are not today's fire-danger rating."
                    : "Held until a dated regional feed, source-use review, and non-fire-danger wording are verified."
            )
        }
    }

    static var all: [ArkFileWeatherEnvironmentalModuleDescriptor] {
        ArkFileWeatherEnvironmentalModule.allCases.map(descriptor(for:))
    }
}

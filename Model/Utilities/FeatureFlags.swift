// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Foundation

enum FeatureFlags {
#if DEBUG
    static let map: Bool = true
#else
    static let map: Bool = false
#endif
    /// Custom apps, which have a bundled zim file, do not require library access
    /// this will remove all library related features
    static let hasLibrary: Bool = !AppType.isCustom
    static let hasCatalog: Bool = hasLibrary && Config.value(for: .hideKiwixCatalog) != true
    static let opensNativeHomeOnLaunch: Bool = hasLibrary && Config.value(for: .hideKiwixCatalog) == true
    static let arkFileUnifiedAccountUI: Bool = false
    /// ArkFile's free, opt-in, last-saved weather briefing. Keep this scoped to
    /// the ArkFile native home instead of exposing it in upstream/custom apps.
    static let savedWeather: Bool = opensNativeHomeOnLaunch
    /// Provider- and policy-dependent additions remain independently gated so
    /// core NWS forecast/alert availability never depends on them.
    static let savedWeatherClimateOutlooks: Bool = savedWeather
    static let savedWeatherAirQuality: Bool = false
    static let savedWeatherRiverGauges: Bool = false
    static let savedWeatherDrought: Bool = false

    static let showExternalLinkOptionInSettings: Bool = Config.value(for: .showExternalLinkSettings) ?? true
    static let showSearchSnippetInSettings: Bool = Config.value(for: .showSearchSnippetInSettings) ?? true
    
    static let suggestSearchTerms: Bool = Config.value(for: .showSearchSuggestionsSpellChecked) ?? false
}

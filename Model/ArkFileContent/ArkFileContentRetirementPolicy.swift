// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileContentRetirementPolicy {
    static let userFacingStatus = "No longer distributed by ArkFile"
    static let retainedDeletionWarning = "ArkFile no longer distributes this title. It remains readable on this device unless you remove it. If you remove it, ArkFile cannot download it again."

    struct Record: Equatable, Sendable {
        let relativePath: String
        let sha256: String
    }

    static let records: [Record] = [
        Record(relativePath: "general/survival/FM 21-76 - Survival Manual (2002).pdf", sha256: "76905fc16b14b2a57eb646adb6f3c238dcfb161d66ff1103a2a7b702e20e0f32"),
        Record(relativePath: "general/survival/TC 31-34-4 Special Forces - Tracking and Countertracking (2009).pdf", sha256: "23fe57dd4f6aebb7f24b5a766c5fdea60dd068fcbd504fe8235f99ccc50ae2a9"),
        Record(relativePath: "medical/reference/FM 4-02-283 - Treatment of Nuclear and Radiological Casualties (2001).pdf", sha256: "3608b59a8caafd90e2080c7c4969c7edf68e55aeafd9018bff40d8b90087301e"),
        Record(relativePath: "general/survival/AF Reg 64-4 SAR Survival Training (1985).pdf", sha256: "65cdfd021919245b310b96087be94f0312f13d4000874878d163ecc4eb821766"),
        Record(relativePath: "food-preparation/food/USDA - Chicken from Farm to Table.pdf", sha256: "a7677cc210f1b4b73f394370f2edef83fc185765ae4af96b1ecc7c43c2274941"),
        Record(relativePath: "food-preparation/food/USDA - Duck and Goose from Farm to Table.pdf", sha256: "8b3706362e883e68e27d3f581aefa9ac5c1908590eeb2b6d553eba80db6423a0"),
        Record(relativePath: "food-preparation/food/USDA - Fresh Pork from Farm to Table.pdf", sha256: "f309349d3807ee3fe521657413e2fa21f128fa58219de7ac1061d70e5800a494"),
        Record(relativePath: "food-preparation/food/USDA - Game_from_Farm_to_Table.pdf", sha256: "9cedc5c684d88da28b013afc746f92cc078a4006d4356e2433a08a40ce38f6f6"),
        Record(relativePath: "food-preparation/food/USDA - Lamb from Farm to Table.pdf", sha256: "cfd5543b38b66fa90e278730423c18aa0d1197965bb09d4ab19603f832879ac7"),
        Record(relativePath: "food-preparation/food/USDA - Turkey from Farm to Table.pdf", sha256: "434405a9d894175599a698eb9c661d51c97e5f2a5d84f41c003cb7e91603b9cd"),
        Record(relativePath: "general/survival/FEMA - 72-hour-nuclear-detonation-response-guidance (2023).pdf", sha256: "e312a9e0c64b8e4cda0c12677695744abd254cfbdc45c10b14d290a7e7c1ee1f"),
        Record(relativePath: "general/survival/NatSec - PlanningGuidanceNuclearDetonation (2010).pdf", sha256: "6b1bbeeb8f9b9a531a28834258d3b597f4b841d28eae59b33b902010573e2115"),
        Record(relativePath: "medical/field-guides/Emergency Healthcare - Family Guide.pdf", sha256: "6a5eeeee26cc14fe7a0eb167d68c4ddebcae75e235dd83542b2af3dcba925ed2")
    ]

    private static let retiredPaths = Set(records.map { $0.relativePath.lowercased() })

    static func isRetired(relativePath: String) -> Bool {
        guard let normalized = normalizedRelativePath(relativePath) else { return false }
        return retiredPaths.contains(normalized.lowercased())
    }

    private static func normalizedRelativePath(_ value: String) -> String? {
        let raw = value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !raw.isEmpty,
              !segments.isEmpty,
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return segments.joined(separator: "/")
    }

}

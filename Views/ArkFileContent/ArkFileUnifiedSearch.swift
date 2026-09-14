// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import SwiftUI

extension Notification.Name {
    static let arkFileOpenGuideSection = Notification.Name("arkFileOpenGuideSection")
    static let arkFileOpenToolkitView = Notification.Name("arkFileOpenToolkitView")
    static let arkFileOpenLibraryItem = Notification.Name("arkFileOpenLibraryItem")
}

/// Matches a search query against everything ArkFile knows beyond ZIM full-text:
/// survival guide sections, preparedness calculators, and library title names.
/// ZIM full-text results continue to come from the Kiwix search pipeline; these
/// results render above them so one search box covers the whole app.
@MainActor
enum ArkFileUnifiedSearchProvider {
    struct ToolMatch: Identifiable, Equatable {
        let id: String
        let title: String
        let systemImage: String
    }

    struct Matches {
        let guideSections: [ArkFileGuideSearchMatch]
        let tools: [ToolMatch]
        let libraryItems: [ArkFileLibraryContentItem]

        var isEmpty: Bool {
            guideSections.isEmpty && tools.isEmpty && libraryItems.isEmpty
        }
    }

    private static let bundledCatalog = try? ArkFileContentCatalog.loadBundled()

    private static let toolCatalog: [(id: String, title: String, systemImage: String, keywords: [String])] = [
        (
            id: "water",
            title: "Water & Bleach Calculator",
            systemImage: "drop",
            keywords: ["water", "bleach", "disinfect", "purify", "purification", "gallon", "rain", "rainwater", "drink"]
        ),
        (
            id: "plan",
            title: "Household Supply Calculator",
            systemImage: "list.clipboard",
            keywords: ["food", "calorie", "supply", "supplies", "household", "freezer", "fridge", "refrigerator", "outage", "storage"]
        ),
        (
            id: "power",
            title: "Power & Generator Calculator",
            systemImage: "bolt.batteryblock",
            keywords: ["power", "battery", "batteries", "generator", "fuel", "watt", "charge", "electricity", "solar"]
        ),
        (
            id: "evacuation",
            title: "Evacuation Range Calculator",
            systemImage: "figure.walk",
            keywords: ["evacuation", "evacuate", "vehicle", "gas", "mpg", "walk", "walking", "range", "travel", "drive"]
        ),
        (
            id: "lists",
            title: "Preparedness Checklists",
            systemImage: "checklist",
            keywords: ["checklist", "kit", "go-bag", "gobag", "72 hour", "supplies", "evacuation kit"]
        )
    ]

    static func matches(for query: String) -> Matches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 2 else {
            return Matches(guideSections: [], tools: [], libraryItems: [])
        }
        let guideSections = ArkFileSurvivalGuideSearch.matches(for: trimmed)
        let tools = toolCatalog
            .filter { tool in
                tool.keywords.contains { keyword in
                    keyword.hasPrefix(trimmed) || trimmed.contains(keyword)
                }
            }
            .map { ToolMatch(id: $0.id, title: $0.title, systemImage: $0.systemImage) }
        let library = ArkFileLocalContentLibrary.shared
        let categories = ArkFileContentDisplayLibrarySection.completeCatalogBackedCategories(
            installedCategories: library.categories,
            fallbackCategories: library.libraryCategories,
            catalog: bundledCatalog
        )
        let libraryItems = ArkFileLibraryDiscovery.matchingItems(
            categories.flatMap(\.items), query: trimmed
        )
        return Matches(guideSections: guideSections, tools: tools, libraryItems: libraryItems)
    }
}

/// Renders unified ArkFile matches above the ZIM full-text results inside the
/// Kiwix search experience. Taps post notifications handled by the active tab.
struct ArkFileSearchResultsSection: View {
    let matches: ArkFileUnifiedSearchProvider.Matches
    var showsArticlesHeading = true
    @ObservedObject private var installer = ArkFileContentPackInstaller.shared
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !matches.guideSections.isEmpty {
                sectionLabel("Survival Guide")
                ForEach(matches.guideSections) { match in
                    row(systemImage: match.systemImage, title: match.title, subtitle: "Survival Guide section") {
                        NotificationCenter.default.post(
                            name: .arkFileOpenGuideSection,
                            object: nil,
                            userInfo: ["sectionID": match.id]
                        )
                    }
                }
            }
            if !matches.tools.isEmpty {
                sectionLabel("Preparedness Tools")
                ForEach(matches.tools) { tool in
                    row(systemImage: tool.systemImage, title: tool.title, subtitle: "Offline calculator") {
                        NotificationCenter.default.post(
                            name: .arkFileOpenToolkitView,
                            object: nil,
                            userInfo: ["view": tool.id]
                        )
                    }
                }
            }
            if !matches.libraryItems.isEmpty {
                sectionLabel("Titles & Maps")
                ForEach(matches.libraryItems) { item in
                    row(
                        systemImage: item.type.systemImage,
                        title: ArkFileLibraryDiscovery.displayName(for: item),
                        subtitle: presentation(for: item).statusTitle
                    ) {
                        NotificationCenter.default.post(
                            name: item.type == .map ? .arkFileOpenMapRegion
                                : item.isInstalled || item.isSampleContent ? .arkFileOpenLibraryItem : .arkFileOpenContentDownloads,
                            object: nil,
                            userInfo: ["relativePath": item.relativePath, "showDownloads": true]
                        )
                    }
                }
            }
            if showsArticlesHeading && !matches.isEmpty {
                sectionLabel("Articles in downloaded content")
            }
        }
        .padding(.horizontal, 12)
    }

    private func presentation(for item: ArkFileLibraryContentItem) -> ArkFileLockedContentPresentation {
        ArkFileLockedContentPresentation.resolve(
            item: item,
            input: ArkFileLockedContentResolutionInput(
                installer: installer,
                hasAuthoritativeNoPurchase: installer.hasAuthoritativeNoPurchase,
                hasEssentialsAccess: installer.hasSavedLiteAccess || Brand.hasDeveloperContentAuthToken,
                essentialsInstallNeedsRepair: false,
                completeInstallNeedsRepair: false
            )
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    private func row(
        systemImage: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            dismissSearch()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 30, height: 30)
                    .background(Color.arkPrimary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.arkAppSurface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}
#endif

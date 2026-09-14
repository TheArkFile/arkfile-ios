// This file is part of ArkFile and is licensed under GPL-3.0-or-later.

#if os(iOS)
import SwiftUI

/// The native menu scrolls independently of Home and dismisses without moving
/// the category cards. Home owns filtering and the existing reader/detail route.
struct ArkFileHomeCategoryMenu: View {
    let section: ArkFileContentDisplayLibrarySection
    let items: [ArkFileLibraryContentItem]
    let resolutionInput: ArkFileLockedContentResolutionInput
    let onOpen: (ArkFileLibraryContentItem) -> Void

    private struct PresentedItem: Identifiable {
        let item: ArkFileLibraryContentItem
        let presentation: ArkFileLockedContentPresentation

        var id: String { item.id }

        var group: AvailabilityGroup {
            switch presentation.accessState {
            case .sample, .installed: .readyOffline
            case .downloadable: .available
            case .locked:
                presentation.resolvedTier == .complete ? .requiresComplete : .requiresEssentials
            }
        }
    }

    private enum AvailabilityGroup: String, CaseIterable, Identifiable {
        case readyOffline
        case available
        case requiresEssentials
        case requiresComplete

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readyOffline: "Ready offline"
            case .available: "Available to download"
            case .requiresEssentials: "Requires Essentials"
            case .requiresComplete: "Requires Complete"
            }
        }
    }

    var body: some View {
        let presentedItems = items.map {
            PresentedItem(item: $0, presentation: .resolve(item: $0, input: resolutionInput))
        }
        let summary = countSummary(presentedItems)
        Menu {
            ForEach(AvailabilityGroup.allCases) { group in
                let groupItems = presentedItems.filter { $0.group == group }
                if !groupItems.isEmpty {
                    Section(group.title) {
                        ForEach(groupItems) { presented in
                            Button {
                                onOpen(presented.item)
                            } label: {
                                Label(
                                    ArkFileLibraryDiscovery.displayName(for: presented.item),
                                    systemImage: presented.presentation.statusSystemImage
                                )
                            }
                            .accessibilityValue(presented.presentation.statusTitle)
                            .accessibilityIdentifier("arkfile_home_title_\(presented.id)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.group.systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 36, height: 36)
                    .background(Color.arkPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.group.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.arkInteractiveForeground)
            }
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(Color.arkAppSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.arkAppBorder, lineWidth: 1)
            }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .tint(Color.arkInteractiveForeground)
        .accessibilityLabel(section.group.displayName)
        .accessibilityValue(summary)
        .accessibilityHint("Choose a title. Downloaded titles open directly; other titles show details and download options.")
        .accessibilityIdentifier("arkfile_home_category_\(section.group.id)")
    }

    private func countSummary(_ presentedItems: [PresentedItem]) -> String {
        let ready = presentedItems.filter { $0.group == .readyOffline }.count
        let available = presentedItems.filter { $0.group == .available }.count
        let locked = presentedItems.count - ready - available
        var parts: [String] = []
        if ready > 0 { parts.append("\(ready) ready offline") }
        if available > 0 { parts.append("\(available) available") }
        if locked > 0 { parts.append("\(locked) locked") }
        return parts.isEmpty ? "No matching titles" : parts.joined(separator: " · ")
    }
}
#endif

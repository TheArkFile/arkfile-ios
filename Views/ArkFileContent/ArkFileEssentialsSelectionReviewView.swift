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

enum ArkFilePackSelectionPurpose: Equatable, Sendable {
    case purchase
    case upgradeFromEssentials
    case downloadOwnedPack
    case manageDownloads
}

struct ArkFilePackSelectionResult: Equatable, Sendable {
    let excludedItemKeys: Set<String>
    let selectedMissingItemKeys: Set<String>
}

/// Purchase review and post-purchase download manager with live title counts
/// and storage totals. Installed titles are informational and never removed
/// from this screen.
struct ArkFileEssentialsSelectionReviewView: View {
    let tier: ArkFileContentTier
    let confirmTitle: String
    let managementMode: Bool
    let purpose: ArkFilePackSelectionPurpose
    let initiallyExcluded: Set<String>?
    let startsWithSavedSelection: Bool
    let onConfirm: (ArkFilePackSelectionResult) -> Void
    let onCancel: () -> Void

    private struct SelectableItem: Identifiable, Hashable {
        let id: String
        let name: String
        let displayGroup: ArkFileContentDisplayGroup
        let subcategory: String
        let sizeBytes: Int64
        let type: ArkFileLocalContentType
        let isAlreadyInEssentials: Bool
        let isInstalled: Bool
        let variantGroup: String?
        let variantLabel: String?
        let variantDefault: Bool
        let summary: String?
    }

    private struct DisplayGroupSection: Identifiable {
        let group: ArkFileContentDisplayGroup
        let items: [SelectableItem]

        var id: String { group.id }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
        var addedWithCompleteItems: [SelectableItem] {
            items.filter { !$0.isAlreadyInEssentials }
        }
        var alreadyInEssentialsItems: [SelectableItem] {
            items.filter(\.isAlreadyInEssentials)
        }
    }

    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared
    @State private var catalogSelectableItems: [SelectableItem] = []
    @State private var groups: [DisplayGroupSection] = []
    @State private var excludedKeys: Set<String> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedAlreadyInEssentialsIDs: Set<String> = []
    @State private var expandedSummaryItemID: String?
    @State private var completeOwnershipMetrics = ArkFileCompleteOwnershipMetrics.empty
    @State private var availableBytes: Int64?
    @State private var didLoad = false
    @State private var searchText = ""
    @State private var isDownloadDetailsExpanded = false
    @State private var previewTask: Task<Void, Never>?
    @State private var isPreparingDownload = false
    @State private var pendingReviewedSelection: ArkFilePackSelectionResult?
    @State private var previewMessage = ""
    @State private var previewGeneration = UUID()
    @State private var previewError: String?
    @State private var showsWikipediaOptions = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var allItems: [SelectableItem] {
        catalogSelectableItems
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleGroups: [DisplayGroupSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.items.filter { item in
                item.name.localizedCaseInsensitiveContains(query)
                    || item.subcategory.localizedCaseInsensitiveContains(query)
                    || (item.summary?.localizedCaseInsensitiveContains(query) == true)
            }
            guard !matches.isEmpty else { return nil }
            return DisplayGroupSection(group: group.group, items: matches)
        }
    }

    private var selectedItems: [SelectableItem] {
        allItems.filter { !excludedKeys.contains($0.id) }
    }

    /// Items the confirm action will actually download. Titles already on the
    /// device stay part of the selection but cost nothing, so every count and
    /// storage number the user sees reflects only new downloads.
    private var itemsToDownload: [SelectableItem] {
        selectedItems.filter { !$0.isInstalled }
    }

    private var bytesToDownload: Int64 {
        itemsToDownload.reduce(0) { $0 + $1.sizeBytes }
    }

    private var packName: String {
        switch tier {
        case .complete:
            "Complete"
        case .lite:
            "Essentials"
        case .standard:
            "ArkFile"
        }
    }

    init(
        tier: ArkFileContentTier = .lite,
        confirmTitle: String,
        managementMode: Bool = false,
        purpose: ArkFilePackSelectionPurpose? = nil,
        initiallyExcluded: Set<String>?,
        startsWithSavedSelection: Bool = false,
        onConfirm: @escaping (ArkFilePackSelectionResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.tier = tier
        self.confirmTitle = confirmTitle
        self.managementMode = managementMode
        self.purpose = purpose ?? (managementMode ? .manageDownloads : .purchase)
        self.initiallyExcluded = initiallyExcluded
        self.startsWithSavedSelection = startsWithSavedSelection
        _showsWikipediaOptions = State(initialValue: startsWithSavedSelection)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var requiredAvailableBytes: Int64 {
        storageEstimate.requiredAvailableBytes
    }

    private var storageEstimate: ArkFileContentStorageEstimate {
        ArkFileContentStoragePreflight.storageEstimate(
            contentBytes: bytesToDownload,
            maximumTransientBytes: ArkFileContentBackgroundDownloadService.maximumTransientDownloadBytes,
            availableBytes: availableBytes
        )
    }

    private var hasInsufficientReportedStorage: Bool {
        storageEstimate.hasEnoughReportedStorage == false
    }

    private var canConfirmSelection: Bool {
        guard !isPreparingDownload else { return false }
        if itemsToDownload.isEmpty {
            return allowsPurchaseWithoutDownload
        }
        return !hasInsufficientReportedStorage
    }

    private var allowsPurchaseWithoutDownload: Bool {
        purpose == .purchase || purpose == .upgradeFromEssentials
    }

    private var installedSelectedTitleCount: Int {
        allItems.filter { $0.isInstalled && $0.type != .map }.count
    }

    private var installedSelectedMapCount: Int {
        allItems.filter { $0.isInstalled && $0.type == .map }.count
    }

    private var storageLine: (text: String, isWarning: Bool)? {
        guard let availableBytes, bytesToDownload > 0 else { return nil }
        let required = requiredAvailableBytes
        let availableText = Self.byteFormatter.string(fromByteCount: availableBytes)
        let requiredText = Self.byteFormatter.string(fromByteCount: required)
        let downloadText = Self.byteFormatter.string(fromByteCount: bytesToDownload)
        if availableBytes >= required {
            return ("This device has \(availableText) free. The selected downloads total \(downloadText) and need about \(requiredText) during installation, including temporary working space.", false)
        }
        return ("This device has only \(availableText) free. The selected downloads total \(downloadText) and need about \(requiredText) during installation. Deselect some items or free up space.", true)
    }

    var body: some View {
        List {
            if !isSearching {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reviewIntro)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(
                            "Use Wi-Fi, plug in your device, and keep ArkFile open for the most reliable download.",
                            systemImage: "wifi"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)

                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }

                Section {
                    downloadDetailsDisclosure
                }
            }

            if tier == .complete, !isSearching || !matchingWikipediaItems.isEmpty {
                completeChoicesSection
            }

            if isSearching, visibleGroups.isEmpty, matchingWikipediaItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }

            ForEach(visibleGroups) { group in
                Section {
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expandedGroupIDs.contains(group.id) {
                        if tier == .complete {
                            completeGroupRows(group)
                        } else {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        }
                    }
                } header: {
                    categoryHeader(group)
                }
                .id("catalog-group-\(group.id)")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search titles"
        )
        .navigationTitle(managementMode ? "Add Downloads" : "Review \(packName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    previewTask?.cancel()
                    onCancel()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .onDisappear { previewTask?.cancel() }
        .onChange(of: excludedKeys) { _, _ in
            previewGeneration = UUID()
            previewTask?.cancel()
            isPreparingDownload = false
            pendingReviewedSelection = nil
        }
        .alert("Download selected content?", isPresented: Binding(
            get: { pendingReviewedSelection != nil },
            set: { if !$0 { pendingReviewedSelection = nil } }
        )) {
            Button("Download") {
                guard let selection = pendingReviewedSelection else { return }
                pendingReviewedSelection = nil
                onConfirm(selection)
            }
            Button("Not Now", role: .cancel) { pendingReviewedSelection = nil }
        } message: {
            Text(previewMessage)
        }
        .alert("Couldn’t check download size", isPresented: Binding(
            get: { previewError != nil }, set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "Please try again when connected.")
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await contentLibrary.refresh()
            loadCatalog()
            availableBytes = await Task.detached(priority: .utility) {
                try? ArkFileContentStoragePreflight.availableCapacityForDownload()
            }.value ?? nil
        }
    }

    private var matchingWikipediaItems: [SelectableItem] {
        guard isSearching else { return wikipediaItems }
        return wikipediaItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.subcategory.localizedCaseInsensitiveContains(searchText)
                || ($0.summary?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var completeChoicesSection: some View {
        Section("Optional Full Wikipedia") {
            if isSearching {
                ForEach(matchingWikipediaItems) { item in itemRow(item) }
            } else {
                DisclosureGroup(isExpanded: $showsWikipediaOptions) {
                    ForEach(wikipediaItems) { item in itemRow(item) }
                    Text("Choose one edition, or add it later. Both are included with Complete.")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Full Wikipedia", systemImage: "globe")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("arkfile_complete_wikipedia_choices")
                        Text(wikipediaChoiceSummary)
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Color.arkInteractiveForeground)
            }
        }
    }

    private var wikipediaItems: [SelectableItem] {
        ArkFilePackSelectionPresentation.dedicatedVariantItems(
            from: allItems,
            variantGroup: \.variantGroup
        )
    }

    private var wikipediaSelectedItems: [SelectableItem] {
        wikipediaItems.filter { !excludedKeys.contains($0.id) }
    }

    private var wikipediaChoiceSummary: String {
        if let selected = wikipediaSelectedItems.first {
            return "\(selected.variantLabel ?? selected.name) selected · \(Self.byteFormatter.string(fromByteCount: selected.sizeBytes)). Only one full-Wikipedia option can be selected."
        }
        let options = wikipediaItems.map {
            "\($0.variantLabel ?? $0.name) \(Self.byteFormatter.string(fromByteCount: $0.sizeBytes))"
        }
        return "None selected. Choose one if wanted: \(options.joined(separator: " or "))."
    }

    private var regionalMapItems: [SelectableItem] {
        allItems.filter { $0.type == .map && !$0.isAlreadyInEssentials }
    }

    private var selectedRegionalMapItems: [SelectableItem] {
        regionalMapItems.filter { !excludedKeys.contains($0.id) }
    }

    @ViewBuilder
    private func completeGroupRows(_ group: DisplayGroupSection) -> some View {
        if managementMode {
            managementGroupRows(group)
        } else {
            purchaseReviewGroupRows(group)
        }
    }

    @ViewBuilder
    private func managementGroupRows(_ group: DisplayGroupSection) -> some View {
        let missing = ArkFileManagedDownloadPresentation.missingItems(
            from: group.items,
            isInstalled: \.isInstalled
        )
        let installed = ArkFileManagedDownloadPresentation.installedItems(
            from: group.items,
            isInstalled: \.isInstalled
        )

        if !missing.isEmpty {
            subgroupLabel(
                title: ArkFileManagedDownloadPresentation.selectionGroupTitle,
                systemImage: "arrow.down.circle",
                items: missing,
                isProminent: true
            )
            .id("choose-downloads-\(group.id)")
            ForEach(missing) { item in
                itemRow(item)
            }
        }
        if !installed.isEmpty {
            subgroupLabel(
                title: ArkFileManagedDownloadPresentation.installedGroupTitle,
                systemImage: "checkmark.circle.fill",
                items: installed,
                isProminent: false
            )
            .id("installed-downloads-\(group.id)")
            ForEach(installed) { item in
                itemRow(item)
            }
        }
    }

    @ViewBuilder
    private func purchaseReviewGroupRows(_ group: DisplayGroupSection) -> some View {
        let addedItems = group.addedWithCompleteItems
        let alreadyItems = group.alreadyInEssentialsItems
        if !addedItems.isEmpty {
            subgroupLabel(
                title: "Added with Complete",
                systemImage: "plus.circle.fill",
                items: addedItems,
                isProminent: true
            )
            ForEach(addedItems) { item in
                itemRow(item)
            }
        }
        if !alreadyItems.isEmpty {
            Button {
                if expandedAlreadyInEssentialsIDs.contains(group.id) {
                    expandedAlreadyInEssentialsIDs.remove(group.id)
                } else {
                    expandedAlreadyInEssentialsIDs.insert(group.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedAlreadyInEssentialsIDs.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    subgroupLabel(
                        title: "Included with Essentials",
                        systemImage: "checkmark.seal",
                        items: alreadyItems,
                        isProminent: false
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedAlreadyInEssentialsIDs.contains(group.id) {
                ForEach(alreadyItems) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func subgroupLabel(
        title: String,
        systemImage: String,
        items: [SelectableItem],
        isProminent: Bool
    ) -> some View {
        let downloadable = items.filter { !$0.isInstalled }
        let summary = ArkFileContentDisplaySectionSummary.selection(
            items: downloadable,
            excludedKeys: excludedKeys,
            key: \.id,
            sizeBytes: \.sizeBytes
        )
        let installedCount = items.count - downloadable.count
        let detail: String
        if downloadable.isEmpty {
            detail = "\(installedCount) on this device"
        } else if summary.selectedCount == 0 {
            detail = installedCount > 0
                ? "Nothing selected · \(installedCount) on this device"
                : "Nothing selected"
        } else if installedCount > 0 {
            let selected = summary.selectedCount == summary.totalCount
                ? "\(summary.selectedCount) selected"
                : "\(summary.selectedCount) of \(summary.totalCount) selected"
            detail = "\(selected) · \(Self.byteFormatter.string(fromByteCount: summary.selectedBytes)) · \(installedCount) on this device"
        } else {
            let selected = summary.selectedCount == summary.totalCount
                ? "\(summary.selectedCount) selected"
                : "\(summary.selectedCount) of \(summary.totalCount) selected"
            detail = "\(selected) · \(Self.byteFormatter.string(fromByteCount: summary.selectedBytes))"
        }
        return HStack {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .fontWeight(isProminent ? .bold : .semibold)
                .foregroundStyle(isProminent ? Color.arkPrimary : Color.arkTextMuted)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.arkTextMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SelectableItem) -> some View {
        let isSelected = !excludedKeys.contains(item.id)
        // Titles already on this device are part of the pack no matter what;
        // showing them as toggleable only invites "should I deselect these?"
        // confusion. They render as a quiet installed row instead.
        if item.isInstalled {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.arkPrimaryHover)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .lineLimit(2)
                        Text("On this device")
                            .font(.caption2)
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    Spacer(minLength: 8)
                    Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.arkTextMuted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), already on this device")
                .accessibilityIdentifier(itemAccessibilityIdentifier(for: item))
                if let summary = item.summary, !summary.isEmpty {
                    titleSummaryDisclosure(item: item, summary: summary)
                }
            }
            .id("installed-\(item.id)")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if let variantGroup = item.variantGroup {
                        excludedKeys = toggledVariantExclusions(
                            selecting: isSelected ? nil : item.id,
                            variantGroup: variantGroup
                        )
                    } else if isSelected {
                        excludedKeys.insert(item.id)
                    } else {
                        excludedKeys.remove(item.id)
                    }
                    excludedKeys = enforceExclusiveVariantSelections(excludedKeys)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : item.variantGroup == nil ? "circle" : "circle.dashed")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.arkPrimary : Color.arkTextMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                                .foregroundStyle(Color.arkTextPrimary)
                                .lineLimit(2)
                            Text(itemSubtitle(for: item))
                                .font(.caption2)
                                .foregroundStyle(Color.arkTextMuted)
                        }
                        Spacer(minLength: 8)
                        Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(Self.byteFormatter.string(fromByteCount: item.sizeBytes))")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityIdentifier(itemAccessibilityIdentifier(for: item))

                if let summary = item.summary, !summary.isEmpty {
                    titleSummaryDisclosure(item: item, summary: summary)
                }
            }
            .id("download-\(item.id)")
        }
    }

    private func titleSummaryDisclosure(item: SelectableItem, summary: String) -> some View {
        ArkFileTitleSummaryDisclosure(
            title: item.name,
            summary: summary,
            isExpanded: expandedSummaryItemID == item.id
        ) {
            expandedSummaryItemID = ArkFileTitleSummaryDisclosureState.nextExpandedItemID(
                current: expandedSummaryItemID,
                tapped: item.id
            )
        }
    }

    private func categoryHeader(_ group: DisplayGroupSection) -> some View {
        let downloadableItems = group.items.filter { !$0.isInstalled }
        let selectedInstalledVariantGroups = Set(
            group.items.compactMap { item -> String? in
                guard item.isInstalled,
                      !excludedKeys.contains(item.id) else {
                    return nil
                }
                return item.variantGroup
            }
        )
        let batchSelectableItems = downloadableItems.filter { item in
            guard let variantGroup = item.variantGroup else { return true }
            return !selectedInstalledVariantGroups.contains(variantGroup)
        }
        let summary = ArkFileContentDisplaySectionSummary.selection(
            items: downloadableItems,
            excludedKeys: excludedKeys,
            key: \.id,
            sizeBytes: \.sizeBytes
        )
        let summarySlotMetrics = ArkFileSelectableSlotMetrics.make(
            items: downloadableItems,
            excludedKeys: excludedKeys,
            key: \.id,
            variantGroup: \.variantGroup
        )
        let batchSlotMetrics = ArkFileSelectableSlotMetrics.make(
            items: batchSelectableItems,
            excludedKeys: excludedKeys,
            key: \.id,
            variantGroup: \.variantGroup
        )
        let allSelected = batchSlotMetrics.allSlotsSelected
        let managementMetrics = ArkFileManagedDownloadGroupMetrics.make(
            items: group.items,
            isInstalled: \.isInstalled,
            isSelected: { !excludedKeys.contains($0.id) }
        )
        let isExpanded = expandedGroupIDs.contains(group.id)
        let summaryText = managementMode
            ? managementMetrics.summaryText
            : reviewHeaderSummaryText(
                summary: summary,
                slotMetrics: summarySlotMetrics,
                installedCount: managementMetrics.installedCount
            )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if isExpanded {
                        expandedGroupIDs.remove(group.id)
                    } else {
                        expandedGroupIDs.insert(group.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Label(group.group.displayName, systemImage: group.group.systemImage)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("arkfile_pack_group_\(group.id)")
                Spacer()
                if !batchSelectableItems.isEmpty {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            excludedKeys.formUnion(batchSelectableItems.map(\.id))
                        } else {
                            excludedKeys = ArkFileSelectableSlotMetrics.exclusionsSelectingAll(
                                currentExclusions: excludedKeys,
                                items: batchSelectableItems,
                                key: \.id,
                                variantGroup: \.variantGroup,
                                variantDefault: \.variantDefault
                            )
                        }
                        excludedKeys = enforceExclusiveVariantSelections(excludedKeys)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("arkfile_pack_group_\(group.id)_toggle_all")
                }
            }
            Text(summaryText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            if group.group == .streetMaps {
                Text("The included base offline map remains available. These optional Complete downloads add higher-detail street coverage by U.S. region.")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_regional_street_maps_explanation")
            }
        }
    }

    private func reviewHeaderSummaryText(
        summary: ArkFileContentDisplaySectionSummary,
        slotMetrics: ArkFileSelectableSlotMetrics,
        installedCount: Int
    ) -> String {
        if slotMetrics.totalSlotCount == 0 {
            return "All \(installedCount) on this device"
        }
        if slotMetrics.selectedSlotCount == 0 {
            return installedCount > 0
                ? "\(installedCount) on this device · Nothing selected"
                : "Nothing selected"
        }
        var text = slotMetrics.selectedSlotCount == slotMetrics.totalSlotCount
            ? "\(slotMetrics.selectedSlotCount) selected · \(Self.byteFormatter.string(fromByteCount: summary.selectedBytes))"
            : "\(slotMetrics.selectedSlotCount) of \(slotMetrics.totalSlotCount) selected · \(Self.byteFormatter.string(fromByteCount: summary.selectedBytes))"
        if installedCount > 0 {
            text += " · \(installedCount) on this device"
        }
        return text
    }

    private var downloadDetailsDisclosure: some View {
        DisclosureGroup(isExpanded: $isDownloadDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(footerSummaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                downloadDetailsContent
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Download details", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.byteFormatter.string(fromByteCount: bytesToDownload))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .accessibilityIdentifier("arkfile_pack_download_details")
    }

    @ViewBuilder
    private var downloadDetailsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if installedSelectedTitleCount > 0 {
                Text("\(installedSelectedTitleCount) title\(installedSelectedTitleCount == 1 ? " is" : "s are") already on this device and stay on this device. This selection adds only new downloads.")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installedSelectedMapCount > 0 {
                Text("\(installedSelectedMapCount) regional street map\(installedSelectedMapCount == 1 ? " is" : "s are") already on this device and stay on this device. This selection adds only new downloads.")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tier == .complete,
               wikipediaSelectedItems.isEmpty || selectedRegionalMapItems.isEmpty {
                Text(completeOmissionSummary)
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let storageLine {
                Label(storageLine.text, systemImage: storageLine.isWarning ? "exclamationmark.triangle" : "internaldrive")
                    .font(.caption)
                    .foregroundStyle(storageLine.isWarning ? Color.orange : Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasInsufficientReportedStorage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text("Not enough free space for this selection.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("arkfile_pack_storage_blocking_warning")
            }
            HStack(spacing: 8) {
                Text(compactFooterSummaryText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(0)
                    .accessibilityIdentifier(
                        "arkfile_pack_selection_footer_summary"
                    )
                Spacer(minLength: 0)
                Text(Self.byteFormatter.string(fromByteCount: bytesToDownload))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .accessibilityIdentifier(
                        "arkfile_pack_selection_footer_size"
                    )
            }
            .frame(maxWidth: .infinity)
            Button {
                confirmSelection()
            } label: {
                Text(confirmButtonTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .disabled(!canConfirmSelection)
            .accessibilityIdentifier("arkfile_pack_selection_confirm_action")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .background {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("arkfile_pack_selection_action_bar")
        }
    }

    private var completeOmissionSummary: String {
        switch (wikipediaSelectedItems.isEmpty, selectedRegionalMapItems.isEmpty) {
        case (true, true):
            return "This download will not include full Wikipedia or regional street maps. You can add either later."
        case (true, false):
            return "This download will not include full Wikipedia. You can add it later."
        case (false, true):
            return "This download will not include regional street maps. You can add them later."
        case (false, false):
            return ""
        }
    }

    private var compactFooterSummaryText: String {
        let count = itemsToDownload.count
        if count == 0 {
            return allowsPurchaseWithoutDownload ? "Download later" : "No downloads selected"
        }
        return "\(count) selected"
    }

    private var footerSummaryText: String {
        let titleCount = itemsToDownload.filter { $0.type != .map }.count
        let mapCount = itemsToDownload.filter { $0.type == .map }.count
        if titleCount == 0, mapCount == 0 {
            return allowsPurchaseWithoutDownload
                ? "No content selected to download now"
                : "No downloads selected"
        }
        var parts: [String] = []
        if titleCount > 0 {
            parts.append("\(titleCount) title\(titleCount == 1 ? "" : "s")")
        }
        if mapCount > 0 {
            parts.append("\(mapCount) regional street map\(mapCount == 1 ? "" : "s")")
        }
        return "\(parts.joined(separator: " · ")) selected to download"
    }

    private func confirmSelection() {
        let normalizedExclusions = enforceExclusiveVariantSelections(excludedKeys)
            .intersection(allItems.map(\.id))
        let selection = ArkFilePackSelectionResult(
            excludedItemKeys: normalizedExclusions,
            selectedMissingItemKeys: Set(itemsToDownload.map(\.id)
                .filter { !normalizedExclusions.contains($0) })
        )
        guard itemsToDownload.contains(where: { $0.type == .map }) else {
            onConfirm(selection)
            return
        }
        isPreparingDownload = true
        previewTask?.cancel()
        let generation = UUID()
        previewGeneration = generation
        previewTask = Task { @MainActor in
            defer {
                if previewGeneration == generation { isPreparingDownload = false }
            }
            do {
                let preview = try await ArkFileContentPackInstaller.shared.downloadPreview(
                    keys: selection.selectedMissingItemKeys.sorted(), tier: tier
                )
                try Task.checkCancellation()
                guard previewGeneration == generation else { return }
                previewMessage = "Download \(Self.byteFormatter.string(fromByteCount: preview.downloadBytes)) total."
                if preview.mapFoundationBytes > 0 {
                    previewMessage += " This includes \(Self.byteFormatter.string(fromByteCount: preview.mapFoundationBytes)) of shared map detail and places needed by these maps."
                }
                pendingReviewedSelection = selection
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, previewGeneration == generation else { return }
                previewError = "Connect to the internet and try again. No download has started."
            }
        }
    }

    private var confirmButtonTitle: String {
        if isPreparingDownload { return "Checking download size…" }
        if itemsToDownload.isEmpty {
            if purpose == .upgradeFromEssentials {
                return "Continue to Upgrade — Download Later"
            }
            if purpose == .purchase {
                return "Continue to Purchase — Download Later"
            }
            return "No Downloads Selected"
        }
        if hasInsufficientReportedStorage {
            return "Free Up Space to Continue"
        }
        if managementMode {
            let count = itemsToDownload.count
            return "Download \(count) Selected"
        }
        return selectedItems.count == allItems.count ? "\(confirmTitle) (Full Pack)" : confirmTitle
    }

    private func loadCatalog() {
        guard let catalog = try? ArkFileContentCatalog.loadBundled() else {
            return
        }
        var seenKeys = Set<String>()
        let installedIDs = Set(contentLibrary.allLibraryItems.filter(\.isInstalled).map(\.id))
        let loadedItems = ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            catalog.items(for: tier, category: category).compactMap { item -> SelectableItem? in
                guard let key = ArkFileLocalContentLibrary.canonicalCatalogItemKey(for: item),
                      seenKeys.insert(key).inserted else {
                    return nil
                }
                return SelectableItem(
                    id: key,
                    name: ArkFileContentDisplayName.displayName(
                        for: item.name,
                        relativePath: item.normalizedRelativePath
                    ),
                    displayGroup: ArkFileContentDisplayGroup.group(for: item),
                    subcategory: item.subcategory,
                    sizeBytes: item.sizeBytes,
                    type: item.type,
                    isAlreadyInEssentials: item.isAvailable(in: .lite),
                    isInstalled: installedIDs.contains(key),
                    variantGroup: item.normalizedVariantGroup,
                    variantLabel: item.variantLabel,
                    variantDefault: item.variantDefault == true,
                    summary: item.summary
                )
            }
        }
        catalogSelectableItems = loadedItems
        let catalogGroupItems = ArkFilePackSelectionPresentation.catalogGroupItems(
            from: loadedItems,
            variantGroup: \.variantGroup
        )
        let itemsByGroup = Dictionary(grouping: catalogGroupItems, by: \.displayGroup)
        let catalogGroups: [DisplayGroupSection] = ArkFileContentDisplayGroup.allCases.compactMap { displayGroup -> DisplayGroupSection? in
            guard let items = itemsByGroup[displayGroup], !items.isEmpty else { return nil }
            return DisplayGroupSection(
                group: displayGroup,
                items: items.sorted {
                    if $0.subcategory != $1.subcategory {
                        return $0.subcategory.localizedCaseInsensitiveCompare($1.subcategory) == .orderedAscending
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
        // Each new download choice starts empty. Saved exclusions belong to
        // legacy install/resume state, not a new shopping basket. Developer
        // previews may explicitly seed selections to exercise large layouts.
        let startingExclusions: Set<String>
        if managementMode,
           !startsWithSavedSelection {
            startingExclusions = seenKeys
        } else {
            startingExclusions = ArkFileDownloadReviewGroupPlan.initialExclusions(
                saved: initiallyExcluded,
                defaults: catalog.defaultExcludedItemKeys(for: tier)
            )
        }
        excludedKeys = enforceExclusiveVariantSelections(startingExclusions.intersection(seenKeys))
        completeOwnershipMetrics = ArkFileCompleteOwnershipMetrics.make(
            catalog: catalog,
            libraryItems: contentLibrary.allLibraryItems
        )
        if managementMode, tier == .complete {
            let inputs = catalogGroups.map { group in
                let selectedMissing = group.items.filter {
                    !$0.isInstalled && !excludedKeys.contains($0.id)
                }
                return ArkFileDownloadReviewGroupPlan.Input(
                    id: group.id,
                    selectedMissingCount: selectedMissing.count,
                    selectedIncludedCount: selectedMissing.filter(\.isAlreadyInEssentials).count
                )
            }
            let plan = ArkFileDownloadReviewGroupPlan.make(inputs: inputs)
            let groupsByID: [String: DisplayGroupSection] = Dictionary(
                uniqueKeysWithValues: catalogGroups.map { ($0.id, $0) }
            )
            groups = plan.orderedGroupIDs.compactMap { groupsByID[$0] }
            expandedGroupIDs = plan.expandedGroupIDs
            expandedAlreadyInEssentialsIDs = plan.expandedIncludedGroupIDs
        } else {
            groups = catalogGroups
            expandedGroupIDs = tier == .complete
                ? []
                : Set(catalogGroups.map(\.id))
            expandedAlreadyInEssentialsIDs = []
        }
    }

    private var reviewIntro: String {
        if purpose == .manageDownloads, tier == .complete {
            return "Complete is unlocked. Choose the titles and maps you want on this device. Add more whenever you need them."
        }
        if purpose == .manageDownloads {
            return "Essentials is unlocked. Choose the titles you want on this device. Add more whenever you need them."
        }
        if purpose == .downloadOwnedPack {
            return "Included with \(packName). Choose individual titles or select a category. Add more whenever you need them."
        }
        if purpose == .upgradeFromEssentials {
            return "The one-time upgrade keeps Essentials and everything already stored on this device. It unlocks all of Complete; these checkmarks only choose what downloads now. Anything skipped stays available later at no additional charge."
        }
        if purpose == .purchase {
            return "Your one-time purchase unlocks the entire \(packName) pack. These checkmarks only choose what downloads now. Anything skipped stays available later at no additional charge."
        }
        return "Choose what downloads now. Nothing already stored on this device is removed."
    }

    private func itemSubtitle(for item: SelectableItem) -> String {
        var parts = [
            ArkFilePackSelectionPresentation.itemGroupLabel(
                displayGroup: item.displayGroup,
                catalogSubcategory: item.subcategory
            )
        ]
        if let variantLabel = item.variantLabel, !variantLabel.isEmpty {
            parts.append(variantLabel)
        }
        if tier == .complete, item.isAlreadyInEssentials {
            parts.append("Included with Essentials")
        }
        return parts.joined(separator: " • ")
    }

    private func itemAccessibilityIdentifier(for item: SelectableItem) -> String {
        if item.variantGroup == "wikipedia-full" {
            return item.variantDefault
                ? "arkfile_complete_wikipedia_text_only"
                : "arkfile_complete_wikipedia_with_images"
        }
        return "arkfile_pack_item_\(item.id)"
    }

    private func toggledVariantExclusions(selecting itemID: String?, variantGroup: String) -> Set<String> {
        var exclusions = excludedKeys
        let siblings = allItems.filter { $0.variantGroup == variantGroup }
        for sibling in siblings {
            exclusions.insert(sibling.id)
        }
        if let itemID {
            exclusions.remove(itemID)
        }
        return exclusions
    }

    private func enforceExclusiveVariantSelections(_ exclusions: Set<String>) -> Set<String> {
        ArkFileSelectableSlotMetrics.exclusionsEnforcingExclusiveVariants(
            currentExclusions: exclusions,
            items: allItems,
            key: \.id,
            variantGroup: \.variantGroup,
            variantDefault: \.variantDefault,
            isInstalled: \.isInstalled
        )
    }
}
#endif

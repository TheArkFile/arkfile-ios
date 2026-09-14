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

enum ArkFileContentBrowserRowDownloadState: Equatable {
    case none
    case queued
    case waitingToRetry
    case downloading(progress: Double?)
    case checking
    case installing
}

enum ArkFileContentBrowserDownloadAction: Equatable {
    case downloadOnly
    case reviewSelection
    case resumeQueuedBatch
    case unavailable
}

struct ArkFileContentBrowserView: View {
    let openItem: (ArkFileLocalContentItem) -> Void
    var initialTargetRelativePath: String?
    private let dismissOnOpen: Bool
    @State private var libraryFilter: ArkFileLibraryFilter
    @State private var selectedGroup: ArkFileContentDisplayGroup?
    @State private var detailItem: ArkFileLibraryContentItem?
    @State private var showPackComparison = false

    init(
        openItem: @escaping (ArkFileLocalContentItem) -> Void,
        initialTargetRelativePath: String? = nil,
        initialFilter: ArkFileLibraryFilter = .allContent,
        initialGroup: ArkFileContentDisplayGroup? = nil,
        dismissOnOpen: Bool = true
    ) {
        self.openItem = openItem
        self.initialTargetRelativePath = initialTargetRelativePath
        self.dismissOnOpen = dismissOnOpen
        _libraryFilter = State(initialValue: initialFilter)
        _selectedGroup = State(initialValue: initialGroup)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared
    @StateObject private var liteInstaller = ArkFileContentPackInstaller.shared
    @State private var catalog: ArkFileContentCatalog?
    @State private var contentLicenseIndex: ArkFileContentLicenseIndex?
    @State private var sections: [ArkFileContentDisplayLibrarySection] = []
    @State private var expandedSectionIDs: Set<String> = []
    @State private var availableBytes: Int64?
    @State private var itemPendingRemoval: ArkFileLibraryContentItem?
    @State private var showCancelCurrentDownloadConfirmation = false
    @State private var showRemoveStoppedDownloadConfirmation = false
    @State private var removalError: String?
    @State private var openError: String?
    @State private var showEssentialsSelectionReview = false
    @State private var showCompleteSelectionReview = false
    @State private var highlightedItemID: String?
    @State private var pendingScrollTargetItemID: String?
    @State private var hasResolvedInitialTarget = false
    @State private var searchText = ""
    @State private var didExpandIncludedSamples = false
    @State private var isAwaitingRestoreOutcome = false
    @State private var pendingPurchaseTierAfterRestore: ArkFileContentTier?
    @State private var pendingCellularRequest: ArkFilePendingContentDownload?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                headerSection

                if visibleSections.isEmpty {
                    ContentUnavailableView(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No downloads here yet" : "No matching titles",
                        systemImage: searchText.isEmpty ? "books.vertical" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Choose All content to find titles and maps to download."
                            : "Try another title, topic, or region.")
                    )
                    .listRowBackground(Color.clear)
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedGroup != nil {
                    Section {
                        ForEach(visibleSections.flatMap { visibleItems(in: $0) }) { item in
                            itemRow(item)
                                .id(item.id)
                                .listRowBackground(rowBackground(for: item))
                        }
                    } header: {
                        Text("\(visibleSections.reduce(0) { $0 + visibleItems(in: $1).count }) titles")
                    }
                } else {
                    ForEach(visibleSections) { section in
                        Section {
                            if expandedSectionIDs.contains(section.id) {
                                ForEach(visibleItems(in: section)) { item in
                                    itemRow(item)
                                        .id(item.id)
                                        .listRowBackground(rowBackground(for: item))
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("arkfile_downloads_root")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search ArkFile content"
            )
            .navigationTitle(selectedGroup?.displayName ?? contentManagerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await load()
            }
            .onChange(of: contentLibrary.categories) { _, _ in
                rebuildSections()
                Task { await refreshAvailableBytes() }
            }
            .onChange(of: lockedResolutionInput) { _, _ in
                rebuildSections()
            }
            .onChange(of: contentLibrary.libraryCategories) { _, _ in
                rebuildSections()
            }
            .onChange(of: pendingScrollTargetItemID) { _, itemID in
                scrollToTargetItem(itemID, proxy: proxy)
            }
        }
        .arkFileRestoreOutcomePrompt(
            installer: liteInstaller,
            isAwaitingOutcome: $isAwaitingRestoreOutcome,
            chooseDownloads: chooseDownloadsAfterRestore,
            successActionTitle: restoreSuccessActionTitle,
            cancel: { pendingPurchaseTierAfterRestore = nil }
        )
        .confirmationDialog(
            "Remove \(itemPendingRemoval?.displayName ?? "this title") from this device?",
            isPresented: Binding(
                get: { itemPendingRemoval != nil },
                set: { if !$0 { itemPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(itemPendingRemoval?.isNoLongerDistributedByArkFile == true ? "Permanently Remove" : "Remove Download", role: .destructive) {
                if let item = itemPendingRemoval {
                    removeItem(item)
                }
                itemPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                itemPendingRemoval = nil
            }
        } message: {
            Text(removalMessage(for: itemPendingRemoval))
        }
        .confirmationDialog(
            "Remove stopped download?",
            isPresented: $showRemoveStoppedDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove stopped download", role: .destructive) {
                _ = liteInstaller.cancelPausedDownloadRequest()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This removes the stopped request. Downloaded titles stay available, and unfinished data is kept for a later retry. Other queued titles stay paused until you resume them.")
        }
        .confirmationDialog(
            "Cancel \(liteInstaller.currentDownloadDisplayName ?? "this title") download?",
            isPresented: $showCancelCurrentDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel & Remove Partial", role: .destructive) {
                cancelCurrentDownload()
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text(cancelCurrentDownloadMessage)
        }
        .alert(
            "Use Cellular Data?",
            isPresented: Binding(
                get: { pendingCellularRequest != nil },
                set: { if !$0 { pendingCellularRequest = nil } }
            ),
            presenting: pendingCellularRequest
        ) { request in
            Button("Not Now", role: .cancel) { pendingCellularRequest = nil }
            Button("Use Cellular Data") {
                continueStoppedDownloadUsingCellular(request)
            }
            .accessibilityIdentifier("arkfile_confirm_cellular_download")
        } message: { _ in
            Text("This continues only your stopped download selection. Cellular, hotspot, or Low Data Mode can use a large amount of data and may incur charges. Other queued downloads still use Wi-Fi by default.")
        }
        .alert(
            "Could Not Remove",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
        .alert(
            "Could Not Open",
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .sheet(isPresented: $showEssentialsSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .lite,
                    confirmTitle: "Start Download",
                    managementMode: liteInstaller.hasSavedLiteAccess,
                    purpose: liteInstaller.hasSavedLiteAccess ? .manageDownloads : .purchase,
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .lite),
                    onConfirm: { result in
                        showEssentialsSelectionReview = false
                        liteInstaller.includeItemsAndDownload(keys: Array(result.selectedMissingItemKeys), tier: .lite)
                    },
                    onCancel: {
                        showEssentialsSelectionReview = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCompleteSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .complete,
                    confirmTitle: "Download Selected",
                    managementMode: liteInstaller.hasSavedCompleteAccess,
                    purpose: liteInstaller.hasSavedCompleteAccess
                        ? .manageDownloads
                        : hasEssentialsAccess ? .upgradeFromEssentials : .purchase,
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .complete),
                    onConfirm: { result in
                        showCompleteSelectionReview = false
                        liteInstaller.includeItemsAndDownload(keys: Array(result.selectedMissingItemKeys), tier: .complete)
                    },
                    onCancel: {
                        showCompleteSelectionReview = false
                    }
                )
            }
        }
        .navigationDestination(item: $detailItem) { selected in
            titleDetail(for: sections.flatMap(\.items).first { $0.id == selected.id } ?? selected)
        }
        .sheet(isPresented: $showPackComparison) {
            packComparisonSheet
        }
        .alert(
            "Purchase Status",
            isPresented: Binding(
                get: { liteInstaller.purchaseHelpMessage != nil },
                set: { if !$0 { liteInstaller.dismissPurchaseHelpMessage() } }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissPurchaseHelpMessage()
            }
        } message: {
            Text(liteInstaller.purchaseHelpMessage ?? "")
        }
        .alert(
            "Download Could Not Start",
            isPresented: Binding(
                get: { liteInstaller.downloadFailureMessage != nil },
                set: { if !$0 { liteInstaller.dismissDownloadFailureMessage() } }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissDownloadFailureMessage()
            }
        } message: {
            Text(liteInstaller.downloadFailureMessage ?? "")
        }
    }

    private var isSearchingLibrary: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if !isSearchingLibrary {
                    Label(
                        "Your library, your choice",
                        systemImage: usesManagementPresentation ? "internaldrive" : "rectangle.grid.1x2"
                    )
                        .font(.headline)
                        .foregroundStyle(Color.arkTextPrimary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            installedMetric
                            freeSpaceMetric
                        }
                        VStack(spacing: 8) {
                            installedMetric
                            freeSpaceMetric
                        }
                    }
                    Text(
                        packStateLine + ". Choose what stays on this device. Downloaded titles work offline."
                    )
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                libraryFilterControl
                if selectedGroup != nil {
                    Button("Show all categories") { selectedGroup = nil }
                        .font(.subheadline)
                        .foregroundStyle(Color.arkInteractiveForeground)
                        .frame(minHeight: 44)
                }
                if blocksForAppleAccountCheck {
                    ArkFileApplePurchaseCheckingView(
                        isBusy: liteInstaller.isBusy,
                        checkAppleAccount: {
                            beginRestore(tier: .lite)
                        }
                    )
                }
                if liteInstaller.queuedDownloadCount > 0 {
                    Label("\(liteInstaller.queuedDownloadCount) queued", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                    if !liteInstaller.isBusy && !liteInstaller.canCancelPausedDownloadRequest {
                        Button("Resume downloads") { liteInstaller.resumeQueuedDownloads() }
                            .frame(minHeight: 44)
                    }
                }
                if liteInstaller.canCancelPausedDownloadRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Download stopped", systemImage: "pause.circle")
                            .font(.subheadline.weight(.semibold))
                        if let status = liteInstaller.stoppedDownloadStatusText {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(Color.arkTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("arkfile_stopped_download_reason")
                        }
                        Text("Resume this download, or remove the stopped request to choose what downloads next. Your downloaded content stays available.")
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(liteInstaller.stoppedDownloadCellularRequest == nil ? "Resume downloads" : "Resume on Wi-Fi") {
                            liteInstaller.resumeQueuedDownloads()
                        }
                            .frame(minHeight: 44)
                        if let request = liteInstaller.stoppedDownloadCellularRequest {
                            Button("Use Cellular Data…") { pendingCellularRequest = request }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("arkfile_stopped_download_cellular_action")
                        }
                        Button("Remove stopped download", role: .destructive) {
                            showRemoveStoppedDownloadConfirmation = true
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("arkfile_remove_stopped_download")
                    }
                }
                if liteInstaller.isBusy, let statusText = liteInstaller.statusText {
                    Label(statusText, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                if let progress = liteInstaller.state.progressFraction,
                   liteInstaller.shouldShowProgressBar {
                    ProgressView(value: progress)
                }
                if liteInstaller.canPauseLiteDownload {
                    downloadInterruptionControls
                }
                if !isSearchingLibrary, let tier = bulkSelectionTier {
                    addMultipleButton(tier: tier)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    private var libraryFilterPicker: some View {
        Picker("Library content", selection: $libraryFilter) {
            ForEach(ArkFileLibraryFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .accessibilityIdentifier("arkfile_library_filter")
        .tint(Color.arkInteractiveForeground)
    }

    @ViewBuilder
    private var libraryFilterControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            libraryFilterPicker.pickerStyle(.menu).frame(minHeight: 44)
        } else {
            libraryFilterPicker.pickerStyle(.segmented)
        }
    }

    private var downloadInterruptionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = liteInstaller.currentDownloadDisplayName {
                Text("Currently downloading \(title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pauseDownloadButton
                    if liteInstaller.canCancelCurrentDownload {
                        cancelDownloadButton
                    }
                }
                VStack(spacing: 8) {
                    pauseDownloadButton
                    if liteInstaller.canCancelCurrentDownload {
                        cancelDownloadButton
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private var pauseDownloadButton: some View {
        Button(role: .cancel) {
            liteInstaller.cancelLiteDownload()
        } label: {
            Label("Pause Download", systemImage: "pause.circle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Keeps partial download progress so it can resume later.")
    }

    private var cancelDownloadButton: some View {
        Button(role: .destructive) {
            showCancelCurrentDownloadConfirmation = true
        } label: {
            Label("Cancel Download…", systemImage: "xmark.circle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityHint("Stops the current title and removes its unfinished data after confirmation.")
    }

    private var installedMetric: some View {
        let summary = ArkFileDownloadManagerInstalledSummary.make(items: sections.flatMap(\.items))
        return metric(
            "On this device",
            value: summary.countSummary,
            detail: summary.installedTitleBytes > 0
                ? "\(Self.byteFormatter.string(fromByteCount: summary.installedTitleBytes)) in downloaded titles"
                : nil
        )
    }

    private var freeSpaceMetric: some View {
        metric(
            "Free space",
            value: availableBytes.map(Self.byteFormatter.string(fromByteCount:)) ?? "Unknown"
        )
    }

    private func metric(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.arkTextMuted)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Color.arkTextPrimary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private func addMultipleButton(tier: ArkFileContentTier) -> some View {
        Button {
            if tier == .complete {
                showCompleteSelectionReview = true
            } else {
                showEssentialsSelectionReview = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.headline)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Downloads…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(
                        "Pick several titles or categories to download at once."
                    )
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextMuted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkAppBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds several titles at once. Downloaded content is not removed.")
    }

    private func sectionHeader(_ section: ArkFileContentDisplayLibrarySection) -> some View {
        let isExpanded = expandedSectionIDs.contains(section.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isExpanded {
                    expandedSectionIDs.remove(section.id)
                } else {
                    expandedSectionIDs.insert(section.id)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextMuted)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Label(section.group.displayName, systemImage: section.group.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    sectionSummary(section)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func sectionSummary(_ section: ArkFileContentDisplayLibrarySection) -> some View {
        let items = visibleItems(in: section)
        let readyCount = items.filter { $0.isInstalled || $0.isSampleContent }.count
        let titleCount = items.count == 1 ? "1 title" : "\(items.count) titles"
        return Text("\(titleCount) · \(readyCount) ready offline")
            .font(.caption)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func itemRow(_ item: ArkFileLibraryContentItem) -> some View {
        let presentation = ArkFileLockedContentPresentation.resolve(item: item, input: lockedResolutionInput)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                showDetails(for: item)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.type.systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.arkInteractiveForeground)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ArkFileLibraryDiscovery.displayName(for: item))
                            .font(.headline)
                            .foregroundStyle(Color.arkTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.type == .map ? "Regional street map" : itemSubtitle(item))
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.arkTextMuted)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.type == .map ? "Shows map coverage and download options." : "Shows the title description and download options.")

            Label(presentation.statusTitle, systemImage: presentation.statusSystemImage)
                .font(.subheadline)
                .foregroundStyle(presentation.accessState == .locked ? Color.arkLockedForeground : Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.arkTextMuted)
                Spacer(minLength: 0)
                trailingControl(for: item, presentation: presentation)
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove(item, presentation: presentation) {
                Button("Remove", role: .destructive) { itemPendingRemoval = item }
            }
        }
    }

    @ViewBuilder
    private func trailingControl(
        for item: ArkFileLibraryContentItem,
        presentation: ArkFileLockedContentPresentation
    ) -> some View {
        if presentation.accessState == .sample || presentation.accessState == .installed {
            Button("Open") { openFromLibrary(item) }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .foregroundStyle(Color.arkInteractiveForeground)
                .accessibilityLabel("Open \(ArkFileLibraryDiscovery.displayName(for: item))")
        } else if presentation.accessState == .downloadable {
            let rowState = currentRowDownloadState(for: item)
            if rowState == .none {
                Button {
                    handleDownloadAction(item, presentation: presentation)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .foregroundStyle(Color.arkInteractiveForeground)
                .disabled(!presentation.canDownloadOnlyThisTitle)
                .accessibilityLabel("Download \(ArkFileLibraryDiscovery.displayName(for: item))")
            } else if rowState == .queued {
                if liteInstaller.isItemQueued(key: item.id) {
                    Menu {
                        Button("Remove from queue", role: .destructive) {
                            liteInstaller.removeQueuedItem(key: item.id)
                        }
                    } label: {
                        Label("Queued", systemImage: "clock")
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("\(ArkFileLibraryDiscovery.displayName(for: item)) queued. Queue options")
                } else {
                    Label("Waiting in current download", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if rowState == .waitingToRetry {
                Button("Resume") { liteInstaller.resumeQueuedDownloads() }
                    .buttonStyle(.borderless)
                    .disabled(!presentation.canDownloadOnlyThisTitle || liteInstaller.isBusy)
                    .frame(minHeight: 44)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .accessibilityLabel("Resume downloads")
            } else {
                rowDownloadIndicator(for: rowState)
                    .accessibilityLabel(rowDownloadAccessibilityLabel(for: rowState, item: item))
            }
        } else {
            Button(presentation.resolvedTier == .complete && hasEssentialsAccess ? "Upgrade" : "View pack") {
                showDetails(for: item)
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .foregroundStyle(Color.arkLockedForeground)
        }
    }

    @ViewBuilder
    private func rowDownloadIndicator(
        for state: ArkFileContentBrowserRowDownloadState
    ) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .none:
                EmptyView()
            case .queued:
                ProgressView()
                    .controlSize(.small)
                Text("Queued...")
                    .fontWeight(.semibold)
            case .waitingToRetry:
                Image(systemName: "arrow.clockwise.circle")
                Text("Ready to retry")
                    .fontWeight(.semibold)
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 42)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Downloading")
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Checking")
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("Adding")
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.arkTextMuted)
        .frame(minWidth: 78, alignment: .trailing)
    }

    private func rowDownloadAccessibilityLabel(
        for state: ArkFileContentBrowserRowDownloadState,
        item: ArkFileLibraryContentItem
    ) -> String {
        switch state {
        case .none:
            "Download \(ArkFileLibraryDiscovery.displayName(for: item))"
        case .queued:
            "\(ArkFileLibraryDiscovery.displayName(for: item)) queued for download"
        case .waitingToRetry:
            "\(ArkFileLibraryDiscovery.displayName(for: item)) selected and ready to retry"
        case .downloading:
            "\(ArkFileLibraryDiscovery.displayName(for: item)) downloading"
        case .checking:
            "\(ArkFileLibraryDiscovery.displayName(for: item)) checking installed file"
        case .installing:
            "\(ArkFileLibraryDiscovery.displayName(for: item)) adding to this device"
        }
    }

    private func rowBackground(for item: ArkFileLibraryContentItem) -> Color {
        highlightedItemID == item.id
            ? Color.arkPrimary.opacity(0.12)
            : Color.clear
    }

    private func itemSubtitle(_ item: ArkFileLibraryContentItem) -> String {
        var parts = item.isNoLongerDistributedByArkFile
            ? [ArkFileContentRetirementPolicy.userFacingStatus]
            : [item.subcategory]
        if let variantLabel = item.variantLabel, !variantLabel.isEmpty {
            parts.append(variantLabel)
        }
        if item.isSampleContent {
            parts.append("Sample")
        }
        return parts.joined(separator: " · ")
    }

    private func removalMessage(for item: ArkFileLibraryContentItem?) -> String {
        guard let item else {
            return "This removes the downloaded file from this device."
        }
        guard item.isNoLongerDistributedByArkFile else {
            guard hasSavedAccess(for: item.requiredTier) else {
                return "It stays part of ArkFile. Restore the matching purchase before downloading it again."
            }
            return "It stays part of ArkFile and can be downloaded again anytime."
        }
        return ArkFileContentRetirementPolicy.retainedDeletionWarning
    }

    private func showDetails(for item: ArkFileLibraryContentItem) {
        if item.type == .map {
            NotificationCenter.default.post(name: .arkFileOpenMapRegion, object: nil,
                userInfo: ["relativePath": item.relativePath, "showDownloads": true])
        } else {
            detailItem = item
        }
    }

    private func openFromLibrary(_ item: ArkFileLibraryContentItem) {
        if item.type == .map {
            NotificationCenter.default.post(name: .arkFileOpenMapRegion, object: nil,
                userInfo: ["relativePath": item.relativePath, "showDownloads": false])
        } else {
            open(item)
        }
    }

    private func handleDownloadAction(_ item: ArkFileLibraryContentItem, presentation: ArkFileLockedContentPresentation) {
        guard presentation.canDownloadOnlyThisTitle else { return }
        if currentRowDownloadState(for: item) == .waitingToRetry {
            liteInstaller.resumeQueuedDownloads()
        } else {
            startIndividualDownload(item, tier: presentation.resolvedTier)
        }
    }

    private func startIndividualDownload(_ item: ArkFileLibraryContentItem, tier: ArkFileContentTier) {
        // Regional map review includes any required foundation files in the
        // download total before the user starts the transfer.
        guard item.type != .map else {
            showDetails(for: item)
            return
        }
        liteInstaller.includeItemAndDownload(key: item.id, tier: tier)
    }

    private func currentRowDownloadState(for item: ArkFileLibraryContentItem) -> ArkFileContentBrowserRowDownloadState {
        guard !item.isInstalled && !item.isSampleContent else { return .none }
        switch liteInstaller.downloadQueueState(for: item.id) {
        case .queued: return .queued
        case .paused: return .waitingToRetry
        case .active: return Self.rowDownloadState(for: item, installState: liteInstaller.state)
        case .none: return .none
        }
    }

    private func titleDetail(for item: ArkFileLibraryContentItem) -> some View {
        let presentation = ArkFileLockedContentPresentation.resolve(item: item, input: lockedResolutionInput)
        let rowState = currentRowDownloadState(for: item)
        let isOffline = presentation.accessState == .sample || presentation.accessState == .installed
        let actionTitle: String
        let actionIcon: String
        let transferStatus: String?
        let isEnabled: Bool
        switch rowState {
        case .queued:
            let canRemoveFromQueue = liteInstaller.isItemQueued(key: item.id)
            actionTitle = canRemoveFromQueue ? "Remove from queue" : "Waiting in current download"
            actionIcon = canRemoveFromQueue ? "xmark.circle" : "clock"
            transferStatus = canRemoveFromQueue ? "Queued for download" : "This title will follow the current title."
            isEnabled = canRemoveFromQueue
        case .waitingToRetry:
            actionTitle = presentation.accessState == .locked ? presentation.primaryActionTitle
                : liteInstaller.stoppedDownloadCellularRequest != nil ? "Use Cellular Data…" : "Resume downloads"
            actionIcon = presentation.accessState == .locked ? "lock.open" : "arrow.clockwise.circle"
            transferStatus = liteInstaller.stoppedDownloadStatusText ?? "Download stopped"
            isEnabled = presentation.accessState == .locked
                ? presentation.isPrimaryActionEnabled
                : !liteInstaller.isBusy && presentation.canDownloadOnlyThisTitle
        case .downloading, .checking, .installing:
            actionTitle = "Downloading"
            actionIcon = "arrow.down.circle"
            transferStatus = liteInstaller.statusText
            isEnabled = false
        case .none:
            actionTitle = isOffline ? "Open" : presentation.accessState == .downloadable
                ? "Download · \(Self.byteFormatter.string(fromByteCount: item.sizeBytes))"
                : presentation.primaryActionTitle
            actionIcon = isOffline ? "book" : presentation.accessState == .downloadable
                ? "arrow.down.circle" : "lock.open"
            transferStatus = nil
            isEnabled = isOffline || (presentation.accessState == .downloadable
                ? presentation.canDownloadOnlyThisTitle : presentation.isPrimaryActionEnabled)
        }
        return ArkFileTitleDetailView(
            item: item,
            presentation: presentation,
            transferStatus: transferStatus,
            actionTitle: actionTitle,
            actionSystemImage: actionIcon,
            isActionEnabled: isEnabled,
            licenseEntry: contentLicenseEntry(for: item),
            ledgerVersion: contentLicenseIndex?.ledgerVersion ?? "Unknown",
            primaryAction: {
                if isOffline {
                    openFromLibrary(item)
                } else if rowState == .queued {
                    liteInstaller.removeQueuedItem(key: item.id)
                } else if rowState == .waitingToRetry {
                    if presentation.accessState == .locked {
                        if let route = presentation.primaryRestoreRoute {
                            handleLockedRestoreAction(route)
                        } else {
                            showPackComparison = true
                        }
                    } else if let request = liteInstaller.stoppedDownloadCellularRequest {
                        pendingCellularRequest = request
                    } else {
                        liteInstaller.resumeQueuedDownloads()
                    }
                } else if presentation.canDownloadOnlyThisTitle {
                    startIndividualDownload(item, tier: presentation.resolvedTier)
                } else if let route = presentation.primaryRestoreRoute {
                    handleLockedRestoreAction(route)
                } else {
                    showPackComparison = true
                }
            },
            restoreAction: { beginRestore(tier: presentation.resolvedTier) },
            removeAction: canRemove(item, presentation: presentation) ? { itemPendingRemoval = item } : nil
        )
    }

    private func continueStoppedDownloadUsingCellular(_ request: ArkFilePendingContentDownload) {
        pendingCellularRequest = nil
        // A refund, another window, or removal can replace the request while
        // its warning is open. Approval applies only to the reviewed batch.
        guard liteInstaller.stoppedDownloadCellularRequest == request else { return }
        if request.tier == .complete {
            liteInstaller.installCompleteAllowingCellularDownload()
        } else {
            liteInstaller.installLiteAllowingCellularDownload()
        }
    }

    private var packComparisonSheet: some View {
        let items = sections.flatMap(\.items)
        let metrics = ArkFileHomePackCardMetrics.make(items: items)
        let ownership = ArkFileCompleteOwnershipMetrics.make(catalog: catalog, libraryItems: items)
        return NavigationStack {
            ArkFilePackComparisonView(
                catalog: catalog,
                hasEssentialsAccess: hasEssentialsAccess,
                hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
                hasLocalPaidContent: hasLocalPaidContent,
                hasCurrentEssentialsStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .lite),
                hasCurrentCompleteStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .complete),
                hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
                essentialsInstalledCount: metrics.installedEssentialsTitleCount,
                completeInstalledCount: ownership.installedTitleSlots,
                completeInstalledMapCount: ownership.installedMapCount,
                isBusy: liteInstaller.isBusy,
                isCheckingApplePurchases: liteInstaller.isCheckingApplePurchases,
                chooseEssentials: { handleComparisonAction(tier: .lite) },
                chooseComplete: { currentProof in
                    handleComparisonAction(tier: .complete, currentEssentialsProof: currentProof)
                },
                manageDownloads: {
                    showPackComparison = false
                    libraryFilter = .allContent
                },
                restorePurchases: {
                    showPackComparison = false
                    // A generic Restore Purchases action restores the highest
                    // owned pack rather than requiring a Complete purchase.
                    beginRestore(tier: .lite)
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPackComparison = false }
                }
            }
        }
        .tint(Color.arkInteractiveForeground)
    }

    private func handleComparisonAction(tier: ArkFileContentTier, currentEssentialsProof: Bool? = nil) {
        let action = ArkFilePackComparisonActionResolver.resolve(
            tier: tier,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsStoreKitProof: currentEssentialsProof ?? liteInstaller.hasCurrentStoreKitProof(for: .lite),
            hasCurrentCompleteStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .complete)
        )
        showPackComparison = false
        DispatchQueue.main.async {
            switch action {
            case .manageDownloads:
                libraryFilter = .allContent
            case .restorePurchases:
                if tier == .complete && hasEssentialsAccess && !liteInstaller.hasSavedCompleteAccess {
                    beginRestoreForCompletePurchase()
                } else {
                    beginRestore(tier: tier)
                }
            case .purchase(let purchaseTier):
                beginPurchaseWithoutDownload(tier: purchaseTier)
            }
        }
    }

    private func open(_ item: ArkFileLibraryContentItem) {
        guard let localItem = item.localItem else {
            openError = "ArkFile could not find \(ArkFileLibraryDiscovery.displayName(for: item)) in the local library."
            return
        }
        if dismissOnOpen { dismiss() }
        DispatchQueue.main.async {
            openItem(localItem)
        }
    }

    private func canRemove(
        _ item: ArkFileLibraryContentItem,
        presentation _: ArkFileLockedContentPresentation
    ) -> Bool {
        Self.canRemove(item, isInstallerBusy: liteInstaller.isBusy)
    }

    private func removeItem(_ item: ArkFileLibraryContentItem) {
        let presentation = ArkFileLockedContentPresentation.resolve(
            item: item,
            input: lockedResolutionInput
        )
        guard let url = item.url else {
            removalError = "ArkFile could not find the file for \(ArkFileLibraryDiscovery.displayName(for: item))."
            return
        }
        guard liteInstaller.removeInstalledItem(
            key: item.id,
            fileURL: url,
            tier: presentation.resolvedTier
        ) else {
            removalError = liteInstaller.removalFailureMessage
                ?? "ArkFile could not remove \(ArkFileLibraryDiscovery.displayName(for: item)) from this device."
            return
        }
        if let cleanupWarning = liteInstaller.removalFailureMessage {
            removalError = cleanupWarning
        }
        if detailItem?.id == item.id { detailItem = nil }
        Task {
            await contentLibrary.refresh()
            rebuildSections()
            await refreshAvailableBytes()
        }
    }

    private func cancelCurrentDownload() {
        Task {
            _ = await liteInstaller.cancelCurrentDownloadAndDiscard()
            await contentLibrary.refresh()
            rebuildSections()
            await refreshAvailableBytes()
        }
    }

    private func load() async {
        catalog = try? ArkFileContentCatalog.loadBundled()
        contentLicenseIndex = try? ArkFileContentLicenseIndex.loadBundled()
        await contentLibrary.refresh()
        rebuildSections()
        await refreshAvailableBytes()
    }

    private func refreshAvailableBytes() async {
        availableBytes = await Task.detached(priority: .utility) {
            try? ArkFileContentStoragePreflight.availableCapacityForDownload()
        }.value ?? nil
    }

    private func contentLicenseEntry(
        for item: ArkFileLibraryContentItem
    ) -> ArkFileContentLicenseEntry? {
        contentLicenseIndex?.entry(forRelativePath: item.relativePath)
    }

    private func rebuildSections() {
        let categories = ArkFileContentDisplayLibrarySection.completeCatalogBackedCategories(
            installedCategories: contentLibrary.categories,
            fallbackCategories: contentLibrary.libraryCategories,
            catalog: catalog
        )
        sections = ArkFileContentDisplayLibrarySection.makeSections(
            from: categories,
            catalog: catalog,
            resolutionInput: lockedResolutionInput
        )
        if !didExpandIncludedSamples {
            didExpandIncludedSamples = true
            expandedSectionIDs.formUnion(sections.map(\.id))
        }
        applyInitialTargetIfNeeded()
    }

    private var visibleSections: [ArkFileContentDisplayLibrarySection] {
        sections.filter {
            (selectedGroup == nil || $0.group == selectedGroup) && !visibleItems(in: $0).isEmpty
        }
    }

    private func visibleItems(in section: ArkFileContentDisplayLibrarySection) -> [ArkFileLibraryContentItem] {
        ArkFileLibraryDiscovery.matchingItems(section.items, filter: libraryFilter, query: searchText)
    }

    private func applyInitialTargetIfNeeded() {
        guard !hasResolvedInitialTarget,
              let target = Self.contentDownloadTarget(
                relativePath: initialTargetRelativePath,
                catalog: catalog,
                sections: sections
              ) else {
            return
        }
        hasResolvedInitialTarget = true
        libraryFilter = .allContent
        selectedGroup = nil
        expandedSectionIDs.insert(target.sectionID)
        highlightedItemID = target.itemID
        pendingScrollTargetItemID = target.itemID
        if let item = sections.flatMap(\.items).first(where: { $0.id == target.itemID }), item.type != .map {
            detailItem = item
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedItemID == target.itemID {
                highlightedItemID = nil
            }
        }
    }

    private func scrollToTargetItem(
        _ itemID: String?,
        proxy: ScrollViewProxy
    ) {
        guard let itemID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(itemID, anchor: .center)
            }
        }
    }

    static func contentDownloadTarget(
        relativePath: String?,
        catalog: ArkFileContentCatalog?,
        sections: [ArkFileContentDisplayLibrarySection]
    ) -> (sectionID: String, itemID: String)? {
        guard let targetPath = normalizedDownloadTargetPath(relativePath, catalog: catalog) else {
            return nil
        }
        for section in sections {
            if let item = section.items.first(where: { item in
                normalizedDownloadTargetPath(item.relativePath, catalog: nil) == targetPath
            }) {
                return (section.id, item.id)
            }
        }
        return nil
    }

    static func rowDownloadState(
        for item: ArkFileLibraryContentItem,
        installState: ArkFileContentInstallState
    ) -> ArkFileContentBrowserRowDownloadState {
        let itemID = item.id
        let currentID = normalizedDownloadTargetPath(installState.currentFile, catalog: nil)
        let matchesPendingAdd = installState.normalizedAddedItemPaths.contains(itemID)
        let matchesCurrentFile = currentID == itemID
        guard matchesPendingAdd || matchesCurrentFile else {
            return .none
        }
        switch installState.phase {
        case .purchasing, .preparing:
            return .queued
        case .readyToDownload:
            return matchesPendingAdd ? .waitingToRetry : .none
        case .downloading:
            return matchesCurrentFile
                ? .downloading(progress: installState.progressFraction)
                : .queued
        case .verifying:
            return matchesCurrentFile ? .checking : .queued
        case .installing:
            return matchesCurrentFile ? .installing : .queued
        case .idle, .failed:
            return matchesPendingAdd ? .waitingToRetry : .none
        case .installed:
            return .none
        }
    }

    static func downloadAction(
        canDownloadOnlyThisTitle: Bool,
        isInstallerBusy: Bool,
        hasQueuedRequestForItem: Bool = false
    ) -> ArkFileContentBrowserDownloadAction {
        if hasQueuedRequestForItem {
            return .resumeQueuedBatch
        }
        return canDownloadOnlyThisTitle ? .downloadOnly : .reviewSelection
    }

    static func showsCancelControl(
        for rowState: ArkFileContentBrowserRowDownloadState,
        canCancelCurrentDownload: Bool
    ) -> Bool {
        guard canCancelCurrentDownload else { return false }
        if case .downloading = rowState {
            return true
        }
        return false
    }

    static func contentManagerTitle(
        hasSavedLiteAccess: Bool,
        hasSavedCompleteAccess: Bool,
        hasInstalledNonSampleContent: Bool
    ) -> String {
        "Library"
    }

    static func bulkSelectionTier(
        hasSavedLiteAccess: Bool,
        hasSavedCompleteAccess: Bool
    ) -> ArkFileContentTier? {
        if hasSavedCompleteAccess {
            return .complete
        }
        return hasSavedLiteAccess ? .lite : nil
    }

    static func canRemove(
        _ item: ArkFileLibraryContentItem,
        isInstallerBusy: Bool
    ) -> Bool {
        let isManagedURL = item.url.map(ArkFileEssentialsAccessGate.isManagedEssentialsURL) ?? false
        return canRemove(
            isInstalled: item.isInstalled,
            isSampleContent: item.isSampleContent,
            hasManagedURL: isManagedURL,
            isInstallerBusy: isInstallerBusy
        )
    }

    static func canRemove(
        isInstalled: Bool,
        isSampleContent: Bool,
        hasManagedURL: Bool,
        isInstallerBusy: Bool
    ) -> Bool {
        isInstalled && !isSampleContent && hasManagedURL && !isInstallerBusy
    }

    private static func normalizedDownloadTargetPath(
        _ relativePath: String?,
        catalog: ArkFileContentCatalog?
    ) -> String? {
        let normalized = relativePath?
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        if let catalog,
           let catalogPath = ArkFileLocalContentLibrary.canonicalCatalogRelativePath(
            for: normalized,
            catalog: catalog
           ) {
            return catalogPath.lowercased()
        }
        return normalized.lowercased()
    }

    private func sectionAccessBadges(
        for section: ArkFileContentDisplayLibrarySection
    ) -> [(title: String, color: Color)] {
        let lockedPresentations = section.items.compactMap { item -> ArkFileLockedContentPresentation? in
            let presentation = ArkFileLockedContentPresentation.resolve(
                item: item,
                input: lockedResolutionInput
            )
            return presentation.accessState == .locked ? presentation : nil
        }
        let completeLockedCount = lockedPresentations.filter { $0.resolvedTier == .complete }.count
        let otherLockedCount = lockedPresentations.count - completeLockedCount
        var badges: [(title: String, color: Color)] = []
        if completeLockedCount > 0 {
            let title = hasEssentialsAccess
                ? "\(completeLockedCount) with Complete"
                : "\(completeLockedCount) Complete"
            badges.append((title, Color.arkLockedForeground))
        }
        if otherLockedCount > 0 {
            badges.append(("\(otherLockedCount) locked", Color.arkLockedForeground))
        }
        if section.summary.notDownloadedCount > 0 {
            badges.append(("\(section.summary.notDownloadedCount) not downloaded", Color.arkTextMuted))
        }
        return badges
    }

    private var cancelCurrentDownloadMessage: String {
        let remainingCount = max(
            0,
            liteInstaller.state.normalizedAddedItemPaths.count - 1
        )
        let queueCopy = remainingCount > 0
            ? " The other \(remainingCount) selected download\(remainingCount == 1 ? "" : "s") will stop and remain available to resume or edit."
            : ""
        return "The unfinished data for the current title will be removed and the batch will stop.\(queueCopy) Installed titles stay available."
    }

    private var usesManagementPresentation: Bool {
        hasEssentialsAccess
            || liteInstaller.hasSavedCompleteAccess
            || contentLibrary.hasNonSampleContent
    }

    private var contentManagerTitle: String {
        Self.contentManagerTitle(
            hasSavedLiteAccess: hasEssentialsAccess,
            hasSavedCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasInstalledNonSampleContent: contentLibrary.hasNonSampleContent
        )
    }

    private var bulkSelectionTier: ArkFileContentTier? {
        Self.bulkSelectionTier(
            hasSavedLiteAccess: hasEssentialsAccess,
            hasSavedCompleteAccess: liteInstaller.hasSavedCompleteAccess
        )
    }

    private var packStateLine: String {
        let essentialsState: String
        if hasEssentialsAccess {
            essentialsState = "Essentials unlocked"
        } else {
            essentialsState = "Essentials locked"
        }

        let completeState: String
        if liteInstaller.hasSavedCompleteAccess {
            completeState = "Complete unlocked"
        } else {
            completeState = "Complete locked"
        }
        return "\(essentialsState) · \(completeState)"
    }

    private var lockedResolutionInput: ArkFileLockedContentResolutionInput {
        ArkFileLockedContentResolutionInput(
            installer: liteInstaller,
            hasAuthoritativeNoPurchase: liteInstaller.hasAuthoritativeNoPurchase,
            hasEssentialsAccess: hasEssentialsAccess,
            essentialsInstallNeedsRepair: essentialsInstallNeedsRepair,
            completeInstallNeedsRepair: completeInstallNeedsRepair
        )
    }

    private var hasEssentialsAccess: Bool {
        liteInstaller.hasSavedLiteAccess || Brand.hasDeveloperContentAuthToken
    }

    private func hasSavedAccess(for tier: ArkFileContentTier) -> Bool {
        tier == .complete ? liteInstaller.hasSavedCompleteAccess : hasEssentialsAccess
    }

    private var activeInstallNeedsRepair: Bool {
        liteInstaller.needsLiteRepair
            || ArkFileLocalContentLibrary.installedCatalogNeedsRepair(
                phase: liteInstaller.state.phase,
                installedCount: contentLibrary.installedCatalogItemCount,
                expectedCount: contentLibrary.expectedEssentialsItemCount,
                allowsDeveloperFixtureCatalog: Brand.allowsDeveloperFixtureCatalog
            )
    }

    private var essentialsInstallNeedsRepair: Bool {
        ArkFileContentPackInstaller.isActiveDownloadTier(
            .lite,
            activeTier: liteInstaller.state.tier
        ) && activeInstallNeedsRepair
    }

    private var completeInstallNeedsRepair: Bool {
        ArkFileContentPackInstaller.isActiveDownloadTier(
            .complete,
            activeTier: liteInstaller.state.tier
        ) && activeInstallNeedsRepair
    }

    private var blocksForAppleAccountCheck: Bool {
        ArkFilePurchasePresentation.shouldBlockForAppleAccountCheck(
            isCheckingApplePurchases: liteInstaller.isCheckingApplePurchases,
            hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
            hasEssentialsAccess: liteInstaller.hasSavedLiteAccess,
            hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasLocalPaidContent: hasLocalPaidContent
        )
    }

    private var hasLocalPaidContent: Bool {
        liteInstaller.hasInstalledOrPartialContent
            || contentLibrary.allLibraryItems.contains { item in
                item.isInstalled
                    && !item.isBundledSampleAsset
                    && item.requiredTier.isIOSInstallable
            }
    }

    private func handleLockedRestoreAction(_ route: ArkFileLockedContentRestoreRoute) {
        switch route {
        case .restore(let tier):
            beginRestore(tier: tier)
        case .restoreEssentialsThenReviewComplete:
            beginRestoreForCompletePurchase()
        }
    }

    private func beginPurchaseWithoutDownload(tier: ArkFileContentTier) {
        if liteInstaller.purchasePackWithoutDownload(tier: tier) {
            isAwaitingRestoreOutcome = true
        }
    }

    private func beginRestore(tier: ArkFileContentTier) {
        if startRestore(tier: tier) {
            pendingPurchaseTierAfterRestore = nil
        }
    }

    private func beginRestoreForCompletePurchase() {
        if startRestore(tier: .lite) {
            pendingPurchaseTierAfterRestore = .complete
        }
    }

    @discardableResult
    private func startRestore(tier: ArkFileContentTier) -> Bool {
        let didStart: Bool
        if tier == .complete {
            didStart = liteInstaller.restoreComplete()
        } else {
            didStart = liteInstaller.restoreOwnedPacks()
        }
        if didStart {
            isAwaitingRestoreOutcome = true
        }
        return didStart
    }

    private func chooseDownloadsAfterRestore(outcome: ArkFileContentRestoreOutcome) {
        let continuation = ArkFilePostRestoreContinuation.resolve(
            restoredTier: outcome.tier,
            requestedTier: outcome.requestedTier,
            pendingPurchaseTier: pendingPurchaseTierAfterRestore
        )
        pendingPurchaseTierAfterRestore = nil
        DispatchQueue.main.async {
            switch continuation {
            case .chooseDownloads(.complete):
                if detailItem == nil { showCompleteSelectionReview = true }
            case .chooseDownloads:
                if detailItem == nil { showEssentialsSelectionReview = true }
            case .continueCompletePurchase:
                beginPurchaseWithoutDownload(tier: .complete)
            }
        }
    }

    private var restoreSuccessActionTitle: String {
        pendingPurchaseTierAfterRestore == .complete
            ? "Review Upgrade Price"
            : detailItem == nil ? "Choose Downloads" : "Return to Title"
    }
}
#endif

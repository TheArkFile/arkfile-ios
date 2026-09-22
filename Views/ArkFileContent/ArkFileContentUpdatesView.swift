// This file is part of Kiwix for iOS & macOS.
// Distributed under the GNU General Public License, version 3 or later.

#if os(iOS)
import SwiftUI

/// A user-initiated catalog check and per-title download manager. Opening this
/// screen only reads local metadata; every network transfer needs an action.
@MainActor
struct ArkFileContentUpdatesView: View {
    @ObservedObject private var coordinator = ArkFileContentUpdateCoordinator.shared
    @ObservedObject private var installer = ArkFileContentPackInstaller.shared
    var initialTargetRelativePath: String?
    @State private var rows: [ContentRow] = []
    @State private var legacyIDs: Set<String> = []
    @State private var didFocusTarget = false
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var review: DownloadReview?
    @State private var removal: ContentRow?
    @State private var showCancel = false
    @State private var showCellularResume = false
    @State private var availableBytes: Int64?
    @State private var localMessage: String?

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All content", updates = "Updates & new", installed = "Downloaded", missing = "Not downloaded"
        var id: String { rawValue }
    }
    private struct ContentRow: Identifiable {
        let item: ArkFileContentRelease.Item
        let binding: ArkFileContentReleaseBinding
        let createdAt: String
        let contentBytes: Int64
        let downloadBytes: Int64
        let supported: Bool
        let offered: Bool
        let installed: ArkFileContentReleaseProvider.InstalledRevision?
        let isInstalled: Bool
        let isNew: Bool
        var id: String { item.itemID }
        var isUpdate: Bool { isInstalled && installed?.revisionID != item.revisionID }
        var status: String {
            if !supported { return "Requires App Update" }
            if !offered { return isInstalled ? "Installed · Download Unavailable" : "Download Unavailable" }
            if isUpdate { return "Update Available" }
            if isInstalled { return "Installed" }
            return isNew ? "New Content" : "Not Downloaded"
        }
    }
    private struct DownloadReview: Identifiable {
        let id = UUID()
        let row: ContentRow
        let replaced: [ArkFileContentReleaseProvider.InstalledRevision]
        let switchesVariant: Bool
        let redownload: Bool
    }

    var body: some View {
        List {
            Section {
                Text("Choose what to keep offline. Checking the catalog does not download or replace your content.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await coordinator.checkForUpdates(); await refreshLocalState() }
                } label: {
                    HStack {
                        Label("Check for Content Updates", systemImage: "arrow.clockwise")
                        Spacer()
                        if coordinator.isChecking { ProgressView() }
                    }
                }
                .disabled(coordinator.isChecking)
                .accessibilityIdentifier("arkfile_check_content_updates")
                if let availableBytes {
                    LabeledContent("Available storage", value: Self.bytes(availableBytes))
                        .font(.subheadline)
                }
                if let message = localMessage ?? coordinator.message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("arkfile_content_update_message")
                }
            }
            if let journal = coordinator.journal, !journal.isTerminal {
                progressSection(journal)
            }
            if !installer.hasSavedLiteAccess && !installer.hasSavedCompleteAccess {
                Section {
                    Text("Downloading requires the matching ArkFile purchase. Installed content remains readable offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Restore Purchases") { _ = installer.restoreOwnedPacks() }
                        .disabled(installer.isBusy || installer.isRestoringPurchases)
                }
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if filteredRows.isEmpty {
                ContentUnavailableView(
                    rows.isEmpty ? "Content catalog unavailable" : "No matching content",
                    systemImage: rows.isEmpty ? "books.vertical" : "magnifyingglass",
                    description: Text(rows.isEmpty
                        ? "Check for updates when online. Your downloaded library stays available."
                        : "Try another filter or search term.")
                )
            } else {
                Section {
                    ForEach(filteredRows) { row in contentRow(row) }
                } header: { Text("\(filteredRows.count) items") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Content Updates")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search titles and maps")
        .accessibilityIdentifier("arkfile_content_updates")
        .task { await refreshLocalState() }
        .onChange(of: coordinator.generation) { _, _ in Task { await refreshLocalState() } }
        .onChange(of: coordinator.isBusy) { _, _ in Task { await refreshLocalState() } }
        .sheet(item: $review) { selection in
            DownloadReviewSheet(review: selection, availableBytes: availableBytes) { mode, cellular in
                let request = ArkFileContentReleaseRequest(id: UUID(), binding: selection.row.binding,
                    tier: selection.row.item.minimumTier == "complete" ? .complete : .lite,
                    selections: [.init(itemID: selection.row.id,
                        revisionID: selection.row.item.revisionID, mode: mode)], confirmedAt: Date())
                coordinator.install(request: request, allowsCellular: cellular)
            }
        }
        .confirmationDialog("Remove this download?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { row in
            Button("Remove Download", role: .destructive) {
                coordinator.remove(itemID: row.id); removal = nil
            }
            Button("Keep Download", role: .cancel) { removal = nil }
        } message: { row in
            Text("\(row.item.catalog.name) will be unavailable offline. Saved links are kept. Downloading again needs internet access and a valid purchase\(row.offered ? "." : ", and this edition is currently unavailable for download.")")
        }
        .confirmationDialog("Cancel this content update?", isPresented: $showCancel, titleVisibility: .visible) {
            Button("Cancel & Remove Partial Download", role: .destructive) { Task { await coordinator.cancel() } }
            Button("Keep Update", role: .cancel) { }
        } message: {
            Text("Completed downloads stay available. If you chose to remove the old copy first, cancelling does not restore it. You can choose another download later.")
        }
        .confirmationDialog("Resume using cellular data?", isPresented: $showCellularResume, titleVisibility: .visible) {
            Button("Use Cellular Data") { coordinator.resume(allowsCellular: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This may use a large amount of data, including on Personal Hotspot or Low Data Mode. The exact edition already selected will resume.")
        }
    }

    private var filteredRows: [ContentRow] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .updates: matchesFilter = row.isUpdate || row.isNew
            case .installed: matchesFilter = row.isInstalled
            case .missing: matchesFilter = !row.isInstalled
            }
            return matchesFilter && (term.isEmpty || row.item.catalog.name.localizedCaseInsensitiveContains(term)
                || row.item.catalog.subcategory.localizedCaseInsensitiveContains(term))
        }
    }
    private var blocksNewOperation: Bool {
        coordinator.isBusy || installer.isBusy || coordinator.canResume
    }
    private func hasAccess(_ row: ContentRow) -> Bool {
        row.item.minimumTier == "complete" ? installer.hasSavedCompleteAccess
            : installer.hasSavedLiteAccess || installer.hasSavedCompleteAccess
    }
    @ViewBuilder private func contentRow(_ row: ContentRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.item.catalog.name).font(.headline)
            Text("\(row.status) · \(Self.bytes(row.contentBytes))")
                .font(.subheadline).foregroundStyle(row.isUpdate ? Color.arkInteractiveForeground : .secondary)
            if let summary = row.item.catalog.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let variant = row.item.catalog.variantLabel {
                Text(variant).font(.caption).foregroundStyle(.secondary)
            }
            if legacyIDs.contains(row.id) {
                Button("Verify Installed Edition") { coordinator.verifyLegacy(itemID: row.id) }
                    .disabled(blocksNewOperation)
                    .accessibilityIdentifier("arkfile_verify_legacy_\(row.id)")
                Text("Check the existing files on this device so this edition can be managed safely. This does not download content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if row.offered && row.supported {
                Button(row.isUpdate ? "Review Update" : row.isInstalled ? "Download This Edition Again" : "Review Download") {
                    prepareReview(row)
                }
                .buttonStyle(.bordered)
                .disabled(blocksNewOperation || !hasAccess(row))
                .accessibilityIdentifier("arkfile_review_content_\(row.id)")
                if !hasAccess(row) {
                    Text(row.item.minimumTier == "complete" ? "ArkFile Complete purchase required" : "ArkFile Essentials or Complete purchase required")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                NavigationLink("Source & Notice") { ArkFilePublicContentNoticeView(notice: row.item.publicNotice) }
                if row.isInstalled {
                    Spacer()
                    Button("Remove", role: .destructive) { removal = row }
                        .disabled(blocksNewOperation)
                }
            }
            .font(.subheadline)
            if row.isInstalled && (row.isUpdate || !row.offered) {
                Button("Download Installed Edition Again") { prepareInstalledReview(row) }
                    .font(.subheadline).disabled(blocksNewOperation || !hasAccess(row))
            }
        }
        .padding(.vertical, 6)
    }
    @ViewBuilder private func progressSection(_ journal: ArkFileContentReplacementJournal) -> some View {
        Section("Current download") {
            Text(journal.request.selections.compactMap { selection in
                rows.first { $0.id == selection.itemID }?.item.catalog.name
            }.joined(separator: ", ")).font(.headline)
            Text(Self.phaseLabel(journal.phase)).font(.subheadline)
            if coordinator.totalBytes > 0 {
                ProgressView(value: Double(min(coordinator.completedBytes, coordinator.totalBytes)), total: Double(coordinator.totalBytes))
                Text("\(Self.bytes(coordinator.completedBytes)) of \(Self.bytes(coordinator.totalBytes))")
                    .font(.caption).monospacedDigit()
            }
            if let message = journal.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !journal.oldFiles.isEmpty {
                Text("The old copy was removed or its removal is in progress. This content is unavailable offline until the replacement finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if coordinator.isBusy {
                    Button("Pause") { coordinator.pause() }
                        .disabled(!coordinator.canPause)
                } else {
                    Button(journal.requiresRecoveryBarrier ? "Finish Recovery" : journal.removeOnly ? "Finish Removal" : "Resume on Wi-Fi") { coordinator.resume() }
                    if !journal.removeOnly && !journal.requiresRecoveryBarrier {
                        Menu("More") { Button("Resume Using Cellular") { showCellularResume = true } }
                    }
                }
                Spacer()
                Button("Cancel", role: .destructive) { showCancel = true }
                    .disabled(!coordinator.canCancel)
            }
            .disabled(installer.isPerformingOtherOperation)
        }
        .accessibilityIdentifier("arkfile_content_update_progress")
    }
    private func prepareReview(_ row: ContentRow) {
        let installedIDs = coordinator.installedItemIDs()
        let replaced = coordinator.installed.values.filter { receipt in
            guard installedIDs.contains(receipt.itemID) else { return false }
            return receipt.itemID == row.id || (row.item.catalog.variantGroup != nil
                && receipt.catalog.variantGroup == row.item.catalog.variantGroup)
        }
        review = .init(row: row, replaced: replaced,
            switchesVariant: replaced.contains { $0.itemID != row.id }, redownload: row.isInstalled && !row.isUpdate)
    }
    private func prepareInstalledReview(_ row: ContentRow) {
        guard let receipt = row.installed,
              let verified = try? ArkFileContentReleaseProvider.shared.verifiedRelease(receipt.binding),
              let item = verified.release.item(row.id) else {
            localMessage = "The saved edition could not be verified. Check for content updates before trying again."
            return
        }
        let saved = ContentRow(item: item, binding: verified.binding, createdAt: verified.release.createdAt,
            contentBytes: verified.release.itemBytes(item),
            downloadBytes: verified.release.files(for: Set(item.groupIDs)).reduce(0) { $0 + $1.sizeBytes },
            supported: verified.release.isSupported(item), offered: true, installed: receipt, isInstalled: true, isNew: false)
        review = .init(row: saved, replaced: [receipt], switchesVariant: false, redownload: true)
    }
    private func refreshLocalState() async {
        do { try coordinator.migrateKnownInstalledContent(); localMessage = nil }
        catch { localMessage = error.localizedDescription }
        let snapshot = ArkFileContentReleaseProvider.shared.snapshot
        let installedIDs = coordinator.installedItemIDs()
        legacyIDs = coordinator.legacyItemIDs()
        let baselinePaths = Set((try? ArkFileContentCatalog.loadBundled().allItems.map(\.normalizedRelativePath)) ?? [])
        var result: [ContentRow] = []
        if let verified = snapshot.available {
            result = verified.release.items.map { item in
                let installed = snapshot.installed[item.itemID]
                return ContentRow(item: item, binding: verified.binding, createdAt: verified.release.createdAt,
                    contentBytes: verified.release.itemBytes(item),
                    downloadBytes: verified.release.files(for: Set(item.groupIDs)).reduce(0) { $0 + $1.sizeBytes },
                    supported: verified.release.isSupported(item), offered: item.availability == "available",
                    installed: installed, isInstalled: installedIDs.contains(item.itemID),
                    isNew: installed == nil && !baselinePaths.contains(item.catalog.relativePath))
            }
        }
        let currentIDs = Set(result.map(\.id))
        for receipt in snapshot.installed.values where !currentIDs.contains(receipt.itemID) {
            guard let verified = try? ArkFileContentReleaseProvider.shared.verifiedRelease(receipt.binding),
                  let item = verified.release.item(receipt.itemID) else { continue }
            result.append(.init(item: item, binding: verified.binding, createdAt: verified.release.createdAt,
                contentBytes: verified.release.itemBytes(item),
                downloadBytes: verified.release.files(for: Set(item.groupIDs)).reduce(0) { $0 + $1.sizeBytes },
                supported: verified.release.isSupported(item), offered: false, installed: receipt,
                isInstalled: installedIDs.contains(item.itemID), isNew: false))
        }
        rows = result.sorted { $0.item.catalog.name.localizedStandardCompare($1.item.catalog.name) == .orderedAscending }
        if !didFocusTarget, let path = initialTargetRelativePath {
            didFocusTarget = true
            let normalized = ArkFileContentReleaseVerifier.canonicalPath(path)
            if let row = rows.first(where: { ArkFileContentReleaseVerifier.canonicalPath($0.item.catalog.relativePath) == normalized }) {
                search = row.item.catalog.name
            }
        }
        availableBytes = await Task.detached(priority: .utility) {
            try? ArkFileContentStoragePreflight.availableCapacityForDownload()
        }.value
    }
    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    private static func phaseLabel(_ phase: ArkFileContentReplacementJournal.Phase) -> String {
        switch phase {
        case .prepared: "Preparing download"
        case .quiescing: "Finishing active readers"
        case .removing, .recoveryPending: "Finishing removal of the old copy"
        case .removed: "Ready to download the replacement"
        case .downloading: "Downloading"
        case .verifying: "Checking downloaded files"
        case .activating: "Making content available offline"
        case .installed: "Ready offline"
        case .paused: "Paused"
        case .cancelled: "Cancelled"
        case .failed: "Download needs attention"
        }
    }

    private struct DownloadReviewSheet: View {
        let review: DownloadReview
        let availableBytes: Int64?
        let start: (ArkFileContentRevisionSelection.Mode, Bool) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var mode: ArkFileContentRevisionSelection.Mode = .staged
        @State private var useCellular = false
        @State private var confirmedRemoval = false
        private var supportsDeleteFirst: Bool { review.row.item.catalog.type == "zim" }
        private var removesFirst: Bool { supportsDeleteFirst && (review.switchesVariant || mode == .deleteFirst) }
        private var additionalFreeBytes: Int64? {
            guard let availableBytes else { return nil }
            let reclaimable = removesFirst ? review.replaced.flatMap(\.files).reduce(Int64(0)) { $0 + $1.sizeBytes } : 0
            let required = ArkFileContentReplacementStoragePolicy.requiredFreeBytes(
                remainingBytes: review.row.downloadBytes, reclaimableBytes: reclaimable)
            return max(0, required - max(0, availableBytes))
        }
        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Text(review.row.item.catalog.name).font(.headline)
                        Text(review.row.item.catalog.summary ?? review.row.item.catalog.subcategory)
                        LabeledContent("Available copy", value: bytes(review.row.contentBytes))
                        LabeledContent("Download", value: "Up to \(bytes(review.row.downloadBytes))")
                        if let date = ISO8601DateFormatter().date(from: review.row.createdAt) {
                            LabeledContent("Catalog published", value: date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let availableBytes { LabeledContent("Free storage", value: bytes(availableBytes)) }
                        if let additionalFreeBytes {
                            LabeledContent("Additional free space needed",
                                           value: additionalFreeBytes == 0 ? "None estimated" : "Up to \(bytes(additionalFreeBytes))")
                            Text("This estimate includes a download buffer. ArkFile checks available space again before downloading.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !review.replaced.isEmpty {
                        Section("Downloaded content") {
                            ForEach(review.replaced, id: \.itemID) { receipt in
                                LabeledContent(receipt.catalog.name, value: bytes(receipt.files.reduce(0) { $0 + $1.sizeBytes }))
                            }
                            if review.redownload { Text("This downloads the exact same edition again.") }
                            if review.switchesVariant && supportsDeleteFirst {
                                Text("Switching variants removes the downloaded variant before downloading your new choice.")
                            } else if supportsDeleteFirst {
                                Picker("Replacement", selection: $mode) {
                                    Text("Keep current copy until ready").tag(ArkFileContentRevisionSelection.Mode.staged)
                                    Text("Remove current copy first").tag(ArkFileContentRevisionSelection.Mode.deleteFirst)
                                }
                                .pickerStyle(.inline)
                            }
                            if removesFirst {
                                Text("The old copy will be deleted after ArkFile confirms the replacement is available to download. It will be unavailable offline until the new copy finishes. Pausing or cancelling will not restore the deleted copy.")
                                    .foregroundStyle(.secondary)
                                Toggle("I understand this content will be temporarily unavailable", isOn: $confirmedRemoval)
                                    .accessibilityIdentifier("arkfile_confirm_content_removal")
                            } else {
                                Text("The downloaded copy stays available while its replacement downloads. Your device needs room for both copies until the replacement is ready.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Toggle("Allow Cellular Data", isOn: $useCellular)
                    } footer: {
                        Text("Large downloads can use substantial data. This also applies to Personal Hotspot and Low Data Mode. Leave this off to use the standard Wi-Fi check.")
                    }
                    Section {
                        NavigationLink("Source & Notice") { ArkFilePublicContentNoticeView(notice: review.row.item.publicNotice) }
                        Button(removesFirst ? "Remove Old Copy & Download" : review.redownload ? "Download This Edition Again" : "Download Selected Content") {
                            start(removesFirst ? .deleteFirst : .staged, useCellular)
                            dismiss()
                        }
                        .disabled(removesFirst && !confirmedRemoval)
                        .accessibilityIdentifier("arkfile_confirm_content_download")
                    } footer: {
                        Text("Your saved links stay on this device. ArkFile checks your purchase, download availability, and storage before transferring content.")
                    }
                }
                .navigationTitle(review.switchesVariant ? "Review Variant Change" : review.row.isUpdate ? "Review Content Update" : "Review Download")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }
}

struct ArkFilePublicContentNoticeView: View {
    let notice: ArkFileContentPublicNotice
    var body: some View {
        List {
            Section("Source") {
                Text(notice.sourceTitle).font(.headline)
                if !notice.creators.isEmpty { Text(notice.creators.joined(separator: ", ")) }
                if let publisher = notice.publisher { LabeledContent("Publisher", value: publisher) }
                if let value = notice.canonicalURL, let url = URL(string: value) { Link("Original Source", destination: url) }
            }
            Section("Attribution") { Text(notice.attributionText) }
            Section("Changes") { Text(notice.changesMade) }
            Section("Rights & License") {
                Text(notice.rightsSummary)
                if let name = notice.licenseName { Text(name) }
                if let value = notice.licenseURL, let url = URL(string: value) { Link("License Terms", destination: url) }
                ForEach(notice.internalNoticePaths ?? [], id: \.self) { Text("Included notice: \($0)").font(.caption) }
            }
        }
        .navigationTitle("Source & Notice")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

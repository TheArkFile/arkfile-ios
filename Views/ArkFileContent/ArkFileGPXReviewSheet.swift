// This file is part of Kiwix for iOS & macOS.
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

struct ArkFileGPXReviewRequest: Identifiable {
    enum Mode {
        case importFile
        case shareFile
    }

    let id: UUID
    let mode: Mode
    let document: ArkFileMapGPXDocument
    let filename: String

    init(id: UUID = UUID(), mode: Mode, document: ArkFileMapGPXDocument, filename: String) {
        self.id = id
        self.mode = mode
        self.document = document
        self.filename = filename
    }
}

struct ArkFileGPXImportResult {
    let waypoints: [ArkFileMapWaypoint]
    let tracks: [ArkFileMapTrack]
    let summary: String
}

/// Reviews an already-parsed local document. Selecting, previewing, or closing
/// this sheet never acquires map content or requests location permission.
@MainActor
struct ArkFileGPXReviewSheet: View {
    let request: ArkFileGPXReviewRequest
    let onShowOnMap: (ArkFileGPXImportResult) -> Void

    @ObservedObject private var waypointStore: ArkFileMapWaypointStore
    @ObservedObject private var trackRecorder: ArkFileMapTrackRecorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPreviewExpanded = false
    @State private var selectedPlaces = Set<String>()
    @State private var selectedPaths = Set<String>()
    @State private var duplicatePlaces = Set<String>()
    @State private var duplicatePaths = Set<String>()
    @State private var repeatedPlaces = Set<String>()
    @State private var repeatedPaths = Set<String>()
    @State private var capacityPlaces = Set<String>()
    @State private var capacityPaths = Set<String>()
    @State private var plannedPlaces: [ArkFileMapWaypoint] = []
    @State private var plannedPaths: [ArkFileMapTrack] = []
    @State private var geometry = ArkFileGPXPreviewGeometry()
    @State private var pathDetails: [String: String] = [:]
    @State private var isPrepared = false
    @State private var storeRevision = 0
    @State private var isClosing = false
    @State private var isWorking = false
    @State private var isRefreshing = false
    @State private var reviewNotice: String?
    @State private var failureMessage: String?
    @State private var outcome: ImportOutcome?
    @State private var shareFile: ShareFile?
    @State private var operation: Task<Void, Never>?
    @State private var refreshOperation: Task<Void, Never>?

    init(
        request: ArkFileGPXReviewRequest,
        waypointStore: ArkFileMapWaypointStore = .shared,
        trackRecorder: ArkFileMapTrackRecorder = .shared,
        onShowOnMap: @escaping (ArkFileGPXImportResult) -> Void
    ) {
        self.request = request
        self.waypointStore = waypointStore
        self.trackRecorder = trackRecorder
        self.onShowOnMap = onShowOnMap
    }

    private var isImport: Bool { request.mode == .importFile }
    private var isInteractionBusy: Bool { isWorking || isRefreshing }
    private var selectedWaypoints: [ArkFileMapWaypoint] {
        request.document.waypoints.filter { selectedPlaces.contains($0.id) }
    }
    private var selectedTracks: [ArkFileMapTrack] {
        request.document.tracks.filter { selectedPaths.contains($0.id) }
    }
    private var selectedCount: Int { selectedPlaces.count + selectedPaths.count }
    private var importCount: Int { plannedPlaces.count + plannedPaths.count }
    private var duplicateCount: Int { duplicatePlaces.count + duplicatePaths.count }
    private var capacityCount: Int { capacityPlaces.count + capacityPaths.count }
    private var selectableCount: Int {
        request.document.waypoints.count + request.document.tracks.count - duplicateCount
    }

    var body: some View {
        NavigationStack {
            Group {
                if let outcome {
                    resultContent(outcome)
                } else if isPrepared {
                    selectionContent
                } else {
                    ProgressView("Preparing your items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("arkfile_gpx_review")
            .background(Color.arkAppSurface)
            .navigationTitle(isImport ? "Import map items" : "Share map items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isClosing = true
                        operation?.cancel()
                        refreshOperation?.cancel()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("arkfile_gpx_close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionFooter
            }
        }
        .tint(Color.arkInteractiveForeground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await prepareIfNeeded() }
        .onChange(of: waypointStore.waypoints) { _, _ in refreshAfterStoreChange() }
        .onChange(of: trackRecorder.savedTracks) { _, _ in refreshAfterStoreChange() }
        .onDisappear {
            operation?.cancel()
            refreshOperation?.cancel()
        }
        .sheet(item: $shareFile) { file in
            ArkFileGPXActivityView(url: file.url)
        }
        .alert("Could not \(isImport ? "import" : "share") these items", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "Please try again.")
        }
    }

    private var selectionContent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.filename)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("GPX files transfer pins and paths; map downloads are separate.")
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                }
                .padding(.vertical, 4)
                DisclosureGroup("Preview selection", isExpanded: $isPreviewExpanded) {
                    preview
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("arkfile_gpx_toggle_preview")
            }
            .listRowBackground(Color.arkAppSurface)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectionSummary)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("arkfile_gpx_selection_summary")
                    if isImport, duplicateCount > 0 {
                        Text("\(itemCount(duplicateCount)) already saved or repeated in this file will be left out. Matching items are recognized even if their names changed.")
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    if let reviewNotice {
                        informationLabel(reviewNotice)
                    }
                    if capacityCount > 0 {
                        informationLabel("There is room for \(itemCount(importCount)) in this selection. \(itemCount(capacityCount)) will not be imported. Choose fewer items or make room in your saved places and trails.")
                    }
                    ForEach(Array(request.document.warnings.enumerated()), id: \.offset) { _, warning in
                        informationLabel(warning)
                    }
                }
                HStack(spacing: 20) {
                    Button("Select All") { selectAll() }
                        .disabled(selectableCount == 0 || selectedCount == selectableCount || isInteractionBusy)
                        .accessibilityIdentifier("arkfile_gpx_select_all")
                    Button("Select None") {
                        selectedPlaces = []
                        selectedPaths = []
                        reviewNotice = nil
                        refreshSelectedPlan()
                    }
                    .disabled(selectedCount == 0 || isInteractionBusy)
                    .accessibilityIdentifier("arkfile_gpx_select_none")
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
            .listRowBackground(Color.arkAppSurface)

            if !request.document.waypoints.isEmpty {
                Section("Places") {
                    ForEach(Array(request.document.waypoints.enumerated()), id: \.element.id) { index, place in
                        selectionRow(
                            name: place.name,
                            detail: place.coordinateText,
                            systemImage: place.kind?.systemImage ?? "mappin.circle.fill",
                            selected: selectedPlaces.contains(place.id),
                            duplicate: duplicatePlaces.contains(place.id),
                            repeated: repeatedPlaces.contains(place.id),
                            atCapacity: capacityPlaces.contains(place.id),
                            identifier: "arkfile_gpx_place_\(index)"
                        ) {
                            toggle(place.id, isPath: false)
                        }
                    }
                }
                .listRowBackground(Color.arkAppSurface)
            }
            if !request.document.tracks.isEmpty {
                Section("Trails & routes") {
                    ForEach(Array(request.document.tracks.enumerated()), id: \.element.id) { index, track in
                        selectionRow(
                            name: track.name,
                            detail: pathDetails[track.id] ?? track.kind.displayName,
                            systemImage: track.kind == .plannedRoute ? "point.topleft.down.to.point.bottomright.curvepath" : "figure.walk",
                            selected: selectedPaths.contains(track.id),
                            duplicate: duplicatePaths.contains(track.id),
                            repeated: repeatedPaths.contains(track.id),
                            atCapacity: capacityPaths.contains(track.id),
                            identifier: "arkfile_gpx_path_\(index)"
                        ) {
                            toggle(track.id, isPath: true)
                        }
                    }
                }
                .listRowBackground(Color.arkAppSurface)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Color.arkTextPrimary)
    }

    private var preview: some View {
        ArkFileGPXGeometryPreview(
            geometry: geometry,
            selectedPlaces: selectedPlaces,
            selectedPaths: selectedPaths,
            summary: selectionSummary
        )
        .padding(.vertical, 4)
    }

    private var selectionSummary: String {
        selectedCount == 0 ? "No items selected" : "\(countSummary(places: selectedWaypoints, paths: selectedTracks)) selected"
    }

    private func informationLabel(_ message: String) -> some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(Color.arkTextMuted)
    }

    private func selectionRow(
        name: String,
        detail: String,
        systemImage: String,
        selected: Bool,
        duplicate: Bool,
        repeated: Bool,
        atCapacity: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let state = duplicate ? (repeated ? "Duplicate in this file" : "Already saved")
            : (selected ? "Selected" : "Not selected")
        return Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: duplicate ? "checkmark.seal" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(duplicate ? Color.arkTextMuted : Color.arkInteractiveForeground)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(detail, systemImage: systemImage)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if duplicate || atCapacity {
                        Text(duplicate ? state : "Will not fit in this selection")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.arkTextMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(duplicate || isInteractionBusy)
        .accessibilityLabel("\(name), \(detail)\(atCapacity ? ", will not fit in this selection" : "")")
        .accessibilityValue(state)
        .accessibilityHint(duplicate ? "This item will not be imported again." : "Double-tap to change selection.")
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var actionFooter: some View {
        VStack(spacing: 10) {
            if let outcome {
                if !outcome.result.waypoints.isEmpty || !outcome.result.tracks.isEmpty {
                    primaryButton("Show on map", systemImage: "map", identifier: "arkfile_gpx_show_on_map") {
                        onShowOnMap(outcome.result)
                        dismiss()
                    }
                }
            } else {
                if selectedCount == 0 {
                    Text(selectableCount == 0 && isImport
                         ? "These items are already saved or repeated in this file."
                         : "Select the items you want to \(isImport ? "import" : "share").")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isImport, capacityCount > 0 {
                    Text(importCount == 0 ? LocalString.arkfile_content_offline_map_gpx_import_no_room
                         : "\(itemCount(capacityCount)) will be skipped because there is not enough room for all selected items.")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                primaryButton(
                    isRefreshing ? "Updating selection…"
                        : isWorking ? (isImport ? "Importing…" : "Preparing…")
                        : "\(isImport ? "Import" : "Share") \(itemCount(isImport ? importCount : selectedCount))",
                    systemImage: isImport ? "square.and.arrow.down" : "square.and.arrow.up",
                    identifier: "arkfile_gpx_primary_action"
                ) {
                    beginPrimaryAction()
                }
                .disabled(!isPrepared || isInteractionBusy || (isImport ? importCount == 0 : selectedCount == 0))
                .opacity(!isPrepared || (isImport ? importCount == 0 : selectedCount == 0) ? 0.45 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if isInteractionBusy { ProgressView().tint(.white) }
                else if !dynamicTypeSize.isAccessibilitySize { Image(systemName: systemImage) }
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.arkPrimary, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func resultContent(_ outcome: ImportOutcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: outcome.isPartial ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .accessibilityHidden(true)
                Text(outcome.isPartial ? "Some items were saved" : "Saved to your map")
                    .font(.title2.bold())
                Text(outcome.result.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_gpx_result")
                ArkFileGPXGeometryPreview(
                    geometry: geometry,
                    selectedPlaces: Set(outcome.result.waypoints.map(\.id)),
                    selectedPaths: Set(outcome.result.tracks.map(\.id)),
                    summary: outcome.result.summary
                )
                Text("Saved places and paths are available offline. Download maps separately when you need more map detail.")
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.arkTextPrimary)
    }

    private func prepareIfNeeded() async {
        guard !isPrepared else { return }
        while !Task.isCancelled && !isClosing {
            let document = request.document
            let existingPlaces = waypointStore.waypoints
            let existingPaths = trackRecorder.savedTracks
            let revision = storeRevision
            let importing = isImport
            let work = Task.detached(priority: .userInitiated) {
                try ArkFileGPXPreparedReview(
                    document: document, existingPlaces: existingPlaces,
                    existingPaths: existingPaths, isImport: importing
                )
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled, !isClosing else { return }
                // If saved items changed while the snapshot was being prepared,
                // classify against the new stores before enabling confirmation.
                guard revision == storeRevision else { continue }
                geometry = prepared.geometry
                pathDetails = prepared.pathDetails
                repeatedPlaces = prepared.repeatedPlaces
                repeatedPaths = prepared.repeatedPaths
                duplicatePlaces = prepared.duplicatePlaces
                duplicatePaths = prepared.duplicatePaths
                isPrepared = true
                selectAll()
                return
            } catch {
                // Preparation only throws for cancellation. Closing the sheet
                // never changes either store or presents a late error.
                return
            }
        }
    }


    private func selectAll() {
        selectedPlaces = Set(request.document.waypoints.map(\.id)).subtracting(duplicatePlaces)
        selectedPaths = Set(request.document.tracks.map(\.id)).subtracting(duplicatePaths)
        reviewNotice = nil
        refreshSelectedPlan()
    }

    private func toggle(_ id: String, isPath: Bool) {
        if isPath {
            if selectedPaths.contains(id) { selectedPaths.remove(id) }
            else { selectedPaths.insert(id) }
        } else {
            if selectedPlaces.contains(id) { selectedPlaces.remove(id) }
            else { selectedPlaces.insert(id) }
        }
        reviewNotice = nil
        refreshSelectedPlan()
    }

    private func refreshAfterStoreChange() {
        storeRevision += 1
        guard isPrepared, isImport, !isWorking, outcome == nil, !isClosing else { return }
        refreshOperation?.cancel()
        isRefreshing = true
        refreshOperation = Task { @MainActor in
            await refreshReviewPreservingSelection()
            if !Task.isCancelled { isRefreshing = false }
        }
    }

    private func refreshReviewPreservingSelection() async {
        let document = request.document
        while !Task.isCancelled && !isClosing {
            let revision = storeRevision
            let existingPlaces = waypointStore.waypoints
            let existingPaths = trackRecorder.savedTracks
            let work = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let places = ArkFileMapGPX.planWaypoints(document.waypoints, existing: existingPlaces).duplicateIDs
                try Task.checkCancellation()
                let paths = ArkFileMapGPX.planTracks(document.tracks, existing: existingPaths).duplicateIDs
                return (places, paths)
            }
            do {
                let duplicates = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled, !isClosing else { return }
                guard revision == storeRevision else { continue }
                duplicatePlaces = duplicates.0
                duplicatePaths = duplicates.1
                selectedPlaces.subtract(duplicatePlaces)
                selectedPaths.subtract(duplicatePaths)
                refreshSelectedPlan()
                reviewNotice = "Your saved items changed. Review the updated selection before importing."
                return
            } catch {
                return
            }
        }
    }

    private func recheckChangedSelection() async {
        isRefreshing = true
        await refreshReviewPreservingSelection()
        isRefreshing = false
    }

    private func refreshSelectedPlan() {
        guard isImport else { return }
        // Duplicate classification is cached independently of selection. A tap
        // only changes the available-slot projection, never rehashes long paths.
        // The stores' authoritative planners run again before confirmation.
        let places = selectedWaypoints.filter { !duplicatePlaces.contains($0.id) }
        let paths = selectedTracks.filter { !duplicatePaths.contains($0.id) }
        let placeSlots = max(0, ArkFileMapWaypointStore.maxWaypoints - waypointStore.waypoints.count)
        let pathSlots = max(0, ArkFileMapTrackRecorder.maximumSavedTracks - trackRecorder.savedTracks.count)
        plannedPlaces = Array(places.prefix(placeSlots))
        plannedPaths = Array(paths.prefix(pathSlots))
        capacityPlaces = Set(places.dropFirst(placeSlots).map(\.id))
        capacityPaths = Set(paths.dropFirst(pathSlots).map(\.id))
    }

    private func beginPrimaryAction() {
        guard !isInteractionBusy, !isClosing else { return }
        isWorking = true
        operation = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { isWorking = false; return }
            if isImport { await commitImport() }
            else { await prepareShare() }
            isWorking = false
        }
    }

    private func commitImport() async {
        guard importCount > 0 else { return }
        let previouslyPlanned = (Set(plannedPlaces.map(\.id)), Set(plannedPaths.map(\.id)))
        let previousCapacity = (capacityPlaces, capacityPaths)
        let candidates = (selectedWaypoints, selectedTracks)
        let existingPlaces = waypointStore.waypoints
        let existingPaths = trackRecorder.savedTracks
        let revision = storeRevision
        let skippedDuplicates = duplicateCount
        let notSelected = max(0, selectableCount - selectedCount)
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let paths = try ArkFileMapGPX.prepareTracks(candidates.1, existing: existingPaths)
            try Task.checkCancellation()
            let places = try ArkFileMapGPX.prepareWaypoints(candidates.0, existing: existingPlaces)
            try Task.checkCancellation()
            return ArkFileGPXPreparedSelection(places: places, paths: paths)
        }
        var importedPaths: [ArkFileMapTrack] = []
        do {
            let prepared = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, !isClosing else { return }
            // Validate both snapshots before either store writes. Their apply
            // methods also reject a stale snapshot instead of replanning here.
            guard revision == storeRevision,
                  waypointStore.waypoints == prepared.places.existingItems,
                  trackRecorder.savedTracks == prepared.paths.existingItems,
                  previouslyPlanned.0 == Set(prepared.places.plan.accepted.map(\.id)),
                  previouslyPlanned.1 == Set(prepared.paths.plan.accepted.map(\.id)),
                  previousCapacity.0 == prepared.places.plan.capacitySkippedIDs,
                  previousCapacity.1 == prepared.paths.plan.capacitySkippedIDs else {
                await recheckChangedSelection()
                return
            }
            // Only the short persistence/publication step remains on the main
            // actor. Planning and JSON encoding have already completed above.
            let paths = try trackRecorder.applyPreparedImport(prepared.paths)
            importedPaths = paths.accepted
            let places = try waypointStore.applyPreparedImport(prepared.places)
            let summary = importSummary(
                places: places.accepted, paths: importedPaths,
                duplicates: skippedDuplicates + paths.duplicateCount + places.duplicateCount,
                capacity: paths.capacitySkippedCount + places.capacitySkippedCount,
                unselected: notSelected
            )
            outcome = ImportOutcome(
                result: ArkFileGPXImportResult(waypoints: places.accepted, tracks: importedPaths, summary: summary),
                isPartial: false
            )
        } catch is CancellationError {
            return
        } catch ArkFileMapImportError.storeChanged {
            if importedPaths.isEmpty {
                await recheckChangedSelection()
            } else {
                showImportFailure(importedPaths: importedPaths)
            }
        } catch {
            guard !Task.isCancelled, !isClosing else { return }
            showImportFailure(importedPaths: importedPaths)
        }
    }

    private func showImportFailure(importedPaths: [ArkFileMapTrack]) {
        if !importedPaths.isEmpty {
            let summary = "Imported \(countSummary(places: [], paths: importedPaths)). Places could not be saved. Close and try this file again; the paths already saved will be recognized."
            outcome = ImportOutcome(
                result: ArkFileGPXImportResult(waypoints: [], tracks: importedPaths, summary: summary),
                isPartial: true
            )
        } else {
            failureMessage = "Nothing was imported. ArkFile could not save the selected items on this device. Your existing saved items have not changed. Please try again."
        }
    }

    private func prepareShare() async {
        guard selectedCount > 0 else { return }
        let places = selectedWaypoints
        let paths = selectedTracks
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try ArkFileMapGPX.temporaryExportURL(waypoints: places, tracks: paths)
        }
        do {
            let url = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            // A completed export may outlive this review or its share extension.
            // Keep it for the exporter's age-based cleanup even after cancellation.
            guard !Task.isCancelled, !isClosing else { return }
            shareFile = ShareFile(url: url)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !isClosing else { return }
            failureMessage = "ArkFile could not prepare the selected items as a GPX file. Your saved items have not changed. Please try again."
        }
    }

    private func importSummary(
        places: [ArkFileMapWaypoint], paths: [ArkFileMapTrack],
        duplicates: Int, capacity: Int, unselected: Int
    ) -> String {
        let imported = !places.isEmpty && !paths.isEmpty && paths.allSatisfy { $0.kind == .recordedTrail }
            ? LocalString.arkfile_content_offline_map_gpx_imported_notice(withArgs: placeCountText(places.count), trailCountText(paths.count))
            : "Imported \(countSummary(places: places, paths: paths))."
        var sentences = [imported]
        if duplicates > 0 { sentences.append("\(itemCount(duplicates)) already saved or repeated in the file were left out.") }
        if capacity > 0 { sentences.append("\(itemCount(capacity)) could not fit and were not imported.") }
        if unselected > 0 { sentences.append("\(itemCount(unselected)) left unselected.") }
        return sentences.joined(separator: " ")
    }

    private func placeCountText(_ count: Int) -> String {
        count == 1 ? LocalString.arkfile_content_offline_map_gpx_waypoint_count_one
            : LocalString.arkfile_content_offline_map_gpx_waypoint_count_many(withArgs: count)
    }

    private func trailCountText(_ count: Int) -> String {
        count == 1 ? LocalString.arkfile_content_offline_map_gpx_trail_count_one
            : LocalString.arkfile_content_offline_map_gpx_trail_count_many(withArgs: count)
    }

    private func itemCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "item" : "items")"
    }

    private func countSummary(places: [ArkFileMapWaypoint], paths: [ArkFileMapTrack]) -> String {
        var parts: [String] = []
        if !places.isEmpty { parts.append(placeCountText(places.count)) }
        let trails = paths.filter { $0.kind == .recordedTrail }.count
        let routes = paths.count - trails
        if trails > 0 { parts.append(trailCountText(trails)) }
        if routes > 0 { parts.append("\(routes.formatted()) \(routes == 1 ? "route" : "routes")") }
        return parts.isEmpty ? "0 items" : parts.joined(separator: " and ")
    }

    private struct ImportOutcome {
        let result: ArkFileGPXImportResult
        let isPartial: Bool
    }

    private struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }
}

private struct ArkFileGPXActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ArkFileGPXPreparedSelection: Sendable {
    let places: ArkFileMapPreparedImport<ArkFileMapWaypoint>
    let paths: ArkFileMapPreparedImport<ArkFileMapTrack>
}

/// Value-only work prepared away from the main actor. Selection changes reuse
/// this geometry and duplicate classification instead of rescanning full paths.
private struct ArkFileGPXPreparedReview: Sendable {
    let geometry: ArkFileGPXPreviewGeometry
    let pathDetails: [String: String]
    let repeatedPlaces: Set<String>
    let repeatedPaths: Set<String>
    let duplicatePlaces: Set<String>
    let duplicatePaths: Set<String>

    init(
        document: ArkFileMapGPXDocument,
        existingPlaces: [ArkFileMapWaypoint],
        existingPaths: [ArkFileMapTrack],
        isImport: Bool
    ) throws {
        try Task.checkCancellation()
        geometry = ArkFileGPXPreviewGeometry(document: document)
        try Task.checkCancellation()
        var details: [String: String] = [:]
        for track in document.tracks {
            try Task.checkCancellation()
            var parts = [track.kind.displayName]
            let meters = track.totalDistanceMeters
            if meters > 0 {
                parts.append(Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
            }
            if track.segmentStartIndices.count > 1 {
                parts.append("\(track.segmentStartIndices.count.formatted()) separate segments")
            }
            details[track.id] = parts.joined(separator: " · ")
        }
        pathDetails = details
        if isImport {
            try Task.checkCancellation()
            repeatedPlaces = ArkFileMapGPX.planWaypoints(document.waypoints, existing: [], capacity: .max).duplicateIDs
            repeatedPaths = ArkFileMapGPX.planTracks(document.tracks, existing: [], capacity: .max).duplicateIDs
            try Task.checkCancellation()
            duplicatePlaces = ArkFileMapGPX.planWaypoints(document.waypoints, existing: existingPlaces).duplicateIDs
            duplicatePaths = ArkFileMapGPX.planTracks(document.tracks, existing: existingPaths).duplicateIDs
        } else {
            repeatedPlaces = []
            repeatedPaths = []
            duplicatePlaces = []
            duplicatePaths = []
        }
        try Task.checkCancellation()
    }
}

private struct ArkFileGPXPreviewGeometry: Sendable {
    struct Place: Sendable {
        let id: String
        let point: CGPoint
    }
    struct Trail: Sendable {
        let id: String
        let isRoute: Bool
        let segments: [[CGPoint]]
    }
    var places: [Place] = []
    var paths: [Trail] = []
    var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    init() {}

    init(document: ArkFileMapGPXDocument) {
        let sampled = document.tracks.map { track in (track, Self.sampledSegments(track.segments)) }
        let longitudes = document.waypoints.map(\.longitude)
            + sampled.flatMap { $0.1.flatMap { $0.map(\.longitude) } }
        let normalized = longitudes.map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var origin = normalized.first ?? 0
        var largestGap = -Double.infinity
        // Put the projection seam in the largest empty longitude interval so a
        // path crossing the date line stays compact in the preview.
        for index in normalized.indices {
            let next = index + 1 < normalized.count ? normalized[index + 1] : normalized[0] + 360
            if next - normalized[index] > largestGap {
                largestGap = next - normalized[index]
                origin = next.truncatingRemainder(dividingBy: 360)
            }
        }
        func project(latitude: Double, longitude: Double) -> CGPoint {
            var longitude = (longitude.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            if longitude < origin { longitude += 360 }
            let latitude = max(-85, min(85, latitude)) * .pi / 180
            return CGPoint(x: (longitude - origin) / 360, y: -log(tan(.pi / 4 + latitude / 2)) / (2 * .pi))
        }
        places = document.waypoints.map { Place(id: $0.id, point: project(latitude: $0.latitude, longitude: $0.longitude)) }
        paths = sampled.map { track, segments in
            Trail(id: track.id, isRoute: track.kind == .plannedRoute, segments: segments.map { segment in
                segment.map { project(latitude: $0.latitude, longitude: $0.longitude) }
            })
        }
        let points = places.map(\.point) + paths.flatMap { $0.segments.flatMap { $0 } }
        if let first = points.first {
            let minX = points.reduce(first.x) { min($0, $1.x) }
            let maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }
            let maxY = points.reduce(first.y) { max($0, $1.y) }
            let width = max(0.00002, maxX - minX)
            let height = max(0.00002, maxY - minY)
            bounds = CGRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
        }
    }

    private static func sampledSegments(_ allSegments: [[ArkFileTrackPoint]]) -> [[ArkFileTrackPoint]] {
        let nonempty = allSegments.filter { !$0.isEmpty }
        let segments: [[ArkFileTrackPoint]]
        if nonempty.count > 250 {
            segments = (0..<250).map { nonempty[$0 * (nonempty.count - 1) / 249] }
        } else {
            segments = nonempty
        }
        let budget = max(2, 500 / max(1, segments.count))
        return segments.map { segment in
            guard segment.count > budget else { return segment }
            return (0..<budget).map { segment[$0 * (segment.count - 1) / (budget - 1)] }
        }
    }
}

private struct ArkFileGPXGeometryPreview: View {
    let geometry: ArkFileGPXPreviewGeometry
    let selectedPlaces: Set<String>
    let selectedPaths: Set<String>
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Places and paths preview")
                .font(.subheadline.weight(.semibold))
            Canvas { context, size in
                var grid = Path()
                for fraction in 1..<5 {
                    let x = size.width * CGFloat(fraction) / 5
                    let y = size.height * CGFloat(fraction) / 5
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(Color.arkBorder), lineWidth: 0.5)
                let scale = min(max(1, size.width - 48) / geometry.bounds.width, max(1, size.height - 48) / geometry.bounds.height)
                func fit(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: (point.x - geometry.bounds.midX) * scale + size.width / 2,
                            y: (point.y - geometry.bounds.midY) * scale + size.height / 2)
                }
                for trail in geometry.paths {
                    let selected = selectedPaths.contains(trail.id)
                    let color = selected ? Color.arkInteractiveForeground : Color.arkTextMuted.opacity(0.3)
                    for segment in trail.segments {
                        guard let first = segment.first else { continue }
                        if segment.count == 1 {
                            let point = fit(first)
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
                        } else {
                            var path = Path()
                            path.move(to: fit(first))
                            for point in segment.dropFirst() { path.addLine(to: fit(point)) }
                            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected ? 3 : 1.5, lineCap: .round, lineJoin: .round, dash: trail.isRoute ? [5, 4] : []))
                        }
                    }
                }
                for place in geometry.places {
                    let point = fit(place.point)
                    let selected = selectedPlaces.contains(place.id)
                    let mark = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    context.fill(mark, with: .color(selected ? Color.arkInteractiveForeground : Color.arkTextMuted.opacity(0.35)))
                    context.stroke(mark, with: .color(Color.arkAppSurface), lineWidth: 1.5)
                }
            }
            .frame(height: 172)
            .background(Color.arkAppSurfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 1) {
                    Image(systemName: "location.north.fill")
                    Text("N").font(.caption2.bold())
                }
                .font(.caption)
                .padding(10)
                .foregroundStyle(Color.arkTextPrimary)
            }
            Text("Selected items are highlighted. Preview only. Full paths are kept; map downloads are separate.")
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Places and paths preview. \(summary). North is up. This is a simplified offline geometry preview, without a base map.")
    }
}
#endif

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

import SwiftUI

#if os(iOS)
/// Keeps authority inspection out of SwiftUI's render path. A library refresh
/// publishes one coherent revision only after scanning and ZIM registration,
/// while favorite changes form the other presentation-relevant cache input.
/// An active session always owns its frozen snapshot and does not advance this
/// idle cache until sharing stops.
@MainActor
final class ArkFileLocalSharingContentSnapshotCache: ObservableObject {
    struct Input: Equatable {
        let libraryRevision: UInt64
        let favoriteRelativePaths: Set<String>
        let readerSourceIDs: Set<UUID>
    }

    typealias Builder = @MainActor (
        [ArkFileLocalContentCategory],
        [ArkFileLibraryContentCategory],
        [ArkFileLocalContentItem],
        Set<UUID>
    ) -> ArkFileLocalSharingContentSnapshot

    @Published private(set) var snapshot: ArkFileLocalSharingContentSnapshot

    private let builder: Builder
    private var input: Input?

    init(
        builder: @escaping Builder = {
            categories,
            libraryCategories,
            favoriteItems,
            readerSourceIDs in
            ArkFileLocalSharingContentSnapshot.make(
                categories: categories,
                libraryCategories: libraryCategories,
                favoriteItems: favoriteItems,
                additionalZimFileIDs: readerSourceIDs
            )
        }
    ) {
        self.builder = builder
        snapshot = ArkFileLocalSharingContentSnapshot(
            categories: [],
            libraryCategories: [],
            favoriteItems: [],
            zimFileIDs: [],
            shareableItemCount: 0,
            identity: "local-sharing-snapshot-not-refreshed"
        )
    }

    /// Returns true only when a new idle snapshot was built.
    @discardableResult
    func refresh(
        libraryRevision: UInt64,
        categories: [ArkFileLocalContentCategory],
        libraryCategories: [ArkFileLibraryContentCategory],
        favoriteItems: [ArkFileLocalContentItem],
        favoriteRelativePaths: Set<String>,
        readerSourceIDs: Set<UUID>,
        activeSessionSnapshot: ArkFileLocalSharingContentSnapshot?
    ) -> Bool {
        // Never let a library notification replace the immutable boundary
        // displayed for an active or starting Local Sharing session.
        guard activeSessionSnapshot == nil else { return false }

        let nextInput = Input(
            libraryRevision: libraryRevision,
            favoriteRelativePaths: favoriteRelativePaths,
            readerSourceIDs: readerSourceIDs
        )
        guard nextInput != input else { return false }

        let nextSnapshot = builder(
            categories,
            libraryCategories,
            favoriteItems,
            readerSourceIDs
        )
        input = nextInput
        snapshot = nextSnapshot
        return true
    }

    func displayedSnapshot(
        activeSessionSnapshot: ArkFileLocalSharingContentSnapshot?
    ) -> ArkFileLocalSharingContentSnapshot {
        activeSessionSnapshot ?? snapshot
    }
}
#endif

/// A grid of zim files that are opened, or was open but is now missing.
/// A specific version of ZimFilesOpened, supporting multi selection for HotSpot
struct HotspotZimFilesSelection: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.openedPredicate(),
        animation: .easeInOut
    ) private var zimFiles: FetchedResults<ZimFile>
    @StateObject private var selection: MultiSelectedZimFilesViewModel
    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared
    @ObservedObject private var hotspot = HotspotObservable.shared
    #if os(iOS)
    @StateObject private var contentFavorites = ArkFileContentFavorites.shared
    @StateObject private var contentSnapshotCache =
        ArkFileLocalSharingContentSnapshotCache()
    #endif
    @State private var presentedSheet: PresentedSheet?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hotspotError: (String, String)?
    @State private var isShowingPortSettings = false
    @State private var isConfirmingStartSharing = false
    
    private enum PresentedSheet: Identifiable {
        case shareHotspot(url: URL)
        
        var id: String {
            switch self {
            case .shareHotspot: return "shareHotspot"
            }
        }
    }
    
    init(
        selectionProvider: @MainActor () -> MultiSelectedZimFilesViewModel = { @MainActor in HotspotState.selection }
    ) {
        let selectionInstance = selectionProvider()
        _selection = StateObject(wrappedValue: selectionInstance)
    }
    
    var body: some View {
        #if os(iOS)
        arkFileLocalSharing
        #else
        legacyHotspotSelection
        #endif
    }

    #if os(iOS)
    private var arkFileLocalSharing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                localSharingHeader

                if showsSharingStatus {
                    sharingStatusCard
                }

                if showsSharingStatus {
                    localSharingGuide
                } else {
                    emptyLocalSharingState
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 42)
        }
        .background(Color.arkSand.ignoresSafeArea())
        .navigationTitle("Local Sharing")
        .navigationBarTitleDisplayMode(.large)
        .tint(Color.arkTeal)
        .task {
            await contentLibrary.refresh()
            refreshCachedLocalSharingContentSnapshot()
            syncSelection(defaultingToAll: true)
        }
        .onChange(of: contentLibrary.localSharingSnapshotRevision) {
            _, _ in
            refreshCachedLocalSharingContentSnapshot()
        }
        .onChange(of: contentFavorites.relativePaths) { _, _ in
            refreshCachedLocalSharingContentSnapshot()
        }
        .onChange(of: zimFiles.map(\.fileID)) { _, _ in
            syncSelection(defaultingToAll: true)
            refreshCachedLocalSharingContentSnapshot()
        }
        .onReceive(hotspot.$state, perform: { state in
            switch state {
            case .started:
                hotspotError = nil
            case .starting:
                hotspotError = nil
            case .stopped:
                hotspotError = nil
            case let .error(title, description):
                hotspotError = (title, description)
            }
            if !state.isStarted && !state.isStarting {
                refreshCachedLocalSharingContentSnapshot()
            }
        })
        .alert(isPresented: Binding<Bool>.constant($hotspotError.wrappedValue != nil)) {
            let settingButton = Alert.Button.default(Text(LocalString.settings_navigation_title), action: {
                dismissAlert()
                isShowingPortSettings = true
            })
            let okButton = Alert.Button.default(Text(LocalString.common_button_ok), action: { dismissAlert() })
            return Alert(
                title: Text(hotspotError?.0 ?? ""),
                message: Text(hotspotError?.1 ?? ""),
                primaryButton: settingButton,
                secondaryButton: okButton
            )
        }
        .sheet(isPresented: $isShowingPortSettings) {
            LocalSharingPortSettingsSheet()
        }
        .confirmationDialog(
            "Start Local Sharing?",
            isPresented: $isConfirmingStartSharing,
            titleVisibility: .visible
        ) {
            Button("Start Sharing") {
                Task {
                    await hotspot.toggleWith(zimFileIds: allReaderSourceIDs)
                }
            }
            Button(LocalString.common_button_cancel, role: .cancel) {}
        } message: {
            Text("While sharing is active, anyone who can reach a Wi-Fi or Personal Hotspot link shown here can browse \(shareableItemSummary) with no account or access code. ArkFile stops serving when you stop, but other devices may save content they open.")
        }
    }

    private var localSharingHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(Brand.loadingLogoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.arkGold.opacity(0.75), lineWidth: 1)
                    }
                    .shadow(color: Color.arkInk.opacity(0.14), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Share ArkFile Nearby")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkInk)
                    Text("Turn this device into a local offline library for nearby phones, tablets, and laptops.")
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTaupe)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                localSharingPills
                    .fixedSize(horizontal: true, vertical: false)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 126), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    localSharingPillItems
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkBorder, lineWidth: 1)
        }
    }

    private var sharingStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch hotspot.state {
            case .started(let address, let qrCodeImage):
                activeSharingDetails(address: address, qrCodeImage: qrCodeImage)
            case .starting:
                startingSharingDetails
            case let .error(title, description):
                failedSharingDetails(title: title, description: description)
            case .stopped:
                inactiveSharingDetails
            }

            AsyncButton {
                if hotspot.state.isStarted {
                    await hotspot.toggleWith(zimFileIds: allReaderSourceIDs)
                } else {
                    isConfirmingStartSharing = true
                }
            } label: {
                HStack {
                    Image(systemName: hotspot.state.isStarted ? "stop.fill" : "wifi")
                    Text(hotspot.state.isStarted
                        ? "Stop Local Sharing"
                        : hotspot.state.isStarting ? "Starting Local Sharing..." : "Start Local Sharing")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(hotspot.state.isStarted ? Color.arkAmber : Color.arkTeal)
            .disabled(
                hotspot.state.isStarting
                    || (localSharingServingPlan == .none && !hotspot.state.isStarted)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hotspot.state.isStarted ? Color.arkTeal : Color.arkBorder, lineWidth: hotspot.state.isStarted ? 2 : 1)
        }
    }

    private var inactiveSharingDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ready to share", systemImage: "wifi")
                .font(.headline)
                .foregroundStyle(Color.arkInk)
            Text("ArkFile will share every readable, non-retired library item currently on this device, including downloaded content and included samples.")
                .font(.subheadline)
                .foregroundStyle(Color.arkTaupe)
                .fixedSize(horizontal: false, vertical: true)
            Text(shareableItemSummary)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkTeal)
        }
    }

    private var startingSharingDetails: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.arkTeal)
            VStack(alignment: .leading, spacing: 4) {
                Text("Starting Local Sharing")
                    .font(.headline)
                    .foregroundStyle(Color.arkInk)
                Text("ArkFile is waiting for the local server to become reachable.")
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTaupe)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failedSharingDetails(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.arkAmber)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(Color.arkTaupe)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activeSharingDetails(address: URL, qrCodeImage: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Sharing is active", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Color.arkTeal)
            Text("Keep ArkFile open and this device awake while others are reading.")
                .font(.subheadline)
                .foregroundStyle(Color.arkTaupe)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open to everyone on this local network. The QR code and address make the library easier to find; they are not access codes.")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkInk)
                .fixedSize(horizontal: false, vertical: true)

            let links = hotspot.sharingLinks
            if links.isEmpty {
                Label("Waiting for Wi-Fi or Personal Hotspot", systemImage: "wifi.slash")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkAmber)
                Text("Connect this device and the other devices to the same Wi-Fi network, then stop and restart Local Sharing.")
                    .font(.caption)
                    .foregroundStyle(Color.arkTaupe)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(links) { link in
                    sharingLinkCard(
                        label: links.count > 1 || link.endpoint.kind == .personalHotspot
                            ? link.endpoint.displayLabel
                            : nil,
                        systemImage: link.endpoint.kind == .personalHotspot ? "personalhotspot" : "wifi",
                        url: link.url,
                        qrCodeImage: link.qrCodeImage
                    )
                }
            }
            if !links.contains(where: { $0.endpoint.kind == .wifi }) {
                noWifiGuidance(
                    hasHotspotLink: links.contains { $0.endpoint.kind == .personalHotspot }
                )
            }
        }
    }

    private func sharingLinkCard(
        label: String?,
        systemImage: String?,
        url: URL,
        qrCodeImage: CGImage?
    ) -> some View {
        VStack(spacing: 14) {
            if let label {
                Label(label, systemImage: systemImage ?? "wifi")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkTeal)
            }
            Group {
                if let qrCodeImage {
                    Image(qrCodeImage, scale: 1, label: Text(url.absoluteString))
                        .resizable()
                } else {
                    ProgressView().progressViewStyle(.circular)
                }
            }
            .frame(width: 210, height: 210)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(url.absoluteString)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkInk)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                ShareLink(item: url) {
                    Label(LocalString.common_button_share, systemImage: "square.and.arrow.up")
                }
                DynamicCopyButton(action: { CopyPaste.copyToPasteBoard(url: url) })
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.arkTeal)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Sharing needs a reachable local network. Personal Hotspot availability
    /// depends on the device and cellular plan; Wi-Fi-only iPads can join one.
    private func noWifiGuidance(hasHotspotLink: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                hasHotspotLink ? "Sharing over your Personal Hotspot" : "No Wi-Fi network detected",
                systemImage: "personalhotspot"
            )
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(Color.arkAmber)
            Text(
                hasHotspotLink
                    ? "Have others join this device's Personal Hotspot network, then use the QR code or address above. Reading shared content does not use the internet."
                    : "Connect everyone to the same Wi-Fi network or another device's hotspot. A Wi-Fi-only iPad can join a hotspot but cannot create one. If this device and your cellular plan support Personal Hotspot, you can turn it on in Settings instead. Restart Local Sharing after connecting."
            )
            .font(.caption)
            .foregroundStyle(Color.arkTaupe)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAmber.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAmber.opacity(0.30), lineWidth: 1)
        }
    }

    private var localSharingGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)
                .foregroundStyle(Color.arkInk)
            LocalSharingGuideRow(
                number: "1",
                title: "Share this device's library",
                copy: "ArkFile shares included samples and every readable, non-retired library item currently on this device."
            )
            LocalSharingGuideRow(
                number: "2",
                title: "Start Local Sharing",
                copy: "ArkFile creates \(ArkFileDeviceCopy.localWebAddressAndQRCode)."
            )
            LocalSharingGuideRow(
                number: "3",
                title: "Open from another device",
                copy: "Nearby devices on the same network - Wi-Fi or this device's Personal Hotspot - can scan the QR code or type the address into a browser. No ArkFile account, app, or access code is required."
            )
            Divider()
            Label(
                "Local Sharing is meant for another nearby device. Opening the address on this same device can stop sharing because ArkFile moves to the background.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(Color.arkTaupe)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkBorder, lineWidth: 1)
        }
    }

    private var emptyLocalSharingState: some View {
        ContentUnavailableView(
            "No shareable content",
            systemImage: "wifi.slash",
            description: Text("Download ArkFile content on this device, then return here to share it nearby.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private var showsSharingStatus: Bool {
        hotspot.state.isStarted
            || hotspot.state.isStarting
            || localSharingServingPlan != .none
    }

    private var localSharingPills: some View {
        HStack(alignment: .top, spacing: 8) {
            localSharingPillItems
        }
    }

    @ViewBuilder
    private var localSharingPillItems: some View {
        LocalSharingPill(systemImage: "wifi", text: "Wi-Fi or Hotspot")
        LocalSharingPill(systemImage: "qrcode", text: "QR discovery")
        LocalSharingPill(systemImage: "books.vertical", text: shareableItemSummary)
    }

    private var shareableItemSummary: String {
        ArkFileLocalSharingAccess.shareableItemSummary(
            count: localSharingContentSnapshot.shareableItemCount
        )
    }

    private var localSharingServingPlan: ArkFileLocalSharingServingPlan {
        ArkFileLocalSharingServingPlan(contentSnapshot: localSharingContentSnapshot)
    }

    private var localSharingContentSnapshot: ArkFileLocalSharingContentSnapshot {
        contentSnapshotCache.displayedSnapshot(
            activeSessionSnapshot: hotspot.activeLocalSharingContentSnapshot
        )
    }

    private func refreshCachedLocalSharingContentSnapshot() {
        contentSnapshotCache.refresh(
            libraryRevision: contentLibrary.localSharingSnapshotRevision,
            categories: contentLibrary.categories,
            libraryCategories: contentLibrary.libraryCategories,
            favoriteItems: contentFavorites.favoriteItems(
                in: contentLibrary.categories
            ),
            favoriteRelativePaths: contentFavorites.relativePaths,
            readerSourceIDs: allReaderSourceIDs,
            activeSessionSnapshot:
                hotspot.activeLocalSharingContentSnapshot
        )
    }

    private var allReaderSourceIDs: Set<UUID> {
        Set(zimFiles.map(\.fileID))
    }

    private func syncSelection(defaultingToAll: Bool) {
        let available = Set(zimFiles)
        selection.intersection(with: available)
        if defaultingToAll, selection.selectedZimFiles.isEmpty, !available.isEmpty {
            selection.selectAll(available)
        }
    }

    #endif

    private var legacyHotspotSelection: some View {
        VStack(spacing: 0) {
            if zimFiles.isEmpty {
                Message(text: LocalString.zim_file_opened_overlay_no_opened_message)
            } else {
                if case .started(let address, let qrCodeImage) = hotspot.state {
                    ScrollView {
                        HStack(alignment: .center) {
                            VStack(alignment: .center, spacing: 12) {
                                Spacer()
                                LazyVGrid(
                                    columns: [GridItem(.flexible(minimum: 250, maximum: 303), spacing: 12)],
                                    alignment: .center,
                                    spacing: 12
                                ) {
                                    HotspotDetails(address: address, qrCodeImage: qrCodeImage)
                                }
                                Spacer()
                            }
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 500), spacing: 12)],
                        alignment: .center,
                        spacing: 12
                    ) {
                        ForEach(zimFiles, id: \.fileID) { zimFile in
                            MultiZimFilesSelectionContext(
                                content: {
                                    ZimFileCell(
                                        zimFile,
                                        prominent: .name,
                                        isSelected: selection.isSelected(zimFile),
                                        backgroundColoring: CellBackground.hotspotSelectionColorFor
                                    )
                                },
                                zimFile: zimFile,
                                selection: selection
                            )
                        }
                    }
                    .modifier(GridCommon(edges: .all))
                }
            }
        }
        .modifier(ToolbarRoleBrowser())
        .navigationTitle(MenuItem.hotspot.name)
        .task {
            // make sure that our selection only contains still existing ZIM files
            selection.intersection(with: Set(zimFiles))
            if !FeatureFlags.hasLibrary, let customZIM = zimFiles.first {
                selection.singleSelect(zimFile: customZIM)
            }
        }
        .onReceive(hotspot.$state, perform: { state in
            switch state {
            case .started:
                hotspotError = nil
            case .starting:
                hotspotError = nil
            case .stopped:
                hotspotError = nil
            case let .error(title, description):
                hotspotError = (title, description)
            }
        })
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AsyncButton {
                    await hotspot.toggleWith(
                        zimFileIds: Set(selection.selectedZimFiles.map { $0.fileID })
                    )
                } label: {
                    Text(hotspot.buttonTitle)
                        .bold()
                    #if os(macOS)
                        .padding(selection.selectedZimFiles.count == 0 ? .horizontal : .trailing)
                    #endif
                }
#if os(macOS)
                .buttonStyle(.borderless)
#endif
                .disabled(selection.selectedZimFiles.isEmpty && !hotspot.state.isStarted)
                .modifier(BadgeModifier(count: selection.selectedZimFiles.count))
            }
        }
        .alert(isPresented: Binding<Bool>.constant($hotspotError.wrappedValue != nil)) {
            
            let settingButton = Alert.Button.default(Text(LocalString.settings_navigation_title), action: {
                dismissAlert()
                NotificationCenter.navigateToHotspotSettings()
            })
            let okButton = Alert.Button.default(Text(LocalString.common_button_ok), action: { dismissAlert() })
            
            #if os(macOS)
            let primary = okButton
            let secondary = settingButton
            #else
            let primary = settingButton
            let secondary = okButton
            #endif
            
            return Alert(title: Text(hotspotError?.0 ?? ""),
                         message: Text(hotspotError?.1 ?? ""),
                         primaryButton: primary,
                         secondaryButton: secondary
            )
        }
    }
    
    private func dismissAlert() {
        hotspotError = nil
        // at the end resetError is also setting hotspotError to nil
        // but it's just too slow for UI
        hotspot.resetError()
    }
}

#if os(iOS)
private struct LocalSharingPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.arkTeal)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.arkTeal.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct LocalSharingGuideRow: View {
    let number: String
    let title: String
    let copy: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Color.arkSurface)
                .frame(width: 24, height: 24)
                .background(Color.arkTeal)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkInk)
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(Color.arkTaupe)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LocalSharingPortSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Local Sharing") {
                    PortInput(focusOnPortInput: true)
                    Text(Hotspot.validPortRangeMessage())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Local Sharing Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(LocalString.common_button_done) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.arkTeal)
    }
}
#endif

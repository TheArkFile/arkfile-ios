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

#if os(iOS)

import SwiftUI
import UniformTypeIdentifiers

/// A grid of zim files that are opened, or was open but is now missing
/// iOS only
struct ZimFilesOpenedNavStack: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.Predicate.isDownloaded(),
        animation: .easeInOut
    ) private var zimFiles: FetchedResults<ZimFile>
    @StateObject private var arkFileContentLibrary = ArkFileLocalContentLibrary.shared
    @State private var isFileImporterPresented = false
    @State private var navPath: [ZimFile] = []
    @State private var activeLocalItem: ArkFileLocalContentItem?
    @State private var activeBookmark: ArkFileContentBookmark?
    @State private var savedOpenError: String?
    // opening the details of a freshly added zimFile
    private let selectFileById = NotificationCenter.default.publisher(for: .selectFile)
    @State private var fileIdToOpen: UUID?
    
    let dismiss: (() -> Void)?
    
    var body: some View {
        NavigationStack(path: $navPath) {
            LazyVGrid(
                columns: ([GridItem(.adaptive(minimum: 250, maximum: 500), spacing: 12)]),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(zimFiles, id: \.fileID) { zimFile in
                    NavigationLink(value: zimFile) {
                        ZimFileCell(
                            zimFile,
                            prominent: .name,
                            isSelected: navPath.contains(where: { $0.fileID == zimFile.fileID })
                        )
                    }.accessibilityIdentifier(zimFile.name)
                }
                ForEach(arkFileContentLibrary.nonZimCategories) { category in
                    GridSection(title: category.displayName) {
                        ForEach(category.items) { item in
                            Button {
                                activeBookmark = nil
                                activeLocalItem = item
                            } label: {
                                ArkFileContentCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationDestination(for: ZimFile.self) { zimFile in
                ZimFileDetail(zimFile: zimFile, dismissParent: dismiss)
            }
            .navigationDestination(item: $activeLocalItem) { item in
                ArkFileContentViewer(
                    item: item,
                    initialBookmark: activeBookmark,
                    openContentItem: openContentItem
                )
            }
        }
        .modifier(GridCommon(edges: .all))
        .modifier(ToolbarRoleBrowser())
        .navigationTitle(MenuItem.opened.name)
        .overlay {
            if zimFiles.isEmpty && !arkFileContentLibrary.hasContent {
                Message(text: LocalString.zim_file_opened_overlay_no_opened_message)
            }
        }
        .task {
            await arkFileContentLibrary.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label(LocalString.zim_file_opened_toolbar_open_title, systemImage: "plus")
                }.help(LocalString.zim_file_opened_toolbar_open_help)
            }
        }
        // not using OpenFileButton here, because it does not work on iOS/iPadOS 15 when this view is in a modal
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.zimFile],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            NotificationCenter.openFiles(urls, context: .library)
        }
        .onReceive(selectFileById, perform: { notification in
            guard let fileId = notification.userInfo?["fileId"] as? UUID else {
                return
            }
            fileIdToOpen = fileId
        })
        .onChange(of: zimFiles.count) {
            if let fileIdToOpen,
               let selectedZimFile = zimFiles.first(where: { $0.fileID == fileIdToOpen }) {
                self.fileIdToOpen = nil
                navPath = [selectedZimFile]
            }
        }
        .alert(
            "Couldn’t Open Saved Item",
            isPresented: Binding(
                get: { savedOpenError != nil },
                set: { if !$0 { savedOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                savedOpenError = nil
            }
        } message: {
            Text(savedOpenError ?? "")
        }
    }

    private func openContentItem(
        _ item: ArkFileLocalContentItem,
        bookmark: ArkFileContentBookmark?
    ) {
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        activeBookmark = nil
        activeLocalItem = nil
        guard item.type == .zim else {
            activeBookmark = bookmark
            activeLocalItem = item
            return
        }
        Task {
            if let bookmark {
                switch await ArkFileSavedZIMResolver.resolve(bookmark: bookmark, item: item) {
                case .success(let destination):
                    finishOpeningZIM(destination.url, continuing: readerOpenIntent)
                case .failure(let failure):
                    if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                        savedOpenError = failure.message(itemName: item.displayName)
                    }
                }
            } else {
                await openZIMMainPage(item, continuing: readerOpenIntent)
            }
        }
    }

    private func openZIMMainPage(
        _ item: ArkFileLocalContentItem,
        continuing readerOpenIntent: ArkFileReaderOpenIntent
    ) async {
        guard let fileID = await LibraryOperations.openFileID(url: item.url),
              ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent),
              await ZimFileService.shared.openArchive(zimFileID: fileID) != nil,
              ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent),
              let url = await ZimFileService.shared.getMainPageURL(zimFileID: fileID) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                savedOpenError = "ArkFile could not open the current local copy of \(item.displayName)."
            }
            return
        }
        finishOpeningZIM(url, continuing: readerOpenIntent)
    }

    private func finishOpeningZIM(
        _ url: URL,
        continuing readerOpenIntent: ArkFileReaderOpenIntent
    ) {
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        activeBookmark = nil
        activeLocalItem = nil
        dismiss?()
        DispatchQueue.main.async {
            NotificationCenter.openURL(url, continuing: readerOpenIntent)
        }
    }
}

#endif

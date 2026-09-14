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

enum ArkFileHTMLBookNavigation {
    static func entryIndex(
        committedURL: URL?,
        initialURL: URL,
        entries: [ArkFileHTMLBookEntry]
    ) -> Int? {
        let activeURL = committedURL ?? initialURL
        let activeKey = entryKey(for: activeURL)
        if let exactIndex = entries.firstIndex(where: { entryKey(for: $0.url) == activeKey }) {
            return exactIndex
        }
        let activeFileKey = fileKey(for: activeURL)
        return entries.firstIndex { fileKey(for: $0.url) == activeFileKey }
    }

    static func entryKey(for url: URL) -> String {
        let rawFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        let fragment = (rawFragment.removingPercentEncoding ?? rawFragment).lowercased()
        return "\(fileKey(for: url))#\(fragment)"
    }

    static func fileKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.standardizedFileURL.fileSystemPath.lowercased()
        }
        components.fragment = nil
        return (components.url ?? url).standardizedFileURL.fileSystemPath.lowercased()
    }
}

struct ArkFileHTMLBookViewer: View {
    let item: ArkFileLocalContentItem
    @ObservedObject var controller: ArkFileWebReaderController
    var initialURL: URL?
    var initialChapterPath: String?
    var targetScrollTop: Double?
    var targetScrollID: String? = nil
    var targetAnchorID: String? = nil
    var waitsForResolvedInitialURL = false
    var onEntriesLoaded: ([ArkFileHTMLBookEntry]) -> Void = { _ in }
    var onInitialURLResolved: (URL) -> Void = { _ in }

    @State private var loadResult: HTMLBookLoadResult?
    @State private var errorMessage: String?
    @State private var remountToken = 0
    @State private var isShowingContents = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let loadResult {
                    ArkFileHTMLViewer(
                        url: loadResult.initialURL,
                        readAccessURL: loadResult.rootURL,
                        accessGuardURL: item.url,
                        controller: controller,
                        targetScrollTop: targetScrollTop,
                        targetScrollID: targetScrollID,
                        targetAnchorID: targetAnchorID,
                        onBlankRenderDetected: {
                            guard remountToken < 2 else { return }
                            remountToken += 1
                        }
                    )
                    .id("\(loadResult.initialURL.absoluteString)#\(remountToken)")
                } else if let errorMessage {
                    Message(text: errorMessage)
                } else {
                    LoadingDataView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let navigationError = controller.navigationErrorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.arkGold)
                    Text("Couldn’t open that chapter. \(navigationError)")
                        .font(.caption)
                        .foregroundStyle(Color.arkInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if controller.canRetryLastLoad {
                        Button("Retry") {
                            controller.retryLastLoad()
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.arkSurface)
            }

            if let loadResult, loadResult.entries.count > 1 {
                Divider()
                chapterNavigationBar(for: loadResult)
            }
        }
        .sheet(isPresented: $isShowingContents) {
            if let entries = loadResult?.entries {
                ArkFileHTMLBookContentsSheet(entries: entries) { entry in
                    open(entry)
                    isShowingContents = false
                }
            }
        }
        .task(id: targetIdentity) {
            loadResult = nil
            errorMessage = nil
            remountToken = 0
            do {
                let extractionTask = Task.detached(priority: .userInitiated) {
                    let entryURL = try ArkFileHTMLBookExtractor.entryURL(for: item)
                    let rootURL = try ArkFileHTMLBookExtractor.extractedRootURL(for: item)
                    let initialURL = try ArkFileHTMLBookExtractor.bookmarkedURL(
                        for: item,
                        chapterPath: initialChapterPath,
                        articleURL: initialURL
                    ) ?? entryURL
                    let entries = try ArkFileHTMLBookExtractor.tableOfContents(for: item)
                    return HTMLBookLoadResult(
                        rootURL: rootURL,
                        initialURL: initialURL,
                        entries: entries
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await extractionTask.value
                } onCancel: {
                    extractionTask.cancel()
                }
                guard !Task.isCancelled else { return }
                onEntriesLoaded(result.entries)
                if waitsForResolvedInitialURL, initialURL == nil {
                    Log.ContentPack.info(
                        "HTML book resolved initial page \(result.initialURL.lastPathComponent, privacy: .public) for \(item.relativePath, privacy: .public)"
                    )
                    onInitialURLResolved(result.initialURL)
                    return
                }
                loadResult = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                loadResult = nil
                errorMessage = LocalString.arkfile_content_viewer_htmlbook_error
            }
        }
    }

    private var targetIdentity: String {
        [
            item.id,
            initialChapterPath ?? "",
            initialURL?.absoluteString ?? ""
        ].joined(separator: "|")
    }

    private func chapterNavigationBar(for result: HTMLBookLoadResult) -> some View {
        let currentIndex = currentEntryIndex(in: result)
        let currentEntry = currentIndex.flatMap { result.entries[$0] }
        let previousEntry = currentIndex.flatMap { index in
            index > 0 ? result.entries[index - 1] : nil
        }
        // When the visible page is not itself a TOC entry (e.g. the book's
        // index page), Next enters the first chapter instead of being dead.
        let nextEntry: ArkFileHTMLBookEntry? = {
            guard let currentIndex else { return result.entries.first }
            return currentIndex + 1 < result.entries.count ? result.entries[currentIndex + 1] : nil
        }()

        return HStack(spacing: 10) {
            Button {
                if let previousEntry {
                    open(previousEntry)
                }
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .disabled(previousEntry == nil || controller.isNavigating)
            .accessibilityLabel("Previous chapter")

            Button {
                isShowingContents = true
            } label: {
                VStack(spacing: 2) {
                    Text(currentEntry?.title ?? "Contents")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Contents")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Open contents")

            Button {
                if let nextEntry {
                    open(nextEntry)
                }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .disabled(nextEntry == nil || controller.isNavigating)
            .accessibilityLabel("Next chapter")
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(Color.arkInk)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.arkSurface)
    }

    private func currentEntryIndex(in result: HTMLBookLoadResult) -> Int? {
        ArkFileHTMLBookNavigation.entryIndex(
            committedURL: controller.currentURL,
            initialURL: result.initialURL,
            entries: result.entries
        )
    }

    private func open(_ entry: ArkFileHTMLBookEntry) {
        controller.load(entry.url)
    }

    private struct HTMLBookLoadResult: Sendable {
        let rootURL: URL
        let initialURL: URL
        let entries: [ArkFileHTMLBookEntry]
    }
}

private struct ArkFileHTMLBookContentsSheet: View {
    let entries: [ArkFileHTMLBookEntry]
    let openEntry: (ArkFileHTMLBookEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    openEntry(entry)
                    dismiss()
                } label: {
                    Text(entry.title)
                        .foregroundStyle(Color.arkInk)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .tint(Color.arkTeal)
    }
}
#endif

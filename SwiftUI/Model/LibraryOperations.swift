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

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
import CoreData
import os

import Defaults

enum ArkFileLibraryRevalidationOutcome: Equatable, Sendable {
    case definitive
    case temporarilyUnavailable

    var permitsMissingTabDeletion: Bool {
        self == .definitive
    }
}

struct LibraryOperations {
    private init() {}

    private struct PendingRegistration: Sendable {
        let bookmark: Data
        let metadata: ZimFileMetaStruct
    }

    // MARK: - Open

    /// Open a zim file with url
    /// - Parameter url: url of the zim file
    @discardableResult
    static func open(url: URL, includeInSearchByDefault: Bool = false) async -> ZimFileMetaStruct? {
        await open(urls: [url], includeInSearchByDefault: includeInSearchByDefault).first
    }

    /// Fast path for opening already-registered managed content. Normal taps
    /// avoid reparsing the ZIM header and rewriting its Core Data row; newly
    /// imported or changed files still fall through to full validation.
    static func openFileID(url: URL) async -> UUID? {
        guard await ArkFileEssentialsAccessGate.resolvedURLForReading(url) != nil else { return nil }
        if let fileID = await ZimFileService.shared.registeredFileID(for: url) {
            return fileID
        }
        return await open(url: url)?.fileID
    }

    /// Registers a set of ZIMs with one Core Data save. A Complete install can
    /// contain many archives; saving once per file repeatedly woke the global
    /// search observer and restarted its work while registration was ongoing.
    @discardableResult
    static func open(
        urls: [URL],
        includeInSearchByDefault: Bool = false
    ) async -> [ZimFileMetaStruct] {
        // The embedded UUID belongs to the archive generation. Core Data IDs
        // are app aliases and must survive a same-path replacement so tabs,
        // bookmarks, and search preferences continue to resolve. Read this
        // projection before parsing new headers; startup revalidation and the
        // local-content scanner may otherwise race to register different IDs.
        var retainedFileIDsByPath = await retainedDownloadedFileIDsByPath()
        var registrations: [PendingRegistration] = []
        registrations.reserveCapacity(urls.count)

        for url in urls {
            guard await ArkFileEssentialsAccessGate.resolvedURLForReading(url) != nil,
                  let fileURLBookmark = await ZimFileService.getFileURLBookmarkData(for: url),
                  let embeddedMetadata = await ZimFileService.getMetaData(url: url) else {
                continue
            }
            let path = canonicalRegistrationPath(url)
            let appFileID = retainedFileIDsByPath[path] ?? embeddedMetadata.fileID
            retainedFileIDsByPath[path] = appFileID
            let appMetadata = metadata(embeddedMetadata, replacingFileID: appFileID)
            do {
                try await ZimFileService.shared.revalidate(
                    fileURLBookmark: fileURLBookmark,
                    for: appMetadata.fileID
                )
                registrations.append(PendingRegistration(
                    bookmark: fileURLBookmark,
                    metadata: appMetadata
                ))
            } catch {
                continue
            }
        }

        guard !registrations.isEmpty else { return [] }
        let preparedRegistrations = registrations
        await Database.shared.viewContext.perform {
            let context = Database.shared.viewContext
            for registration in preparedRegistrations {
                let predicate = NSPredicate(
                    format: "fileID == %@",
                    registration.metadata.fileID as CVarArg
                )
                let fetchRequest = ZimFile.fetchRequest(predicate: predicate)
                fetchRequest.fetchLimit = 1
                let existingZimFile = try? fetchRequest.execute().first
                let isNewZimFile = existingZimFile == nil
                let zimFile = existingZimFile ?? ZimFile(context: context)
                LibraryOperations.configureZimFile(zimFile, metadata: registration.metadata)
                zimFile.fileURLBookmark = registration.bookmark
                zimFile.isMissing = false
                if includeInSearchByDefault && isNewZimFile {
                    zimFile.includedInSearch = true
                }
            }
            if context.hasChanges {
                try? context.save()
            }
        }
        return preparedRegistrations.map(\.metadata)
    }

    /// One deterministic app alias per downloaded physical path. A row with
    /// navigation references wins over an unreferenced duplicate; remaining
    /// ties use durable user state and then UUID ordering. This does not delete
    /// or rewrite rows—it prevents the scanner from creating a new one during
    /// a cold same-path replacement.
    @MainActor
    private static func retainedDownloadedFileIDsByPath() -> [String: UUID] {
        let request = ZimFile.fetchRequest(predicate: ZimFile.Predicate.isDownloaded())
        guard let zimFiles = try? Database.shared.viewContext.fetch(request) else { return [:] }
        var retained: [String: ZimFile] = [:]
        for zimFile in zimFiles {
            guard let bookmark = zimFile.fileURLBookmark,
                  let url = try? resolveBookmark(bookmark) else {
                continue
            }
            let didStartSecurityScope = url.startAccessingSecurityScopedResource()
            let path = canonicalRegistrationPath(url)
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            if let existing = retained[path] {
                if shouldPreferRegistration(zimFile, over: existing) {
                    retained[path] = zimFile
                }
            } else {
                retained[path] = zimFile
            }
        }
        return retained.mapValues(\.fileID)
    }

    @MainActor
    private static func shouldPreferRegistration(_ candidate: ZimFile, over existing: ZimFile) -> Bool {
        let candidateReferenceCount = candidate.tabs.count + candidate.bookmarks.count
        let existingReferenceCount = existing.tabs.count + existing.bookmarks.count
        if candidateReferenceCount != existingReferenceCount {
            return candidateReferenceCount > existingReferenceCount
        }
        if candidate.includedInSearch != existing.includedInSearch {
            return candidate.includedInSearch
        }
        if candidate.isMissing != existing.isMissing {
            return !candidate.isMissing
        }
        if (candidate.isIntegrityChecked != nil) != (existing.isIntegrityChecked != nil) {
            return candidate.isIntegrityChecked != nil
        }
        return candidate.fileID.uuidString < existing.fileID.uuidString
    }

    nonisolated private static func canonicalRegistrationPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().fileSystemPath
    }

    nonisolated private static func metadata(
        _ metadata: ZimFileMetaStruct,
        replacingFileID fileID: UUID
    ) -> ZimFileMetaStruct {
        ZimFileMetaStruct(
            fileID: fileID,
            groupIdentifier: metadata.groupIdentifier,
            title: metadata.title,
            fileDescription: metadata.fileDescription,
            languageCodes: metadata.languageCodes,
            category: metadata.category,
            creationDate: metadata.creationDate,
            size: metadata.size,
            articleCount: metadata.articleCount,
            mediaCount: metadata.mediaCount,
            creator: metadata.creator,
            publisher: metadata.publisher,
            downloadURL: metadata.downloadURL,
            faviconURL: metadata.faviconURL,
            faviconData: metadata.faviconData,
            flavor: metadata.flavor,
            hasDetails: metadata.hasDetails,
            hasPictures: metadata.hasPictures,
            hasVideos: metadata.hasVideos,
            requiresServiceWorkers: metadata.requiresServiceWorkers
        )
    }
    
    /// Makes sure that on app start the inital task we await for
    /// and the scene phase change are not triggering twice the reValidate()
    @MainActor
    private static var isReValidating: Bool = false

    @MainActor
    private struct PendingRevalidation {
        let zimFile: ZimFile
        let previousBookmark: Data?
        let previousIsMissing: Bool
        let bookmark: Data?
        let isMissing: Bool
    }

    /// Revalidate ZIM files from url bookmark data
    /// Marks only definitively missing ZIM files in the DB. Protected-data,
    /// permission, bookmark, access-gate, fetch, and open failures preserve the
    /// last durable state and report an unavailable pass to the caller.
    nonisolated static func shouldBeginRevalidation(
        alreadyRevalidating: Bool,
        activationRootWideReadBlocked: Bool,
        protectedDataAvailable: Bool
    ) -> Bool {
        !alreadyRevalidating
            && !activationRootWideReadBlocked
            && protectedDataAvailable
    }

    @discardableResult
    @MainActor
    static func reValidate(
        protectedDataAvailableOverride: Bool? = nil
    ) async -> ArkFileLibraryRevalidationOutcome {
        let protectedDataAvailable = protectedDataAvailableOverride
            ?? ArkFileProtectedDataAvailability.isAvailable
        guard Self.shouldBeginRevalidation(
            alreadyRevalidating: isReValidating,
            activationRootWideReadBlocked: ArkFileContentActivationCoordinator
                .hasRootWideReadBlock,
            protectedDataAvailable: protectedDataAvailable
        ) else {
            return .temporarilyUnavailable
        }
        isReValidating = true
        defer {
            isReValidating = false
        }
        var successCount = 0
        let context = Database.shared.viewContext
        let request = ZimFile.fetchRequest(predicate: ZimFile.Predicate.isDownloaded())

        let zimFiles: [ZimFile]
        do {
            zimFiles = try context.fetch(request)
        } catch {
            Log.LibraryOperations.error(
                "ZIM revalidation unavailable because the library could not be fetched: \(error, privacy: .public)"
            )
            return .temporarilyUnavailable
        }

        var pending: [PendingRevalidation] = []
        for zimFile in zimFiles {
            guard let data = zimFile.fileURLBookmark else {
                return .temporarilyUnavailable
            }

            let downloadPath = zimFile.downloadURL?.absoluteString ?? "unknown"
            let fileURL: URL
            do {
                fileURL = try Self.resolveBookmark(data)
            } catch {
                Log.LibraryOperations.notice("""
ZIM bookmark temporarily unavailable: \(zimFile.name, privacy: .public) |\
\(downloadPath, privacy: .public) due to: \(error, privacy: .public)
""")
                return .temporarilyUnavailable
            }

            let didStartSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let resolvedReadingURL = ArkFileEssentialsAccessGate.resolvedURLForReading(fileURL)
            let probedURL = resolvedReadingURL ?? fileURL
            switch ArkFileLocalPathProbe.availability(of: probedURL, expectedDirectory: false) {
            case .definitivelyMissing:
                pending.append(PendingRevalidation(
                    zimFile: zimFile,
                    previousBookmark: zimFile.fileURLBookmark,
                    previousIsMissing: zimFile.isMissing,
                    bookmark: zimFile.fileURLBookmark,
                    isMissing: true
                ))
                continue
            case .temporarilyUnavailable:
                return .temporarilyUnavailable
            case .available:
                break
            }

            guard resolvedReadingURL != nil else {
                return .temporarilyUnavailable
            }

            do {
                let refreshedBookmark = try await ZimFileService.shared.revalidate(
                    fileURLBookmark: data,
                    for: zimFile.fileID
                )
                pending.append(PendingRevalidation(
                    zimFile: zimFile,
                    previousBookmark: zimFile.fileURLBookmark,
                    previousIsMissing: zimFile.isMissing,
                    bookmark: refreshedBookmark ?? zimFile.fileURLBookmark,
                    isMissing: false
                ))
                successCount += 1
                Log.LibraryOperations.notice("""
ZIM file reValidated: \(zimFile.name, privacy: .public) |\
\(downloadPath, privacy: .public)
""")
            } catch ZimFileOpenError.missing {
                let postFailureURL = ArkFileEssentialsAccessGate.resolvedURLForReading(fileURL)
                    ?? fileURL
                guard ArkFileLocalPathProbe.availability(
                    of: postFailureURL,
                    expectedDirectory: false
                ) == .definitivelyMissing else {
                    return .temporarilyUnavailable
                }
                pending.append(PendingRevalidation(
                    zimFile: zimFile,
                    previousBookmark: zimFile.fileURLBookmark,
                    previousIsMissing: zimFile.isMissing,
                    bookmark: zimFile.fileURLBookmark,
                    isMissing: true
                ))
                Log.LibraryOperations.notice("""
ZIM file missing: \(zimFile.name, privacy: .public) |\
 \(downloadPath, privacy: .public)
""")
            } catch {
                Log.LibraryOperations.notice("""
ZIM file temporarily cannot be opened: \(zimFile.name, privacy: .public) |\
\(downloadPath, privacy: .public) due to: \(error, privacy: .public)
""")
                return .temporarilyUnavailable
            }
        }

        for update in pending {
            update.zimFile.fileURLBookmark = update.bookmark
            update.zimFile.isMissing = update.isMissing
        }
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                for update in pending {
                    update.zimFile.fileURLBookmark = update.previousBookmark
                    update.zimFile.isMissing = update.previousIsMissing
                }
                Log.LibraryOperations.error(
                    "ZIM revalidation unavailable because changes could not be saved: \(error, privacy: .public)"
                )
                return .temporarilyUnavailable
            }
        }
        Log.LibraryOperations.info(
            "Re-validated \(successCount, privacy: .public) out of \(zimFiles.count, privacy: .public) zim files"
        )
        return .definitive
    }

    @MainActor
    private static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        return try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    // MARK: - Configure

    /// Configure a zim file object based on its metadata.
    nonisolated static func configureZimFile(_ zimFile: ZimFile, metadata: ZimFileMetaStruct) {
        zimFile.articleCount = metadata.articleCount
        zimFile.category = (Category(rawValue: metadata.category) ?? .other).rawValue
        zimFile.created = metadata.creationDate
        zimFile.fileDescription = metadata.fileDescription
        zimFile.fileID = metadata.fileID
        zimFile.flavor = metadata.flavor
        zimFile.hasDetails = metadata.hasDetails
        zimFile.hasPictures = metadata.hasPictures
        zimFile.hasVideos = metadata.hasVideos
        zimFile.languageCode = metadata.languageCodes
        zimFile.mediaCount = metadata.mediaCount
        zimFile.name = metadata.title
        zimFile.persistentID = metadata.groupIdentifier
        zimFile.requiresServiceWorkers = metadata.requiresServiceWorkers
        zimFile.size = metadata.size

        // Overwrite these, only if there are new values
        if let faviconURL = metadata.faviconURL { zimFile.faviconURL = faviconURL }
        if let faviconData = metadata.faviconData { zimFile.faviconData = faviconData }
        if let downloadURL = metadata.downloadURL { zimFile.downloadURL = downloadURL }
    }

    // MARK: - Deletion

    /// Unlink a zim file from library, delete associated bookmarks, and delete the file.
    /// - Parameter zimFile: the zim file to delete
    @ZimActor static func delete(zimFileID: UUID) async {
        guard let url = ZimFileService.shared.getFileURL(zimFileID: zimFileID) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        await LibraryOperations.unlink(zimFileID: zimFileID)
    }

    /// Unlink a zim file from library, delete associated bookmarks, but don't delete the file.
    /// - Parameter zimFile: the zim file to unlink
    @ZimActor static func unlink(zimFileID: UUID) async {
        ZimFileService.shared.close(fileID: zimFileID)
        await Database.shared.viewContext.perform {
            let request = ZimFile.fetchRequest(fileID: zimFileID)
            request.fetchLimit = 1
            guard let zimFile = try? request.execute().first else {
                return
            }
            let context = Database.shared.viewContext
            zimFile.bookmarks.forEach { context.delete($0) }
            zimFile.fileURLBookmark = nil
            zimFile.isMissing = false
            zimFile.isIntegrityChecked = nil
            zimFile.tabs.forEach { context.delete($0) }
            try? context.save()
        }
        
        let tabIds: [NSManagedObjectID] = await Database.shared.viewContext.perform {
            let tabIdsRequest = NSFetchRequest<NSManagedObjectID>(entityName: "Tab")
            tabIdsRequest.resultType = .managedObjectIDResultType
            do {
                let tabIds = try tabIdsRequest.execute()
                return tabIds
            } catch {
                return []
            }
        }
        
        // clear out all the browserViewModels of tabs no longer in use
        BrowserViewModel.keepOnlyTabsByIds(Set(tabIds))

        #if os(iOS)
        // make sure we won't end up without any tabs
        if tabIds.count == 0 {
            await Database.shared.viewContext.perform {
                let context = Database.shared.viewContext
                let tab = Tab(context: context)
                tab.created = Date()
                tab.lastOpened = Date()
                try? context.obtainPermanentIDs(for: [tab])
                try? context.save()
            }
        }
        #else
        await MainActor.run {
            NotificationCenter.keepOnlyTabs(Set(tabIds))
        }
        #endif
    }

    // MARK: - Backup

    /// Apply iCloud backup setting on zim files in document directory.
    /// - Parameter isEnabled: if file should be included in backup
    static func applyFileBackupSetting(isEnabled: Bool? = nil) {
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isExcludedFromBackupKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            ).filter({ $0.pathExtension.contains("zim") })
            let backupDocumentDirectory = isEnabled ?? Defaults[.backupDocumentDirectory]
            try urls.forEach { url in
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = !backupDocumentDirectory
                var url = url
                try url.setResourceValues(resourceValues)
            }
            let status = backupDocumentDirectory ? "backing up" : "not backing up"
            let fileCount = urls.count
            Log.LibraryOperations.info(
                "Updated iCloud backup setting (\(status, privacy: .public)) on files: \(fileCount, privacy: .public)")
        } catch {
            Log.LibraryOperations.error(
                "Unable to change iCloud backup settings, due to \(error.localizedDescription, privacy: .public)")
        }
    }
}

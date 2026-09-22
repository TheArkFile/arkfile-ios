import Combine
import Darwin
import Foundation

/// User-initiated content acquisition. The persisted request pins the exact
/// signed release, item revision and replacement mode across every retry.
@MainActor
final class ArkFileContentUpdateCoordinator: ObservableObject {
    static let shared = ArkFileContentUpdateCoordinator()
    @Published private var isRunning = false
    @Published private var isCancelling = false
    @Published private(set) var isChecking = false
    @Published private(set) var journal: ArkFileContentReplacementJournal?
    @Published private(set) var message: String?
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let provider: ArkFileContentReleaseProvider
    private let authorizationStore = ArkFileContentBackgroundAuthorizationStore()
    private var observer: AnyCancellable?

    init(provider: ArkFileContentReleaseProvider = .shared) {
        self.provider = provider
        if let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot() {
            ArkFileContentReplacementStore.loadRecoveryBarrier(at: root)
            journal = try? ArkFileContentReplacementStore.load(at: root)
        }
        generation = provider.generation
        observer = NotificationCenter.default.publisher(for: .arkFileContentReleaseChanged)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                Task { @MainActor in self?.generation = provider.generation }
            }
    }
    var available: ArkFileVerifiedContentRelease? { provider.snapshot.available }
    var installed: [String: ArkFileContentReleaseProvider.InstalledRevision] { provider.snapshot.installed }
    var isBusy: Bool { isRunning || isCancelling }
    var canResume: Bool { journal.map { !$0.isTerminal } == true && !isBusy }
    var canPause: Bool { isRunning && canCancel }
    var canCancel: Bool {
        !isCancelling && Self.allowsInterruption(phase: journal?.phase, isRunning: isRunning)
    }

    /// An activation already launched on its worker must finish its atomic
    /// commit. A stopped activation can still be resumed or cancelled later.
    nonisolated static func allowsInterruption(
        phase: ArkFileContentReplacementJournal.Phase?, isRunning: Bool
    ) -> Bool {
        guard let phase else { return false }
        switch phase {
        case .removing, .recoveryPending, .installed, .cancelled: return false
        case .activating: return !isRunning
        default: return true
        }
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true; defer { isChecking = false }
        do {
            try await provider.refresh(using: makeAPI())
            try migrateKnownInstalledContent()
            generation = provider.generation; message = "Content catalog is up to date. Choose the items to download."
        } catch { message = error.localizedDescription }
    }

    func isInstalled(_ itemID: String) -> Bool {
        guard let receipt = installed[itemID],
              let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else { return false }
        return receipt.files.allSatisfy { file in
            commit.payload.entries.contains { $0.relativePath == file.relativePath && $0.byteCount == file.sizeBytes && $0.sha256 == file.sha256 }
                && ArkFileInstalledContentAccess.canRead(root.appendingPathComponent(file.relativePath))
        }
    }

    func install(itemID: String, mode: ArkFileContentRevisionSelection.Mode,
                 allowsCellular: Bool = false) {
        guard !isBusy, !ArkFileContentPackInstaller.shared.isBusy else { return }
        do {
            try migrateKnownInstalledContent()
            guard let verified = available, let item = verified.release.item(itemID) else {
                throw ArkFileContentReleaseError.releaseUnavailable
            }
            let request = ArkFileContentReleaseRequest(id: UUID(), binding: verified.binding,
                tier: item.minimumTier == "complete" ? .complete : .lite,
                selections: [.init(itemID: item.itemID, revisionID: item.revisionID, mode: mode)], confirmedAt: Date())
            _ = try verified.selectedFiles(for: request)
            try start(request: request, removeOnly: false, allowsCellular: allowsCellular)
        } catch { message = error.localizedDescription }
    }

    /// The review sheet supplies its frozen request so a later catalog refresh
    /// cannot change the edition or destructive mode the user confirmed.
    func install(request: ArkFileContentReleaseRequest, allowsCellular: Bool = false) {
        guard !isBusy, !ArkFileContentPackInstaller.shared.isBusy else { return }
        do {
            let verified = try provider.verifiedRelease(request.binding)
            _ = try verified.selectedFiles(for: request)
            try start(request: request, removeOnly: false, allowsCellular: allowsCellular)
        } catch { message = error.localizedDescription }
    }

    func installInstalled(itemID: String, mode: ArkFileContentRevisionSelection.Mode = .staged,
                          allowsCellular: Bool = false) {
        do {
            guard let receipt = installed[itemID] else { throw ArkFileContentReleaseError.staleSelection }
            let verified = try provider.verifiedRelease(receipt.binding)
            guard let item = verified.release.item(itemID), item.revisionID == receipt.revisionID else {
                throw ArkFileContentReleaseError.invalid("This older edition is no longer available. Choose an offered edition to download.")
            }
            install(request: .init(id: UUID(), binding: receipt.binding,
                tier: item.minimumTier == "complete" ? .complete : .lite,
                selections: [.init(itemID: itemID, revisionID: receipt.revisionID, mode: mode)], confirmedAt: Date()),
                allowsCellular: allowsCellular)
        } catch { message = error.localizedDescription }
    }

    func installedItemIDs() -> Set<String> {
        guard let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else { return [] }
        let entries = Dictionary(commit.payload.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(installed.values.filter { receipt in
            receipt.files.allSatisfy { file in
                let entry = entries[file.relativePath]
                return entry?.byteCount == file.sizeBytes && entry?.sha256 == file.sha256
                    && ArkFileInstalledContentAccess.canRead(root.appendingPathComponent(file.relativePath))
            }
        }.map(\.itemID))
    }

    /// Removal is entirely local and remains available offline or after a refund.
    func remove(itemID: String) {
        guard !isBusy, !ArkFileContentPackInstaller.shared.isBusy else { return }
        do {
            try migrateKnownInstalledContent()
            guard let receipt = installed[itemID], isInstalled(itemID) else {
                throw ArkFileContentReleaseError.invalid("This item is not a verified managed installation.")
            }
            let verified = try provider.verifiedRelease(receipt.binding)
            guard let item = verified.release.item(itemID) else { throw ArkFileContentReleaseError.staleSelection }
            let dependent = installed.values.first { other in
                guard other.itemID != itemID, isInstalled(other.itemID),
                      let otherRelease = try? provider.verifiedRelease(other.binding),
                      let otherItem = otherRelease.release.item(other.itemID) else { return false }
                let sharedFiles = otherRelease.release.files(for: Set(otherItem.groupIDs.filter { $0 != otherItem.primaryGroupID }))
                let removingPaths = Set(receipt.files.map { ArkFileContentReleaseVerifier.canonicalPath($0.relativePath) })
                return sharedFiles.contains { removingPaths.contains(ArkFileContentReleaseVerifier.canonicalPath($0.relativePath)) }
            }
            if let dependent {
                throw ArkFileContentReleaseError.invalid("Remove \(dependent.catalog.name) before removing its shared map foundation.")
            }
            let request = ArkFileContentReleaseRequest(id: UUID(), binding: receipt.binding,
                tier: item.minimumTier == "complete" ? .complete : .lite,
                selections: [.init(itemID: itemID, revisionID: receipt.revisionID, mode: .staged)], confirmedAt: Date())
            try start(request: request, removeOnly: true, allowsCellular: false)
        } catch { message = error.localizedDescription }
    }

    func resume(allowsCellular: Bool = false) {
        guard !isBusy, !ArkFileContentPackInstaller.shared.isBusy, let journal, !journal.isTerminal else { return }
        run(journal, allowsCellular: allowsCellular)
    }

    /// Pausing retains verified parts and the old-removal journal. It never
    /// pretends a deleted title is usable while its replacement is incomplete.
    func pause() {
        guard canPause else { return }
        task?.cancel()
        if let journal, let release = try? provider.verifiedRelease(journal.request.binding),
           let files = try? release.selectedFiles(for: journal.request) {
            for file in files {
                ArkFileContentBackgroundDownloadService.shared.cancel(recordID: ArkFileContentBackgroundDownloadRecord.id(for: file.manifestEntry))
            }
        }
    }

    func cancel() async {
        guard canCancel else { return }
        pause()
        // Keep new work and repeated cancellation out until discard finishes,
        // including the interval after the running transfer has stopped.
        isCancelling = true
        defer { isCancelling = false }
        await task?.value
        guard journal?.isTerminal == false else { return }
        guard var journal, !journal.requiresRecoveryBarrier else {
            message = "Finish interrupted removal before cancelling this update."; return
        }
        do {
            let verified = try provider.verifiedRelease(journal.request.binding)
            let files = journal.removeOnly ? [] : try verified.selectedFiles(for: journal.request)
            for file in files {
                _ = await ArkFileContentBackgroundDownloadService.shared.cancelAndDiscard(
                    recordID: ArkFileContentBackgroundDownloadRecord.id(for: file.manifestEntry),
                    expectedDownloadRoot: ArkFileContentDownloadPaths.managedDownloadRoot(in: try ArkFileContentPackInstaller.protectedActiveContentRoot().deletingLastPathComponent().deletingLastPathComponent()))
            }
            journal.phase = .cancelled; journal.message = "Cancelled. Removed content can be downloaded again."
            try save(journal)
            authorizationStore.delete(reference: tokenReference(journal.request))
        } catch { message = error.localizedDescription }
    }

    private func start(request: ArkFileContentReleaseRequest, removeOnly: Bool, allowsCellular: Bool) throws {
        if let pending = journal, !pending.isTerminal {
            throw ArkFileContentReleaseError.invalid("Resume or cancel the current content update first.")
        }
        let journal = ArkFileContentReplacementJournal(request: request, removeOnly: removeOnly)
        try save(journal)
        run(journal, allowsCellular: allowsCellular)
    }
    private func run(_ initial: ArkFileContentReplacementJournal, allowsCellular: Bool) {
        isRunning = true; message = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil }
            do { try await self.perform(initial, allowsCellular: allowsCellular) }
            catch {
                var failed = self.journal ?? initial
                if failed.phase == .quiescing {
                    failed.oldFiles = []; failed.priorCommit = nil; failed.removedCommit = nil
                }
                if !failed.requiresRecoveryBarrier {
                    failed.phase = error is CancellationError ? .paused : .failed
                }
                failed.message = error is CancellationError ? "Paused. Resume to continue the same edition." : error.localizedDescription
                try? self.save(failed); self.message = failed.message
            }
        }
    }
    private func perform(_ initial: ArkFileContentReplacementJournal, allowsCellular: Bool) async throws {
        var work = initial
        let root = try ArkFileContentPackInstaller.protectedActiveContentRoot()
        let downloads = ArkFileContentDownloadPaths.managedDownloadRoot(in: root.deletingLastPathComponent().deletingLastPathComponent())
        let verified = try provider.verifiedRelease(work.request.binding)
        let files = work.removeOnly ? [] : try verified.selectedFiles(for: work.request)
        let manifest = work.removeOnly ? nil : try verified.manifest(for: work.request)
        let api = try makeAPI()
        try ArkFileDataProtection.createProtectedDirectory(at: downloads)
        if work.requiresRecoveryBarrier {
            try await recoverRemoval(&work, root: root)
        }
        // Activation may have committed just before the process exited. Its
        // local metadata completion never depends on another purchase/network
        // check, including when access was subsequently refunded.
        if !work.removeOnly, work.phase != .prepared,
           allTargetsCommitted(files, binding: work.request.binding, root: root) {
            try await removeOldContent(&work, release: verified.release, root: root, stagedRetirement: true)
            try await finishInstallation(&work, verified: verified)
            return
        }
        var authorization: ArkFileContentAuthorization?
        var lease: ArkFileStoreKitAcquisitionLease?
        if !work.removeOnly {
            try await ArkFileContentPackInstaller.shared.ensureLargeDownloadNetworkIsReady(allowsCellularDownload: allowsCellular)
            authorization = try await mint(work.request, allowsCellular: allowsCellular)
            lease = try ArkFileLitePurchaseManager.shared.makeAcquisitionLease(for: work.request.tier)
            // Prove every target is deliverable before removing any old bytes.
            for file in files {
                try Task.checkCancellation()
                try await api.preflightReleaseFile(file, binding: work.request.binding, authorization: authorization!)
            }
            try await ArkFileContentBackgroundDownloadService.shared.quiesceStaleDownloads(for: manifest!, downloadRoot: downloads)
        }
        if work.oldFiles.isEmpty && (work.removeOnly || work.request.selections.contains { $0.mode == .deleteFirst }) {
            try await removeOldContent(&work, release: verified.release, root: root)
        }
        if work.removeOnly {
            work.phase = .installed; work.message = "Removed from this device. Saved links are kept for redownload."
            try save(work); message = work.message; return
        }
        try Task.checkCancellation()
        let priorReleases = ArkFileContentPackInstaller.verifiedReleasesForInstalledContent(
            commit: ArkFileInstalledContentAccess.currentCommitRecord(at: root), provider: provider)
        let trust = try ArkFileTrustedPackageManifest(verifiedRelease: verified, request: work.request,
                                                       previousVerifiedReleases: priorReleases)
        let selectedGroupIDs = Set(work.request.selections.flatMap { verified.release.item($0.itemID)?.groupIDs ?? [] })
        let groups = verified.release.groups.filter { selectedGroupIDs.contains($0.groupID) }
        var downloadedNewBytes = false
        totalBytes = files.reduce(0) { $0 + $1.sizeBytes }; completedBytes = 0
        for group in groups {
            try Task.checkCancellation()
            try ArkFileLitePurchaseManager.shared.validateAcquisitionLease(lease!)
            let members = group.fileIDs.compactMap(verified.release.file)
            try checkCapacity(members, root: root, downloads: downloads)
            // A preceding dependency may already be committed. Verification of
            // the next group is interruptible again until activation starts.
            work.phase = .verifying; try save(work)
            var candidates: [ArkFileContentActivationCandidate] = []
            for file in members {
                let beforeFile = completedBytes
                try Task.checkCancellation()
                let entry = file.manifestEntry
                let destination = root.appendingPathComponent(file.relativePath)
                var staged: URL?
                if !(await ArkFileContentPackInstaller.fileMatchesInBackground(destination, entry: entry)) {
                    let partial = ArkFileContentDownloadPaths.partialDownloadURL(for: entry, in: downloads)
                    if !(await ArkFileContentPackInstaller.fileMatchesInBackground(partial, entry: entry)) {
                        if authorization!.expiresAt.map({ $0 < Date().addingTimeInterval(300) }) != false {
                            authorization = try await mint(work.request, allowsCellular: allowsCellular)
                        }
                        work.phase = .downloading; try save(work)
                        let before = completedBytes
                        var renewalAttempts = 0
                        while true {
                            do {
                                let downloadURL = try await api.releaseFileURL(file, binding: work.request.binding)
                                try await ArkFileContentBackgroundDownloadService.shared.download(manifest: manifest!, entry: entry,
                                    from: downloadURL, authorization: authorization!, to: partial,
                                    progress: { [weak self] bytes, _ in self?.completedBytes = before + bytes })
                                downloadedNewBytes = true
                                break
                            } catch {
                                if case ArkFileContentError.confirmedStoreKitRefund(let productIDs) = error {
                                    await ArkFileLitePurchaseManager.shared.applyConfirmedRefund(productIDs: productIDs,
                                                                                                cancelCurrentInstallTask: false)
                                    throw error
                                }
                                guard !(error is CancellationError), renewalAttempts == 0,
                                      ArkFileContentPackInstaller.isAuthorizationExpiredOrRejected(error) else { throw error }
                                renewalAttempts += 1
                                authorization = try await mint(work.request, allowsCellular: allowsCellular)
                            }
                        }
                    }
                    work.phase = .verifying; try save(work)
                    guard await ArkFileContentPackInstaller.fileMatchesInBackground(partial, entry: entry) else {
                        throw ArkFileContentActivationError.missingVerifiedReplacement(file.relativePath)
                    }
                    staged = partial
                }
                completedBytes = beforeFile + file.sizeBytes
                candidates.append(.init(relativePath: file.relativePath, manifestEntry: entry,
                    tier: group.minimumTier == "complete" ? .complete : .lite, stagedURL: staged))
            }
            try ArkFileLitePurchaseManager.shared.validateAcquisitionLease(lease!)
            work.phase = .activating; try save(work)
            await HotspotObservable.shared.stopForAppBackground()
            let gateGroups = Set(members.map { ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath) })
            try await quiesce(id: work.request.id, groups: gateGroups)
            defer { ArkFileManagedContentConcurrencyGate.endQuiescing(id: work.request.id) }
            // Compatibility planner keeps native map and multipart groups atomic.
            let nativeGroups = Dictionary(grouping: candidates) { ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath) }
            for (nativeID, candidates) in nativeGroups.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try Task.checkCancellation()
                let installedTier: ArkFileContentTier = ArkFileInstalledContentAccess.currentCommitRecord(at: root)?.payload.installedTier == "complete"
                    ? .complete : work.request.tier
                try await ArkFileContentPackInstaller.activateAfterValidatingAcquisitionLease(
                    { try ArkFileLitePurchaseManager.shared.validateAcquisitionLease(lease!) },
                    activation: {
                        try ArkFileContentActivationCoordinator.activate(
                            groupID: nativeID.rawValue, candidates: candidates,
                            activeRoot: root, downloadRoot: downloads,
                            installedTier: installedTier, trustedManifest: trust)
                    })
            }
            await ZimFileService.shared.purgeUnpinnedArchives()
            ArkFileManagedContentConcurrencyGate.endQuiescing(id: work.request.id)
        }
        // Retire obsolete paths only after the replacement is committed and
        // semantically readable. Stable-path overwrites remain the activation
        // journal's staged rollback operation.
        try await removeOldContent(&work, release: verified.release, root: root, stagedRetirement: true)
        try await finishInstallation(&work, verified: verified)
        #if os(iOS)
        if downloadedNewBytes { ArkFileAdMeasurement.shared.recordFirstContentReady() }
        #endif
    }

    private func allTargetsCommitted(_ files: [ArkFileContentRelease.File],
                                     binding: ArkFileContentReleaseBinding, root: URL) -> Bool {
        guard !files.isEmpty, let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else { return false }
        return files.allSatisfy { file in commit.payload.entries.contains { entry in
            entry.relativePath == file.relativePath && entry.byteCount == file.sizeBytes && entry.sha256 == file.sha256
                && entry.manifestProvenance?.manifestID == "v2-" + binding.releaseID
                && entry.manifestProvenance?.semanticFingerprint == binding.releaseSHA256
        } }
    }

    private func finishInstallation(_ work: inout ArkFileContentReplacementJournal,
                                    verified: ArkFileVerifiedContentRelease) async throws {
        for selection in work.request.selections {
            guard let item = verified.release.item(selection.itemID) else { continue }
            let previousPaths = installed[item.itemID].map { $0.legacyPaths + [$0.catalog.relativePath] } ?? []
            try provider.recordInstalled(item, from: verified, legacyPaths: previousPaths)
            work.completedItemIDs.append(item.itemID)
        }
        work.phase = .installed; work.message = "Selected content is ready offline."; try save(work)
        authorizationStore.delete(reference: tokenReference(work.request))
        await ArkFileLocalContentLibrary.shared.refresh()
        message = work.message
    }

    private func removeOldContent(_ work: inout ArkFileContentReplacementJournal,
                                  release: ArkFileContentRelease, root: URL,
                                  stagedRetirement: Bool = false) async throws {
        var ids = Set(work.request.selections.filter { stagedRetirement || work.removeOnly || $0.mode == .deleteFirst }.map(\.itemID))
        // A confirmed variant replacement removes only the managed old variant
        // in that exclusive family, never another encyclopedia/import.
        for selection in work.request.selections where stagedRetirement || selection.mode == .deleteFirst {
            if let family = release.item(selection.itemID)?.catalog.variantGroup {
                ids.formUnion(installed.values.filter { $0.catalog.variantGroup == family }.map(\.itemID))
            }
        }
        let receipts = ids.compactMap { installed[$0] }.filter { stagedRetirement || isInstalled($0.itemID) }
        if receipts.isEmpty { return }
        guard let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else {
            throw ArkFileContentReleaseError.invalid("No verified installed content to replace.")
        }
        let targetPaths = Set(release.files(for: Set(work.request.selections.flatMap {
            release.item($0.itemID)?.groupIDs ?? []
        })).map(\.relativePath))
        let oldFiles = receipts.flatMap(\.files).filter { file in
            !stagedRetirement || (!targetPaths.contains(file.relativePath) && commit.payload.entries.contains {
                $0.relativePath == file.relativePath && $0.sha256 == file.sha256 && $0.byteCount == file.sizeBytes
            })
        }
        let paths = Set(oldFiles.map(\.relativePath))
        if paths.isEmpty { return }
        work.oldFiles = []
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(at: root),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent(ArkFileContentActivationCoordinator.journalFileName).path) else {
            throw ArkFileManagedContentDeletionError.pendingActivation
        }
        let oldEntries = commit.payload.entries.filter { paths.contains($0.relativePath) }
        guard oldEntries.count == paths.count else { throw ArkFileContentReleaseError.staleSelection }
        for entry in oldEntries {
            var status = Darwin.stat()
            guard Darwin.lstat(root.appendingPathComponent(entry.relativePath).path, &status) == 0,
                  status.st_nlink == 1 else {
                throw ArkFileContentReleaseError.invalid("An earlier content operation still holds this file. Close readers and retry after cleanup.")
            }
            guard entry.sha256 != nil, let identity = ArkFileOpenFileIdentity.capture(noFollowURL: root.appendingPathComponent(entry.relativePath)),
                  identity.byteCount == entry.byteCount else { throw ArkFileContentReleaseError.staleSelection }
            work.oldFiles.append(.init(entry: entry, identity: identity))
        }
        if !work.removeOnly && !stagedRetirement {
            let targetFiles = release.files(for: Set(work.request.selections.flatMap { release.item($0.itemID)?.groupIDs ?? [] }))
            let wanted = targetFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let reclaimed = oldEntries.reduce(Int64(0)) { $0 + $1.byteCount }
            let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            guard ArkFileContentReplacementStoragePolicy.hasCapacity(capacity, remainingBytes: wanted, reclaimableBytes: reclaimed) else {
                throw ArkFileContentReleaseError.invalid("There is not enough space for this replacement even after removing the selected old content.")
            }
        }
        let keys = Set(paths.map { $0.lowercased() })
        let remaining = commit.payload.entries.filter { !keys.contains($0.relativePath.lowercased()) }
        work.priorCommit = commit
        work.removedCommit = remaining.isEmpty
            ? try ArkFileInstalledContentAccess.makeExplicitEmptyCommitRecord(installedTier: work.request.tier, explicitlyRemovedPaths: keys)
            : try ArkFileInstalledContentAccess.makeMergedCommitRecord(previous: commit, replacingGroupPaths: keys, with: [],
                installedTier: ArkFileContentTier.iOSInstallableTier(named: commit.payload.installedTier) ?? work.request.tier,
                explicitlyRemovingPaths: keys)
        work.phase = .quiescing; try save(work)
        let groups = Set(oldEntries.map { ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath) })
        await HotspotObservable.shared.stopForAppBackground()
        try await quiesce(id: work.request.id, groups: groups)
        defer { ArkFileManagedContentConcurrencyGate.endQuiescing(id: work.request.id) }
        guard let writer = ArkFileManagedContentConcurrencyGate.tryBeginWriterReservation() else {
            throw ArkFileManagedContentDeletionError.contentChangeInProgress
        }
        defer { writer.release() }
        guard ArkFileInstalledContentAccess.currentCommitRecord(at: root) == commit else { throw ArkFileContentReleaseError.staleSelection }
        work.phase = .removing; try save(work)
        try ArkFileContentReplacementStore.finishRemoval(&work, at: root, writer: writer)
        try save(work)
    }

    private func recoverRemoval(_ work: inout ArkFileContentReplacementJournal, root: URL) async throws {
        let groups = Set(work.oldFiles.map { ArkFileContentCompatibilityPlanner.groupID(for: $0.entry.relativePath) })
        await HotspotObservable.shared.stopForAppBackground()
        try await quiesce(id: work.request.id, groups: groups)
        defer { ArkFileManagedContentConcurrencyGate.endQuiescing(id: work.request.id) }
        guard let writer = ArkFileManagedContentConcurrencyGate.tryBeginWriterReservation() else {
            throw ArkFileManagedContentDeletionError.contentChangeInProgress
        }
        defer { writer.release() }
        try ArkFileContentReplacementStore.finishRemoval(&work, at: root, writer: writer)
        try save(work)
    }

    private func quiesce(id: UUID, groups: Set<ArkFileContentCompatibilityGroupID>) async throws {
        try await Self.waitForReaders(id: id, groups: groups)
    }
    static func waitForReaders(id: UUID, groups: Set<ArkFileContentCompatibilityGroupID>,
                               timeout: TimeInterval = 30) async throws {
        ArkFileManagedContentConcurrencyGate.beginQuiescing(id: id, groups: groups)
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let pinned = await ZimFileService.shared.hasPinnedArchives
                if !ArkFileManagedContentConcurrencyGate.hasReaders(overlapping: groups) && !pinned { break }
                try Task.checkCancellation()
                guard Date() < deadline else { throw ArkFileManagedContentDeletionError.contentInUse }
                try await Task.sleep(for: .milliseconds(100))
            }
            await ZimFileService.shared.purgeUnpinnedArchives()
        } catch {
            ArkFileManagedContentConcurrencyGate.endQuiescing(id: id); throw error
        }
    }
    private func mint(_ request: ArkFileContentReleaseRequest, allowsCellular: Bool) async throws -> ArkFileContentAuthorization {
        let reference = tokenReference(request)
        let previousHeaders = authorizationStore.headers(reference: reference)
            ?? authorizationStore.headers(reference: "release-v2-binding-" + request.binding.releaseSHA256)
        let prior = previousHeaders?["Authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let authorization = try await ArkFileLitePurchaseManager.shared.releaseAuthorization(for: request,
            allowsCellular: allowsCellular, previousContentAccessToken: prior)
        guard authorizationStore.save(authorization.headers, reference: reference) else {
            throw ArkFileStoreKitMintError.contentAccessPersistenceFailed
        }
        guard authorizationStore.save(authorization.headers, reference: "release-v2-binding-" + request.binding.releaseSHA256) else {
            throw ArkFileStoreKitMintError.contentAccessPersistenceFailed
        }
        return authorization
    }
    private func tokenReference(_ request: ArkFileContentReleaseRequest) -> String { "release-v2-" + request.id.uuidString }
    private func save(_ work: ArkFileContentReplacementJournal) throws {
        var copy = work; copy.updatedAt = Date()
        try ArkFileContentReplacementStore.save(copy, at: ArkFileContentPackInstaller.protectedActiveContentRoot())
        journal = copy
    }
    private func makeAPI() throws -> ArkFileContentAPI {
        guard let url = URL(string: Brand.arkFileSiteURL) else { throw ArkFileContentError.invalidSiteURL }
        return try ArkFileContentAPI(siteURL: url)
    }
    private func checkCapacity(_ files: [ArkFileContentRelease.File], root: URL, downloads: URL) throws {
        var remaining: Int64 = 0
        for file in files {
            let active = root.appendingPathComponent(file.relativePath)
            let committed = ArkFileInstalledContentAccess.committedArtifactIdentity(for: active)
            if committed?.sha256 == file.sha256 && committed?.byteCount == file.sizeBytes { continue }
            let partial = ArkFileContentDownloadPaths.partialDownloadURL(for: file.manifestEntry, in: downloads)
            let bytes = ArkFileOpenFileIdentity.capture(noFollowURL: partial)?.byteCount ?? 0
            remaining += max(0, file.sizeBytes - bytes)
        }
        let values = try downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard ArkFileContentReplacementStoragePolicy.hasCapacity(values.volumeAvailableCapacityForImportantUsage,
                                                                   remainingBytes: remaining) else {
            throw ArkFileContentReleaseError.invalid("More free storage is needed for the selected content and its download buffer.")
        }
    }
    func legacyItemIDs() -> Set<String> {
        guard let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root),
              let candidates = try? provider.migrationEntries() else { return [] }
        let entries = Dictionary(commit.payload.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(candidates.filter { candidate in
            installed[candidate.itemID] == nil && !candidate.files.isEmpty && candidate.files.allSatisfy {
                entries[$0.relativePath]?.byteCount == $0.sizeBytes
            }
        }.map(\.itemID))
    }

    /// One explicit local verification upgrades known hashless legacy authority
    /// without acquiring content or changing files. Unknown/imported bytes stay
    /// legacy; this is never inferred from a filename alone.
    func verifyLegacy(itemID: String) {
        guard !isBusy, !ArkFileContentPackInstaller.shared.isBusy else { return }
        isRunning = true; message = "Verifying the installed edition on this device…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil }
            do {
                let root = try ArkFileContentPackInstaller.protectedActiveContentRoot()
                guard let prior = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else {
                    throw ArkFileContentReleaseError.staleSelection
                }
                let candidates = try self.provider.migrationEntries().filter { $0.itemID == itemID }
                var matches: [ArkFileContentReleaseProvider.Migration.Entry] = []
                for candidate in candidates {
                    guard candidate.files.allSatisfy({ file in prior.payload.entries.contains {
                        $0.relativePath == file.relativePath && $0.byteCount == file.sizeBytes
                    } }) else { continue }
                    var matchesAll = true
                    for file in candidate.files {
                        try Task.checkCancellation()
                        if !(await ArkFileContentPackInstaller.fileMatchesInBackground(root.appendingPathComponent(file.relativePath), entry: file.manifestEntry)) {
                            matchesAll = false; break
                        }
                    }
                    if matchesAll { matches.append(candidate) }
                }
                guard matches.count == 1, let match = matches.first,
                      let writer = ArkFileManagedContentConcurrencyGate.tryBeginWriterReservation() else {
                    throw ArkFileContentReleaseError.invalid("This local edition could not be identified. It remains available as legacy content.")
                }
                defer { writer.release() }
                guard ArkFileInstalledContentAccess.currentCommitRecord(at: root) == prior else { throw ArkFileContentReleaseError.staleSelection }
                let oldEntries = Dictionary(prior.payload.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
                let entries = match.files.map { file in
                    ArkFileInstalledContentAccess.CommitEntry(relativePath: file.relativePath,
                        tier: oldEntries[file.relativePath]?.tier ?? "lite", byteCount: file.sizeBytes, sha256: file.sha256,
                        manifestProvenance: oldEntries[file.relativePath]?.manifestProvenance)
                }
                let next = try ArkFileInstalledContentAccess.makeMergedCommitRecord(previous: prior,
                    replacingGroupPaths: Set(entries.map { $0.relativePath.lowercased() }), with: entries,
                    installedTier: ArkFileContentTier.iOSInstallableTier(named: prior.payload.installedTier) ?? .lite,
                    trustedProjectionHash: prior.payload.manifestProjection?.projectionHash)
                try ArkFileInstalledContentAccess.installCommitRecordDurablyAndReload(next, at: root)
                try self.provider.adoptKnownBaselineInstallations()
                self.message = "Installed edition verified. It remains available offline."
            } catch { self.message = error.localizedDescription }
        }
    }

    func migrateKnownInstalledContent() throws {
        try provider.adoptKnownBaselineInstallations()
    }
}

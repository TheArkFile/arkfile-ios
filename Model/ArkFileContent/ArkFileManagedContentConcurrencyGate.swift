// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

extension Notification.Name {
    /// Posted after an activation mutation token is released. A reader that
    /// arrived while the short commit window was active may retry acquisition.
    static let arkFileManagedContentMutationDidEnd = Notification.Name(
        "ArkFileManagedContentMutationDidEnd"
    )
}

/// A lifetime token for a reader that must not have managed content paths
/// replaced underneath it. Release is synchronous, thread-safe, and idempotent.
final class ArkFileManagedContentReaderToken: @unchecked Sendable {
    fileprivate let registrationID: UUID
    private let releaseLock = NSLock()
    private var didRelease = false

    fileprivate init(registrationID: UUID) {
        self.registrationID = registrationID
    }

    var isReleased: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return didRelease
    }

    func release() {
        releaseLock.lock()
        guard !didRelease else {
            releaseLock.unlock()
            return
        }
        didRelease = true
        releaseLock.unlock()
        ArkFileManagedContentConcurrencyGate.releaseReader(registrationID)
    }

    deinit {
        release()
    }
}

/// Exclusive permission to replace the named compatibility groups. Activation
/// holds this only across overlay installation, path replacement, commit, and
/// recovery/cleanup -- never while downloading or hashing staged content.
final class ArkFileManagedContentMutationToken: @unchecked Sendable {
    fileprivate let registrationID: UUID
    let affectedGroups: Set<ArkFileContentCompatibilityGroupID>
    private let releaseLock = NSLock()
    private var didRelease = false

    fileprivate init(
        registrationID: UUID,
        affectedGroups: Set<ArkFileContentCompatibilityGroupID>
    ) {
        self.registrationID = registrationID
        self.affectedGroups = affectedGroups
    }

    var isReleased: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return didRelease
    }

    func release() {
        releaseLock.lock()
        guard !didRelease else {
            releaseLock.unlock()
            return
        }
        didRelease = true
        releaseLock.unlock()
        ArkFileManagedContentConcurrencyGate.releaseMutation(registrationID)
    }

    deinit {
        release()
    }
}

/// Serializes durable managed-content writers without blocking readers. It is
/// intentionally longer-lived than a path mutation token: activation holds it
/// before journal/commit planning through recovery and cleanup, while the
/// reader-priority mutation token still covers only the short namespace switch.
final class ArkFileManagedContentWriterToken: @unchecked Sendable {
    fileprivate let registrationID: UUID
    private let releaseLock = NSLock()
    private var didRelease = false

    fileprivate init(registrationID: UUID) {
        self.registrationID = registrationID
    }

    var isReleased: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return didRelease
    }

    func release() {
        releaseLock.lock()
        guard !didRelease else {
            releaseLock.unlock()
            return
        }
        didRelease = true
        releaseLock.unlock()
        ArkFileManagedContentConcurrencyGate.releaseWriter(registrationID)
    }

    deinit {
        release()
    }
}

/// Reader-priority coordination for the brief interval in which activation
/// changes authoritative paths. This deliberately does not wait: an existing
/// emergency reader makes an update defer, while a mutation that has already
/// begun makes a new overlapping reader retry after the commit window.
enum ArkFileManagedContentConcurrencyGate {
    /// Wildcard reservation used only for explicit whole-pack deletion. It
    /// overlaps every reader and every group mutation, including a group that
    /// is not present in the current install commit yet.
    private static let allManagedContentGroup = ArkFileContentCompatibilityGroupID(
        rawValue: "arkfile:all-managed-content"
    )

    private enum ReaderScope {
        case maps
        case allManagedContent

        func overlaps(_ groups: Set<ArkFileContentCompatibilityGroupID>) -> Bool {
            switch self {
            case .maps:
                groups.contains(ArkFileManagedContentConcurrencyGate.allManagedContentGroup)
                    || groups.contains(where: \.requiresExclusivePathReaderGate)
            case .allManagedContent:
                !groups.isEmpty
            }
        }
    }

    struct Snapshot: Equatable {
        let activeMapReaders: Int
        let activeAllContentReaders: Int
        let activeMutations: Int
        let activeWriters: Int
    }

    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var readers: [UUID: ReaderScope] = [:]
    private nonisolated(unsafe) static var mutations: [
        UUID: Set<ArkFileContentCompatibilityGroupID>
    ] = [:]
    private nonisolated(unsafe) static var activeWriter: UUID?
    private nonisolated(unsafe) static var quiescing: [UUID: Set<ArkFileContentCompatibilityGroupID>] = [:]

    /// Reserves reader admission before draining existing leases. Holding a
    /// writer token alone deliberately does not stop readers.
    static func beginQuiescing(id: UUID, groups: Set<ArkFileContentCompatibilityGroupID>) {
        stateLock.lock(); quiescing[id] = groups; stateLock.unlock()
    }
    static func endQuiescing(id: UUID) {
        stateLock.lock(); quiescing.removeValue(forKey: id); stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .arkFileManagedContentMutationDidEnd, object: nil)
        }
    }
    static func hasReaders(overlapping groups: Set<ArkFileContentCompatibilityGroupID>) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return readers.values.contains { $0.overlaps(groups) }
    }

    /// Reserves the single install commit, activation journal, and global
    /// overlay for one durable transaction. Readers remain unaffected.
    static func tryBeginWriterReservation() -> ArkFileManagedContentWriterToken? {
        stateLock.lock()
        guard activeWriter == nil else {
            stateLock.unlock()
            return nil
        }
        let registrationID = UUID()
        activeWriter = registrationID
        stateLock.unlock()
        return ArkFileManagedContentWriterToken(registrationID: registrationID)
    }

    static func isActiveWriterReservation(
        _ token: ArkFileManagedContentWriterToken
    ) -> Bool {
        guard !token.isReleased else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeWriter == token.registrationID
    }

    /// Covers MapLibre and every map resource retained by its view lifetime.
    static func tryBeginMapRead() -> ArkFileManagedContentReaderToken? {
        tryBeginReader(scope: .maps)
    }

    /// Covers one ZIM scheme response from metadata lookup through its final
    /// streamed chunk, finish, failure, or cancellation. This applies to both
    /// LibZim-backed responses and direct media reads so a response can never
    /// combine metadata or chunks from two installed generations.
    static func tryBeginZIMResponseRead() -> ArkFileManagedContentReaderToken? {
        tryBeginReader(scope: .allManagedContent)
    }

    /// Compatibility spelling retained for non-scheme direct-reader callers.
    static func tryBeginDirectMediaRead() -> ArkFileManagedContentReaderToken? {
        tryBeginZIMResponseRead()
    }

    /// Covers Local Sharing from pre-start through complete server shutdown.
    static func tryBeginLocalSharingRead() -> ArkFileManagedContentReaderToken? {
        tryBeginReader(scope: .allManagedContent)
    }

    /// Attempts to reserve the named compatibility groups for the short path
    /// mutation window. Nil is an expected defer signal, not data loss: callers
    /// must preserve verified staging and avoid beginning path replacement.
    static func tryBeginMutation(
        affectedGroups: Set<ArkFileContentCompatibilityGroupID>,
        writerToken: ArkFileManagedContentWriterToken
    ) -> ArkFileManagedContentMutationToken? {
        guard !affectedGroups.isEmpty, !writerToken.isReleased else { return nil }
        stateLock.lock()
        guard activeWriter == writerToken.registrationID else {
            stateLock.unlock()
            return nil
        }
        let readerConflict = readers.values.contains {
            $0.overlaps(affectedGroups)
        }
        // There is one global install authority and one overlay/journal. Even
        // disjoint group swaps cannot overlap their short commit windows.
        let mutationConflict = !mutations.isEmpty
        guard !readerConflict, !mutationConflict else {
            stateLock.unlock()
            return nil
        }
        let registrationID = UUID()
        mutations[registrationID] = affectedGroups
        stateLock.unlock()
        return ArkFileManagedContentMutationToken(
            registrationID: registrationID,
            affectedGroups: affectedGroups
        )
    }

    static func tryBeginAllContentMutation(
        writerToken: ArkFileManagedContentWriterToken
    ) -> ArkFileManagedContentMutationToken? {
        tryBeginMutation(
            affectedGroups: [allManagedContentGroup],
            writerToken: writerToken
        )
    }

    private static func tryBeginReader(
        scope: ReaderScope
    ) -> ArkFileManagedContentReaderToken? {
        stateLock.lock()
        guard !mutations.values.contains(where: scope.overlaps),
              !quiescing.values.contains(where: scope.overlaps) else {
            stateLock.unlock()
            return nil
        }
        let registrationID = UUID()
        readers[registrationID] = scope
        stateLock.unlock()
        return ArkFileManagedContentReaderToken(registrationID: registrationID)
    }

    fileprivate static func releaseReader(_ registrationID: UUID) {
        stateLock.lock()
        readers.removeValue(forKey: registrationID)
        stateLock.unlock()
    }

    fileprivate static func releaseMutation(_ registrationID: UUID) {
        stateLock.lock()
        let didRelease = mutations.removeValue(forKey: registrationID) != nil
        stateLock.unlock()
        guard didRelease else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: .arkFileManagedContentMutationDidEnd,
                object: nil
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .arkFileManagedContentMutationDidEnd,
                    object: nil
                )
            }
        }
    }

    fileprivate static func releaseWriter(_ registrationID: UUID) {
        stateLock.lock()
        if activeWriter == registrationID {
            activeWriter = nil
        }
        stateLock.unlock()
    }

    static func snapshotForTesting() -> Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Snapshot(
            activeMapReaders: readers.values.filter {
                if case .maps = $0 { return true }
                return false
            }.count,
            activeAllContentReaders: readers.values.filter {
                if case .allManagedContent = $0 { return true }
                return false
            }.count,
            activeMutations: mutations.count,
            activeWriters: activeWriter == nil ? 0 : 1
        )
    }

    static func resetForTesting() {
        stateLock.lock()
        readers.removeAll()
        mutations.removeAll()
        quiescing.removeAll()
        activeWriter = nil
        stateLock.unlock()
    }
}

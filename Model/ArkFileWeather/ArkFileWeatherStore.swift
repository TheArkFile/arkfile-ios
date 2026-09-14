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

import CryptoKit
import Foundation

enum ArkFileWeatherStoreCopy: String, Equatable, Sendable {
    case current
    case previous
    case staged
}

enum ArkFileWeatherStoreOperation: String, Equatable, Sendable {
    case resolveApplicationSupport
    case prepareDirectory
    case read
    case write
    case protect
    case excludeFromBackup
    case delete
    case inspect
}

enum ArkFileWeatherValidationIssue: String, Equatable, Sendable {
    case unsupportedSchema
    case invalidLocation
    case invalidRevision
    case invalidComponentState
    case invalidStamp
    case excessiveCount
    case excessiveText
    case invalidValue
    case invalidDateRange
}

enum ArkFileWeatherStoreError: Error, Equatable, Sendable {
    case notFound
    case fileTooLarge
    case malformedEnvelope
    case checksumMismatch
    case invalidStorageObject
    case unsupportedEnvelopeVersion(Int)
    case unexpectedPayloadKind
    case invalidPayload(ArkFileWeatherValidationIssue)
    case io(ArkFileWeatherStoreOperation)
}

struct ArkFileWeatherStoreLoadResult<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    let value: Value?
    let source: ArkFileWeatherStoreCopy?
    let currentError: ArkFileWeatherStoreError?
    let previousError: ArkFileWeatherStoreError?

    var loadedPreviousAfterCurrentFailure: Bool {
        source == .previous && currentError != nil && currentError != .notFound
    }
}

struct ArkFileWeatherStoreFileURLs: Equatable, Sendable {
    let settingsCurrent: URL
    let settingsPrevious: URL
    let snapshotCurrent: URL
    let snapshotPrevious: URL
    let snapshotStaged: URL
    let deletionPending: URL

    var all: [URL] {
        [
            settingsCurrent,
            settingsPrevious,
            snapshotCurrent,
            snapshotPrevious,
            snapshotStaged
        ]
    }
}

struct ArkFileWeatherStoreStateRead: Equatable, Sendable {
    let settings: ArkFileWeatherStoreLoadResult<ArkFileWeatherSettings>
    let snapshot: ArkFileWeatherStoreLoadResult<ArkFileWeatherSnapshot>
    let storageSizeBytes: Int64
    let deletionPending: Bool
}

enum ArkFileWeatherSettingsMutation: Equatable, Sendable {
    case automaticRefreshEnabled(Bool)
    case refreshOnWiFiOnly(Bool)
    case unitPreference(ArkFileWeatherUnitPreference)
    case environmental(ArkFileWeatherEnvironmentalPreferences)
}

/// Durable, coordinate-bearing Saved Weather state.
///
/// Files are canonical JSON envelopes containing a versioned payload and a
/// SHA-256 corruption checksum. This is integrity detection, not encryption or
/// authentication. The actor owns all reads, rotation, and writes.
actor ArkFileWeatherStore {
    static let directoryName = "SavedWeather"

    private static let envelopeSchemaVersion = 1
    private static let maximumPayloadBytes = 5_000_000
    private static let maximumEnvelopeBytes = 7_000_000

    private enum PayloadKind: String {
        case settings
        case snapshot
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let payloadKind: String
        let payload: Data
        let sha256: String
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let removalOperation: (@Sendable (URL) throws -> Void)?
    private let deletionMarkerWriteOperation:
        (@Sendable (URL) throws -> Void)?

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        removalOperation: (@Sendable (URL) throws -> Void)? = nil,
        deletionMarkerWriteOperation:
            (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        self.removalOperation = removalOperation
        self.deletionMarkerWriteOperation = deletionMarkerWriteOperation
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ArkFileWeatherStoreError.io(.resolveApplicationSupport)
            }
            self.directoryURL = applicationSupport
                .appendingPathComponent("ArkFile", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        }
    }

    func fileURLs() -> ArkFileWeatherStoreFileURLs {
        ArkFileWeatherStoreFileURLs(
            settingsCurrent: directoryURL.appendingPathComponent(
                "settings-current-v1.json",
                isDirectory: false
            ),
            settingsPrevious: directoryURL.appendingPathComponent(
                "settings-previous-v1.json",
                isDirectory: false
            ),
            snapshotCurrent: directoryURL.appendingPathComponent(
                "snapshot-current-v1.json",
                isDirectory: false
            ),
            snapshotPrevious: directoryURL.appendingPathComponent(
                "snapshot-previous-v1.json",
                isDirectory: false
            ),
            snapshotStaged: directoryURL.appendingPathComponent(
                "snapshot-staged-v1.json",
                isDirectory: false
            ),
            deletionPending: directoryURL.appendingPathComponent(
                "deletion-pending-v1",
                isDirectory: false
            )
        )
    }

    /// A non-sensitive tombstone makes delete intent durable across partial
    /// filesystem failures and process termination. Any object at this fixed
    /// path is treated as pending; its contents are never trusted.
    func isDeletionPending() -> Bool {
        let marker = fileURLs().deletionPending
        if fileManager.fileExists(atPath: marker.path) {
            return true
        }
        // `fileExists` follows symlinks, so also recognize a dangling link.
        return (try? fileManager.destinationOfSymbolicLink(
            atPath: marker.path
        )) != nil
    }

    func loadSettings() -> ArkFileWeatherStoreLoadResult<ArkFileWeatherSettings> {
        let urls = fileURLs()
        return load(
            currentURL: urls.settingsCurrent,
            previousURL: urls.settingsPrevious,
            kind: .settings,
            type: ArkFileWeatherSettings.self,
            validate: Self.validate(settings:)
        )
    }

    func loadSnapshot() -> ArkFileWeatherStoreLoadResult<ArkFileWeatherSnapshot> {
        let urls = fileURLs()
        return load(
            currentURL: urls.snapshotCurrent,
            previousURL: urls.snapshotPrevious,
            kind: .snapshot,
            type: ArkFileWeatherSnapshot.self,
            validate: Self.validate(snapshot:)
        )
    }

    /// A followed-location commit stages the replacement snapshot before it
    /// changes settings. If the process ends between those writes, choose the
    /// verified generation whose revision still matches the durable location.
    func loadSnapshot(
        matchingLocationRevision expectedRevision: Int?
    ) -> ArkFileWeatherStoreLoadResult<ArkFileWeatherSnapshot> {
        guard let expectedRevision else {
            return loadSnapshot()
        }
        let urls = fileURLs()
        var currentError: ArkFileWeatherStoreError?
        do {
            let current = try read(
                from: urls.snapshotCurrent,
                kind: .snapshot,
                type: ArkFileWeatherSnapshot.self,
                validate: Self.validate(snapshot:)
            )
            if current.locationRevision == expectedRevision {
                return ArkFileWeatherStoreLoadResult(
                    value: current,
                    source: .current,
                    currentError: nil,
                    previousError: nil
                )
            }
        } catch {
            currentError = Self.normalized(error, operation: .read)
        }

        var stagedError: ArkFileWeatherStoreError?
        do {
            let staged = try read(
                from: urls.snapshotStaged,
                kind: .snapshot,
                type: ArkFileWeatherSnapshot.self,
                validate: Self.validate(snapshot:)
            )
            if staged.locationRevision == expectedRevision {
                return ArkFileWeatherStoreLoadResult(
                    value: staged,
                    source: .staged,
                    currentError: currentError,
                    previousError: nil
                )
            }
        } catch {
            let normalized = Self.normalized(error, operation: .read)
            if normalized != .notFound {
                stagedError = normalized
            }
        }

        do {
            let previous = try read(
                from: urls.snapshotPrevious,
                kind: .snapshot,
                type: ArkFileWeatherSnapshot.self,
                validate: Self.validate(snapshot:)
            )
            if previous.locationRevision == expectedRevision {
                return ArkFileWeatherStoreLoadResult(
                    value: previous,
                    source: .previous,
                    currentError: currentError ?? stagedError,
                    previousError: nil
                )
            }
            return ArkFileWeatherStoreLoadResult(
                value: nil,
                source: nil,
                currentError: currentError ?? stagedError,
                previousError: nil
            )
        } catch {
            return ArkFileWeatherStoreLoadResult(
                value: nil,
                source: nil,
                currentError: currentError ?? stagedError,
                previousError: Self.normalized(error, operation: .read)
            )
        }
    }

    /// Reads the complete presentation state without allowing another
    /// store operation to interleave between settings, snapshot, and size.
    func loadState() throws -> ArkFileWeatherStoreStateRead {
        let settings = loadSettings()
        return ArkFileWeatherStoreStateRead(
            settings: settings,
            snapshot: loadSnapshot(
                matchingLocationRevision:
                    settings.value?.savedLocation?.revision
            ),
            storageSizeBytes: try storageSizeBytes(),
            deletionPending: isDeletionPending()
        )
    }

    func saveSettings(_ settings: ArkFileWeatherSettings) throws {
        let urls = fileURLs()
        try save(
            settings,
            currentURL: urls.settingsCurrent,
            previousURL: urls.settingsPrevious,
            kind: .settings,
            validate: Self.validate(settings:)
        )
    }

    /// Allocates the next location revision and writes the replacement as one
    /// actor-isolated transaction. Concurrent selections therefore cannot
    /// share a revision or roll a newer location back to an older point.
    func replaceLocation(
        coordinate: ArkFileWeatherCoordinate,
        displayName: String,
        timeZoneIdentifier: String?,
        source: ArkFileWeatherLocationSource,
        measuredAt: Date?,
        horizontalAccuracyMeters: Double?,
        modifiedAt: Date,
        automaticRefreshEnabled: Bool? = nil
    ) throws -> ArkFileWeatherSettings {
        guard !Task.isCancelled else {
            throw ArkFileWeatherStoreError.io(.write)
        }
        let result = loadSettings()
        var settings: ArkFileWeatherSettings
        if let loaded = result.value {
            settings = loaded
        } else if Self.onlyMissingFiles(
            result.currentError,
            result.previousError
        ) {
            settings = ArkFileWeatherSettings(modifiedAt: modifiedAt)
        } else {
            throw result.currentError
                ?? result.previousError
                ?? ArkFileWeatherStoreError.io(.read)
        }

        let currentRevision = settings.savedLocation?.revision ?? 0
        let (revision, overflow) = currentRevision.addingReportingOverflow(1)
        guard !overflow, revision > 0 else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidRevision)
        }
        let location = ArkFileWeatherSavedLocation(
            id: settings.savedLocation?.id ?? UUID().uuidString,
            revision: revision,
            coordinate: coordinate,
            displayName: displayName,
            timeZoneIdentifier: timeZoneIdentifier,
            source: source,
            selectedAt: modifiedAt,
            measuredAt: measuredAt,
            horizontalAccuracyMeters: horizontalAccuracyMeters
        )
        settings.savedLocation = location
        if let automaticRefreshEnabled {
            settings.automaticRefreshEnabled = automaticRefreshEnabled
        }
        settings.modifiedAt = modifiedAt
        try saveSettings(settings)
        return settings
    }

    /// Commits a traveled Current Location only if the exact location that was
    /// used to preassemble the candidate forecast is still selected. Staging
    /// the snapshot before settings keeps either the old pair or the new pair
    /// readable across process interruption.
    func commitFollowedLocation(
        expectedRevision: Int,
        coordinate: ArkFileWeatherCoordinate,
        displayName: String,
        timeZoneIdentifier: String?,
        measuredAt: Date,
        horizontalAccuracyMeters: Double,
        snapshot: ArkFileWeatherSnapshot,
        modifiedAt: Date
    ) throws -> ArkFileWeatherSettings? {
        guard !Task.isCancelled else { return nil }
        let result = loadSettings()
        guard var settings = result.value,
              let current = settings.savedLocation,
              current.revision == expectedRevision,
              current.source == .currentLocation,
              settings.automaticRefreshEnabled else {
            if result.value == nil,
               !Self.onlyMissingFiles(
                   result.currentError,
                   result.previousError
               ) {
                throw result.currentError
                    ?? result.previousError
                    ?? ArkFileWeatherStoreError.io(.read)
            }
            return nil
        }

        let (revision, overflow) = expectedRevision.addingReportingOverflow(1)
        guard !overflow,
              revision > 0,
              snapshot.locationRevision == revision else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidRevision)
        }
        let followedLocation = ArkFileWeatherSavedLocation(
            id: current.id,
            revision: revision,
            coordinate: coordinate,
            displayName: displayName,
            timeZoneIdentifier: timeZoneIdentifier,
            source: .currentLocation,
            selectedAt: current.selectedAt,
            measuredAt: measuredAt,
            horizontalAccuracyMeters: horizontalAccuracyMeters
        )
        settings.savedLocation = followedLocation
        settings.modifiedAt = modifiedAt

        let urls = fileURLs()
        try saveStagedSnapshot(snapshot, to: urls.snapshotStaged)
        guard !Task.isCancelled else {
            try? removeItem(at: urls.snapshotStaged)
            return nil
        }
        try saveSettings(settings)

        // The staged snapshot already makes the new settings readable. Promote
        // it into the normal rotation when possible; a later regular refresh
        // will also clear any surviving staged copy.
        do {
            try saveSnapshot(snapshot)
            try? removeItem(at: urls.snapshotStaged)
        } catch {
            // Keep the verified staged copy. Returning success is truthful
            // because settings and a matching durable briefing are complete.
        }
        return settings
    }

    /// Applies a narrow preference mutation against the latest durable
    /// settings and writes it before leaving the store actor. This prevents
    /// concurrent toggles, timezone resolution, and location changes from
    /// overwriting one another with stale read/modify/write copies.
    func mutateSettings(
        _ mutation: ArkFileWeatherSettingsMutation,
        modifiedAt: Date
    ) throws -> ArkFileWeatherSettings {
        guard !Task.isCancelled else {
            throw ArkFileWeatherStoreError.io(.write)
        }
        let result = loadSettings()
        var settings: ArkFileWeatherSettings
        if let loaded = result.value {
            settings = loaded
        } else if Self.onlyMissingFiles(
            result.currentError,
            result.previousError
        ) {
            settings = ArkFileWeatherSettings(modifiedAt: modifiedAt)
        } else {
            throw result.currentError
                ?? result.previousError
                ?? ArkFileWeatherStoreError.io(.read)
        }

        switch mutation {
        case let .automaticRefreshEnabled(enabled):
            settings.automaticRefreshEnabled = enabled
        case let .refreshOnWiFiOnly(enabled):
            settings.refreshOnWiFiOnly = enabled
        case let .unitPreference(preference):
            settings.unitPreference = preference
        case let .environmental(preferences):
            settings.environmental = preferences
        }
        settings.modifiedAt = modifiedAt
        try saveSettings(settings)
        return settings
    }

    /// Persists provider-resolved timezone metadata without replaying a stale
    /// copy of unrelated user preferences. The revision check and narrow
    /// mutation are atomic within this actor.
    @discardableResult
    func updateLocationTimeZone(
        _ identifier: String,
        ifCurrentLocationRevision expectedRevision: Int,
        modifiedAt: Date
    ) throws -> Bool {
        guard !Task.isCancelled else { return false }
        guard TimeZone(identifier: identifier) != nil else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidLocation)
        }
        let result = loadSettings()
        guard var settings = result.value,
              let location = settings.savedLocation,
              location.revision == expectedRevision else {
            if result.value == nil,
               (
                   result.currentError != .notFound
                       || result.previousError != .notFound
               ) {
                throw result.currentError
                    ?? result.previousError
                    ?? ArkFileWeatherStoreError.io(.read)
            }
            return false
        }
        guard location.timeZoneIdentifier != identifier else {
            return true
        }
        settings.savedLocation = ArkFileWeatherSavedLocation(
            id: location.id,
            revision: location.revision,
            coordinate: location.coordinate,
            displayName: location.displayName,
            timeZoneIdentifier: identifier,
            source: location.source,
            selectedAt: location.selectedAt,
            measuredAt: location.measuredAt,
            horizontalAccuracyMeters: location.horizontalAccuracyMeters
        )
        settings.modifiedAt = modifiedAt
        try saveSettings(settings)
        return true
    }

    func saveSnapshot(_ snapshot: ArkFileWeatherSnapshot) throws {
        let urls = fileURLs()
        try save(
            snapshot,
            currentURL: urls.snapshotCurrent,
            previousURL: urls.snapshotPrevious,
            kind: .snapshot,
            validate: Self.validate(snapshot:)
        )
    }

    /// Commits a refresh only while the durable selected-location revision
    /// still matches the flight that produced it. The read and write are one
    /// actor-isolated operation, so a location change cannot slip between a
    /// coordinator's revision check and the snapshot replacement.
    @discardableResult
    func saveSnapshot(
        _ snapshot: ArkFileWeatherSnapshot,
        ifCurrentLocationRevision expectedRevision: Int
    ) throws -> Bool {
        guard !Task.isCancelled else { return false }
        let settingsResult = loadSettings()
        guard settingsResult.value?.savedLocation?.revision == expectedRevision,
              snapshot.locationRevision == expectedRevision else {
            return false
        }
        try saveSnapshot(snapshot)
        let staged = fileURLs().snapshotStaged
        if fileManager.fileExists(atPath: staged.path) {
            try? removeItem(at: staged)
        }
        return true
    }

    /// Deletes only the four payload files owned by this store. A fixed,
    /// non-sensitive tombstone remains if any deletion fails, preventing
    /// refresh or mutation from recreating data after a user's erase request.
    /// An injected directory can safely contain unrelated test/future state.
    @discardableResult
    func deleteAll() throws -> Int {
        let urls = fileURLs()
        let marker = urls.deletionPending
        do {
            try prepareDirectory()
            if !isDeletionPending() {
                if let deletionMarkerWriteOperation {
                    try deletionMarkerWriteOperation(marker)
                } else {
                    try writeAtomically(Data("pending\n".utf8), to: marker)
                }
            }
            guard isDeletionPending() else {
                throw ArkFileWeatherStoreError.io(.delete)
            }
        } catch {
            // Creating durable delete intent is the commit boundary. If it
            // cannot be recorded, leave every payload untouched.
            throw ArkFileWeatherStoreError.io(.delete)
        }

        let targets = urls.all
        var deleted = 0
        var encounteredFailure = false
        for target in targets where fileManager.fileExists(atPath: target.path) {
            do {
                try removeItem(at: target)
                if fileManager.fileExists(atPath: target.path) {
                    encounteredFailure = true
                } else {
                    deleted += 1
                }
            } catch {
                encounteredFailure = true
            }
        }
        if encounteredFailure {
            throw ArkFileWeatherStoreError.io(.delete)
        }

        do {
            try removeItem(at: marker)
            guard !isDeletionPending() else {
                throw ArkFileWeatherStoreError.io(.delete)
            }
        } catch {
            throw ArkFileWeatherStoreError.io(.delete)
        }
        return deleted
    }

    func storageSizeBytes() throws -> Int64 {
        var total: Int64 = 0
        for url in fileURLs().all where fileManager.fileExists(atPath: url.path) {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                throw ArkFileWeatherStoreError.io(.inspect)
            }
        }
        return total
    }

    // MARK: - Envelope IO

    private func load<Value>(
        currentURL: URL,
        previousURL: URL,
        kind: PayloadKind,
        type: Value.Type,
        validate: (Value) throws -> Void
    ) -> ArkFileWeatherStoreLoadResult<Value>
    where Value: Codable & Equatable & Sendable {
        do {
            let current = try read(
                from: currentURL,
                kind: kind,
                type: type,
                validate: validate
            )
            return ArkFileWeatherStoreLoadResult(
                value: current,
                source: .current,
                currentError: nil,
                previousError: nil
            )
        } catch {
            let currentError = Self.normalized(error, operation: .read)
            do {
                let previous = try read(
                    from: previousURL,
                    kind: kind,
                    type: type,
                    validate: validate
                )
                return ArkFileWeatherStoreLoadResult(
                    value: previous,
                    source: .previous,
                    currentError: currentError,
                    previousError: nil
                )
            } catch {
                return ArkFileWeatherStoreLoadResult(
                    value: nil,
                    source: nil,
                    currentError: currentError,
                    previousError: Self.normalized(error, operation: .read)
                )
            }
        }
    }

    private func save<Value>(
        _ value: Value,
        currentURL: URL,
        previousURL: URL,
        kind: PayloadKind,
        validate: (Value) throws -> Void
    ) throws where Value: Codable & Equatable & Sendable {
        do {
            guard !isDeletionPending() else {
                throw ArkFileWeatherStoreError.io(.delete)
            }
            try validate(value)
            try prepareDirectory()
            let newData = try envelopeData(for: value, kind: kind)

            // Rotate only a fully verified current file. If the current bytes
            // are corrupt or from an unknown future schema, refuse to
            // overwrite them. Recovery may read the previous copy, but only
            // the explicit Reset Saved Weather action may clear the evidence.
            if fileManager.fileExists(atPath: currentURL.path) {
                let currentData = try verifiedEnvelopeData(
                   at: currentURL,
                   kind: kind,
                   type: Value.self,
                   validate: validate
                )
                try writeAtomically(currentData, to: previousURL)
            }

            try writeAtomically(newData, to: currentURL)
        } catch {
            throw Self.normalized(error, operation: .write)
        }
    }

    private func saveStagedSnapshot(
        _ snapshot: ArkFileWeatherSnapshot,
        to url: URL
    ) throws {
        do {
            guard !isDeletionPending() else {
                throw ArkFileWeatherStoreError.io(.delete)
            }
            try Self.validate(snapshot: snapshot)
            try prepareDirectory()
            try writeAtomically(
                envelopeData(for: snapshot, kind: .snapshot),
                to: url
            )
        } catch {
            throw Self.normalized(error, operation: .write)
        }
    }

    private func read<Value>(
        from url: URL,
        kind: PayloadKind,
        type: Value.Type,
        validate: (Value) throws -> Void
    ) throws -> Value where Value: Codable & Equatable & Sendable {
        let data = try verifiedEnvelopeData(
            at: url,
            kind: kind,
            type: type,
            validate: validate
        )
        let envelope: Envelope
        do {
            envelope = try Self.decoder().decode(Envelope.self, from: data)
        } catch {
            throw ArkFileWeatherStoreError.malformedEnvelope
        }
        do {
            return try Self.decoder().decode(type, from: envelope.payload)
        } catch {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    /// Returns exact verified bytes so rotation preserves the known-good
    /// envelope without a lossy decode/re-encode cycle.
    private func verifiedEnvelopeData<Value>(
        at url: URL,
        kind: PayloadKind,
        type: Value.Type,
        validate: (Value) throws -> Void
    ) throws -> Data where Value: Codable & Equatable & Sendable {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArkFileWeatherStoreError.notFound
        }
        do {
            let resourceValues = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard resourceValues.isRegularFile == true,
                  resourceValues.isSymbolicLink != true else {
                throw ArkFileWeatherStoreError.invalidStorageObject
            }
            let size = resourceValues.fileSize ?? 0
            guard size <= Self.maximumEnvelopeBytes else {
                throw ArkFileWeatherStoreError.fileTooLarge
            }
        } catch let error as ArkFileWeatherStoreError {
            throw error
        } catch {
            throw ArkFileWeatherStoreError.io(.inspect)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ArkFileWeatherStoreError.io(.read)
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw ArkFileWeatherStoreError.fileTooLarge
        }

        let envelope: Envelope
        do {
            envelope = try Self.decoder().decode(Envelope.self, from: data)
        } catch {
            throw ArkFileWeatherStoreError.malformedEnvelope
        }
        guard envelope.schemaVersion == Self.envelopeSchemaVersion else {
            throw ArkFileWeatherStoreError.unsupportedEnvelopeVersion(envelope.schemaVersion)
        }
        guard envelope.payloadKind == kind.rawValue else {
            throw ArkFileWeatherStoreError.unexpectedPayloadKind
        }
        guard envelope.payload.count <= Self.maximumPayloadBytes else {
            throw ArkFileWeatherStoreError.fileTooLarge
        }
        guard Self.sha256(envelope.payload) == envelope.sha256 else {
            throw ArkFileWeatherStoreError.checksumMismatch
        }

        let value: Value
        do {
            value = try Self.decoder().decode(type, from: envelope.payload)
        } catch {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        try validate(value)
        return data
    }

    private func envelopeData<Value>(
        for value: Value,
        kind: PayloadKind
    ) throws -> Data where Value: Encodable {
        let payload: Data
        do {
            payload = try Self.encoder().encode(value)
        } catch {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        guard payload.count <= Self.maximumPayloadBytes else {
            throw ArkFileWeatherStoreError.fileTooLarge
        }
        let envelope = Envelope(
            schemaVersion: Self.envelopeSchemaVersion,
            payloadKind: kind.rawValue,
            payload: payload,
            sha256: Self.sha256(payload)
        )
        do {
            let data = try Self.encoder().encode(envelope)
            guard data.count <= Self.maximumEnvelopeBytes else {
                throw ArkFileWeatherStoreError.fileTooLarge
            }
            return data
        } catch let error as ArkFileWeatherStoreError {
            throw error
        } catch {
            throw ArkFileWeatherStoreError.io(.write)
        }
    }

    private func prepareDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw ArkFileWeatherStoreError.io(.prepareDirectory)
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectoryURL = directoryURL
            try mutableDirectoryURL.setResourceValues(values)
        } catch {
            throw ArkFileWeatherStoreError.io(.excludeFromBackup)
        }

        #if os(iOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw ArkFileWeatherStoreError.io(.protect)
        }
        #endif
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ArkFileWeatherStoreError.io(.write)
        }

        #if os(iOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            throw ArkFileWeatherStoreError.io(.protect)
        }
        #endif
    }

    private func removeItem(at url: URL) throws {
        if let removalOperation {
            try removalOperation(url)
        } else {
            try fileManager.removeItem(at: url)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func onlyMissingFiles(
        _ current: ArkFileWeatherStoreError?,
        _ previous: ArkFileWeatherStoreError?
    ) -> Bool {
        (current == nil || current == .notFound)
            && (previous == nil || previous == .notFound)
    }

    private static func normalized(
        _ error: Error,
        operation: ArkFileWeatherStoreOperation
    ) -> ArkFileWeatherStoreError {
        if let storeError = error as? ArkFileWeatherStoreError {
            return storeError
        }
        return .io(operation)
    }

    // MARK: - Bounded payload validation

    private static func validate(settings: ArkFileWeatherSettings) throws {
        guard settings.schemaVersion == ArkFileWeatherSettings.currentSchemaVersion else {
            throw ArkFileWeatherStoreError.invalidPayload(.unsupportedSchema)
        }
        guard settings.modifiedAt.timeIntervalSince1970.isFinite else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        if let location = settings.savedLocation {
            guard location.revision > 0 else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidRevision)
            }
            guard location.coordinate.isValid,
                  UUID(uuidString: location.id) != nil,
                  isBounded(location.id, maximum: 128, allowEmpty: false),
                  isBounded(location.displayName, maximum: 160, allowEmpty: false),
                  isBounded(location.timeZoneIdentifier, maximum: 128),
                  location.selectedAt.timeIntervalSince1970.isFinite,
                  location.measuredAt?.timeIntervalSince1970.isFinite != false else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidLocation)
            }
            if let accuracy = location.horizontalAccuracyMeters {
                guard accuracy.isFinite, (0 ... 1_000_000).contains(accuracy) else {
                    throw ArkFileWeatherStoreError.invalidPayload(.invalidLocation)
                }
            }
        }
        guard isBounded(
            settings.environmental.selectedRiverGaugeID,
            maximum: 128
        ) else {
            throw ArkFileWeatherStoreError.invalidPayload(.excessiveText)
        }
    }

    private static func validate(snapshot: ArkFileWeatherSnapshot) throws {
        guard snapshot.schemaVersion == ArkFileWeatherSnapshot.currentSchemaVersion else {
            throw ArkFileWeatherStoreError.invalidPayload(.unsupportedSchema)
        }
        guard snapshot.locationRevision > 0 else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidRevision)
        }
        guard snapshot.assembledAt.timeIntervalSince1970.isFinite else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        guard isBounded(snapshot.resolvedPlaceName, maximum: 160) else {
            throw ArkFileWeatherStoreError.invalidPayload(.excessiveText)
        }

        try validateComponent(snapshot.hourly)
        try validateComponent(snapshot.daily)
        try validateComponent(snapshot.alerts)
        try validateComponent(snapshot.climateOutlooks)
        try validateComponent(snapshot.astronomy)
        try validateComponent(snapshot.radioTransmitters)
        try validateComponent(snapshot.airQuality)
        try validateComponent(snapshot.smoke)
        try validateComponent(snapshot.riverConditions)
        try validateComponent(snapshot.drought)

        guard (snapshot.hourly.value?.count ?? 0) <= 384,
              (snapshot.daily.value?.count ?? 0) <= 31,
              (snapshot.alerts.value?.count ?? 0) <= 128,
              (snapshot.climateOutlooks.value?.count ?? 0) <= 12,
              (snapshot.astronomy.value?.count ?? 0) <= 35,
              (snapshot.radioTransmitters.value?.count ?? 0) <= 32,
              (snapshot.radioAreas?.count ?? 0) <= 32,
              (snapshot.riverConditions.value?.count ?? 0) <= 16 else {
            throw ArkFileWeatherStoreError.invalidPayload(.excessiveCount)
        }

        try snapshot.hourly.value?.forEach(validate(hourly:))
        try snapshot.daily.value?.forEach(validate(daily:))
        try snapshot.alerts.value?.forEach(validate(alert:))
        try snapshot.climateOutlooks.value?.forEach(validate(outlook:))
        try snapshot.astronomy.value?.forEach(validate(astronomy:))
        try snapshot.radioTransmitters.value?.forEach(validate(radio:))
        guard snapshot.radioAreas?.allSatisfy({
            isSixDigitCode($0.sameCode)
                && isBounded($0.countyZoneID, maximum: 64, allowEmpty: false)
                && isBounded($0.displayName, maximum: 256, allowEmpty: false)
        }) != false else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        try snapshot.riverConditions.value?.forEach(validate(river:))
        if let airQuality = snapshot.airQuality.value {
            try validate(airQuality: airQuality)
        }
        if let smoke = snapshot.smoke.value {
            try validate(smoke: smoke)
        }
        if let drought = snapshot.drought.value {
            try validate(drought: drought)
        }
    }

    private static func validateComponent<Value>(
        _ component: ArkFileWeatherComponent<Value>
    ) throws {
        switch component.availability {
        case .available:
            guard component.value != nil,
                  let stamp = component.stamp,
                  component.failure == nil,
                  component.unavailableReason == nil else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidComponentState)
            }
            try validate(stamp: stamp)
        case .successfulEmpty:
            guard component.value == nil,
                  let stamp = component.stamp,
                  component.failure == nil,
                  component.unavailableReason == nil else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidComponentState)
            }
            try validate(stamp: stamp)
        case .failed:
            guard let failure = component.failure,
                  component.unavailableReason == nil,
                  (component.value == nil) == (component.stamp == nil) else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidComponentState)
            }
            try validate(failure: failure)
            if let stamp = component.stamp {
                try validate(stamp: stamp)
            }
        case .unavailable, .unsupported:
            guard component.value == nil,
                  component.stamp == nil,
                  component.failure == nil,
                  component.unavailableReason != nil else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidComponentState)
            }
        }
    }

    private static func validate(stamp: ArkFileWeatherComponentStamp) throws {
        guard isBounded(stamp.sourceID, maximum: 512, allowEmpty: false),
              isSafeHTTPValidator(stamp.entityTag),
              isSafeHTTPValidator(stamp.lastModified),
              [
                  stamp.issuedAt,
                  stamp.validFrom,
                  stamp.validUntil
              ].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              [
                  stamp.fetchedAt,
                  stamp.freshUntil,
                  stamp.agingUntil,
                  stamp.expiresAt,
                  stamp.historicalAt
              ].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              stamp.fetchedAt <= stamp.freshUntil,
              stamp.freshUntil <= stamp.agingUntil,
              stamp.agingUntil <= stamp.expiresAt,
              stamp.expiresAt <= stamp.historicalAt else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidStamp)
        }
        if let validFrom = stamp.validFrom, let validUntil = stamp.validUntil,
           validFrom > validUntil {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidStamp)
        }
        if let products = stamp.climateSourceProducts {
            guard stamp.sourceID == ArkFileCPCOutlookProvider.sourceID,
                  products.count == ArkFileWeatherClimateSourceProduct
                    .cpcProductIDs.count,
                  Set(products.map(\.productID))
                    == ArkFileWeatherClimateSourceProduct.cpcProductIDs else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidStamp)
            }
            try products.forEach(validate(climateSourceProduct:))
        }
    }

    private static func validate(
        climateSourceProduct product: ArkFileWeatherClimateSourceProduct
    ) throws {
        guard product.issuedAt.timeIntervalSince1970.isFinite,
              product.validFrom.timeIntervalSince1970.isFinite,
              product.validUntil.timeIntervalSince1970.isFinite,
              product.issuedAt <= product.validFrom,
              product.validFrom < product.validUntil,
              isSafeHTTPValidator(product.entityTag),
              isSafeHTTPValidator(product.lastModified) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidStamp)
        }
        if let distribution = product.distribution {
            let values = [
                distribution.belowNormalFraction,
                distribution.nearNormalFraction,
                distribution.aboveNormalFraction
            ]
            guard values.allSatisfy(validFraction),
                  values.compactMap({ $0 }).reduce(0, +) <= 1.000_001 else {
                throw ArkFileWeatherStoreError.invalidPayload(.invalidStamp)
            }
        }
    }

    private static func validate(failure: ArkFileWeatherComponentFailure) throws {
        guard failure.occurredAt.timeIntervalSince1970.isFinite,
              failure.retryAfter?.timeIntervalSince1970.isFinite != false,
              isBounded(failure.providerCode, maximum: 128) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidComponentState)
        }
    }

    private static func validate(hourly period: ArkFileWeatherHourlyPeriod) throws {
        guard isBounded(period.id, maximum: 128, allowEmpty: false),
              isBounded(period.summary, maximum: 1_024),
              validRange(period.startsAt, period.endsAt),
              validTemperature(period.temperatureCelsius),
              validTemperature(period.apparentTemperatureCelsius),
              validTemperature(period.dewPointCelsius),
              validFraction(period.relativeHumidityFraction),
              validFraction(period.precipitationProbabilityFraction),
              validNonnegative(period.precipitationMillimeters, maximum: 10_000),
              validNonnegative(period.windSpeedMetersPerSecond, maximum: 250),
              validNonnegative(period.windGustMetersPerSecond, maximum: 250),
              validOptionalRange(period.windDirectionDegrees, 0 ... 360),
              validFraction(period.cloudCoverFraction),
              validNonnegative(period.visibilityMeters, maximum: 1_000_000),
              validOptionalRange(period.pressureHectopascals, 100 ... 1_500) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(daily period: ArkFileWeatherDailyPeriod) throws {
        guard isBounded(period.id, maximum: 128, allowEmpty: false),
              isBounded(period.summary, maximum: 1_024),
              validRange(period.startsAt, period.endsAt),
              validTemperature(period.minimumTemperatureCelsius),
              validTemperature(period.maximumTemperatureCelsius),
              validFraction(period.precipitationProbabilityFraction),
              validNonnegative(period.precipitationMillimeters, maximum: 10_000),
              validNonnegative(period.maximumWindSpeedMetersPerSecond, maximum: 250),
              validNonnegative(period.maximumWindGustMetersPerSecond, maximum: 250) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        if let minimum = period.minimumTemperatureCelsius,
           let maximum = period.maximumTemperatureCelsius,
           minimum > maximum {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(alert: ArkFileWeatherAlert) throws {
        guard isBounded(alert.id, maximum: 512, allowEmpty: false),
              isBounded(alert.sourceID, maximum: 512, allowEmpty: false),
              isBounded(alert.issuingAgency, maximum: 512),
              isBounded(alert.event, maximum: 256, allowEmpty: false),
              isBounded(alert.headline, maximum: 1_024),
              isBounded(alert.areaDescription, maximum: 4_096),
              isBounded(alert.description, maximum: 32_768),
              isBounded(alert.instruction, maximum: 32_768),
              alert.affectedZoneIDs.count <= 256,
              alert.affectedZoneIDs.allSatisfy({
                  isBounded($0, maximum: 512, allowEmpty: false)
              }),
              alert.sentAt.timeIntervalSince1970.isFinite,
              alert.effectiveAt?.timeIntervalSince1970.isFinite != false,
              alert.onsetAt?.timeIntervalSince1970.isFinite != false,
              alert.expiresAt.timeIntervalSince1970.isFinite,
              alert.endsAt?.timeIntervalSince1970.isFinite != false,
              alert.expiresAt >= (alert.effectiveAt ?? alert.sentAt) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(outlook: ArkFileWeatherClimateOutlook) throws {
        guard isBounded(outlook.id, maximum: 128, allowEmpty: false),
              validRange(outlook.validFrom, outlook.validUntil) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        try validate(distribution: outlook.temperature)
        try validate(distribution: outlook.precipitation)
    }

    private static func validate(
        distribution: ArkFileWeatherProbabilityDistribution
    ) throws {
        let values = [
            distribution.belowNormalFraction,
            distribution.nearNormalFraction,
            distribution.aboveNormalFraction
        ]
        guard values.allSatisfy(validFraction) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
        let known = values.compactMap { $0 }
        if known.count == 3, abs(known.reduce(0, +) - 1) > 0.02 {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(astronomy: ArkFileWeatherAstronomyDay) throws {
        let dates = [
            astronomy.localDayStart,
            astronomy.sunrise,
            astronomy.sunset,
            astronomy.civilDawn,
            astronomy.civilDusk,
            astronomy.moonrise,
            astronomy.moonset
        ].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              (0 ... 1).contains(astronomy.moonIlluminationFraction),
              astronomy.moonIlluminationFraction.isFinite else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(radio: ArkFileWeatherRadioTransmitter) throws {
        guard isBounded(radio.id, maximum: 128, allowEmpty: false),
              isBounded(radio.callSign, maximum: 32, allowEmpty: false),
              isBounded(radio.channel, maximum: 32),
              isBounded(radio.siteName, maximum: 256, allowEmpty: false),
              isBounded(radio.coverageNote, maximum: 2_048),
              radio.frequencyMegahertz.isFinite,
              (162.4 ... 162.55).contains(radio.frequencyMegahertz),
              radio.coordinate?.isValid != false,
              radio.sameCounties.count <= 256,
              radio.sameCounties.allSatisfy({
                  isSixDigitCode($0.code)
                      && isBounded($0.displayName, maximum: 256, allowEmpty: false)
              }) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(airQuality: ArkFileWeatherAirQuality) throws {
        guard airQuality.observedAt.timeIntervalSince1970.isFinite,
              (-1 ... 1_000).contains(airQuality.airQualityIndex),
              isBounded(airQuality.category, maximum: 128, allowEmpty: false),
              isBounded(airQuality.primaryPollutant, maximum: 128) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(smoke: ArkFileWeatherSmoke) throws {
        guard smoke.validAt.timeIntervalSince1970.isFinite,
              isBounded(smoke.category, maximum: 128, allowEmpty: false),
              isBounded(smoke.summary, maximum: 2_048) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(river: ArkFileWeatherRiverCondition) throws {
        guard isBounded(river.gaugeID, maximum: 128, allowEmpty: false),
              isBounded(river.gaugeName, maximum: 256, allowEmpty: false),
              river.observedAt.timeIntervalSince1970.isFinite,
              validOptionalRange(river.stageMeters, -1_000 ... 20_000),
              validNonnegative(river.flowCubicMetersPerSecond, maximum: 10_000_000),
              isBounded(river.category, maximum: 128) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validate(drought: ArkFileWeatherDroughtCondition) throws {
        guard drought.validAt.timeIntervalSince1970.isFinite,
              isBounded(drought.summary, maximum: 2_048) else {
            throw ArkFileWeatherStoreError.invalidPayload(.invalidValue)
        }
    }

    private static func validRange(_ start: Date, _ end: Date) -> Bool {
        start.timeIntervalSince1970.isFinite
            && end.timeIntervalSince1970.isFinite
            && start < end
    }

    private static func validTemperature(_ value: Double?) -> Bool {
        validOptionalRange(value, -150 ... 100)
    }

    private static func validFraction(_ value: Double?) -> Bool {
        validOptionalRange(value, 0 ... 1)
    }

    private static func validNonnegative(_ value: Double?, maximum: Double) -> Bool {
        validOptionalRange(value, 0 ... maximum)
    }

    private static func isSafeHTTPValidator(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= 256
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && value.unicodeScalars.allSatisfy {
                (0x20 ... 0x7E).contains($0.value)
            }
    }

    private static func validOptionalRange(
        _ value: Double?,
        _ range: ClosedRange<Double>
    ) -> Bool {
        guard let value else { return true }
        return value.isFinite && range.contains(value)
    }

    private static func isBounded(
        _ value: String?,
        maximum: Int,
        allowEmpty: Bool = true
    ) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= maximum,
              allowEmpty || !value.isEmpty else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            let codePoint = scalar.value
            let isAllowedWhitespace = codePoint == 0x09
                || codePoint == 0x0A
                || codePoint == 0x0D
            let isControl = codePoint <= 0x1F || (0x7F ... 0x9F).contains(codePoint)
            let isBidirectionalControl = codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A ... 0x202E).contains(codePoint)
                || (0x2066 ... 0x2069).contains(codePoint)
            return (isControl && !isAllowedWhitespace)
                || isBidirectionalControl
                || codePoint == 0xFEFF
        }
    }

    private static func isSixDigitCode(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }
}

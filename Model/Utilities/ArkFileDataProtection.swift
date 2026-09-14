// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import os

/// One explicit protection policy for ArkFile's durable offline state.
///
/// Content remains encrypted at rest and is unavailable before the first
/// unlock after a restart. After that unlock, background URL sessions and
/// refresh work can resume while the device is locked.
enum ArkFileDataProtection {
    enum MigrationDiagnosticKind: String, Equatable, Sendable {
        case prepareRoot
        case enumerate
        case readAttributes
        case applyProtection
        case verifyProtection
    }

    struct MigrationDiagnostic: Equatable, Sendable {
        let kind: MigrationDiagnosticKind
        let path: String
        let errorDescription: String
    }

    struct MigrationResult: Equatable, Sendable {
        let visitedItemCount: Int
        let protectedItemCount: Int
        let failedItemCount: Int
        let enumerationErrorCount: Int
        let attributeErrorCount: Int
        let unprotectedItemCount: Int

        var isComplete: Bool {
            failedItemCount == 0
                && enumerationErrorCount == 0
                && attributeErrorCount == 0
                && unprotectedItemCount == 0
        }
    }

    static let currentApplicationSupportMigrationVersion = 1
    static let applicationSupportMigrationMarkerKey =
        "ArkFileDataProtection.applicationSupportMigrationVersion"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.arkfile.ios",
        category: "DataProtectionMigration"
    )

    #if os(iOS)
    static let durableProtectionType =
        FileProtectionType.completeUntilFirstUserAuthentication

    static var persistentStoreOption: NSObject {
        durableProtectionType.rawValue as NSString
    }
    #endif

    static func apply(
        toExistingItem url: URL,
        fileManager: FileManager = .default
    ) throws {
        #if os(iOS)
        guard fileManager.fileExists(atPath: url.fileSystemPath) else {
            return
        }
        try fileManager.setAttributes(
            [.protectionKey: durableProtectionType],
            ofItemAtPath: url.fileSystemPath
        )
        #endif
    }

    static func createProtectedDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try apply(toExistingItem: url, fileManager: fileManager)
    }

    /// Runs the versioned Application Support upgrade at most once after a
    /// completely successful pass.
    ///
    /// An incomplete pass deliberately leaves the marker unchanged, allowing
    /// the app to retry after protected data becomes available or a transient
    /// filesystem error clears.
    @discardableResult
    static func migrateApplicationSupportIfNeeded(
        at root: URL,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        protectionApplier: (
            _ url: URL,
            _ fileManager: FileManager
        ) throws -> Void = { url, fileManager in
            try ArkFileDataProtection.apply(
                toExistingItem: url,
                fileManager: fileManager
            )
        },
        protectionVerifier: (
            _ url: URL,
            _ fileManager: FileManager
        ) throws -> Bool = { url, fileManager in
            try ArkFileDataProtection.hasDurableProtection(
                at: url,
                fileManager: fileManager
            )
        },
        diagnosticHandler: ((MigrationDiagnostic) -> Void)? = nil
    ) -> MigrationResult? {
        guard userDefaults.integer(
            forKey: applicationSupportMigrationMarkerKey
        ) < currentApplicationSupportMigrationVersion else {
            return nil
        }

        if !fileManager.fileExists(atPath: root.fileSystemPath) {
            do {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
            } catch {
                report(
                    MigrationDiagnostic(
                        kind: .prepareRoot,
                        path: root.fileSystemPath,
                        errorDescription: error.localizedDescription
                    ),
                    to: diagnosticHandler
                )
                return MigrationResult(
                    visitedItemCount: 0,
                    protectedItemCount: 0,
                    failedItemCount: 1,
                    enumerationErrorCount: 0,
                    attributeErrorCount: 0,
                    unprotectedItemCount: 0
                )
            }
        }

        let result = migrateExistingTree(
            at: root,
            fileManager: fileManager,
            protectionApplier: protectionApplier,
            protectionVerifier: protectionVerifier,
            diagnosticHandler: diagnosticHandler
        )
        if result.isComplete {
            userDefaults.set(
                currentApplicationSupportMigrationVersion,
                forKey: applicationSupportMigrationMarkerKey
            )
        }
        return result
    }

    /// Applies the durable policy to an already-installed tree.
    ///
    /// Directory defaults cover newly-created children, but they do not
    /// rewrite existing descendants. This bounded, best-effort pass closes
    /// that upgrade gap without following symbolic links.
    static func migrateExistingTree(
        at root: URL,
        fileManager: FileManager = .default,
        protectionApplier: (
            _ url: URL,
            _ fileManager: FileManager
        ) throws -> Void = { url, fileManager in
            try ArkFileDataProtection.apply(
                toExistingItem: url,
                fileManager: fileManager
            )
        },
        protectionVerifier: (
            _ url: URL,
            _ fileManager: FileManager
        ) throws -> Bool = { url, fileManager in
            try ArkFileDataProtection.hasDurableProtection(
                at: url,
                fileManager: fileManager
            )
        },
        diagnosticHandler: ((MigrationDiagnostic) -> Void)? = nil
    ) -> MigrationResult {
        guard fileManager.fileExists(atPath: root.fileSystemPath) else {
            return MigrationResult(
                visitedItemCount: 0,
                protectedItemCount: 0,
                failedItemCount: 0,
                enumerationErrorCount: 0,
                attributeErrorCount: 0,
                unprotectedItemCount: 0
            )
        }

        var visited = 1
        var protected = 0
        var failed = 0
        var enumerationErrors = 0
        var attributeErrors = 0
        var unprotected = 0

        func protectAndVerify(_ url: URL) {
            do {
                try protectionApplier(url, fileManager)
            } catch {
                failed += 1
                report(
                    MigrationDiagnostic(
                        kind: .applyProtection,
                        path: url.fileSystemPath,
                        errorDescription: error.localizedDescription
                    ),
                    to: diagnosticHandler
                )
                return
            }

            do {
                if try protectionVerifier(url, fileManager) {
                    protected += 1
                } else {
                    unprotected += 1
                    report(
                        MigrationDiagnostic(
                            kind: .verifyProtection,
                            path: url.fileSystemPath,
                            errorDescription:
                                "The expected protection attribute is absent."
                        ),
                        to: diagnosticHandler
                    )
                }
            } catch {
                attributeErrors += 1
                report(
                    MigrationDiagnostic(
                        kind: .readAttributes,
                        path: url.fileSystemPath,
                        errorDescription: error.localizedDescription
                    ),
                    to: diagnosticHandler
                )
            }
        }

        protectAndVerify(root)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { url, error in
                enumerationErrors += 1
                report(
                    MigrationDiagnostic(
                        kind: .enumerate,
                        path: url.fileSystemPath,
                        errorDescription: error.localizedDescription
                    ),
                    to: diagnosticHandler
                )
                return true
            }
        ) else {
            enumerationErrors += 1
            report(
                MigrationDiagnostic(
                    kind: .enumerate,
                    path: root.fileSystemPath,
                    errorDescription:
                        "FileManager could not create a directory enumerator."
                ),
                to: diagnosticHandler
            )
            return MigrationResult(
                visitedItemCount: visited,
                protectedItemCount: protected,
                failedItemCount: failed,
                enumerationErrorCount: enumerationErrors,
                attributeErrorCount: attributeErrors,
                unprotectedItemCount: unprotected
            )
        }

        for case let itemURL as URL in enumerator {
            visited += 1
            let isSymbolicLink: Bool
            do {
                isSymbolicLink = try itemURL.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
                ).isSymbolicLink == true
            } catch {
                attributeErrors += 1
                report(
                    MigrationDiagnostic(
                        kind: .readAttributes,
                        path: itemURL.fileSystemPath,
                        errorDescription: error.localizedDescription
                    ),
                    to: diagnosticHandler
                )
                enumerator.skipDescendants()
                continue
            }

            if isSymbolicLink {
                enumerator.skipDescendants()
                continue
            }
            protectAndVerify(itemURL)
        }

        return MigrationResult(
            visitedItemCount: visited,
            protectedItemCount: protected,
            failedItemCount: failed,
            enumerationErrorCount: enumerationErrors,
            attributeErrorCount: attributeErrors,
            unprotectedItemCount: unprotected
        )
    }

    static func hasDurableProtection(
        at url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.fileSystemPath) else {
            return false
        }
        #if os(iOS)
        let attributes = try fileManager.attributesOfItem(
            atPath: url.fileSystemPath
        )
        guard let protection = attributes[.protectionKey] else {
            #if targetEnvironment(simulator)
            // The Simulator accepts the attribute-setting call but its host
            // filesystem does not expose the value through FileManager.
            return true
            #else
            return false
            #endif
        }
        if let protectionType = protection as? FileProtectionType {
            return protectionType == durableProtectionType
        }
        if let rawValue = protection as? String {
            return rawValue == durableProtectionType.rawValue
        }
        return false
        #else
        return true
        #endif
    }

    private static func report(
        _ diagnostic: MigrationDiagnostic,
        to diagnosticHandler: ((MigrationDiagnostic) -> Void)?
    ) {
        logger.error(
            "Migration \(diagnostic.kind.rawValue, privacy: .public) failure at \(diagnostic.path, privacy: .private): \(diagnostic.errorDescription, privacy: .private)"
        )
        diagnosticHandler?(diagnostic)
    }
}

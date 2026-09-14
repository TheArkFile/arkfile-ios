// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// Exhaustive presentation counts for ArkFile-managed installed content.
///
/// Bundled samples are deliberately outside this ledger because they are
/// immutable app resources rather than installed managed items. The Local
/// Sharing serving-snapshot count continues to include those samples.
struct ArkFileLocalSharingClassification: Equatable, Sendable {
    let installedManagedItemCount: Int
    let readyToShareCount: Int
    let needsIntegrityPreparationCount: Int
    let technicallyPendingCount: Int
    let hardBlockedCount: Int

    var isReconciled: Bool {
        installedManagedItemCount
            == readyToShareCount
                + needsIntegrityPreparationCount
                + technicallyPendingCount
                + hardBlockedCount
    }

    init(
        installedManagedPaths: some Sequence<String>,
        readyManagedPaths: some Sequence<String>,
        needsIntegrityPreparationGroupIDs: Set<String>,
        hardBlockedPaths: some Sequence<String>
    ) {
        let installed = Set(
            installedManagedPaths
                .map(ArkFileLocalSharingDispositionIndex.canonicalPath)
                .filter { !$0.isEmpty }
        )
        let blocked = installed.intersection(
            hardBlockedPaths.map(
                ArkFileLocalSharingDispositionIndex.canonicalPath
            )
        )
        let ready = installed.intersection(
            readyManagedPaths.map(
                ArkFileLocalSharingDispositionIndex.canonicalPath
            )
        ).subtracting(blocked)
        let needsPreparation = Set(installed.filter {
            needsIntegrityPreparationGroupIDs.contains(
                ArkFileContentCompatibilityPlanner.groupID(for: $0).rawValue
            )
        })
        .subtracting(blocked)
        .subtracting(ready)
        let pending = installed
            .subtracting(blocked)
            .subtracting(ready)
            .subtracting(needsPreparation)

        installedManagedItemCount = installed.count
        readyToShareCount = ready.count
        needsIntegrityPreparationCount = needsPreparation.count
        technicallyPendingCount = pending.count
        hardBlockedCount = blocked.count
    }
}

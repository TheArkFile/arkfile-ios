import Foundation

/// Background callbacks may resume only the exact persisted, signed selection.
/// A v2 marker in mutable JSON alone is never an alternative trust boundary.
enum ArkFileContentReleaseResumeValidation {
    static func accepts(_ record: ArkFileContentBackgroundDownloadRecord,
                        provider: ArkFileContentReleaseProvider = .shared,
                        allowInactive: Bool = true, activeRoot: URL? = nil) -> Bool {
        guard let tier = ArkFileContentTier.iOSInstallableTier(named: record.manifest.tier) else { return false }
        guard record.manifest.deliveryMode == "release-v2" else {
            return (try? record.manifest.validateForInstall(tier: tier)) != nil
        }
        guard record.sourceURL.path == "/api/content/v2/file",
              let query = URLComponents(url: record.sourceURL, resolvingAgainstBaseURL: false)?.queryItems,
              Set(query.map(\.name)).count == query.count,
              let releaseID = query.first(where: { $0.name == "releaseID" })?.value,
              let digest = query.first(where: { $0.name == "releaseSHA256" })?.value,
              let fileID = query.first(where: { $0.name == "fileID" })?.value,
              let root = activeRoot ?? (try? ArkFileContentPackInstaller.protectedActiveContentRoot()),
              let journal = try? ArkFileContentReplacementStore.load(at: root),
              !journal.removeOnly, !journal.isTerminal,
              allowInactive || (journal.phase != .paused && journal.phase != .failed),
              journal.request.binding == .init(releaseID: releaseID, releaseSHA256: digest),
              let verified = try? provider.verifiedRelease(journal.request.binding),
              let expected = try? verified.manifest(for: journal.request),
              expected.files == record.manifest.files,
              expected.tier == record.manifest.tier,
              record.manifest.installMode == "manifest-v2", record.manifest.product == "ArkFile",
              record.manifest.sourceEdition == releaseID,
              verified.release.file(fileID)?.manifestEntry == record.entry,
              expected.files.contains(record.entry) else { return false }
        return true
    }
}

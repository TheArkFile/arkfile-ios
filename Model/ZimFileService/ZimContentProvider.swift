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

import Foundation

/// Async reading data in chunks via LibZim
/// to be used with ``DataStream``
struct ZimContentProvider: DataProvider {
    
    typealias Element = URLContent
    private let url: URL
    private let expectedRegistrationGeneration: UInt64?

    init(for url: URL, expectedRegistrationGeneration: UInt64? = nil) {
        self.url = url
        self.expectedRegistrationGeneration = expectedRegistrationGeneration
    }

    func data(from start: UInt, to end: UInt) async -> URLContent? {
        guard let zimFileID = url.zimFileID else { return nil }
        return await ZimFileService.shared.getURLContent(
            zimFileID: zimFileID,
            contentPath: url.contentPath,
            start: start,
            end: end,
            expectedRegistrationGeneration: expectedRegistrationGeneration
        )
    }
}

/// Async reading data in chunks directly from the file system
/// to be used with ``DataStream``
struct ZimDirectContentProvider: DataProvider {

    typealias Element = URLContent
    private let directAccess: DirectAccessInfo
    private let contentSize: UInt
    private let acquireSourceLease: @Sendable (URL) -> ArkFileAuthoritativeReadLease?
    /// Retained by DataStream for the entire response, so activation cannot
    /// switch the ZIM between two independently requested byte ranges.
    private let managedContentReadToken: ArkFileManagedContentReaderToken?

    init(
        directAccess: DirectAccessInfo,
        contentSize: UInt,
        canReadSource: (@Sendable (URL) -> Bool)? = nil,
        managedContentReadToken: ArkFileManagedContentReaderToken? = nil
    ) {
        self.directAccess = directAccess
        self.contentSize = contentSize
        self.managedContentReadToken = managedContentReadToken
        if let canReadSource {
            self.acquireSourceLease = {
                canReadSource($0)
                    ? ArkFileAuthoritativeReadLease(url: $0, transactionID: nil)
                    : nil
            }
        } else {
            self.acquireSourceLease = ArkFileInstalledContentAccess.acquireReadLease
        }
    }

    init(
        directAccess: DirectAccessInfo,
        contentSize: UInt,
        resolveSource: @escaping @Sendable (URL) -> URL?,
        managedContentReadToken: ArkFileManagedContentReaderToken? = nil
    ) {
        self.directAccess = directAccess
        self.contentSize = contentSize
        self.managedContentReadToken = managedContentReadToken
        self.acquireSourceLease = {
            resolveSource($0).map {
                ArkFileAuthoritativeReadLease(url: $0, transactionID: nil)
            }
        }
    }

    init(
        directAccess: DirectAccessInfo,
        contentSize: UInt,
        acquireSourceLease: @escaping @Sendable (URL) -> ArkFileAuthoritativeReadLease?,
        managedContentReadToken: ArkFileManagedContentReaderToken? = nil
    ) {
        self.directAccess = directAccess
        self.contentSize = contentSize
        self.acquireSourceLease = acquireSourceLease
        self.managedContentReadToken = managedContentReadToken
    }

    func data(from start: UInt, to end: UInt) async -> URLContent? {
        guard managedContentReadToken?.isReleased != true,
              start < contentSize,
              end >= start else {
            return nil
        }
        if let zimFileID = directAccess.zimFileID,
           let generation = directAccess.registrationGeneration,
           !(await ZimFileService.shared.isCurrentRegistration(
               zimFileID: zimFileID,
               generation: generation
           )) {
            return nil
        }
        let availableLength = contentSize - start
        let inclusiveDelta = end - start
        let requestedLength = inclusiveDelta >= availableLength - 1
            ? availableLength
            : inclusiveDelta + 1
        let (fileOffset, offsetOverflow) = directAccess.offset.addingReportingOverflow(start)
        guard !offsetOverflow,
              requestedLength <= UInt(Int.max) else {
            return nil
        }
        let responseReadToken = managedContentReadToken
        let sourcePath = directAccess.path
        let sourceLease = acquireSourceLease
        let readOffset = fileOffset
        let readLength = Int(requestedLength)
        let result: URLContent? = await Task.detached(priority: .utility) { () -> URLContent? in
            // Awaiting the detached task itself is important. A continuation
            // resumed from inside this closure would let the response finish
            // while this safety token was still retained by the task epilogue.
            defer { withExtendedLifetime(responseReadToken) {} }
            guard responseReadToken?.isReleased != true else { return nil }
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard let readLease = sourceLease(sourceURL),
                  let handle = FileHandle(forReadingAtPath: readLease.url.fileSystemPath) else {
                return nil
            }
            do {
                try handle.seek(toOffset: UInt64(readOffset))
            } catch {
                try? handle.close()
                return nil
            }
            let data = handle.readData(ofLength: readLength)
            try? handle.close()
            guard !data.isEmpty else { return nil }
            let actualEnd = start + UInt(data.count) - 1
            return URLContent(data: data, start: start, end: actualEnd)
        }.value
        if let zimFileID = directAccess.zimFileID,
           let generation = directAccess.registrationGeneration,
           !(await ZimFileService.shared.isCurrentRegistration(
               zimFileID: zimFileID,
               generation: generation
           )) {
            return nil
        }
        return result
    }
}

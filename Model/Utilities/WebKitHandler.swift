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

import os
import WebKit

enum RangeRequestError: Error {
    case invalidRange
}

/// Skipping handling for HTTP 206 Partial Content
/// For video playback, WebKit makes a large amount of requests with small byte range (e.g. 8 bytes)
/// to retrieve content of the video.
/// As a result of the large volume of small requests, CPU usage will be very high,
/// which can result in app or webpage frozen.
/// To mitigate, opting for the less "broken" behavior of ignoring Range header
/// until WebKit behavior is changed.
final class KiwixURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let ZIMScheme = "zim"
    @MainActor private var startedTasks: [Int: Bool] = [:]

    // MARK: Life cycle

    @MainActor
    private func startFor(_ hashValue: Int) {
        startedTasks[hashValue] = true
    }

    @MainActor
    private func isStartedFor(_ hashValue: Int) -> Bool {
        startedTasks[hashValue] != nil
    }

    @MainActor
    private func stopFor(_ hashValue: Int) {
        startedTasks.removeValue(forKey: hashValue)
    }

    @MainActor
    private func stopAll() {
        startedTasks.removeAll()
    }

    @MainActor
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopFor(urlSchemeTask.hash)
    }

    @MainActor
    func didFailProvisionalNavigation() {
        stopAll()
    }

    @MainActor
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard isStartedFor(urlSchemeTask.hash) == false else { return }
        startFor(urlSchemeTask.hash)
        Task { @MainActor in
            await handle(task: urlSchemeTask)
        }
    }

    @MainActor
    private func handle(task urlSchemeTask: WKURLSchemeTask) async {
        let request = urlSchemeTask.request
        guard let url = request.url?.updatedToZIMSheme(), url.isZIMURL else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            stopFor(urlSchemeTask.hash)
            return
        }
        guard let zimResponseReadToken = ArkFileManagedContentConcurrencyGate
            .tryBeginZIMResponseRead() else {
            // Activation already owns the short path-switch window. Never
            // sample metadata or bytes from a changing ZIM generation.
            sendHTTPErrorResponse(urlSchemeTask, url: url, status: .code503)
            return
        }
        defer { zimResponseReadToken.release() }
        guard let metaData = await contentMetaData(for: url) else {
            sendHTTPErrorResponse(urlSchemeTask, url: url, status: .code404)
            return
        }
        let requestedRange: ClosedRange<UInt>?
        do {
            requestedRange = try rangeFrom(request)
        } catch {
            sendHTTPErrorResponse(urlSchemeTask, url: url, status: .code400)
            return
        }

        guard let dataStream = await dataStream(
            for: url,
            metaData: metaData,
            requestedRange: requestedRange,
            managedContentReadToken: zimResponseReadToken
        ) else {
            sendHTTPErrorResponse(urlSchemeTask, url: url, status: .code404)
            return
        }
        
        // send the headers
        guard isStartedFor(urlSchemeTask.hash) else { return }
        guard let responseHeaders = HTTPSuccess.response(
            url: url,
            metaData: metaData,
            requestedRange: requestedRange
        ) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse, userInfo: ["url": url]))
            stopFor(urlSchemeTask.hash)
            return
        }
        urlSchemeTask.didReceive(responseHeaders)

        // send the data
        do {
            try await writeContent(to: urlSchemeTask, from: dataStream)
            guard isStartedFor(urlSchemeTask.hash) else { return }
            urlSchemeTask.didFinish()
        } catch {
            guard isStartedFor(urlSchemeTask.hash) else { return }
            urlSchemeTask.didFailWithError(URLError(.badServerResponse, userInfo: ["url": url]))
        }
        stopFor(urlSchemeTask.hash)
    }

    // MARK: Range request detection

    private func rangeFrom(_ request: URLRequest) throws -> ClosedRange<UInt>? {
        guard let range = request.allHTTPHeaderFields?["Range"] as? String else {
            return nil
        }
        let parts = range.components(separatedBy: ["=", "-"])
        guard parts.count > 1, let rangeStart = UInt(parts[1]) else {
            throw RangeRequestError.invalidRange
        }
        let rangeEnd = parts.count == 3 ? UInt(parts[2]) ?? 0 : 0
        return rangeStart...rangeEnd+1
    }

    // MARK: Reading content

    private func dataStream(
        for url: URL,
        metaData: URLContentMetaData,
        requestedRange: ClosedRange<UInt>?,
        managedContentReadToken: ArkFileManagedContentReaderToken
    ) async -> DataStream<URLContent>? {
        let dataProvider: any DataProvider<URLContent>
        let ranges: [ClosedRange<UInt>] = rangesForDataStreaming(metaData, requestedRange: requestedRange)
        if metaData.isMediaType, let directAccess = await directAccessInfo(for: url) {
            guard directAccess.zimFileID == metaData.zimFileID,
                  directAccess.registrationGeneration == metaData.registrationGeneration else {
                // Identity changed between metadata and offset lookup. End this
                // response instead of opening replacement bytes at old offsets.
                return nil
            }
            dataProvider = ZimDirectContentProvider(
                directAccess: directAccess,
                contentSize: metaData.size,
                managedContentReadToken: managedContentReadToken
            )
        } else {
            dataProvider = ZimContentProvider(
                for: url,
                expectedRegistrationGeneration: metaData.registrationGeneration
            )
        }
        return DataStream(
            dataProvider: dataProvider,
            ranges: ranges,
            managedContentReadToken: managedContentReadToken
        )
    }
    
    /// The list of ranges we should use to stream data
    /// - Parameter metaData: the URLContentMetaData from the ZIM file content
    /// - Returns: If the data is larger than 2MB, it returns the "chunks" that should be read,
    /// otherwise returns the full range 0...metaData.size
    private func rangesForDataStreaming(
        _ metaData: URLContentMetaData,
        requestedRange: ClosedRange<UInt>?
    ) -> [ClosedRange<UInt>] {
        let size2MB: UInt = 2_097_152 // 2MB
        if let requested = requestedRange {
            return ByteRanges.rangesFor(
                contentLength: requested.upperBound - requested.lowerBound,
                rangeSize: size2MB,
                start: requested.lowerBound
            )
        } else {
            return ByteRanges.rangesFor(contentLength: metaData.size, rangeSize: size2MB)
        }
    }

    private func contentMetaData(for url: URL) async -> URLContentMetaData? {
        await ZimFileService.shared.getContentMetaData(url: url)
    }

    private func directAccessInfo(for url: URL) async -> DirectAccessInfo? {
        await ZimFileService.shared.getDirectAccessInfo(url: url)
    }

    // MARK: Writing content
    
    private func writeContent(
        to urlSchemeTask: WKURLSchemeTask,
        from dataStream: DataStream<URLContent>
    ) async throws {
        for try await urlContent in dataStream {
            let didDeliver = await MainActor.run { () -> Bool in
                guard isStartedFor(urlSchemeTask.hash) else { return false }
                urlSchemeTask.didReceive(urlContent.data)
                return true
            }
            guard didDeliver else { throw CancellationError() }
        }
    }

    // MARK: Error response

    @MainActor
    private func sendHTTPErrorResponse(_ urlSchemeTask: WKURLSchemeTask, url: URL, status: StatusCode) {
        guard isStartedFor(urlSchemeTask.hash) else { return }
        if let response = HTTPURLResponse(
            url: url,
            statusCode: status.rawValue,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        } else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse, userInfo: ["url": url]))
        }
        stopFor(urlSchemeTask.hash)
    }

    private enum StatusCode: Int {
        case code400 = 400
        case code404 = 404
        case code503 = 503
    }
}

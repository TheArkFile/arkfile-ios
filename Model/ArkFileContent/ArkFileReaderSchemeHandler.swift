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

#if os(iOS)
import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ArkFileReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "arkfile-reader"
    nonisolated static let host = "book"
    nonisolated static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self' 'unsafe-inline' data:",
        "style-src 'self' 'unsafe-inline' data:",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "media-src 'self' data:",
        "connect-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "manifest-src 'none'"
    ].joined(separator: "; ")

    private let rootURL: URL
    private let rootPath: String
    private let accessGuardURL: URL
    private let accessResolver: (URL) -> URL?
    private let readLeaseProvider: (URL) -> ArkFileAuthoritativeReadLease?
    private var startedTasks: Set<ObjectIdentifier> = []
    private var loadTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let responseChunkSize = 1_024 * 1_024

    init(
        rootURL: URL,
        accessGuardURL: URL? = nil,
        accessCheck: ((URL) -> Bool)? = nil
    ) {
        let canonicalRoot = Self.canonicalDirectoryURL(rootURL)
        self.rootURL = canonicalRoot
        self.rootPath = Self.normalizedFileSystemPath(canonicalRoot)
        self.accessGuardURL = accessGuardURL ?? canonicalRoot
        if let accessCheck {
            self.accessResolver = { accessCheck($0) ? $0 : nil }
            self.readLeaseProvider = {
                accessCheck($0)
                    ? ArkFileAuthoritativeReadLease(url: $0, transactionID: nil)
                    : nil
            }
        } else {
            self.accessResolver = ArkFileEssentialsAccessGate.resolvedURLForReadingSync
            self.readLeaseProvider = ArkFileInstalledContentAccess.acquireReadLease
        }
        super.init()
    }

    func matches(rootURL: URL, accessGuardURL: URL) -> Bool {
        rootPath == Self.normalizedFileSystemPath(rootURL)
            && Self.normalizedFileSystemPath(self.accessGuardURL)
                == Self.normalizedFileSystemPath(accessGuardURL)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        guard startedTasks.insert(taskID).inserted else { return }
        let method = urlSchemeTask.request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET",
              let requestURL = urlSchemeTask.request.url,
              let fileURL = Self.fileURL(fromReaderURL: requestURL, rootURL: rootURL) else {
            fail(urlSchemeTask, with: URLError(.unsupportedURL))
            return
        }
        guard canRead(fileURL) else {
            failAccess(urlSchemeTask, fileURL: fileURL)
            return
        }

        loadTasks[taskID] = Task { @MainActor [weak self] in
            await self?.load(
                logicalFileURL: fileURL,
                requestURL: requestURL,
                for: urlSchemeTask
            )
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        startedTasks.remove(taskID)
        loadTasks.removeValue(forKey: taskID)?.cancel()
    }

    func didFailProvisionalNavigation() {
        startedTasks.removeAll()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
    }

    private func load(
        logicalFileURL: URL,
        requestURL: URL,
        for urlSchemeTask: WKURLSchemeTask
    ) async {
        let taskID = ObjectIdentifier(urlSchemeTask)
        let mimeType = Self.mimeType(for: logicalFileURL)
        let textEncodingName = Self.textEncodingName(for: logicalFileURL)
        do {
            guard let readLease = readLeaseProvider(logicalFileURL) else {
                failAccess(urlSchemeTask, fileURL: logicalFileURL)
                return
            }
            let fileURL = readLease.url
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileNoSuchFile) }
            guard let response = Self.response(
                requestURL: requestURL,
                mimeType: mimeType,
                textEncodingName: textEncodingName,
                fileSize: values.fileSize
            ) else {
                throw URLError(.cannotParseResponse)
            }
            guard canRead(logicalFileURL) else {
                failAccess(urlSchemeTask, fileURL: logicalFileURL)
                return
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            guard canRead(logicalFileURL) else {
                failAccess(urlSchemeTask, fileURL: logicalFileURL)
                return
            }
            guard startedTasks.contains(taskID) else { return }
            urlSchemeTask.didReceive(response)
            while startedTasks.contains(taskID), !Task.isCancelled {
                guard canRead(logicalFileURL) else {
                    failAccess(urlSchemeTask, fileURL: logicalFileURL)
                    return
                }
                guard let data = try handle.read(upToCount: Self.responseChunkSize), !data.isEmpty else {
                    break
                }
                guard canRead(logicalFileURL) else {
                    failAccess(urlSchemeTask, fileURL: logicalFileURL)
                    return
                }
                guard startedTasks.contains(taskID), !Task.isCancelled else { return }
                urlSchemeTask.didReceive(data)
                await Task.yield()
            }
            guard canRead(logicalFileURL) else {
                failAccess(urlSchemeTask, fileURL: logicalFileURL)
                return
            }
            guard startedTasks.contains(taskID), !Task.isCancelled else { return }
            urlSchemeTask.didFinish()
            startedTasks.remove(taskID)
            loadTasks.removeValue(forKey: taskID)
        } catch {
            fail(
                urlSchemeTask,
                with: CocoaError(
                    .fileNoSuchFile,
                    userInfo: [NSFilePathErrorKey: logicalFileURL.fileSystemPath]
                )
            )
        }
    }

    private func canRead(_ requestedURL: URL) -> Bool {
        accessResolver(accessGuardURL) != nil && accessResolver(requestedURL) != nil
    }

    private func failAccess(_ urlSchemeTask: WKURLSchemeTask, fileURL: URL) {
        fail(
            urlSchemeTask,
            with: CocoaError(
                .fileReadNoPermission,
                userInfo: [NSFilePathErrorKey: fileURL.fileSystemPath]
            )
        )
    }

    private func fail(_ urlSchemeTask: WKURLSchemeTask, with error: Error) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        guard startedTasks.contains(taskID) else { return }
        urlSchemeTask.didFailWithError(error)
        startedTasks.remove(taskID)
        loadTasks.removeValue(forKey: taskID)
    }

    nonisolated static func readerURL(forFileURL fileURL: URL, rootURL: URL) -> URL? {
        guard fileURL.isFileURL else { return nil }
        let canonicalRoot = canonicalDirectoryURL(rootURL)
        let rootPath = normalizedFileSystemPath(canonicalRoot)
        let filePath = normalizedFileSystemPath(fileURL)
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let relativePath = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedSegments = relativePath.isEmpty ? [] : relativePath.split(separator: "/").compactMap {
            strictPercentEncode(String($0))
        }
        guard relativePath.isEmpty || encodedSegments.count == relativePath.split(separator: "/").count else {
            return nil
        }
        var readerComponents = URLComponents()
        readerComponents.scheme = scheme
        readerComponents.host = host
        readerComponents.percentEncodedPath = "/" + encodedSegments.joined(separator: "/")
        if let fileComponents = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) {
            readerComponents.percentEncodedQuery = fileComponents.percentEncodedQuery
            readerComponents.percentEncodedFragment = fileComponents.percentEncodedFragment
        }
        return readerComponents.url
    }

    nonisolated static func fileURL(fromReaderURL readerURL: URL, rootURL: URL) -> URL? {
        guard let components = URLComponents(url: readerURL, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath.hasPrefix("/") else {
            return nil
        }
        let encodedPath = String(components.percentEncodedPath.dropFirst())
        let encodedSegments = encodedPath.isEmpty
            ? []
            : encodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var decodedSegments: [String] = []
        for encodedSegment in encodedSegments {
            guard !encodedSegment.isEmpty,
                  let decoded = encodedSegment.removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.contains("\0") else {
                return nil
            }
            decodedSegments.append(decoded)
        }

        let canonicalRoot = canonicalDirectoryURL(rootURL)
        let rootPath = normalizedFileSystemPath(canonicalRoot)
        let candidate = decodedSegments.reduce(canonicalRoot) { partialURL, segment in
            partialURL.appendingPathComponent(segment)
        }
        let candidatePath = normalizedFileSystemPath(candidate)
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        var fileComponents = URLComponents(
            url: URL(fileURLWithPath: candidatePath),
            resolvingAgainstBaseURL: false
        )
        fileComponents?.percentEncodedQuery = components.percentEncodedQuery
        fileComponents?.percentEncodedFragment = components.percentEncodedFragment
        return fileComponents?.url
    }

    nonisolated static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm", "xhtml", "xht":
            return "text/html"
        case "css":
            return "text/css"
        case "js", "mjs":
            return "text/javascript"
        case "svg":
            return "image/svg+xml"
        case "json":
            return "application/json"
        case "xml", "opf", "ncx":
            return "application/xml"
        default:
            return UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    nonisolated static func response(
        requestURL: URL,
        mimeType: String,
        textEncodingName: String?,
        fileSize: Int?
    ) -> HTTPURLResponse? {
        let contentType = textEncodingName.map { "\(mimeType); charset=\($0)" } ?? mimeType
        var headers = [
            "Content-Type": contentType,
            "Content-Security-Policy": contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff"
        ]
        if let fileSize {
            headers["Content-Length"] = String(fileSize)
        }
        return HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    nonisolated private static func textEncodingName(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm", "xhtml", "xht", "css", "js", "mjs", "json", "xml", "opf", "ncx", "svg":
            return "utf-8"
        default:
            return nil
        }
    }

    nonisolated private static func strictPercentEncode(_ segment: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    nonisolated private static func canonicalDirectoryURL(_ url: URL) -> URL {
        URL(
            fileURLWithPath: normalizedFileSystemPath(url),
            isDirectory: true
        )
    }

    nonisolated private static func normalizedFileSystemPath(_ url: URL) -> String {
        var path = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

}
#endif

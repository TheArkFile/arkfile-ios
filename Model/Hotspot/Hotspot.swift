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
import Darwin
import Defaults
import Network
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

/// The physical generation of one already-open regular file.
///
/// Device/inode alone rejects pathname replacement but not an in-place
/// same-size rewrite. Modification and status-change timestamps make that
/// mutation observable without re-hashing large managed payloads at session
/// start. Callers keep validating this identity on the exact descriptor they
/// stream, so pathname races cannot substitute a different file.
struct ArkFileOpenFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    nonisolated init?(status: Darwin.stat) {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            return nil
        }
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        byteCount = Int64(status.st_size)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    nonisolated static func capture(
        fileDescriptor: Int32
    ) -> ArkFileOpenFileIdentity? {
        var status = Darwin.stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0 else { return nil }
        return ArkFileOpenFileIdentity(status: status)
    }

    nonisolated static func capture(
        noFollowURL url: URL
    ) -> ArkFileOpenFileIdentity? {
        var status = Darwin.stat()
        guard Darwin.lstat(
            url.standardizedFileURL.fileSystemPath,
            &status
        ) == 0 else {
            return nil
        }
        return ArkFileOpenFileIdentity(status: status)
    }
}

@MainActor
final class Hotspot {

    enum ServingMode: Equatable, Sendable {
        /// The ArkFile portal serves non-ZIM content directly. No raw Kiwix
        /// listener exists for this session.
        case portalOnly
        /// The ArkFile portal links ZIM readers to the raw Kiwix listener.
        case zim(Set<UUID>)

        var zimFileIDs: Set<UUID> {
            switch self {
            case .portalOnly:
                []
            case let .zim(ids):
                ids
            }
        }
    }

    struct ServingSession: Equatable, Sendable {
        let id: UUID
        let mode: ServingMode
        /// iOS raw ZIM sessions bind Kiwix to exactly this approved endpoint.
        /// Portal-only sessions and the upstream macOS path leave it nil.
        let zimBindingEndpoint: ArkFileSharingEndpoint?

        init(
            id: UUID = UUID(),
            mode: ServingMode,
            zimBindingEndpoint: ArkFileSharingEndpoint? = nil
        ) {
            self.id = id
            self.mode = mode
            self.zimBindingEndpoint = zimBindingEndpoint
        }
    }
    
    enum State: Equatable, Sendable {
        case started(ServingSession)
        case stopped
        case error(sessionID: UUID?, title: String, description: String)
    }
    
    @MainActor
    static let shared = Hotspot()
    
    nonisolated static let minPort = 1
    nonisolated static let defaultPort = 80
    nonisolated static let maxPort = 65535
    nonisolated private static let fallbackPorts = [8080, 8081, 8082, 8083, 8084, 8085]
    
    @MainActor
    @Published var state: State = .stopped
    
    @ZimActor
    private let hotspot = KiwixHotspot()

    @ZimActor
    private var lifecycleGeneration: UInt64 = 0

    @ZimActor
    private var activeZimServerURL: URL?
    
    nonisolated init() {
    }

    @ZimActor
    func startWith(zimFileIds: Set<UUID>, updating: Bool = true) async {
        guard !zimFileIds.isEmpty else {
            debugPrint("no zim files were set for Hotspot to start")
            return
        }
        await start(session: ServingSession(mode: .zim(zimFileIds)), updating: updating)
    }

    @ZimActor
    func start(session: ServingSession, updating: Bool = true) async {
        #if os(iOS)
        if case .zim = session.mode {
            guard let endpoint = session.zimBindingEndpoint,
                  ArkFileSharingEndpoints.isUsableBindingEndpoint(endpoint),
                  ArkFileSharingEndpoints.isBoundEndpointAvailable(
                    endpoint,
                    in: ArkFileSharingEndpoints.current()
                  ) else {
                lifecycleGeneration &+= 1
                hotspot.__stop()
                activeZimServerURL = nil
                if updating {
                    await update(state: .error(
                        sessionID: session.id,
                        title: "Waiting for Wi-Fi or Personal Hotspot",
                        description: "Connect this device to the same Wi-Fi network as the other devices, or turn on Personal Hotspot if this device and your cellular plan support it. Then tap Start Local Sharing again."
                    ))
                }
                return
            }
        }
        #endif
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await performStart(session: session, updating: updating, generation: generation)
    }

    @ZimActor
    private func restart(session: ServingSession) async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        hotspot.__stop()
        activeZimServerURL = nil
        switch session.mode {
        case .portalOnly:
            guard lifecycleGeneration == generation else { return }
            await preventSleep(true)
        case .zim:
            await preventSleep(false)
            guard lifecycleGeneration == generation else { return }
            await performStart(session: session, updating: false, generation: generation)
        }
    }

    @ZimActor
    private func performStart(
        session: ServingSession,
        updating: Bool,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        if session.mode == .portalOnly {
            // Portal-only must never inherit a raw Kiwix listener from an
            // interrupted or otherwise stale prior session.
            hotspot.__stop()
            activeZimServerURL = nil
            if updating {
                await update(state: .started(session))
            }
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            await preventSleep(true)
            return
        }
        guard case let .zim(zimFileIds) = session.mode, !zimFileIds.isEmpty else {
            debugPrint("no zim files were set for the Kiwix Local Sharing server")
            return
        }
        let openedZimFileIDs = Set(zimFileIds.compactMap {
            ZimFileService.shared.openArchive(zimFileID: $0)
        })
        guard !openedZimFileIDs.isEmpty else {
            activeZimServerURL = nil
            if updating {
                await update(state: .error(
                    sessionID: session.id,
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile could not open an available offline archive. Wait for the current search to finish, then try again."
                ))
            }
            return
        }
        #if os(iOS)
        guard let bindingEndpoint = session.zimBindingEndpoint,
              ArkFileSharingEndpoints.isUsableBindingEndpoint(bindingEndpoint),
              ArkFileSharingEndpoints.isBoundEndpointAvailable(
                bindingEndpoint,
                in: ArkFileSharingEndpoints.current()
              ) else {
            activeZimServerURL = nil
            await update(state: .error(
                sessionID: session.id,
                title: "Local Sharing Stopped",
                description: "The Wi-Fi or Personal Hotspot interface used by this session is no longer available. Confirm Local Sharing again before restarting."
            ))
            await preventSleep(false)
            return
        }
        let bindingAddress: String? = bindingEndpoint.ipAddress
        #else
        let bindingAddress: String? = nil
        #endif
        let port: Int = Defaults[.hotspotPortNumber]
        if let activePort = await startWithRetry(
            zimFileIds: openedZimFileIDs,
            bindingAddress: bindingAddress,
            preferredPort: port,
            generation: generation
        ) {
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            #if os(iOS)
            guard let bindingAddress,
                  let serverURL = Self.explicitServerURL(
                    address: bindingAddress,
                    port: activePort
                  ) else {
                lifecycleGeneration &+= 1
                hotspot.__stop()
                activeZimServerURL = nil
                await update(state: .error(
                    sessionID: session.id,
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile could not build the address for the approved local interface."
                ))
                await preventSleep(false)
                return
            }
            activeZimServerURL = serverURL
            #else
            activeZimServerURL = nil
            #endif
            if activePort != port {
                await updatePreferredPort(activePort)
            }
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            if updating {
                await update(state: .started(session))
            }
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            await preventSleep(true)
        } else {
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            activeZimServerURL = nil
            if updating {
                await update(state: .error(
                    sessionID: session.id,
                    title: LocalString.hotspot_error_port_already_used_by_another_app_title(withArgs: "\(port)"),
                    description: LocalString.hotspot_error_port_already_used_by_another_app_description
                ))
            } else {
                await update(state: .error(
                    sessionID: session.id,
                    title: "Local Sharing Stopped",
                    description: "ArkFile could not restart the ZIM server on its approved local interface. Confirm Local Sharing again to retry."
                ))
            }
            await preventSleep(false)
        }
    }

    @ZimActor
    private func startWithRetry(
        zimFileIds: Set<UUID>,
        bindingAddress: String?,
        preferredPort: Int,
        generation: UInt64
    ) async -> Int? {
        for (index, port) in Self.portsToTry(preferredPort: preferredPort).enumerated() {
            guard lifecycleGeneration == generation, !Task.isCancelled else { return nil }
            if index == 1 {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return nil
                }
            }
            guard lifecycleGeneration == generation, !Task.isCancelled else { return nil }
            let didStart: Bool
            #if os(iOS)
            guard let bindingAddress, !bindingAddress.isEmpty else { return nil }
            didStart = hotspot.__start(
                for: zimFileIds,
                onAddress: bindingAddress,
                onPort: Int32(port)
            )
            #else
            didStart = hotspot.__start(for: zimFileIds, onPort: Int32(port))
            #endif
            if didStart {
                guard lifecycleGeneration == generation, !Task.isCancelled else {
                    guard lifecycleGeneration == generation else { return nil }
                    lifecycleGeneration &+= 1
                    hotspot.__stop()
                    return nil
                }
                return port
            }
        }
        return nil
    }
    
    @ZimActor
    func stop(updating: Bool = true) async {
        lifecycleGeneration &+= 1
        hotspot.__stop()
        activeZimServerURL = nil
        if updating {
            await update(state: .stopped)
        }
        await preventSleep(false)
    }

    @ZimActor
    func fail(sessionID: UUID?, title: String, description: String) async {
        lifecycleGeneration &+= 1
        hotspot.__stop()
        activeZimServerURL = nil
        await update(state: .error(sessionID: sessionID, title: title, description: description))
        await preventSleep(false)
    }
    
    @MainActor
    func resetError() {
        if case .error = state {
            update(state: .stopped)
            preventSleep(false)
        }
    }
    
    @MainActor
    func appDidBecomeActive() async {
        if case let .started(session) = state {
            Task { @ZimActor in
                await restart(session: session)
            }
        }
    }
    
    @MainActor
    private func preventSleep(_ value: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = value
        #endif
    }
    
    @ZimActor
    func serverAddress() async -> URL? {
        #if os(iOS)
        // Never fall back to libkiwix's broad-interface or loopback guess on
        // iOS. The URL is derived only from the address explicitly bound for
        // the active session.
        return activeZimServerURL
        #else
        guard let address = hotspot.__address() else {
            return nil
        }
        return URL(string: address)
        #endif
    }
    
    @MainActor
    private func update(state newState: State) {
        if state != newState {
            state = newState
        }
    }

    @MainActor
    private func updatePreferredPort(_ port: Int) {
        Defaults[.hotspotPortNumber] = port
    }

    nonisolated private static func portsToTry(preferredPort: Int) -> [Int] {
        let preferred = min(max(preferredPort, minPort), maxPort)
        var ports = [preferred]

        // First retry the requested port once after a short delay. Some iOS networking
        // stacks need a moment to release the listener after Local Sharing is stopped.
        ports.append(preferred)

        for port in fallbackPorts where port != preferred {
            ports.append(port)
        }
        return ports
    }

    nonisolated static func explicitServerURL(address: String, port: Int) -> URL? {
        guard port >= minPort,
              port <= maxPort,
              ArkFileSharingEndpoints.isUsableBindingEndpoint(
                ArkFileSharingEndpoint(
                    interfaceName: "explicit-zim-binding",
                    ipAddress: address,
                    kind: .other
                )
              ) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = address
        components.port = port
        components.path = "/"
        return components.url
    }
    
    nonisolated static func validPortRangeMessage() -> String {
        LocalString.hotspot_settings_recommended_port_range(withArgs: "\(minPort)", "\(maxPort)")
    }
    
    nonisolated static var explanationText: String {
        #if os(macOS)
        LocalString.hotspot_server_wifi_only_explanation
        #else
        LocalString.hotspot_server_full_explanation
        #endif
    }
}

/// The two-server plan for one immutable Local Sharing content snapshot.
/// A non-empty snapshot with no registered ZIMs is intentionally valid: the
/// ArkFile portal can serve PDFs, HTML books, and images itself.
enum ArkFileLocalSharingServingPlan: Equatable, Sendable {
    /// Raw Kiwix is enabled only because every iOS ZIM session now carries one
    /// explicit approved binding and starts libkiwix with `setAddress`.
    static let rawZimSharingIsEnabled = true

    case none
    case portalOnly
    case portalAndZim(Set<UUID>)

    init(contentSnapshot: ArkFileLocalSharingContentSnapshot) {
        guard contentSnapshot.shareableItemCount > 0 else {
            self = .none
            return
        }
        if contentSnapshot.zimFileIDs.isEmpty {
            self = .portalOnly
        } else {
            self = .portalAndZim(contentSnapshot.zimFileIDs)
        }
    }

    var servingMode: Hotspot.ServingMode? {
        switch self {
        case .none:
            nil
        case .portalOnly:
            .portalOnly
        case let .portalAndZim(ids):
            .zim(ids)
        }
    }
}

#if os(iOS)
enum ArkFileLocalSharingAccess {
    static func sharedPath(_ path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return normalized
    }

    static func normalizedRequestPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }

    static func shareableItemSummary(count: Int) -> String {
        "\(count) shareable item\(count == 1 ? "" : "s")"
    }
}

final class ArkFileLocalSharingPortalServer: @unchecked Sendable {
    static let shared = ArkFileLocalSharingPortalServer()
    typealias BookServingSnapshotProvider =
        @Sendable (ArkFileLocalContentItem) throws -> ArkFileHTMLBookServingSnapshot

    enum StartError: Error, Equatable, LocalizedError, Sendable {
        case invalidServerAddress
        case invalidPort
        case missingZimServer
        case unresolvedZimMetadata
        case invalidContentSnapshot
        case sharedContentUnavailable
        case listenerCreationFailed(String)
        case listenerFailed(String)
        case listenerTimedOut(String?)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidServerAddress:
                "ArkFile could not determine the local server address."
            case .invalidPort:
                "ArkFile could not use the Local Sharing port."
            case .missingZimServer:
                "ArkFile could not start the ZIM reader required by this shared library."
            case .unresolvedZimMetadata:
                "ArkFile could not identify one of the ZIM files in this shared library."
            case .invalidContentSnapshot:
                "ArkFile could not freeze one consistent local library for sharing."
            case .sharedContentUnavailable:
                "One of the selected local files changed or became unavailable before sharing started."
            case let .listenerCreationFailed(reason), let .listenerFailed(reason):
                "The local server failed: \(reason)"
            case let .listenerTimedOut(reason):
                if let reason, !reason.isEmpty {
                    "The local server did not become reachable in time: \(reason)"
                } else {
                    "The local server did not become reachable in time."
                }
            case .cancelled:
                "Local Sharing was cancelled before the local server became reachable."
            }
        }
    }

    private struct Snapshot {
        let categories: [PortalCategory]
        let itemsByID: [String: PortalItem]
        let zimServerURL: URL?
        let zimServerPort: Int?
        let offlineMapResources: ArkFileOfflineMapResources
        let contentRoots: [URL]
        let contentLicenseLedgerVersion: String?
        let allowedHosts: Set<String>
        let approvedLocalIPAddresses: Set<String>
        let allowsDynamicPersonalHotspotInterfaces: Bool
        let allowsMapSharing: Bool
    }

    private struct PortalCategory {
        let key: ArkFileLocalContentCategoryKey?
        let title: String
        let description: String
        let systemImage: String
        let accent: String
        let items: [PortalItem]
    }

    private struct PortalItem {
        let id: String
        let name: String
        let url: URL?
        let sourceItem: ArkFileLocalContentItem?
        let relativePath: String
        let type: ArkFileLocalContentType
        let category: ArkFileLocalContentCategoryKey
        let subcategory: String
        let sizeBytes: Int64
        let zimContentID: String?
        let isLocked: Bool
        let isSampleContent: Bool
        let contentLicense: ArkFileContentLicenseEntry?
        let receiverNotice:
            ArkFileLocalSharingDispositionIndex.Entry.ReceiverNotice?
        let expectedSHA256: String?
        let sourceFileIdentity: ArkFileOpenFileIdentity
    }

    private struct OpenedPortalFile {
        let handle: FileHandle
        let size: Int64
        let modificationSeconds: Int64
        let identity: ArkFileOpenFileIdentity
    }

    private struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let queryItems: [URLQueryItem]
        let headers: [String: String]

        func replacing(path newPath: String) -> HTTPRequest {
            HTTPRequest(method: method, path: newPath, queryItems: queryItems, headers: headers)
        }
    }

    private let queue = DispatchQueue(label: "app.arkfile.local-sharing.portal")
    private var listener: NWListener?
    private var snapshot: Snapshot?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionsAwaitingRequest = Set<ObjectIdentifier>()
    private var connectionsReadingRequest = Set<ObjectIdentifier>()
    // ZIP extraction is synchronous and may cold-open a large archive. Keep
    // those jobs off the Network.framework queue so stop/background handling
    // stays prompt; this queue-owned registry is the cancellation authority.
    private var pendingBookRequests: [
        ObjectIdentifier: PendingBookRequest
    ] = [:]
    private var pendingStart: PendingStart?
    private var listenerIsReady = false
    private var runtimeFailureHandler: (@Sendable (StartError) -> Void)?
    private let listenerReadyTimeout: TimeInterval
    private let bookServingSnapshotProvider: BookServingSnapshotProvider
    private static let requestHeaderTimeout: TimeInterval = 10
    private static let maximumConnections = 24
    private static let maximumRequestHeaderBytes = 32 * 1024

    private struct PendingStart {
        let listener: NWListener
        let url: URL
        let continuation: CheckedContinuation<URL, Error>
        var lastWaitingReason: String?
    }

    private struct PendingBookRequest {
        let token: UUID
        let task: Task<Void, Never>
    }

    private enum BookServingSnapshotResult: @unchecked Sendable {
        case success(
            ArkFileHTMLBookServingSnapshot,
            ArkFileHTMLBookServingSnapshot.OpenedMember?
        )
        case memberUnavailable
        case failure
    }

    init(
        listenerReadyTimeout: TimeInterval = 8,
        bookServingSnapshotProvider: @escaping BookServingSnapshotProvider = {
            try ArkFileHTMLBookExtractor.servingSnapshot(for: $0)
        }
    ) {
        self.listenerReadyTimeout = listenerReadyTimeout
        self.bookServingSnapshotProvider = bookServingSnapshotProvider
    }

    var isReady: Bool {
        queue.sync { listenerIsReady }
    }

    var activeConnectionCount: Int {
        queue.sync { activeConnections.count }
    }

    func start(
        advertiseHost: String,
        zimServerURL: URL?,
        approvedLocalIPAddresses: Set<String>,
        contentSnapshot: ArkFileLocalSharingContentSnapshot,
        allowsDynamicPersonalHotspotInterfaces: Bool = true,
        onFailure: @escaping @Sendable (StartError) -> Void = { _ in }
    ) async throws -> URL {
        let snapshot = try Self.makeSnapshot(
            advertiseHost: advertiseHost,
            zimServerURL: zimServerURL,
            approvedLocalIPAddresses: approvedLocalIPAddresses,
            allowsDynamicPersonalHotspotInterfaces: allowsDynamicPersonalHotspotInterfaces,
            contentSnapshot: contentSnapshot
        )
        let zimItems = snapshot.itemsByID.values.filter { $0.type == .zim }
        try Self.validateZimBackend(
            hasShareableZim: !zimItems.isEmpty,
            hasUnresolvedZimMetadata: zimItems.contains { $0.zimContentID == nil },
            hasZimServer: zimServerURL != nil
        )
        guard let url = Self.portalURL(advertiseHost: advertiseHost) else {
            throw StartError.invalidServerAddress
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? Self.defaultPort)) else {
            throw StartError.invalidPort
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: StartError.cancelled)
                        return
                    }
                    self.stopOnQueue(pendingStartError: .cancelled)
                    do {
                        // Network.framework's portal listener is wildcard, but
                        // it reads no request bytes until the accepted socket's
                        // concrete local address passes the immutable session
                        // scope below. ZIM sessions approve only their Kiwix
                        // binding; portal-only sessions may also accept a
                        // Personal Hotspot enabled after start.
                        let listener = try NWListener(using: .tcp, on: port)
                        listener.newConnectionHandler = { [weak self] connection in
                            self?.handle(connection: connection)
                        }
                        listener.stateUpdateHandler = { [weak self, weak listener] state in
                            guard let self, let listener else { return }
                            self.handle(listenerState: state, for: listener)
                        }
                        self.listener = listener
                        self.snapshot = snapshot
                        self.runtimeFailureHandler = onFailure
                        self.pendingStart = PendingStart(
                            listener: listener,
                            url: url,
                            continuation: continuation,
                            lastWaitingReason: nil
                        )
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + self.listenerReadyTimeout) { [weak self, weak listener] in
                            guard let self, let listener else { return }
                            self.timeoutStart(for: listener)
                        }
                    } catch {
                        self.stopOnQueue()
                        continuation.resume(throwing: StartError.listenerCreationFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                self?.stopOnQueue(pendingStartError: .cancelled)
            }
        }
    }

    static func validateZimBackend(
        hasShareableZim: Bool,
        hasUnresolvedZimMetadata: Bool,
        hasZimServer: Bool
    ) throws {
        guard !hasUnresolvedZimMetadata else {
            throw StartError.unresolvedZimMetadata
        }
        guard !hasShareableZim || hasZimServer else {
            throw StartError.missingZimServer
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue(pendingStartError: .cancelled)
        }
    }

    private func handle(listenerState state: NWListener.State, for listener: NWListener) {
        guard self.listener === listener else { return }
        switch state {
        case .ready:
            listenerIsReady = true
            guard let pendingStart, pendingStart.listener === listener else { return }
            self.pendingStart = nil
            pendingStart.continuation.resume(returning: pendingStart.url)
        case let .waiting(error):
            if var pendingStart, pendingStart.listener === listener {
                pendingStart.lastWaitingReason = error.localizedDescription
                self.pendingStart = pendingStart
            }
        case let .failed(error):
            let startError = StartError.listenerFailed(error.localizedDescription)
            if let pendingStart, pendingStart.listener === listener {
                self.pendingStart = nil
                stopOnQueue()
                pendingStart.continuation.resume(throwing: startError)
            } else {
                let failureHandler = runtimeFailureHandler
                stopOnQueue()
                failureHandler?(startError)
            }
        case .cancelled:
            if let pendingStart, pendingStart.listener === listener {
                self.pendingStart = nil
                stopOnQueue()
                pendingStart.continuation.resume(throwing: StartError.cancelled)
            }
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func timeoutStart(for listener: NWListener) {
        guard let pendingStart, pendingStart.listener === listener else { return }
        let error = StartError.listenerTimedOut(pendingStart.lastWaitingReason)
        self.pendingStart = nil
        stopOnQueue()
        pendingStart.continuation.resume(throwing: error)
    }

    private func stopOnQueue(pendingStartError: StartError? = nil) {
        let continuation = pendingStart?.continuation
        pendingStart = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let connections = Array(activeConnections.values)
        let bookRequestTasks = pendingBookRequests.values.map(\.task)
        activeConnections.removeAll()
        connectionsAwaitingRequest.removeAll()
        connectionsReadingRequest.removeAll()
        pendingBookRequests.removeAll()
        for task in bookRequestTasks {
            task.cancel()
        }
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        snapshot = nil
        listenerIsReady = false
        runtimeFailureHandler = nil
        if let continuation, let pendingStartError {
            continuation.resume(throwing: pendingStartError)
        }
    }

    private func handle(connection: NWConnection) {
        guard listenerIsReady,
              snapshot != nil,
              activeConnections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        connectionsAwaitingRequest.insert(connectionID)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard self.connectionsAwaitingRequest.contains(connectionID),
                      let snapshot = self.snapshot else {
                    self.finish(connection: connection)
                    return
                }
                guard self.connectionsReadingRequest.insert(connectionID).inserted else {
                    return
                }
                let currentPersonalHotspotIPAddresses: Set<String>
                if snapshot.allowsDynamicPersonalHotspotInterfaces {
                    currentPersonalHotspotIPAddresses = Set(
                        ArkFileSharingEndpoints.current()
                            .filter { $0.kind == .personalHotspot }
                            .map(\.ipAddress)
                    )
                } else {
                    currentPersonalHotspotIPAddresses = []
                }
                let localIPAddress = Self.localIPAddress(
                    from: connection.currentPath?.localEndpoint
                )
                guard Self.shouldAcceptPortalConnection(
                    localIPAddress: localIPAddress,
                    approvedLocalIPAddresses: snapshot.approvedLocalIPAddresses,
                    currentPersonalHotspotIPAddresses: currentPersonalHotspotIPAddresses,
                    allowsDynamicPersonalHotspotInterfaces: snapshot.allowsDynamicPersonalHotspotInterfaces
                ) else {
                    self.finish(connection: connection)
                    return
                }
                self.receiveRequest(
                    on: connection,
                    connectionID: connectionID,
                    buffer: Data()
                )
            case .failed, .cancelled:
                self.removeTerminal(connection: connection)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestHeaderTimeout) { [weak self, weak connection] in
            guard let self,
                  let connection,
                  self.connectionsAwaitingRequest.remove(connectionID) != nil else {
                return
            }
            self.finish(connection: connection)
        }
    }

    static func shouldAcceptPortalConnection(
        localIPAddress: String?,
        approvedLocalIPAddresses: Set<String>,
        currentPersonalHotspotIPAddresses: Set<String>,
        allowsDynamicPersonalHotspotInterfaces: Bool = true
    ) -> Bool {
        guard let localIPAddress, !localIPAddress.isEmpty else { return false }
        return approvedLocalIPAddresses.contains(localIPAddress)
            || (allowsDynamicPersonalHotspotInterfaces
                && currentPersonalHotspotIPAddresses.contains(localIPAddress))
    }

    private static func localIPAddress(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return String(describing: host)
    }

    private func receiveRequest(
        on connection: NWConnection,
        connectionID: ObjectIdentifier,
        buffer: Data
    ) {
        let remainingCapacity = Self.maximumRequestHeaderBytes - buffer.count
        guard remainingCapacity > 0 else {
            connectionsAwaitingRequest.remove(connectionID)
            Self.send(status: "431 Request Header Fields Too Large", body: "Request headers are too large.", on: connection)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingCapacity) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.isActive(connection: connection) else {
                connection.cancel()
                return
            }
            guard error == nil else {
                self.connectionsAwaitingRequest.remove(connectionID)
                Self.send(status: "400 Bad Request", body: "Bad request", contentType: "text/plain", on: connection)
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.connectionsAwaitingRequest.remove(connectionID)
                guard let request = Self.parseRequest(data: accumulated) else {
                    Self.send(status: "400 Bad Request", body: "Bad request", contentType: "text/plain", on: connection)
                    return
                }
                self.route(request, connection: connection)
            } else if isComplete {
                self.connectionsAwaitingRequest.remove(connectionID)
                Self.send(status: "400 Bad Request", body: "Bad request", contentType: "text/plain", on: connection)
            } else {
                self.receiveRequest(on: connection, connectionID: connectionID, buffer: accumulated)
            }
        }
    }

    private func isActive(connection: NWConnection) -> Bool {
        listenerIsReady && activeConnections[ObjectIdentifier(connection)] === connection
    }

    private func finish(connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        guard activeConnections.removeValue(forKey: connectionID) != nil else { return }
        connectionsAwaitingRequest.remove(connectionID)
        connectionsReadingRequest.remove(connectionID)
        pendingBookRequests.removeValue(forKey: connectionID)?.task.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func removeTerminal(connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        activeConnections.removeValue(forKey: connectionID)
        connectionsAwaitingRequest.remove(connectionID)
        connectionsReadingRequest.remove(connectionID)
        pendingBookRequests.removeValue(forKey: connectionID)?.task.cancel()
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) {
        guard let snapshot else {
            Self.send(
                status: "503 Service Unavailable",
                body: "Local Sharing is not active.",
                request: request,
                on: connection
            )
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            Self.send(
                status: "405 Method Not Allowed",
                data: Data("Local Sharing is read-only.".utf8),
                contentType: "text/plain; charset=utf-8",
                extraHeaders: ["Allow": "GET, HEAD"],
                on: connection
            )
            return
        }
        guard let normalizedPath = ArkFileLocalSharingAccess.normalizedRequestPath(request.path) else {
            Self.send(
                status: "400 Bad Request",
                body: "Bad request",
                request: request,
                on: connection
            )
            return
        }
        let request = request.replacing(path: normalizedPath)

        switch request.path {
        case "/", "/index.html":
            Self.sendHTML(Self.homePage(snapshot: snapshot), request: request, snapshot: snapshot, on: connection)
        case "/style.css":
            Self.send(
                status: "200 OK",
                body: Self.stylesheet,
                contentType: "text/css; charset=utf-8",
                request: request,
                on: connection
            )
        case "/arkfile-logo.png":
            Self.serveLogo(request: request, on: connection)
        case "/map":
            guard snapshot.allowsMapSharing else {
                Self.send(
                    status: "404 Not Found",
                    body: "Map sharing is not enabled for this content.",
                    request: request,
                    on: connection
                )
                return
            }
            Self.sendHTML(Self.mapPage(snapshot: snapshot), request: request, snapshot: snapshot, on: connection)
        default:
            if request.path.hasPrefix("/item/") {
                openItem(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/view/") {
                serveReader(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/license/") {
                serveContentLicense(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/file/") {
                serveItemFile(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/html/") {
                serveStaticHTML(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/book/") {
                serveBook(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/map/") {
                serveMapItem(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else if request.path.hasPrefix("/tiles/") {
                serveTile(path: request.path, request: request, snapshot: snapshot, connection: connection)
            } else {
                Self.send(
                    status: "404 Not Found",
                    body: "Not found",
                    request: request,
                    on: connection
                )
            }
        }
    }

    private func openItem(path: String, request: HTTPRequest, snapshot: Snapshot, connection: NWConnection) {
        guard let route = Self.routeParts(path: path, prefix: "/item/"),
              let item = snapshot.itemsByID[route.id] else {
            Self.send(
                status: "404 Not Found",
                body: "Content item not found.",
                request: request,
                on: connection
            )
            return
        }
        if item.isLocked {
            Self.sendHTML(Self.lockedContentPage(for: item, snapshot: snapshot), request: request, snapshot: snapshot, on: connection)
            return
        }
        Self.redirect(
            location: Self.sharedPath("/view/\(route.id)", snapshot: snapshot),
            request: request,
            on: connection
        )
    }

    private func serveReader(path: String, request: HTTPRequest, snapshot: Snapshot, connection: NWConnection) {
        guard let route = Self.routeParts(path: path, prefix: "/view/"),
              let item = snapshot.itemsByID[route.id] else {
            Self.send(
                status: "404 Not Found",
                body: "Content item not found.",
                request: request,
                on: connection
            )
            return
        }
        guard !item.isLocked else {
            Self.sendHTML(Self.lockedContentPage(for: item, snapshot: snapshot), request: request, snapshot: snapshot, on: connection)
            return
        }
        Self.sendHTML(Self.readerPage(for: item, snapshot: snapshot), request: request, snapshot: snapshot, on: connection)
    }

    private func serveContentLicense(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard let route = Self.routeParts(path: path, prefix: "/license/"),
              let item = snapshot.itemsByID[route.id],
              let notice = item.receiverNotice else {
            Self.send(
                status: "404 Not Found",
                body: "Content source details not found.",
                request: request,
                on: connection
            )
            return
        }
        Self.sendHTML(
            Self.receiverNoticePage(for: item, notice: notice, snapshot: snapshot),
            request: request,
            snapshot: snapshot,
            on: connection
        )
    }

    private func serveItemFile(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard let route = Self.routeParts(path: path, prefix: "/file/"),
              route.relativePath.isEmpty,
              let item = snapshot.itemsByID[route.id],
              !item.isLocked,
              item.type != .zim,
              item.type != .htmlBook,
              let resolvedURL = Self.resolvedURL(for: item, in: snapshot) else {
            Self.send(
                status: "404 Not Found",
                body: "File not found.",
                request: request,
                on: connection
            )
            return
        }
        sendFile(
            resolvedURL,
            request: request,
            accessCheckURL: resolvedURL,
            downloadName: item.type == .map
                ? Self.mapDownloadFileName(for: item)
                : nil,
            expectedSHA256: item.expectedSHA256,
            expectedByteCount: item.sizeBytes,
            expectedFileIdentity: item.sourceFileIdentity,
            noticePath: item.receiverNotice == nil
                ? nil
                : Self.sharedPath("/license/\(item.id)", snapshot: snapshot),
            connection: connection
        )
    }

    private func serveStaticHTML(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard let route = Self.routeParts(path: path, prefix: "/html/"),
              let item = snapshot.itemsByID[route.id],
              !item.isLocked,
              item.type == .html else {
            Self.send(
                status: "404 Not Found",
                body: "HTML file not found.",
                request: request,
                on: connection
            )
            return
        }

        guard let itemURL = Self.resolvedURL(for: item, in: snapshot) else {
            Self.send(
                status: "404 Not Found",
                body: "HTML file not found.",
                request: request,
                on: connection
            )
            return
        }
        let root = itemURL.deletingLastPathComponent()
        if route.relativePath.isEmpty {
            Self.redirect(
                location: Self.sharedPath("/html/\(item.id)/\(Self.urlPath(for: itemURL.lastPathComponent))", snapshot: snapshot),
                request: request,
                on: connection
            )
            return
        }
        let itemDirectory = (item.relativePath as NSString)
            .deletingLastPathComponent
        let memberRelativePath = itemDirectory.isEmpty
            ? route.relativePath
            : "\(itemDirectory)/\(route.relativePath)"
        guard !ArkFileContentRetirementPolicy.isRetired(
            relativePath: memberRelativePath
        ) else {
            Self.send(
                status: "404 Not Found",
                body: "HTML resource not found.",
                request: request,
                on: connection
            )
            return
        }

        let didStartSecurityScope = itemURL.startAccessingSecurityScopedResource()
        guard let openedMember = Self.openLooseHTMLMember(
            root: root,
            relativePath: route.relativePath,
            expectedIdentity: route.relativePath == itemURL.lastPathComponent
                ? item.sourceFileIdentity
                : nil
        ) else {
            if didStartSecurityScope {
                itemURL.stopAccessingSecurityScopedResource()
            }
            Self.send(
                status: "404 Not Found",
                body: "HTML resource not found.",
                request: request,
                on: connection
            )
            return
        }
        sendOpenedFile(
            openedMember.handle,
            url: root.appendingPathComponent(route.relativePath),
            size: openedMember.size,
            modificationSeconds: openedMember.modificationSeconds,
            request: request,
            accessCheckURL: itemURL,
            expectedFileIdentity: openedMember.identity,
            contentSecurityPolicy: "sandbox; frame-ancestors 'self'",
            securityScopedURL: didStartSecurityScope ? itemURL : nil,
            connection: connection
        )
    }

    private func serveBook(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard let route = Self.routeParts(path: path, prefix: "/book/"),
              let item = snapshot.itemsByID[route.id],
              !item.isLocked,
              item.type == .htmlBook else {
            Self.send(
                status: "404 Not Found",
                body: "Book not found.",
                request: request,
                on: connection
            )
            return
        }

        guard let resolvedURL = Self.resolvedURL(for: item, in: snapshot),
              let localItem = Self.localContentItem(
                  from: item,
                  resolvedURL: resolvedURL
              ) else {
            Self.send(
                status: "404 Not Found",
                body: "Book not found.",
                request: request,
                on: connection
            )
            return
        }

        let connectionID = ObjectIdentifier(connection)
        let token = UUID()
        let itemID = route.id
        let relativePath = route.relativePath
        let provider = bookServingSnapshotProvider
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: BookServingSnapshotResult
            do {
                let servingSnapshot = try provider(localItem)
                if relativePath.isEmpty {
                    result = .success(servingSnapshot, nil)
                } else if let openedMember = servingSnapshot.openMember(
                    for: relativePath
                ) {
                    result = .success(servingSnapshot, openedMember)
                } else {
                    result = .memberUnavailable
                }
            } catch {
                result = .failure
            }
            guard !Task.isCancelled, let self else { return }
            self.queue.async { [weak self] in
                self?.completeBookRequest(
                    token: token,
                    connectionID: connectionID,
                    itemID: itemID,
                    relativePath: relativePath,
                    request: request,
                    resolvedURL: resolvedURL,
                    result: result
                )
            }
        }
        pendingBookRequests.removeValue(forKey: connectionID)?.task.cancel()
        pendingBookRequests[connectionID] = PendingBookRequest(
            token: token,
            task: task
        )
    }

    private func completeBookRequest(
        token: UUID,
        connectionID: ObjectIdentifier,
        itemID: String,
        relativePath: String,
        request: HTTPRequest,
        resolvedURL: URL,
        result: BookServingSnapshotResult
    ) {
        guard let pendingRequest = pendingBookRequests[connectionID],
              pendingRequest.token == token else {
            return
        }
        pendingBookRequests.removeValue(forKey: connectionID)
        guard let connection = activeConnections[connectionID],
              isActive(connection: connection),
              let snapshot,
              let item = snapshot.itemsByID[itemID],
              !item.isLocked,
              item.type == .htmlBook else {
            return
        }
        if case .memberUnavailable = result {
            Self.send(
                status: "404 Not Found",
                body: "Book resource not found.",
                request: request,
                on: connection
            )
            return
        }
        guard case let .success(servingSnapshot, openedMember) = result else {
            Self.send(
                status: "500 Internal Server Error",
                body: "ArkFile could not open this HTML book.",
                request: request,
                on: connection
            )
            return
        }

        let entryURL = servingSnapshot.entryURL
        let root = servingSnapshot.rootURL
        if relativePath.isEmpty {
            guard let entryPath = Self.relativePath(from: root, to: entryURL) else {
                Self.send(
                    status: "500 Internal Server Error",
                    body: "ArkFile could not resolve this HTML book.",
                    request: request,
                    on: connection
                )
                return
            }
            Self.redirect(
                location: Self.sharedPath(
                    "/book/\(item.id)/\(Self.urlPath(for: entryPath))",
                    snapshot: snapshot
                ),
                request: request,
                on: connection
            )
            return
        }

        guard let openedMember else {
            Self.send(
                status: "404 Not Found",
                body: "Book resource not found.",
                request: request,
                on: connection
            )
            return
        }
        sendOpenedFile(
            openedMember.handle,
            url: openedMember.url,
            size: openedMember.byteCount,
            request: request,
            accessCheckURL: resolvedURL,
            expectedSHA256: openedMember.sha256,
            expectedFileIdentity: openedMember.fileIdentity,
            noticePath: item.receiverNotice == nil
                ? nil
                : Self.sharedPath("/license/\(item.id)", snapshot: snapshot),
            contentSecurityPolicy: "sandbox; frame-ancestors 'self'",
            securityScopedURL: nil,
            connection: connection
        )
    }

    private func serveMapItem(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard let route = Self.routeParts(path: path, prefix: "/map/"),
              route.relativePath.isEmpty,
              let item = snapshot.itemsByID[route.id],
              !item.isLocked,
              item.type == .map,
              Self.resolvedURL(for: item, in: snapshot) != nil else {
            Self.send(
                status: "404 Not Found",
                body: "Map file not found.",
                request: request,
                on: connection
            )
            return
        }
        Self.sendHTML(
            Self.mapDownloadPage(for: item, snapshot: snapshot),
            request: request,
            snapshot: snapshot,
            on: connection
        )
    }

    private func serveTile(
        path: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        connection: NWConnection
    ) {
        guard snapshot.allowsMapSharing,
              let mapTilesRoot = snapshot.offlineMapResources.legacyTilesRoot else {
            Self.send(
                status: "404 Not Found",
                body: "Map tiles are not installed.",
                request: request,
                on: connection
            )
            return
        }
        let relative = String(path.dropFirst("/tiles/".count))
        guard relative.range(of: #"^\d+/\d+/\d+\.png$"#, options: .regularExpression) != nil else {
            Self.send(
                status: "400 Bad Request",
                body: "Invalid tile path.",
                request: request,
                on: connection
            )
            return
        }
        let target = mapTilesRoot.appendingPathComponent(relative)
        sendFile(target, request: request, accessCheckURL: target, connection: connection)
    }

    private static func makeSnapshot(
        advertiseHost: String,
        zimServerURL: URL?,
        approvedLocalIPAddresses: Set<String>,
        allowsDynamicPersonalHotspotInterfaces: Bool,
        contentSnapshot: ArkFileLocalSharingContentSnapshot
    ) throws -> Snapshot {
        guard contentSnapshot.orderedDescriptorKeys.count
                == contentSnapshot.descriptorsByCanonicalPath.count,
              contentSnapshot.shareableItemCount
                == contentSnapshot.descriptorsByCanonicalPath.count,
              Set(contentSnapshot.orderedDescriptorKeys)
                == Set(contentSnapshot.descriptorsByCanonicalPath.keys) else {
            throw StartError.invalidContentSnapshot
        }

        var itemsByPath: [String: PortalItem] = [:]
        for key in contentSnapshot.orderedDescriptorKeys {
            guard let descriptor = contentSnapshot
                .descriptorsByCanonicalPath[key],
                  descriptor.canonicalPathKey == key,
                  ArkFileLocalSharingDispositionIndex.canonicalPath(
                      descriptor.item.relativePath
                  ) == key,
                  (descriptor.item.type == .zim)
                    == (descriptor.zimIdentity != nil) else {
                throw StartError.invalidContentSnapshot
            }
            let item = descriptor.item
            guard let sourceFileIdentity = descriptor.sourceFileIdentity
                ?? regularFileIdentity(at: item.url, expectedByteCount: nil)
            else { continue }
            let committedArtifact = descriptor.sourceIdentity?.artifact
            let portalItem = PortalItem(
                id: itemID(for: item.relativePath),
                name: item.displayName,
                url: item.url,
                sourceItem: item,
                relativePath: item.relativePath,
                type: item.type,
                category: item.category,
                subcategory: item.sampleOriginalSubcategory
                    ?? item.subcategory,
                sizeBytes: sourceFileIdentity.byteCount,
                zimContentID: descriptor.zimIdentity?.contentID,
                isLocked: false,
                isSampleContent: item.isSampleContent,
                contentLicense: descriptor.contentLicense,
                receiverNotice: descriptor.disposition?.receiverNotice,
                expectedSHA256: committedArtifact?.byteCount
                    == sourceFileIdentity.byteCount
                    ? committedArtifact?.sha256
                    : nil,
                sourceFileIdentity: sourceFileIdentity
            )
            guard itemsByPath.updateValue(
                portalItem,
                forKey: key
            ) == nil else {
                throw StartError.invalidContentSnapshot
            }
        }
        guard !itemsByPath.isEmpty
                || contentSnapshot.shareableItemCount == 0 else {
            throw StartError.sharedContentUnavailable
        }
        let descriptorZimFileIDs: Set<UUID> = Set(
            contentSnapshot.descriptorsByCanonicalPath.compactMap {
                key, descriptor -> UUID? in
                guard itemsByPath[key] != nil else { return nil }
                return descriptor.zimIdentity?.registrationID
            }
        )
        guard descriptorZimFileIDs == contentSnapshot.zimFileIDs else {
            throw StartError.invalidContentSnapshot
        }

        let categoryKeys = contentSnapshot.categoryDescriptorKeys
            .values
            .flatMap { $0 }
            .filter { itemsByPath[$0] != nil }
        guard categoryKeys.count == Set(categoryKeys).count,
              Set(categoryKeys) == Set(itemsByPath.keys),
              contentSnapshot.categoryDescriptorKeys.allSatisfy({
                  category, keys in
                  keys.filter { itemsByPath[$0] != nil }.allSatisfy {
                      itemsByPath[$0]?.category == category
                  }
              }) else {
            throw StartError.invalidContentSnapshot
        }
        let portalCategories = try ArkFileLocalContentCategoryKey.allCases
            .compactMap { category -> PortalCategory? in
                let keys = contentSnapshot.categoryDescriptorKeys[category]
                    .map { $0.filter { itemsByPath[$0] != nil } } ?? []
                guard !keys.isEmpty else { return nil }
                let items = try keys.map { key -> PortalItem in
                    guard let item = itemsByPath[key] else {
                        throw StartError.invalidContentSnapshot
                    }
                    return item
                }
                return PortalCategory(
                    key: category,
                    title: category.displayName,
                    description: description(for: category),
                    systemImage: category.systemImage,
                    accent: accent(for: category),
                    items: items
                )
            }

        let favoriteCategory: [PortalCategory]
        let availableFavoriteKeys = contentSnapshot.favoriteDescriptorKeys
            .filter { itemsByPath[$0] != nil }
        guard availableFavoriteKeys.count
                == Set(availableFavoriteKeys).count else {
            throw StartError.invalidContentSnapshot
        }
        if availableFavoriteKeys.isEmpty {
            favoriteCategory = []
        } else {
            let favoriteItems = try availableFavoriteKeys.map {
                key -> PortalItem in
                guard let item = itemsByPath[key] else {
                    throw StartError.invalidContentSnapshot
                }
                return item
            }
            favoriteCategory = [
                PortalCategory(
                    key: nil,
                    title: "Favorites",
                    description: "Your favorite ArkFile content",
                    systemImage: "star",
                    accent: "#e38f1d",
                    items: favoriteItems
                )
            ]
        }

        let allItems = Dictionary(uniqueKeysWithValues: itemsByPath.values.map { ($0.id, $0) })
        // Installed map files use the same open-library rule as every other
        // item. Ancillary tile routes remain constrained to the discovered
        // installed map root and read-only request paths.
        let allowsMapSharing = itemsByPath.values.contains {
            $0.type == .map
        }
        let acceptedItems = try contentSnapshot.orderedDescriptorKeys
            .filter { itemsByPath[$0] != nil }
            .map {
            key -> ArkFileLocalContentItem in
            guard let item = contentSnapshot
                .descriptorsByCanonicalPath[key]?.item else {
                throw StartError.invalidContentSnapshot
            }
            return item
        }
        let contentRoots = contentRoots(from: [
            ArkFileLocalContentCategory(key: .general, items: acceptedItems)
        ])
        let offlineMapResources = ArkFileOfflineMapResources.locate(contentRoot: contentRoots.first)

        let allowedHosts = Set(
            Array(approvedLocalIPAddresses)
                + [advertiseHost]
                + [zimServerURL?.host].compactMap { $0 }
        )
        return Snapshot(
            categories: favoriteCategory + portalCategories,
            itemsByID: allItems,
            zimServerURL: zimServerURL,
            zimServerPort: zimServerURL.map { $0.port ?? 80 },
            offlineMapResources: offlineMapResources,
            contentRoots: contentRoots,
            contentLicenseLedgerVersion: contentSnapshot.ledgerVersion,
            allowedHosts: allowedHosts,
            approvedLocalIPAddresses: approvedLocalIPAddresses,
            allowsDynamicPersonalHotspotInterfaces: allowsDynamicPersonalHotspotInterfaces,
            allowsMapSharing: allowsMapSharing
        )
    }

    private static func regularFileIdentity(
        at url: URL,
        expectedByteCount: Int64?
    ) -> ArkFileOpenFileIdentity? {
        guard let identity = ArkFileOpenFileIdentity.capture(
            noFollowURL: url
        ),
              expectedByteCount.map({
                  $0 == identity.byteCount
              }) != false else {
            return nil
        }
        return identity
    }

    private static func localContentItem(
        from item: PortalItem,
        resolvedURL: URL
    ) -> ArkFileLocalContentItem? {
        guard let sourceItem = item.sourceItem else { return nil }
        return ArkFileLocalContentItem(
            name: sourceItem.name,
            url: resolvedURL,
            relativePath: sourceItem.relativePath,
            type: sourceItem.type,
            category: sourceItem.category,
            subcategory: sourceItem.subcategory,
            sizeBytes: sourceItem.sizeBytes,
            isSampleContent: sourceItem.isSampleContent,
            sampleOriginalSubcategory: sourceItem.sampleOriginalSubcategory,
            isBundledSampleAsset: sourceItem.isBundledSampleAsset
        )
    }

    private static func homePage(snapshot: Snapshot) -> String {
        let cards = snapshot.categories.map { category in
            categoryCard(category, snapshot: snapshot)
        }.joined(separator: "\n")

        return page(
            title: "ArkFile Local Library",
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Local Sharing</p>
                <h1>Local ArkFile Content</h1>
                <p>Browse the ArkFile library shared from this device. This library is open to everyone on the local network while sharing is active; no account or access code is required.</p>
              </div>
            </header>
            <main class="grid">
              \(cards)
            </main>
            <footer>
              Keep ArkFile open and this device awake while other devices are reading. Devices must stay on the same local network.
            </footer>
            \(launcherScript)
            """
        )
    }

    private static func readerPage(for item: PortalItem, snapshot: Snapshot) -> String {
        let subtitle = "\(item.type.displayLabel) · \(item.category.displayName)"
        let content = readerContent(for: item, snapshot: snapshot)
        let licenseLink = item.receiverNotice == nil
            ? ""
            : "<a class=\"reader-button secondary\" href=\"\(sharedPath("/license/\(item.id)", snapshot: snapshot))\">Source &amp; notice</a>"
        return page(
            title: item.name,
            bodyClass: "reader-body",
            snapshot: snapshot,
            body: """
            <div class="reader-shell">
              <nav class="reader-nav" aria-label="ArkFile reader navigation">
                <a class="reader-brand" href="\(sharedPath("/", snapshot: snapshot))" aria-label="Back to ArkFile library">
                  <img src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
                </a>
                <div class="reader-title">
                  <strong>\(escape(item.name))</strong>
                  <span>\(escape(subtitle))</span>
                </div>
                <div class="reader-actions">
                  \(licenseLink)
                  <a class="reader-button" href="\(sharedPath("/", snapshot: snapshot))">Library</a>
                </div>
              </nav>
              \(content)
            </div>
            """
        )
    }

    private static func contentLicensePage(
        for item: PortalItem,
        entry: ArkFileContentLicenseEntry,
        snapshot: Snapshot
    ) -> String {
        page(
            title: "License & Source — \(item.name)",
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Title-level content record</p>
                <h1>License &amp; Source</h1>
                <p>\(escape(item.name))</p>
              </div>
            </header>
            <main class="license-card">
              \(titleLicenseHTML(entry: entry))
            </main>
            <p class="license-back"><a class="back" href="\(sharedPath("/view/\(item.id)", snapshot: snapshot))">Back to title</a></p>
            """
        )
    }

    private static func receiverNoticePage(
        for item: PortalItem,
        notice: ArkFileLocalSharingDispositionIndex.Entry.ReceiverNotice,
        snapshot: Snapshot
    ) -> String {
        let sourceValue: String
        if notice.canonicalURL?.isEmpty != false {
            sourceValue = "\(escape(notice.sourceTitle)) (source URL unavailable)"
        } else {
            sourceValue = "<a href=\"\(escape(notice.canonicalURL ?? ""))\">\(escape(notice.sourceTitle))</a>"
        }
        return page(
            title: "Source & Notice — \(item.name)",
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Receiver notice</p>
                <h1>Source &amp; Notice</h1>
                <p>\(escape(item.name))</p>
              </div>
            </header>
            <main class="license-card">
              <dl class="license-details">
                <dt>Source</dt><dd>\(sourceValue)</dd>
                <dt>Creator</dt><dd>\(escape(notice.creators.joined(separator: ", ")))</dd>
                <dt>Publisher</dt><dd>\(escape(notice.publisher ?? "Unknown"))</dd>
                <dt>Attribution</dt><dd>\(escape(notice.attributionText))</dd>
                <dt>Changes</dt><dd>\(escape(notice.changesMade))</dd>
                <dt>Rights summary</dt><dd>\(escape(notice.rightsSummary))</dd>
              </dl>
            </main>
            <p class="license-back"><a class="back" href="\(sharedPath("/view/\(item.id)", snapshot: snapshot))">Back to title</a></p>
            """
        )
    }

    static func titleLicenseHTML(
        entry: ArkFileContentLicenseEntry
    ) -> String {
        """
        <h2>\(escape(entry.displayName))</h2>
        <dl class="license-details">
          <dt>Edition / revision</dt><dd>\(escape(entry.artifact.editionOrRevision))</dd>
          <dt>Source</dt><dd><a href="\(escape(entry.source.canonicalUrl))">\(escape(entry.source.title))</a></dd>
          <dt>Creator</dt><dd>\(escape(entry.source.creators.joined(separator: ", ")))</dd>
          <dt>Publisher</dt><dd>\(escape(entry.source.publisher))</dd>
          <dt>License</dt><dd><a href="\(escape(entry.license.url))">\(escape(entry.license.name)) (\(escape(entry.license.id)))</a></dd>
          <dt>Attribution</dt><dd>\(escape(entry.notices.attributionText))</dd>
          <dt>Changes</dt><dd>\(escape(entry.notices.changesMade))</dd>
          <dt>Downstream rights</dt><dd>\(escape(entry.downstreamRights.summary))</dd>
        </dl>
        """
    }

    private static func lockedContentPage(for item: PortalItem, snapshot: Snapshot) -> String {
        page(
            title: item.name,
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Local Sharing</p>
                <h1>Not Downloaded Yet</h1>
                <p>\(escape(item.name)) is part of an ArkFile pack that has not been downloaded to this device yet. Download it in the ArkFile app on the host device, then share it nearby.</p>
              </div>
            </header>
            <p><a class="back" href="\(sharedPath("/", snapshot: snapshot))">Back to library</a></p>
            """
        )
    }

    private static func readerContent(for item: PortalItem, snapshot: Snapshot) -> String {
        let source = readerSource(for: item, snapshot: snapshot)
        switch item.type {
        case .image:
            return """
            <main class="reader-content image-reader">
              <img class="reader-image" src="\(escape(source))" alt="\(escape(item.name))">
            </main>
            """
        case .pdf:
            return """
            <main class="reader-content pdf-reader">
              <object class="reader-pdf" data="\(escape(source))#view=FitH" type="application/pdf">
                <p><a class="reader-button inline" href="\(escape(source))">Open PDF</a></p>
              </object>
            </main>
            """
        case .htmlBook:
            return """
            <iframe class="reader-frame" src="\(escape(source))" title="\(escape(item.name))" sandbox></iframe>
            """
        case .map:
            return """
            <main class="reader-content image-reader">
              <div class="license-card">
                <p>This map is shared as its exact offline PMTiles file. A compatible map application can open the download; ArkFile does not expose the map's sibling support files.</p>
                <p><a class="reader-button inline" href="\(escape(sharedPath("/file/\(item.id)", snapshot: snapshot)))">Download PMTiles map</a></p>
              </div>
            </main>
            """
        case .zim, .html:
            return """
            <iframe class="reader-frame" src="\(escape(source))" title="\(escape(item.name))"></iframe>
            """
        }
    }

    private static func categoryCard(_ category: PortalCategory, snapshot: Snapshot) -> String {
        let options = selectOptions(for: category.items, snapshot: snapshot)
        let empty = category.items.isEmpty
            ? "<p class=\"empty\">No installed content in this category.</p>"
            : ""
        let availableCount = category.items.filter { !$0.isLocked }.count
        let lockedCount = category.items.filter(\.isLocked).count
        let countText: String
        if lockedCount > 0 {
            // "Not downloaded", never "locked": the phone may own the pack —
            // the portal only knows the file is not on this device yet.
            countText = "\(availableCount) available · \(lockedCount) not downloaded"
        } else {
            countText = "\(availableCount) item\(availableCount == 1 ? "" : "s")"
        }

        return """
        <section class="card" style="--accent: \(category.accent)">
          <div class="card-title">
            <div class="icon">\(symbol(for: category.systemImage))</div>
            <div>
              <h2>\(escape(category.title))</h2>
              <p>\(escape(category.description))</p>
            </div>
          </div>
          <p class="count">\(countText)</p>
          <label class="picker-label" for="select-\(slug(category.title))">Select content</label>
          <select class="content-select" id="select-\(slug(category.title))">
            <option value="">-- Select content --</option>
            \(options)
          </select>
          <div class="selection-panel" hidden>
            <small class="selected-meta">No content selected</small>
            <button class="open-button" type="button">&#9654; Open selected content</button>
          </div>
          \(empty)
        </section>
        """
    }

    private static func selectOptions(for items: [PortalItem], snapshot: Snapshot) -> String {
        Dictionary(grouping: items, by: \.subcategory)
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { groupName, items in
                let options = items.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }.map { item in
                    let label = item.isLocked
                        ? "\(item.name) [Not downloaded]"
                        : "\(item.name) [\(item.type.displayLabel)]"
                    let disabled = item.isLocked ? " disabled" : ""
                    return """
                    <option value="\(sharedPath("/item/\(item.id)", snapshot: snapshot))" data-name="\(escape(item.name))" data-type="\(item.type.displayLabel)"\(disabled)>\(escape(label))</option>
                    """
                }.joined(separator: "\n")
                return """
                <optgroup label="\(escape(groupName))">
                  \(options)
                </optgroup>
                """
            }
            .joined(separator: "\n")
    }

    private static var launcherScript: String {
        """
        <script>
        (() => {
          const selects = Array.from(document.querySelectorAll('.content-select'));

          selects.forEach((select) => {
            const card = select.closest('.card');
            const panel = card ? card.querySelector('.selection-panel') : null;
            const button = panel ? panel.querySelector('.open-button') : null;
            const meta = panel ? panel.querySelector('.selected-meta') : null;
            let selectedURL = '';

            select.addEventListener('change', () => {
              const option = select.selectedOptions[0];
              selectedURL = option && option.value ? option.value : '';
              if (!panel || !button || !meta) return;
              if (selectedURL.length === 0) {
                panel.hidden = true;
                meta.textContent = 'No content selected';
                return;
              }
              const name = option.dataset.name || option.textContent;
              const type = option.dataset.type || 'Item';
              panel.hidden = false;
              meta.textContent = `Selected: ${name} [${type}]`;
            });

            if (button) {
              button.addEventListener('click', () => {
                if (selectedURL.length > 0) window.location.href = selectedURL;
              });
            }
          });
        })();
        </script>
        """
    }

    private static func mapPage(snapshot: Snapshot) -> String {
        let resources = snapshot.offlineMapResources
        let sampleTiles = sampleMapTiles(root: resources.legacyTilesRoot)
        let mapRows = [
            resources.base.map { "<li>Base app global map: \($0.relativePath), z\(Int($0.minZoom))-z\(Int($0.maxZoom))</li>" },
            resources.detail.map { "<li>Essentials North America detail: \($0.relativePath), z\(Int($0.minZoom))-z\(Int($0.maxZoom))</li>" }
        ].compactMap { $0 }.joined(separator: "\n")
        let tileMarkup: String
        if !mapRows.isEmpty {
            tileMarkup = "<ul class=\"item-list\">\(mapRows)</ul>"
        } else if sampleTiles.isEmpty {
            tileMarkup = "<p class=\"empty\">Offline vector map files were not found in this Essentials install.</p>"
        } else {
            tileMarkup = sampleTiles.map { tile in
                "<img src=\"\(sharedPath("/tiles/\(tile)", snapshot: snapshot))\" alt=\"Map tile\">"
            }.joined(separator: "\n")
        }
        return page(
            title: "ArkFile Offline Map",
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Local Sharing</p>
                <h1>Offline Vector Map</h1>
                <p>This view confirms offline map files are available from the host device. Open the map inside ArkFile for the interactive map view.</p>
              </div>
            </header>
            <p><a class="back" href="\(sharedPath("/", snapshot: snapshot))">Back to library</a></p>
            <div class="tile-grid">\(tileMarkup)</div>
            """
        )
    }

    private static func mapDownloadPage(for item: PortalItem, snapshot: Snapshot) -> String {
        page(
            title: item.name,
            snapshot: snapshot,
            body: """
            <header class="hero">
              <a class="logo-link" href="\(sharedPath("/", snapshot: snapshot))" aria-label="ArkFile home">
                <img class="logo-img" src="\(sharedPath("/arkfile-logo.png", snapshot: snapshot))" alt="ArkFile">
              </a>
              <div>
                <p class="eyebrow">Offline map data</p>
                <h1>\(escape(item.name))</h1>
                <p>This map is shared as its exact offline PMTiles file. A compatible map application can open the downloaded file; this browser page is not an interactive map viewer.</p>
              </div>
            </header>
            <main class="license-card">
              <p><strong>Size:</strong> \(escape(sizeString(item.sizeBytes)))</p>
              <p><a class="reader-button inline" href="\(sharedPath("/file/\(item.id)", snapshot: snapshot))">Download PMTiles map</a></p>
            </main>
            <p class="license-back"><a class="back" href="\(sharedPath("/", snapshot: snapshot))">Back to library</a></p>
            """
        )
    }

    private static func page(title: String, bodyClass: String = "", snapshot: Snapshot, body: String) -> String {
        let classAttribute = bodyClass.isEmpty ? "" : " class=\"\(escape(bodyClass))\""
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(escape(title))</title>
          <link rel="stylesheet" href="\(sharedPath("/style.css", snapshot: snapshot))">
        </head>
        <body\(classAttribute)>
          \(body)
        </body>
        </html>
        """
    }

    private static var stylesheet: String {
        """
        :root {
          color-scheme: light;
          --sand: #fff1b8;
          --surface: #fffdf6;
          --ink: #2b170e;
          --teal: #123f3e;
          --taupe: #6c5a3b;
          --border: rgba(108, 90, 59, 0.28);
          --gold: #e38f1d;
        }
        * { box-sizing: border-box; }
        html { height: 100%; }
        body {
          margin: 0;
          padding: 20px;
          background: linear-gradient(180deg, var(--sand), #fff6cf 54%, #fffdf6);
          color: var(--ink);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        body.reader-body {
          height: 100dvh;
          min-height: -webkit-fill-available;
          padding: 0;
          overflow: hidden;
          background: var(--surface);
          overscroll-behavior: none;
        }
        .hero, .card {
          background: rgba(255,253,246,0.94);
          border: 1px solid var(--border);
          border-radius: 8px;
          box-shadow: 0 8px 24px rgba(43, 23, 14, 0.08);
        }
        .hero {
          display: flex;
          gap: 16px;
          align-items: center;
          padding: 16px;
          margin: 0 auto 18px;
          max-width: 1120px;
        }
        .logo-link {
          display: grid;
          place-items: center;
          flex: 0 0 84px;
          width: 84px;
          height: 84px;
          border-radius: 50%;
          text-decoration: none;
        }
        .logo-img {
          width: 100%;
          height: 100%;
          border-radius: 50%;
          object-fit: cover;
          display: block;
        }
        .eyebrow {
          margin: 0 0 4px;
          color: var(--taupe);
          text-transform: uppercase;
          letter-spacing: .08em;
          font-size: 12px;
          font-weight: 700;
        }
        h1 { margin: 0 0 6px; font-size: clamp(26px, 4vw, 38px); line-height: 1.05; }
        h2 { margin: 0; font-size: 21px; color: #86451f; line-height: 1.1; }
        p { line-height: 1.4; }
        .hero p:last-child, .card-title p { margin: 0; color: var(--taupe); }
        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(min(100%, 330px), 1fr));
          gap: 14px;
          max-width: 1120px;
          margin: 0 auto;
        }
        .card { padding: 16px; min-height: 152px; }
        .card-title {
          display: flex;
          gap: 12px;
          align-items: flex-start;
          margin-bottom: 14px;
        }
        .icon {
          display: grid;
          place-items: center;
          width: 36px;
          height: 36px;
          border-radius: 8px;
          background: color-mix(in srgb, var(--accent), transparent 84%);
          color: var(--accent);
          font-weight: 800;
        }
        .count {
          margin: 0 0 10px;
          color: var(--taupe);
          font-size: 13px;
        }
        .picker-label {
          position: absolute;
          width: 1px;
          height: 1px;
          overflow: hidden;
          clip: rect(0 0 0 0);
        }
        select {
          width: 100%;
          min-height: 44px;
          border: 1px solid rgba(108, 90, 59, 0.26);
          border-radius: 6px;
          background: #fffef9;
          color: var(--ink);
          font: inherit;
          padding: 0 12px;
        }
        select:focus {
          outline: 2px solid rgba(18, 63, 62, 0.18);
          border-color: var(--teal);
        }
        .selection-panel {
          margin-top: 10px;
          padding: 10px;
          border-radius: 8px;
          background: color-mix(in srgb, var(--accent), transparent 88%);
        }
        .selected-meta {
          display: block;
          margin-bottom: 8px;
          color: var(--taupe);
          font-size: 12px;
          font-weight: 700;
        }
        .open-button {
          width: 100%;
          min-height: 48px;
          border: 0;
          border-radius: 6px;
          background: var(--teal);
          color: #fffdf6;
          font: inherit;
          font-weight: 800;
          box-shadow: 0 8px 20px rgba(18,63,62,.18);
        }
        .reader-shell {
          display: grid;
          grid-template-rows: auto minmax(0, 1fr);
          position: fixed;
          inset: 0;
          height: 100dvh;
          min-height: -webkit-fill-available;
          overflow: hidden;
          background: var(--surface);
        }
        .reader-nav {
          display: grid;
          grid-template-columns: auto minmax(0, 1fr) auto;
          gap: 10px;
          align-items: center;
          min-height: calc(64px + env(safe-area-inset-top));
          padding: calc(8px + env(safe-area-inset-top)) 12px 8px;
          border-bottom: 1px solid var(--border);
          background: #fff8d8;
          box-shadow: 0 4px 18px rgba(43, 23, 14, 0.08);
          z-index: 20;
          touch-action: manipulation;
        }
        .reader-brand {
          display: grid;
          place-items: center;
          width: 44px;
          height: 44px;
          border-radius: 50%;
          overflow: hidden;
        }
        .reader-brand img {
          width: 44px;
          height: 44px;
          object-fit: cover;
          display: block;
        }
        .reader-title {
          min-width: 0;
          display: grid;
          gap: 2px;
        }
        .reader-title strong,
        .reader-title span {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .reader-title strong {
          color: var(--ink);
          font-size: 15px;
          line-height: 1.15;
        }
        .reader-title span {
          color: var(--taupe);
          font-size: 12px;
        }
        .reader-button {
          display: inline-grid;
          place-items: center;
          min-height: 40px;
          padding: 0 14px;
          border-radius: 6px;
          background: var(--teal);
          color: #fffdf6;
          text-decoration: none;
          font-weight: 800;
          position: relative;
          z-index: 21;
          touch-action: manipulation;
        }
        .reader-button.inline {
          display: inline-grid;
          width: auto;
        }
        .reader-actions {
          display: flex;
          gap: 7px;
          align-items: center;
        }
        .reader-button.secondary {
          background: #fffef9;
          color: var(--teal);
          border: 1px solid var(--teal);
        }
        .license-card {
          max-width: 860px;
          margin: 0 auto;
          padding: 18px;
          border: 1px solid var(--border);
          border-radius: 8px;
          background: var(--surface);
        }
        .license-details {
          display: grid;
          grid-template-columns: minmax(130px, 0.35fr) minmax(0, 1fr);
          gap: 10px 16px;
        }
        .license-details dt { color: var(--taupe); font-weight: 700; }
        .license-details dd { margin: 0; overflow-wrap: anywhere; }
        .license-details a { color: var(--teal); }
        .license-back { max-width: 860px; margin: 14px auto; }
        .reader-content {
          min-height: 0;
          overflow: auto;
          -webkit-overflow-scrolling: touch;
          background: #fff;
        }
        .image-reader {
          display: grid;
          align-content: start;
          justify-items: center;
          padding: 12px;
        }
        .reader-image {
          display: block;
          width: 100%;
          max-width: 100%;
          height: auto;
          object-fit: contain;
          transform-origin: top center;
        }
        .pdf-reader {
          padding: 0;
        }
        .reader-pdf {
          display: block;
          width: 100%;
          height: 100%;
          min-height: calc(100vh - 64px);
          border: 0;
          background: #fff;
        }
        .reader-frame {
          display: block;
          width: 100%;
          height: 100%;
          min-height: 0;
          border: 0;
          background: #fff;
        }
        .back {
          display: inline-block;
          margin: 0 0 14px;
          color: var(--teal);
          font-weight: 700;
        }
        .tile-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
          gap: 8px;
          max-width: 900px;
          margin: 0 auto;
        }
        .tile-grid img {
          width: 100%;
          border: 1px solid var(--border);
          background: var(--surface);
        }
        footer {
          max-width: 1120px;
          margin: 18px auto 0;
          color: var(--taupe);
          font-size: 13px;
        }
        .empty {
          color: var(--taupe);
          font-style: italic;
          margin: 8px 0 0;
        }
        @media (max-width: 520px) {
          body { padding: 10px; }
          body.reader-body { padding: 0; }
          .hero { align-items: flex-start; gap: 12px; padding: 14px; }
          .logo-link { width: 64px; height: 64px; flex-basis: 64px; }
          h1 { font-size: 27px; }
          .hero p:last-child { font-size: 15px; }
          .card { min-height: 0; }
          .reader-nav {
            min-height: calc(58px + env(safe-area-inset-top));
            padding: calc(7px + env(safe-area-inset-top)) 9px 7px;
          }
          .reader-brand, .reader-brand img { width: 40px; height: 40px; }
          .reader-button { min-height: 38px; padding: 0 11px; }
          .reader-actions { gap: 4px; }
          .reader-button.secondary { padding: 0 9px; }
          .license-details { grid-template-columns: 1fr; gap: 4px; }
          .license-details dd { margin: 0 0 10px; }
        }
        """
    }

    private static func parseRequest(data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let target = parts[1]
        let components = URLComponents(string: "http://local\(target)")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            headers[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return HTTPRequest(
            method: parts[0],
            path: components?.path.removingPercentEncoding ?? "/",
            queryItems: components?.queryItems ?? [],
            headers: headers
        )
    }

    private static func sendHTML(
        _ html: String,
        request: HTTPRequest,
        snapshot: Snapshot,
        on connection: NWConnection
    ) {
        let resolvedHTML: String
        guard let zimServerURL = snapshot.zimServerURL,
              let zimServerPort = snapshot.zimServerPort else {
            resolvedHTML = html
            send(
                status: "200 OK",
                body: resolvedHTML,
                contentType: "text/html; charset=utf-8",
                request: request,
                on: connection
            )
            return
        }
        let newlyAvailableHotspotHosts: [String]
        if snapshot.allowsDynamicPersonalHotspotInterfaces {
            newlyAvailableHotspotHosts = ArkFileSharingEndpoints.current()
                .filter { $0.kind == .personalHotspot }
                .map(\.ipAddress)
        } else {
            newlyAvailableHotspotHosts = []
        }
        resolvedHTML = resolvedZimHostHTML(
                html,
                hostHeader: request.headers["host"],
                fallbackHost: zimServerURL.host,
                zimServerPort: zimServerPort,
                allowedHosts: snapshot.allowedHosts.union(newlyAvailableHotspotHosts)
            )
        send(
            status: "200 OK",
            body: resolvedHTML,
            contentType: "text/html; charset=utf-8",
            request: request,
            on: connection
        )
    }

    private static func serveLogo(
        request: HTTPRequest,
        on connection: NWConnection
    ) {
        guard let image = UIImage(named: "welcomeLogo"),
              let data = image.pngData() else {
            send(
                status: "404 Not Found",
                body: "Logo not found.",
                request: request,
                on: connection
            )
            return
        }
        send(
            status: "200 OK",
            data: data,
            contentType: "image/png",
            extraHeaders: [:],
            request: request,
            on: connection
        )
    }

    private static func send(
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection
    ) {
        let data = Data(body.utf8)
        send(status: status, data: data, contentType: contentType, extraHeaders: [:], on: connection)
    }

    private static func redirect(
        location: String,
        request: HTTPRequest,
        on connection: NWConnection
    ) {
        let data = Data("Redirecting to \(location)".utf8)
        send(
            status: "302 Found",
            data: data,
            contentType: "text/plain; charset=utf-8",
            extraHeaders: ["Location": location],
            request: request,
            on: connection
        )
    }

    private static func send(
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        request: HTTPRequest,
        on connection: NWConnection
    ) {
        send(
            status: status,
            data: Data(body.utf8),
            contentType: contentType,
            extraHeaders: [:],
            request: request,
            on: connection
        )
    }

    private static func send(
        status: String,
        data: Data,
        contentType: String,
        extraHeaders: [String: String],
        request: HTTPRequest,
        on connection: NWConnection
    ) {
        if request.method == "HEAD" {
            sendHeaderOnly(
                status: status,
                contentLength: Int64(data.count),
                contentType: contentType,
                extraHeaders: extraHeaders,
                on: connection
            )
        } else {
            send(
                status: status,
                data: data,
                contentType: contentType,
                extraHeaders: extraHeaders,
                on: connection
            )
        }
    }

    private func sendFile(
        _ url: URL,
        request: HTTPRequest,
        accessCheckURL: URL,
        downloadName: String? = nil,
        expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil,
        expectedFileIdentity: ArkFileOpenFileIdentity? = nil,
        noticePath: String? = nil,
        contentSecurityPolicy: String? = nil,
        connection: NWConnection
    ) {
        guard isActive(connection: connection) else {
            Self.send(
                status: "404 Not Found",
                body: "This installed file is no longer available.",
                request: request,
                on: connection
            )
            return
        }
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        guard let openedFile = Self.openPortalFile(
            at: url,
            expectedByteCount: expectedByteCount,
            expectedIdentity: expectedFileIdentity
        ) else {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            Self.send(
                status: "404 Not Found",
                body: "File not found.",
                request: request,
                on: connection
            )
            return
        }
        sendOpenedFile(
            openedFile.handle,
            url: url,
            size: openedFile.size,
            modificationSeconds: openedFile.modificationSeconds,
            request: request,
            accessCheckURL: accessCheckURL,
            downloadName: downloadName,
            expectedSHA256: expectedSHA256,
            expectedFileIdentity: openedFile.identity,
            noticePath: noticePath,
            contentSecurityPolicy: contentSecurityPolicy,
            securityScopedURL: didStartSecurityScope ? url : nil,
            connection: connection
        )
    }

    private static func openPortalFile(
        at url: URL,
        expectedByteCount: Int64?,
        expectedIdentity: ArkFileOpenFileIdentity?
    ) -> OpenedPortalFile? {
        let descriptor = Darwin.open(
            url.standardizedFileURL.fileSystemPath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        guard let identity = ArkFileOpenFileIdentity.capture(
            fileDescriptor: descriptor
        ),
              expectedByteCount.map({
                  $0 == identity.byteCount
              }) != false,
              expectedIdentity.map({ $0 == identity }) != false else {
            try? handle.close()
            return nil
        }
        return OpenedPortalFile(
            handle: handle,
            size: identity.byteCount,
            modificationSeconds: identity.modificationSeconds,
            identity: identity
        )
    }

    /// Opens a loose HTML sibling through no-follow directory descriptors so
    /// an installed HTML page can load its assets without exposing symlinks,
    /// parent traversal, or ArkFile's hidden metadata.
    private static func openLooseHTMLMember(
        root: URL,
        relativePath: String,
        expectedIdentity: ArkFileOpenFileIdentity?
    ) -> OpenedPortalFile? {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
                      && !$0.hasPrefix(".")
              }) else {
            return nil
        }
        let rootDescriptor = Darwin.open(
            root.standardizedFileURL.fileSystemPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return nil }
        var directoryDescriptor = rootDescriptor
        var ownsDirectoryDescriptor = false
        defer {
            if ownsDirectoryDescriptor {
                Darwin.close(directoryDescriptor)
            }
            Darwin.close(rootDescriptor)
        }

        for component in components.dropLast() {
            let nextDescriptor = String(component).withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return nil }
            if ownsDirectoryDescriptor {
                Darwin.close(directoryDescriptor)
            }
            directoryDescriptor = nextDescriptor
            ownsDirectoryDescriptor = true
        }

        guard let finalComponent = components.last else { return nil }
        let fileDescriptor = String(finalComponent).withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard fileDescriptor >= 0 else { return nil }
        let handle = FileHandle(
            fileDescriptor: fileDescriptor,
            closeOnDealloc: true
        )
        guard let identity = ArkFileOpenFileIdentity.capture(
            fileDescriptor: fileDescriptor
        ),
              expectedIdentity.map({ $0 == identity }) != false else {
            try? handle.close()
            return nil
        }
        return OpenedPortalFile(
            handle: handle,
            size: identity.byteCount,
            modificationSeconds: identity.modificationSeconds,
            identity: identity
        )
    }

    private func sendOpenedFile(
        _ handle: FileHandle,
        url: URL,
        size: Int64,
        modificationSeconds: Int64 = 0,
        request: HTTPRequest,
        accessCheckURL: URL,
        downloadName: String? = nil,
        expectedSHA256: String? = nil,
        expectedFileIdentity: ArkFileOpenFileIdentity,
        noticePath: String? = nil,
        contentSecurityPolicy: String? = nil,
        securityScopedURL: URL?,
        connection: NWConnection
    ) {
        guard isActive(connection: connection),
              size == expectedFileIdentity.byteCount,
              Self.openFileIdentityMatches(
                  handle: handle,
                  expectedIdentity: expectedFileIdentity
              ) else {
            try? handle.close()
            securityScopedURL?.stopAccessingSecurityScopedResource()
            Self.send(
                status: "404 Not Found",
                body: "This installed file is no longer available.",
                request: request,
                on: connection
            )
            return
        }
        let contentType = Self.mimeType(for: url)
        let rangeHeader = request.headers["range"]
        let range = Self.byteRange(from: rangeHeader, fileSize: size)
        if rangeHeader != nil, range == nil {
            try? handle.close()
            securityScopedURL?.stopAccessingSecurityScopedResource()
            Self.send(
                status: "416 Range Not Satisfiable",
                data: Data(),
                contentType: contentType,
                extraHeaders: [
                    "Content-Range": "bytes */\(size)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-store"
                ],
                request: request,
                on: connection
            )
            return
        }
        let entityTag = expectedSHA256.map { "\"\($0.lowercased())\"" }
            ?? "\"\(size)-\(modificationSeconds)\""
        if range == nil, request.headers["if-none-match"] == entityTag {
            try? handle.close()
            securityScopedURL?.stopAccessingSecurityScopedResource()
            var notModifiedHeaders = [
                "ETag": entityTag,
                "Cache-Control": "no-store"
            ]
            if let downloadName {
                notModifiedHeaders["Content-Disposition"]
                    = "attachment; filename=\"\(downloadName)\""
            }
            if let noticePath {
                notModifiedHeaders["Link"] = "<\(noticePath)>; rel=\"license\""
            }
            if let contentSecurityPolicy {
                notModifiedHeaders["Content-Security-Policy"]
                    = contentSecurityPolicy
            }
            Self.send(
                status: "304 Not Modified",
                data: Data(),
                contentType: contentType,
                extraHeaders: notModifiedHeaders,
                request: request,
                on: connection
            )
            return
        }
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? max(size - 1, 0)
        let length = range.map { max($0.upperBound - $0.lowerBound + 1, 0) } ?? size
        if request.method == "HEAD" {
            try? handle.close()
            securityScopedURL?.stopAccessingSecurityScopedResource()
            var headers: [String: String] = [
                "Accept-Ranges": "bytes",
                "ETag": entityTag,
                "Cache-Control": "no-store"
            ]
            if let downloadName {
                headers["Content-Disposition"]
                    = "attachment; filename=\"\(downloadName)\""
            }
            if let noticePath {
                headers["Link"] = "<\(noticePath)>; rel=\"license\""
            }
            if let contentSecurityPolicy {
                headers["Content-Security-Policy"] = contentSecurityPolicy
            }
            let status: String
            if range != nil {
                status = "206 Partial Content"
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            } else {
                status = "200 OK"
            }
            Self.sendHeaderOnly(
                status: status,
                contentLength: length,
                contentType: contentType,
                extraHeaders: headers,
                on: connection
            )
            return
        }

        do {
            try handle.seek(toOffset: UInt64(start))
            var headers: [String: String] = [
                "Accept-Ranges": "bytes",
                "ETag": entityTag,
                "Cache-Control": "no-store"
            ]
            if let downloadName {
                headers["Content-Disposition"] = "attachment; filename=\"\(downloadName)\""
            }
            if let noticePath {
                headers["Link"] = "<\(noticePath)>; rel=\"license\""
            }
            if let contentSecurityPolicy {
                headers["Content-Security-Policy"] = contentSecurityPolicy
            }
            let status: String
            if range != nil {
                status = "206 Partial Content"
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            } else {
                status = "200 OK"
            }
            let headerData = Self.responseHeaderData(
                status: status,
                contentLength: length,
                contentType: contentType,
                extraHeaders: headers
            )
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    Self.closeFileTransfer(
                        handle: handle,
                        securityScopedURL: securityScopedURL,
                        connection: connection
                    )
                    return
                }
                guard error == nil else {
                    self.finishFileTransfer(
                        handle: handle,
                        securityScopedURL: securityScopedURL,
                        connection: connection
                    )
                    return
                }
                self.sendNextFileChunk(
                    handle: handle,
                    remainingBytes: length,
                    accessCheckURL: accessCheckURL,
                    expectedFileIdentity: expectedFileIdentity,
                    securityScopedURL: securityScopedURL,
                    connection: connection
                )
            })
        } catch {
            try? handle.close()
            securityScopedURL?.stopAccessingSecurityScopedResource()
            Self.send(
                status: "500 Internal Server Error",
                body: "Could not read file.",
                request: request,
                on: connection
            )
        }
    }

    private static let fileTransferChunkSize = 256 * 1024

    private func sendNextFileChunk(
        handle: FileHandle,
        remainingBytes: Int64,
        accessCheckURL: URL,
        expectedFileIdentity: ArkFileOpenFileIdentity,
        securityScopedURL: URL?,
        connection: NWConnection
    ) {
        let connectionIsActive = isActive(connection: connection)
        guard Self.shouldContinueFileTransfer(
            remainingBytes: remainingBytes,
            serverIsReady: listenerIsReady,
            connectionIsTracked: connectionIsActive,
            accessIsAllowed: true
        ),
              Self.openFileIdentityMatches(
                  handle: handle,
                  expectedIdentity: expectedFileIdentity
              ) else {
            finishFileTransfer(
                handle: handle,
                securityScopedURL: securityScopedURL,
                connection: connection
            )
            return
        }

        do {
            let requestedCount = Int(min(remainingBytes, Int64(Self.fileTransferChunkSize)))
            let data = try handle.read(upToCount: requestedCount) ?? Data()
            guard !data.isEmpty,
                  Self.openFileIdentityMatches(
                      handle: handle,
                      expectedIdentity: expectedFileIdentity
                  ) else {
                finishFileTransfer(
                    handle: handle,
                    securityScopedURL: securityScopedURL,
                    connection: connection
                )
                return
            }
            let nextRemaining = remainingBytes - Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    Self.closeFileTransfer(
                        handle: handle,
                        securityScopedURL: securityScopedURL,
                        connection: connection
                    )
                    return
                }
                guard error == nil else {
                    self.finishFileTransfer(
                        handle: handle,
                        securityScopedURL: securityScopedURL,
                        connection: connection
                    )
                    return
                }
                self.sendNextFileChunk(
                    handle: handle,
                    remainingBytes: nextRemaining,
                    accessCheckURL: accessCheckURL,
                    expectedFileIdentity: expectedFileIdentity,
                    securityScopedURL: securityScopedURL,
                    connection: connection
                )
            })
        } catch {
            finishFileTransfer(
                handle: handle,
                securityScopedURL: securityScopedURL,
                connection: connection
            )
        }
    }

    static func shouldContinueFileTransfer(
        remainingBytes: Int64,
        serverIsReady: Bool,
        connectionIsTracked: Bool,
        accessIsAllowed: Bool
    ) -> Bool {
        remainingBytes > 0 && serverIsReady && connectionIsTracked && accessIsAllowed
    }

    static func openFileIdentityMatches(
        handle: FileHandle,
        expectedIdentity: ArkFileOpenFileIdentity
    ) -> Bool {
        ArkFileOpenFileIdentity.capture(
            fileDescriptor: handle.fileDescriptor
        ) == expectedIdentity
    }

    private func finishFileTransfer(
        handle: FileHandle,
        securityScopedURL: URL?,
        connection: NWConnection
    ) {
        Self.closeFileTransfer(
            handle: handle,
            securityScopedURL: securityScopedURL,
            connection: connection,
            cancelConnection: false
        )
        finish(connection: connection)
    }

    private static func closeFileTransfer(
        handle: FileHandle,
        securityScopedURL: URL?,
        connection: NWConnection,
        cancelConnection: Bool = true
    ) {
        try? handle.close()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if cancelConnection {
            connection.cancel()
        }
    }

    private static func send(
        status: String,
        data: Data,
        contentType: String,
        extraHeaders: [String: String],
        on connection: NWConnection
    ) {
        var response = responseHeaderData(
            status: status,
            contentLength: Int64(data.count),
            contentType: contentType,
            extraHeaders: extraHeaders
        )
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func sendHeaderOnly(
        status: String,
        contentLength: Int64,
        contentType: String,
        extraHeaders: [String: String],
        on connection: NWConnection
    ) {
        connection.send(
            content: responseHeaderData(
                status: status,
                contentLength: contentLength,
                contentType: contentType,
                extraHeaders: extraHeaders
            ),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private static func responseHeaderData(
        status: String,
        contentLength: Int64,
        contentType: String,
        extraHeaders: [String: String]
    ) -> Data {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: SAMEORIGIN",
            "Referrer-Policy: no-referrer"
        ]
        if extraHeaders["Content-Security-Policy"] == nil {
            headers.append("Content-Security-Policy: frame-ancestors 'self'")
        }
        if extraHeaders["Cache-Control"] == nil {
            headers.append("Cache-Control: no-store")
        }
        for (key, value) in extraHeaders {
            headers.append("\(key): \(value)")
        }
        headers.append("")
        headers.append("")

        return Data(headers.joined(separator: "\r\n").utf8)
    }

    static func byteRange(from header: String?, fileSize: Int64) -> ClosedRange<Int64>? {
        guard let header,
              header.lowercased().hasPrefix("bytes="),
              fileSize > 0 else {
            return nil
        }
        let rangeText = header.dropFirst("bytes=".count)
        guard !rangeText.contains(",") else { return nil }
        let parts = rangeText.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        guard let start = Int64(startText), start >= 0, start < fileSize else { return nil }
        let requestedEnd: Int64
        if endText.isEmpty {
            requestedEnd = fileSize - 1
        } else {
            guard let parsedEnd = Int64(endText), parsedEnd >= 0 else {
                return nil
            }
            requestedEnd = parsedEnd
        }
        let end = min(requestedEnd, fileSize - 1)
        guard end >= start else { return nil }
        return start...end
    }

    private static func portalURL(advertiseHost: String) -> URL? {
        let host = advertiseHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("\0") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = defaultPort
        components.path = "/"
        return components.url
    }

    private static func sharedPath(_ path: String, snapshot: Snapshot) -> String {
        ArkFileLocalSharingAccess.sharedPath(path)
    }

    private static let defaultPort = 8090
    private static func description(for key: ArkFileLocalContentCategoryKey) -> String {
        switch key {
        case .general:
            "Wikipedia and general reference"
        case .medical:
            "Medical references and first aid guides"
        case .foodPreparation:
            "Cooking, canning, and food preservation"
        case .travel:
            "Travel guides, destination info, and offline maps"
        case .booksDocuments:
            "E-books and documents"
        }
    }

    private static func accent(for key: ArkFileLocalContentCategoryKey) -> String {
        switch key {
        case .general, .travel:
            "#123f3e"
        case .medical:
            "#346a54"
        case .foodPreparation:
            "#b65218"
        case .booksDocuments:
            "#86451f"
        }
    }

    private static func symbol(for systemImage: String) -> String {
        switch systemImage {
        case "star":
            "☆"
        case "archivebox":
            "▣"
        case "cross.case":
            "+"
        case "fork.knife":
            "╂"
        case "map":
            "⌁"
        case "books.vertical":
            "▥"
        default:
            "•"
        }
    }

    private static func sizeString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func itemID(for relativePath: String) -> String {
        Data(relativePath.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func contentRoots(from categories: [ArkFileLocalContentCategory]) -> [URL] {
        var rootsByPath: [String: URL] = [:]
        for item in categories.flatMap(\.items) {
            guard let root = contentRoot(for: item.url, relativePath: item.relativePath) else { continue }
            rootsByPath[root.standardizedFileURL.path] = root
        }
        return rootsByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func contentRoot(for url: URL, relativePath: String) -> URL? {
        let targetPath = url.standardizedFileURL.path
        let normalizedRelativePath = normalizedRelativePath(relativePath)
        guard !normalizedRelativePath.isEmpty else { return nil }
        let suffix = "/" + normalizedRelativePath
        guard targetPath.hasSuffix(suffix) else { return nil }
        let rootPath = String(targetPath.dropLast(suffix.count))
        guard !rootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    private static func resolvedURL(for item: PortalItem, in snapshot: Snapshot) -> URL? {
        guard !ArkFileContentRetirementPolicy.isRetired(relativePath: item.relativePath) else {
            return nil
        }
        guard let itemURL = item.url,
              FileManager.default.fileExists(atPath: itemURL.fileSystemPath) else {
            return nil
        }
        // The snapshot captures one exact canonical URL. Never substitute a
        // same-relative-path file from another installed/sample root.
        return itemURL
    }

    private static func readerSource(for item: PortalItem, snapshot: Snapshot) -> String {
        switch item.type {
        case .zim:
            guard let zimServerURL = snapshot.zimServerURL else {
                // Startup rejects this state. Keep the renderer defensive if a
                // future route is introduced without the same invariant.
                return "about:blank"
            }
            return zimContentURL(for: item, serverURL: zimServerURL).absoluteString
        case .htmlBook:
            return sharedPath("/book/\(item.id)/", snapshot: snapshot)
        case .map:
            return sharedPath("/map/\(item.id)", snapshot: snapshot)
        case .html:
            return sharedPath("/html/\(item.id)/", snapshot: snapshot)
        case .pdf, .image:
            return sharedPath("/file/\(item.id)", snapshot: snapshot)
        }
    }

    /// Substituted per request from the client's Host header. ZIM sessions
    /// permit only the same explicitly bound interface as the raw server.
    static let zimHostPlaceholder = "__ARKFILE_ZIM_HOST__"

    private static func zimContentURL(for item: PortalItem, serverURL: URL) -> URL {
        let zimName = item.zimContentID ?? item.url.map(zimName(for:)) ?? item.id
        let scheme = serverURL.scheme ?? "http"
        return URL(string: "\(scheme)://\(zimHostPlaceholder)/content/\(urlPath(for: zimName))") ?? serverURL
    }

    static func resolvedZimHostHTML(
        _ html: String,
        hostHeader: String?,
        fallbackHost: String?,
        zimServerPort: Int,
        allowedHosts: Set<String>? = nil
    ) -> String {
        guard html.contains(zimHostPlaceholder) else { return html }
        let headerHost = hostHeader?
            .split(separator: ":")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if let headerHost,
           !headerHost.isEmpty,
           headerHost.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
           allowedHosts?.contains(headerHost) != false {
            host = headerHost
        } else {
            host = fallbackHost ?? "localhost"
        }
        return html.replacingOccurrences(of: zimHostPlaceholder, with: "\(host):\(zimServerPort)")
    }

    private static func zimContentID(for item: ArkFileLocalContentItem) -> String? {
        guard item.type == .zim,
              let metadata = ZimService.__getMetaData(withFileURL: item.url),
              !metadata.fileID.uuidString.isEmpty else {
            return nil
        }
        return metadata.fileID.uuidString.lowercased()
    }

    private static func zimName(for url: URL) -> String {
        url.deletingPathExtension()
            .lastPathComponent
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func mapDownloadFileName(for item: PortalItem) -> String {
        let components = item.relativePath.split(separator: "/")
        let region = components.count >= 3
            ? String(components[components.count - 2])
            : item.name
        let slug = region.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "arkfile-\(slug.isEmpty ? "map" : slug).pmtiles"
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "pdf":
            return "application/pdf"
        case "pmtiles":
            return "application/vnd.pmtiles"
        default:
            return "application/octet-stream"
        }
    }

    private static func sampleMapTiles(root: URL?) -> [String] {
        guard let root,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var tiles: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard tiles.count < 12 else { break }
            guard url.pathExtension.lowercased() == "png",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let relative = url.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.range(of: #"^\d+/\d+/\d+\.png$"#, options: .regularExpression) != nil {
                tiles.append(relative)
            }
        }
        return tiles.sorted()
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "content" : collapsed
    }

    private static func routeParts(path: String, prefix: String) -> (id: String, relativePath: String)? {
        guard path.hasPrefix(prefix) else { return nil }
        let routedPath = String(path.dropFirst(prefix.count))
        let parts = routedPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let idPart = parts.first, !idPart.isEmpty else { return nil }
        let relativePath = parts.count > 1 ? normalizedRelativePath(String(parts[1])) : ""
        return (String(idPart), relativePath)
    }

    private static func normalizedRelativePath(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func relativePath(from root: URL, to url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(targetPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func urlPath(for relativePath: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#[]@!$&'()*+,;="))
        return relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }
}
#endif

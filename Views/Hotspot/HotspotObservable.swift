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

import SwiftUI
import Combine

enum HotspotState: Equatable {
    @MainActor static let selection = MultiSelectedZimFilesViewModel()

    case started(URL, CGImage?)
    case starting
    case stopped
    case error(title: String, description: String)

    var isStarted: Bool {
        switch self {
        case .stopped, .starting, .error: return false
        case .started: return true
        }
    }

    var isStarting: Bool {
        if case .starting = self {
            return true
        }
        return false
    }
}

enum HotspotAsyncStartPolicy {
    static func shouldApply(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        startedSession: Hotspot.ServingSession,
        desiredSession: Hotspot.ServingSession?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && expectedGeneration == currentGeneration
            && desiredSession == startedSession
    }
}

@MainActor
final class HotspotObservable: ObservableObject {

    private struct LocalSharingReaderLease {
        let sessionID: UUID
        let token: ArkFileManagedContentReaderToken
    }

    @Published var buttonTitle: String = LocalString.hotspot_action_start_hotspot_title
    @Published var state: HotspotState = .stopped
    /// Portal-only sessions can show every approved reachable interface. A
    /// raw ZIM session shows only its single explicitly bound interface.
    @Published var sharingLinks: [ArkFileSharingLink] = []
    private var hotspot = Hotspot.shared
    private var cancellables = Set<AnyCancellable>()
    private var hotspotStartTask: Task<Void, Never>?
    private var hotspotStartGeneration: UInt64 = 0
    private var hotspotStateTask: Task<Void, Never>?
    private var hotspotStateGeneration: UInt64 = 0
    private var desiredServingSession: Hotspot.ServingSession?
    private var localSharingReaderLease: LocalSharingReaderLease?
    private var portalOwnerSessionID: UUID?
    private var endpointRefreshTask: Task<Void, Never>?
    private var sharedBaseURL: URL?
    private var contentSnapshot: ArkFileLocalSharingContentSnapshot?
    private var approvedEndpoints: [ArkFileSharingEndpoint] = []
    private var approvedNetworkBoundary: ArkFileSharingNetworkBoundary?
    #if os(iOS)
    private let networkPathGenerationMonitor = ArkFileSharingNetworkPathGenerationMonitor()
    #endif
    @MainActor
    static let shared = HotspotObservable()

    private static let endpointRefreshInterval: UInt64 = 3_000_000_000

    /// The immutable snapshot owned by the active or starting session. UI
    /// counts must not drift to a newly scanned library while that session is
    /// still serving its original content boundary.
    var activeLocalSharingContentSnapshot:
        ArkFileLocalSharingContentSnapshot? {
        guard state.isStarted || state.isStarting else { return nil }
        return contentSnapshot
    }

    private init() {
        hotspot.$state.sink { [weak self] state in
            Task { @MainActor [weak self] in
                self?.scheduleUpdate(hotspotState: state)
            }
        }.store(in: &cancellables)
        #if os(iOS)
        Publishers.CombineLatest(
            ArkFileLocalContentLibrary.shared.$categories,
            ArkFileLocalContentLibrary.shared.$libraryCategories
        )
        .dropFirst()
        .sink { [weak self] categories, libraryCategories in
            guard let self, self.state.isStarted, let currentSnapshot = self.contentSnapshot else {
                return
            }
            let favorites = ArkFileContentFavorites.shared.favoriteItems(in: categories)
            let refreshed = ArkFileLocalSharingContentSnapshot.make(
                categories: categories,
                libraryCategories: libraryCategories,
                favoriteItems: favorites,
                additionalZimFileIDs: currentSnapshot.zimFileIDs
            )
            guard refreshed.identity != currentSnapshot.identity else { return }
            Task { @MainActor [weak self] in
                await self?.stopForContentMutation()
            }
        }
        .store(in: &cancellables)
        #endif
    }

    func toggleWith(zimFileIds: Set<UUID>) async {
        if state.isStarted || state.isStarting {
            await stopSharing()
        } else {
            #if os(iOS)
            let sessionID = UUID()
            guard localSharingReaderLease == nil,
                  let readerToken = ArkFileManagedContentConcurrencyGate.tryBeginLocalSharingRead() else {
                update(state: .error(
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile is finishing a content update. Try Local Sharing again in a moment."
                ))
                return
            }
            localSharingReaderLease = LocalSharingReaderLease(
                sessionID: sessionID,
                token: readerToken
            )
            let approvedPathGeneration = await networkPathGenerationMonitor.currentGeneration()
            guard !Task.isCancelled, ownsReaderLease(sessionID: sessionID) else {
                releaseLocalSharingReaderToken(for: sessionID)
                if desiredServingSession == nil, localSharingReaderLease == nil {
                    update(state: .stopped)
                }
                return
            }
            approvedEndpoints = ArkFileSharingEndpoints.current()
            let preparedNetworkBoundary = ArkFileSharingNetworkBoundary(
                approvedEndpoints: approvedEndpoints,
                pathGeneration: approvedPathGeneration
            )
            approvedNetworkBoundary = preparedNetworkBoundary
            // The all-content lease must cover refresh and snapshot creation;
            // otherwise activation can replace a path between discovery and
            // the first portal/raw read.
            update(state: .starting)
            await ArkFileLocalContentLibrary.shared.refresh()
            guard !Task.isCancelled, ownsReaderLease(sessionID: sessionID) else {
                releaseLocalSharingReaderToken(for: sessionID)
                approvedEndpoints = []
                approvedNetworkBoundary = nil
                if desiredServingSession == nil, localSharingReaderLease == nil {
                    update(state: .stopped)
                }
                return
            }
            let currentEndpoints = ArkFileSharingEndpoints.current()
            let currentPathGeneration = await networkPathGenerationMonitor.currentGeneration()
            guard !preparedNetworkBoundary.requiresFreshConfirmation(
                currentEndpoints: currentEndpoints,
                currentPathGeneration: currentPathGeneration
            ) else {
                releaseLocalSharingReaderToken(for: sessionID)
                approvedEndpoints = []
                approvedNetworkBoundary = nil
                update(state: .error(
                    title: "Local Sharing Couldn't Start",
                    description: "This device joined a different local network. Confirm Local Sharing again on that network."
                ))
                return
            }
            let categories = ArkFileLocalContentLibrary.shared.categories
            let libraryCategories = ArkFileLocalContentLibrary.shared.libraryCategories
            let favorites = ArkFileContentFavorites.shared.favoriteItems(in: categories)
            // Refresh can discover and register a newly installed managed ZIM
            // after the view captured its Core Data IDs. Include those fresh
            // registrations in this first sharing session instead of making
            // the user stop and start a second time.
            let refreshedManagedZimFileIDs = Set(
                categories.flatMap(\.items).compactMap {
                    item -> UUID? in
                    guard item.type == .zim else { return nil }
                    return ZimService.__sharedInstance()
                        .__registeredIdentifier(forFileURL: item.url)
                }
            )
            let requestedZimFileIDs = zimFileIds.union(
                refreshedManagedZimFileIDs
            )
            var openableZimFileIDs = Set<UUID>()
            for zimFileID in requestedZimFileIDs.sorted(
                by: { $0.uuidString < $1.uuidString }
            ) {
                if await ZimFileService.shared.openArchive(
                    zimFileID: zimFileID
                ) != nil {
                    openableZimFileIDs.insert(zimFileID)
                }
            }
            guard !Task.isCancelled, ownsReaderLease(sessionID: sessionID) else {
                releaseLocalSharingReaderToken(for: sessionID)
                approvedEndpoints = []
                approvedNetworkBoundary = nil
                if desiredServingSession == nil, localSharingReaderLease == nil {
                    update(state: .stopped)
                }
                return
            }
            let preparedSnapshot = ArkFileLocalSharingContentSnapshot.make(
                categories: categories,
                libraryCategories: libraryCategories,
                favoriteItems: favorites,
                additionalZimFileIDs: openableZimFileIDs
            )
            let servingPlan = ArkFileLocalSharingServingPlan(
                contentSnapshot: preparedSnapshot
            )
            guard let requestedMode = servingPlan.servingMode else {
                releaseLocalSharingReaderToken(for: sessionID)
                approvedEndpoints = []
                approvedNetworkBoundary = nil
                update(state: .error(
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile could not find a readable item in \(ArkFileDeviceCopy.thisDevice)'s library."
                ))
                return
            }
            let usableApprovedEndpoints = ArkFileSharingEndpoints.visibleEndpoints(
                approved: approvedEndpoints,
                current: currentEndpoints,
                boundZimEndpoint: nil
            )
            guard !usableApprovedEndpoints.isEmpty else {
                releaseLocalSharingReaderToken(for: sessionID)
                approvedEndpoints = []
                approvedNetworkBoundary = nil
                update(state: .error(
                    title: "Waiting for Wi-Fi or Personal Hotspot",
                    description: "Connect this device to Wi-Fi or turn on Personal Hotspot, then tap Start Local Sharing again."
                ))
                return
            }
            let zimBindingEndpoint: ArkFileSharingEndpoint?
            switch requestedMode {
            case .portalOnly:
                zimBindingEndpoint = nil
            case .zim:
                guard let selectedEndpoint = ArkFileSharingEndpoints.preferredZimBinding(
                    from: usableApprovedEndpoints
                ) else {
                    releaseLocalSharingReaderToken(for: sessionID)
                    approvedEndpoints = []
                    approvedNetworkBoundary = nil
                    update(state: .error(
                        title: "Waiting for Wi-Fi or Personal Hotspot",
                        description: "Connect this device to Wi-Fi or turn on Personal Hotspot, then tap Start Local Sharing again."
                    ))
                    return
                }
                zimBindingEndpoint = selectedEndpoint
            }
            let requestedSession = Hotspot.ServingSession(
                id: sessionID,
                mode: requestedMode,
                zimBindingEndpoint: zimBindingEndpoint
            )
            contentSnapshot = preparedSnapshot
            #else
            let requestedSession = Hotspot.ServingSession(mode: .zim(zimFileIds))
            #endif
            desiredServingSession = requestedSession
            update(state: .starting)
            hotspotStartGeneration &+= 1
            let generation = hotspotStartGeneration
            let task = Task { [hotspot] in
                await hotspot.start(session: requestedSession)
            }
            hotspotStartTask = task
            await task.value
            if (task.isCancelled || Task.isCancelled),
               desiredServingSession == requestedSession {
                await stopSharing()
                return
            }
            if hotspotStartGeneration == generation {
                hotspotStartTask = nil
            }
        }
    }

    /// Local Sharing is deliberately foreground-only. Screen lock and app
    /// backgrounding invalidate the session before iOS suspends its listeners.
    func stopForAppBackground() async {
        guard state.isStarted || state.isStarting else { return }
        await stopSharing()
    }

    func resetError() {
        hotspot.resetError()
        if case .error = state {
            update(state: .stopped)
        }
    }

    private func scheduleUpdate(hotspotState: Hotspot.State) {
        hotspotStateGeneration &+= 1
        let generation = hotspotStateGeneration
        hotspotStateTask?.cancel()
        hotspotStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.update(hotspotState: hotspotState, generation: generation)
            if self.hotspotStateGeneration == generation {
                self.hotspotStateTask = nil
            }
        }
    }

    private func update(hotspotState: Hotspot.State, generation: UInt64) async {
        switch hotspotState {
        case let .started(servingSession):
            // A superseding state task or explicit stop owns cleanup. A stale
            // task must not touch singleton servers because a newer session may
            // already own them.
            guard !Task.isCancelled, generation == hotspotStateGeneration else {
                return
            }
            guard desiredServingSession == servingSession else {
                guard desiredServingSession == nil else {
                    // This is a delayed state event from an older session. Its
                    // stop path already completed before the replacement lease
                    // could be acquired.
                    return
                }
                stopPortalServer(ownedBy: servingSession.id)
                stopEndpointRefresh()
                await hotspot.stop()
                releaseLocalSharingReaderToken(for: servingSession.id)
                if desiredServingSession == nil, localSharingReaderLease == nil {
                    update(state: .stopped)
                }
                return
            }
            let zimServerURL: URL?
            switch servingSession.mode {
            case .portalOnly:
                zimServerURL = nil
            case .zim:
                zimServerURL = await hotspot.serverAddress()
            }
            guard shouldApplyStart(generation: generation, servingSession: servingSession) else {
                return
            }

            #if os(iOS)
            if case .zim = servingSession.mode, zimServerURL == nil {
                await failLocalSharing(.invalidServerAddress, session: servingSession)
                return
            }
            guard let contentSnapshot else {
                await failLocalSharing(.cancelled, session: servingSession)
                return
            }
            let currentEndpoints = ArkFileSharingEndpoints.current()
            guard let approvedNetworkBoundary,
                  !approvedNetworkBoundary.requiresFreshConfirmation(
                    currentEndpoints: currentEndpoints,
                    currentPathGeneration: await networkPathGenerationMonitor.currentGeneration()
                  ) else {
                await stopForNetworkReplacement()
                return
            }
            let visibleEndpoints = ArkFileSharingEndpoints.visibleEndpoints(
                approved: approvedEndpoints,
                current: currentEndpoints,
                boundZimEndpoint: servingSession.zimBindingEndpoint
            )
            guard let advertiseEndpoint = visibleEndpoints.first else {
                await failLocalSharing(.invalidServerAddress, session: servingSession)
                return
            }
            let advertiseHost = advertiseEndpoint.ipAddress
            let portalApprovedIPAddresses: Set<String>
            let allowsDynamicPersonalHotspotInterfaces: Bool
            if let bindingEndpoint = servingSession.zimBindingEndpoint {
                portalApprovedIPAddresses = [bindingEndpoint.ipAddress]
                allowsDynamicPersonalHotspotInterfaces = false
            } else {
                portalApprovedIPAddresses = Set(approvedEndpoints.map(\.ipAddress))
                allowsDynamicPersonalHotspotInterfaces = true
            }
            portalOwnerSessionID = servingSession.id
            do {
                let portalAddress = try await ArkFileLocalSharingPortalServer.shared.start(
                    advertiseHost: advertiseHost,
                    zimServerURL: zimServerURL,
                    approvedLocalIPAddresses: portalApprovedIPAddresses,
                    contentSnapshot: contentSnapshot,
                    allowsDynamicPersonalHotspotInterfaces: allowsDynamicPersonalHotspotInterfaces,
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.portalOwnerSessionID == servingSession.id,
                                  self.shouldApplyStart(
                                    generation: generation,
                                    servingSession: servingSession
                                  ) else { return }
                            await self.failLocalSharing(error, session: servingSession)
                        }
                    }
                )
                guard shouldApplyStart(generation: generation, servingSession: servingSession) else {
                    stopPortalServer(ownedBy: servingSession.id)
                    return
                }
                buttonTitle = LocalString.hotspot_action_stop_hotspot_title
                sharedBaseURL = portalAddress
                await rebuildSharingLinks(
                    baseURL: portalAddress,
                    expectedGeneration: generation,
                    expectedServingSession: servingSession
                )
                guard shouldApplyStart(generation: generation, servingSession: servingSession) else {
                    stopPortalServer(ownedBy: servingSession.id)
                    stopEndpointRefresh()
                    return
                }
                startEndpointRefresh(session: servingSession)
            } catch let error as ArkFileLocalSharingPortalServer.StartError {
                if shouldApplyStart(generation: generation, servingSession: servingSession) {
                    await failLocalSharing(error, session: servingSession)
                } else {
                    stopPortalServer(ownedBy: servingSession.id)
                }
            } catch {
                if shouldApplyStart(generation: generation, servingSession: servingSession) {
                    await failLocalSharing(
                        .listenerFailed(error.localizedDescription),
                        session: servingSession
                    )
                } else {
                    stopPortalServer(ownedBy: servingSession.id)
                }
            }
            #else
            guard let address = zimServerURL else {
                await hotspot.fail(
                    sessionID: servingSession.id,
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile could not determine the local server address."
                )
                return
            }
            buttonTitle = LocalString.hotspot_action_stop_hotspot_title
            sharedBaseURL = address
            await rebuildSharingLinks(
                baseURL: address,
                expectedGeneration: generation,
                expectedServingSession: servingSession
            )
            guard shouldApplyStart(generation: generation, servingSession: servingSession) else {
                stopEndpointRefresh()
                return
            }
            startEndpointRefresh(session: servingSession)
            #endif
        case .stopped:
            // Explicit stop retains the lease until Hotspot.__stop() has
            // completed. A delayed stop from an older session must not clear a
            // replacement session.
            guard desiredServingSession == nil, localSharingReaderLease == nil else {
                return
            }
            contentSnapshot = nil
            approvedEndpoints = []
            approvedNetworkBoundary = nil
            stopPortalServer()
            stopEndpointRefresh()
            buttonTitle = LocalString.hotspot_action_start_hotspot_title
            update(state: .stopped)
        case let .error(sessionID, title, description):
            if let sessionID {
                guard desiredServingSession?.id == sessionID
                        || localSharingReaderLease?.sessionID == sessionID else {
                    return
                }
            } else {
                guard desiredServingSession == nil, localSharingReaderLease == nil else {
                    return
                }
            }
            desiredServingSession = nil
            contentSnapshot = nil
            approvedEndpoints = []
            approvedNetworkBoundary = nil
            if let sessionID {
                stopPortalServer(ownedBy: sessionID)
                releaseLocalSharingReaderToken(for: sessionID)
            } else {
                stopPortalServer()
            }
            stopEndpointRefresh()
            buttonTitle = LocalString.hotspot_action_start_hotspot_title
            update(state: .error(title: title, description: description))
        }
    }

    /// Portal-only sessions expose every approved reachable interface. A ZIM
    /// session exposes exactly the endpoint to which raw Kiwix was bound.
    private func rebuildSharingLinks(
        baseURL: URL,
        expectedGeneration: UInt64? = nil,
        expectedServingSession: Hotspot.ServingSession? = nil
    ) async {
        guard canApplyLinkUpdate(
            expectedGeneration: expectedGeneration,
            expectedServingSession: expectedServingSession
        ) else { return }
        let session = expectedServingSession ?? desiredServingSession
        #if os(iOS)
        let endpoints = ArkFileSharingEndpoints.visibleEndpoints(
            approved: approvedEndpoints,
            current: ArkFileSharingEndpoints.current(),
            boundZimEndpoint: session?.zimBindingEndpoint
        )
        #else
        var endpoints = ArkFileSharingEndpoints.current()
        if endpoints.isEmpty, let host = baseURL.host, !host.isEmpty {
            endpoints = [ArkFileSharingEndpoint(
                interfaceName: "server",
                ipAddress: host,
                kind: .other
            )]
        }
        #endif
        var links: [ArkFileSharingLink] = endpoints.compactMap { endpoint in
            guard let url = ArkFileSharingEndpoints.url(baseURL, replacingHostWith: endpoint.ipAddress) else {
                return nil
            }
            return ArkFileSharingLink(endpoint: endpoint, url: url, qrCodeImage: nil)
        }
        if links.isEmpty {
            sharingLinks = []
            if session?.zimBindingEndpoint != nil {
                await stopForNetworkReplacement()
            } else if !state.isStarted, let session {
                #if os(iOS)
                await failLocalSharing(.invalidServerAddress, session: session)
                #else
                await hotspot.fail(
                    sessionID: session.id,
                    title: "Local Sharing Couldn't Start",
                    description: "ArkFile could not determine a usable local network address."
                )
                #endif
            }
            return
        }

        guard canApplyLinkUpdate(
            expectedGeneration: expectedGeneration,
            expectedServingSession: expectedServingSession
        ) else { return }
        if state.isStarted, links.map(\.id) == sharingLinks.map(\.id) {
            // Same interfaces as before: keep the existing QR codes.
            return
        }
        sharingLinks = links
        update(state: .started(primaryURL(of: links), nil))
        for index in links.indices {
            links[index].qrCodeImage = await QRCode.image(from: links[index].url.absoluteString)
            guard canApplyLinkUpdate(
                expectedGeneration: expectedGeneration,
                expectedServingSession: expectedServingSession
            ) else { return }
        }
        sharingLinks = links
        update(state: .started(primaryURL(of: links), links.first?.qrCodeImage))
    }

    private func primaryURL(of links: [ArkFileSharingLink]) -> URL {
        links.first?.url ?? sharedBaseURL ?? URL(fileURLWithPath: "/")
    }

    /// Watches the immutable network boundary. Portal-only sessions may add a
    /// newly enabled Personal Hotspot. ZIM sessions never change their single
    /// binding: losing it stops the session and requires confirmation.
    private func startEndpointRefresh(session: Hotspot.ServingSession) {
        guard endpointRefreshTask == nil else { return }
        endpointRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HotspotObservable.endpointRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.state.isStarted,
                      self.desiredServingSession == session,
                      let baseURL = self.sharedBaseURL else { continue }
                let currentEndpoints = ArkFileSharingEndpoints.current()
                #if os(iOS)
                guard let approvedNetworkBoundary = self.approvedNetworkBoundary,
                      !approvedNetworkBoundary.requiresFreshConfirmation(
                        currentEndpoints: currentEndpoints,
                        currentPathGeneration: await self.networkPathGenerationMonitor.currentGeneration()
                      ) else {
                    await self.stopForNetworkReplacement()
                    return
                }
                if let bindingEndpoint = session.zimBindingEndpoint {
                    guard ArkFileSharingEndpoints.isBoundEndpointAvailable(
                        bindingEndpoint,
                        in: currentEndpoints
                    ) else {
                        await self.stopForNetworkReplacement()
                        return
                    }
                }
                let currentIDs = ArkFileSharingEndpoints.visibleEndpoints(
                    approved: self.approvedEndpoints,
                    current: currentEndpoints,
                    boundZimEndpoint: session.zimBindingEndpoint
                ).map(\.id)
                #else
                let currentIDs = currentEndpoints.map(\.id)
                #endif
                if currentIDs != self.sharingLinks.map(\.endpoint.id) {
                    await self.rebuildSharingLinks(
                        baseURL: baseURL,
                        expectedServingSession: session
                    )
                }
            }
        }
    }

    private func stopEndpointRefresh() {
        endpointRefreshTask?.cancel()
        endpointRefreshTask = nil
        sharedBaseURL = nil
        sharingLinks = []
    }

    private func shouldApplyStart(
        generation: UInt64,
        servingSession: Hotspot.ServingSession
    ) -> Bool {
        HotspotAsyncStartPolicy.shouldApply(
            expectedGeneration: generation,
            currentGeneration: hotspotStateGeneration,
            startedSession: servingSession,
            desiredSession: desiredServingSession,
            isCancelled: Task.isCancelled
        )
    }

    private func canApplyLinkUpdate(
        expectedGeneration: UInt64?,
        expectedServingSession: Hotspot.ServingSession?
    ) -> Bool {
        guard !Task.isCancelled, desiredServingSession != nil else { return false }
        if let expectedGeneration, expectedGeneration != hotspotStateGeneration {
            return false
        }
        if let expectedServingSession, expectedServingSession != desiredServingSession {
            return false
        }
        return true
    }

    private func stopSharing() async {
        let sessionID = desiredServingSession?.id ?? localSharingReaderLease?.sessionID
        desiredServingSession = nil
        contentSnapshot = nil
        approvedEndpoints = []
        approvedNetworkBoundary = nil
        hotspotStartGeneration &+= 1
        hotspotStartTask?.cancel()
        hotspotStartTask = nil
        hotspotStateGeneration &+= 1
        hotspotStateTask?.cancel()
        hotspotStateTask = nil
        if let sessionID {
            stopPortalServer(ownedBy: sessionID)
        } else {
            stopPortalServer()
        }
        stopEndpointRefresh()
        buttonTitle = LocalString.hotspot_action_start_hotspot_title
        await hotspot.stop()
        if let sessionID {
            releaseLocalSharingReaderToken(for: sessionID)
        }
        if desiredServingSession == nil, localSharingReaderLease == nil {
            update(state: .stopped)
        }
    }

    private func stopForContentMutation() async {
        await stopSharing()
        update(state: .error(
            title: "Local Sharing Stopped",
            description: "The installed library changed. Review the available content, then start Local Sharing again."
        ))
    }

    private func stopForNetworkReplacement() async {
        await stopSharing()
        update(state: .error(
            title: "Local Sharing Stopped",
            description: "The Wi-Fi or Personal Hotspot used by this session changed or became unavailable. Confirm Local Sharing again before restarting."
        ))
    }

    private func stopPortalServer() {
        #if os(iOS)
        ArkFileLocalSharingPortalServer.shared.stop()
        #endif
        portalOwnerSessionID = nil
    }

    private func stopPortalServer(ownedBy sessionID: UUID) {
        guard portalOwnerSessionID == sessionID else { return }
        #if os(iOS)
        ArkFileLocalSharingPortalServer.shared.stop()
        #endif
        portalOwnerSessionID = nil
    }

    #if os(iOS)
    private func failLocalSharing(
        _ error: ArkFileLocalSharingPortalServer.StartError,
        session: Hotspot.ServingSession
    ) async {
        guard desiredServingSession == session
                || localSharingReaderLease?.sessionID == session.id else {
            return
        }
        let title = state.isStarted ? "Local Sharing Stopped" : "Local Sharing Couldn't Start"
        let description = "\(error.localizedDescription) Check Local Network access, then tap Start Local Sharing to retry."
        desiredServingSession = nil
        contentSnapshot = nil
        approvedEndpoints = []
        approvedNetworkBoundary = nil
        stopPortalServer(ownedBy: session.id)
        stopEndpointRefresh()
        await hotspot.fail(sessionID: session.id, title: title, description: description)
        releaseLocalSharingReaderToken(for: session.id)
        if desiredServingSession == nil, localSharingReaderLease == nil {
            buttonTitle = LocalString.hotspot_action_start_hotspot_title
            update(state: .error(title: title, description: description))
        }
    }
    #endif

    private func ownsReaderLease(sessionID: UUID) -> Bool {
        localSharingReaderLease?.sessionID == sessionID
    }

    private func releaseLocalSharingReaderToken(for sessionID: UUID) {
        guard localSharingReaderLease?.sessionID == sessionID else { return }
        localSharingReaderLease?.token.release()
        localSharingReaderLease = nil
    }

    private func update(state newState: HotspotState) {
        if state != newState {
            state = newState
        }
    }
}

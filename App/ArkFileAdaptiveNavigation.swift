// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Combine
import CoreData
import Foundation

/// A stable, scene-portable identity for one persisted reader tab.
///
/// The adaptive shell deliberately keeps Core Data object instances out of its
/// semantic route. Permanent object URI representations survive view
/// reconstruction and can be compared without relying on a particular context.
struct ArkFileReaderTabIdentity: Hashable, Sendable {
    let objectURI: URL

    init(objectURI: URL) {
        self.objectURI = objectURI
    }

    init(objectID: NSManagedObjectID) {
        objectURI = objectID.uriRepresentation()
    }
}

enum ArkFileAdaptiveDestination: String, CaseIterable, Hashable, Sendable {
    case home
    case library
    case downloads
    case saved
    case map
    case savedWeather
    case preparedness
    case localSharing
    case settings
    case reader

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .downloads: "Downloads"
        case .saved: "Saved"
        case .map: "Map"
        case .savedWeather: "Saved Weather"
        case .preparedness: "Preparedness"
        case .localSharing: "Local Sharing"
        case .settings: "Settings"
        case .reader: "Reading"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .downloads: "arrow.down.circle"
        case .saved: "bookmark"
        case .map: "map"
        case .savedWeather: "cloud.sun"
        case .preparedness: "checklist"
        case .localSharing: "wifi"
        case .settings: "gearshape"
        case .reader: "book"
        }
    }

    var accessibilityIdentifier: String {
        "arkfile_ipad_nav_\(rawValue)"
    }
}

enum ArkFileAdaptivePreparednessRoute: Hashable, Sendable {
    case toolkit(selectedView: String?)
    case survivalGuide(sectionID: String?, blockID: String?)
}

/// The complete semantic navigation route for one app scene.
///
/// Large-screen and compact presentations consume the same route even when
/// they render it differently (for example, an iPad detail versus an iPhone
/// sheet).
enum ArkFileAdaptiveRoute: Hashable, Sendable {
    case home
    case library
    case importedFile(fileID: UUID)
    case downloads(relativePath: String?)
    case saved
    case map
    case savedWeather
    case preparedness(ArkFileAdaptivePreparednessRoute)
    case localSharing
    case settings(scrollToHotspot: Bool)
    case reader(ArkFileReaderTabIdentity)

    var destination: ArkFileAdaptiveDestination {
        switch self {
        case .home: .home
        case .library, .importedFile: .library
        case .downloads: .downloads
        case .saved: .saved
        case .map: .map
        case .savedWeather: .savedWeather
        case .preparedness: .preparedness
        case .localSharing: .localSharing
        case .settings: .settings
        case .reader: .reader
        }
    }
}

enum ArkFileAdaptiveNavigationIntent: Equatable, Sendable {
    case select(ArkFileAdaptiveRoute)
    case expectReader
    case activateReader(ArkFileReaderTabIdentity)
    case presentStaticContent
}

struct ArkFileAdaptiveSceneContentOpenIntent: Equatable, Sendable {
    fileprivate let revision: UInt
}

enum ArkFileAdaptiveHomeTransitionPolicy {
    /// Home replaces the lone reader on iPhone, but is only another
    /// destination beside preserved reader tabs on iPad.
    static func clearsCurrentReader(usesSingleReader: Bool) -> Bool {
        usesSingleReader
    }
}

enum ArkFileAdaptivePresentationPolicy {
    /// Only iPhone uses ArkFile's separate compact reader tree. Every iPad
    /// width keeps one NavigationSplitView so UIKit can collapse its columns
    /// without reconstructing stateful detail content.
    static func usesSeparateCompactPresentation(
        device: Device
    ) -> Bool {
        device == .iPhone
    }
}

enum ArkFileAdaptiveCompactColumn: Equatable, Sendable {
    case sidebar
    case detail
}

struct ArkFileAdaptiveSplitColumnPlan: Equatable, Sendable {
    let showsAllRegularColumns: Bool
    let preferredCompactColumn: ArkFileAdaptiveCompactColumn
}

enum ArkFileAdaptiveSidebarTogglePolicy {
    /// Regular windows hide or restore the leading column. A narrow Stage
    /// Manager or multitasking window instead changes which collapsed column
    /// is on top while keeping the semantic detail route intact.
    static func plan(
        isCompactWidth: Bool,
        regularShowsDetailOnly: Bool,
        compactShowsSidebar: Bool
    ) -> ArkFileAdaptiveSplitColumnPlan {
        if isCompactWidth {
            return ArkFileAdaptiveSplitColumnPlan(
                showsAllRegularColumns: true,
                preferredCompactColumn:
                    compactShowsSidebar ? .detail : .sidebar
            )
        }
        return ArkFileAdaptiveSplitColumnPlan(
            showsAllRegularColumns: regularShowsDetailOnly,
            preferredCompactColumn: .detail
        )
    }
}

enum ArkFileAdaptiveHistoryReaderTarget: Equatable, Sendable {
    /// The compact iPhone shell continues to treat NavigationViewModel as the
    /// authority for its one visible reader.
    case currentNavigationReader
    /// The iPad shell uses its typed scene route so a preserved background tab
    /// cannot receive commands while Home or an offline tool is visible.
    case adaptiveReader(ArkFileReaderTabIdentity)
}

enum ArkFileAdaptiveHistoryTargetPolicy {
    static func target(
        device: Device,
        route: ArkFileAdaptiveRoute,
        hasCurrentNavigationReader: Bool
    ) -> ArkFileAdaptiveHistoryReaderTarget? {
        if device == .iPhone {
            return hasCurrentNavigationReader
                ? .currentNavigationReader
                : nil
        }

        guard case .reader(let identity) = route else {
            return nil
        }
        return .adaptiveReader(identity)
    }
}

enum ArkFileAdaptiveReaderPresentationPolicy {
    static func hasPresentedReader(
        route: ArkFileAdaptiveRoute,
        observedReader: ArkFileReaderTabIdentity,
        hasPresentedContent: Bool
    ) -> Bool {
        guard hasPresentedContent,
              case .reader(let routedReader) = route else {
            return false
        }
        return routedReader == observedReader
    }
}

/// Pure reducer state kept separate from SwiftUI so resize and routing
/// transitions can be pinned with focused unit tests.
struct ArkFileAdaptiveNavigationSnapshot: Equatable, Sendable {
    private(set) var route: ArkFileAdaptiveRoute = .home
    private(set) var currentReader: ArkFileReaderTabIdentity?
    private(set) var expectsReader = false
    private(set) var readerActivationRevision: UInt = 0
    private(set) var routeSelectionRevision: UInt = 0
    private var expectedReader: ArkFileReaderTabIdentity?
    private var contentOpenRevision: UInt = 0
    /// The initial Home route is a launch placeholder while Core Data restores
    /// the persisted reader. Once a person explicitly selects any route,
    /// including Home, later reader observations must not override that choice.
    private var allowsInitialReaderRestoration = true

    mutating func apply(_ intent: ArkFileAdaptiveNavigationIntent) {
        switch intent {
        case .select(let route):
            select(route)
        case .expectReader:
            invalidateContentOpen()
            expectsReader = true
            expectedReader = nil
            readerActivationRevision &+= 1
            if let currentReader {
                route = .reader(currentReader)
            }
        case .activateReader(let identity):
            invalidateContentOpen()
            route = .reader(identity)
            currentReader = identity
            expectsReader = true
            expectedReader = identity
            readerActivationRevision &+= 1
            allowsInitialReaderRestoration = false
        case .presentStaticContent:
            invalidateContentOpen()
            expectsReader = false
            expectedReader = nil
            allowsInitialReaderRestoration = false
        }
    }

    mutating func select(_ route: ArkFileAdaptiveRoute) {
        invalidateContentOpen()
        routeSelectionRevision &+= 1
        self.route = route
        expectsReader = false
        expectedReader = nil
        allowsInitialReaderRestoration = false
        if case .reader(let identity) = route {
            currentReader = identity
        }
    }

    mutating func beginContentOpen() ->
        ArkFileAdaptiveSceneContentOpenIntent {
        contentOpenRevision &+= 1
        return ArkFileAdaptiveSceneContentOpenIntent(
            revision: contentOpenRevision
        )
    }

    func isCurrentContentOpen(
        _ intent: ArkFileAdaptiveSceneContentOpenIntent
    ) -> Bool {
        intent.revision == contentOpenRevision
    }

    private mutating func invalidateContentOpen() {
        contentOpenRevision &+= 1
    }

    mutating func observeReader(
        _ identity: ArkFileReaderTabIdentity,
        hasPresentedContent: Bool
    ) {
        if expectsReader {
            if let expectedReader, expectedReader != identity {
                return
            }
            currentReader = identity
            route = .reader(identity)
            if hasPresentedContent {
                expectsReader = false
                expectedReader = nil
            }
            return
        }

        currentReader = identity

        switch route {
        case .home where hasPresentedContent && allowsInitialReaderRestoration:
            route = .reader(identity)
            allowsInitialReaderRestoration = false
        case .reader:
            // An explicit reader selection owns the semantic route. Browser
            // restoration can briefly publish an empty page while SwiftUI
            // collapses or expands split columns; that transient observation
            // must not send the person back Home.
            if hasPresentedContent {
                route = .reader(identity)
            }
        default:
            break
        }
    }

    mutating func removeDeletedReaders(
        _ identities: Set<ArkFileReaderTabIdentity>
    ) {
        guard !identities.isEmpty else { return }

        if let currentReader, identities.contains(currentReader) {
            self.currentReader = nil
        }
        if let expectedReader, identities.contains(expectedReader) {
            self.expectedReader = nil
            expectsReader = false
        }

        guard case .reader(let routedReader) = route,
              identities.contains(routedReader) else {
            return
        }
        select(.home)
    }
}

/// Scene-owned semantic navigation state. RootViewiOS creates one instance per
/// SwiftUI scene; there is intentionally no process-global singleton.
@MainActor
final class ArkFileAdaptiveNavigationState: ObservableObject {
    @Published private(set) var snapshot = ArkFileAdaptiveNavigationSnapshot()

    var route: ArkFileAdaptiveRoute {
        snapshot.route
    }

    var currentReader: ArkFileReaderTabIdentity? {
        snapshot.currentReader
    }

    var readerActivationRevision: UInt {
        snapshot.readerActivationRevision
    }

    var routeSelectionRevision: UInt {
        snapshot.routeSelectionRevision
    }

    func handle(_ intent: ArkFileAdaptiveNavigationIntent) {
        snapshot.apply(intent)
    }

    func select(_ route: ArkFileAdaptiveRoute) {
        snapshot.select(route)
    }

    func expectReader() {
        snapshot.apply(.expectReader)
    }

    func activateReader(_ identity: ArkFileReaderTabIdentity) {
        snapshot.apply(.activateReader(identity))
    }

    func presentStaticContent() {
        snapshot.apply(.presentStaticContent)
    }

    func beginContentOpen() -> ArkFileAdaptiveSceneContentOpenIntent {
        snapshot.beginContentOpen()
    }

    func isCurrentContentOpen(
        _ intent: ArkFileAdaptiveSceneContentOpenIntent
    ) -> Bool {
        snapshot.isCurrentContentOpen(intent)
    }

    func observeReader(
        objectID: NSManagedObjectID,
        hasPresentedContent: Bool
    ) {
        snapshot.observeReader(
            ArkFileReaderTabIdentity(objectID: objectID),
            hasPresentedContent: hasPresentedContent
        )
    }

    func removeDeletedReaders(with objectIDs: [NSManagedObjectID]) {
        snapshot.removeDeletedReaders(
            Set(objectIDs.map(ArkFileReaderTabIdentity.init(objectID:)))
        )
    }
}

/// Compatibility bridge for existing destination senders. New adaptive
/// surfaces use typed routes directly, while compact handlers can continue
/// receiving the same notifications during the transition.
enum ArkFileAdaptiveNotificationRoutePolicy {
    static func rootHandles(
        _ name: Notification.Name,
        device: Device
    ) -> Bool {
        switch name {
        case .arkFileGoHome, .openURL:
            return true
        case .selectFile,
             .arkFileOpenContentDownloads,
             .arkFileOpenMapLocation,
             .arkFileImportMapGPX,
             .arkFileOpenGuideSection,
             .arkFileOpenToolkitView,
             .navigateToHotspotSettings,
             .arkFileOnboardingDestination:
            return device == .iPad
        case .arkFileOpenLibraryItem:
            // SplitViewForiPad resolves static versus ZIM content on iPad,
            // while CompactViewController owns the same event on iPhone.
            return false
        default:
            return false
        }
    }

    static func intent(
        for notification: Notification,
        device: Device
    ) -> ArkFileAdaptiveNavigationIntent? {
        guard rootHandles(notification.name, device: device) else {
            return nil
        }
        return intent(for: notification)
    }

    /// Embedded Home/Library views retain legacy listeners only for unusual
    /// non-phone/non-iPad hosts. CompactViewController owns these events on
    /// iPhone, and the typed scene root owns them on iPad.
    static func embeddedViewHandles(
        _ name: Notification.Name,
        device: Device
    ) -> Bool {
        switch name {
        case .arkFileOpenContentDownloads,
             .arkFileOpenMapLocation,
             .arkFileImportMapGPX:
            device != .iPhone && !rootHandles(name, device: device)
        default:
            false
        }
    }

    static func intent(for notification: Notification) -> ArkFileAdaptiveNavigationIntent? {
        switch notification.name {
        case .arkFileGoHome:
            return .select(.home)
        case .openURL:
            return .expectReader
        case .arkFileOpenLibraryItem:
            // The regular-width shell resolves the relative path before it
            // knows whether to push a static document or load a ZIM reader.
            // CompactViewController retains the same responsibility on iPhone.
            return nil
        case .selectFile:
            guard let fileID =
                notification.userInfo?["fileId"] as? UUID else {
                return nil
            }
            return .select(.importedFile(fileID: fileID))
        case .arkFileOpenContentDownloads:
            return .select(
                .downloads(
                    relativePath: notification.userInfo?["relativePath"] as? String
                )
            )
        case .arkFileOpenMapLocation, .arkFileImportMapGPX:
            return .select(.map)
        case .arkFileOpenGuideSection:
            return .select(
                .preparedness(
                    .survivalGuide(
                        sectionID: notification.userInfo?["sectionID"] as? String,
                        blockID: notification.userInfo?["blockID"] as? String
                    )
                )
            )
        case .arkFileOpenToolkitView:
            return .select(
                .preparedness(
                    .toolkit(
                        selectedView: notification.userInfo?["view"] as? String
                    )
                )
            )
        case .navigateToHotspotSettings:
            return .select(.settings(scrollToHotspot: true))
        case .arkFileOnboardingDestination:
            guard let destination = notification.object as? ArkFileOnboardingDestination else {
                return nil
            }
            switch destination {
            case .home:
                return .select(.home)
            case .includedSamples:
                return .select(.library)
            case .packs:
                return .select(.downloads(relativePath: nil))
            }
        default:
            return nil
        }
    }
}
#endif

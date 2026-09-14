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

import CoreGraphics
import Foundation
#if os(iOS)
import Network
#endif

/// A network interface Local Sharing is reachable on. Enumerating these
/// directly (instead of trusting whichever address the server reports first)
/// lets sharing work over the iPhone's own Personal Hotspot when there is no
/// Wi-Fi network at all.
struct ArkFileSharingEndpoint: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case wifi
        case personalHotspot
        case other
    }

    let interfaceName: String
    let ipAddress: String
    let kind: Kind

    var id: String { "\(interfaceName)-\(ipAddress)" }

    var displayLabel: String {
        switch kind {
        case .wifi:
            "On your Wi-Fi network"
        case .personalHotspot:
            "On your Personal Hotspot"
        case .other:
            "On this network"
        }
    }
}

/// One shareable link per reachable interface, with its QR code.
struct ArkFileSharingLink: Equatable, Identifiable {
    let endpoint: ArkFileSharingEndpoint
    let url: URL
    var qrCodeImage: CGImage?

    var id: String { endpoint.id }
}

/// The local-network authorization captured when the owner taps Start.
///
/// Interface names and RFC1918 addresses are not network identities: a second
/// Wi-Fi network can hand `en0` the same address as the first one. The path
/// generation closes that ambiguity. Stable endpoint refreshes keep the same
/// generation, while a Network.framework path replacement requires a fresh
/// confirmation even when the visible endpoint tuple repeats exactly.
struct ArkFileSharingNetworkBoundary: Equatable, Sendable {
    let approvedEndpoints: [ArkFileSharingEndpoint]
    let pathGeneration: UInt64

    func requiresFreshConfirmation(
        currentEndpoints: [ArkFileSharingEndpoint],
        currentPathGeneration: UInt64
    ) -> Bool {
        if ArkFileSharingEndpoints.isNetworkReplacement(
            approved: approvedEndpoints,
            current: currentEndpoints
        ) {
            return true
        }

        // Personal Hotspot is intentionally allowed to appear after the owner
        // confirms sharing. A hotspot-only session therefore does not inherit
        // the phone's unrelated default-route generation. Any session approved
        // on Wi-Fi/another LAN does: a path transition must be reconfirmed even
        // when DHCP reuses the same interface name and address.
        let hasApprovedNonHotspotPath = approvedEndpoints.contains {
            $0.kind != .personalHotspot
        }
        return hasApprovedNonHotspotPath && currentPathGeneration != pathGeneration
    }
}

#if os(iOS)
/// Monotonic identity for the effective local-network path during this app
/// process. `NWPathMonitor` delivers one initial snapshot; only later path
/// updates advance the generation. Timer-driven endpoint refreshes do not.
@MainActor
final class ArkFileSharingNetworkPathGenerationMonitor {
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(
        label: "app.arkfile.local-sharing.network-path"
    )
    private var generation: UInt64?
    private var initialSnapshotWaiters: [CheckedContinuation<UInt64, Never>] = []

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordPathUpdate()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Waits only for Network.framework's required initial snapshot. Once that
    /// arrives, reads are immediate and do not perform network work.
    func currentGeneration() async -> UInt64 {
        if let generation {
            return generation
        }
        return await withCheckedContinuation { continuation in
            initialSnapshotWaiters.append(continuation)
        }
    }

    private func recordPathUpdate() {
        guard let generation else {
            self.generation = 0
            let waiters = initialSnapshotWaiters
            initialSnapshotWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: 0)
            }
            return
        }
        self.generation = generation &+ 1
    }
}
#endif

enum ArkFileSharingEndpoints {
    /// Interfaces that can never carry a peer connection to this device.
    private static let excludedPrefixes = ["lo", "pdp_ip", "utun", "awdl", "llw", "ipsec", "anpi", "XHC"]

    static func current() -> [ArkFileSharingEndpoint] {
        var endpoints: [ArkFileSharingEndpoint] = []
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return []
        }
        defer { freeifaddrs(addressList) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(current.pointee.ifa_flags) & IFF_UP) != 0 else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let ipAddress = string(fromNullTerminatedCChars: host)
            guard !ipAddress.isEmpty, ipAddress != "0.0.0.0" else {
                continue
            }
            endpoints.append(ArkFileSharingEndpoint(
                interfaceName: name,
                ipAddress: ipAddress,
                kind: kind(forInterface: name)
            ))
        }

        // Wi-Fi first, then Personal Hotspot, then anything else; drop
        // duplicate addresses that appear on multiple interfaces.
        var seenAddresses = Set<String>()
        return endpoints
            .sorted { rank($0.kind) < rank($1.kind) }
            .filter { seenAddresses.insert($0.ipAddress).inserted }
    }

    static func kind(forInterface name: String) -> ArkFileSharingEndpoint.Kind {
        if name == "en0" {
            return .wifi
        }
        if name.hasPrefix("bridge") {
            return .personalHotspot
        }
        return .other
    }

    /// Picks the one interface a raw Kiwix server may bind for this session.
    /// Personal Hotspot wins when it is already active so an iPhone can be the
    /// network host during an outage; otherwise prefer Wi-Fi, then another
    /// explicitly enumerated LAN interface. The result is deterministic even
    /// when iOS exposes more than one bridge or LAN interface.
    static func preferredZimBinding(
        from endpoints: [ArkFileSharingEndpoint]
    ) -> ArkFileSharingEndpoint? {
        endpoints
            .filter(isUsableBindingEndpoint)
            .sorted { lhs, rhs in
                let lhsRank = zimBindingRank(lhs.kind)
                let rhsRank = zimBindingRank(rhs.kind)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                if lhs.interfaceName != rhs.interfaceName {
                    return lhs.interfaceName < rhs.interfaceName
                }
                return lhs.ipAddress < rhs.ipAddress
            }
            .first
    }

    /// Returns exactly the interfaces that may be advertised for a session.
    /// Portal-only sessions retain the existing approved-LAN plus dynamically
    /// enabled Personal Hotspot behavior. A ZIM session exposes only the one
    /// endpoint to which Kiwix was bound and never broadens after start.
    static func visibleEndpoints(
        approved: [ArkFileSharingEndpoint],
        current: [ArkFileSharingEndpoint],
        boundZimEndpoint: ArkFileSharingEndpoint?
    ) -> [ArkFileSharingEndpoint] {
        if let boundZimEndpoint {
            return current.filter {
                $0.id == boundZimEndpoint.id && isUsableBindingEndpoint($0)
            }
        }
        let approvedIDs = Set(approved.map(\.id))
        return current.filter { endpoint in
            endpoint.kind == .personalHotspot || approvedIDs.contains(endpoint.id)
        }
    }

    static func isBoundEndpointAvailable(
        _ endpoint: ArkFileSharingEndpoint,
        in current: [ArkFileSharingEndpoint]
    ) -> Bool {
        current.contains { $0.id == endpoint.id && isUsableBindingEndpoint($0) }
    }

    static func isUsableBindingEndpoint(_ endpoint: ArkFileSharingEndpoint) -> Bool {
        let address = endpoint.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              address != "0.0.0.0",
              !address.hasPrefix("127.") else {
            return false
        }
        var parsed = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &parsed) } == 1
    }

    /// Personal Hotspot may be enabled after the owner confirms sharing. Any
    /// newly observed Wi-Fi/other LAN identity would broaden the session to a
    /// different network and therefore requires a fresh confirmation.
    static func isNetworkReplacement(
        approved: [ArkFileSharingEndpoint],
        current: [ArkFileSharingEndpoint]
    ) -> Bool {
        let approvedLAN = Set(approved.filter { $0.kind != .personalHotspot }.map(\.id))
        let currentLAN = Set(current.filter { $0.kind != .personalHotspot }.map(\.id))
        guard !currentLAN.isEmpty else {
            // A transient path flap or Wi-Fi disappearance does not silently
            // authorize another network. Keep the original approval identity.
            return false
        }
        return !currentLAN.isSubset(of: approvedLAN)
    }

    /// Rebuilds an open sharing URL for a specific interface address while
    /// keeping the scheme, port, and portal route intact.
    static func url(_ base: URL, replacingHostWith host: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.host = host
        return components.url
    }

    private static func rank(_ kind: ArkFileSharingEndpoint.Kind) -> Int {
        switch kind {
        case .wifi: 0
        case .personalHotspot: 1
        case .other: 2
        }
    }

    private static func zimBindingRank(_ kind: ArkFileSharingEndpoint.Kind) -> Int {
        switch kind {
        case .personalHotspot: 0
        case .wifi: 1
        case .other: 2
        }
    }

    private static func string(fromNullTerminatedCChars chars: [CChar]) -> String {
        let bytes = chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

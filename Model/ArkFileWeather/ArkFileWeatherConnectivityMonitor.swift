// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Combine
import Foundation
import Network

/// Connectivity is only a refresh hint. A satisfied path never proves that an
/// official provider is reachable, so request failures remain authoritative.
@MainActor
final class ArkFileWeatherConnectivityMonitor: ObservableObject {
    @Published private(set) var connectivity: ArkFileWeatherConnectivity = .unknown
    @Published private(set) var usesExpensiveNetwork = false

    var onReconnect: (() -> Void)?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "app.arkfile.saved-weather.path")
    private var isStarted = false

    deinit {
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let newConnectivity: ArkFileWeatherConnectivity =
                path.status == .satisfied ? .online : .offline
            let isExpensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.apply(
                    connectivity: newConnectivity,
                    usesExpensiveNetwork: isExpensive
                )
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        connectivity = .unknown
        usesExpensiveNetwork = false
    }

    private func apply(
        connectivity newConnectivity: ArkFileWeatherConnectivity,
        usesExpensiveNetwork: Bool
    ) {
        let wasOffline = connectivity == .offline
        connectivity = newConnectivity
        self.usesExpensiveNetwork = usesExpensiveNetwork
        if wasOffline && newConnectivity == .online {
            onReconnect?()
        }
    }
}
#endif

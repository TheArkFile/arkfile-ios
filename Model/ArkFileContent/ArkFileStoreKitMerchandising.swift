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

import Combine
import Foundation
import StoreKit

/// Sendable StoreKit merchandising values copied from `Product`. Currency
/// formatting remains Apple's responsibility through `displayPrice`.
struct ArkFileStoreKitProductMetadata: Equatable, Sendable {
    let productID: String
    let displayName: String
    let displayPrice: String
    let isNonConsumable: Bool
}

protocol ArkFileStoreKitProductMetadataLoading: Sendable {
    func loadProductMetadata(
        productIDs: Set<String>
    ) async throws -> [ArkFileStoreKitProductMetadata]
}

struct ArkFileSystemStoreKitProductMetadataLoader: ArkFileStoreKitProductMetadataLoading {
    func loadProductMetadata(
        productIDs: Set<String>
    ) async throws -> [ArkFileStoreKitProductMetadata] {
        let products = try await Product.products(for: productIDs)
        return products.map { product in
            ArkFileStoreKitProductMetadata(
                productID: product.id,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                isNonConsumable: product.type == .nonConsumable
            )
        }
    }
}

struct ArkFileStoreKitMerchandisingSnapshot: Equatable, Sendable {
    let offersByRole: [ArkFileStoreKitProductRole: ArkFileStoreKitProductMetadata]

    func offer(
        for role: ArkFileStoreKitProductRole
    ) -> ArkFileStoreKitProductMetadata? {
        offersByRole[role]
    }

    /// Uses the same pure role decision as the purchase path so an Essentials
    /// owner is never shown the outright Complete product as their upgrade
    /// offer, or vice versa.
    func completeOffer(
        hasCurrentEssentialsProof: Bool
    ) -> ArkFileStoreKitProductMetadata? {
        offer(for: ArkFileStoreKitCompleteProductRoleResolver.resolve(
            hasEssentialsProof: hasCurrentEssentialsProof
        ))
    }
}

enum ArkFileStoreKitMerchandisingState: Equatable, Sendable {
    case idle
    case loading(previous: ArkFileStoreKitMerchandisingSnapshot?)
    case loaded(ArkFileStoreKitMerchandisingSnapshot)
    case partial(
        ArkFileStoreKitMerchandisingSnapshot,
        unavailableRoles: Set<ArkFileStoreKitProductRole>
    )
    case failed(previous: ArkFileStoreKitMerchandisingSnapshot?)

    var snapshot: ArkFileStoreKitMerchandisingSnapshot? {
        switch self {
        case .idle:
            nil
        case .loading(let previous), .failed(let previous):
            previous
        case .loaded(let snapshot), .partial(let snapshot, _):
            snapshot
        }
    }
}

/// Loads product metadata only when a comparison surface explicitly invokes
/// `loadIfNeeded()`. Construction does not contact StoreKit, and failed or
/// partial loads retry only through the explicit `retry()` action.
@MainActor
final class ArkFileStoreKitMerchandisingStore: ObservableObject {
    static let shared = ArkFileStoreKitMerchandisingStore()

    @Published private(set) var state: ArkFileStoreKitMerchandisingState = .idle

    private let loader: any ArkFileStoreKitProductMetadataLoading
    private let productConfiguration: ArkFileStoreKitProductConfiguration
    private var loadTask: Task<[ArkFileStoreKitProductMetadata], Error>?

    init(
        loader: any ArkFileStoreKitProductMetadataLoading = ArkFileSystemStoreKitProductMetadataLoader(),
        productConfiguration: ArkFileStoreKitProductConfiguration = .current
    ) {
        self.loader = loader
        self.productConfiguration = productConfiguration
    }

    func loadIfNeeded() async {
        switch state {
        case .idle:
            await load(force: false)
        case .loading:
            if let loadTask {
                _ = await loadTask.result
            }
        case .loaded, .partial, .failed:
            return
        }
    }

    func retry() async {
        await load(force: true)
    }

    private func load(force: Bool) async {
        if let loadTask {
            _ = await loadTask.result
            return
        }
        if !force {
            guard case .idle = state else { return }
        }

        let previous = state.snapshot
        let productIDs = productConfiguration.productIDs
        guard !productIDs.isEmpty else {
            state = .failed(previous: previous)
            return
        }

        state = .loading(previous: previous)
        let loader = loader
        let task = Task {
            try await loader.loadProductMetadata(productIDs: productIDs)
        }
        loadTask = task
        let result = await task.result
        loadTask = nil

        switch result {
        case .success(let metadata):
            state = Self.resolveState(
                metadata: metadata,
                configuration: productConfiguration,
                previous: previous
            )
        case .failure:
            state = .failed(previous: previous)
        }
    }

    private static func resolveState(
        metadata: [ArkFileStoreKitProductMetadata],
        configuration: ArkFileStoreKitProductConfiguration,
        previous: ArkFileStoreKitMerchandisingSnapshot?
    ) -> ArkFileStoreKitMerchandisingState {
        let expectedRoles: [ArkFileStoreKitProductRole] = [
            .lite,
            .complete,
            .completeUpgrade
        ]
        var offersByRole: [ArkFileStoreKitProductRole: ArkFileStoreKitProductMetadata] = [:]
        for product in metadata {
            guard let role = configuration.role(for: product.productID),
                  product.isNonConsumable,
                  !product.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            offersByRole[role] = product
        }

        let snapshot = ArkFileStoreKitMerchandisingSnapshot(offersByRole: offersByRole)
        let unavailableRoles = Set(expectedRoles.filter { role in
            let productID = configuration.productID(for: role)
            return productID.isEmpty || offersByRole[role] == nil
        })
        if offersByRole.isEmpty {
            return .failed(previous: previous)
        }
        if unavailableRoles.isEmpty {
            return .loaded(snapshot)
        }
        return .partial(snapshot, unavailableRoles: unavailableRoles)
    }
}

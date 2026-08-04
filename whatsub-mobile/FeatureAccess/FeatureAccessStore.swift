import Foundation
import Combine

@MainActor
final class FeatureAccessStore: ObservableObject {
    @Published private(set) var snapshot: FeatureAccessSnapshot?
    @Published private(set) var entitlementUnavailable = true

    private struct AccountContext: Equatable {
        let key: String
        let generation: UInt64
    }

    private let api: any FeatureAccessAPI
    private let persistence: FeatureAccessPersistence
    private var activeAccount: String?
    private var accountGeneration: UInt64 = 0
    /// True only after this account was checked by the server during the
    /// current in-memory activation. A disk cache may label an entry, but a
    /// stale cached `consumed` value must not itself open a paywall when the
    /// entitlement endpoint is offline (the account may have become Pro).
    private var snapshotIsFresh = false

    init(
        api: any FeatureAccessAPI = WhatsubAPI.shared,
        persistence: FeatureAccessPersistence = .shared
    ) {
        self.api = api
        self.persistence = persistence
    }

    func presentation(
        for feature: FeatureKey,
        localPro: Bool
    ) -> FeatureEntryPresentation {
        if localPro || snapshot?.isPro == true { return .normal }
        guard let snapshot, !entitlementUnavailable else { return .temporarilyUnavailable }
        switch snapshot.features[feature] {
        case .available: return .freeTrial
        case .inProgress: return .continueTrial
        case .consumed: return .subscriptionRequired
        case nil: return .temporarilyUnavailable
        }
    }

    /// Cache-first, then server refresh. Late responses are discarded if the
    /// signed-in account changed while the request was in flight.
    func refresh(token: String, email: String, localPro: Bool) async {
        let context = activate(email: email)
        do {
            let response = try await api.featureEntitlements(token: token)
            guard isCurrent(context) else { return }
            var features = response.features
            for pending in persistence.pendingConsumes(email: email) {
                features[pending] = .consumed
            }
            snapshot = FeatureAccessSnapshot(
                isPro: response.isPro || localPro,
                features: features,
                updatedAt: Date().timeIntervalSince1970
            )
            snapshotIsFresh = true
            entitlementUnavailable = false
            persistSnapshotBestEffort(email: email)
        } catch {
            guard isCurrent(context) else { return }
            snapshotIsFresh = false
            entitlementUnavailable = snapshot == nil
        }
    }

    func start(
        feature: FeatureKey,
        token: String,
        email: String,
        localPro: Bool
    ) async throws -> FeatureAccessGrant {
        let context = activate(email: email)
        if localPro || snapshot?.isPro == true {
            return FeatureAccessGrant(feature: feature, access: .pro, email: email)
        }
        // A local pending marker was synchronously persisted before showing a
        // valuable result. It is authoritative even while offline.
        if persistence.pendingConsumes(email: email).contains(feature) {
            throw FeatureAccessError.subscriptionRequired
        }
        // Only a server-verified state from this account activation may avoid
        // another request. A stale disk cache must revalidate first.
        if snapshotIsFresh, snapshot?.features[feature] == .consumed {
            throw FeatureAccessError.subscriptionRequired
        }

        do {
            let response = try await api.startFeature(feature, token: token)
            guard isCurrent(context), response.featureKey == feature else {
                throw FeatureAccessError.temporarilyUnavailable
            }
            var current = snapshot ?? FeatureAccessSnapshot(
                isPro: false,
                features: [:],
                updatedAt: 0
            )
            current.isPro = response.access == .pro
            current.features[feature] = response.state
            current.updatedAt = Date().timeIntervalSince1970
            snapshot = current
            snapshotIsFresh = true
            entitlementUnavailable = false
            persistSnapshotBestEffort(email: email)
            return FeatureAccessGrant(feature: feature, access: response.access, email: email)
        } catch FeatureAccessError.temporarilyUnavailable {
            throw FeatureAccessError.temporarilyUnavailable
        } catch APIError.server(let status, let code)
                    where status == 403 && code == "feature_subscription_required" {
            guard isCurrent(context) else { throw FeatureAccessError.temporarilyUnavailable }
            markConsumedInMemory(feature, email: email)
            snapshotIsFresh = true
            entitlementUnavailable = false
            throw FeatureAccessError.subscriptionRequired
        } catch APIError.unauthorized {
            throw FeatureAccessError.unauthorized
        } catch {
            guard isCurrent(context) else { throw FeatureAccessError.temporarilyUnavailable }
            snapshotIsFresh = false
            entitlementUnavailable = true
            throw FeatureAccessError.temporarilyUnavailable
        }
    }

    /// Called at the feature-specific success boundary before publishing the
    /// first valuable result. Returning false means the crash-retry marker
    /// could not be persisted (or the grant belongs to a previous account),
    /// so the caller must fail closed and not display the result.
    @discardableResult
    func recordSuccessfulResult(
        feature: FeatureKey,
        grant: FeatureAccessGrant,
        token: String,
        email: String
    ) -> Bool {
        guard grant.matches(feature, email: email),
              activeAccount == Self.accountKey(email) else { return false }
        guard grant.access == .trial else { return true }
        do {
            try persistence.addPendingConsume(feature, email: email)
        } catch {
            return false
        }
        // The pending marker is already durable. Snapshot persistence is a
        // cache optimization and may fail without reopening the duplicate-use
        // window because start() checks the marker first.
        markConsumedInMemory(feature, email: email)
        Task { [weak self] in
            await self?.consumePending(feature, token: token, email: email)
        }
        return true
    }

    func retryPendingConsumes(token: String, email: String) async {
        let key = Self.accountKey(email)
        if activeAccount == nil { _ = activate(email: email) }
        guard activeAccount == key else { return }
        let pending = persistence.pendingConsumes(email: email)
        for feature in FeatureKey.allCases where pending.contains(feature) {
            await consumePending(feature, token: token, email: email)
        }
    }

    func sendEvent(
        _ event: FeatureFunnelEvent,
        feature: FeatureKey,
        token: String
    ) {
        Task { [api] in
            try? await api.sendFeatureEvent(event, feature: feature, token: token)
        }
    }

    func removeAccount(email: String) throws {
        try persistence.removeAccount(email: email)
        if activeAccount == Self.accountKey(email) { resetMemory() }
    }

    func resetMemory() {
        activeAccount = nil
        accountGeneration &+= 1
        snapshot = nil
        snapshotIsFresh = false
        entitlementUnavailable = true
    }

    private func consumePending(_ feature: FeatureKey, token: String, email: String) async {
        do {
            try await api.consumeFeature(feature, token: token)
            try persistence.removePendingConsume(feature, email: email)
            if activeAccount == Self.accountKey(email) {
                markConsumedInMemory(feature, email: email)
            }
        } catch {
            // Keep the marker. Login/foreground/purchase refresh retries it.
        }
    }

    private func markConsumedInMemory(_ feature: FeatureKey, email: String) {
        guard activeAccount == Self.accountKey(email) else { return }
        var current = snapshot ?? persistence.snapshot(for: email) ?? FeatureAccessSnapshot(
            isPro: false,
            features: [:],
            updatedAt: 0
        )
        current.features[feature] = .consumed
        current.updatedAt = Date().timeIntervalSince1970
        snapshot = current
        persistSnapshotBestEffort(email: email)
    }

    @discardableResult
    private func activate(email: String) -> AccountContext {
        let key = Self.accountKey(email)
        if activeAccount != key {
            activeAccount = key
            accountGeneration &+= 1
            snapshot = persistence.snapshot(for: email)
            snapshotIsFresh = false
            entitlementUnavailable = snapshot == nil
        }
        return AccountContext(key: key, generation: accountGeneration)
    }

    private func isCurrent(_ context: AccountContext) -> Bool {
        activeAccount == context.key && accountGeneration == context.generation
    }

    private func persistSnapshotBestEffort(email: String) {
        guard activeAccount == Self.accountKey(email), let snapshot else { return }
        try? persistence.store(snapshot: snapshot, for: email)
    }

    private static func accountKey(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

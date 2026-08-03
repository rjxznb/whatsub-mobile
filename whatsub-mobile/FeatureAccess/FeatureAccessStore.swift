import Foundation
import Combine

@MainActor
final class FeatureAccessStore: ObservableObject {
    @Published private(set) var snapshot: FeatureAccessSnapshot?
    @Published private(set) var entitlementUnavailable = true

    private let api: any FeatureAccessAPI
    private let persistence: FeatureAccessPersistence
    private var activeAccount: String?

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

    /// Cache-first, then server refresh. A network failure preserves a known
    /// cached snapshot; it never silently turns a free account into Pro.
    func refresh(token: String, email: String, localPro: Bool) async {
        activate(email: email)
        do {
            let response = try await api.featureEntitlements(token: token)
            var features = response.features
            // A consume marker is written before displaying the result. Until
            // its retry reaches the server, the local entry must still look
            // consumed so closing/re-entering cannot start another free flow.
            for pending in persistence.pendingConsumes(email: email) {
                features[pending] = .consumed
            }
            snapshot = FeatureAccessSnapshot(
                isPro: response.isPro || localPro,
                features: features,
                updatedAt: Date().timeIntervalSince1970
            )
            entitlementUnavailable = false
            persistSnapshot(email: email)
        } catch {
            // Cached server-Pro is intentionally allowed offline. For a free
            // cached snapshot, known entry labels remain useful, but start()
            // still requires a successful server call.
            entitlementUnavailable = snapshot == nil
        }
    }

    func start(
        feature: FeatureKey,
        token: String,
        email: String,
        localPro: Bool
    ) async throws -> FeatureAccessGrant {
        activate(email: email)
        if localPro || snapshot?.isPro == true {
            return FeatureAccessGrant(feature: feature, access: .pro)
        }

        do {
            let response = try await api.startFeature(feature, token: token)
            guard response.featureKey == feature else {
                entitlementUnavailable = true
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
            entitlementUnavailable = false
            persistSnapshot(email: email)
            return FeatureAccessGrant(feature: feature, access: response.access)
        } catch FeatureAccessError.temporarilyUnavailable {
            throw FeatureAccessError.temporarilyUnavailable
        } catch APIError.server(let status, let code)
                    where status == 403 && code == "feature_subscription_required" {
            markConsumed(feature, email: email)
            entitlementUnavailable = false
            throw FeatureAccessError.subscriptionRequired
        } catch APIError.unauthorized {
            throw FeatureAccessError.unauthorized
        } catch {
            entitlementUnavailable = true
            throw FeatureAccessError.temporarilyUnavailable
        }
    }

    /// Called at the feature-specific success boundary, before publishing the
    /// first valuable result. The disk marker is synchronous; network consume
    /// is idempotent and retried later if this best-effort task fails.
    func recordSuccessfulResult(
        feature: FeatureKey,
        grant: FeatureAccessGrant,
        token: String,
        email: String
    ) {
        guard grant.feature == feature, grant.access == .trial else { return }
        activate(email: email)
        persistence.addPendingConsume(feature, email: email)
        markConsumed(feature, email: email)
        Task { [weak self] in
            await self?.consumePending(feature, token: token, email: email)
        }
    }

    func retryPendingConsumes(token: String, email: String) async {
        activate(email: email)
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

    func resetMemory() {
        activeAccount = nil
        snapshot = nil
        entitlementUnavailable = true
    }

    private func consumePending(_ feature: FeatureKey, token: String, email: String) async {
        do {
            try await api.consumeFeature(feature, token: token)
            persistence.removePendingConsume(feature, email: email)
            if activeAccount == Self.accountKey(email) {
                markConsumed(feature, email: email)
            }
        } catch {
            // Keep the marker. Login/foreground/purchase refresh retries it.
        }
    }

    private func markConsumed(_ feature: FeatureKey, email: String) {
        var current = snapshot ?? persistence.snapshot(for: email) ?? FeatureAccessSnapshot(
            isPro: false,
            features: [:],
            updatedAt: 0
        )
        current.features[feature] = .consumed
        current.updatedAt = Date().timeIntervalSince1970
        snapshot = current
        persistSnapshot(email: email)
    }

    private func activate(email: String) {
        let key = Self.accountKey(email)
        guard activeAccount != key else { return }
        activeAccount = key
        snapshot = persistence.snapshot(for: email)
        entitlementUnavailable = snapshot == nil
    }

    private func persistSnapshot(email: String) {
        guard activeAccount == Self.accountKey(email), let snapshot else { return }
        persistence.store(snapshot: snapshot, for: email)
    }

    private static func accountKey(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

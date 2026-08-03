import Foundation

enum FeatureKey: String, Codable, CaseIterable, Hashable {
    case quickChat = "quick_chat"
    case videoRoleplay = "video_roleplay"
    case liveScene = "live_scene"
    case photoAI = "photo_ai"
}

enum FeatureTrialState: String, Codable, Equatable {
    case available
    case inProgress = "in_progress"
    case consumed
}

enum FeatureAccessKind: String, Codable, Equatable {
    case pro
    case trial
}

struct FeatureAccessGrant: Equatable {
    let feature: FeatureKey
    let access: FeatureAccessKind

    func matches(_ expectedFeature: FeatureKey) -> Bool {
        feature == expectedFeature
    }
}

enum FeatureEntryPresentation: Equatable {
    case normal
    case freeTrial
    case continueTrial
    case subscriptionRequired
    case temporarilyUnavailable
}

enum FeatureAccessError: Error, Equatable, LocalizedError {
    case subscriptionRequired
    case temporarilyUnavailable
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .subscriptionRequired:
            return "这项功能的免费体验已经用过了，订阅 Pro 后可以继续使用。"
        case .temporarilyUnavailable:
            return "暂时无法确认免费体验，请检查网络后重试。"
        case .unauthorized:
            return "登录信息已过期，请重新登录。"
        }
    }
}

enum FeatureFunnelEvent: String, Encodable {
    case paywallShown = "paywall_shown"
    case purchaseSuccess = "purchase_success"
}

struct FeatureAccessSnapshot: Codable, Equatable {
    var isPro: Bool
    var features: [FeatureKey: FeatureTrialState]
    var updatedAt: TimeInterval

    init(
        isPro: Bool,
        features: [FeatureKey: FeatureTrialState],
        updatedAt: TimeInterval
    ) {
        self.isPro = isPro
        self.features = features
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case isPro, features, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPro = try container.decode(Bool.self, forKey: .isPro)
        updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
        let wire = try container.decode([String: FeatureTrialState].self, forKey: .features)
        features = Dictionary(uniqueKeysWithValues: wire.compactMap { key, value in
            FeatureKey(rawValue: key).map { ($0, value) }
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPro, forKey: .isPro)
        try container.encode(updatedAt, forKey: .updatedAt)
        let wire = Dictionary(uniqueKeysWithValues: features.map { ($0.key.rawValue, $0.value) })
        try container.encode(wire, forKey: .features)
    }
}

protocol FeatureAccessAPI {
    func featureEntitlements(token: String) async throws -> FeatureEntitlementsResponse
    func startFeature(_ feature: FeatureKey, token: String) async throws -> FeatureStartResponse
    func consumeFeature(_ feature: FeatureKey, token: String) async throws
    func sendFeatureEvent(
        _ event: FeatureFunnelEvent,
        feature: FeatureKey,
        token: String
    ) async throws
}

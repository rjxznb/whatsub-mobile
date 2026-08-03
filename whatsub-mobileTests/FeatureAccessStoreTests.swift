import XCTest
@testable import whatsub_mobile

private actor FeatureAccessAPISpy: FeatureAccessAPI {
    enum EntitlementsMode {
        case response(FeatureEntitlementsResponse)
        case networkFailure
    }
    enum StartMode {
        case response(FeatureStartResponse)
        case subscriptionRequired
        case networkFailure
    }
    enum ConsumeMode { case success, networkFailure }

    private var entitlementsMode: EntitlementsMode
    private var startMode: StartMode
    private var consumeMode: ConsumeMode
    private var startCalls: [FeatureKey] = []
    private var consumeCalls: [FeatureKey] = []

    init(
        entitlements: EntitlementsMode = .networkFailure,
        start: StartMode = .networkFailure,
        consume: ConsumeMode = .success
    ) {
        entitlementsMode = entitlements
        startMode = start
        consumeMode = consume
    }

    func featureEntitlements(token: String) async throws -> FeatureEntitlementsResponse {
        switch entitlementsMode {
        case .response(let response): return response
        case .networkFailure: throw APIError.network("offline")
        }
    }

    func startFeature(_ feature: FeatureKey, token: String) async throws -> FeatureStartResponse {
        startCalls.append(feature)
        switch startMode {
        case .response(let response): return response
        case .subscriptionRequired:
            throw APIError.server(403, "feature_subscription_required")
        case .networkFailure: throw APIError.network("offline")
        }
    }

    func consumeFeature(_ feature: FeatureKey, token: String) async throws {
        consumeCalls.append(feature)
        if case .networkFailure = consumeMode { throw APIError.network("offline") }
    }

    func sendFeatureEvent(
        _ event: FeatureFunnelEvent,
        feature: FeatureKey,
        token: String
    ) async throws {}

    func setConsumeMode(_ mode: ConsumeMode) { consumeMode = mode }
    func startCallCount() -> Int { startCalls.count }
    func consumeCallCount() -> Int { consumeCalls.count }
}

@MainActor
final class FeatureAccessStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("feature_access_\(UUID().uuidString).json")
    }

    private func allStates(_ state: FeatureTrialState) -> [FeatureKey: FeatureTrialState] {
        Dictionary(uniqueKeysWithValues: FeatureKey.allCases.map { ($0, state) })
    }

    func testPresentationMapsEveryServerStateAndUnknownIsNotPro() async {
        let api = FeatureAccessAPISpy(entitlements: .response(.init(
            isPro: false,
            features: [
                .quickChat: .available,
                .videoRoleplay: .inProgress,
                .liveScene: .consumed,
                .photoAI: .available,
            ]
        )))
        let store = FeatureAccessStore(api: api, persistence: .init(fileURL: tempURL()))
        XCTAssertEqual(store.presentation(for: .quickChat, localPro: false), .temporarilyUnavailable)

        await store.refresh(token: "session", email: "free@x.com", localPro: false)
        XCTAssertEqual(store.presentation(for: .quickChat, localPro: false), .freeTrial)
        XCTAssertEqual(store.presentation(for: .videoRoleplay, localPro: false), .continueTrial)
        XCTAssertEqual(store.presentation(for: .liveScene, localPro: false), .subscriptionRequired)
        XCTAssertEqual(store.presentation(for: .photoAI, localPro: false), .freeTrial)
    }

    func testLocalProGetsImmediateGrantWithoutStartRequest() async throws {
        let api = FeatureAccessAPISpy()
        let store = FeatureAccessStore(api: api, persistence: .init(fileURL: tempURL()))
        let grant = try await store.start(
            feature: .quickChat,
            token: "session",
            email: "pro@x.com",
            localPro: true
        )
        XCTAssertEqual(grant, .init(feature: .quickChat, access: .pro))
        let startCount = await api.startCallCount()
        XCTAssertEqual(startCount, 0)
    }

    func testCachedServerProCanStartOffline() async throws {
        let persistence = FeatureAccessPersistence(fileURL: tempURL())
        persistence.store(
            snapshot: .init(isPro: true, features: allStates(.available), updatedAt: 1),
            for: "cached@x.com"
        )
        let api = FeatureAccessAPISpy(entitlements: .networkFailure, start: .networkFailure)
        let store = FeatureAccessStore(api: api, persistence: persistence)
        await store.refresh(token: "session", email: "CACHED@x.com", localPro: false)

        let grant = try await store.start(
            feature: .photoAI,
            token: "session",
            email: "cached@x.com",
            localPro: false
        )
        XCTAssertEqual(grant.access, .pro)
        let startCount = await api.startCallCount()
        XCTAssertEqual(startCount, 0)
    }

    func testFreeStartRequiresServerSuccess() async throws {
        let api = FeatureAccessAPISpy(start: .response(.init(
            featureKey: .liveScene,
            access: .trial,
            state: .inProgress
        )))
        let store = FeatureAccessStore(api: api, persistence: .init(fileURL: tempURL()))
        let grant = try await store.start(
            feature: .liveScene,
            token: "session",
            email: "free@x.com",
            localPro: false
        )
        XCTAssertEqual(grant, .init(feature: .liveScene, access: .trial))
        XCTAssertEqual(store.presentation(for: .liveScene, localPro: false), .continueTrial)
        let startCount = await api.startCallCount()
        XCTAssertEqual(startCount, 1)
    }

    func testOnlyExactSubscription403BecomesSubscriptionDecision() async {
        let api = FeatureAccessAPISpy(start: .subscriptionRequired)
        let store = FeatureAccessStore(api: api, persistence: .init(fileURL: tempURL()))
        do {
            _ = try await store.start(
                feature: .quickChat,
                token: "session",
                email: "free@x.com",
                localPro: false
            )
            XCTFail("expected subscriptionRequired")
        } catch {
            XCTAssertEqual(error as? FeatureAccessError, .subscriptionRequired)
        }
        XCTAssertEqual(store.presentation(for: .quickChat, localPro: false), .subscriptionRequired)
    }

    func testNetworkFailureBecomesRetryStateNotPaywall() async {
        let api = FeatureAccessAPISpy(start: .networkFailure)
        let store = FeatureAccessStore(api: api, persistence: .init(fileURL: tempURL()))
        do {
            _ = try await store.start(
                feature: .videoRoleplay,
                token: "session",
                email: "free@x.com",
                localPro: false
            )
            XCTFail("expected temporarilyUnavailable")
        } catch {
            XCTAssertEqual(error as? FeatureAccessError, .temporarilyUnavailable)
        }
        XCTAssertEqual(
            store.presentation(for: .videoRoleplay, localPro: false),
            .temporarilyUnavailable
        )
    }

    func testSuccessfulTrialResultPersistsPendingConsumeBeforeAsyncRequest() async throws {
        let url = tempURL()
        let persistence = FeatureAccessPersistence(fileURL: url)
        let api = FeatureAccessAPISpy(
            start: .response(.init(
                featureKey: .quickChat,
                access: .trial,
                state: .inProgress
            )),
            consume: .networkFailure
        )
        let store = FeatureAccessStore(api: api, persistence: persistence)
        let grant = try await store.start(
            feature: .quickChat,
            token: "session",
            email: "free@x.com",
            localPro: false
        )

        store.recordSuccessfulResult(
            feature: .quickChat,
            grant: grant,
            token: "session",
            email: "free@x.com"
        )

        XCTAssertEqual(persistence.pendingConsumes(email: "free@x.com"), Set([.quickChat]))
        XCTAssertEqual(
            FeatureAccessPersistence(fileURL: url).pendingConsumes(email: "FREE@x.com"),
            Set([.quickChat])
        )
        XCTAssertEqual(store.presentation(for: .quickChat, localPro: false), .subscriptionRequired)
    }

    func testRetryPendingConsumeRemovesMarkerAfterSuccess() async {
        let persistence = FeatureAccessPersistence(fileURL: tempURL())
        persistence.addPendingConsume(.photoAI, email: "free@x.com")
        let api = FeatureAccessAPISpy(consume: .success)
        let store = FeatureAccessStore(api: api, persistence: persistence)

        await store.retryPendingConsumes(token: "session", email: "free@x.com")

        XCTAssertTrue(persistence.pendingConsumes(email: "free@x.com").isEmpty)
        let consumeCount = await api.consumeCallCount()
        XCTAssertEqual(consumeCount, 1)
    }

    func testPersistenceIsolatesAccounts() {
        let persistence = FeatureAccessPersistence(fileURL: tempURL())
        persistence.store(
            snapshot: .init(isPro: false, features: [.quickChat: .consumed], updatedAt: 1),
            for: "alice@x.com"
        )
        persistence.addPendingConsume(.quickChat, email: "alice@x.com")

        XCTAssertNil(persistence.snapshot(for: "mallory@x.com"))
        XCTAssertTrue(persistence.pendingConsumes(email: "mallory@x.com").isEmpty)
        XCTAssertEqual(persistence.snapshot(for: "ALICE@x.com")?.features[.quickChat], .consumed)
    }
}

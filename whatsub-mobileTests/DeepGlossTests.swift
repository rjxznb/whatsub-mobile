import XCTest
@testable import whatsub_mobile

final class DeepGlossPromptTests: XCTestCase {
    func testPromptCentersAtMostNineCompleteCuesAndOmitsTheRestOfTheTranscript() throws {
        let cues = (0..<30).map { makeDeepGlossCue(index: $0, text: "cue-\($0)-complete") }
        let payload = DeepGlossPrompt.build(context: makeDeepGlossContext(cues: cues, currentCueIndex: 15))

        XCTAssertEqual(payload.includedCueIndexes, Array(11...19))
        let joined = payload.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(joined.contains("cue-0-complete"))
        XCTAssertFalse(joined.contains("cue-10-complete"))
        XCTAssertFalse(joined.contains("cue-20-complete"))

        let userObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.messages.last!.content.utf8))
                as? [String: Any]
        )
        let sentCues = try XCTUnwrap(userObject["cues"] as? [[String: Any]])
        XCTAssertEqual(sentCues.count, 9)
        XCTAssertEqual(sentCues.compactMap { $0["text"] as? String }, (11...19).map { "cue-\($0)-complete" })
        XCTAssertNil(userObject["transcript"])
        XCTAssertNil(userObject["transcriptSrt"])
        XCTAssertNil(userObject["score"])
    }

    func testPromptIncludesAtMostFourFollowingCuesNearBeginning() {
        let cues = (0..<30).map { makeDeepGlossCue(index: $0) }

        let payload = DeepGlossPrompt.build(context: makeDeepGlossContext(cues: cues, currentCueIndex: 1))

        XCTAssertEqual(payload.includedCueIndexes, Array(0...5))
    }

    func testPromptIncludesAtMostFourPrecedingCuesNearEnd() {
        let cues = (0..<30).map { makeDeepGlossCue(index: $0) }

        let payload = DeepGlossPrompt.build(context: makeDeepGlossContext(cues: cues, currentCueIndex: 28))

        XCTAssertEqual(payload.includedCueIndexes, Array(24...29))
    }

    func testPromptUsesEveryCueWhenFewerThanNineExist() {
        let cues = (0..<5).map { makeDeepGlossCue(index: $0) }

        let payload = DeepGlossPrompt.build(context: makeDeepGlossContext(cues: cues, currentCueIndex: 2))

        XCTAssertEqual(payload.includedCueIndexes, Array(0...4))
    }
}

final class DeepGlossParserTests: XCTestCase {
    func testParserAcceptsEmptyOptionalSectionsAndPresentationOmitsThem() throws {
        let result = try DeepGlossParser.parse(validDeepGlossJSON())

        XCTAssertEqual(result.contextualMeaning, "在这里表示理解并认可对方刚才的观点。")
        XCTAssertEqual(result.slangOrIdiom, "")
        XCTAssertEqual(result.culturalContext, "")
        XCTAssertEqual(result.usageWarning, "")
        XCTAssertEqual(
            DeepGlossPresentation.visibleSections(for: result).map(\.kind),
            [.contextualMeaning, .toneAndSubtext, .naturalAlternatives]
        )
    }

    func testParserRejectsMissingExactKey() throws {
        var object = try validDeepGlossObject()
        object.removeValue(forKey: "usageWarning")

        XCTAssertThrowsError(try DeepGlossParser.parse(jsonString(object)))
    }

    func testParserRejectsExtraKeyIncludingNumericScore() throws {
        var object = try validDeepGlossObject()
        object["score"] = 9

        XCTAssertThrowsError(try DeepGlossParser.parse(jsonString(object)))
    }

    func testParserRejectsAFieldOverFiveHundredCharacters() throws {
        var object = try validDeepGlossObject()
        object["toneAndSubtext"] = String(repeating: "a", count: 501)

        XCTAssertThrowsError(try DeepGlossParser.parse(jsonString(object)))
    }

    func testParserRejectsMoreThanFiveNaturalAlternatives() throws {
        var object = try validDeepGlossObject()
        object["naturalAlternatives"] = (0..<6).map { "alternative-\($0)" }

        XCTAssertThrowsError(try DeepGlossParser.parse(jsonString(object)))
    }

    func testParserRejectsSerializedResultOverFourKilobytesEvenWhenIndividualFieldsFit() throws {
        let longChinese = String(repeating: "中", count: 500)
        var object = try validDeepGlossObject()
        object["contextualMeaning"] = longChinese
        object["toneAndSubtext"] = longChinese
        object["slangOrIdiom"] = longChinese

        let raw = try jsonString(object)
        XCTAssertGreaterThan(Data(raw.utf8).count, 4_096)
        XCTAssertThrowsError(try DeepGlossParser.parse(raw))
    }
}

final class DeepGlossCacheTests: XCTestCase {
    func testFingerprintChangeMissesCache() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let cache = DeepGlossCache(fileURL: rig.fileURL)

        await cache.store(deepGlossResult, fingerprint: "old", cueAnchor: "15", expression: "see your point")

        let value = await cache.value(fingerprint: "new", cueAnchor: "15", expression: "see your point")
        XCTAssertNil(value)
    }

    func testExpressionKeyTrimsCollapsesWhitespaceAndUsesLocaleIndependentLowercase() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let cache = DeepGlossCache(fileURL: rig.fileURL)

        await cache.store(
            deepGlossResult,
            fingerprint: "f",
            cueAnchor: "15",
            expression: "  SEE\tYOUR\nPOINT  "
        )

        let value = await cache.value(fingerprint: "f", cueAnchor: "15", expression: "see your point")
        XCTAssertEqual(value, deepGlossResult)
    }

    func testCacheEvictsLeastRecentlyUsedPastTwoHundred() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let cache = DeepGlossCache(fileURL: rig.fileURL)
        for index in 0..<200 {
            await cache.store(
                deepGlossResult,
                fingerprint: "f",
                cueAnchor: "\(index)",
                expression: "p\(index)"
            )
        }
        _ = await cache.value(fingerprint: "f", cueAnchor: "0", expression: "p0")

        await cache.store(deepGlossResult, fingerprint: "f", cueAnchor: "200", expression: "p200")

        let refreshedOldest = await cache.value(fingerprint: "f", cueAnchor: "0", expression: "p0")
        let evicted = await cache.value(fingerprint: "f", cueAnchor: "1", expression: "p1")
        XCTAssertEqual(refreshedOldest, deepGlossResult)
        XCTAssertNil(evicted)
    }

    func testCorruptFileRecoversToEmptyAndCanBeReplacedByValidCacheData() async throws {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        try FileManager.default.createDirectory(at: rig.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: rig.fileURL)
        let cache = DeepGlossCache(fileURL: rig.fileURL)

        let corruptMiss = await cache.value(fingerprint: "f", cueAnchor: "1", expression: "hello")
        XCTAssertNil(corruptMiss)
        await cache.store(deepGlossResult, fingerprint: "f", cueAnchor: "1", expression: "hello")

        let reloaded = DeepGlossCache(fileURL: rig.fileURL)
        let reloadedValue = await reloaded.value(
            fingerprint: "f",
            cueAnchor: "1",
            expression: "hello"
        )
        XCTAssertEqual(reloadedValue, deepGlossResult)
    }

    func testWriteFailureDoesNotEscapeAndKeepsInMemoryValueUsable() async throws {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        try FileManager.default.createDirectory(at: rig.fileURL, withIntermediateDirectories: true)
        let cache = DeepGlossCache(fileURL: rig.fileURL)

        await cache.store(deepGlossResult, fingerprint: "f", cueAnchor: "1", expression: "hello")

        let memoryValue = await cache.value(
            fingerprint: "f",
            cueAnchor: "1",
            expression: "hello"
        )
        XCTAssertEqual(memoryValue, deepGlossResult)
    }
}

@MainActor
final class DeepGlossViewModelTests: XCTestCase {
    func testMissingProfilePreparesOnceBeforeStartingSingleGlossRequest() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let cache = DeepGlossCache(fileURL: rig.fileURL)
        let ensure = GatedDeepGlossProfileProvider()
        let provider = DeepGlossProviderSpy(outcomes: [.success(validDeepGlossJSON())])
        let model = DeepGlossViewModel(cache: cache, provider: provider.call)
        let gloss = makeWordGloss(sourceContext: makeSourceContext(profile: nil))

        let first = Task { await model.load(gloss: gloss, ensureProfile: ensure.call) }
        while await ensure.callCount == 0 { await Task.yield() }
        let second = Task { await model.load(gloss: gloss, ensureProfile: ensure.call) }
        await Task.yield()

        XCTAssertEqual(model.phase, .preparingContext)
        let ensureCallsWhilePreparing = await ensure.callCount
        let glossCallsWhilePreparing = await provider.callCount
        XCTAssertEqual(ensureCallsWhilePreparing, 1)
        XCTAssertEqual(glossCallsWhilePreparing, 0)

        await ensure.release(makeSourceContext(profile: deepGlossProfile))
        await first.value
        await second.value

        let finalEnsureCalls = await ensure.callCount
        let finalGlossCalls = await provider.callCount
        XCTAssertEqual(finalEnsureCalls, 1)
        XCTAssertEqual(finalGlossCalls, 1)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.result, deepGlossResult)
    }

    func testAnalysisChangedStopsBeforeGlossAndRequiresExplicitRetry() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let ensure = SequentialDeepGlossProfileProvider(outcomes: [
            .failure(.analysisChanged),
            .success(makeSourceContext(fingerprint: "f2", profile: deepGlossProfile)),
        ])
        let provider = DeepGlossProviderSpy(outcomes: [.success(validDeepGlossJSON())])
        let model = DeepGlossViewModel(
            cache: DeepGlossCache(fileURL: rig.fileURL),
            provider: provider.call
        )
        let gloss = makeWordGloss(sourceContext: makeSourceContext(profile: nil))

        await model.load(gloss: gloss, ensureProfile: ensure.call)

        XCTAssertEqual(model.phase, .analysisChanged)
        XCTAssertTrue(model.canRetry)
        XCTAssertNil(model.result)
        let callsBeforeRetry = await provider.callCount
        XCTAssertEqual(callsBeforeRetry, 0)

        await model.load(gloss: gloss, ensureProfile: ensure.call)

        let callsAfterRetry = await provider.callCount
        XCTAssertEqual(callsAfterRetry, 1)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testCancellationStopsInFlightGlossAndLeavesItRetryable() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let provider = CancellableDeepGlossProvider()
        let model = DeepGlossViewModel(
            cache: DeepGlossCache(fileURL: rig.fileURL),
            provider: provider.call
        )
        let gloss = makeWordGloss(sourceContext: makeSourceContext(profile: deepGlossProfile))
        let task = Task { await model.load(gloss: gloss, ensureProfile: nil) }
        while await provider.callCount == 0 { await Task.yield() }

        model.cancel()
        await task.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
    }

    func testEmptyFingerprintNeverBurnsGlossLLM() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let provider = DeepGlossProviderSpy(outcomes: [.success(validDeepGlossJSON())])
        let model = DeepGlossViewModel(
            cache: DeepGlossCache(fileURL: rig.fileURL),
            provider: provider.call
        )
        let gloss = makeWordGloss(
            sourceContext: makeSourceContext(fingerprint: "  ", profile: deepGlossProfile)
        )

        await model.load(gloss: gloss, ensureProfile: nil)

        XCTAssertEqual(model.phase, .fingerprintUnavailable)
        XCTAssertTrue(model.canRetry)
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testCacheHitRendersWithoutProviderRequest() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let cache = DeepGlossCache(fileURL: rig.fileURL)
        await cache.store(deepGlossResult, fingerprint: "f1", cueAnchor: "5", expression: "see your point")
        let provider = DeepGlossProviderSpy(outcomes: [])
        let model = DeepGlossViewModel(cache: cache, provider: provider.call)
        let gloss = makeWordGloss(sourceContext: makeSourceContext(profile: deepGlossProfile))

        await model.load(gloss: gloss, ensureProfile: nil)

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.result, deepGlossResult)
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testMalformedProviderResultIsNotCached() async {
        let rig = makeCacheRig()
        defer { rig.cleanup() }
        let provider = DeepGlossProviderSpy(outcomes: [
            .success(#"{"contextualMeaning":"missing exact keys"}"#),
            .success(validDeepGlossJSON()),
        ])
        let model = DeepGlossViewModel(
            cache: DeepGlossCache(fileURL: rig.fileURL),
            provider: provider.call
        )
        let gloss = makeWordGloss(sourceContext: makeSourceContext(profile: deepGlossProfile))

        await model.load(gloss: gloss, ensureProfile: nil)
        XCTAssertTrue(model.canRetry)

        await model.load(gloss: gloss, ensureProfile: nil)

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(model.phase, .loaded)
    }
}

private actor DeepGlossProviderSpy {
    private var outcomes: [Result<String, TestDeepGlossError>]
    private(set) var callCount = 0

    init(outcomes: [Result<String, TestDeepGlossError>]) {
        self.outcomes = outcomes
    }

    func call(_ messages: [ChatMessage]) async throws -> String {
        callCount += 1
        return try outcomes.removeFirst().get()
    }
}

private actor GatedDeepGlossProfileProvider {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<WordGloss.SourceContext, Never>?

    func call() async throws -> WordGloss.SourceContext {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ context: WordGloss.SourceContext) {
        continuation?.resume(returning: context)
        continuation = nil
    }
}

private actor SequentialDeepGlossProfileProvider {
    private var outcomes: [Result<WordGloss.SourceContext, DeepGlossPreparationError>]

    init(outcomes: [Result<WordGloss.SourceContext, DeepGlossPreparationError>]) {
        self.outcomes = outcomes
    }

    func call() async throws -> WordGloss.SourceContext {
        try outcomes.removeFirst().get()
    }
}

private actor CancellableDeepGlossProvider {
    private(set) var callCount = 0

    func call(_ messages: [ChatMessage]) async throws -> String {
        callCount += 1
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return validDeepGlossJSON()
    }
}

private enum TestDeepGlossError: Error {
    case failed
}

private let deepGlossProfile = VideoContextProfile(
    theme: "委婉沟通与分歧处理",
    participants: "采访者与演员",
    setting: "轻松访谈",
    tone: "自然、友好并带有幽默感",
    culturalContext: "",
    recurringConcepts: ["先认可对方观点"]
)

private let deepGlossResult = DeepGlossResult(
    contextualMeaning: "在这里表示理解并认可对方刚才的观点。",
    toneAndSubtext: "语气友好，为后续补充不同意见留出空间。",
    slangOrIdiom: "",
    culturalContext: "",
    naturalAlternatives: ["I understand your point."],
    usageWarning: ""
)

private func makeDeepGlossCue(index: Int, text: String? = nil) -> Cue {
    Cue(
        index: index,
        time: Double(index * 2),
        endTime: Double(index * 2 + 2),
        text: text ?? "cue-\(index)"
    )
}

private func makeDeepGlossContext(
    cues: [Cue],
    currentCueIndex: Int
) -> DeepGlossContext {
    DeepGlossContext(
        title: "Interview",
        profile: deepGlossProfile,
        expression: "see your point",
        quickTranslation: "明白你的意思",
        quickNote: "表示理解对方观点。",
        cues: cues,
        currentCueIndex: currentCueIndex
    )
}

private func makeSourceContext(
    fingerprint: String = "f1",
    profile: VideoContextProfile?
) -> WordGloss.SourceContext {
    let cues = (0..<12).map { makeDeepGlossCue(index: $0) }
    return WordGloss.SourceContext(
        title: "Interview",
        analysisFingerprint: fingerprint,
        profile: profile,
        cues: cues,
        currentCueIndex: 5
    )
}

private func makeWordGloss(sourceContext: WordGloss.SourceContext) -> WordGloss {
    WordGloss(
        word: "see your point",
        translation: "明白你的意思",
        note: "表示理解对方观点。",
        sourceContext: sourceContext,
        collectionState: .unavailable
    )
}

private func validDeepGlossJSON() -> String {
    #"{"contextualMeaning":"在这里表示理解并认可对方刚才的观点。","toneAndSubtext":"语气友好，为后续补充不同意见留出空间。","slangOrIdiom":"","culturalContext":"","naturalAlternatives":["I understand your point."],"usageWarning":""}"#
}

private func validDeepGlossObject() throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(validDeepGlossJSON().utf8)) as? [String: Any]
    )
}

private func jsonString(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private struct DeepGlossCacheRig {
    let directoryURL: URL
    let fileURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func makeCacheRig() -> DeepGlossCacheRig {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deep-gloss-\(UUID().uuidString)", isDirectory: true)
    return DeepGlossCacheRig(
        directoryURL: directory,
        fileURL: directory.appendingPathComponent("deep_gloss_cache.json")
    )
}

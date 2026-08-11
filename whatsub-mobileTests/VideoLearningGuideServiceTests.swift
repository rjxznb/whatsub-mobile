import XCTest
@testable import whatsub_mobile

actor LearningGuideAPISpy: LearningGuidePersisting {
    enum Outcome {
        case accepted(LearningGuideUpdateResponse)
        case failure(APIError)
    }

    private var outcomes: [Outcome]
    private(set) var expectedFingerprints: [String] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func updateLearningGuide(
        id: String,
        expectedFingerprint: String,
        guide: LearningGuideDraft,
        profile: VideoContextProfile,
        token: String
    ) async throws -> LearningGuideUpdateResponse {
        expectedFingerprints.append(expectedFingerprint)
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .accepted(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

actor SummaryProviderSpy {
    enum Outcome {
        case summary(AnalysisSummary)
        case failure(ChatCompletionsClient.LlmError)
    }

    private var outcomes: [Outcome]
    private(set) var callCount = 0

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func call(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> AnalysisSummary {
        callCount += 1
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .summary(let summary):
            return summary
        case .failure(let error):
            throw error
        }
    }
}

actor CancellableSummaryProviderSpy {
    private(set) var callCount = 0

    func call(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> AnalysisSummary {
        callCount += 1
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return makeAnalysisSummary()
    }
}

final class VideoLearningGuideServiceTests: XCTestCase {
    func testLazyGenerationUsesCurrentFingerprintAndPersistsOnce() async throws {
        let api = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "f1"))])
        let llm = SummaryProviderSpy([.summary(makeAnalysisSummary())])
        let service = VideoLearningGuideService(api: api, summaryProvider: llm.call)

        let result = try await service.generate(
            entry: makeLearningGuideEntry(fingerprint: "f1"),
            settings: LlmSettings(),
            token: "token"
        )

        let fingerprints = await api.expectedFingerprints
        let callCount = await llm.callCount
        XCTAssertEqual(fingerprints, ["f1"])
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.learningGuide.verdict, .selectSegments)
    }

    func testEmptyFingerprintStopsBeforeSummaryOrPatch() async {
        let api = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "unused"))])
        let llm = SummaryProviderSpy([.summary(makeAnalysisSummary())])
        let service = VideoLearningGuideService(api: api, summaryProvider: llm.call)

        do {
            _ = try await service.generate(
                entry: makeLearningGuideEntry(fingerprint: ""),
                settings: LlmSettings(),
                token: "token"
            )
            XCTFail("Expected a missing fingerprint error")
        } catch {
            XCTAssertEqual(error as? VideoLearningGuideServiceError, .missingAnalysisFingerprint)
        }

        let callCount = await llm.callCount
        let fingerprints = await api.expectedFingerprints
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(fingerprints, [])
    }

    func testCancellationStopsBeforePatch() async {
        let api = LearningGuideAPISpy([.accepted(makeGuideResponse(fingerprint: "unused"))])
        let llm = CancellableSummaryProviderSpy()
        let service = VideoLearningGuideService(api: api, summaryProvider: llm.call)
        let task = Task {
            try await service.generate(
                entry: makeLearningGuideEntry(fingerprint: "f1"),
                settings: LlmSettings(),
                token: "token"
            )
        }

        while await llm.callCount == 0 { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let fingerprints = await api.expectedFingerprints
        XCTAssertEqual(fingerprints, [])
    }
}

// MARK: - Shared Task 6 fixtures

func makeLearningGuideDraft() -> LearningGuideDraft {
    LearningGuideDraft(
        verdict: .selectSegments,
        overview: "这段访谈通过自然对话展示人物如何先认可对方观点，再用缓和语气委婉表达不同意见，并维持轻松友好的交流氛围。",
        contentOutline: ["先说明讨论背景和人物之间的关系", "再展示缓和分歧时常用的自然表达"],
        cefrLevel: .b2,
        cefrReason: "语速自然，并包含需要结合上下文和说话语气理解的委婉表达。",
        recommendedFor: ["希望提升真实会话理解的学习者"],
        learningReasons: ["包含可直接迁移到讨论场景的表达"],
        cultureNotes: ["先认可对方观点通常能让分歧表达更自然"],
        studyTips: ["先盲听，再跟读推荐片段"],
        topSegments: [
            RecommendedSegment(
                startTime: 10,
                endTime: 14,
                title: "委婉认同",
                reason: "展示先认可再表达分歧的方式",
                focusExpressions: ["see your point"]
            ),
        ]
    )
}

func makeLearningGuide() -> LearningGuide {
    LearningGuide(draft: makeLearningGuideDraft(), generatedAt: 2_000)
}

func makeVideoContextProfile() -> VideoContextProfile {
    VideoContextProfile(
        theme: "委婉沟通与分歧处理",
        participants: "采访者与演员",
        setting: "轻松访谈",
        tone: "自然、友好并带有幽默感",
        culturalContext: "",
        recurringConcepts: ["先认可对方观点", "再表达不同意见"]
    )
}

func makeAnalysisSummary() -> AnalysisSummary {
    AnalysisSummary(
        keyPhrases: [],
        learningGuide: makeLearningGuideDraft(),
        contextProfile: makeVideoContextProfile()
    )
}

func makeGuideResponse(fingerprint: String) -> LearningGuideUpdateResponse {
    LearningGuideUpdateResponse(
        learningGuide: makeLearningGuide(),
        contextProfile: makeVideoContextProfile(),
        analysisFingerprint: fingerprint
    )
}

func makeLearningGuideEntry(
    fingerprint: String,
    guide: LearningGuide? = nil
) -> LibraryEntryDetail {
    let cue = Cue(
        index: 0,
        time: 10,
        endTime: 14,
        text: "I see your point.",
        translation: "我明白你的意思。"
    )
    return LibraryEntryDetail(
        id: "entry",
        youtubeId: "dQw4w9WgXcQ",
        sourceUrl: "https://youtu.be/dQw4w9WgXcQ",
        title: "Test video",
        durationSec: 20,
        transcriptSrt: nil,
        analysisJson: .assembled(
            subtitles: [cue],
            keyPhrases: [],
            learningGuide: guide,
            contextProfile: guide == nil ? nil : makeVideoContextProfile(),
            learningGuideSourceFingerprint: guide == nil ? nil : fingerprint
        ),
        videoUrl: nil,
        audioUrl: nil,
        analysisFingerprint: fingerprint
    )
}

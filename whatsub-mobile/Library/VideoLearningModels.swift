import Foundation

enum LearningVerdict: String, Codable, Equatable {
    case studyAll = "study_all"
    case selectSegments = "select_segments"
    case extensiveListening = "extensive_listening"
    case limitedValue = "limited_value"
}

enum CEFRLevel: String, Codable, Equatable {
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"
    case c2 = "C2"
}

struct RecommendedSegment: Codable, Equatable {
    let startTime: Double
    let endTime: Double
    let title: String
    let reason: String
    let focusExpressions: [String]
}

struct LearningGuideDraft: Codable, Equatable {
    let verdict: LearningVerdict
    let overview: String
    let contentOutline: [String]
    let cefrLevel: CEFRLevel
    let cefrReason: String
    let recommendedFor: [String]
    let learningReasons: [String]
    let cultureNotes: [String]
    let studyTips: [String]
    let topSegments: [RecommendedSegment]
}

struct LearningGuide: Codable, Equatable {
    let verdict: LearningVerdict
    let overview: String
    let contentOutline: [String]
    let cefrLevel: CEFRLevel
    let cefrReason: String
    let recommendedFor: [String]
    let learningReasons: [String]
    let cultureNotes: [String]
    let studyTips: [String]
    let topSegments: [RecommendedSegment]
    let generatedAt: Int64

    init(draft: LearningGuideDraft, generatedAt: Int64) {
        verdict = draft.verdict
        overview = draft.overview
        contentOutline = draft.contentOutline
        cefrLevel = draft.cefrLevel
        cefrReason = draft.cefrReason
        recommendedFor = draft.recommendedFor
        learningReasons = draft.learningReasons
        cultureNotes = draft.cultureNotes
        studyTips = draft.studyTips
        topSegments = draft.topSegments
        self.generatedAt = generatedAt
    }

    var draft: LearningGuideDraft {
        LearningGuideDraft(
            verdict: verdict,
            overview: overview,
            contentOutline: contentOutline,
            cefrLevel: cefrLevel,
            cefrReason: cefrReason,
            recommendedFor: recommendedFor,
            learningReasons: learningReasons,
            cultureNotes: cultureNotes,
            studyTips: studyTips,
            topSegments: topSegments
        )
    }
}

struct VideoContextProfile: Codable, Equatable {
    let theme: String
    let participants: String
    let setting: String
    let tone: String
    let culturalContext: String
    let recurringConcepts: [String]
}

struct DeepGlossResult: Codable, Equatable {
    let contextualMeaning: String
    let toneAndSubtext: String
    let slangOrIdiom: String
    let culturalContext: String
    let naturalAlternatives: [String]
    let usageWarning: String
}

/// Complete summary checkpoint. New checkpoints encode this object; the
/// custom single-value fallback preserves version-1 files whose
/// `completedSummary` value was a raw `[KeyPhrase]` array.
struct AnalysisSummary: Codable {
    let keyPhrases: [KeyPhrase]
    let learningGuide: LearningGuideDraft?
    let contextProfile: VideoContextProfile?

    init(
        keyPhrases: [KeyPhrase],
        learningGuide: LearningGuideDraft?,
        contextProfile: VideoContextProfile?
    ) {
        self.keyPhrases = keyPhrases
        self.learningGuide = learningGuide
        self.contextProfile = contextProfile
    }

    private enum CodingKeys: String, CodingKey {
        case keyPhrases, learningGuide, contextProfile
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([KeyPhrase].self) {
            keyPhrases = legacy
            learningGuide = nil
            contextProfile = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyPhrases = try container.decode([KeyPhrase].self, forKey: .keyPhrases)
        learningGuide = try container.decodeIfPresent(
            LearningGuideDraft.self,
            forKey: .learningGuide
        )
        contextProfile = try container.decodeIfPresent(
            VideoContextProfile.self,
            forKey: .contextProfile
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyPhrases, forKey: .keyPhrases)
        try container.encodeIfPresent(learningGuide, forKey: .learningGuide)
        try container.encodeIfPresent(contextProfile, forKey: .contextProfile)
    }
}

struct LearningGuideUpdateResponse: Decodable {
    let learningGuide: LearningGuide
    let contextProfile: VideoContextProfile
    let analysisFingerprint: String
}

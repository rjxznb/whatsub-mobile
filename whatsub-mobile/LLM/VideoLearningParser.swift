import CoreFoundation
import Foundation

enum VideoLearningParserError: LocalizedError {
    case invalidSummary
    case invalidLearningGuide
    case invalidContextProfile

    var errorDescription: String? {
        switch self {
        case .invalidSummary:
            return "AI 返回的视频总结格式不正确。"
        case .invalidLearningGuide:
            return "AI 返回的学习导览格式不正确。"
        case .invalidContextProfile:
            return "AI 返回的视频语境格式不正确。"
        }
    }
}

enum VideoLearningParser {
    private enum Limits {
        static let overview = 40...220
        static let contentOutlineCount = 2...6
        static let contentOutlineItem = 10...100
        static let cefrReason = 20...160
        static let recommendedForCount = 1...4
        static let recommendedForItem = 1...160
        static let learningReasonsCount = 1...5
        static let learningReasonItem = 1...200
        static let cultureNotesCount = 0...5
        static let cultureNoteItem = 1...200
        static let studyTipsCount = 1...5
        static let studyTipItem = 1...200
        static let segmentCount = 0...3
        static let segmentTitle = 4...40
        static let segmentReason = 10...160
        static let focusExpressionCount = 0...5
        static let focusExpression = 1...100
        static let profileScalarMax = 500
        static let recurringConceptCount = 0...8
        static let recurringConcept = 1...120
        static let profileSerializedBytes = 4 * 1_024
    }

    private static let summaryKeys = Set([
        "type", "keyPhrases", "learningGuide", "contextProfile",
    ])
    private static let keyPhraseKeys = Set(["expression", "meaningZh", "usage"])
    private static let guideKeys = Set([
        "verdict", "overview", "contentOutline", "cefrLevel", "cefrReason",
        "recommendedFor", "learningReasons", "cultureNotes", "studyTips", "topSegments",
    ])
    private static let segmentKeys = Set([
        "startTime", "endTime", "title", "reason", "focusExpressions",
    ])
    private static let profileKeys = Set([
        "theme", "participants", "setting", "tone", "culturalContext", "recurringConcepts",
    ])

    static func parseSummary(
        _ data: Data,
        durationSec: Double?,
        cues: [Cue]
    ) throws -> AnalysisSummary {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw VideoLearningParserError.invalidSummary
        }
        let nonEmptyLines = raw.split(whereSeparator: { $0.isNewline }).filter {
            !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonEmptyLines.count == 1,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == summaryKeys,
              root["type"] as? String == "summary",
              let rawPhrases = root["keyPhrases"] as? [Any] else {
            throw VideoLearningParserError.invalidSummary
        }

        let keyPhrases = try rawPhrases.map(parseKeyPhrase)
        let guide = try parseGuide(root["learningGuide"], durationSec: durationSec, cues: cues)
        let profile = try parseProfile(root["contextProfile"])
        return AnalysisSummary(
            keyPhrases: keyPhrases,
            learningGuide: guide,
            contextProfile: profile
        )
    }

    private static func parseKeyPhrase(_ value: Any) throws -> KeyPhrase {
        guard let object = value as? [String: Any],
              Set(object.keys) == keyPhraseKeys,
              let expression = object["expression"] as? String,
              let meaningZh = object["meaningZh"] as? String,
              let usage = object["usage"] as? String,
              !expression.isEmpty,
              !meaningZh.isEmpty,
              !usage.isEmpty else {
            throw VideoLearningParserError.invalidSummary
        }
        return KeyPhrase(expression: expression, meaningZh: meaningZh, usage: usage)
    }

    private static func parseGuide(
        _ value: Any?,
        durationSec: Double?,
        cues: [Cue]
    ) throws -> LearningGuideDraft {
        guard let object = value as? [String: Any], Set(object.keys) == guideKeys else {
            throw VideoLearningParserError.invalidLearningGuide
        }

        let bounds = try cues.map { cue -> (start: Double, end: Double) in
            guard cue.time.isFinite, cue.endTime.isFinite,
                  cue.time >= 0, cue.time < cue.endTime else {
                throw VideoLearningParserError.invalidLearningGuide
            }
            return (cue.time, cue.endTime)
        }
        let effectiveDuration: Double
        if let durationSec {
            guard durationSec.isFinite, durationSec >= 0 else {
                throw VideoLearningParserError.invalidLearningGuide
            }
            effectiveDuration = durationSec
        } else {
            effectiveDuration = bounds.map { $0.end }.max() ?? 0
        }

        guard let verdictRaw = object["verdict"] as? String,
              let verdict = LearningVerdict(rawValue: verdictRaw),
              let cefrRaw = object["cefrLevel"] as? String,
              let cefr = CEFRLevel(rawValue: cefrRaw),
              let rawSegments = object["topSegments"] as? [Any],
              Limits.segmentCount.contains(rawSegments.count) else {
            throw VideoLearningParserError.invalidLearningGuide
        }

        return LearningGuideDraft(
            verdict: verdict,
            overview: try string(object["overview"], length: Limits.overview, error: .invalidLearningGuide),
            contentOutline: try stringArray(
                object["contentOutline"],
                count: Limits.contentOutlineCount,
                itemLength: Limits.contentOutlineItem,
                error: .invalidLearningGuide
            ),
            cefrLevel: cefr,
            cefrReason: try string(object["cefrReason"], length: Limits.cefrReason, error: .invalidLearningGuide),
            recommendedFor: try stringArray(
                object["recommendedFor"],
                count: Limits.recommendedForCount,
                itemLength: Limits.recommendedForItem,
                error: .invalidLearningGuide
            ),
            learningReasons: try stringArray(
                object["learningReasons"],
                count: Limits.learningReasonsCount,
                itemLength: Limits.learningReasonItem,
                error: .invalidLearningGuide
            ),
            cultureNotes: try stringArray(
                object["cultureNotes"],
                count: Limits.cultureNotesCount,
                itemLength: Limits.cultureNoteItem,
                error: .invalidLearningGuide
            ),
            studyTips: try stringArray(
                object["studyTips"],
                count: Limits.studyTipsCount,
                itemLength: Limits.studyTipItem,
                error: .invalidLearningGuide
            ),
            topSegments: try rawSegments.map {
                try parseSegment($0, duration: effectiveDuration, bounds: bounds)
            }
        )
    }

    private static func parseSegment(
        _ value: Any,
        duration: Double,
        bounds: [(start: Double, end: Double)]
    ) throws -> RecommendedSegment {
        guard let object = value as? [String: Any], Set(object.keys) == segmentKeys else {
            throw VideoLearningParserError.invalidLearningGuide
        }
        let start = try finiteNumber(object["startTime"], error: .invalidLearningGuide)
        let end = try finiteNumber(object["endTime"], error: .invalidLearningGuide)
        guard start >= 0, start < end, end <= duration,
              bounds.contains(where: { start < $0.end && end > $0.start }) else {
            throw VideoLearningParserError.invalidLearningGuide
        }
        return RecommendedSegment(
            startTime: start,
            endTime: end,
            title: try string(object["title"], length: Limits.segmentTitle, error: .invalidLearningGuide),
            reason: try string(object["reason"], length: Limits.segmentReason, error: .invalidLearningGuide),
            focusExpressions: try stringArray(
                object["focusExpressions"],
                count: Limits.focusExpressionCount,
                itemLength: Limits.focusExpression,
                error: .invalidLearningGuide
            )
        )
    }

    private static func parseProfile(_ value: Any?) throws -> VideoContextProfile {
        guard let object = value as? [String: Any],
              Set(object.keys) == profileKeys,
              JSONSerialization.isValidJSONObject(object),
              try JSONSerialization.data(withJSONObject: object).count <= Limits.profileSerializedBytes else {
            throw VideoLearningParserError.invalidContextProfile
        }
        return VideoContextProfile(
            theme: try string(object["theme"], length: 1...Limits.profileScalarMax, error: .invalidContextProfile),
            participants: try string(object["participants"], length: 1...Limits.profileScalarMax, error: .invalidContextProfile),
            setting: try string(object["setting"], length: 1...Limits.profileScalarMax, error: .invalidContextProfile),
            tone: try string(object["tone"], length: 1...Limits.profileScalarMax, error: .invalidContextProfile),
            culturalContext: try string(object["culturalContext"], length: 0...Limits.profileScalarMax, error: .invalidContextProfile),
            recurringConcepts: try stringArray(
                object["recurringConcepts"],
                count: Limits.recurringConceptCount,
                itemLength: Limits.recurringConcept,
                error: .invalidContextProfile
            )
        )
    }

    private static func string(
        _ value: Any?,
        length: ClosedRange<Int>,
        error: VideoLearningParserError
    ) throws -> String {
        guard let value = value as? String,
              length.contains(value.unicodeScalars.count) else { throw error }
        return value
    }

    private static func stringArray(
        _ value: Any?,
        count: ClosedRange<Int>,
        itemLength: ClosedRange<Int>,
        error: VideoLearningParserError
    ) throws -> [String] {
        guard let values = value as? [Any], count.contains(values.count) else { throw error }
        return try values.map { try string($0, length: itemLength, error: error) }
    }

    private static func finiteNumber(
        _ value: Any?,
        error: VideoLearningParserError
    ) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw error }
        let result = number.doubleValue
        guard result.isFinite else { throw error }
        return result
    }
}

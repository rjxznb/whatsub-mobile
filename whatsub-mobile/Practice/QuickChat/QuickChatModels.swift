// whatsub-mobile/Practice/QuickChat/QuickChatModels.swift
import Foundation

/// Per-phrase production-mastery state. Mirrors QuizProgress in shape and
/// persistence pattern, but tracks "spoke it correctly in a dialogue" instead
/// of "picked the right Chinese meaning on a quiz card".
struct ProductionProgress: Codable, Equatable {
    var phraseNormalized: String
    var usedCorrectCount: Int = 0   // cumulative correct uses across sessions
    var attemptCount: Int = 0       // cumulative attempts (including wrong)
    var lastErrorNote: String? = nil
    var lastPracticedAt: Double = 0 // epoch seconds
    var masteredAt: Double? = nil   // set when usedCorrectCount first crosses threshold

    /// Spec §5: mastery threshold = 2 distinct correct uses (across sessions).
    static let masteryThreshold: Int = 2
    /// Spec §5: spaced-repetition window. Mastered phrases reenter the pool
    /// after this many seconds idle.
    static let spacedRepetitionWindow: TimeInterval = 7 * 24 * 3600
}

/// One phrase the selector picked for this session. Carries the original
/// MineItem fields the view + prompt need (no need to keep the full MineItem).
struct SessionPhrase: Equatable, Identifiable {
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let contextSentence: String
    let sourceKind: String         // youtube | webpage | pdf | curator
    let sourceURL: String
    let sourceTimestampSec: Double?
    let tags: [String]
    var id: String { phraseNormalized }
}

/// One verdict entry for one phrase in one assistant turn.
struct PhraseVerdict: Codable, Equatable {
    let phrase: String         // phraseRaw — matches what's in the prompt
    let attempted: Bool
    let correct: Bool
    let note: String           // Chinese correction or empty
}

/// The JSON block between <<<VERDICT>>> ... <<<END>>>.
struct TurnVerdict: Codable, Equatable {
    let verdicts: [PhraseVerdict]
}

/// One round of dialogue (one user turn + one assistant reply).
struct ChatTurn: Identifiable, Equatable {
    let id: UUID
    let userText: String           // empty for the opening assistant-only turn
    var assistantText: String      // accumulates as chunks stream in
    var verdict: TurnVerdict?      // parsed from the sentinel block
    let timestamp: Date

    init(id: UUID = UUID(), userText: String, assistantText: String = "",
         verdict: TurnVerdict? = nil, timestamp: Date = Date()) {
        self.id = id
        self.userText = userText
        self.assistantText = assistantText
        self.verdict = verdict
        self.timestamp = timestamp
    }
}

/// End-of-session summary written to ProductionProgressStore.
struct SessionResult {
    let phrases: [SessionPhrase]
    let correctlyUsed: Set<String>     // phraseNormalized
    let perPhraseErrorNotes: [String: String]  // phraseNormalized → most recent note
    let turnCount: Int
}

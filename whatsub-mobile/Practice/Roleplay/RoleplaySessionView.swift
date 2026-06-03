import SwiftUI

/// Hosts a roleplay session in the existing QuickChat orb shell. We reuse
/// the full QuickChat stack — VoiceOrbView + VADCoordinator + ConversationEngine
/// + ProductionProgressStore + Speaker TTS — and only swap two things:
///
/// 1. The system prompt: `RoleplayPrompts.turnSystemPrompt(scenario:)`
///    instead of `QuickChatPrompts.systemPrompt(phrases:suggestedTag:)`.
/// 2. The "phrases" shown in the header chips: synthesized `SessionPhrase`s
///    built from `scenario.vocabHints` so per-turn `<<<VERDICT>>>` blocks
///    line up with the store's existing per-phrase mastery semantics.
///
/// The session sheet drives itself. When user dismisses, control returns
/// to the picker.
struct RoleplaySessionView: View {
    let scenario: RoleplayScenario

    /// 8 turns gives the scene more room than QuickChat's 5 (a roleplay
    /// session needs setup → conflict → resolution; phrase-drill just
    /// needs each phrase to show up once).
    private let maxTurns: Int = 8

    var body: some View {
        let phrases = Self.synthesizedPhrases(from: scenario)
        let prompt = RoleplayPrompts.turnSystemPrompt(scenario: scenario, maxTurns: maxTurns)
        return QuickChatView(
            roleplayScenarioTitle: scenario.title,
            vocabPhrases: phrases,
            systemPrompt: prompt,
            maxTurns: maxTurns
        )
    }

    /// Convert `vocabHints` (plain English strings) into the `SessionPhrase`
    /// shape QuickChatView's header + verdict-keying pipeline expects.
    /// `phraseRaw` is what gets written to ProductionProgressStore, so we
    /// keep it lowercase + trimmed (same convention QuickChat uses for
    /// corpus phrases) — that way the same phrase shows up under the same
    /// key whether it was practiced in a roleplay or a phrase-drill session.
    static func synthesizedPhrases(from scenario: RoleplayScenario) -> [SessionPhrase] {
        scenario.normalizedHints.enumerated().map { (i, hint) in
            SessionPhrase(
                phraseNormalized: hint,
                phraseRaw: hint,
                meaningZh: nil,
                usageNote: "scenario: \(scenario.title)",
                contextSentence: scenario.setup,
                sourceKind: "roleplay",
                sourceURL: "",
                sourceTimestampSec: nil,
                tags: []
            )
        }
    }
}

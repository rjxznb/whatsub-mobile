import Foundation

/// One phrase extracted by the LLM from the OCR'd photo text. Matches
/// the wire shape declared in `PhotoPrompts.systemPrompt` — see
/// `PhotoAnalyzer.parse` for the lenient decoder.
struct PhotoPhrase: Identifiable, Equatable {
    let id: UUID
    /// Original-case phrase as it appears (or should appear) in the
    /// English text. Lowercase-normalized form goes into mastery store.
    let phrase: String
    /// Short Chinese meaning. Optional because the LLM occasionally
    /// drops the field on edge cases — UI shows "(略)" in that case.
    let meaningZh: String?
    /// One-sentence Chinese usage tip / example. Optional.
    let usageNote: String?
    /// Original sentence the phrase appears in — stored on the corpus
    /// contribution as `contextSentence` so the user can later see
    /// where they collected it.
    let contextSentence: String

    var phraseNormalized: String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One round of `PhotoAnalyzer.analyze` — Chinese translation of the
/// whole OCR text PLUS the highlighted phrases.
struct PhotoAnalysisResult: Equatable {
    /// Free-form Chinese translation. Rendered in the bottom half of the
    /// bilingual review pane.
    let translation: String
    /// 3-8 phrases the LLM judged worth learning. Order matches the
    /// order of appearance in the source text.
    let phrases: [PhotoPhrase]
}

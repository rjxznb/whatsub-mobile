import SwiftUI

/// Testable behavior behind the compact card shown for a tapped AI highlight.
/// The view owns presentation; this model owns one-shot pronunciation and the
/// duplicate-safe transition into the local pending collection queue.
final class HighlightWordCardModel: ObservableObject {
    @Published private(set) var saved: Bool
    let ipa: String?

    private let gloss: WordGloss
    private let store: PendingPhraseStore
    private let speak: (String) -> Void
    private let stop: () -> Void
    private var didAutoSpeak = false

    var canCollect: Bool {
        guard case .collectable = gloss.collectionState else { return false }
        return !saved
    }

    init(
        gloss: WordGloss,
        store: PendingPhraseStore = .shared,
        speak: @escaping (String) -> Void = { Speaker.speak($0) },
        stop: @escaping () -> Void = { Speaker.stop() },
        ipaLookup: @escaping (String) -> String? = { IPADict.shared.lookup($0) }
    ) {
        self.gloss = gloss
        self.store = store
        self.speak = speak
        self.stop = stop
        self.ipa = ipaLookup(gloss.word)
        switch gloss.collectionState {
        case .collectable(let context):
            self.saved = store.contains(entryId: context.entryId, phraseRaw: gloss.word)
        case .alreadyCollected:
            self.saved = true
        case .unavailable:
            self.saved = false
        }
    }

    /// Called whenever SwiftUI presents or redraws the card. The guard keeps
    /// automatic pronunciation to exactly once for this presentation.
    func appear() {
        guard !didAutoSpeak else { return }
        didAutoSpeak = true
        speak(gloss.word)
    }

    func replay() {
        speak(gloss.word)
    }

    func disappear() {
        stop()
    }

    /// Returns true only for a newly inserted pending phrase. The caller uses
    /// this to avoid duplicate success haptics when a phrase was already saved.
    @discardableResult
    func collect() -> Bool {
        guard case .collectable(let context) = gloss.collectionState,
              !saved else { return false }
        let trimmedNote = (gloss.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeaning = (gloss.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = PendingPhrase(
            id: UUID(),
            entryId: context.entryId,
            videoTitle: context.videoTitle,
            youtubeId: context.youtubeId,
            phraseRaw: gloss.word,
            contextSentence: context.contextSentence,
            meaningZh: trimmedMeaning.isEmpty ? nil : trimmedMeaning,
            usageNote: trimmedNote.isEmpty ? nil : trimmedNote,
            timestampSec: context.timestampSec,
            collectedAt: Date().timeIntervalSince1970
        )
        let inserted = store.addIfAbsent(pending)
        saved = inserted || store.contains(entryId: context.entryId, phraseRaw: gloss.word)
        return inserted
    }
}

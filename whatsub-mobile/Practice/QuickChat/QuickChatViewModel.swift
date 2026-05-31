import Foundation
import SwiftUI
import AVFoundation
import Speech
import UIKit

/// Testable seam: production wraps ConversationEngine; tests inject canned turns.
struct EngineDriver {
    /// Runs one turn (user input → AsyncThrowingStream of events).
    let runTurn: (String) -> AsyncThrowingStream<ConversationEngine.Event, Error>

    /// Construct a real driver around a ConversationEngine.
    @MainActor
    static func live(_ engine: ConversationEngine) -> EngineDriver {
        EngineDriver(runTurn: { input in engine.runTurn(userInput: input) })
    }

    /// Test stub: a pre-canned list of turns, each with a pre-canned event list.
    struct StubTurn { let events: [ConversationEngine.Event] }
    static func stub(turns: [StubTurn]) -> EngineDriver {
        // Box the mutable list in a reference type so the closure can pop turns.
        final class Cursor { var remaining: [StubTurn]; init(_ t: [StubTurn]) { remaining = t } }
        let cursor = Cursor(turns)
        return EngineDriver(runTurn: { _ in
            let turn = cursor.remaining.isEmpty ? StubTurn(events: [.finished]) : cursor.remaining.removeFirst()
            return AsyncThrowingStream { continuation in
                for e in turn.events { continuation.yield(e) }
                continuation.finish()
            }
        })
    }
}

/// Spec §6.5.1 FSM. One @MainActor view model owns all mutation; views read
/// @Published state.
@MainActor
final class QuickChatViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle              // can record / type
        case recording        // legacy (kept; typing fallback may still use briefly)
        case listening        // NEW — auto-listen with VAD active
        case thinking          // user input sent, awaiting first chunk
        case speaking          // dialog + TTS streaming
        case paused            // backgrounded / interrupted
        case summarizing       // running the local end-of-session aggregation
        case done
        case error(String)
    }

    // ---- inputs / config ----
    let phrases: [SessionPhrase]
    let suggestedTag: String?
    let progressStore: ProductionProgressStore
    private let driver: EngineDriver
    private let now: () -> Double                  // injectable clock
    private static let maxTurns = 5                // spec §9 #4

    // ---- @Published state for the view ----
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [ChatTurn] = []
    /// Phrases the session has already confirmed as correctly used. Spec §6.4
    /// session-local Set bottom — drives checklist + bounds store +1's.
    @Published private(set) var completedPhrases: Set<String> = []
    @Published private(set) var perPhraseLastNote: [String: String] = [:]
    @Published var typedInput: String = ""

    // ---- internal session state ----
    private var turnIndex = 0                       // 0 = opening
    private var written = false                     // ensure single end-of-session write
    /// How many times VAD timed out with no speech. After 2, end the session.
    private(set) var noSpeechRounds: Int = 0

    init(phrases: [SessionPhrase],
         suggestedTag: String?,
         progressStore: ProductionProgressStore,
         engineDriver: EngineDriver,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.phrases = phrases
        self.suggestedTag = suggestedTag
        self.progressStore = progressStore
        self.driver = engineDriver
        self.now = now
    }

    /// Start the session: LLM opens the scene (no user input).
    func start() async {
        guard phase == .idle, turns.isEmpty else { return }
        await runOneTurn(userInput: "")
    }

    /// User submitted a transcribed sentence (or typed input).
    func submitUserInput(_ text: String) async {
        guard phase == .idle else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runOneTurn(userInput: trimmed)
    }

    /// User actively ends the session (close button, summary "完成").
    func endSession() async {
        await persistAndFinish()
    }

    /// Mark a phrase as correctly used (manual override "我说对了").
    /// Spec §6.4: takes the same code path as a correct verdict.
    func manuallyConfirm(_ phraseNormalized: String) {
        let wasAlreadyCompleted = completedPhrases.contains(phraseNormalized)
        completedPhrases.insert(phraseNormalized)
        if !wasAlreadyCompleted {
            SoundFX.correct()
        }
    }

    /// Move FSM to paused (scenePhase background, audio session interruption).
    func pause() {
        if phase == .recording || phase == .listening || phase == .speaking || phase == .thinking || phase == .idle {
            phase = .paused
            Speaker.stop()
        }
    }

    /// Move back to idle from paused (user tapped "继续" after returning to foreground).
    func resume() {
        if phase == .paused { phase = .idle }
    }

    /// Called by the view when VAD times out with no user speech. After 2
    /// consecutive timeouts, ends the session.
    func handleNoSpeechTimeout() async {
        noSpeechRounds += 1
        if noSpeechRounds >= 2 {
            await endSession()
        }
    }

    /// Called when a user message has been transcribed by ASR and is about to
    /// be submitted. Resets the no-speech counter.
    func resetNoSpeechCounter() {
        noSpeechRounds = 0
    }

    /// Transition the FSM into `.listening`. The view should start the
    /// VoiceActivityRecorder when this fires.
    func enterListening() {
        guard phase == .idle else { return }
        phase = .listening
    }

    /// Exit `.listening` back to `.idle` (e.g. user tapped close on listening,
    /// or switched to typing mode).
    func exitListening() {
        if phase == .listening { phase = .idle }
    }

    // ---- internal ----

    private func runOneTurn(userInput: String) async {
        let isOpening = userInput.isEmpty
        phase = .thinking

        // Add a user-text turn placeholder (for opening: empty user, assistant only).
        let bubble = ChatTurn(userText: userInput, assistantText: "")
        turns.append(bubble)
        let turnIdx = turns.count - 1

        do {
            for try await event in driver.runTurn(userInput) {
                switch event {
                case .dialogDelta(let s):
                    turns[turnIdx].assistantText += s
                    // Re-sanitize the full running buffer on each delta so that a
                    // leading `<assistant>` tag arriving split across chunks is still
                    // stripped once the full tag has accumulated. O(n) per delta but
                    // n is small (a few hundred chars per turn).
                    turns[turnIdx].assistantText = AssistantTextSanitizer.sanitize(turns[turnIdx].assistantText)
                    if phase == .thinking { phase = .speaking }
                case .sentence(let s):
                    let clean = AssistantTextSanitizer.sanitize(s)
                    // Skip TTS for sentences with no ASCII letters — Speaker uses
                    // en-US voice which goes silent on pure Chinese content. The
                    // dialogue should be all-English now (system prompt rule 3),
                    // but defensive against LLM lapses.
                    if clean.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) {
                        Speaker.enqueue(clean, locale: "en-US",
                                        rate: AVSpeechUtteranceDefaultSpeechRate)
                    }
                case .verdict(let v):
                    turns[turnIdx].verdict = v
                    applyVerdict(v)
                case .finished:
                    break
                }
            }
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "对话失败：\(error.localizedDescription)")
            return
        }

        turnIndex += 1
        // Hard cap on user turns. The opening turn (0) doesn't count toward the user budget.
        if !isOpening, turnIndex - 1 >= Self.maxTurns {
            await persistAndFinish()
        } else {
            phase = .idle
        }
    }

    /// Spec §6.4 session-Set + §6.5 realtime checklist + reactive feedback sound.
    private func applyVerdict(_ v: TurnVerdict) {
        var newlyCorrect: [String] = []
        for entry in v.verdicts {
            let normalized = entry.phrase   // verdict uses phraseRaw, which we set == phraseNormalized for now
            if entry.attempted && entry.correct {
                if !completedPhrases.contains(normalized) {
                    completedPhrases.insert(normalized)
                    newlyCorrect.append(normalized)
                }
            } else if entry.attempted && !entry.correct, !entry.note.isEmpty {
                perPhraseLastNote[normalized] = entry.note
            }
        }
        if !newlyCorrect.isEmpty { SoundFX.correct() }
    }

    /// End-of-session: write to ProductionProgressStore once, transition to done.
    private func persistAndFinish() async {
        guard !written else { return }
        written = true
        let nowSec = now()
        for p in phrases {
            let key = p.phraseNormalized
            if completedPhrases.contains(key) {
                progressStore.recordCorrect(phrase: key, at: nowSec)
            } else if let note = perPhraseLastNote[key] {
                progressStore.recordWrong(phrase: key, note: note, at: nowSec)
            }
            // Phrases neither correct nor noted → no store mutation.
        }
        Speaker.stop()
        phase = .done
    }
}

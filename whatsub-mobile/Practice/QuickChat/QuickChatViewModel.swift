import Foundation
import SwiftUI
import AVFoundation
import Speech
import UIKit

/// Testable seam: production wraps ConversationEngine; tests inject canned turns.
struct EngineDriver {
    /// Runs one turn (user input → TurnResult). Throws on network/format errors.
    let runTurn: (String) async throws -> ConversationEngine.TurnResult
    /// Raw `chat()` response from the most recent turn — surfaces what the
    /// LLM actually sent (incl. text VerdictParser routed away from dialog).
    /// Used by the VM's empty-response guard for a useful diagnostic.
    let lastRawText: () -> String

    /// Construct a real driver around a ConversationEngine.
    @MainActor
    static func live(_ engine: ConversationEngine) -> EngineDriver {
        EngineDriver(
            runTurn: { input in try await engine.runTurn(userInput: input) },
            lastRawText: { engine.lastTurnRawText }
        )
    }

    /// Test stub: a pre-canned list of TurnResults, popped in order.
    static func stub(turns: [ConversationEngine.TurnResult]) -> EngineDriver {
        final class Cursor { var remaining: [ConversationEngine.TurnResult]; init(_ t: [ConversationEngine.TurnResult]) { remaining = t } }
        let cursor = Cursor(turns)
        return EngineDriver(
            runTurn: { _ in
                if cursor.remaining.isEmpty { return ConversationEngine.TurnResult(dialog: "", verdict: nil) }
                return cursor.remaining.removeFirst()
            },
            lastRawText: { "" }
        )
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
    /// Per-session turn cap. nil = unlimited (only end on explicit close or
    /// LLM error). Set in init. Spec §9 #4 default = 5.
    let maxTurns: Int?

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
         maxTurns: Int? = 5,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.phrases = phrases
        self.suggestedTag = suggestedTag
        self.progressStore = progressStore
        self.driver = engineDriver
        self.maxTurns = maxTurns
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

        // Direct call. chat() either returns the full text or throws — no
        // AsyncThrowingStream nesting (build 222 probes proved that path
        // silently swallowed the await before it returned).
        let result: ConversationEngine.TurnResult
        do {
            result = try await driver.runTurn(userInput)
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "对话失败：\(error.localizedDescription)")
            return
        }

        // Apply verdict immediately if the LLM included one — affects
        // session checklist + completedPhrases set.
        if let v = result.verdict {
            turns[turnIdx].verdict = v
            applyVerdict(v)
        }

        // Typewriter display + TTS — chunk the dialog locally for the
        // streaming-display effect we used to get from the AsyncThrowingStream.
        let dialog = result.dialog
        if !dialog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if phase == .thinking { phase = .speaking }
            var displayed = ""
            var sentenceChunker = SentenceChunker()
            var idx = dialog.startIndex
            while idx < dialog.endIndex {
                let next = dialog.index(idx, offsetBy: 3, limitedBy: dialog.endIndex) ?? dialog.endIndex
                let small = String(dialog[idx..<next])
                displayed += small
                turns[turnIdx].assistantText = AssistantTextSanitizer.sanitize(displayed)
                for sentence in sentenceChunker.feed(small) {
                    let clean = AssistantTextSanitizer.sanitize(sentence)
                    if clean.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) {
                        Speaker.enqueue(clean, locale: "en-US",
                                        rate: AVSpeechUtteranceDefaultSpeechRate)
                    }
                }
                idx = next
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Flush any trailing partial sentence.
            for sentence in sentenceChunker.flush() {
                let clean = AssistantTextSanitizer.sanitize(sentence)
                if clean.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) {
                    Speaker.enqueue(clean, locale: "en-US",
                                    rate: AVSpeechUtteranceDefaultSpeechRate)
                }
            }
        }

        // Empty-response guard: stream completed but no dialogue text arrived.
        // Common causes: LLM returned empty, prompt rejected, parser swallowed
        // everything into verdict buffer (no <<<END>>>), sanitizer over-stripped.
        // Without this, vm.phase falls through to .idle and the UI shows
        // "稍等..." forever with no signal to the user. We surface the engine's
        // pre-parser raw text (everything the LLM actually emitted, including
        // text routed to the verdict buffer) so the cause is immediately visible.
        if turns[turnIdx].assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           turns[turnIdx].verdict == nil {
            var msg = isOpening
                ? "AI 没有给出开场。"
                : "AI 这一轮没有回复。"
            let raw = driver.lastRawText().trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                msg += " 服务端返回空内容，检查「我的 → LLM 设置」里的 API Key 和 baseUrl，或换个网络重试。"
            } else {
                // Tag obvious causes inline so the user / I can read the banner
                // and know what to fix.
                var diagnosis = ""
                if raw.contains("<<<VERDICT>>>") && !raw.contains("<<<END>>>") {
                    diagnosis = "[parser 卡在 verdict — LLM 发了 <<<VERDICT>>> 但没 <<<END>>>，可能 token 上限切断]"
                } else if raw.contains("<<<VERDICT>>>") && !raw.contains("\n") {
                    diagnosis = "[LLM 只输出了 verdict 块没写 dialog]"
                } else {
                    diagnosis = "[LLM 返回内容未走 dialog 路径，可能格式不符 prompt]"
                }
                msg += "\n\n\(diagnosis)\n\n[LLM 实际返回] \(raw.prefix(400))"
            }
            phase = .error(msg)
            return
        }

        turnIndex += 1
        // Hard cap on user turns. The opening turn (0) doesn't count toward the user budget.
        // nil maxTurns = unlimited (only end on explicit user close).
        if !isOpening, let cap = maxTurns, turnIndex - 1 >= cap {
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

import Foundation

/// Drives one QuickChat session: holds the running message history, calls
/// ChatCompletionsClient.stream for each turn, splits the assistant response
/// into dialog (→ TTS-friendly sentence stream + UI text) and verdict (→ parsed
/// TurnVerdict). Pure orchestration around already-tested helpers —
/// VerdictParser, SentenceChunker, ChatCompletionsClient.stream.
@MainActor
final class ConversationEngine {
    /// One event during a turn.
    enum Event {
        /// A complete sentence ready to send to TTS + append to UI.
        case sentence(String)
        /// Partial dialog text — accumulates into the assistant bubble. Caller
        /// may show it incrementally even before a sentence boundary.
        case dialogDelta(String)
        /// The verdict JSON has finished parsing. Fires at most once per turn,
        /// usually near the end of the stream.
        case verdict(TurnVerdict)
        /// Stream completed naturally. The full assistant text and (maybe) the
        /// verdict have already been emitted as separate events above.
        case finished
    }

    private let client: ChatCompletionsClient
    private(set) var messages: [ChatMessage]
    /// Pre-parser raw stream content from the most recent runTurn(). Captures
    /// EVERYTHING the LLM emitted, including content that VerdictParser routed
    /// into the verdict buffer (which never reaches the VM's dialogDelta path).
    /// Used by QuickChatViewModel's empty-response guard to surface what the
    /// LLM actually returned — without this, "empty assistantText + nil verdict"
    /// looks identical regardless of whether the LLM truly said nothing or said
    /// "<<<VERDICT>>>..." without a closing "<<<END>>>" (parser stays stuck in
    /// verdict phase, no dialog ever emitted).
    private(set) var lastTurnRawText: String = ""

    init(client: ChatCompletionsClient, systemPrompt: String) {
        self.client = client
        self.messages = [ChatMessage(role: "system", content: systemPrompt)]
    }

    /// Run one turn. `userInput` is "" for the opening turn (LLM opens scene).
    /// Yields events as they happen; throws on network/format errors.
    ///
    /// Spec §6.5.1: per-turn idle-chunk timeout. If 30 s pass between chunks
    /// we throw a `ChatCompletionsClient.LlmError.network("idle-chunk timeout")` so the view model
    /// can surface it as "再说一次或换文字" instead of waiting forever.
    func runTurn(userInput: String) -> AsyncThrowingStream<Event, Error> {
        if !userInput.isEmpty {
            messages.append(ChatMessage(role: "user", content: userInput))
        } else {
            // Opening turn — no user has spoken yet. DeepSeek (unlike OpenAI)
            // returns empty `content` when given system-only messages with no
            // user turn; the import flow works because it always has a real
            // user message with the subtitles. Inject a minimal English-only
            // kickoff so the model has something to respond to. We keep it in
            // English (no Chinese) because system rule 3 forbids Chinese in
            // dialog body — a Chinese user message would tempt the model to
            // open in Chinese too.
            messages.append(ChatMessage(role: "user", content: "Please start the conversation now."))
        }
        lastTurnRawText = ""
        let stream = client.stream(messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = VerdictParser()
                var chunker = SentenceChunker()
                var fullAssistantText = ""   // including verdict block — we replay full into history
                var lastChunkAt = Date()
                let idleLimit: TimeInterval = 30
                // Watchdog: cancels the iterator if no chunk arrives for idleLimit.
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if Date().timeIntervalSince(lastChunkAt) > idleLimit {
                            continuation.finish(throwing: ChatCompletionsClient.LlmError.network("idle-chunk timeout"))
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                do {
                    for try await raw in stream {
                        lastChunkAt = Date()
                        fullAssistantText += raw
                        self.lastTurnRawText = fullAssistantText
                        let out = parser.feed(raw)
                        if !out.dialogChunk.isEmpty {
                            continuation.yield(.dialogDelta(out.dialogChunk))
                            for sentence in chunker.feed(out.dialogChunk) {
                                continuation.yield(.sentence(sentence))
                            }
                        }
                        if let v = out.completedVerdict {
                            continuation.yield(.verdict(v))
                        }
                    }
                    // Stream done — drain any held buffers.
                    let tail = parser.finish()
                    if !tail.dialogChunk.isEmpty {
                        continuation.yield(.dialogDelta(tail.dialogChunk))
                        for sentence in chunker.feed(tail.dialogChunk) {
                            continuation.yield(.sentence(sentence))
                        }
                    }
                    for sentence in chunker.flush() {
                        continuation.yield(.sentence(sentence))
                    }
                    if let v = tail.completedVerdict {
                        continuation.yield(.verdict(v))
                    }
                    // Record the full assistant text (including verdict block) in
                    // history so the next turn's LLM sees its own previous output.
                    messages.append(ChatMessage(role: "assistant", content: fullAssistantText))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

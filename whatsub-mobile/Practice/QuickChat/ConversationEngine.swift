import Foundation

/// Drives one QuickChat session: holds the running message history, calls
/// ChatCompletionsClient.chat for each turn, splits the assistant response
/// into dialog (→ TTS-friendly sentence stream + UI text) and verdict (→ parsed
/// TurnVerdict). Pure orchestration around already-tested helpers —
/// VerdictParser, SentenceChunker, ChatCompletionsClient.chat.
///
/// History (the "why we now call chat() inline" story):
///   Builds 213-219 went through ChatCompletionsClient.stream(_:) — a wrapper
///   that called chat() then chunked the result. That added two layers of
///   AsyncThrowingStream (wrapper's + engine's). When chat() threw on empty
///   content, the throw should have propagated through both layers to the
///   VM's catch. In practice the VM kept seeing the empty-response GUARD fire
///   (raw text empty) instead of the catch — meaning the throw was being
///   swallowed somewhere in the nested stream/Task plumbing. After 7 build
///   iterations chasing it, the simplest fix was to delete the indirection:
///   call chat() directly here, capture the raw response BEFORE chunking,
///   then drive the parser/chunker in this same Task.
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
    /// Raw `chat()` response from the most recent turn — captured BEFORE the
    /// parser/chunker see it, so the VM's empty-response guard can show what
    /// the LLM actually returned even if the parser swallowed it.
    private(set) var lastTurnRawText: String = ""

    init(client: ChatCompletionsClient, systemPrompt: String) {
        self.client = client
        self.messages = [ChatMessage(role: "system", content: systemPrompt)]
    }

    /// Run one turn. `userInput` is "" for the opening turn (LLM opens scene).
    /// Yields events as they happen; throws on network/format errors.
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
        // PROBE: write a marker BEFORE the Task starts. If guard later shows
        // this marker, the Task code below never ran (or threw before
        // assignment). If guard shows ".../[after-chat]...", chat() returned.
        // If guard shows "" (totally empty), the VM is reading a DIFFERENT
        // engine instance — would indicate a wiring bug in EngineDriver.live.
        lastTurnRawText = "[probe-A: runTurn called, msg.count=\(messages.count), userInput=\"\(userInput)\"]"
        let messagesSnapshot = messages
        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                self.lastTurnRawText += " | [probe-B: Task started]"
                var parser = VerdictParser()
                var chunker = SentenceChunker()
                var fullAssistantText = ""
                do {
                    // Single non-streaming call. Capture full text BEFORE any
                    // parsing — guarantees lastTurnRawText is set even if the
                    // parser swallows everything or downstream throws.
                    self.lastTurnRawText += " | [probe-C: about to call chat()]"
                    let full = try await client.chat(messagesSnapshot)
                    self.lastTurnRawText = "[probe-D: chat() returned, len=\(full.count)] \(full)"
                    fullAssistantText = full

                    // Chunk locally (~3 chars per 20ms) so the UI gets the
                    // same incremental rendering it did when we had real SSE.
                    var idx = full.startIndex
                    while idx < full.endIndex {
                        let next = full.index(idx, offsetBy: 3, limitedBy: full.endIndex) ?? full.endIndex
                        let small = String(full[idx..<next])
                        let out = parser.feed(small)
                        if !out.dialogChunk.isEmpty {
                            continuation.yield(.dialogDelta(out.dialogChunk))
                            for sentence in chunker.feed(out.dialogChunk) {
                                continuation.yield(.sentence(sentence))
                            }
                        }
                        if let v = out.completedVerdict {
                            continuation.yield(.verdict(v))
                        }
                        idx = next
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }

                    // Drain held buffers (parser still in dialog phase /
                    // chunker holding a partial sentence).
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

                    self.messages.append(ChatMessage(role: "assistant", content: fullAssistantText))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    // Defensive + probe: preserve any existing marker so we
                    // can see WHERE in the flow the error landed.
                    self.lastTurnRawText += " | [probe-E: catch fired] \(error.localizedDescription)"
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

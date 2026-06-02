import Foundation

/// Drives one QuickChat session. Owns the message history, calls
/// ChatCompletionsClient.chat() for each turn, and parses the response into
/// dialog + verdict.
///
/// History (why the API shape is what it is):
///   v1 (builds 213-222) returned `AsyncThrowingStream<Event, Error>`. Probes
///   in build 222 proved that when `chat()` await suspended (or threw), the
///   stream got finished out-of-band before the Task's `continuation.finish()`
///   ran — the throw was swallowed and the VM saw an empty stream complete
///   normally. After 10 builds chasing this, the API shape itself was the
///   problem. v2 (build 223+) returns `async throws -> TurnResult` directly:
///   chat() throws → VM's catch fires, no stream plumbing in the middle.
///   The UI keeps the typewriter effect by chunking inside the VM after the
///   full text arrives.
@MainActor
final class ConversationEngine {
    /// Parsed result of one LLM turn.
    struct TurnResult {
        /// Pre-sanitized dialog text (everything BEFORE `<<<VERDICT>>>`).
        let dialog: String
        /// Parsed verdict, if the response contained a valid block.
        let verdict: TurnVerdict?
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

    /// Run one turn. Single linear async function — `chat()` is awaited
    /// directly so throws propagate through the catch on the call site.
    func runTurn(userInput: String) async throws -> TurnResult {
        if !userInput.isEmpty {
            messages.append(ChatMessage(role: "user", content: userInput))
        } else {
            // Opening turn — no user has spoken yet. DeepSeek returns empty
            // content for system-only messages with no user turn (the import
            // flow always has a real user message, which is why it works).
            // Inject a minimal English-only kickoff so the model has
            // something to respond to. Kept in English to avoid biasing the
            // model into a Chinese opener (system rule 3 forbids that).
            messages.append(ChatMessage(role: "user", content: "Please start the conversation now."))
        }
        lastTurnRawText = ""

        let full = try await client.chat(messages)
        lastTurnRawText = full
        messages.append(ChatMessage(role: "assistant", content: full))

        // One-shot parse of the full text — no streaming. The VM does the
        // typewriter chunking after we return.
        var parser = VerdictParser()
        var dialog = ""
        var verdict: TurnVerdict?
        let mid = parser.feed(full)
        dialog += mid.dialogChunk
        if let v = mid.completedVerdict { verdict = v }
        let tail = parser.finish()
        dialog += tail.dialogChunk
        if let v = tail.completedVerdict { verdict = v }

        return TurnResult(dialog: dialog, verdict: verdict)
    }
}

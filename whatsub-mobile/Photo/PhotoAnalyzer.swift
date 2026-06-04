import Foundation

/// Calls the configured LLM (managed relay by default, BYOK if user
/// flipped it off) to do TWO things in one round-trip from OCR text:
///
///   1. translate the entire English passage into natural Chinese
///   2. extract 3-8 phrases worth adding to the corpus, each with
///      meaning + usage hint + the sentence it lives in
///
/// One call (vs. two separate translate/extract calls) keeps the
/// month-quota math simple — the spike-derived ¥0.056/video number was
/// for a similar single-call shape. Failure modes are first-class: any
/// step throws → caller surfaces friendly Chinese error.
///
/// 2026-06-04 (拍照识别短语).
struct PhotoAnalyzer {

    let chat: ([ChatMessage]) async throws -> String

    /// Production wiring against the user's LLM config (resolves to the
    /// whatsub-managed relay when the toggle is on).
    static func live(settings: LlmSettings = LlmSettingsStore.load()) -> PhotoAnalyzer {
        let client = ChatCompletionsClient(settings: settings)
        return PhotoAnalyzer { messages in
            try await client.chat(messages)
        }
    }

    /// Outcome of one analyze call. Custom enum (not Swift's `Result`)
    /// because `Result<S, F>` requires `F: Error`; we want a plain
    /// Chinese string for the UI banner without inventing a one-case
    /// error type. Same shape used by `RoleplayScenarioClient`.
    enum AnalysisOutcome {
        case success(PhotoAnalysisResult)
        case failure(String)
    }

    /// `ocrText` is the joined OCR output (newline-separated lines).
    /// Returns `.success` with the parsed bundle or `.failure(zh msg)`
    /// when anything from network down to JSON shape goes wrong.
    func analyze(ocrText: String) async -> AnalysisOutcome {
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("OCR 文本为空,先拍一张含英文的清楚图片")
        }

        let messages = PhotoPrompts.messages(ocrText: trimmed)
        let raw: String
        do {
            raw = try await chat(messages)
        } catch let e as ChatCompletionsClient.LlmError {
            return .failure(e.errorDescription ?? "LLM 调用失败")
        } catch let e as APIError {
            return .failure(e.chinese)
        } catch {
            return .failure("LLM 调用失败:\(error.localizedDescription)")
        }

        return parse(raw)
    }

    /// Strip markdown fences + decode the JSON envelope. Same lenient
    /// pattern proven on `RoleplayScenarioClient`.
    func parse(_ raw: String) -> AnalysisOutcome {
        let body = Self.stripFences(raw)
        guard let data = body.data(using: .utf8) else {
            return .failure("LLM 返回无法解码")
        }
        do {
            let resp = try JSONDecoder().decode(WireResult.self, from: data)
            let phrases = resp.phrases.compactMap { $0.toModel() }
            let translation = resp.translation
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty translation OR zero phrases is still a usable
            // result — UI surfaces the path-specific copy.
            return .success(PhotoAnalysisResult(
                translation: translation,
                phrases: phrases
            ))
        } catch {
            let head = body.prefix(200)
            return .failure("JSON 解析失败 · head=\(head)")
        }
    }

    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        }
        if let lastFence = t.range(of: "```", options: .backwards) {
            t = String(t[..<lastFence.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - wire shapes (lenient decoders)

    private struct WireResult: Decodable {
        let translation: String
        let phrases: [WirePhrase]

        enum CodingKeys: String, CodingKey {
            case translation, phrases
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.translation = (try? c.decode(String.self, forKey: .translation)) ?? ""
            self.phrases = (try? c.decode([WirePhrase].self, forKey: .phrases)) ?? []
        }
    }

    private struct WirePhrase: Decodable {
        let phrase: String?
        let meaningZh: String?
        let usageNote: String?
        let contextSentence: String?

        enum CodingKeys: String, CodingKey {
            // Both camelCase (our convention) AND snake_case (LLM common
            // tendency for Chinese keys) get accepted.
            case phrase
            case meaningZh, meaning_zh
            case usageNote, usage_note
            case contextSentence, context_sentence
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.phrase = try? c.decode(String.self, forKey: .phrase)
            self.meaningZh = (try? c.decode(String.self, forKey: .meaningZh))
                ?? (try? c.decode(String.self, forKey: .meaning_zh))
            self.usageNote = (try? c.decode(String.self, forKey: .usageNote))
                ?? (try? c.decode(String.self, forKey: .usage_note))
            self.contextSentence = (try? c.decode(String.self, forKey: .contextSentence))
                ?? (try? c.decode(String.self, forKey: .context_sentence))
        }

        func toModel() -> PhotoPhrase? {
            guard let p = phrase?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !p.isEmpty else { return nil }
            return PhotoPhrase(
                id: UUID(),
                phrase: p,
                meaningZh: meaningZh?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                usageNote: usageNote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                contextSentence: contextSentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Prompt builder. Split out so the wording (which is the product
/// itself — same as QuickChat / Roleplay) is auditable in one place.
enum PhotoPrompts {
    static func messages(ocrText: String) -> [ChatMessage] {
        let system = """
        你是英语学习助手。下面是用户拍的一张图片(可能是杂志页、广告、书本片段、街边标语等)经过 OCR 识别得到的英文文本。

        请同时完成两件事:

        1. **整段翻译**:翻译成自然、贴近原意的中文。不要逐字直译。如果原文有标题、列表、段落,翻译里也保留对应的换行结构。

        2. **提取重点短语 3-8 条**:挑选对中文母语学习者最有价值的英文短语、搭配、习语、句型。
           - 优先短语动词(get away with, look forward to)、习语(piece of cake)、不直观的搭配(make a decision 而不是 do a decision)、地道句型
           - 排除过于基础的单词(eat, run, the)
           - 每条返回:
             - phrase: 原文中的短语,保留原始大小写
             - meaningZh: 简短中文释义
             - usageNote: 一句中文使用提示或例句
             - contextSentence: 短语所在的原文句子(完整)

        硬约束:
        - **只输出 JSON**,不要任何前后缀文字、不要 markdown 围栏。
        - 即使 OCR 文本不长(比如只有一句话),也要尝试提取 1-3 条短语;实在没有学习价值就返回 phrases: [] 空数组。
        - 翻译字段名是 `translation`(整段),短语数组字段名是 `phrases`。

        输出格式(exactly):
        {
          "translation": "...",
          "phrases": [
            {
              "phrase": "...",
              "meaningZh": "...",
              "usageNote": "...",
              "contextSentence": "..."
            }
          ]
        }
        """

        let user = """
        OCR 识别的英文文本:

        \(ocrText)

        现在请按上面的格式输出 JSON。
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }
}

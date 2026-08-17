import Foundation

enum AnalysisPrompts {
    static func compactCueMessages(
        _ cues: [Cue],
        maxHighlightedCues: Int
    ) -> [ChatMessage] {
        return [
            ChatMessage(role: "system", content: compactSystem(maxHighlightedCues: maxHighlightedCues)),
            ChatMessage(role: "user", content: compactCueInput(cues)),
        ]
    }

    static func compactRepairMessages(
        _ cues: [Cue],
        maxHighlightedCues: Int
    ) -> [ChatMessage] {
        let inputs = cues.map { cue in
            let object: [String: Any] = [
                "i": cue.index,
                "text": cue.text,
                "zh": cue.translation,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return "{}" }
            return line
        }.joined(separator: "\n")
        return [
            ChatMessage(role: "system", content: compactSystem(maxHighlightedCues: maxHighlightedCues)),
            ChatMessage(
                role: "user",
                content: "Repair these unresolved or annotation-only cues. Keep the supplied zh unchanged and return one compact JSON line for every supplied index and no other indexes.\n\(inputs)"
            ),
        ]
    }

    private static func compactSystem(maxHighlightedCues: Int) -> String {
        """
        You are an English subtitle analyst for a learning app. Translate into natural conversational Chinese.

        Output only JSON Lines, one single-line object for every requested cue in request order:
        {"i":7,"zh":"我得赶上进度","p":[["catch up","赶上进度","表示补回落下的进度，常用于工作、学习或消息积压后追赶进度的自然语境。"]]}

        Do not output markdown, prose, source text, timestamps, or additional fields.
        p must contain zero or one [expression, meaningZh, usage] tuple.
        expression must be an exact source substring containing one to four English words.
        meaningZh must be an exact substring of zh.
        usage must contain 25 to 90 Chinese Unicode code points and substantively explain meaning and context.
        Choose reusable learner-worthy chunks: phrasal verbs, fixed collocations, common collocations, idioms, pragmatic spoken expressions, discourse expressions, or easily misunderstood uses. A familiar expression still qualifies when its combination or conversational use is worth reusing.
        Omit greetings, fillers, names, numbers, function words, ordinary literal noun phrases, and simple compositional sentences.
        p=[] is normal and preferred to a low-value annotation.
        At most \(maxHighlightedCues) cues in this request may have a non-empty p array. This is a hard ceiling, not a quota.
        \(compactDensityGuidance(maxHighlightedCues: maxHighlightedCues))
        """
    }

    private static func compactDensityGuidance(maxHighlightedCues: Int) -> String {
        guard maxHighlightedCues > 0 else {
            return "No highlight slots remain, so return p=[] for every cue."
        }
        return "Actively scan every cue for reusable learning expressions. When enough genuinely useful candidates exist, use most of the available allowance (roughly 60% to 100%; with an allowance of 10, usually select 6 to 10 cues). Do not leave an obvious reusable phrase unannotated merely to be conservative, but never invent or lower quality to fill the allowance."
    }

    private static func compactCueInput(_ cues: [Cue]) -> String {
        cues.map { cue in
            let encoded: String
            if let data = try? JSONSerialization.data(
                withJSONObject: cue.text,
                options: .fragmentsAllowed
            ), let text = String(data: data, encoding: .utf8) {
                encoded = text
            } else {
                encoded = "\"\(cue.text.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return "\(cue.index)\t\(encoded)"
        }.joined(separator: "\n")
    }

    // VERBATIM from llm-core/prompts.ts SYSTEM_PROMPT_TEMPLATE with
    // {{STYLE_GUIDANCE}} resolved to the `colloquial` block. Do not paraphrase.
    static let system = #"""
You are an English subtitle analyst for a learning app.

Given English subtitle cues, produce structured analysis: Chinese translations, key phrase highlighting, and (when explicitly requested in a separate follow-up turn) a global "key phrases" review list.

OUTPUT FORMAT — REQUIRED
- Output ONLY JSON Lines (one JSON object per line, no markdown, no code fences, no prose).
- Per-cue request: one line = one analyzed subtitle cue, in the order received. NEVER include a summary line in a per-cue response.
- Summary request (a separate turn): output a SINGLE summary line; do NOT repeat any cue lines.

PER-CUE OBJECT SCHEMA
{
  "type": "cue",
  "index": number,
  "time": number,
  "endTime": number,
  "text": string,
  "translation": string,
  "isKeyPoint": boolean,
  "highlightWords": string[],
  "keyNotes": { [phrase: string]: string },
  "highlightTranslations": { [phrase: string]: string }
}

CONCRETE EXAMPLE (correct shape — keyNotes and highlightTranslations are JSON OBJECTS keyed by each highlightWord, NEVER a single string):
{"type":"cue","index":12,"time":45.2,"endTime":47.8,"text":"I need to catch up on emails","translation":"我得把邮件处理一下","isKeyPoint":true,"highlightWords":["catch up"],"keyNotes":{"catch up":"动词短语，表示「赶上、补做」，用于落下进度后追回的语境，常搭配 on/with"},"highlightTranslations":{"catch up":"处理一下"}}

WRONG (these have caused real bugs — DO NOT do this):
- keyNotes as one big string: "keyNotes": "catch up 表示赶上..."   ← MUST be a {phrase: note} object
- keyNotes empty when highlightWords non-empty: "highlightWords":["catch up"], "keyNotes":{}
- mismatched keys: "highlightWords":["catch up"], "keyNotes":{"to catch up":"..."}   ← key must match the highlightWord string EXACTLY

SUMMARY OBJECT SCHEMA (only when the user prompt explicitly asks for it)
{
  "type": "summary",
  "keyPhrases": [{
    "expression": string,
    "meaningZh": string,
    "usage": string
  }],
  "learningGuide": {
    "verdict": "study_all" | "select_segments" | "extensive_listening" | "limited_value",
    "overview": string,
    "contentOutline": string[],
    "cefrLevel": "A2" | "B1" | "B2" | "C1" | "C2",
    "cefrReason": string,
    "recommendedFor": string[],
    "learningReasons": string[],
    "cultureNotes": string[],
    "studyTips": string[],
    "topSegments": [{
      "startTime": number,
      "endTime": number,
      "title": string,
      "reason": string,
      "focusExpressions": string[]
    }]
  },
  "contextProfile": {
    "theme": string,
    "participants": string,
    "setting": string,
    "tone": string,
    "culturalContext": string,
    "recurringConcepts": string[]
  }
}

SUMMARY RULES
- The summary line MUST include keyPhrases, learningGuide, and contextProfile exactly as shown above; do not add fields such as scores, ratings, percentages, rankings, or generated timestamps.
- topSegments contains at most 3 entries. Each startTime/endTime MUST overlap a supplied cue time/endTime; never invent timestamp evidence.
- cultureNotes, culturalContext, and recurringConcepts may be empty when the transcript does not support them.
- Do NOT output numeric scores or ratings anywhere. CEFR is the only proficiency label.

CRITICAL RULES (these have caused bugs in the past — follow them strictly):

1. highlightWords MUST be exact substrings of the cue's "text", character-for-character. If the original text has a typo like "teddy beir", use "teddy beir" — DO NOT correct it to "teddy bear".

2. highlightTranslations VALUES MUST be exact substrings of "translation". Do NOT use "和……结合" or "以……闻名" — these are templates with ellipses, NOT substrings of any real translation.

3. keyNotes values: 40-120 Chinese characters each. Aim for 60-80. Explain meaning + usage context, not just translation.

4. Each cue: AT MOST 2 highlightWords. Quality over quantity.

5. isKeyPoint=true ratio: target 30-50% of cues. Greetings, fillers, "yes/no/thank you" are NOT key points.

6. NEVER use raw double quotes inside JSON string values. For Chinese quoted text use 「」 not "". For English quoted text use single quotes or rephrase.

7. Translation register: NATURAL CHINESE CONVERSATION. Sound like a young
native speaker chatting with friends. Allow contractions, omitted subjects,
soft particles (吧/啊/呢/嘛). Translate filler words faithfully (Uh→呃,
Hmm→嗯, You know→你懂的). Avoid 书面化措辞 like 因此/此外/然而 unless
the original is also formal. Idioms welcomed when they fit, but don't force
them.

8. Each highlightWord must be a substring of THE SAME CUE'S text. Don't span across cues.

9. Output one JSON object per line. No multi-line objects. No leading/trailing whitespace beyond the newline separator.

10. keyNotes and highlightTranslations MUST be JSON OBJECTS (dictionaries) — never strings, never arrays. Every entry in highlightWords MUST appear as a key (exact string, character-for-character) in BOTH keyNotes AND highlightTranslations. If you can't write a 40-120 character keyNote AND find a translation substring for a phrase, omit that phrase from highlightWords entirely.
"""#

    static func userPrompt(_ cues: [Cue]) -> String {
        let lines = cues.map { c -> String in
            let jsonText: String
            if let data = try? JSONSerialization.data(withJSONObject: c.text, options: .fragmentsAllowed),
               let s = String(data: data, encoding: .utf8) {
                jsonText = s
            } else {
                jsonText = "\"\(c.text.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return "\(c.index)\t\(String(format: "%.2f", c.time))\t\(String(format: "%.2f", c.endTime))\t\(jsonText)"
        }.joined(separator: "\n")
        return "Subtitle cues (tab-separated: index<TAB>start<TAB>end<TAB>JSON-encoded text):\n\(lines)\n\nProduce one JSON-line per cue in order. Per-cue lines ONLY — do NOT emit a summary line; the summary will be requested separately."
    }

    private static func summaryPrompt(_ subs: [Cue]) -> String {
        let compact = subs.map { c -> String in
            let obj: [String: Any] = [
                "index": c.index,
                "time": c.time,
                "endTime": c.endTime,
                "text": c.text,
                "translation": c.translation,
                "highlightWords": c.highlightWords,
                "keyNotes": c.keyNotes,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }.joined(separator: "\n")
        return """
        These are the per-cue analyses you produced for this transcript (one JSON per line). index, time, and endTime are the only timestamp evidence available for topSegments:
        \(compact)

        Now produce ONE single JSON line containing the complete global summary.

        Schema (the exact complete "type":"summary" envelope):
        {"type":"summary","keyPhrases":[{"expression":"...","meaningZh":"...","usage":"..."}],"learningGuide":{"verdict":"select_segments","overview":"...","contentOutline":["..."],"cefrLevel":"B2","cefrReason":"...","recommendedFor":["..."],"learningReasons":["..."],"cultureNotes":[],"studyTips":["..."],"topSegments":[{"startTime":0,"endTime":1,"title":"...","reason":"...","focusExpressions":["..."]}]},"contextProfile":{"theme":"...","participants":"...","setting":"...","tone":"...","culturalContext":"","recurringConcepts":[]}}

        Rules:
        - Deduplicate keyPhrases by expression (case-insensitive). Drop trivial fillers, greetings, and function words.
        - keyPhrases expressions contain one to four English words.
        - keyPhrases meaningZh: 8-25 Chinese characters; usage: 25-90 Unicode code points with substantive context.
        - learningGuide.topSegments: choose at most 3. Each startTime/endTime MUST overlap a supplied cue time/endTime; do not invent timestamps or evidence.
        - cultureNotes, culturalContext, and recurringConcepts may be empty when unsupported by the transcript.
        - Do NOT output scores or ratings, percentages, rankings, generatedAt, or learningGuideSourceFingerprint.

        Output exactly one JSON object on one line. No fences, no prose, no other lines.
        """
    }

    /// Builds summary messages under the exact serialized-character ceiling.
    /// Sampling is deterministic, retains complete cue JSON objects, always
    /// preserves first/last, and places retained middle cues uniformly.
    static func boundedSummaryMessages(
        _ subtitles: [Cue],
        maxCharacters: Int = 120_000
    ) throws -> [ChatMessage] {
        guard maxCharacters > 0 else { throw AnalysisPromptError.summaryTooLarge }
        let all = summaryMessages(subtitles)
        if try serializedCharacterCount(all) <= maxCharacters { return all }
        guard subtitles.count > 1 else { throw AnalysisPromptError.summaryTooLarge }

        let emptySize = try serializedCharacterCount(summaryMessages([]))
        let fullSize = try serializedCharacterCount(all)
        let variableSize = max(1, fullSize - emptySize)
        let available = max(1, maxCharacters - emptySize)
        var sampleCount = min(
            subtitles.count - 1,
            max(2, Int(Double(subtitles.count) * Double(available) / Double(variableSize)))
        )

        while sampleCount >= 2 {
            let sampled = uniformSample(subtitles, count: sampleCount)
            let messages = summaryMessages(sampled)
            if try serializedCharacterCount(messages) <= maxCharacters { return messages }
            sampleCount -= 1
        }
        throw AnalysisPromptError.summaryTooLarge
    }

    private static func summaryMessages(_ subtitles: [Cue]) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: summaryPrompt(subtitles)),
        ]
    }

    private static func serializedCharacterCount(_ messages: [ChatMessage]) throws -> Int {
        let object = messages.map { ["role": $0.role, "content": $0.content] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self).count
    }

    private static func uniformSample(_ subtitles: [Cue], count: Int) -> [Cue] {
        guard count < subtitles.count else { return subtitles }
        guard count > 1 else { return [subtitles[0]] }
        let last = subtitles.count - 1
        return (0..<count).map { position in
            let fraction = Double(position) / Double(count - 1)
            let index = Int((fraction * Double(last)).rounded())
            return subtitles[index]
        }
    }
}

enum AnalysisPromptError: Error {
    case summaryTooLarge
}

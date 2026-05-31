import Foundation

/// Strips LLM cruft from dialog text before it's shown in the chat bubble
/// or sent to TTS. Defensive — even after we hardened the system prompt
/// forbidding markdown and `<assistant>` prefixes, an LLM occasionally still
/// emits them. Pure function; safe to call on every chunk.
///
/// Behavior:
/// - Removes leading "<assistant>", "[assistant]", "<assistant ...>",
///   "Assistant:", "AI:", "Bot:" prefixes (case-insensitive, allows leading whitespace)
/// - Strips markdown emphasis markers: `**bold**` `*italic*` `__bold__` `_italic_`
///   keeping the inner text. Backticks `` `code` `` also stripped.
/// - Leaves all other content (including Chinese, punctuation, line breaks) intact.
enum AssistantTextSanitizer {

    /// One-shot sanitize: strip leading tag + all markdown emphasis from `text`.
    static func sanitize(_ text: String) -> String {
        var s = stripLeadingTagPrefix(text)
        s = stripMarkdownEmphasis(s)
        return s
    }

    /// Pattern: optional whitespace + opening bracket + assistant|ai|bot + optional
    /// attributes + closing bracket + optional `:` or `,` or whitespace.
    /// Matches `<assistant>`, `[assistant]`, `<assistant 自然...>`, `Assistant:`, `AI:`, etc.
    private static let leadingTagRegex: NSRegularExpression? = {
        let pattern = #"^\s*(?:[<\[]\s*(?:assistant|ai|bot)\b[^>\]]*[>\]]|(?:assistant|ai|bot)\s*[:：])\s*"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func stripLeadingTagPrefix(_ text: String) -> String {
        guard let re = leadingTagRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let trimmed = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return trimmed
    }

    /// Strips paired markdown markers, keeping the inner text. Handles ** __ * _ ` in that order.
    private static func stripMarkdownEmphasis(_ text: String) -> String {
        var s = text
        // Order matters: double-marker first so `**foo**` doesn't get mangled by the `*` pass.
        s = replaceMatched(s, opening: "**", closing: "**")
        s = replaceMatched(s, opening: "__", closing: "__")
        s = replaceMatched(s, opening: "*",  closing: "*")
        s = replaceMatched(s, opening: "_",  closing: "_")
        s = replaceMatched(s, opening: "`",  closing: "`")
        return s
    }

    /// Replaces every `opening...closing` pair in `text` with just the inner text.
    /// Non-greedy: `**a** **b**` becomes `a b`, not `a** **b`.
    private static func replaceMatched(_ text: String, opening: String, closing: String) -> String {
        guard text.contains(opening) else { return text }
        // Escape regex metachars in the markers.
        let openEsc = NSRegularExpression.escapedPattern(for: opening)
        let closeEsc = NSRegularExpression.escapedPattern(for: closing)
        // Inner: any char except newlines (so we don't strip across multiple lines).
        let pattern = "\(openEsc)([^\n\r]*?)\(closeEsc)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }
}

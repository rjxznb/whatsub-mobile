import Foundation

enum DeepGlossParserError: Error, LocalizedError, Equatable {
    case invalidJSON
    case invalidKeys
    case invalidField(String)
    case resultTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "AI 返回的深度解读不是有效 JSON，请重试。"
        case .invalidKeys:
            return "AI 返回的深度解读字段不完整，请重试。"
        case .invalidField:
            return "AI 返回的深度解读超出格式限制，请重试。"
        case .resultTooLarge:
            return "AI 返回的深度解读过长，请重试。"
        }
    }
}

enum DeepGlossSectionKind: Equatable {
    case contextualMeaning
    case toneAndSubtext
    case slangOrIdiom
    case culturalContext
    case naturalAlternatives
    case usageWarning
}

struct DeepGlossSection: Equatable {
    let kind: DeepGlossSectionKind
    let title: String
    let content: String
}

enum DeepGlossPresentation {
    static func visibleSections(for result: DeepGlossResult) -> [DeepGlossSection] {
        var sections = [
            DeepGlossSection(
                kind: .contextualMeaning,
                title: "此处含义",
                content: result.contextualMeaning
            ),
            DeepGlossSection(
                kind: .toneAndSubtext,
                title: "语气与言外之意",
                content: result.toneAndSubtext
            ),
        ]
        appendIfPresent(
            result.slangOrIdiom,
            kind: .slangOrIdiom,
            title: "俚语 / 习语",
            to: &sections
        )
        appendIfPresent(
            result.culturalContext,
            kind: .culturalContext,
            title: "文化语境",
            to: &sections
        )
        if !result.naturalAlternatives.isEmpty {
            sections.append(DeepGlossSection(
                kind: .naturalAlternatives,
                title: "自然替换表达",
                content: result.naturalAlternatives.joined(separator: "\n")
            ))
        }
        appendIfPresent(
            result.usageWarning,
            kind: .usageWarning,
            title: "使用提醒",
            to: &sections
        )
        return sections
    }

    private static func appendIfPresent(
        _ content: String,
        kind: DeepGlossSectionKind,
        title: String,
        to sections: inout [DeepGlossSection]
    ) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sections.append(DeepGlossSection(kind: kind, title: title, content: content))
    }
}

enum DeepGlossParser {
    private static let maximumSerializedBytes = 4_096
    private static let maximumStringCharacters = 500
    private static let maximumAlternatives = 5
    private static let exactKeys: Set<String> = [
        "contextualMeaning",
        "toneAndSubtext",
        "slangOrIdiom",
        "culturalContext",
        "naturalAlternatives",
        "usageWarning",
    ]

    static func parse(_ raw: String) throws -> DeepGlossResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              data.count <= maximumSerializedBytes else {
            if Data(trimmed.utf8).count > maximumSerializedBytes {
                throw DeepGlossParserError.resultTooLarge
            }
            throw DeepGlossParserError.invalidJSON
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw DeepGlossParserError.invalidJSON
        }
        guard Set(root.keys) == exactKeys else {
            throw DeepGlossParserError.invalidKeys
        }

        let contextualMeaning = try string(
            root,
            key: "contextualMeaning",
            allowsEmpty: false
        )
        let toneAndSubtext = try string(
            root,
            key: "toneAndSubtext",
            allowsEmpty: false
        )
        let slangOrIdiom = try string(root, key: "slangOrIdiom", allowsEmpty: true)
        let culturalContext = try string(root, key: "culturalContext", allowsEmpty: true)
        let usageWarning = try string(root, key: "usageWarning", allowsEmpty: true)
        guard let alternatives = root["naturalAlternatives"] as? [String],
              alternatives.count <= maximumAlternatives else {
            throw DeepGlossParserError.invalidField("naturalAlternatives")
        }
        for alternative in alternatives {
            let trimmedAlternative = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAlternative.isEmpty,
                  alternative.count <= maximumStringCharacters else {
                throw DeepGlossParserError.invalidField("naturalAlternatives")
            }
        }

        return DeepGlossResult(
            contextualMeaning: contextualMeaning,
            toneAndSubtext: toneAndSubtext,
            slangOrIdiom: slangOrIdiom,
            culturalContext: culturalContext,
            naturalAlternatives: alternatives,
            usageWarning: usageWarning
        )
    }

    private static func string(
        _ root: [String: Any],
        key: String,
        allowsEmpty: Bool
    ) throws -> String {
        guard let value = root[key] as? String,
              value.count <= maximumStringCharacters,
              allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepGlossParserError.invalidField(key)
        }
        return value
    }
}

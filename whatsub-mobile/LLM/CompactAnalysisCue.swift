import Foundation

struct CompactCueValidation {
    let cue: Cue
    let needsAnnotationRepair: Bool
}

final class CompactHighlightBudget {
    let limit: Int
    private(set) var used: Int

    init(limit: Int, used: Int = 0) {
        self.limit = max(0, limit)
        self.used = max(0, min(used, self.limit))
    }

    var remaining: Int { max(0, limit - used) }

    func apply(to result: CompactCueValidation) -> CompactCueValidation {
        guard result.cue.isKeyPoint else {
            if result.needsAnnotationRepair && remaining == 0 {
                return CompactCueValidation(cue: result.cue, needsAnnotationRepair: false)
            }
            return result
        }
        guard remaining > 0 else {
            var cue = result.cue
            cue.isKeyPoint = false
            cue.highlightWords = []
            cue.keyNotes = [:]
            cue.highlightTranslations = [:]
            return CompactCueValidation(cue: cue, needsAnnotationRepair: false)
        }
        used += 1
        return result
    }
}

enum CompactAnalysisCueError: Error {
    case invalidObject
    case invalidIndex
    case unknownIndex(Int)
    case missingTranslation(Int)
}

enum CompactAnalysisCue {
    private static let tokenPattern = #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#

    static func capacity(for cueCount: Int) -> Int {
        guard cueCount > 0 else { return 0 }
        return min(10, Int(ceil(Double(cueCount) / 5.0)))
    }

    static func validate(
        _ object: Any,
        requested: [Int: Cue]
    ) throws -> CompactCueValidation {
        guard let value = object as? [String: Any] else {
            throw CompactAnalysisCueError.invalidObject
        }
        let rawIndex = value["i"] ?? value["index"]
        guard let index = integer(rawIndex) else {
            throw CompactAnalysisCueError.invalidIndex
        }
        guard let source = requested[index] else {
            throw CompactAnalysisCueError.unknownIndex(index)
        }
        let rawTranslation = (value["zh"] as? String) ?? (value["translation"] as? String)
        let translation = rawTranslation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !translation.isEmpty else {
            throw CompactAnalysisCueError.missingTranslation(index)
        }

        var cue = Cue(
            index: source.index,
            time: source.time,
            endTime: source.endTime,
            text: source.text,
            translation: translation
        )
        let annotation = annotationCandidates(value)
        if let accepted = annotation.tuples.lazy.compactMap({
            validateTuple($0, source: source.text, translation: translation)
        }).first {
            cue.isKeyPoint = true
            cue.highlightWords = [accepted.expression]
            cue.keyNotes = [accepted.expression: accepted.usage]
            cue.highlightTranslations = [accepted.expression: accepted.meaning]
        }
        return CompactCueValidation(
            cue: cue,
            needsAnnotationRepair: annotation.intended && !cue.isKeyPoint
        )
    }

    private static func annotationCandidates(
        _ value: [String: Any]
    ) -> (tuples: [[Any]], intended: Bool) {
        if value.keys.contains("p") {
            guard let phrases = value["p"] as? [Any] else { return ([], true) }
            return (phrases.compactMap { $0 as? [Any] }, !phrases.isEmpty)
        }
        if let words = value["highlightWords"] as? [String], let expression = words.first {
            let notes = value["keyNotes"] as? [String: String]
            let meanings = value["highlightTranslations"] as? [String: String]
            guard let meaning = meanings?[expression], let note = notes?[expression] else {
                return ([], true)
            }
            return ([[expression, meaning, note]], true)
        }
        return ([], value["isKeyPoint"] as? Bool == true)
    }

    private static func validateTuple(
        _ tuple: [Any],
        source: String,
        translation: String
    ) -> (expression: String, meaning: String, usage: String)? {
        guard tuple.count >= 3,
              let expression = tuple[0] as? String,
              let meaning = tuple[1] as? String,
              let usage = tuple[2] as? String else { return nil }
        let phrase = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = usage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !translated.isEmpty,
              source.contains(phrase), translation.contains(translated),
              phraseTokenCount(phrase) >= 1, phraseTokenCount(phrase) <= 4,
              note.count >= 25, note.count <= 90 else { return nil }
        return (phrase, translated, note)
    }

    private static func phraseTokenCount(_ value: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return 0 }
        return regex.numberOfMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.rounded() == double ? number.intValue : nil
        }
        return nil
    }
}

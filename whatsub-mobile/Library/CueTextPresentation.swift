import Foundation

struct CueDisplayRun: Equatable {
    let text: String
    let highlightID: Int?
    let phrase: String?
}

struct CueTextPresentation: Equatable {
    let runs: [CueDisplayRun]

    var plainText: String {
        runs.map(\.text).joined()
    }

    func highlightPhrase(id: Int) -> String? {
        runs.first { $0.highlightID == id }?.phrase
    }

    static func make(text: String, highlights: [String]) -> CueTextPresentation {
        let normalizedText = normalizeWhitespace(text)
        let normalizedHighlights = highlights.map(normalizeWhitespace).filter { !$0.isEmpty }
        var runs: [CueDisplayRun] = []
        var nextHighlightID = 0
        var hasText = false
        var pendingSpace = false
        var pendingSpaceHighlightID: Int?

        for sourceRun in splitForHighlights(normalizedText, highlights: normalizedHighlights) {
            let highlightID: Int?
            let phrase: String?
            if sourceRun.highlight {
                highlightID = nextHighlightID
                phrase = sourceRun.text
                nextHighlightID += 1
            } else {
                highlightID = nil
                phrase = nil
            }

            var displayText = ""
            for character in sourceRun.text {
                if character.isWhitespace {
                    if hasText && !pendingSpace {
                        pendingSpace = true
                        pendingSpaceHighlightID = highlightID
                    }
                } else {
                    if pendingSpace {
                        if pendingSpaceHighlightID == highlightID {
                            displayText.append(" ")
                        } else {
                            runs.append(CueDisplayRun(text: " ", highlightID: nil, phrase: nil))
                        }
                        pendingSpace = false
                        pendingSpaceHighlightID = nil
                    }
                    displayText.append(character)
                    hasText = true
                }
            }

            if !displayText.isEmpty {
                runs.append(CueDisplayRun(text: displayText, highlightID: highlightID, phrase: phrase))
            }
        }

        return CueTextPresentation(runs: runs)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var normalized = ""
        var pendingSpace = false

        for character in text {
            if character.isWhitespace {
                pendingSpace = !normalized.isEmpty
            } else {
                if pendingSpace {
                    normalized.append(" ")
                    pendingSpace = false
                }
                normalized.append(character)
            }
        }

        return normalized
    }
}

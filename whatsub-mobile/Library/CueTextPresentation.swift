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
        var runs: [CueDisplayRun] = []
        var nextHighlightID = 0
        var hasText = false
        var pendingSpace = false
        var pendingSpaceHighlightID: Int?

        for sourceRun in splitForHighlights(text, highlights: highlights) {
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
}

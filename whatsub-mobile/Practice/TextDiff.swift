import Foundation

/// Token-level diff between the user's transcribed speech and the cue's
/// original English text. Both sides are normalized first (lowercased,
/// stripped to alphanumerics-only) so punctuation and capitalization don't
/// pollute the score.
///
/// The algorithm is a classic LCS (Longest Common Subsequence) over tokens:
/// any expected word that appears in the same relative order in the user's
/// speech is .match, the rest are .miss. Extra spoken words that aren't in
/// the expected text are .extra and rendered after the in-line tokens. This
/// gives reasonable feedback without false-flagging minor word swaps.
enum WordStatus: Equatable {
    case match
    case miss
    case extra // user spoke this; not in original
}

struct DiffToken: Identifiable, Equatable {
    let id: Int
    let word: String
    let status: WordStatus
}

struct DiffResult {
    /// Expected tokens annotated as match/miss in the original order.
    let expected: [DiffToken]
    /// Extra tokens the user spoke that weren't matched.
    let extras: [DiffToken]
    /// matchCount / expectedCount, 0...100.
    let score: Int
}

enum TextDiff {
    static func diff(expected: String, actual: String) -> DiffResult {
        let exp = tokenize(expected)
        let act = tokenize(actual)
        if exp.isEmpty {
            return DiffResult(expected: [], extras: [], score: 0)
        }
        // LCS table — exp.count × act.count. Small (cues are < ~20 words).
        let lcs = lcsMatches(exp, act)
        // expectedAnnotated: every exp word with match/miss based on whether
        // it was in the LCS match set.
        var expectedAnnotated: [DiffToken] = []
        var matchedActIndices = Set<Int>()
        for (i, w) in exp.enumerated() {
            let status: WordStatus
            if let actIdx = lcs[i] {
                status = .match
                matchedActIndices.insert(actIdx)
            } else {
                status = .miss
            }
            expectedAnnotated.append(DiffToken(id: i, word: w, status: status))
        }
        // extras: actual words not consumed by an LCS match
        var extras: [DiffToken] = []
        var id = exp.count
        for (i, w) in act.enumerated() where !matchedActIndices.contains(i) {
            extras.append(DiffToken(id: id, word: w, status: .extra))
            id += 1
        }
        let matchCount = expectedAnnotated.filter { $0.status == .match }.count
        let score = Int(round(Double(matchCount) / Double(exp.count) * 100))
        return DiffResult(expected: expectedAnnotated, extras: extras, score: score)
    }

    /// Normalize text → array of lowercase alphanumeric word-tokens.
    private static func tokenize(_ s: String) -> [String] {
        let lowered = s.lowercased()
        let chars = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(chars).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Classic LCS table. Returns an array mapping each expected index → the
    /// matched actual index (or nil if this expected token wasn't matched).
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [Int?] {
        let m = a.count
        let n = b.count
        if m == 0 || n == 0 { return Array(repeating: nil, count: m) }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // Backtrack to extract the matched pair indices.
        var matches: [Int?] = Array(repeating: nil, count: m)
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                matches[i - 1] = j - 1
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches
    }
}

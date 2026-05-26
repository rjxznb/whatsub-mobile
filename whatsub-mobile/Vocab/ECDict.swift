import Foundation

/// Offline EN→CN definitions, backed by the bundled `ecdict-cn.json` — an ECDICT
/// top-frequency subset (`{word: 简明中文释义}`). Loaded lazily on first use.
/// Single-word level; phrases/idioms fall back to the AI button in CollectSheet.
final class ECDict {
    static let shared = ECDict()
    private lazy var map: [String: String] = ECDict.loadBundled()

    /// CN definition for a single word (lowercased + edge-punctuation trimmed), with
    /// a cheap morphology fallback (-s/-es/-ies/-ed/-ing). nil if not found.
    func define(_ word: String) -> String? {
        let w = ECDict.normalize(word)
        guard !w.isEmpty else { return nil }
        if let d = map[w] { return d }
        for cand in ECDict.stems(of: w) where map[cand] != nil {
            return map[cand]
        }
        return nil
    }

    static func normalize(_ word: String) -> String {
        let trim = CharacterSet(charactersIn: ".,!?;:\"'()[]…—-")
        return word.lowercased().trimmingCharacters(in: trim)
    }

    /// Cheap morphological candidates for a common inflected form (not a real
    /// lemmatizer — just the high-frequency suffix rules).
    static func stems(of w: String) -> [String] {
        var out: [String] = []
        if w.hasSuffix("ies"), w.count > 4 { out.append(String(w.dropLast(3)) + "y") }   // studies→study
        if w.hasSuffix("es"), w.count > 3 { out.append(String(w.dropLast(2))) }            // goes→go
        if w.hasSuffix("s"), w.count > 2 { out.append(String(w.dropLast(1))) }             // cats→cat
        if w.hasSuffix("ing"), w.count > 5 {
            out.append(String(w.dropLast(3)))                                              // going→go
            out.append(String(w.dropLast(3)) + "e")                                        // making→make
        }
        if w.hasSuffix("ed"), w.count > 3 {
            out.append(String(w.dropLast(2)))                                              // worked→work
            out.append(String(w.dropLast(1)))                                              // liked→like
        }
        return out
    }

    private static func loadBundled() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "ecdict-cn", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }
}

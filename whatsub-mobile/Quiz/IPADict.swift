import Foundation

/// Offline IPA (en-US) lookup, backed by the bundled `ipa-en-us.json` (~125k words,
/// the same dict the desktop app uses). Loaded lazily on first use.
final class IPADict {
    static let shared = IPADict()
    private lazy var map: [String: String] = IPADict.loadBundled()

    /// IPA for a phrase: lowercased per-word lookup, joined by spaces. nil if no word found.
    func lookup(_ phrase: String) -> String? {
        IPADict.assemble(phrase: phrase) { self.map[$0] }
    }

    /// Pure + testable: split on whitespace, trim edge punctuation, lowercase,
    /// look up each word, join the found ones. nil if none found.
    static func assemble(phrase: String, lookup: (String) -> String?) -> String? {
        let trim = CharacterSet(charactersIn: ".,!?;:\"()[]")
        let words = phrase.lowercased()
            .split { $0 == " " || $0 == "\t" || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty }
        let parts = words.compactMap(lookup)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func loadBundled() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "ipa-en-us", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }
}

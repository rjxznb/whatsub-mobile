import Foundation

// ----- Auth -----

struct SendCodeRequest: Encodable { let email: String }

struct VerifyCodeRequest: Encodable {
    let email: String
    let code: String
}

struct VerifyCodeResponse: Decodable {
    let sessionToken: String
    let expiresAt: Int64
}

struct MeResponse: Decodable {
    let email: String
    let hasActiveLicense: Bool
    let isAdmin: Bool?
    // Subscription entitlement (whatSub Pro). OPTIONAL: an older backend omits it,
    // so decoding must not fail. Legacy `iosBuyout` + `trialExpiresAt` fields the
    // backend may still emit are silently ignored — the 2026-05-28 policy shift
    // removed the ¥18 buyout SKU and the 1-day trial concept; iOS has only two
    // modes now (免费版 / 已订阅 Pro).
    let iosSubActive: Bool?
    let subProductId: String?
}

/// POST body for /api/license/iap/verify.
struct VerifyPurchaseRequest: Encodable { let signedTransactionInfo: String }

/// Generic `{ ok: true }` or `{ error: "..." }` envelope used by several routes.
struct OkResponse: Decodable { let ok: Bool? }
struct ErrorResponse: Decodable { let error: String? }
/// 403 quota_exceeded body from POST /sync and /import-queue: { error, used, limit }.
struct QuotaErrorBody: Decodable { let error: String?; let used: Int?; let limit: Int? }

// ----- Library -----

struct LibraryListItem: Decodable, Identifiable {
    let id: String
    let youtubeId: String
    let sourceUrl: String
    let title: String
    let durationSec: Int?
    let thumbUrl: String?
    let syncedAt: Int64
    /// Present (signed CDN URL) when the video is self-hosted on OSS → plays
    /// in-app via AVPlayer with NO VPN. nil = YouTube-embed-only → needs VPN.
    let videoUrl: String?
    /// Signed CDN URL for the audio-only .m4a sidecar (since 2026-05-29
    /// desktop sync). Practice modes prefer this over videoUrl — ~30× less
    /// bandwidth per cue. nil for entries synced before the sidecar feature
    /// (iOS practice falls back to videoUrl via the shared player).
    let audioUrl: String?
}

struct LibraryListResponse: Decodable {
    let entries: [LibraryListItem]
}

/// A CodingKey that accepts any string — lets us iterate a JSON object's keys
/// without a fixed schema (used for the lenient string-map decode below).
private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One subtitle cue from analysisJson.subtitles — already bilingual + highlighted.
struct Cue: Decodable, Identifiable {
    var id: Int { index }
    /// Synthesized at decode time (array position) since the JSON has no id.
    var index: Int = 0

    let time: Double
    let endTime: Double
    let text: String          // English
    let translation: String   // Chinese
    let isKeyPoint: Bool
    let highlightWords: [String]
    let keyNotes: [String: String]
    let highlightTranslations: [String: String]

    enum CodingKeys: String, CodingKey {
        case time, endTime, text, translation, isKeyPoint
        case highlightWords, keyNotes, highlightTranslations
    }

    /// Memberwise init for building a Cue from extracted caption data (no LLM yet).
    /// translation / highlights are empty until AnalysisEngine fills them in.
    init(index: Int, time: Double, endTime: Double, text: String) {
        self.index = index
        self.time = time
        self.endTime = endTime
        self.text = text
        self.translation = ""
        self.isKeyPoint = false
        self.highlightWords = []
        self.keyNotes = [:]
        self.highlightTranslations = [:]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        isKeyPoint = try c.decodeIfPresent(Bool.self, forKey: .isKeyPoint) ?? false
        highlightWords = try c.decodeIfPresent([String].self, forKey: .highlightWords) ?? []
        // The desktop pipeline occasionally emits a non-string value inside
        // keyNotes (e.g. a nested `highlightTranslations` object got merged in),
        // which would make a strict `[String: String]` decode throw and fail the
        // ENTIRE entry. Decode leniently: keep only string values, skip the rest.
        keyNotes = Cue.lenientStringMap(c, .keyNotes)
        highlightTranslations = Cue.lenientStringMap(c, .highlightTranslations)
    }

    /// Decode a JSON object as `[String: String]`, keeping only entries whose
    /// value is actually a string. Non-string values (nested objects, numbers,
    /// null) are silently dropped instead of failing the whole decode.
    private static func lenientStringMap(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [String: String] {
        guard let nested = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: key) else {
            return [:]
        }
        var out: [String: String] = [:]
        for k in nested.allKeys {
            if let s = try? nested.decode(String.self, forKey: k) {
                out[k.stringValue] = s
            }
        }
        return out
    }
}

struct KeyPhrase: Decodable {
    let expression: String
    let meaningZh: String
    let usage: String
}

struct AnalysisJson: Decodable {
    let subtitles: [Cue]
    let keyPhrases: [KeyPhrase]

    enum CodingKeys: String, CodingKey { case subtitles, keyPhrases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var subs = try c.decodeIfPresent([Cue].self, forKey: .subtitles) ?? []
        for i in subs.indices { subs[i].index = i }
        subtitles = subs
        keyPhrases = try c.decodeIfPresent([KeyPhrase].self, forKey: .keyPhrases) ?? []
    }

    /// Build from parts (used by AnalysisEngine after assembling batch results).
    /// Skips the JSON round-trip that `init(from:)` requires.
    static func assembled(subtitles: [Cue], keyPhrases: [KeyPhrase]) -> AnalysisJson {
        // Use the Decodable init path by encoding + decoding, so index re-numbering
        // stays in one place (init(from:) sets index = array position).
        // Fast path: build via private memberwise init instead.
        return AnalysisJson(_subtitles: subtitles, _keyPhrases: keyPhrases)
    }

    // Private memberwise init for assembled(). The caller (AnalysisEngine) has
    // already re-indexed, so we store as-is without JSON round-trip.
    private init(_subtitles: [Cue], _keyPhrases: [KeyPhrase]) {
        subtitles = _subtitles
        keyPhrases = _keyPhrases
    }
}

struct ImportQueueItem: Decodable, Identifiable {
    let id: String
    let url: String
    let status: String        // pending | processing | done | failed
    let error: String?
    let createdAt: Int64
    let updatedAt: Int64
}

struct ImportQueueListResponse: Decodable {
    let items: [ImportQueueItem]
}

struct LibraryQuota: Decodable {
    let used: Int
    let limit: Int
}

/// Personal-corpus quota. `limit` is server-authoritative (hasActiveSubscription
/// ? 1000 : 50), so it reflects cross-platform (Alipay/web) subscriptions that an
/// iOS-only `iosSubActive` check would miss.
struct CorpusQuota: Decodable {
    let used: Int
    let limit: Int
}

struct LibraryEntryDetail: Decodable {
    let id: String
    let youtubeId: String
    let title: String
    let durationSec: Int?
    let transcriptSrt: String?
    let analysisJson: AnalysisJson
    let videoUrl: String?
    /// Signed CDN URL for the audio-only .m4a sidecar. Practice modes
    /// (跟读/听抄) prefer this over videoUrl. nil = older entry, falls back.
    let audioUrl: String?
}

// ----- Corpus -----

/// GET /api/corpus/versions → { mine, public }. "public" is a Swift keyword,
/// so it's decoded into `publicVersion`.
struct CorpusVersions: Decodable {
    let mine: Int
    let publicVersion: Int
    enum CodingKeys: String, CodingKey {
        case mine
        case publicVersion = "public"
    }
}

struct CorpusTag: Codable, Identifiable {
    var id: String { tag }
    let tag: String
    let count: Int
}
struct CorpusTagsResponse: Decodable { let tags: [CorpusTag] }

/// A contribution's source. JSONB written by the plugin — camelCase on the wire
/// in BOTH /mine and /lookup. Only `youtube` carries `timestampSec`.
struct CorpusSource: Codable {
    let kind: String   // youtube | webpage | pdf | curator
    let url: String
    let title: String?
    let timestampSec: Double?
}

/// /browse phrase — snake_case, phrase-level (no per-instance source).
struct BrowsePhrase: Codable, Identifiable {
    var id: String { phraseNormalized }
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let tags: [String]
    enum CodingKeys: String, CodingKey {
        case phraseNormalized = "phrase_normalized"
        case phraseRaw = "phrase_raw"
        case meaningZh = "meaning_zh"
        case usageNote = "usage_note"
        case tags
    }
}
struct BrowseResponse: Decodable { let phrases: [BrowsePhrase]; let total: Int }

/// /mine item — camelCase, instance-level (one row per save).
struct MineItem: Codable, Identifiable {
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let contextSentence: String
    let source: CorpusSource
    let contributedAt: Int64
    let tags: [String]
    var id: String { "\(phraseNormalized)#\(contributedAt)" }
}
struct MineResponse: Decodable { let items: [MineItem]; let total: Int }

/// /lookup contribution — snake_case row; its `source` JSONB is camelCase.
struct CorpusContribution: Codable, Identifiable {
    let id: Int
    let contextSentence: String
    let source: CorpusSource
    let contributedAt: Int64
    enum CodingKeys: String, CodingKey {
        case id
        case contextSentence = "context_sentence"
        case source
        case contributedAt = "contributed_at"
    }
}

/// /lookup phrase — snake_case; `tags` arrives wrapped as `{ list: [...] }`.
struct LookupPhrase: Codable {
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let tags: [String]
    enum CodingKeys: String, CodingKey {
        case phraseRaw = "phrase_raw"
        case meaningZh = "meaning_zh"
        case usageNote = "usage_note"
        case tags
    }
    private struct TagWrapper: Codable { let list: [String]? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phraseRaw = try c.decodeIfPresent(String.self, forKey: .phraseRaw) ?? ""
        meaningZh = try c.decodeIfPresent(String.self, forKey: .meaningZh)
        usageNote = try c.decodeIfPresent(String.self, forKey: .usageNote)
        let wrapped = try c.decodeIfPresent(TagWrapper.self, forKey: .tags)
        tags = wrapped?.list ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phraseRaw, forKey: .phraseRaw)
        try c.encodeIfPresent(meaningZh, forKey: .meaningZh)
        try c.encodeIfPresent(usageNote, forKey: .usageNote)
        try c.encode(TagWrapper(list: tags), forKey: .tags) // re-wrap so init(from:) reads it back
    }
}
struct LookupResponse: Codable {
    let phrase: LookupPhrase
    let publicContributions: [CorpusContribution]
    let personalContributions: [CorpusContribution]
}

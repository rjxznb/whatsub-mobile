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
    // Combined, server-authoritative entitlement: true when the user has ANY
    // active subscription — iOS StoreKit (`iosSubActive`) OR a website/plugin
    // Alipay 时段会员 (`web_subscriptions`). A user who subscribed on the web
    // and logs in here with the same email has iosSubActive=false but
    // hasActiveSubscription=true. Drives the "已订阅 Pro" badge and suppresses
    // the in-app upsell, so a cross-platform subscriber isn't mislabeled 免费版
    // or tempted into a second StoreKit charge. Optional — an older backend
    // that omits it decodes to nil (treated as not-subscribed).
    let hasActiveSubscription: Bool?
    /// Server-authoritative Library caps for this account. Optional keeps
    /// decoding compatible with older backends; an unknown limit deliberately
    /// skips client-side replacement preflight and leaves final validation to
    /// the backend/desktop pipeline.
    let libraryLimits: LibraryLimits?
}

/// POST body for /api/license/iap/verify.
struct VerifyPurchaseRequest: Encodable { let signedTransactionInfo: String }

/// Generic `{ ok: true }` or `{ error: "..." }` envelope used by several routes.
struct OkResponse: Decodable { let ok: Bool? }
struct ErrorResponse: Decodable { let error: String? }
/// 403 quota_exceeded body from POST /sync and /import-queue: { error, used, limit }.
struct QuotaErrorBody: Decodable { let error: String?; let used: Int?; let limit: Int? }
/// 429 rate_limited body from POST /api/license/auth/{send,verify}-code.
/// Wire contract: src/lib/authRateLimit.ts in whatsub-license.
struct RateLimitErrorBody: Decodable {
    let error: String        // always "rate_limited"
    let scope: String        // "email-minute" | "email-hour" | "ip-hour"
    let retryAfterSec: Int   // also echoed in the Retry-After header
    let message: String      // server-supplied zh-Hans message
}

struct ManagedAnalysisErrorBody: Decodable {
    let error: String?
    let retryable: Bool?
    let diagnosticCode: String?
    let diagnosticId: String?
}

struct ManagedAnalysisJobsResponse: Decodable {
    let jobs: [ManagedAnalysisJob]
}

// ----- Pro AI feature trials -----

struct FeatureEntitlementsResponse: Codable, Equatable {
    let isPro: Bool
    let features: [FeatureKey: FeatureTrialState]

    init(isPro: Bool, features: [FeatureKey: FeatureTrialState]) {
        self.isPro = isPro
        self.features = features
    }

    private enum CodingKeys: String, CodingKey { case isPro, features }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPro = try container.decode(Bool.self, forKey: .isPro)
        let wire = try container.decode([String: FeatureTrialState].self, forKey: .features)
        features = Dictionary(uniqueKeysWithValues: wire.compactMap { key, value in
            FeatureKey(rawValue: key).map { ($0, value) }
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPro, forKey: .isPro)
        let wire = Dictionary(uniqueKeysWithValues: features.map { ($0.key.rawValue, $0.value) })
        try container.encode(wire, forKey: .features)
    }
}

struct FeatureStartResponse: Codable, Equatable {
    let featureKey: FeatureKey
    let access: FeatureAccessKind
    let state: FeatureTrialState
}

struct FeatureEventRequest: Encodable {
    let event: FeatureFunnelEvent
}

// ----- Library -----

/// Codable (not just Decodable) since 2026-07-05: rows are persisted into
/// `Caches/library_cache.json` by LibraryCache for the cache-first list.
/// NOTE: a cached `videoUrl`/`audioUrl` is a signed CDN URL with a 2h TTL —
/// stale copies are fine because playback always re-fetches `/entry/:id`
/// for fresh URLs; the list only uses videoUrl's nil-ness (VPN badge).
struct LibraryListItem: Codable, Identifiable {
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

/// `GET /api/library/version` — cheap per-owner fingerprint
/// (MAX(synced_at)+COUNT(*), same shape as the corpus /versions numbers).
/// The list cache compares it by equality; any sync/edit/delete shifts it.
struct LibraryVersionResponse: Decodable {
    let version: Int
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
struct Cue: Codable, Identifiable {
    var id: Int { index }
    /// Synthesized at decode time (array position) since the JSON has no id.
    var index: Int = 0

    let time: Double
    let endTime: Double
    // 2026-06-18: text fields became `var` for the in-app subtitle editor.
    // time/endTime stay `let` — the editor deliberately doesn't expose
    // timestamp adjustment (high risk of breaking alignment, low value vs.
    // just deleting/re-creating a cue). highlight* go mutable so editing
    // text can clear stale AI markers in the same struct.
    var text: String          // English
    var translation: String   // Chinese
    var isKeyPoint: Bool
    var highlightWords: [String]
    var keyNotes: [String: String]
    var highlightTranslations: [String: String]

    enum CodingKeys: String, CodingKey {
        case index
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

    /// Memberwise init carrying the translation too — used by the subtitle
    /// editor's merge / split operations (2026-06-18). highlights are still
    /// empty by default since edits invalidate any prior AI markers.
    init(index: Int, time: Double, endTime: Double, text: String, translation: String) {
        self.index = index
        self.time = time
        self.endTime = endTime
        self.text = text
        self.translation = translation
        self.isKeyPoint = false
        self.highlightWords = []
        self.keyNotes = [:]
        self.highlightTranslations = [:]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `index` is synthesized at AnalysisJson decode time (array position) — JSON
        // from the LLM pipeline doesn't carry it. Decode it here for completeness
        // (cache round-trips via the analysisJson string preserve it), but note that
        // `AnalysisJson.init(from:)` reassigns `subs[i].index = i` AFTER decode so
        // the array-position invariant always wins regardless of what's on disk.
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(time, forKey: .time)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(text, forKey: .text)
        try c.encode(translation, forKey: .translation)
        try c.encode(isKeyPoint, forKey: .isKeyPoint)
        try c.encode(highlightWords, forKey: .highlightWords)
        try c.encode(keyNotes, forKey: .keyNotes)
        try c.encode(highlightTranslations, forKey: .highlightTranslations)
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

struct KeyPhrase: Codable {
    let expression: String
    let meaningZh: String
    let usage: String
}

struct AnalysisJson: Decodable {
    let subtitles: [Cue]
    let keyPhrases: [KeyPhrase]
    let learningGuide: LearningGuide?
    let contextProfile: VideoContextProfile?
    let learningGuideSourceFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case subtitles, keyPhrases
        case learningGuide, contextProfile, learningGuideSourceFingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var subs = try c.decodeIfPresent([Cue].self, forKey: .subtitles) ?? []
        for i in subs.indices { subs[i].index = i }
        subtitles = subs
        keyPhrases = try c.decodeIfPresent([KeyPhrase].self, forKey: .keyPhrases) ?? []
        learningGuide = try c.decodeIfPresent(LearningGuide.self, forKey: .learningGuide)
        contextProfile = try c.decodeIfPresent(VideoContextProfile.self, forKey: .contextProfile)
        learningGuideSourceFingerprint = try c.decodeIfPresent(
            String.self,
            forKey: .learningGuideSourceFingerprint
        )
    }

    /// Build from parts (used by AnalysisEngine after assembling batch results).
    /// Skips the JSON round-trip that `init(from:)` requires.
    static func assembled(
        subtitles: [Cue],
        keyPhrases: [KeyPhrase],
        learningGuide: LearningGuide? = nil,
        contextProfile: VideoContextProfile? = nil,
        learningGuideSourceFingerprint: String? = nil
    ) -> AnalysisJson {
        // Use the Decodable init path by encoding + decoding, so index re-numbering
        // stays in one place (init(from:) sets index = array position).
        // Fast path: build via private memberwise init instead.
        return AnalysisJson(
            _subtitles: subtitles,
            _keyPhrases: keyPhrases,
            learningGuide: learningGuide,
            contextProfile: contextProfile,
            learningGuideSourceFingerprint: learningGuideSourceFingerprint
        )
    }

    // Private memberwise init for assembled(). The caller (AnalysisEngine) has
    // already re-indexed, so we store as-is without JSON round-trip.
    private init(
        _subtitles: [Cue],
        _keyPhrases: [KeyPhrase],
        learningGuide: LearningGuide?,
        contextProfile: VideoContextProfile?,
        learningGuideSourceFingerprint: String?
    ) {
        subtitles = _subtitles
        keyPhrases = _keyPhrases
        self.learningGuide = learningGuide
        self.contextProfile = contextProfile
        self.learningGuideSourceFingerprint = learningGuideSourceFingerprint
    }
}

struct ImportQueueItem: Decodable, Identifiable {
    let id: String
    let url: String
    /// `import` for ordinary queue work; `replace` atomically fills the OSS
    /// video of an existing Library entry. Defaults to import for queue rows
    /// returned by older backend versions.
    let mode: String
    let targetLibraryEntryId: String?
    let status: String        // pending | processing | done | failed
    let error: String?
    let createdAt: Int64
    let updatedAt: Int64

    private enum CodingKeys: String, CodingKey {
        case id, url, mode, targetLibraryEntryId, status, error, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "import"
        targetLibraryEntryId = try c.decodeIfPresent(String.self, forKey: .targetLibraryEntryId)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
    }
}

struct ImportQueueListResponse: Decodable {
    let items: [ImportQueueItem]
    /// Seconds since the user's DESKTOP client last touched the queue
    /// (its 30s poll / claim / status writes). nil = never seen OR an old
    /// backend without the field. Drives the "桌面端似乎不在线" banner.
    let desktopSeenSecondsAgo: Int?
}

/// `POST /api/library/import-queue` response. desktopSeenSecondsAgo: see
/// ImportQueueListResponse — nil-tolerant for old backends.
struct EnqueueImportResponse: Decodable {
    let id: String
    let desktopSeenSecondsAgo: Int?
    /// The backend returns the existing row's state when enqueue deduplicates.
    /// Optional keeps compatibility with an older backend during rollout.
    let status: String?
}

enum DesktopPresence {
    /// Desktop polls every 30 seconds. Four missed polls means offline;
    /// exactly 120 seconds is still considered online to match ImportView.
    static func isOffline(secondsAgo: Int?) -> Bool {
        guard let secondsAgo else { return true }
        return secondsAgo > 120
    }
}

enum DesktopReplacementActiveStatus: Equatable {
    case pending
    case processing
}

enum DesktopReplacementQueue {
    static func activeStatus(
        in items: [ImportQueueItem],
        targetLibraryEntryId: String
    ) -> DesktopReplacementActiveStatus? {
        let matching = items.filter {
            $0.mode == "replace" && $0.targetLibraryEntryId == targetLibraryEntryId
        }
        if matching.contains(where: { $0.status == "processing" }) { return .processing }
        if matching.contains(where: { $0.status == "pending" }) { return .pending }
        return nil
    }
}

/// Exact wire body for replacing an existing VPN-required YouTube entry with
/// a desktop-produced OSS video. The backend performs owner/identity checks
/// and commits the replacement atomically after desktop processing completes.
struct EnqueueReplacementRequest: Encodable {
    let url: String
    let mode = "replace"
    let targetLibraryEntryId: String
}

/// Library limits returned by `/me.libraryLimits` and `/api/library/quota.limits`.
/// `/me` is already refreshed at login/foreground, so detail preflight reads
/// the current account's server-selected tier instead of recreating tier rules.
struct LibraryLimits: Decodable {
    let maxVideos: Int
    let maxVideoBytes: Int64
    let maxVideoSeconds: Int
}

struct LibraryQuota: Decodable {
    let used: Int
    let limit: Int
    let limits: LibraryLimits?
}

/// Personal-corpus quota. `limit` is server-authoritative (hasActiveSubscription
/// ? 1000 : 50), so it reflects cross-platform (Alipay/web) subscriptions that an
/// iOS-only `iosSubActive` check would miss.
struct CorpusQuota: Decodable {
    let used: Int
    let limit: Int
}

/// Managed-LLM relay quota — `GET /api/llm/quota`. `tier` distinguishes
/// "pro" (Pro session token) from "trial" (trialToken issued by
/// /trial/start) so the UI can render the right copy. `periodResetAt` is
/// epoch ms of the first day of next month (UTC) — used for the
/// "下次重置 X 月 1 日" hint. `used` and `limit` are total tokens
/// (input + output) for the current calendar month.
///
/// Added 2026-06-04 (managed-LLM relay).
struct LlmQuota: Decodable {
    let used: Int
    let limit: Int
    let requestCount: Int
    let tier: String
    let periodResetAt: Int64
}

/// Structured `source` for POST /api/corpus/contribute. Backend stores this
/// as JSONB and never validates the shape — any keys we add here just flow
/// through. Wire shape per kind:
///
///   kind="library"  — phrase came from a Library video's subtitle reader
///     libraryEntryId: required; primary play path (resolves to OSS AVPlayer
///                     via GET /library/entry/:id).
///     youtubeId: optional; written when the Library video originated from
///                YouTube so the display layer can fall back to YT embed if
///                the Library entry is later deleted.
///     timestampSec: subtitle cue start time.
///     url: optional canonical original (youtu.be/<id> or web URL).
///     title: video title for display headers.
///
///   kind="youtube" — phrase came from a raw YouTube URL (e.g. desktop import
///                    that wasn't synced into Library).
///     url: youtube URL.
///     youtubeId: optional convenience extracted from url.
///     timestampSec: optional.
///     title: optional.
///
///   kind="webpage" — manual entry pasting a non-video URL.
///     url, title.
///
///   kind="manual"  — typed phrase without any source context.
///     (all optional)
///
struct PhraseSource: Encodable {
    let kind: String
    let url: String?
    let title: String?
    let timestampSec: Double?
    let libraryEntryId: String?
    let youtubeId: String?
    /// kind="photo" — UUID minted at capture time so the client can
    /// group multiple phrases from the same photo. Server stores
    /// opaquely in JSONB (no logic uses it backend-side). 2026-06-04.
    let localPhotoId: String?

    /// Convenience: build a Library-video source from a CollectSheet context.
    static func library(entryId: String,
                        videoTitle: String,
                        youtubeId: String?,
                        timestampSec: Double?) -> PhraseSource {
        PhraseSource(
            kind: "library",
            url: youtubeId.map { "https://youtu.be/\($0)" },
            title: videoTitle,
            timestampSec: timestampSec,
            libraryEntryId: entryId,
            youtubeId: youtubeId,
            localPhotoId: nil
        )
    }

    /// Convenience: manual entry (current AddCorpusPhraseView default).
    static func webpage(url: String) -> PhraseSource {
        PhraseSource(kind: "webpage", url: url, title: nil, timestampSec: nil,
                     libraryEntryId: nil, youtubeId: nil, localPhotoId: nil)
    }

    /// Convenience: phrase extracted from an OCR'd photo (iOS only,
    /// added 2026-06-04). `localPhotoId` groups multiple phrases from
    /// the same capture session. `title` is the first OCR line or a
    /// short caption — purely for "我的 → 按来源" display. No url; the
    /// photo bytes intentionally stay on-device.
    static func photo(localPhotoId: String, title: String?) -> PhraseSource {
        PhraseSource(
            kind: "photo",
            url: nil,
            title: title,
            timestampSec: nil,
            libraryEntryId: nil,
            youtubeId: nil,
            localPhotoId: localPhotoId
        )
    }
}

struct LibraryEntryDetail: Decodable {
    let id: String
    let youtubeId: String
    let sourceUrl: String
    let title: String
    let durationSec: Int?
    let transcriptSrt: String?
    let analysisJson: AnalysisJson
    let videoUrl: String?
    /// Signed CDN URL for the audio-only .m4a sidecar. Practice modes
    /// (跟读/听抄) prefer this over videoUrl. nil = older entry, falls back.
    let audioUrl: String?
    /// Server-computed fingerprint for stale-safe guide writes. Transitional
    /// old backends omit it; callers must not generate until a refresh returns
    /// a non-empty value.
    let analysisFingerprint: String

    private enum CodingKeys: String, CodingKey {
        case id, youtubeId, sourceUrl, title, durationSec, transcriptSrt
        case analysisJson, videoUrl, audioUrl, analysisFingerprint
    }

    init(
        id: String,
        youtubeId: String,
        sourceUrl: String,
        title: String,
        durationSec: Int?,
        transcriptSrt: String?,
        analysisJson: AnalysisJson,
        videoUrl: String?,
        audioUrl: String?,
        analysisFingerprint: String = ""
    ) {
        self.id = id
        self.youtubeId = youtubeId
        self.sourceUrl = sourceUrl
        self.title = title
        self.durationSec = durationSec
        self.transcriptSrt = transcriptSrt
        self.analysisJson = analysisJson
        self.videoUrl = videoUrl
        self.audioUrl = audioUrl
        self.analysisFingerprint = analysisFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        youtubeId = try container.decode(String.self, forKey: .youtubeId)
        sourceUrl = try container.decode(String.self, forKey: .sourceUrl)
        title = try container.decode(String.self, forKey: .title)
        durationSec = try container.decodeIfPresent(Int.self, forKey: .durationSec)
        transcriptSrt = try container.decodeIfPresent(String.self, forKey: .transcriptSrt)
        analysisJson = try container.decode(AnalysisJson.self, forKey: .analysisJson)
        videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
        audioUrl = try container.decodeIfPresent(String.self, forKey: .audioUrl)
        analysisFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .analysisFingerprint
        ) ?? ""
    }
}

extension LibraryEntryDetail {
    /// Returns a new detail value containing only the server-accepted derived
    /// guide fields. The currently displayed entry stays untouched until the
    /// caller assigns this copy after PATCH success.
    func applyingLearningGuide(_ update: LearningGuideUpdateResponse) -> LibraryEntryDetail {
        let updatedAnalysis = AnalysisJson.assembled(
            subtitles: analysisJson.subtitles,
            keyPhrases: analysisJson.keyPhrases,
            learningGuide: update.learningGuide,
            contextProfile: update.contextProfile,
            learningGuideSourceFingerprint: update.analysisFingerprint
        )
        return LibraryEntryDetail(
            id: id,
            youtubeId: youtubeId,
            sourceUrl: sourceUrl,
            title: title,
            durationSec: durationSec,
            transcriptSrt: transcriptSrt,
            analysisJson: updatedAnalysis,
            videoUrl: videoUrl,
            audioUrl: audioUrl,
            analysisFingerprint: update.analysisFingerprint
        )
    }

    /// Canonical URL used by the replacement enqueue contract. A backend-safe
    /// URL is derived from the validated 11-character YouTube id instead of
    /// trusting a stale/free-form source URL cached by an older client.
    var canonicalYouTubeURL: String? {
        VideoSource.canonicalYouTubeURL(
            from: sourceUrl,
            expectedVideoID: youtubeId
        )
    }

    /// Only YouTube-fallback entries need desktop replacement. OSS-backed
    /// entries already play without VPN; non-YouTube entries must never be
    /// routed into the YouTube replacement contract.
    var needsDesktopDownload: Bool {
        videoUrl == nil && canonicalYouTubeURL != nil
    }
}

enum DesktopReplacementDurationPolicy {
    /// Returns nil when enqueue may proceed. Unknown values intentionally
    /// proceed so unchanged backend/desktop validation remains authoritative.
    static func blockingMessage(durationSec: Int?, maxVideoSeconds: Int?) -> String? {
        guard let actual = durationSec,
              let allowed = maxVideoSeconds,
              actual > allowed else { return nil }
        return "视频时长 \(format(actual))，当前账号单个视频上限为 \(format(allowed))，无法发送到桌面端下载。"
    }

    private static func format(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if seconds == 0 {
            if hours > 0, minutes > 0 { return "\(hours) 小时 \(minutes) 分钟" }
            if hours > 0 { return "\(hours) 小时" }
            return "\(minutes) 分钟"
        }

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分") }
        parts.append("\(seconds) 秒")
        return parts.joined(separator: " ")
    }
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
    let kind: String   // library | youtube | webpage | pdf | curator | photo
    /// Canonical URL of the original source. Optional because Library
    /// (post-builds-247) phrases may not have one if the OSS entry was
    /// from a non-YouTube origin (e.g. Bilibili import) — those rely on
    /// `libraryEntryId` for primary playback, no URL fallback.
    /// "photo" kind never has a URL — the photo bytes stay on-device.
    let url: String?
    let title: String?
    let timestampSec: Double?
    /// Library entry id when kind == "library". Resolves to OSS AVPlayer
    /// via GET /api/library/entry/:id. Absent for legacy phrases (decoded as nil).
    let libraryEntryId: String?
    /// YouTube id — present when kind == "youtube" OR when kind == "library"
    /// AND the underlying entry originated from YouTube (fallback if the
    /// Library entry is later deleted).
    let youtubeId: String?
    /// "photo" kind — UUID minted client-side at capture so a future
    /// "我的 → 按来源" view can group phrases collected from the same
    /// photo (analog to `libraryEntryId`). 2026-06-04.
    let localPhotoId: String?
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
    /// Backend row id (corpus_contributions.id). Optional because builds
    /// before 2026-06-04 didn't decode it (server has been emitting it all
    /// along); a nil here means a phrase from before-the-decode reached the
    /// view, in which case delete is disabled until the user pull-refreshes
    /// to get an `id`-bearing payload. Backend route field name: `id`.
    let contributionId: Int?
    let phraseNormalized: String
    let phraseRaw: String
    let meaningZh: String?
    let usageNote: String?
    let contextSentence: String
    let source: CorpusSource
    let contributedAt: Int64
    let tags: [String]
    /// SwiftUI Identifiable id. Prefer the backend row id (`contributionId`)
    /// because it is globally unique — the composite `phrase#contributedAt`
    /// can COLLIDE when the same phrase is saved twice in the same millisecond
    /// (batch sync, dual-write), and a collision makes `delete`'s
    /// `removeAll { $0.id == item.id }` drop BOTH rows and confuses ForEach
    /// diffing. Fall back to the composite only for pre-2026-06-04 cached
    /// payloads that decoded without an `id`.
    var id: String {
        if let cid = contributionId { return "c\(cid)" }
        return "\(phraseNormalized)#\(contributedAt)"
    }

    enum CodingKeys: String, CodingKey {
        case contributionId = "id"
        case phraseNormalized, phraseRaw, meaningZh, usageNote, contextSentence
        case source, contributedAt, tags
    }
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

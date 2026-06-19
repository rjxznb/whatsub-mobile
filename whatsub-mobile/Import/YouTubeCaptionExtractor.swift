import Foundation

/// Pure-Swift YouTube caption extractor. Calls Innertube's `/v1/player`
/// API claiming to be one of several "non-web" YouTube clients in turn,
/// parses the returned captionTracks, downloads the timedtext json3
/// payload for the best-English track, and hands cues to the caller.
///
/// Architecture decision (spec §2): pure HTTP — no WKWebView, no
/// JavaScriptCore, no embedded YouTube.js. Caption extraction is the
/// 0.5% of yt-dlp's surface that doesn't need BotGuard / PO_TOKEN /
/// signature deobfuscation, because YouTube serves non-web clients via
/// a different API path entirely.
///
/// Client fallback chain: ANDROID_TESTSUITE → IOS → TVHTML5. The
/// primary (ANDROID_TESTSUITE) wins for the ~95% of plain videos and
/// is the fastest (smallest payload). When YouTube returns UNPLAYABLE
/// / LOGIN_REQUIRED / AGE_VERIFICATION_REQUIRED on it — common on
/// music videos, region-locked content, and certain age-gated videos
/// — we fall through to IOS and then TVHTML5, which together unblock
/// most of the remaining cases (same idea as yt-dlp's
/// `--extractor-args "youtube:player_client=android,ios,tv"`).
///
/// Risks (spec §10): all three clients may eventually require
/// PO_TOKEN. Mitigation: add another entry to `fallbackClients` (e.g.
/// `MEDIA_CONNECT_FRONTEND` or whatever NewPipe / yt-dlp are using
/// next). The chain is the abstraction.
enum YouTubeCaptionExtractor {

    /// Function-type alias for HTTP injection. Tests pass a mock; production
    /// passes `URLSession.shared.data(for:)`. Default value below.
    typealias HTTPFetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Default HTTP implementation: vanilla URLSession.shared. Tests
    /// override this argument to return canned `(Data, URLResponse)`
    /// tuples without hitting the network.
    static let defaultFetcher: HTTPFetcher = { request in
        try await URLSession.shared.data(for: request)
    }

    /// One "client identity" the extractor can pretend to be when
    /// calling Innertube. Headers + context fields are sent verbatim
    /// per the values reverse-engineered from yt-dlp / NewPipe.
    fileprivate struct InnertubeClient {
        let clientName: String
        let clientVersion: String
        let xClientNameHeader: String
        let xClientVersionHeader: String
        let userAgent: String
        /// Extra fields merged into the `client` context dict.
        /// Android variants want `androidSdkVersion`; IOS wants
        /// `deviceMake` + `deviceModel`; TV wants nothing.
        let extraClientContext: [String: Any]

        func buildBodyContext(videoId: String) -> [String: Any] {
            var client: [String: Any] = [
                "clientName": clientName,
                "clientVersion": clientVersion,
                "userAgent": userAgent,
                "hl": "en",
                "gl": "US",
            ]
            for (k, v) in extraClientContext {
                client[k] = v
            }
            return [
                "context": ["client": client],
                "videoId": videoId,
            ]
        }
    }

    fileprivate static let fallbackClients: [InnertubeClient] = [
        // Primary: ANDROID_TESTSUITE — fastest, simplest, no PO_TOKEN.
        // Covers the vast majority of regular videos.
        InnertubeClient(
            clientName: "ANDROID_TESTSUITE",
            clientVersion: "1.9",
            xClientNameHeader: "3",
            xClientVersionHeader: "1.9",
            userAgent: "com.google.android.youtube/19.07.34 (Linux; U; Android 14) gzip",
            extraClientContext: ["androidSdkVersion": 30]
        ),
        // Fallback 1: IOS — broadest compatibility. Generally bypasses
        // music-rights, region locks, and many age gates that
        // ANDROID_TESTSUITE rejects. Same idea as yt-dlp's
        // `--extractor-args "youtube:player_client=ios"`.
        InnertubeClient(
            clientName: "IOS",
            clientVersion: "19.09.3",
            xClientNameHeader: "5",
            xClientVersionHeader: "19.09.3",
            userAgent: "com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)",
            extraClientContext: ["deviceMake": "Apple", "deviceModel": "iPhone14,3"]
        ),
        // Fallback 2: TVHTML5_SIMPLY_EMBEDDED_PLAYER — TV embedded
        // client. Minimal anti-scraping because YouTube can't enforce
        // device attestation across smart TV / Roku / Apple TV
        // ecosystems. Last resort for age-gated content IOS rejects.
        InnertubeClient(
            clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            clientVersion: "2.0",
            xClientNameHeader: "85",
            xClientVersionHeader: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15",
            extraClientContext: [:]
        ),
    ]

    /// Extract English captions for a YouTube videoId.
    ///
    /// - Parameters:
    ///   - videoId: 11-char YouTube videoId.
    ///   - cache: Disk cache. Hits skip the network entirely.
    ///   - fetcher: HTTP function. Defaults to URLSession.shared.
    ///   - onProgress: Receives one debug-log line per extraction step.
    ///     ImportViewModel accumulates these for the `查看诊断` sheet.
    /// - Returns: `[Cue]` with index, time, endTime, text populated;
    ///   translation / highlights remain empty until AnalysisEngine runs.
    /// - Throws: `CaptionError` covering every failure mode.
    static func extract(
        videoId: String,
        cache: CaptionCache = .shared,
        fetcher: @escaping HTTPFetcher = defaultFetcher,
        onProgress: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> [Cue] {

        await emit(onProgress, "extract(videoId=\(videoId)) start")

        // 1. Cache check.
        if let cached = cache.get(videoId) {
            await emit(onProgress, "cache hit for \(videoId)")
            return cached
        }
        await emit(onProgress, "cache miss for \(videoId)")

        // 2. Walk client fallback chain. Break on first OK; remember
        // the last status seen so we can map to the right error if
        // every client refuses.
        var workingResponse: PlayerResponse?
        var lastStatus: String = "UNKNOWN"

        for client in fallbackClients {
            await emit(onProgress, "POST youtubei/v1/player + \(client.clientName)")
            let resp = try await fetchPlayerResponse(
                videoId: videoId, client: client, fetcher: fetcher
            )
            lastStatus = resp.playabilityStatus.status
            if lastStatus == "OK" {
                await emit(onProgress, "playabilityStatus=OK on \(client.clientName)")
                workingResponse = resp
                break
            }
            await emit(onProgress, "playabilityStatus=\(lastStatus) on \(client.clientName) → try next client")
        }

        guard let player = workingResponse else {
            let mapped: CaptionError = (lastStatus == "LOGIN_REQUIRED" || lastStatus == "AGE_VERIFICATION_REQUIRED")
                ? .requiresLogin
                : .videoUnavailable
            await emit(onProgress, "all clients exhausted, last=\(lastStatus)")
            throw mapped
        }

        // 3. Extract caption tracks from the first OK response.
        guard let tracks = player.captions?
                .playerCaptionsTracklistRenderer?.captionTracks,
              !tracks.isEmpty else {
            await emit(onProgress, "no captionTracks → noCaptions")
            throw CaptionError.noCaptions
        }
        await emit(onProgress, "captionTracks: n=\(tracks.count)")

        // 4. Pick best English.
        guard let picked = pickBestEnglishCaptionTrack(tracks) else {
            await emit(onProgress, "no English track → noEnglishCaptions")
            throw CaptionError.noEnglishCaptions
        }
        await emit(onProgress, "picked \(picked.languageCode)\(picked.kind == "asr" ? " (ASR)" : " (manual)")")

        // 5. Fetch timedtext json3.
        let cues = try await fetchTimedtext(
            baseUrl: picked.baseUrl, fetcher: fetcher, onProgress: onProgress
        )

        // 6. Cache + return.
        cache.set(videoId, cues: cues)
        await emit(onProgress, "cache write")
        return cues
    }

    // MARK: - Private

    private static func fetchPlayerResponse(
        videoId: String,
        client: InnertubeClient,
        fetcher: HTTPFetcher
    ) async throws -> PlayerResponse {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.xClientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.xClientVersionHeader, forHTTPHeaderField: "X-YouTube-Client-Version")

        let body = client.buildBodyContext(videoId: videoId)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetcher(request)
        } catch let urlError as URLError {
            throw CaptionError.network(urlError)
        } catch {
            throw CaptionError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CaptionError.http(status: status)
        }

        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw CaptionError.parseFailed
        }
    }

    private static func fetchTimedtext(
        baseUrl: String,
        fetcher: HTTPFetcher,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> [Cue] {
        // Append fmt=json3. baseUrl already carries the signed query
        // string YouTube minted for us — we never reach into it.
        guard var components = URLComponents(string: baseUrl) else {
            throw CaptionError.parseFailed
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = items
        guard let url = components.url else { throw CaptionError.parseFailed }

        await emit(onProgress, "GET timedtext")
        let request = URLRequest(url: url)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetcher(request)
        } catch let urlError as URLError {
            throw CaptionError.network(urlError)
        } catch {
            throw CaptionError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CaptionError.timedtextFetchFailed(status: status)
        }

        guard !data.isEmpty else { throw CaptionError.emptyResult }
        await emit(onProgress, "json3 body: len=\(data.count)")

        let spikeCues = parseTimedtextJson3(data)
        guard !spikeCues.isEmpty else { throw CaptionError.parseFailed }
        await emit(onProgress, "parsed: \(spikeCues.count) cues")

        // Map the parser's SpikeCue → app-wide Cue. translation /
        // highlights stay empty; AnalysisEngine fills them later.
        return spikeCues.map { spike in
            Cue(index: spike.idx, time: spike.time,
                endTime: spike.end, text: spike.text)
        }
    }

    private static func emit(
        _ onProgress: @MainActor @escaping (String) -> Void,
        _ message: String
    ) async {
        await MainActor.run { onProgress(message) }
    }
}

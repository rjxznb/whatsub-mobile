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
/// Client fallback chain (2026-06-20, matches yt-dlp's 2026 picks):
/// ANDROID_VR → TVHTML5_SIMPLY_EMBEDDED_PLAYER → IOS → MWEB.
/// ANDROID_VR (Oculus Quest YouTube app) is the current most-permissive
/// no-PO_TOKEN client per yt-dlp 2026 defaults — replaced our previous
/// ANDROID_TESTSUITE which yt-dlp removed from `INNERTUBE_CLIENTS`. TV
/// embedded second is good for age-gate / kids-mode. IOS bumped to
/// yt-dlp's current metadata (clientVersion 21.02.3 / iPhone16,2 /
/// iOS 18) — older 19.x values started returning HTTP 400 in 2026 as
/// YouTube tightened Apple-platform anti-scrape. MWEB last as a
/// generic-web safety net.
///
/// Risks (spec §10): each client may eventually require PO_TOKEN.
/// Mitigation: mirror what yt-dlp's `extractor/youtube/_base.py`
/// `INNERTUBE_CLIENTS` ships next. The chain is the abstraction.
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
        // Primary: ANDROID_VR — yt-dlp's 2026 default client, lifted
        // from the Oculus Quest YouTube VR app. No PO_TOKEN, broadest
        // coverage as of 2026-06. Replaced our previous
        // ANDROID_TESTSUITE which yt-dlp removed from INNERTUBE_CLIENTS.
        InnertubeClient(
            clientName: "ANDROID_VR",
            clientVersion: "1.65.10",
            xClientNameHeader: "28",
            xClientVersionHeader: "1.65.10",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extraClientContext: ["androidSdkVersion": 32]
        ),
        // Fallback 1: TVHTML5_SIMPLY_EMBEDDED_PLAYER — TV embedded
        // client. Minimal anti-scraping because YouTube can't enforce
        // device attestation across smart TV / Roku / Apple TV
        // ecosystems. Good at unblocking kids-mode + some age-gates.
        InnertubeClient(
            clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            clientVersion: "2.0",
            xClientNameHeader: "85",
            xClientVersionHeader: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15",
            extraClientContext: [:]
        ),
        // Fallback 2: IOS — Apple-platform fallback. Metadata mirrors
        // yt-dlp's 2026 INNERTUBE_CLIENTS values (clientVersion bumped
        // from earlier 19.45.4 → 21.02.3 after another round of
        // YouTube anti-scrape tightening on Apple clients in mid-2026).
        InnertubeClient(
            clientName: "IOS",
            clientVersion: "21.02.3",
            xClientNameHeader: "5",
            xClientVersionHeader: "21.02.3",
            userAgent: "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X)",
            extraClientContext: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.2.0.22C152",
            ]
        ),
        // Fallback 3: MWEB — mobile web. Generic safety net; reaches
        // some videos the device-specific clients above don't. No
        // PO_TOKEN required for the player request itself (only some
        // GVS streams need it, which we don't touch here).
        InnertubeClient(
            clientName: "MWEB",
            clientVersion: "2.20260115.01.00",
            xClientNameHeader: "2",
            xClientVersionHeader: "2.20260115.01.00",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
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

        // 2. Walk client fallback chain. Break on first OK; on ANY
        // failure (UNPLAYABLE status, HTTP error, network error)
        // continue to the next client. Only re-throw after all
        // clients are exhausted.
        var workingResponse: PlayerResponse?
        var lastStatus: String = "UNKNOWN"
        var lastError: CaptionError?

        for client in fallbackClients {
            await emit(onProgress, "POST youtubei/v1/player + \(client.clientName)")
            do {
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
            } catch let err as CaptionError {
                // HTTP / network / parse failure — log + remember as
                // last-error so we can re-throw it if every other
                // client also fails. Continue the chain.
                await emit(onProgress, "\(client.clientName) request failed: \(err.errorDescription ?? "unknown") → try next client")
                lastError = err
            }
        }

        guard let player = workingResponse else {
            // Status-based exhaustion takes precedence (we got responses
            // from at least one client, they just said the video is
            // gated/dead). If we never got a successful response at all,
            // surface the last underlying transport error so the user
            // sees "HTTP 400" / "网络错误" instead of a misleading
            // "video unavailable".
            let mapped: CaptionError
            if lastStatus == "LOGIN_REQUIRED" || lastStatus == "AGE_VERIFICATION_REQUIRED" {
                mapped = .requiresLogin
            } else if lastStatus != "UNKNOWN" {
                mapped = .videoUnavailable
            } else if let lastError = lastError {
                mapped = lastError
            } else {
                mapped = .videoUnavailable
            }
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

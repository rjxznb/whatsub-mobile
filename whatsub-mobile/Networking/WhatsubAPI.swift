import Foundation

/// All backend HTTP lives here. An actor so concurrent calls serialize their
/// access to the (rare) shared state and so the type is Sendable-safe.
actor WhatsubAPI {
    static let shared = WhatsubAPI()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // ----- Auth -----

    func sendCode(email: String) async throws {
        let body = try JSONEncoder().encode(SendCodeRequest(email: email))
        _ = try await postExpectingOk(Endpoints.auth("send-code"), body: body, bearer: nil)
    }

    func verifyCode(email: String, code: String) async throws -> Session {
        let body = try JSONEncoder().encode(VerifyCodeRequest(email: email, code: code))
        let data = try await post(Endpoints.auth("verify-code"), body: body, bearer: nil)
        let resp = try decode(VerifyCodeResponse.self, from: data)
        return Session(email: email, sessionToken: resp.sessionToken, expiresAt: resp.expiresAt)
    }

    func me(token: String) async throws -> MeResponse {
        let data = try await get(Endpoints.auth("me"), bearer: token)
        return try decode(MeResponse.self, from: data)
    }

    /// Best-effort — swallows errors (logout shouldn't block the UI on a
    /// flaky network; the local session is cleared regardless). Non-throwing.
    func logout(token: String) async {
        _ = try? await postExpectingOk(Endpoints.auth("logout"), body: Data("{}".utf8), bearer: token)
    }

    // ----- Library -----

    func listLibrary(token: String) async throws -> [LibraryListItem] {
        let data = try await get(Endpoints.library("list"), bearer: token)
        return try decode(LibraryListResponse.self, from: data).entries
    }

    func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await get(Endpoints.library("entry/\(encoded)"), bearer: token)
        return try decode(LibraryEntryDetail.self, from: data)
    }

    func deleteLibraryEntry(id: String, token: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await delete(Endpoints.library("sync/\(encoded)"), bearer: token)
    }

    func enqueueImport(url: String, token: String) async throws {
        _ = try await postExpectingOk(
            Endpoints.library("import-queue"),
            body: try JSONSerialization.data(withJSONObject: ["url": url]),
            bearer: token
        )
    }

    /// POST /api/library/sync — creates or replaces an entry with the full
    /// analysisJson payload. `analysisJson` is the assembled result from
    /// AnalysisEngine; we serialise it as a nested dict matching the backend's
    /// expected shape (subtitles[] + keyPhrases[]).
    func syncLibraryEntry(
        youtubeId: String,
        sourceUrl: String,
        title: String,
        durationSec: Int?,
        transcriptSrt: String,
        analysis: AnalysisJson,
        thumbData: String? = nil,
        token: String
    ) async throws {
        let subtitlesDicts: [[String: Any]] = analysis.subtitles.map { cue in
            [
                "time": cue.time,
                "endTime": cue.endTime,
                "text": cue.text,
                "translation": cue.translation,
                "isKeyPoint": cue.isKeyPoint,
                "highlightWords": cue.highlightWords,
                "keyNotes": cue.keyNotes,
                "highlightTranslations": cue.highlightTranslations,
            ]
        }
        let keyPhrasesDicts: [[String: Any]] = analysis.keyPhrases.map { kp in
            ["expression": kp.expression, "meaningZh": kp.meaningZh, "usage": kp.usage]
        }
        let analysisDict: [String: Any] = [
            "subtitles": subtitlesDicts,
            "keyPhrases": keyPhrasesDicts,
        ]

        var body: [String: Any] = [
            "id": youtubeId,
            "youtubeId": youtubeId,
            "sourceUrl": sourceUrl,
            "title": title,
            "thumbUrl": "https://i.ytimg.com/vi/\(youtubeId)/mqdefault.jpg",
            "transcriptSrt": transcriptSrt,
            "analysisJson": analysisDict,
        ]
        if let dur = durationSec { body["durationSec"] = dur }
        // Imported videos have no desktop thumb; the iOS import (VPN on) fetches
        // the YouTube cover + sends it here so the backend serves a China-reachable
        // thumbnail (cover shows in the list without VPN).
        if let thumbData { body["thumbData"] = thumbData }

        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await postExpectingOk(Endpoints.library("sync"), body: data, bearer: token)
    }

    // ----- Corpus -----

    /// scope = "public" (needs license) or "mine" (session only).
    func corpusTags(scope: String, token: String) async throws -> [CorpusTag] {
        let data = try await get(Endpoints.corpus("tags?scope=\(scope)"), bearer: token)
        return try decode(CorpusTagsResponse.self, from: data).tags
    }

    func browseCorpus(tags: [String], token: String) async throws -> [BrowsePhrase] {
        var path = "browse?limit=100"
        if !tags.isEmpty {
            let joined = tags.joined(separator: ",")
            path += "&tags=\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined)"
        }
        let data = try await get(Endpoints.corpus(path), bearer: token)
        return try decode(BrowseResponse.self, from: data).phrases
    }

    func mineCorpus(tags: [String], token: String) async throws -> [MineItem] {
        var path = "mine?pageSize=100"
        if !tags.isEmpty {
            let joined = tags.joined(separator: ",")
            path += "&tags=\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined)"
        }
        let data = try await get(Endpoints.corpus(path), bearer: token)
        return try decode(MineResponse.self, from: data).items
    }

    /// Returns nil when the backend reports no_data (404).
    func lookupPhrase(_ phrase: String, token: String) async throws -> LookupResponse? {
        let enc = phrase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? phrase
        do {
            let data = try await get(Endpoints.corpus("lookup?phrase=\(enc)&withScope=true"), bearer: token)
            return try decode(LookupResponse.self, from: data)
        } catch APIError.server(let code, _) where code == 404 {
            return nil
        }
    }

    // ----- HTTP primitives -----

    private func get(_ url: URL, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBearer(&req, bearer)
        return try await send(req)
    }

    private func delete(_ url: URL, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyBearer(&req, bearer)
        return try await send(req)
    }

    private func post(_ url: URL, body: Data, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        applyBearer(&req, bearer)
        return try await send(req)
    }

    @discardableResult
    private func postExpectingOk(_ url: URL, body: Data, bearer: String?) async throws -> Data {
        try await post(url, body: body, bearer: bearer)
    }

    private func applyBearer(_ req: inout URLRequest, _ bearer: String?) {
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("no http response")
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let err = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw APIError.server(http.statusCode, err?.error)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}

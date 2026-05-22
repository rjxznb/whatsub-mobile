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

    // ----- HTTP primitives -----

    private func get(_ url: URL, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
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

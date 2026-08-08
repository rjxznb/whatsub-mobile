import Foundation

struct ManagedAnalysisClient: ManagedAnalysisClientProtocol {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let transport: Transport

    init(
        baseURL: URL = URL(string: Endpoints.mobileAnalysisBase)!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.transport = { request in try await session.data(for: request) }
    }

    init(baseURL: URL, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func createJob(
        _ request: ManagedAnalysisCreateRequest,
        token: String
    ) async throws -> ManagedAnalysisJob {
        try await send(
            method: "POST",
            path: ["jobs"],
            body: try encode(request),
            token: token,
            as: ManagedAnalysisJob.self
        )
    }

    func job(id: String, token: String) async throws -> ManagedAnalysisJob {
        try await send(method: "GET", path: ["jobs", id], token: token, as: ManagedAnalysisJob.self)
    }

    func jobs(token: String) async throws -> [ManagedAnalysisJob] {
        let response = try await send(
            method: "GET",
            path: ["jobs"],
            token: token,
            as: ManagedAnalysisJobsResponse.self
        )
        return response.jobs
    }

    func cancel(id: String, token: String) async throws -> ManagedAnalysisJob {
        try await send(
            method: "POST",
            path: ["jobs", id, "cancel"],
            body: Data("{}".utf8),
            token: token,
            as: ManagedAnalysisJob.self
        )
    }

    func resume(id: String, token: String) async throws -> ManagedAnalysisJob {
        try await send(
            method: "POST",
            path: ["jobs", id, "resume"],
            body: Data("{}".utf8),
            token: token,
            as: ManagedAnalysisJob.self
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: [String],
        body: Data? = nil,
        token: String,
        as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ManagedAnalysisClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ManagedAnalysisClientError.invalidResponse("no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ManagedAnalysisClientError.invalidResponse(error.localizedDescription)
        }
    }

    private func endpoint(_ path: [String]) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ManagedAnalysisClientError.invalidResponse("invalid endpoint")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let root = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        guard encoded.allSatisfy({ !$0.isEmpty }),
              let url = URL(string: root + encoded.joined(separator: "/")) else {
            throw ManagedAnalysisClientError.invalidResponse("invalid endpoint")
        }
        return url
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw ManagedAnalysisClientError.invalidResponse(error.localizedDescription)
        }
    }

    private func mapError(status: Int, data: Data) -> ManagedAnalysisClientError {
        let body = try? JSONDecoder().decode(ManagedAnalysisErrorBody.self, from: data)
        switch (status, body?.error) {
        case (401, _): return .unauthorized
        case (404, _): return .notFound
        case (409, "invalid_state"): return .invalidState
        case (_, "duration_unknown"): return .durationUnknown
        case (_, "video_too_long"): return .videoTooLong
        case (_, "free_used_up"): return .freeUsedUp
        case (_, "quota_exceeded"): return .quotaExceeded
        case (_, "upstream_unavailable"): return .upstreamUnavailable
        case (_, "queue_limit"): return .queueLimit
        case (503, "server_busy"): return .serverBusy(retryable: body?.retryable ?? false)
        default: return .server(status: status, code: body?.error)
        }
    }
}

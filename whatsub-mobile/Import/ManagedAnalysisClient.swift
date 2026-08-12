import Foundation

struct ManagedAnalysisStreamingResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () -> Void

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private final class ManagedAnalysisStreamTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

struct ManagedAnalysisClient: ManagedAnalysisClientProtocol {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    typealias StreamTransport = (URLRequest) async throws -> ManagedAnalysisStreamingResponse

    private let baseURL: URL
    private let transport: Transport
    private let streamTransport: StreamTransport

    init(
        baseURL: URL = URL(string: Endpoints.mobileAnalysisBase)!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.transport = { request in try await session.data(for: request) }
        self.streamTransport = Self.urlSessionStreamTransport(session: session)
    }

    init(
        baseURL: URL,
        transport: @escaping Transport,
        streamTransport: @escaping StreamTransport = { _ in
            throw ManagedAnalysisStreamError.unsupported
        }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.streamTransport = streamTransport
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

    func results(
        id: String,
        afterBatch: Int,
        token: String
    ) async throws -> ManagedAnalysisResultsPage {
        try await send(
            method: "GET",
            path: ["jobs", id, "results"],
            queryItems: [URLQueryItem(name: "afterBatch", value: String(afterBatch))],
            token: token,
            as: ManagedAnalysisResultsPage.self
        )
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

    func events(
        id: String,
        afterEventID: Int64?,
        mode: ManagedAnalysisStreamMode,
        token: String
    ) -> AsyncThrowingStream<ManagedAnalysisStreamEvent, Error> {
        let request: URLRequest
        do {
            request = try eventRequest(
                id: id,
                afterEventID: afterEventID,
                mode: mode,
                token: token
            )
        } catch {
            return failedStream(error)
        }

        return AsyncThrowingStream { continuation in
            let producer = Task {
                var activeResponse: ManagedAnalysisStreamingResponse?
                defer { activeResponse?.cancel() }

                do {
                    let response = try await streamTransport(request)
                    activeResponse = response
                    try Task.checkCancellation()

                    guard (200..<300).contains(response.statusCode) else {
                        let data = try await readErrorBody(response.body)
                        throw mapStreamError(response: response, data: data)
                    }
                    guard isEventStream(response.header("Content-Type")) else {
                        throw ManagedAnalysisClientError.invalidResponse(
                            "expected text/event-stream response"
                        )
                    }

                    var parser = ManagedAnalysisSSEParser()
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        for message in try parser.push(chunk) {
                            if let event = try ManagedAnalysisStreamEvent.decode(message) {
                                continuation.yield(event)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    for message in try parser.finish() {
                        if let event = try ManagedAnalysisStreamEvent.decode(message) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ManagedAnalysisStreamError {
                    continuation.finish(throwing: error)
                } catch let error as ManagedAnalysisClientError {
                    continuation.finish(throwing: error)
                } catch let error as ManagedAnalysisSSEParseError {
                    continuation.finish(throwing: error)
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(
                            throwing: ManagedAnalysisClientError.network(error.localizedDescription)
                        )
                    }
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func send<Response: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        token: String,
        as type: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path, queryItems: queryItems))
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

    private func eventRequest(
        id: String,
        afterEventID: Int64?,
        mode: ManagedAnalysisStreamMode,
        token: String
    ) throws -> URLRequest {
        switch mode {
        case .snapshot:
            guard afterEventID == nil else {
                throw ManagedAnalysisClientError.invalidResponse(
                    "snapshot stream cannot use an event cursor"
                )
            }
        case .replay:
            guard let afterEventID, afterEventID >= 0 else {
                throw ManagedAnalysisClientError.invalidResponse(
                    "replay stream requires a non-negative event cursor"
                )
            }
        }

        var request = URLRequest(
            url: try endpoint(
                ["jobs", id, "events"],
                queryItems: [URLQueryItem(name: "mode", value: mode.rawValue)]
            )
        )
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        if mode == .replay, let afterEventID {
            request.setValue(String(afterEventID), forHTTPHeaderField: "Last-Event-ID")
        }
        return request
    }

    private func endpoint(_ path: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ManagedAnalysisClientError.invalidResponse("invalid endpoint")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let root = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        guard encoded.allSatisfy({ !$0.isEmpty }),
              let rawURL = URL(string: root + encoded.joined(separator: "/")),
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw ManagedAnalysisClientError.invalidResponse("invalid endpoint")
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
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
        default:
            return .server(
                status: status,
                code: body?.error,
                diagnosticCode: body?.diagnosticCode,
                diagnosticId: body?.diagnosticId
            )
        }
    }

    private func mapStreamError(
        response: ManagedAnalysisStreamingResponse,
        data: Data
    ) -> Error {
        struct StreamErrorBody: Decodable {
            let error: String?
            let retryAfterSec: Int?
        }

        let body = try? JSONDecoder().decode(StreamErrorBody.self, from: data)
        if let error = mapStreamSpecificError(
            response: response,
            errorCode: body?.error,
            bodyRetryAfter: body?.retryAfterSec
        ) {
            return error
        }
        switch response.statusCode {
        case 401:
            return ManagedAnalysisClientError.unauthorized
        case 404:
            return ManagedAnalysisClientError.notFound
        default:
            return mapError(status: response.statusCode, data: data)
        }
    }

    private func mapStreamSpecificError(
        response: ManagedAnalysisStreamingResponse,
        errorCode: String?,
        bodyRetryAfter: Int?
    ) -> ManagedAnalysisStreamError? {
        if response.statusCode == 403 {
            return .forbidden
        }
        guard response.statusCode == 429 ||
                (response.statusCode == 503 &&
                    (errorCode == "stream_busy" || errorCode == "stream_unavailable")) else {
            return nil
        }
        return .admissionRejected(
            status: response.statusCode,
            retryAfterSeconds: retryAfterSeconds(response: response, body: bodyRetryAfter)
        )
    }

    private func retryAfterSeconds(
        response: ManagedAnalysisStreamingResponse,
        body: Int?
    ) -> Int? {
        if let body, body >= 0 { return body }
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Int(raw),
              seconds >= 0 else {
            return nil
        }
        return seconds
    }

    private func isEventStream(_ contentType: String?) -> Bool {
        guard let mediaType = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return mediaType == "text/event-stream"
    }

    private func readErrorBody(
        _ body: AsyncThrowingStream<Data, Error>,
        limit: Int = 64 * 1024
    ) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard data.count < limit else { break }
            data.append(chunk.prefix(limit - data.count))
        }
        try Task.checkCancellation()
        return data
    }

    private func failedStream(
        _ error: Error
    ) -> AsyncThrowingStream<ManagedAnalysisStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    private static func urlSessionStreamTransport(session: URLSession) -> StreamTransport {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ManagedAnalysisClientError.invalidResponse("no http response")
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }

            let taskBox = ManagedAnalysisStreamTaskBox()
            let body = AsyncThrowingStream<Data, Error> { continuation in
                let producer = Task {
                    do {
                        var chunk = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            chunk.append(byte)
                            if byte == 0x0A || chunk.count >= 4_096 {
                                if case .terminated = continuation.yield(chunk) { return }
                                chunk.removeAll(keepingCapacity: true)
                            }
                        }
                        if !chunk.isEmpty {
                            _ = continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                taskBox.install(producer)
                continuation.onTermination = { _ in taskBox.cancel() }
            }

            return ManagedAnalysisStreamingResponse(
                statusCode: http.statusCode,
                headers: headers,
                body: body,
                cancel: { taskBox.cancel() }
            )
        }
    }
}

import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisClientTests: XCTestCase {

    private actor Recorder {
        private(set) var requests: [URLRequest] = []
        func append(_ request: URLRequest) { requests.append(request) }
        func last() -> URLRequest? { requests.last }
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelCalls = 0
        private var sourceTerminations = 0
        private var receivedEvents = 0

        func recordCancel() {
            lock.lock()
            cancelCalls += 1
            lock.unlock()
        }

        func recordSourceTermination() {
            lock.lock()
            sourceTerminations += 1
            lock.unlock()
        }

        func recordReceivedEvent() {
            lock.lock()
            receivedEvents += 1
            lock.unlock()
        }

        func snapshot() -> (cancelCalls: Int, sourceTerminations: Int, receivedEvents: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (cancelCalls, sourceTerminations, receivedEvents)
        }
    }

    private func response(_ status: Int, json: String) -> (Data, URLResponse) {
        let url = URL(string: "https://example.test")!
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }

    private func streamingResponse(
        _ status: Int = 200,
        contentType: String? = "text/event-stream; charset=utf-8",
        headers: [String: String] = [:],
        chunks: [Data]
    ) -> ManagedAnalysisStreamingResponse {
        var responseHeaders = headers
        if let contentType { responseHeaders["Content-Type"] = contentType }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return ManagedAnalysisStreamingResponse(
            statusCode: status,
            headers: responseHeaders,
            body: body,
            cancel: {}
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ManagedAnalysisStreamEvent, Error>
    ) async throws -> [ManagedAnalysisStreamEvent] {
        var events: [ManagedAnalysisStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func request(idempotencyKey: String = "ios:test-key") -> ManagedAnalysisCreateRequest {
        ManagedAnalysisCreateRequest(
            idempotencyKey: idempotencyKey,
            youtubeId: "abcdefghijk",
            sourceUrl: "https://www.youtube.com/watch?v=abcdefghijk",
            title: "Test video",
            durationSec: 120,
            cues: [ManagedAnalysisCue(index: 0, time: 0, endTime: 1.5, text: "Hello")],
            transcriptSrt: "1\n00:00:00,000 --> 00:00:01,500\nHello\n",
            thumbData: nil
        )
    }

    private let queuedJob = """
    {"jobId":"job-1","status":"queued","tier":"free",
     "createdAt":100,"updatedAt":101,"completedCues":0,"totalCues":1,
     "tokensIn":0,"tokensOut":0,"errorCode":null,"resultEntryId":null}
    """

    func testCreateUsesStableIdempotencyAndDecodes202() async throws {
        let recorder = Recorder()
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            request in
            await recorder.append(request)
            return self.response(202, json: self.queuedJob)
        }

        let job = try await client.createJob(request(), token: "session")

        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.tier, .free)
        let recorded = await recorder.last()
        let sent = try XCTUnwrap(recorded)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/api/jobs")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(ManagedAnalysisCreateRequest.self, from: XCTUnwrap(sent.httpBody))
        XCTAssertEqual(body.idempotencyKey, "ios:test-key")
        XCTAssertEqual(body.durationSec, 120)
        XCTAssertEqual(body.cues.first?.text, "Hello")
    }

    func testListGetCancelAndResumeUseExpectedRoutes() async throws {
        let recorder = Recorder()
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            request in
            await recorder.append(request)
            if request.httpMethod == "GET", request.url?.path == "/api/jobs" {
                return self.response(200, json: "{\"jobs\":[\(self.queuedJob)]}")
            }
            return self.response(200, json: self.queuedJob)
        }

        let listed = try await client.jobs(token: "s")
        XCTAssertEqual(listed.count, 1)
        _ = try await client.job(id: "job / one", token: "s")
        _ = try await client.cancel(id: "job / one", token: "s")
        _ = try await client.resume(id: "job / one", token: "s")

        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "POST"])
        XCTAssertEqual(requests.map {
            $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath
        }, [
            "/api/jobs",
            "/api/jobs/job%20%2F%20one",
            "/api/jobs/job%20%2F%20one/cancel",
            "/api/jobs/job%20%2F%20one/resume",
        ])
    }

    func testResultsUsesEncodedJobPathAndBatchCursor() async throws {
        let recorder = Recorder()
        let json = """
        {"jobId":"job / one","entryId":"entry-1","status":"running",
         "completedCues":1,"totalCues":2,"nextBatchCursor":0,"errorCode":null,
         "batches":[{"batchIndex":0,"subtitles":[{
           "index":0,"time":0,"endTime":1.5,"text":"Hello","translation":"你好",
           "isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}
         }]}]}
        """
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            request in
            await recorder.append(request)
            return self.response(200, json: json)
        }

        let page = try await client.results(id: "job / one", afterBatch: -1, token: "session")

        XCTAssertEqual(page.nextBatchCursor, 0)
        XCTAssertEqual(page.batches.first?.subtitles.first?.translation, "你好")
        let lastRequest = await recorder.last()
        let sent = try XCTUnwrap(lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/jobs/job%20%2F%20one/results")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "afterBatch", value: "-1")])
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer session")
    }

    func testMapsTypedCreatePolicyErrors() async {
        let cases: [(Int, String, ManagedAnalysisClientError)] = [
            (400, "duration_unknown", .durationUnknown),
            (413, "video_too_long", .videoTooLong),
            (429, "free_used_up", .freeUsedUp),
            (429, "quota_exceeded", .quotaExceeded),
            (503, "upstream_unavailable", .upstreamUnavailable),
            (429, "queue_limit", .queueLimit),
            (503, "server_busy", .serverBusy(retryable: true)),
        ]

        for (status, code, expected) in cases {
            let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
                _ in self.response(status, json: "{\"error\":\"\(code)\",\"retryable\":true}")
            }
            do {
                _ = try await client.createJob(request(idempotencyKey: code), token: "s")
                XCTFail("expected \(expected)")
            } catch let error as ManagedAnalysisClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPreservesManagedValidationDiagnosticFields() async {
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            _ in self.response(
                400,
                json: """
                {"error":"invalid_input","diagnosticCode":"invalid_thumbnail",\
                "diagnosticId":"abc123def456"}
                """
            )
        }

        do {
            _ = try await client.createJob(request(), token: "session-secret")
            XCTFail("expected validation failure")
        } catch let error as ManagedAnalysisClientError {
            XCTAssertEqual(
                error,
                .server(
                    status: 400,
                    code: "invalid_input",
                    diagnosticCode: "invalid_thumbnail",
                    diagnosticId: "abc123def456"
                )
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDecodesTypedTerminalFailureCodeWithoutFlattening() async throws {
        let failed = """
        {"jobId":"job-1","status":"failed","tier":"pro",
         "createdAt":100,"updatedAt":101,"completedCues":50,"totalCues":100,
         "tokensIn":12,"tokensOut":34,"errorCode":"quota_exceeded","resultEntryId":null}
        """
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            _ in self.response(200, json: failed)
        }

        let job = try await client.job(id: "job-1", token: "s")

        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.tier, .pro)
        XCTAssertEqual(job.errorCode, .quotaExceeded)
        XCTAssertEqual(job.progress, 0.5, accuracy: 0.001)
    }

    func testMapsKnownPublicFailureCodes() {
        XCTAssertEqual(ManagedAnalysisFailureCode(rawValue: "free_used_up"), .freeUsedUp)
        XCTAssertEqual(ManagedAnalysisFailureCode(rawValue: "quota_exceeded"), .quotaExceeded)
        XCTAssertEqual(ManagedAnalysisFailureCode(rawValue: "upstream_unavailable"), .upstreamUnavailable)
        XCTAssertEqual(ManagedAnalysisFailureCode(rawValue: "video_too_long"), .videoTooLong)
        XCTAssertEqual(ManagedAnalysisFailureCode(rawValue: "duration_unknown"), .durationUnknown)
    }

    func testRejectsDotSegmentsBeforeTransport() async {
        let recorder = Recorder()
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            request in
            await recorder.append(request)
            return self.response(200, json: self.queuedJob)
        }

        do {
            _ = try await client.job(id: "..", token: "s")
            XCTFail("expected invalid endpoint")
        } catch let error as ManagedAnalysisClientError {
            guard case .invalidResponse = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let recorded = await recorder.requests
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCancellationIsNotFlattenedIntoNetworkError() async {
        let client = ManagedAnalysisClient(baseURL: URL(string: "https://example.test/api")!) {
            _ in throw CancellationError()
        }

        do {
            _ = try await client.jobs(token: "s")
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: structured concurrency cancellation remains intact.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testColdEventStreamUsesAuthenticatedSnapshotRequestWithoutCursor() async throws {
        let recorder = Recorder()
        let frame = Data("event: connected\ndata: {\"jobId\":\"job / one\"}\n\n".utf8)
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api/library/mobile-analysis")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { request in
                await recorder.append(request)
                return self.streamingResponse(chunks: [frame])
            }
        )

        let events = try await collect(client.events(
            id: "job / one",
            afterEventID: nil,
            mode: .snapshot,
            token: "session-secret"
        ))

        XCTAssertEqual(events, [.connected(.init(jobId: "job / one", retryMilliseconds: nil))])
        let recorded = await recorder.last()
        let sent = try XCTUnwrap(recorded)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/library/mobile-analysis/jobs/job%20%2F%20one/events")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "mode", value: "snapshot")])
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer session-secret")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testReplayEventStreamSendsInMemoryCursor() async throws {
        let recorder = Recorder()
        let frame = Data("""
        id: 42
        event: phase
        data: {"eventId":42,"jobId":"job-1","eventType":"phase","batchIndex":0,"attempt":2,"cueIndex":null,"payload":{"phase":"summary"},"createdAt":100}

        """.utf8)
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api/library/mobile-analysis/")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { request in
                await recorder.append(request)
                return self.streamingResponse(chunks: [
                    Data(frame.prefix(17)),
                    Data(frame.dropFirst(17)),
                ])
            }
        )

        let events = try await collect(client.events(
            id: "job-1",
            afterEventID: 41,
            mode: ManagedAnalysisStreamMode.replay,
            token: "session"
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventID, 42)
        let recorded = await recorder.last()
        let sent = try XCTUnwrap(recorded)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "mode", value: "replay")])
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Last-Event-ID"), "41")
    }

    func testEventStreamRejectsModeCursorMismatchBeforeTransport() async {
        let recorder = Recorder()
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { request in
                await recorder.append(request)
                return self.streamingResponse(chunks: [])
            }
        )
        let cases: [(ManagedAnalysisStreamMode, Int64?)] = [
            (.snapshot, 9),
            (.replay, nil),
            (.replay, -1),
        ]

        for (mode, cursor) in cases {
            do {
                _ = try await collect(client.events(
                    id: "job-1", afterEventID: cursor, mode: mode, token: "s"
                ))
                XCTFail("expected invalid mode/cursor pair")
            } catch let error as ManagedAnalysisClientError {
                guard case .invalidResponse = error else {
                    XCTFail("unexpected error: \(error)")
                    continue
                }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEventStreamMapsAuthenticationAndOwnershipErrors() async {
        let cases: [(Int, ManagedAnalysisClientError)] = [
            (401, .unauthorized),
            (404, .notFound),
        ]

        for (status, expected) in cases {
            let client = ManagedAnalysisClient(
                baseURL: URL(string: "https://example.test/api")!,
                transport: { _ in self.response(500, json: "{}") },
                streamTransport: { _ in
                    self.streamingResponse(status, contentType: "application/json", chunks: [Data("{\"error\":\"denied\"}".utf8)])
                }
            )

            do {
                _ = try await collect(client.events(
                    id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
                ))
                XCTFail("expected \(expected)")
            } catch let error as ManagedAnalysisClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let forbiddenClient = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in
                self.streamingResponse(
                    403,
                    contentType: "application/json",
                    chunks: [Data("{\"error\":\"denied\"}".utf8)]
                )
            }
        )
        do {
            _ = try await collect(forbiddenClient.events(
                id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
            ))
            XCTFail("expected forbidden stream")
        } catch let error as ManagedAnalysisStreamError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEventStreamMapsAdmissionRejectionSeparatelyFromJobFailure() async {
        let cases: [(Int, [String: String], Int?)] = [
            (429, ["Retry-After": "7"], 7),
            (503, ["Retry-After": "3"], 3),
        ]

        for (status, headers, retryAfter) in cases {
            let client = ManagedAnalysisClient(
                baseURL: URL(string: "https://example.test/api")!,
                transport: { _ in self.response(500, json: "{}") },
                streamTransport: { _ in
                    self.streamingResponse(
                        status,
                        contentType: "application/json",
                        headers: headers,
                        chunks: [Data("{\"error\":\"stream_busy\",\"retryable\":true}".utf8)]
                    )
                }
            )

            do {
                _ = try await collect(client.events(
                    id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
                ))
                XCTFail("expected stream admission rejection")
            } catch let error as ManagedAnalysisStreamError {
                XCTAssertEqual(
                    error,
                    .admissionRejected(status: status, retryAfterSeconds: retryAfter)
                )
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEventStreamRejectsSuccessfulNonSSEBody() async {
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in
                self.streamingResponse(200, contentType: "application/json", chunks: [Data("{}".utf8)])
            }
        )

        do {
            _ = try await collect(client.events(
                id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
            ))
            XCTFail("expected content-type rejection")
        } catch let error as ManagedAnalysisClientError {
            guard case let .invalidResponse(message) = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertTrue(message.contains("text/event-stream"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEventStreamSurfacesMalformedTypedEvent() async {
        let malformed = Data("event: cue\nid: 8\ndata: {not-json}\n\n".utf8)
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in self.streamingResponse(chunks: [malformed]) }
        )

        do {
            _ = try await collect(client.events(
                id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
            ))
            XCTFail("expected malformed event")
        } catch let error as ManagedAnalysisSSEParseError {
            XCTAssertEqual(error, .malformedJSON(event: "cue", eventID: 8))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEventStreamFlushesFinalFrameAndFinishesNormallyAtEOF() async throws {
        let finalFrameWithoutBlankLine = Data(
            "event: connected\ndata: {\"jobId\":\"job-1\"}".utf8
        )
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in self.streamingResponse(chunks: [finalFrameWithoutBlankLine]) }
        )

        let events = try await collect(client.events(
            id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
        ))

        XCTAssertEqual(events, [.connected(.init(jobId: "job-1", retryMilliseconds: nil))])
    }

    func testEventStreamPreservesTransportCancellation() async {
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in throw CancellationError() }
        )

        do {
            _ = try await collect(client.events(
                id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
            ))
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Structured cancellation must not become a network/job failure.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellingEventConsumerClosesTransportExactlyOnce() async throws {
        let probe = CancellationProbe()
        let client = ManagedAnalysisClient(
            baseURL: URL(string: "https://example.test/api")!,
            transport: { _ in self.response(500, json: "{}") },
            streamTransport: { _ in
                let body = AsyncThrowingStream<Data, Error> { continuation in
                    continuation.yield(Data(
                        "event: connected\ndata: {\"jobId\":\"job-1\"}\n\n".utf8
                    ))
                    let source = Task {
                        do {
                            try await Task.sleep(nanoseconds: 60_000_000_000)
                        } catch {
                            // Response cancellation wakes the held source.
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        source.cancel()
                        probe.recordSourceTermination()
                    }
                }
                return ManagedAnalysisStreamingResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: body,
                    cancel: {
                        probe.recordCancel()
                    }
                )
            }
        )
        let stream = client.events(
            id: "job-1", afterEventID: nil, mode: .snapshot, token: "s"
        )
        let consumer = Task {
            for try await _ in stream { probe.recordReceivedEvent() }
        }

        for _ in 0..<100 {
            if probe.snapshot().receivedEvents == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(probe.snapshot().receivedEvents, 1)
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<20 {
            let counts = probe.snapshot()
            if counts.cancelCalls == 1, counts.sourceTerminations == 1 { break }
            await Task.yield()
        }

        let counts = probe.snapshot()
        XCTAssertEqual(counts.cancelCalls, 1)
        XCTAssertEqual(counts.sourceTerminations, 1)
    }
}

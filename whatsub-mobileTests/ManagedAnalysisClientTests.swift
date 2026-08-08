import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisClientTests: XCTestCase {

    private actor Recorder {
        private(set) var requests: [URLRequest] = []
        func append(_ request: URLRequest) { requests.append(request) }
        func last() -> URLRequest? { requests.last }
    }

    private func response(_ status: Int, json: String) -> (Data, URLResponse) {
        let url = URL(string: "https://example.test")!
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
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
        XCTAssertEqual(requests.map { $0.url?.percentEncodedPath }, [
            "/api/jobs",
            "/api/jobs/job%20%2F%20one",
            "/api/jobs/job%20%2F%20one/cancel",
            "/api/jobs/job%20%2F%20one/resume",
        ])
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
}

import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisSSEParserTests: XCTestCase {
    private let cuePayload = #"{"type":"cue","index":0,"time":0,"endTime":1.25,"text":"Hello","translation":"你好","isKeyPoint":true,"highlightWords":["Hello"],"keyNotes":{"Hello":"问候"},"highlightTranslations":{"Hello":"你好"}}"#

    private func parse(_ chunks: [Data], finish: Bool = false) throws -> [ManagedAnalysisSSEMessage] {
        var parser = ManagedAnalysisSSEParser()
        var messages: [ManagedAnalysisSSEMessage] = []
        for chunk in chunks {
            messages.append(contentsOf: try parser.push(chunk))
        }
        if finish {
            messages.append(contentsOf: try parser.finish())
        }
        return messages
    }

    private func message(event: String, id: Int64? = nil, data: String, retry: Int? = nil) -> ManagedAnalysisSSEMessage {
        ManagedAnalysisSSEMessage(id: id, event: event, data: data, retryMilliseconds: retry)
    }

    private func persisted(
        id: Int64,
        event: String,
        batchIndex: String = "0",
        attempt: String = "1",
        cueIndex: String = "null",
        payload: String,
        createdAt: Int64 = 1_000
    ) -> ManagedAnalysisSSEMessage {
        message(
            event: event,
            id: id,
            data: #"{"eventId":\#(id),"jobId":"job-1","eventType":"\#(event)","batchIndex":\#(batchIndex),"attempt":\#(attempt),"cueIndex":\#(cueIndex),"payload":\#(payload),"createdAt":\#(createdAt)}"#
        )
    }

    func testParserHandlesEveryByteBoundaryIncludingSplitUTF8Scalars() throws {
        let frame = "event: connected\ndata: {\"jobId\":\"任务-一\"}\n\n"
        let bytes = Data(frame.utf8)
        let expected = [message(event: "connected", data: "{\"jobId\":\"任务-一\"}")]

        for boundary in 0...bytes.count {
            let chunks = [Data(bytes.prefix(boundary)), Data(bytes.dropFirst(boundary))]
            XCTAssertEqual(try parse(chunks), expected, "failed at byte boundary \(boundary)")
        }

        XCTAssertEqual(
            try parse(bytes.map { Data([$0]) }),
            expected,
            "one-byte chunks must preserve split UTF-8 scalars"
        )
    }

    func testParserHandlesCRLFCommentsHeartbeatsAndBlankDelimiters() throws {
        let stream = ""
            + ": heartbeat\r\n"
            + "\r\n"
            + ": another comment\r\n"
            + "event: connected\r\n"
            + "data: {\"jobId\":\"job-1\"}\r\n"
            + "\r\n"
            + "\r\n"

        XCTAssertEqual(
            try parse([Data(stream.utf8)]),
            [message(event: "connected", data: "{\"jobId\":\"job-1\"}")]
        )
    }

    func testParserReadsRetryIDNamedEventAndJoinsMultilineData() throws {
        let stream = "retry: 3000\nid: 42\nevent: cue\ndata: first\ndata: second\n\n"

        XCTAssertEqual(
            try parse([Data(stream.utf8)]),
            [message(event: "cue", id: 42, data: "first\nsecond", retry: 3_000)]
        )
    }

    func testParserEmitsSeveralEventsFromOneChunk() throws {
        let stream = ""
            + "event: connected\ndata: {\"jobId\":\"job-1\"}\n\n"
            + "event: resync\ndata: {\"reason\":\"cursor_expired\"}\n\n"
            + "id: 9\nevent: job_state\ndata: {}\n\n"

        XCTAssertEqual(
            try parse([Data(stream.utf8)]),
            [
                message(event: "connected", data: "{\"jobId\":\"job-1\"}"),
                message(event: "resync", data: "{\"reason\":\"cursor_expired\"}"),
                message(event: "job_state", id: 9, data: "{}")
            ]
        )
    }

    func testFinishFlushesACompleteFinalEventWithoutBlankDelimiter() throws {
        let stream = "event: connected\ndata: {\"jobId\":\"job-1\"}"

        XCTAssertEqual(
            try parse([Data(stream.utf8)], finish: true),
            [message(event: "connected", data: "{\"jobId\":\"job-1\"}")]
        )
    }

    func testParserReportsInvalidUTF8AsTypedError() throws {
        var parser = ManagedAnalysisSSEParser()

        XCTAssertThrowsError(try parser.push(Data([0xFF, 0x0A]))) { error in
            XCTAssertEqual(error as? ManagedAnalysisSSEParseError, .invalidUTF8)
        }
    }

    func testKnownEventWithMalformedJSONReportsTypedError() throws {
        let malformed = message(event: "cue", id: 42, data: "{not-json")

        XCTAssertThrowsError(try ManagedAnalysisStreamEvent.decode(malformed)) { error in
            XCTAssertEqual(
                error as? ManagedAnalysisSSEParseError,
                .malformedJSON(event: "cue", eventID: 42)
            )
        }
    }

    func testDecodesConnectedEventWithoutCursor() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            message(event: "connected", data: #"{"jobId":"job-1"}"#, retry: 3_000)
        )

        guard case let .connected(event)? = decoded else {
            return XCTFail("expected connected event")
        }
        XCTAssertEqual(event.jobId, "job-1")
        XCTAssertEqual(event.retryMilliseconds, 3_000)
        XCTAssertNil(decoded?.eventID)
    }

    func testDecodesSnapshotWithCurrentAttemptAndQueueEstimate() throws {
        let cue = #"{"eventId":7,"jobId":"job-1","eventType":"cue","batchIndex":0,"attempt":2,"cueIndex":0,"payload":\#(cuePayload),"createdAt":1000}"#
        let data = #"{"jobId":"job-1","status":"running","totalCues":230,"completedCues":50,"completedBatchCursor":0,"latestEventId":7,"errorCode":null,"jobsAhead":2,"estimatedStartSeconds":45,"currentAttempt":{"batchIndex":0,"attempt":2,"cues":[\#(cue)]}}"#

        let decoded = try ManagedAnalysisStreamEvent.decode(message(event: "snapshot", data: data))

        guard case let .snapshot(snapshot)? = decoded else {
            return XCTFail("expected snapshot event")
        }
        XCTAssertEqual(snapshot.jobId, "job-1")
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.totalCues, 230)
        XCTAssertEqual(snapshot.completedCues, 50)
        XCTAssertEqual(snapshot.completedBatchCursor, 0)
        XCTAssertEqual(snapshot.latestEventId, 7)
        XCTAssertEqual(snapshot.jobsAhead, 2)
        XCTAssertEqual(snapshot.estimatedStartSeconds, 45)
        XCTAssertEqual(snapshot.currentAttempt?.batchIndex, 0)
        XCTAssertEqual(snapshot.currentAttempt?.attempt, 2)
        XCTAssertEqual(snapshot.currentAttempt?.cues.first?.cue.translation, "你好")
        XCTAssertNil(decoded?.eventID, "snapshot frames are intentionally ID-less")
    }

    func testDecodesCueEvent() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(id: 11, event: "cue", cueIndex: "0", payload: cuePayload)
        )

        guard case let .cue(event)? = decoded else {
            return XCTFail("expected cue event")
        }
        XCTAssertEqual(event.eventId, 11)
        XCTAssertEqual(event.jobId, "job-1")
        XCTAssertEqual(event.batchIndex, 0)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.cueIndex, 0)
        XCTAssertEqual(event.cue.text, "Hello")
        XCTAssertEqual(event.cue.translation, "你好")
        XCTAssertEqual(event.cue.highlightWords, ["Hello"])
        XCTAssertEqual(decoded?.eventID, 11)
    }

    func testDecodesBatchResetEvent() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(
                id: 12,
                event: "batch_reset",
                payload: #"{"abandonedAttempt":1,"nextAttempt":2}"#
            )
        )

        guard case let .batchReset(event)? = decoded else {
            return XCTFail("expected batch reset event")
        }
        XCTAssertEqual(event.batchIndex, 0)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.abandonedAttempt, 1)
        XCTAssertEqual(event.nextAttempt, 2)
        XCTAssertEqual(decoded?.eventID, 12)
    }

    func testDecodesBatchCommittedEvent() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(
                id: 13,
                event: "batch_committed",
                payload: #"{"batchIndex":0,"attempt":1,"completedCues":50}"#
            )
        )

        guard case let .batchCommitted(event)? = decoded else {
            return XCTFail("expected batch committed event")
        }
        XCTAssertEqual(event.batchIndex, 0)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertEqual(event.completedCues, 50)
        XCTAssertEqual(decoded?.eventID, 13)
    }

    func testDecodesPhaseEvent() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(
                id: 14,
                event: "phase",
                batchIndex: "null",
                attempt: "null",
                payload: #"{"phase":"summary"}"#
            )
        )

        guard case let .phase(event)? = decoded else {
            return XCTFail("expected phase event")
        }
        XCTAssertEqual(event.phase, .summary)
        XCTAssertEqual(decoded?.eventID, 14)
    }

    func testDecodesFinalizePhaseUsingBackendClaimRawValue() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(
                id: 141,
                event: "phase",
                batchIndex: "null",
                attempt: "null",
                payload: #"{"phase":"finalize"}"#
            )
        )

        guard case let .phase(event)? = decoded else {
            return XCTFail("expected finalize phase event")
        }
        XCTAssertEqual(event.phase, .finalize)
        XCTAssertEqual(decoded?.eventID, 141)
    }

    func testDecodesJobStateEvent() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            persisted(
                id: 15,
                event: "job_state",
                batchIndex: "null",
                attempt: "null",
                payload: #"{"status":"completed","errorCode":null,"resultEntryId":"entry-1"}"#
            )
        )

        guard case let .jobState(event)? = decoded else {
            return XCTFail("expected job state event")
        }
        XCTAssertEqual(event.status, .completed)
        XCTAssertNil(event.errorCode)
        XCTAssertEqual(event.resultEntryId, "entry-1")
        XCTAssertEqual(decoded?.eventID, 15)
    }

    func testDecodesResyncEventWithoutCursor() throws {
        let decoded = try ManagedAnalysisStreamEvent.decode(
            message(event: "resync", data: #"{"reason":"cursor_expired"}"#)
        )

        guard case let .resync(event)? = decoded else {
            return XCTFail("expected resync event")
        }
        XCTAssertEqual(event.reason, .cursorExpired)
        XCTAssertNil(decoded?.eventID)
    }

    func testUnknownEventIsIgnoredWithoutAdvancingCursor() throws {
        let unknown = message(event: "future_event", id: 900, data: "not-even-json")
        let known = persisted(id: 16, event: "cue", cueIndex: "0", payload: cuePayload)

        XCTAssertNil(try ManagedAnalysisStreamEvent.decode(unknown))
        XCTAssertEqual(try ManagedAnalysisStreamEvent.decode(known)?.eventID, 16)
    }

    func testJobQueueFieldsDecodeWhenPresentAndRemainNilWhenAbsent() throws {
        let base = #"{"jobId":"job-1","status":"queued","tier":"pro","createdAt":1000,"updatedAt":1001,"completedCues":0,"totalCues":230,"tokensIn":0,"tokensOut":0,"errorCode":null,"resultEntryId":"entry-1"}"#
        let withQueue = #"{"jobId":"job-1","status":"queued","tier":"pro","createdAt":1000,"updatedAt":1001,"completedCues":0,"totalCues":230,"tokensIn":0,"tokensOut":0,"errorCode":null,"resultEntryId":"entry-1","jobsAhead":3,"estimatedStartSeconds":75}"#

        let oldServerJob = try JSONDecoder().decode(ManagedAnalysisJob.self, from: Data(base.utf8))
        let queuedJob = try JSONDecoder().decode(ManagedAnalysisJob.self, from: Data(withQueue.utf8))

        XCTAssertNil(oldServerJob.jobsAhead)
        XCTAssertNil(oldServerJob.estimatedStartSeconds)
        XCTAssertEqual(queuedJob.jobsAhead, 3)
        XCTAssertEqual(queuedJob.estimatedStartSeconds, 75)
    }
}

import XCTest
@testable import whatsub_mobile

final class VerdictParserTests: XCTestCase {

    func testSingleChunkSplitsDialogAndVerdict() {
        var p = VerdictParser()
        let out = p.feed("Hello there!\n<<<VERDICT>>>\n{\"verdicts\":[]}\n<<<END>>>\n")
        XCTAssertEqual(out.dialogChunk, "Hello there!\n")
        XCTAssertNotNil(out.completedVerdict)
        XCTAssertEqual(out.completedVerdict?.verdicts.count, 0)
    }

    func testSentinelSplitAcrossChunks() {
        var p = VerdictParser()
        let a = p.feed("Hello there! <<<VER")
        XCTAssertEqual(a.dialogChunk, "Hello there! ")     // hold back the partial sentinel
        XCTAssertNil(a.completedVerdict)
        let b = p.feed("DICT>>>\n{\"verdicts\":[")
        XCTAssertEqual(b.dialogChunk, "", "after sentinel: nothing more goes to dialog")
        XCTAssertNil(b.completedVerdict)
        let c = p.feed("]}\n<<<END>>>")
        XCTAssertEqual(c.dialogChunk, "")
        XCTAssertNotNil(c.completedVerdict)
    }

    func testDialogOnlyWhenNoSentinelEver() {
        var p = VerdictParser()
        let out = p.feed("just talking, no verdict here.")
        XCTAssertEqual(out.dialogChunk, "just talking, no verdict here.")
        XCTAssertNil(out.completedVerdict)
        let final = p.finish()
        XCTAssertNil(final.completedVerdict, "missing verdict = nil, not an error")
    }

    func testMalformedVerdictJSONReturnsNilButDoesntCrash() {
        var p = VerdictParser()
        let out = p.feed("hi\n<<<VERDICT>>>\nthis is not json\n<<<END>>>")
        XCTAssertEqual(out.dialogChunk, "hi\n")
        XCTAssertNil(out.completedVerdict, "bad JSON behaves like missing verdict")
    }

    func testCharBeforePartialSentinelStillFlushed() {
        var p = VerdictParser()
        // The '<' itself isn't yet a confirmed sentinel start; everything before
        // it must still flush to dialog so TTS doesn't lag.
        let out = p.feed("ok then.<")
        XCTAssertEqual(out.dialogChunk, "ok then.")
        let next = p.feed("<<VERDICT>>>")
        // Confirmed — the held '<' chars rolled into the sentinel match. Nothing
        // new for dialog.
        XCTAssertEqual(next.dialogChunk, "")
    }
}

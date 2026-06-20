import XCTest
@testable import whatsub_mobile

final class JsonLineParserTests: XCTestCase {

    private func collect(_ feeds: [String]) -> [[String: Any]] {
        let parser = JsonLineParser()
        var objs: [[String: Any]] = []
        for f in feeds {
            parser.feed(f) { obj in
                if let d = obj as? [String: Any] { objs.append(d) }
            }
        }
        parser.flush { obj in
            if let d = obj as? [String: Any] { objs.append(d) }
        }
        return objs
    }

    func testSingleCompleteLine() {
        let objs = collect(["{\"a\":1}\n"])
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs[0]["a"] as? Int, 1)
    }

    func testMultipleLinesOneFeed() {
        let objs = collect(["{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"])
        XCTAssertEqual(objs.count, 3)
        XCTAssertEqual(objs[2]["c"] as? Int, 3)
    }

    /// The whole point of streaming: a JSON object split across two
    /// network chunks should still parse once both halves arrive.
    func testPartialLineAcrossFeeds() {
        let objs = collect(["{\"k\":\"hel", "lo\"}\n"])
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs[0]["k"] as? String, "hello")
    }

    /// LLM occasionally omits the trailing newline before stream end.
    /// flush() must drain the buffer so we don't lose the last cue.
    func testFlushDrainsTrailingObject() {
        let parser = JsonLineParser()
        var objs: [[String: Any]] = []
        parser.feed("{\"k\":1}") { obj in
            if let d = obj as? [String: Any] { objs.append(d) }
        }
        XCTAssertEqual(objs.count, 0, "no newline yet → still buffered")
        parser.flush { obj in
            if let d = obj as? [String: Any] { objs.append(d) }
        }
        XCTAssertEqual(objs.count, 1)
    }

    /// Prose interleaved with the JSON output (DeepSeek's "Now I'll
    /// emit the next cue:" pattern in BYOK mode) must be silently
    /// dropped — handle should NOT fire on a non-{...} line.
    func testNonJsonLinesDropped() {
        let objs = collect([
            "Now I'll emit cues:\n",
            "{\"a\":1}\n",
            "\n",
            "Next batch:\n",
            "{\"a\":2}\n",
        ])
        XCTAssertEqual(objs.count, 2)
        XCTAssertEqual(objs[0]["a"] as? Int, 1)
        XCTAssertEqual(objs[1]["a"] as? Int, 2)
    }

    /// Malformed mid-stream JSON line gets skipped without aborting —
    /// later good lines still surface.
    func testMalformedLineTolerated() {
        let objs = collect([
            "{\"a\":1}\n",
            "{not json}\n",
            "{\"a\":2}\n",
        ])
        XCTAssertEqual(objs.count, 2)
        XCTAssertEqual(objs[1]["a"] as? Int, 2)
    }
}

import XCTest
@testable import whatsub_mobile

final class CaptionCacheTests: XCTestCase {

    private var tempDir: URL!
    private var cache: CaptionCache!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptionCacheTests-\(UUID().uuidString)",
                                    isDirectory: true)
        cache = CaptionCache(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeCue(idx: Int) -> Cue {
        Cue(index: idx, time: Double(idx) * 1.5,
            endTime: Double(idx) * 1.5 + 1.5,
            text: "line \(idx)")
    }

    func testGetReturnsNilWhenMissing() {
        XCTAssertNil(cache.get("unknown_video_id"))
    }

    func testSetThenGetRoundtrip() {
        let cues = [makeCue(idx: 0), makeCue(idx: 1)]
        cache.set("abc123", cues: cues)
        let loaded = cache.get("abc123")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?[0].text, "line 0")
        XCTAssertEqual(loaded?[0].time ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(loaded?[1].endTime ?? 0, 3.0, accuracy: 0.001)
    }

    func testClearAllEmptiesDirectory() {
        cache.set("a", cues: [makeCue(idx: 0)])
        cache.set("b", cues: [makeCue(idx: 1)])
        XCTAssertNotNil(cache.get("a"))
        XCTAssertNotNil(cache.get("b"))
        cache.clearAll()
        XCTAssertNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
    }

    func testGetIgnoresUnknownVersion() throws {
        // Write a file claiming version 999 — current code rejects unknown
        // versions so it can evolve the schema later (spec §5.3).
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("v999.json")
        let payload: [String: Any] = [
            "version": 999,
            "videoId": "v999",
            "cachedAt": Date().timeIntervalSince1970,
            "cues": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: path)
        XCTAssertNil(cache.get("v999"))
    }

    func testGetReturnsNilOnCorruptFile() throws {
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("corrupt.json")
        try "not json".data(using: .utf8)!.write(to: path)
        XCTAssertNil(cache.get("corrupt"))
    }
}

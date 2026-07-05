import XCTest
@testable import whatsub_mobile

final class LibraryCacheTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("librarycache_\(UUID().uuidString).json")
    }
    private func item(_ id: String, videoUrl: String? = nil) -> LibraryListItem {
        let video = videoUrl.map { "\"\($0)\"" } ?? "null"
        return try! JSONDecoder().decode(LibraryListItem.self, from: Data("""
            {"id":"\(id)","youtubeId":"yt-\(id)","sourceUrl":"https://youtu.be/\(id)",
             "title":"t","durationSec":120,"thumbUrl":null,"syncedAt":1700000000000,
             "videoUrl":\(video),"audioUrl":null}
            """.utf8))
    }

    func testRoundTripAndFreshness() {
        let url = tempURL()
        let now = Date()
        do {
            let c = LibraryCache(fileURL: url)
            c.store(entries: [item("a"), item("b", videoUrl: "https://cdn/x.mp4")],
                    version: 7002, for: "alice@x.com", now: now)
            XCTAssertTrue(c.isFresh(for: "alice@x.com", serverVersion: 7002, now: now))
        }
        // Fresh instance reads from disk (cold start).
        let reloaded = LibraryCache(fileURL: url)
        let cached = reloaded.cached(for: "alice@x.com")
        XCTAssertEqual(cached?.entries.count, 2)
        XCTAssertEqual(cached?.version, 7002)
        XCTAssertEqual(cached?.entries.first?.id, "a")
        XCTAssertEqual(cached?.entries.last?.videoUrl, "https://cdn/x.mp4")
        try? FileManager.default.removeItem(at: url)
    }

    func testStaleWhenServerVersionDiffers() {
        let url = tempURL(); let now = Date()
        let c = LibraryCache(fileURL: url)
        c.store(entries: [item("a")], version: 7002, for: "alice@x.com", now: now)
        XCTAssertTrue(c.isFresh(for: "alice@x.com", serverVersion: 7002, now: now))
        // A sync/delete on another device bumped the fingerprint.
        XCTAssertFalse(c.isFresh(for: "alice@x.com", serverVersion: 7003, now: now))
        try? FileManager.default.removeItem(at: url)
    }

    func testStaleAfterTTL() {
        let url = tempURL(); let now = Date()
        let c = LibraryCache(fileURL: url, ttl: 24 * 3600)
        c.store(entries: [item("a")], version: 7002, for: "alice@x.com", now: now)
        XCTAssertFalse(c.isFresh(for: "alice@x.com", serverVersion: 7002,
                                 now: now.addingTimeInterval(25 * 3600)))
        try? FileManager.default.removeItem(at: url)
    }

    func testCrossAccountIsolation() {
        // Logout → login with a different email must never see the previous
        // user's library from disk.
        let url = tempURL(); let now = Date()
        let c = LibraryCache(fileURL: url)
        c.store(entries: [item("a")], version: 7002, for: "alice@x.com", now: now)
        XCTAssertNil(c.cached(for: "mallory@x.com"))
        XCTAssertFalse(c.isFresh(for: "mallory@x.com", serverVersion: 7002, now: now))
        try? FileManager.default.removeItem(at: url)
    }

    func testEmptyLibraryIsAValidCachedState() {
        // A new user with 0 videos: empty entries must still count as "has
        // cache" (fetchedAt marker), unlike corpus where empty = cold start.
        let url = tempURL(); let now = Date()
        let c = LibraryCache(fileURL: url)
        c.store(entries: [], version: 0, for: "new@x.com", now: now)
        XCTAssertNotNil(c.cached(for: "new@x.com"))
        XCTAssertEqual(c.cached(for: "new@x.com")?.entries.count, 0)
        XCTAssertTrue(c.isFresh(for: "new@x.com", serverVersion: 0, now: now))
        try? FileManager.default.removeItem(at: url)
    }

    func testClearDropsEverything() {
        let url = tempURL(); let now = Date()
        let c = LibraryCache(fileURL: url)
        c.store(entries: [item("a")], version: 7002, for: "alice@x.com", now: now)
        c.clear()
        XCTAssertNil(c.cached(for: "alice@x.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // And a reload from the (removed) file stays empty.
        XCTAssertNil(LibraryCache(fileURL: url).cached(for: "alice@x.com"))
    }
}

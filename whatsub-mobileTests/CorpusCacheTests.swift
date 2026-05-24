import XCTest
@testable import whatsub_mobile

final class CorpusCacheTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corpuscache_\(UUID().uuidString).json")
    }
    private func phrase(_ id: String) -> BrowsePhrase {
        try! JSONDecoder().decode(BrowsePhrase.self,
            from: Data(#"{"phrase_normalized":"\#(id)","phrase_raw":"\#(id)","meaning_zh":"m","usage_note":null,"tags":[]}"#.utf8))
    }
    private func lookup() -> LookupResponse {
        try! JSONDecoder().decode(LookupResponse.self,
            from: Data(#"{"phrase":{"phrase_raw":"x","meaning_zh":"y","usage_note":null,"tags":{"list":[]}},"publicContributions":[],"personalContributions":[]}"#.utf8))
    }

    func testBrowseRoundTripAndFreshness() {
        let url = tempURL()
        let now = Date()
        do {
            let c = CorpusCache(fileURL: url)
            c.updateVersions(mine: 1, publicVersion: 5)
            c.storeBrowse(items: [phrase("a"), phrase("b")], tags: [], now: now)
            XCTAssertFalse(c.isBrowseStale(now: now))          // just stored at current versions
        }
        let reloaded = CorpusCache(fileURL: url)               // fresh instance reads disk
        reloaded.updateVersions(mine: 1, publicVersion: 5)
        XCTAssertEqual(reloaded.cachedBrowse()?.items.count, 2)
        XCTAssertFalse(reloaded.isBrowseStale(now: now))
        try? FileManager.default.removeItem(at: url)
    }

    func testBrowseStaleOnPublicVersionChangeAndTTL() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 1, publicVersion: 5)
        c.storeBrowse(items: [phrase("a")], tags: [], now: now)
        c.updateVersions(mine: 1, publicVersion: 6)            // public bumped
        XCTAssertTrue(c.isBrowseStale(now: now))
        c.updateVersions(mine: 1, publicVersion: 5)
        XCTAssertTrue(c.isBrowseStale(now: now.addingTimeInterval(25*3600))) // TTL
        try? FileManager.default.removeItem(at: url)
    }

    func testLookupValidityFollowsBothVersions() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 2, publicVersion: 3)
        c.storeLookup("p", lookup(), now: now)
        XCTAssertNotNil(c.cachedLookup("p", now: now))
        c.updateVersions(mine: 2, publicVersion: 4)            // public changed
        XCTAssertNil(c.cachedLookup("p", now: now))
        c.updateVersions(mine: 2, publicVersion: 3)
        XCTAssertNil(c.cachedLookup("p", now: now.addingTimeInterval(25*3600))) // TTL
        try? FileManager.default.removeItem(at: url)
    }

    func testLookupLRUCapEvictsOldest() {
        let url = tempURL(); let now = Date()
        let c = CorpusCache(fileURL: url)
        c.updateVersions(mine: 0, publicVersion: 0)
        for i in 0...500 { c.storeLookup("p\(i)", lookup(), now: now) } // 501 stores
        XCTAssertNil(c.cachedLookup("p0", now: now))           // oldest evicted
        XCTAssertNotNil(c.cachedLookup("p500", now: now))      // newest kept
        try? FileManager.default.removeItem(at: url)
    }

    func testCorruptFileStartsEmpty() {
        let url = tempURL()
        try? Data("garbage".utf8).write(to: url)
        let c = CorpusCache(fileURL: url)
        XCTAssertNil(c.cachedBrowse())
        try? FileManager.default.removeItem(at: url)
    }
}

import XCTest
import UIKit
@testable import whatsub_mobile

final class LibraryThumbnailRepairTests: XCTestCase {
    private func entry(_ id: String, youtubeID: String? = nil, thumbURL: String? = nil) -> LibraryListItem {
        let encodedThumb = thumbURL.map { "\"\($0)\"" } ?? "null"
        return try! JSONDecoder().decode(LibraryListItem.self, from: Data("""
        {
          "id":"\(id)","youtubeId":"\(youtubeID ?? id)",
          "sourceUrl":"https://www.youtube.com/watch?v=\(youtubeID ?? id)",
          "title":"Title","durationSec":20,"thumbUrl":\(encodedThumb),
          "syncedAt":1,"videoUrl":null,"audioUrl":null
        }
        """.utf8))
    }

    func testFetcherFallsBackToAlternateThumbnailHost() async throws {
        let lock = NSLock()
        var requestedHosts: [String] = []
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.8)!
        let fetcher = YouTubeThumbnailFetcher(
            fetch: { url in
                lock.lock()
                requestedHosts.append(url.host ?? "")
                lock.unlock()
                if url.host == "i.ytimg.com" { throw URLError(.timedOut) }
                return jpeg
            },
            sleep: { _ in }
        )

        let result = await fetcher.fetchBase64(videoID: "abcdefghijk")

        XCTAssertNotNil(result)
        XCTAssertEqual(requestedHosts, ["i.ytimg.com", "img.youtube.com"])
        XCTAssertNotNil(result.flatMap(Data.init(base64Encoded:)).flatMap(UIImage.init(data:)))
    }

    @MainActor
    func testRepairServiceLimitsWorkSkipsExistingCoverAndHonorsFailureCooldown() async {
        let suite = "thumbnail-repair-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = ThumbnailRepairCooldownStore(defaults: defaults, cooldown: 6 * 3600)
        let now = Date(timeIntervalSince1970: 10_000)
        cooldown.recordFailure(entryID: "missing-2", at: now)
        var fetched: [String] = []
        var uploaded: [String] = []
        let service = LibraryThumbnailRepairService(
            cooldown: cooldown,
            now: { now },
            fetch: { videoID in
                fetched.append(videoID)
                return Data([0xff, 0xd8, 0xff, 0xd9]).base64EncodedString()
            },
            upload: { entryID, _, _ in uploaded.append(entryID) }
        )
        let entries = [
            entry("covered", thumbURL: "https://example.com/cover.jpg"),
            entry("missing-1"), entry("missing-2"), entry("missing-3"),
            entry("missing-4"), entry("missing-5"), entry("missing-6"), entry("missing-7"),
        ]

        let repaired = await service.repair(entries: entries, token: "TOKEN")

        XCTAssertEqual(fetched, ["missing-1", "missing-3", "missing-4", "missing-5", "missing-6"])
        XCTAssertEqual(uploaded, ["missing-1", "missing-3", "missing-4", "missing-5", "missing-6"])
        XCTAssertEqual(repaired, Set(uploaded))
    }

    @MainActor
    func testRepairServiceRecordsFailureCooldownWhenFetchFails() async {
        let suite = "thumbnail-repair-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 20_000)
        let cooldown = ThumbnailRepairCooldownStore(defaults: defaults, cooldown: 6 * 3600)
        let service = LibraryThumbnailRepairService(
            cooldown: cooldown,
            now: { now },
            fetch: { _ in nil },
            upload: { _, _, _ in XCTFail("upload must not run") }
        )

        XCTAssertTrue((await service.repair(entries: [entry("missing")], token: "TOKEN")).isEmpty)
        XCTAssertFalse(cooldown.shouldAttempt(entryID: "missing", at: now.addingTimeInterval(60)))
        XCTAssertTrue(cooldown.shouldAttempt(entryID: "missing", at: now.addingTimeInterval(6 * 3600 + 1)))
    }
}

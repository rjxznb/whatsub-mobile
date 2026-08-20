import XCTest
import UIKit
@testable import whatsub_mobile

private actor RequestedHostRecorder {
    private var hosts: [String] = []

    func append(_ host: String) { hosts.append(host) }
    func snapshot() -> [String] { hosts }
}

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
        let requestedHosts = RequestedHostRecorder()
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.8)!
        let fetcher = YouTubeThumbnailFetcher(
            fetch: { url in
                await requestedHosts.append(url.host ?? "")
                if url.host == "i.ytimg.com" { throw URLError(.timedOut) }
                return jpeg
            },
            sleep: { _ in }
        )

        let result = await fetcher.fetchBase64(videoID: "abcdefghijk")

        XCTAssertNotNil(result)
        let hosts = await requestedHosts.snapshot()
        XCTAssertEqual(hosts, ["i.ytimg.com", "img.youtube.com"])
        let decoded = result.flatMap { Data(base64Encoded: $0) }
        XCTAssertNotNil(decoded.flatMap { UIImage(data: $0) })
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
            entry("covered", youtubeID: "covered0001", thumbURL: "https://example.com/cover.jpg"),
            entry("missing-1", youtubeID: "video000001"),
            entry("missing-2", youtubeID: "video000002"),
            entry("missing-3", youtubeID: "video000003"),
            entry("missing-4", youtubeID: "video000004"),
            entry("missing-5", youtubeID: "video000005"),
            entry("missing-6", youtubeID: "video000006"),
            entry("missing-7", youtubeID: "video000007"),
        ]

        let repaired = await service.repair(entries: entries, token: "TOKEN")

        XCTAssertEqual(fetched, ["video000001", "video000003", "video000004", "video000005", "video000006"])
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

        let repaired = await service.repair(
            entries: [entry("missing", youtubeID: "video000001")],
            token: "TOKEN"
        )

        XCTAssertTrue(repaired.isEmpty)
        XCTAssertFalse(cooldown.shouldAttempt(entryID: "missing", at: now.addingTimeInterval(60)))
        XCTAssertTrue(cooldown.shouldAttempt(entryID: "missing", at: now.addingTimeInterval(6 * 3600 + 1)))
    }
}

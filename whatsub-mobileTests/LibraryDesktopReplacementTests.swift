import XCTest
@testable import whatsub_mobile

final class LibraryDesktopReplacementTests: XCTestCase {
    private func entry(
        youtubeId: String = "dQw4w9WgXcQ",
        sourceUrl: String = "https://youtu.be/dQw4w9WgXcQ",
        durationSec: Int? = 600,
        videoUrl: String? = nil
    ) throws -> LibraryEntryDetail {
        let duration = durationSec.map { String($0) } ?? "null"
        let video = videoUrl.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(LibraryEntryDetail.self, from: Data("""
            {
              "id": "library-entry-1",
              "youtubeId": "\(youtubeId)",
              "sourceUrl": "\(sourceUrl)",
              "title": "Test video",
              "durationSec": \(duration),
              "transcriptSrt": null,
              "analysisJson": {"subtitles": [], "keyPhrases": []},
              "videoUrl": \(video),
              "audioUrl": null
            }
            """.utf8))
    }

    func testActionAppearsOnlyForVPNRequiredYouTubeEntry() throws {
        XCTAssertTrue(try entry().needsDesktopDownload)
        XCTAssertFalse(try entry(videoUrl: "https://cdn.example.com/video.mp4").needsDesktopDownload)
        XCTAssertFalse(
            try entry(
                youtubeId: "abcdefghijk",
                sourceUrl: "https://www.bilibili.com/video/BV1xx411c7mD"
            ).needsDesktopDownload
        )
    }

    func testEligibleEntryBuildsCanonicalYouTubeURL() throws {
        XCTAssertEqual(
            try entry().canonicalYouTubeURL,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testDesktopPresenceUsesExact120SecondBoundary() {
        XCTAssertTrue(DesktopPresence.isOffline(secondsAgo: nil))
        XCTAssertTrue(DesktopPresence.isOffline(secondsAgo: 121))
        XCTAssertFalse(DesktopPresence.isOffline(secondsAgo: 0))
        XCTAssertFalse(DesktopPresence.isOffline(secondsAgo: 120))
    }

    func testKnownDurationOverKnownLimitBlocksWithActualAndAllowedValues() {
        XCTAssertEqual(
            DesktopReplacementDurationPolicy.blockingMessage(
                durationSec: 1_201,
                maxVideoSeconds: 1_200
            ),
            "视频时长 20 分 1 秒，当前账号单个视频上限为 20 分钟，无法发送到桌面端下载。"
        )
    }

    func testDurationEqualToLimitAllowsEnqueue() {
        XCTAssertNil(
            DesktopReplacementDurationPolicy.blockingMessage(
                durationSec: 1_200,
                maxVideoSeconds: 1_200
            )
        )
    }

    func testUnknownDurationOrLimitAllowsEnqueue() {
        XCTAssertNil(
            DesktopReplacementDurationPolicy.blockingMessage(
                durationSec: nil,
                maxVideoSeconds: 1_200
            )
        )
        XCTAssertNil(
            DesktopReplacementDurationPolicy.blockingMessage(
                durationSec: 1_201,
                maxVideoSeconds: nil
            )
        )
    }

    func testReplacementRequestEncodesExactBackendContract() throws {
        let request = EnqueueReplacementRequest(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            targetLibraryEntryId: "library-entry-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )

        XCTAssertEqual(object, [
            "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "mode": "replace",
            "targetLibraryEntryId": "library-entry-1"
        ])
    }

    func testMeResponseDecodesServerAuthoritativeLibraryDurationLimit() throws {
        let data = Data("""
            {
              "email": "a@b.com",
              "hasActiveLicense": false,
              "libraryLimits": {
                "maxVideos": 3,
                "maxVideoBytes": 104857600,
                "maxVideoSeconds": 1200
              }
            }
            """.utf8)

        let response = try JSONDecoder().decode(MeResponse.self, from: data)

        XCTAssertEqual(response.libraryLimits?.maxVideoSeconds, 1_200)
    }

    func testQueueDTOsDecodeReplacementFieldsAndLegacyRows() throws {
        let replacement = try JSONDecoder().decode(ImportQueueItem.self, from: Data("""
            {
              "id": "queue-1",
              "url": "https://youtu.be/dQw4w9WgXcQ",
              "mode": "replace",
              "targetLibraryEntryId": "library-entry-1",
              "status": "pending",
              "error": null,
              "createdAt": 1000,
              "updatedAt": 1000
            }
            """.utf8))
        let legacy = try JSONDecoder().decode(ImportQueueItem.self, from: Data("""
            {
              "id": "queue-2",
              "url": "https://example.com/video",
              "status": "done",
              "error": null,
              "createdAt": 1000,
              "updatedAt": 1000
            }
            """.utf8))

        XCTAssertEqual(replacement.mode, "replace")
        XCTAssertEqual(replacement.targetLibraryEntryId, "library-entry-1")
        XCTAssertEqual(legacy.mode, "import")
        XCTAssertNil(legacy.targetLibraryEntryId)
    }

    func testActiveReplacementDetectionIgnoresDoneAndOrdinaryImports() throws {
        let data = Data("""
            {"items": [
              {"id":"done","url":"https://youtu.be/dQw4w9WgXcQ","mode":"replace","targetLibraryEntryId":"library-entry-1","status":"done","error":null,"createdAt":1,"updatedAt":4},
              {"id":"import","url":"https://youtu.be/dQw4w9WgXcQ","mode":"import","targetLibraryEntryId":null,"status":"processing","error":null,"createdAt":1,"updatedAt":3},
              {"id":"pending","url":"https://youtu.be/dQw4w9WgXcQ","mode":"replace","targetLibraryEntryId":"library-entry-1","status":"pending","error":null,"createdAt":1,"updatedAt":2}
            ], "desktopSeenSecondsAgo": 121}
            """.utf8)
        let response = try JSONDecoder().decode(ImportQueueListResponse.self, from: data)

        XCTAssertEqual(
            DesktopReplacementQueue.activeStatus(
                in: response.items,
                targetLibraryEntryId: "library-entry-1"
            ),
            .pending
        )
        XCTAssertTrue(DesktopPresence.isOffline(secondsAgo: response.desktopSeenSecondsAgo))
    }

    func testActiveReplacementDetectionSurfacesProcessing() throws {
        let item = try JSONDecoder().decode(ImportQueueItem.self, from: Data("""
            {"id":"processing","url":"https://youtu.be/dQw4w9WgXcQ","mode":"replace","targetLibraryEntryId":"library-entry-1","status":"processing","error":null,"createdAt":1,"updatedAt":2}
            """.utf8))

        XCTAssertEqual(
            DesktopReplacementQueue.activeStatus(
                in: [item],
                targetLibraryEntryId: "library-entry-1"
            ),
            .processing
        )
    }
}

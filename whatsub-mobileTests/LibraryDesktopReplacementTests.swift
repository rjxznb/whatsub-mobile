import XCTest
@testable import whatsub_mobile

private actor LibraryDesktopReplacementAPISpy: LibraryDesktopReplacementAPI {
    private let detail: LibraryEntryDetail
    private let suspendQueueList: Bool
    private let enqueueResponse: EnqueueImportResponse
    private var enqueueCalls = 0
    private var listCalls = 0
    private var libraryEntryCalls = 0
    private var listStartedWaiter: CheckedContinuation<Void, Never>?
    private var listRelease: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    init(
        detail: LibraryEntryDetail,
        suspendQueueList: Bool = false,
        enqueueResponse: EnqueueImportResponse = EnqueueImportResponse(
            id: "queue-1",
            desktopSeenSecondsAgo: 0,
            status: "pending"
        )
    ) {
        self.detail = detail
        self.suspendQueueList = suspendQueueList
        self.enqueueResponse = enqueueResponse
    }

    func libraryEntry(id: String, token: String) async throws -> LibraryEntryDetail {
        libraryEntryCalls += 1
        return detail
    }

    func listImportQueue(
        token: String
    ) async throws -> (items: [ImportQueueItem], desktopSeenSecondsAgo: Int?) {
        listCalls += 1
        listStartedWaiter?.resume()
        listStartedWaiter = nil

        if suspendQueueList {
            await withCheckedContinuation { continuation in
                if releaseRequested {
                    continuation.resume()
                } else {
                    listRelease = continuation
                }
            }
        }
        return ([], 0)
    }

    func enqueueReplacement(
        url: String,
        targetLibraryEntryId: String,
        token: String
    ) async throws -> EnqueueImportResponse {
        enqueueCalls += 1
        return enqueueResponse
    }

    func enqueueCallCount() -> Int { enqueueCalls }
    func listCallCount() -> Int { listCalls }
    func libraryEntryCallCount() -> Int { libraryEntryCalls }

    func waitUntilListStarts() async {
        if listCalls > 0 { return }
        await withCheckedContinuation { listStartedWaiter = $0 }
    }

    func releaseList() {
        releaseRequested = true
        listRelease?.resume()
        listRelease = nil
    }
}

@MainActor
final class LibraryDesktopReplacementTests: XCTestCase {
    func testToolbarIndicatorReflectsReplacementProgressAndFailure() {
        XCTAssertEqual(
            DesktopReplacementToolbarPresentation.indicator(
                state: .idle,
                activeStatus: nil
            ),
            .none
        )
        XCTAssertEqual(
            DesktopReplacementToolbarPresentation.indicator(
                state: .sending,
                activeStatus: nil
            ),
            .progress
        )
        XCTAssertEqual(
            DesktopReplacementToolbarPresentation.indicator(
                state: .idle,
                activeStatus: .processing
            ),
            .progress
        )
        XCTAssertEqual(
            DesktopReplacementToolbarPresentation.indicator(
                state: .failed("network"),
                activeStatus: nil
            ),
            .failure
        )
    }

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

    func testHostileYouTubeLookalikeHostsAreRejected() throws {
        XCTAssertFalse(
            try entry(
                sourceUrl: "https://notyoutube.com/watch?v=dQw4w9WgXcQ"
            ).needsDesktopDownload
        )
        XCTAssertFalse(
            try entry(
                sourceUrl: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"
            ).needsDesktopDownload
        )
    }

    func testSourceURLVideoIDMustMatchEntryYouTubeID() throws {
        let mismatched = try entry(
            youtubeId: "dQw4w9WgXcQ",
            sourceUrl: "https://www.youtube.com/watch?v=ECXAFUmdJkI"
        )

        XCTAssertFalse(mismatched.needsDesktopDownload)
        XCTAssertNil(mismatched.canonicalYouTubeURL)
    }

    func testMusicYouTubeEntryIsEligibleWhenSourceIDMatchesEntryID() throws {
        let musicEntry = try entry(
            youtubeId: "dQw4w9WgXcQ",
            sourceUrl: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
        )

        XCTAssertTrue(musicEntry.needsDesktopDownload)
        XCTAssertEqual(
            musicEntry.canonicalYouTubeURL,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testStrictHelperRecognizesOnlySupportedOfficialYouTubeHosts() {
        XCTAssertEqual(VideoSource.youtubeVideoID(from: "https://youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoSource.youtubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoSource.youtubeVideoID(from: "https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoSource.youtubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(VideoSource.youtubeVideoID(from: "https://notyoutube.com/watch?v=dQw4w9WgXcQ"))
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

    func testEnqueueResponseDecodesDeduplicatedProcessingStatus() throws {
        let response = try JSONDecoder().decode(EnqueueImportResponse.self, from: Data("""
            {
              "id": "queue-processing",
              "desktopSeenSecondsAgo": 12,
              "status": "processing"
            }
            """.utf8))

        XCTAssertEqual(response.status, "processing")
        XCTAssertEqual(response.desktopSeenSecondsAgo, 12)
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

    func testDetailPublishesBeforeSupplementalQueueRequestCompletes() async throws {
        let detail = try entry()
        let api = LibraryDesktopReplacementAPISpy(detail: detail, suspendQueueList: true)
        let viewModel = LibraryDetailViewModel(api: api)

        let load = Task { await viewModel.load(id: detail.id, token: "token") }
        await api.waitUntilListStarts()

        XCTAssertEqual(viewModel.entry?.id, detail.id)
        XCTAssertFalse(viewModel.loading)

        await api.releaseList()
        await load.value
    }

    func testPlaybackRefreshPublishesSignedURLWithoutPageLoadingOrManagedWork() async throws {
        let refreshed = try entry(videoUrl: "https://cdn.example.com/refreshed.mp4")
        let api = LibraryDesktopReplacementAPISpy(detail: refreshed)
        let viewModel = LibraryDetailViewModel(api: api)

        let result = try await viewModel.refreshPlaybackDetail(
            id: refreshed.id,
            token: "token"
        )

        XCTAssertEqual(result.videoUrl, "https://cdn.example.com/refreshed.mp4")
        XCTAssertEqual(viewModel.entry?.videoUrl, "https://cdn.example.com/refreshed.mp4")
        XCTAssertFalse(viewModel.loading)
        XCTAssertNil(viewModel.managedProgress)
        let detailCalls = await api.libraryEntryCallCount()
        let listCalls = await api.listCallCount()
        XCTAssertEqual(detailCalls, 1)
        XCTAssertEqual(listCalls, 0)
    }

    func testKnownOverLimitBlocksBeforeCallingEnqueueAPI() async throws {
        let detail = try entry(durationSec: 1_201)
        let api = LibraryDesktopReplacementAPISpy(detail: detail)
        let viewModel = LibraryDetailViewModel(api: api)
        viewModel.entry = detail

        await viewModel.enqueueReplacement(
            maxVideoSeconds: 1_200,
            token: "token",
            email: nil
        )

        let calls = await api.enqueueCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testDeduplicatedProcessingResponseSurfacesProcessingWithoutQueuePolling() async throws {
        let detail = try entry()
        let api = LibraryDesktopReplacementAPISpy(
            detail: detail,
            enqueueResponse: EnqueueImportResponse(
                id: "existing-processing",
                desktopSeenSecondsAgo: 0,
                status: "processing"
            )
        )
        let viewModel = LibraryDetailViewModel(api: api)
        viewModel.entry = detail

        await viewModel.enqueueReplacement(
            maxVideoSeconds: 1_200,
            token: "token",
            email: nil
        )

        let calls = await api.enqueueCallCount()
        let listCalls = await api.listCallCount()
        XCTAssertEqual(viewModel.activeReplacementStatus, .processing)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(listCalls, 0)
    }

    func testDurationEqualToLimitCallsEnqueueAPIOnce() async throws {
        let detail = try entry(durationSec: 1_200)
        let api = LibraryDesktopReplacementAPISpy(detail: detail)
        let viewModel = LibraryDetailViewModel(api: api)
        viewModel.entry = detail

        await viewModel.enqueueReplacement(
            maxVideoSeconds: 1_200,
            token: "token",
            email: nil
        )

        let calls = await api.enqueueCallCount()
        XCTAssertEqual(calls, 1)
    }

    func testUnknownDurationCallsEnqueueAPIOnce() async throws {
        let detail = try entry(durationSec: nil)
        let api = LibraryDesktopReplacementAPISpy(detail: detail)
        let viewModel = LibraryDetailViewModel(api: api)
        viewModel.entry = detail

        await viewModel.enqueueReplacement(
            maxVideoSeconds: 1_200,
            token: "token",
            email: nil
        )

        let calls = await api.enqueueCallCount()
        XCTAssertEqual(calls, 1)
    }

    func testUnknownLimitCallsEnqueueAPIOnce() async throws {
        let detail = try entry(durationSec: 1_201)
        let api = LibraryDesktopReplacementAPISpy(detail: detail)
        let viewModel = LibraryDetailViewModel(api: api)
        viewModel.entry = detail

        await viewModel.enqueueReplacement(
            maxVideoSeconds: nil,
            token: "token",
            email: nil
        )

        let calls = await api.enqueueCallCount()
        XCTAssertEqual(calls, 1)
    }
}

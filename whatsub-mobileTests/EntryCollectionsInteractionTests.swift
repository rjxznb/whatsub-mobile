import XCTest
@testable import whatsub_mobile

final class EntryCollectionsInteractionTests: XCTestCase {
    private var fileURL: URL!
    private var store: PendingPhraseStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-gloss-\(UUID().uuidString).json")
        store = PendingPhraseStore(fileURL: fileURL)
    }

    override func tearDown() {
        store = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        super.tearDown()
    }

    // Catches a regression that routes the phrase body through playback seek.
    func testPhraseBodyOpensCollectedGlossWhileTimestampSeeks() {
        XCTAssertEqual(
            EntryCollectionRowInteraction.action(for: .body, timestamp: 42),
            .openGloss
        )
        XCTAssertEqual(
            EntryCollectionRowInteraction.action(for: .timestamp, timestamp: 42),
            .seek(42)
        )
    }

    // Catches a regression that disables the body when a phrase lacks a cue time.
    func testPhraseBodyStillOpensGlossWithoutTimestamp() {
        XCTAssertEqual(
            EntryCollectionRowInteraction.action(for: .body, timestamp: nil),
            .openGloss
        )
    }

    // Catches a regression that shrinks the independent timestamp tap target.
    func testTimestampTargetHasAtLeastFortyFourPointHitArea() {
        XCTAssertGreaterThanOrEqual(
            EntryCollectionTimestampTargetLayout.minimumHitSize.width,
            44
        )
        XCTAssertGreaterThanOrEqual(
            EntryCollectionTimestampTargetLayout.minimumHitSize.height,
            44
        )
    }

    // Catches pending rows accidentally becoming collectable when mapped to gloss.
    func testPendingRowMapsToAlreadyCollectedGlossAndCannotDuplicate() {
        let row = EntryCollectionsList.Row.pending(PendingPhrase(
            id: UUID(),
            entryId: "video-a",
            videoTitle: "Test video",
            youtubeId: "test-id",
            phraseRaw: "see your point",
            contextSentence: "I see your point.",
            meaningZh: "明白你的意思",
            usageNote: "表示理解对方观点。",
            timestampSec: 42,
            collectedAt: 1_700_000_000
        ))

        assertAlreadyCollectedAndCannotDuplicate(
            row.glossSelection,
            expectedPhrase: "see your point",
            expectedTimestamp: 42
        )
    }

    // Catches synced rows accidentally becoming collectable when mapped to gloss.
    func testSyncedRowMapsToAlreadyCollectedGlossAndCannotDuplicate() {
        let row = EntryCollectionsList.Row.synced(MineItem(
            contributionId: 7,
            phraseNormalized: "take it with a grain of salt",
            phraseRaw: "take it with a grain of salt",
            meaningZh: "不要全信",
            usageNote: "提醒对信息保持保留。",
            contextSentence: "Take that claim with a grain of salt.",
            source: CorpusSource(
                kind: "library",
                url: nil,
                title: "Test video",
                timestampSec: nil,
                libraryEntryId: "video-a",
                youtubeId: "test-id",
                localPhotoId: nil
            ),
            contributedAt: 1_700_000_000_000,
            tags: []
        ))

        assertAlreadyCollectedAndCannotDuplicate(
            row.glossSelection,
            expectedPhrase: "take it with a grain of salt",
            expectedTimestamp: nil
        )
    }

    private func assertAlreadyCollectedAndCannotDuplicate(
        _ selection: CollectionGlossSelection,
        expectedPhrase: String,
        expectedTimestamp: Double?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(selection.phrase, expectedPhrase, file: file, line: line)
        XCTAssertEqual(selection.timestamp, expectedTimestamp, file: file, line: line)
        guard case .alreadyCollected = selection.collectionState else {
            return XCTFail("A collection row must not become collectable again", file: file, line: line)
        }

        let model = HighlightWordCardModel(
            gloss: WordGloss(
                word: selection.phrase,
                translation: selection.meaning,
                note: selection.usageNote,
                sourceContext: nil,
                collectionState: selection.collectionState
            ),
            store: store,
            speak: { _ in },
            stop: {},
            ipaLookup: { _ in nil }
        )

        XCTAssertFalse(model.canCollect, file: file, line: line)
        XCTAssertFalse(model.collect(), file: file, line: line)
        XCTAssertEqual(store.total, 0, file: file, line: line)
    }
}

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

        let selection = CollectionGlossSelection(
            phrase: "see your point",
            meaning: "明白你的意思",
            usageNote: "表示理解对方观点。",
            contextSentence: "I see your point.",
            timestamp: 42,
            collectionState: .alreadyCollected
        )

        XCTAssertEqual(selection.phrase, "see your point")
        XCTAssertEqual(selection.contextSentence, "I see your point.")
        guard case .alreadyCollected = selection.collectionState else {
            return XCTFail("A collection gloss must not be collectable again")
        }
    }

    // Catches a regression that disables the body when a phrase lacks a cue time.
    func testPhraseBodyStillOpensGlossWithoutTimestamp() {
        XCTAssertEqual(
            EntryCollectionRowInteraction.action(for: .body, timestamp: nil),
            .openGloss
        )
    }

    // Catches a regression that presents an existing collection as a collectable gloss.
    func testCollectedGlossCannotCreatePendingDuplicate() {
        let gloss = WordGloss(
            word: "see your point",
            translation: "明白你的意思",
            note: "表示理解对方观点。",
            sourceContext: nil,
            collectionState: .alreadyCollected
        )
        let model = HighlightWordCardModel(
            gloss: gloss,
            store: store,
            speak: { _ in },
            stop: {},
            ipaLookup: { _ in nil }
        )

        XCTAssertFalse(model.canCollect)
        XCTAssertFalse(model.collect())
        XCTAssertEqual(store.total, 0)
    }
}

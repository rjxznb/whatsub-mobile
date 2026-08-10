import XCTest
@testable import whatsub_mobile

final class HighlightWordCardModelTests: XCTestCase {
    private var fileURL: URL!
    private var store: PendingPhraseStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight-card-\(UUID().uuidString).json")
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

    func testAppearanceSpeaksOnceReplaySpeaksAgainAndDisappearStops() {
        var spoken: [String] = []
        var stopCount = 0
        let model = makeModel(
            speak: { spoken.append($0) },
            stop: { stopCount += 1 }
        )

        model.appear()
        model.appear()
        XCTAssertEqual(spoken, ["welcome back"])

        model.replay()
        XCTAssertEqual(spoken, ["welcome back", "welcome back"])

        model.disappear()
        XCTAssertEqual(stopCount, 1)
    }

    func testCollectWritesOnceAndReportsSaved() {
        let model = makeModel()

        XCTAssertFalse(model.saved)
        XCTAssertTrue(model.collect())
        XCTAssertTrue(model.saved)
        XCTAssertFalse(model.collect())
        XCTAssertEqual(store.total, 1)

        let reopened = makeModel()
        XCTAssertTrue(reopened.saved)
        XCTAssertFalse(reopened.collect())
        XCTAssertEqual(store.total, 1)
    }

    func testInitializationLooksUpIPAForTheHighlightedPhrase() {
        var lookedUp: [String] = []

        let model = makeModel(ipaLookup: {
            lookedUp.append($0)
            return "/ˈwelkəm bæk/"
        })

        XCTAssertEqual(lookedUp, ["welcome back"])
        XCTAssertEqual(model.ipa, "/ˈwelkəm bæk/")
    }

    private func makeModel(
        speak: @escaping (String) -> Void = { _ in },
        stop: @escaping () -> Void = {},
        ipaLookup: @escaping (String) -> String? = { _ in nil }
    ) -> HighlightWordCardModel {
        HighlightWordCardModel(
            gloss: WordGloss(
                word: "welcome back",
                translation: "欢迎回来",
                note: "用于欢迎某人回来。",
                saveContext: WordGloss.SaveContext(
                    entryId: "video-a",
                    videoTitle: "Test video",
                    youtubeId: "test-id",
                    contextSentence: "They said welcome back.",
                    timestampSec: 12.5
                )
            ),
            store: store,
            speak: speak,
            stop: stop,
            ipaLookup: ipaLookup
        )
    }
}

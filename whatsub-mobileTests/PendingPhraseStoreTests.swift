import XCTest
@testable import whatsub_mobile

final class PendingPhraseStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-phrases-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        super.tearDown()
    }

    func testAddIfAbsentRejectsSamePhraseInSameEntryIgnoringCaseAndWhitespace() {
        let store = PendingPhraseStore(fileURL: fileURL)

        XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: "Welcome   Back")))
        XCTAssertFalse(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: "  welcome\tback\n")))

        XCTAssertEqual(store.total, 1)
        XCTAssertTrue(store.contains(entryId: "video-a", phraseRaw: "WELCOME BACK"))
    }

    func testAddIfAbsentAllowsSamePhraseInDifferentEntries() {
        let store = PendingPhraseStore(fileURL: fileURL)

        XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-a", phrase: "welcome back")))
        XCTAssertTrue(store.addIfAbsent(makePhrase(entryId: "video-b", phrase: "welcome back")))

        XCTAssertEqual(store.total, 2)
    }

    private func makePhrase(entryId: String, phrase: String) -> PendingPhrase {
        PendingPhrase(
            id: UUID(),
            entryId: entryId,
            videoTitle: "Test video",
            youtubeId: "test-id",
            phraseRaw: phrase,
            contextSentence: "They said welcome back.",
            meaningZh: "欢迎回来",
            usageNote: nil,
            timestampSec: 12.5,
            collectedAt: 100
        )
    }
}

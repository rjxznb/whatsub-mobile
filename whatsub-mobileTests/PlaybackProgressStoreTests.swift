import XCTest
@testable import whatsub_mobile

final class PlaybackProgressStoreTests: XCTestCase {
    func testRoundTripNormalizesToWholeSeconds() async {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
        await store.save(
            position: 42.8,
            for: "entry-1",
            now: Date(timeIntervalSince1970: 10)
        )

        let reloaded = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
        let restored = await reloaded.position(for: "entry-1")
        XCTAssertEqual(restored, 42)
    }

    func testInvalidTimesAreIgnoredAndCorruptFileRecovers() async throws {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not-json".utf8).write(to: fileURL)

        let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)
        await store.save(position: .nan, for: "bad")
        await store.save(position: -1, for: "negative")
        let invalid = await store.position(for: "bad")
        let negative = await store.position(for: "negative")
        XCTAssertNil(invalid)
        XCTAssertNil(negative)

        await store.save(position: 7, for: "good")
        let valid = await store.position(for: "good")
        XCTAssertEqual(valid, 7)
    }

    func testEvictsLeastRecentlyUsedPastCapacity() async {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PlaybackProgressStore(fileURL: fileURL, capacity: 500)

        for index in 0..<500 {
            await store.save(
                position: Double(index + 1),
                for: "e-\(index)",
                now: Date(timeIntervalSince1970: Double(index))
            )
        }
        _ = await store.position(for: "e-0")
        await store.save(
            position: 501,
            for: "e-500",
            now: Date(timeIntervalSince1970: 501)
        )

        let recentlyRead = await store.position(for: "e-0")
        let evicted = await store.position(for: "e-1")
        XCTAssertNotNil(recentlyRead)
        XCTAssertNil(evicted)
    }

    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-progress-\(UUID().uuidString).json")
    }
}

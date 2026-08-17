import XCTest
@testable import whatsub_mobile

final class AnalysisPartialCheckpointTests: XCTestCase {
    private func sourceCues(_ count: Int) -> [Cue] {
        (0..<count).map { Cue(index: $0, time: Double($0), endTime: Double($0 + 1), text: "cue \($0)") }
    }

    private func analyzed(_ cue: Cue) -> Cue {
        Cue(
            index: cue.index,
            time: cue.time,
            endTime: cue.endTime,
            text: cue.text,
            translation: "译文 \(cue.index)"
        )
    }

    func testPersistsAndCommitsOnePartialBatchAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisPartialCheckpointTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisCheckpointStore(directory: directory)
        let source = sourceCues(50)
        var checkpoint = store.makeCheckpoint(sourceID: "video", cues: source)

        for offset in 0..<42 {
            try checkpoint.recordCue(
                batchIndex: 0,
                cueOffset: offset,
                cue: analyzed(source[offset]),
                needsAnnotationRepair: false,
                sourceCues: source
            )
        }
        try store.save(checkpoint)
        var restored = try XCTUnwrap(store.load(sourceID: "video", cues: source))
        XCTAssertEqual(restored.partialBatch?.entries.count, 42)
        XCTAssertTrue(restored.completedBatches.isEmpty)

        for offset in 42..<50 {
            try restored.recordCue(
                batchIndex: 0,
                cueOffset: offset,
                cue: analyzed(source[offset]),
                needsAnnotationRepair: false,
                sourceCues: source
            )
        }
        let result = source.map(analyzed)
        try restored.commitPartialBatch(index: 0, result: result, sourceCues: source)
        XCTAssertNil(restored.partialBatch)
        XCTAssertEqual(restored.completedBatches[0]?.count, 50)
    }

    func testAllowsOnlyMonotonicAnnotationRepairUpgrade() throws {
        let source = sourceCues(1)
        var checkpoint = AnalysisCheckpoint(fingerprint: "test")
        let translationOnly = analyzed(source[0])
        try checkpoint.recordCue(
            batchIndex: 0,
            cueOffset: 0,
            cue: translationOnly,
            needsAnnotationRepair: true,
            sourceCues: source
        )
        var repaired = translationOnly
        repaired.isKeyPoint = true
        repaired.highlightWords = ["cue"]
        repaired.highlightTranslations = ["cue": "译文"]
        repaired.keyNotes = ["cue": "表示当前字幕中的核心表达，常用于描述具体线索、提示内容或对话片段的自然交流语境。"]
        try checkpoint.recordCue(
            batchIndex: 0,
            cueOffset: 0,
            cue: repaired,
            needsAnnotationRepair: false,
            sourceCues: source
        )
        XCTAssertEqual(checkpoint.partialBatch?.entries.first?.cue.highlightWords, ["cue"])
        XCTAssertThrowsError(try checkpoint.recordCue(
            batchIndex: 0,
            cueOffset: 0,
            cue: translationOnly,
            needsAnnotationRepair: true,
            sourceCues: source
        ))
    }

    func testLoadsVersionOneCheckpointAsVersionTwo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisCheckpointMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisCheckpointStore(directory: directory)
        let source = sourceCues(1)
        let checkpoint = store.makeCheckpoint(sourceID: "legacy", cues: source)
        try store.save(checkpoint)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        object["version"] = 1
        object.removeValue(forKey: "partialBatch")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)

        let migrated = try XCTUnwrap(store.load(sourceID: "legacy", cues: source))
        XCTAssertEqual(migrated.version, AnalysisCheckpoint.schemaVersion)
        XCTAssertNil(migrated.partialBatch)
    }
}

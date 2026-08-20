import XCTest
@testable import whatsub_mobile

final class AppleTranslationFallbackTests: XCTestCase {
    func testFallbackOnlyRunsAfterRetryableManagedModelFailures() {
        for code in [
            ManagedAnalysisFailureCode.upstreamUnavailable,
            .invalidAnalysisCue,
            .invalidSSE,
        ] {
            XCTAssertTrue(AppleTranslationFallback.isEligible(status: .failed, errorCode: code))
        }
        for code in [
            ManagedAnalysisFailureCode.freeUsedUp,
            .quotaExceeded,
            .videoTooLong,
            .durationUnknown,
        ] {
            XCTAssertFalse(AppleTranslationFallback.isEligible(status: .failed, errorCode: code))
        }
        XCTAssertFalse(AppleTranslationFallback.isEligible(status: .cancelled, errorCode: .upstreamUnavailable))
        XCTAssertFalse(AppleTranslationFallback.isEligible(status: .failed, errorCode: nil))
    }

    func testRequestsOnlyIncludeMissingTranslations() {
        let cues = [
            Cue(index: 0, time: 0, endTime: 1, text: "Already", translation: "已有翻译"),
            Cue(index: 1, time: 1, endTime: 2, text: "Missing", translation: ""),
            Cue(index: 2, time: 2, endTime: 3, text: "Whitespace", translation: "  "),
        ]

        XCTAssertEqual(
            AppleTranslationFallback.requests(from: cues),
            [
                AppleTranslationRequestItem(cueIndex: 1, sourceText: "Missing"),
                AppleTranslationRequestItem(cueIndex: 2, sourceText: "Whitespace"),
            ]
        )
    }

    func testAppleResponseNeverOverwritesModelTranslation() {
        let cues = [
            Cue(index: 0, time: 0, endTime: 1, text: "Model", translation: "模型翻译"),
            Cue(index: 1, time: 1, endTime: 2, text: "Apple", translation: ""),
        ]
        let preserved = AppleTranslationFallback.applying(
            translation: "不应覆盖",
            toCueIndex: 0,
            in: cues
        )
        let filled = AppleTranslationFallback.applying(
            translation: "苹果翻译",
            toCueIndex: 1,
            in: preserved
        )

        XCTAssertEqual(filled[0].translation, "模型翻译")
        XCTAssertEqual(filled[1].translation, "苹果翻译")
    }

    func testCheckpointRoundTripsAndRejectsChangedEnglishTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleTranslationCheckpointStore(directory: directory)
        let source = [Cue(index: 0, time: 0, endTime: 1, text: "Hello")]
        let translated = [Cue(index: 0, time: 0, endTime: 1, text: "Hello", translation: "你好")]

        try store.save(entryID: "entry", sourceCues: source, translatedCues: translated)
        XCTAssertEqual(try store.load(entryID: "entry", sourceCues: source), [0: "你好"])

        let changed = [Cue(index: 0, time: 0, endTime: 1, text: "Changed")]
        XCTAssertEqual(try store.load(entryID: "entry", sourceCues: changed), [:])
    }
}

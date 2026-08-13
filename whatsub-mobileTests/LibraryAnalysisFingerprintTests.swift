import XCTest
@testable import whatsub_mobile

final class LibraryAnalysisFingerprintTests: XCTestCase {
    func testMatchesBackendCanonicalFixture() {
        let cue = Cue(index: 1, time: 0, endTime: 2, text: "Hello", translation: "")

        XCTAssertEqual(
            LibraryAnalysisFingerprint.compute(title: "Ignored title", cues: [cue]),
            "516d9e94759d8feb7b2e720a6aed8f4da0929e5f19d0c54a3c475c0f3af3f8d7"
        )
    }

    func testTranslationAndHighlightsDoNotChangeSourceSubtitleFingerprint() {
        let before = makeCue(translation: "", isKeyPoint: false)
        let after = makeCue(translation: "你好", isKeyPoint: true)

        XCTAssertEqual(
            LibraryAnalysisFingerprint.compute(title: "Interview", cues: [before]),
            LibraryAnalysisFingerprint.compute(title: "Interview", cues: [after])
        )
    }

    private func makeCue(translation: String, isKeyPoint: Bool) -> Cue {
        var cue = Cue(index: 1, time: 0, endTime: 2, text: "Hello", translation: translation)
        cue.isKeyPoint = isKeyPoint
        cue.highlightWords = isKeyPoint ? ["Hello"] : []
        return cue
    }
}

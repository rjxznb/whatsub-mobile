import XCTest
@testable import whatsub_mobile

final class LibraryAnalysisFingerprintTests: XCTestCase {
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

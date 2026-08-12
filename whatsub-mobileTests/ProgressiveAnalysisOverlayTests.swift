import XCTest
@testable import whatsub_mobile

final class ProgressiveAnalysisOverlayTests: XCTestCase {
    private func generated(
        index: Int = 0,
        time: Double = 1,
        endTime: Double = 2,
        text: String = "Authoritative English",
        translation: String = "权威译文"
    ) -> Cue {
        var cue = Cue(index: index, time: time, endTime: endTime, text: text, translation: translation)
        cue.isKeyPoint = true
        cue.highlightWords = ["Authoritative"]
        cue.keyNotes = ["Authoritative": "重点"]
        cue.highlightTranslations = ["Authoritative": "权威"]
        return cue
    }

    func testMergeCopiesOnlyGeneratedFieldsOverAuthoritativeBaseline() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)

        overlay.merge([ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [generated()])])
        let displayed = overlay.displayedCues(from: baseline)

        XCTAssertEqual(displayed[0].index, 0)
        XCTAssertEqual(displayed[0].time, 1)
        XCTAssertEqual(displayed[0].endTime, 2)
        XCTAssertEqual(displayed[0].text, "Authoritative English")
        XCTAssertEqual(displayed[0].translation, "权威译文")
        XCTAssertEqual(displayed[0].highlightWords, ["Authoritative"])
        XCTAssertEqual(overlay.resolvedIndexes, Set([0]))
    }

    func testMergeRejectsTamperingEmptyTranslationAndUnknownIndexes() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)

        overlay.merge([ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [
            generated(text: "Tampered"),
            generated(time: 1.1),
            generated(translation: ""),
            generated(index: 99),
        ])])

        XCTAssertTrue(overlay.resolvedIndexes.isEmpty)
        XCTAssertEqual(overlay.displayedCues(from: baseline)[0].translation, "")
    }

    func testRepeatedBatchIsIdempotentAndCannotOverwriteFirstCommit() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)
        overlay.merge([ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [generated(translation: "第一次")])])
        overlay.merge([ManagedAnalysisCompletedBatch(batchIndex: 0, subtitles: [generated(translation: "第二次")])])

        XCTAssertEqual(overlay.displayedCues(from: baseline)[0].translation, "第一次")
        XCTAssertEqual(overlay.resolvedIndexes.count, 1)
    }

    func testPreviewRendersImmediatelyButCannotOverwriteEnglishAuthority() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)
        let preview = ManagedAnalysisStreamCue(
            type: .cue,
            index: 0,
            time: 1,
            endTime: 2,
            text: "Authoritative English",
            translation: "即时译文",
            isKeyPoint: true,
            highlightWords: ["Authoritative"],
            keyNotes: ["Authoritative": "重点"],
            highlightTranslations: ["Authoritative": "权威"]
        )

        overlay.replacePreviews([
            .init(batchIndex: 0, attempt: 1, cueIndex: 0): preview,
        ])
        let displayed = overlay.displayedCues(from: baseline)

        XCTAssertEqual(displayed[0].text, "Authoritative English")
        XCTAssertEqual(displayed[0].time, 1)
        XCTAssertEqual(displayed[0].translation, "即时译文")
        XCTAssertEqual(overlay.resolvedIndexes, [0])
    }

    func testPreviewRejectsTamperedBaselineFields() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)
        let preview = ManagedAnalysisStreamCue(
            type: .cue,
            index: 0,
            time: 1,
            endTime: 2,
            text: "Tampered English",
            translation: "不应出现",
            isKeyPoint: false,
            highlightWords: [],
            keyNotes: [:],
            highlightTranslations: [:]
        )

        overlay.replacePreviews([
            .init(batchIndex: 0, attempt: 1, cueIndex: 0): preview,
        ])

        XCTAssertEqual(overlay.displayedCues(from: baseline)[0].translation, "")
        XCTAssertTrue(overlay.resolvedIndexes.isEmpty)
    }

    func testDurableBatchSupersedesItsPreviewWithoutDoubleCounting() {
        let baseline = [Cue(index: 0, time: 1, endTime: 2, text: "Authoritative English")]
        var overlay = ProgressiveAnalysisOverlay(baseline: baseline)
        let preview = ManagedAnalysisStreamCue(
            type: .cue,
            index: 0,
            time: 1,
            endTime: 2,
            text: "Authoritative English",
            translation: "预览",
            isKeyPoint: false,
            highlightWords: [],
            keyNotes: [:],
            highlightTranslations: [:]
        )
        overlay.replacePreviews([
            .init(batchIndex: 0, attempt: 1, cueIndex: 0): preview,
        ])
        overlay.merge([.init(batchIndex: 0, subtitles: [generated(translation: "持久结果")])])

        XCTAssertEqual(overlay.displayedCues(from: baseline)[0].translation, "持久结果")
        XCTAssertEqual(overlay.resolvedIndexes.count, 1)
    }

    func testPollingPolicyUsesVisibleActiveCadenceAndBoundedBackoff() {
        XCTAssertEqual(ManagedAnalysisPollPolicy.delay(status: .running, failureCount: 0), 2)
        XCTAssertEqual(ManagedAnalysisPollPolicy.delay(status: .queued, failureCount: 0), 5)
        XCTAssertNil(ManagedAnalysisPollPolicy.delay(status: .pausedQuota, failureCount: 0))
        XCTAssertNil(ManagedAnalysisPollPolicy.delay(status: .completed, failureCount: 0))
        XCTAssertEqual(ManagedAnalysisPollPolicy.delay(status: .running, failureCount: 1), 2)
        XCTAssertEqual(ManagedAnalysisPollPolicy.delay(status: .running, failureCount: 2), 4)
        XCTAssertEqual(ManagedAnalysisPollPolicy.delay(status: .running, failureCount: 20), 15)
    }

    func testProgressPresentationKeepsTerminalEnglishEntriesActionable() {
        let base = ManagedAnalysisJob(
            jobId: "job", status: .running, tier: .pro,
            createdAt: 1, updatedAt: 2, completedCues: 150, totalCues: 620,
            tokensIn: 0, tokensOut: 0, errorCode: nil, resultEntryId: "entry"
        )
        XCTAssertEqual(ManagedAnalysisProgressState(job: base).label, "AI 解析中 · 150/620")

        let failed = ManagedAnalysisJob(
            jobId: "job", status: .failed, tier: .pro,
            createdAt: 1, updatedAt: 2, completedCues: 150, totalCues: 620,
            tokensIn: 0, tokensOut: 0, errorCode: .upstreamUnavailable, resultEntryId: "entry"
        )
        let presentation = ManagedAnalysisProgressState(job: failed)
        XCTAssertEqual(presentation.label, "仅英文 · AI 解析失败")
        XCTAssertTrue(presentation.canResume)
        XCTAssertTrue(presentation.blocksEditing)
    }
}

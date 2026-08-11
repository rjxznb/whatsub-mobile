import XCTest
@testable import whatsub_mobile

@MainActor
final class ImportBYOKResumeTests: XCTestCase {
    private enum StubError: Error { case stop }

    private func settings() -> LlmSettings {
        var value = LlmSettings()
        value.useManagedRelay = false
        value.baseUrl = "https://provider.example/v1"
        value.apiKey = "key"
        value.model = "model"
        return value
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportBYOKResumeTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testForegroundResumeReceivesPersistedCompletedBatch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisCheckpointStore(directory: directory)
        let resumed = expectation(description: "resumed from checkpoint")
        var callCount = 0
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
        let analyzed = Cue(
            index: 0, time: 0, endTime: 1, text: "Hello", translation: "你好"
        )
        let vm = ImportViewModel(
            settingsProvider: { self.settings() },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: 60)
            },
            titleFetcher: { _ in "Title" },
            thumbnailFetcher: { _ in nil },
            checkpointStore: store,
            localAnalyzer: { _, _, resume, _, _ in
                callCount += 1
                if callCount == 1 {
                    try resume.onBatchCompleted(0, [analyzed])
                    throw AnalysisPausedError()
                }
                XCTAssertEqual(resume.completedBatches[0]?.first?.translation, "你好")
                resumed.fulfill()
                throw StubError.stop
            }
        )

        vm.setSceneActive(false, token: nil)
        await vm.run(urlOrId: "abcdefghijk", token: "token")
        guard case .byokPaused = vm.state else {
            return XCTFail("first run should pause at a safe boundary")
        }

        vm.setSceneActive(true, token: "token")
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(callCount, 2)
    }

    func testPersistedCompletedSummaryIsForwardedForResume() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisCheckpointStore(directory: directory)
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
        let analyzed = Cue(
            index: 0, time: 0, endTime: 1, text: "Hello", translation: "你好"
        )
        var checkpoint = store.makeCheckpoint(sourceID: "abcdefghijk", cues: [cue])
        try checkpoint.recordBatch(index: 0, result: [analyzed], sourceCues: [cue])
        checkpoint.recordSummary(AnalysisSummary(
            keyPhrases: [KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "存钱")],
            learningGuide: nil,
            contextProfile: nil
        ))
        try store.save(checkpoint)
        let resumed = expectation(description: "completed summary forwarded")
        let vm = ImportViewModel(
            settingsProvider: { self.settings() },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: 60)
            },
            titleFetcher: { _ in "Title" },
            thumbnailFetcher: { _ in nil },
            checkpointStore: store,
            localAnalyzer: { _, _, resume, _, _ in
                XCTAssertEqual(
                    resume.completedSummary?.keyPhrases.first?.expression,
                    "save up"
                )
                resumed.fulfill()
                throw StubError.stop
            }
        )

        await vm.run(urlOrId: "abcdefghijk", token: "token")

        await fulfillment(of: [resumed], timeout: 1)
    }

    func testExplicitCancelDeletesCheckpointAfterFailedRun() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisCheckpointStore(directory: directory)
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
        let analyzed = Cue(
            index: 0, time: 0, endTime: 1, text: "Hello", translation: "你好"
        )
        let vm = ImportViewModel(
            settingsProvider: { self.settings() },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: 60)
            },
            titleFetcher: { _ in "Title" },
            thumbnailFetcher: { _ in nil },
            checkpointStore: store,
            localAnalyzer: { _, _, resume, _, _ in
                try resume.onBatchCompleted(0, [analyzed])
                throw StubError.stop
            }
        )

        await vm.run(urlOrId: "abcdefghijk", token: "token")
        XCTAssertNotNil(try store.load(sourceID: "abcdefghijk", cues: [cue]))

        vm.cancelWork()

        XCTAssertNil(try store.load(sourceID: "abcdefghijk", cues: [cue]))
    }

    func testZeroProgressTimeoutStopsStalledBYOKAndBuildsDiagnostic() async {
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "SECRET-SUBTITLE")
        let vm = ImportViewModel(
            settingsProvider: { self.settings() },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: 60)
            },
            titleFetcher: { _ in "SECRET-TITLE" },
            thumbnailFetcher: { _ in nil },
            noProgressWait: { },
            localAnalyzer: { _, _, _, _, diagnostic in
                diagnostic(AnalysisStreamEvent(stage: .responseOpen, batch: 0, parsedCues: 0))
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw StubError.stop
            }
        )

        await vm.run(urlOrId: "abcdefghijk", token: "SECRET-TOKEN")

        guard case .error(let message) = vm.state else {
            return XCTFail("stalled analysis must become an error")
        }
        XCTAssertTrue(message.contains("90"))
        let report = vm.diagnosticReport
        XCTAssertEqual(report?.category, "byok-stream")
        XCTAssertTrue(report?.copyText.contains("stage=response_open") == true)
        XCTAssertFalse(report?.copyText.contains("SECRET-SUBTITLE") == true)
        XCTAssertFalse(report?.copyText.contains("SECRET-TITLE") == true)
        XCTAssertFalse(report?.copyText.contains("SECRET-TOKEN") == true)
    }

    func testFirstParsedCueDisarmsZeroProgressTimeout() async {
        let cue = Cue(index: 0, time: 0, endTime: 1, text: "Hello")
        let completed = expectation(description: "analysis continued after progress")
        let vm = ImportViewModel(
            settingsProvider: { self.settings() },
            captionExtractor: { _, _ in
                CaptionExtractionResult(cues: [cue], durationSec: 60)
            },
            titleFetcher: { _ in "Title" },
            thumbnailFetcher: { _ in nil },
            noProgressWait: { await Task.yield() },
            localAnalyzer: { _, _, _, progress, diagnostic in
                diagnostic(AnalysisStreamEvent(stage: .parsing, batch: 0, parsedCues: 1))
                progress(1, 2)
                completed.fulfill()
                throw StubError.stop
            }
        )

        await vm.run(urlOrId: "abcdefghijk", token: "token")

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertNil(vm.diagnosticReport)
    }
}

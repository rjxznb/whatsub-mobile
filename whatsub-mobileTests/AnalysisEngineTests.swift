import XCTest
@testable import whatsub_mobile

final class AnalysisEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal Cue via JSON decode (mirrors the lenient Decodable init).
    private func cueFixture(index: Int) -> Cue {
        let json = """
        {"index":\(index),"time":\(Double(index)),"endTime":\(Double(index) + 1.5),"text":"word \(index)","translation":"词 \(index)","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        """.data(using: .utf8)!
        var cue = try! JSONDecoder().decode(Cue.self, from: json)
        cue.index = index
        return cue
    }

    // MARK: - parseCue / parseSummary (streaming path)
    //
    // Post 2026-06-21 streaming refactor — AnalysisEngine no longer offers
    // a parseCueLines(raw:) helper. The streaming pipeline funnels every
    // line through `JsonLineParser` → `AnalysisEngine.parseCue(obj:)` /
    // `parseSummary(obj:)`. The tests below drive the same JSONL inputs
    // through that pipe and assert the same end-state.

    private func driveLines(_ raw: String) -> (cues: [Cue], keyPhrases: [KeyPhrase]) {
        let parser = JsonLineParser()
        var cues: [Cue] = []
        var keyPhrases: [KeyPhrase] = []
        // Append trailing newline so the parser sees a clean line boundary
        // even when the test fixture's last line omits it.
        let input = raw.hasSuffix("\n") ? raw : raw + "\n"
        parser.feed(input) { obj in
            if let cue = AnalysisEngine.parseCue(obj) { cues.append(cue) }
            if let kp = AnalysisEngine.parseSummary(obj) { keyPhrases = kp }
        }
        parser.flush { obj in
            if let cue = AnalysisEngine.parseCue(obj) { cues.append(cue) }
            if let kp = AnalysisEngine.parseSummary(obj) { keyPhrases = kp }
        }
        return (cues, keyPhrases)
    }

    func testParseCueLinesSkipsNonJSONAndSummary() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.6,"text":"Hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        garbage line
        {"type":"cue","index":1,"time":1.6,"endTime":3,"text":"Save up","translation":"攒钱","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{"Save up":"攒钱的意思"},"highlightTranslations":{"Save up":"攒钱"}}
        """
        let cues = driveLines(raw).cues
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].translation, "攒钱")
        XCTAssertEqual(cues[1].highlightWords, ["Save up"])
    }

    func testParseCueLinesSkipsSummaryLine() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.0,"text":"Hello","translation":"你好","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        {"type":"summary","keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]}
        """
        let cues = driveLines(raw).cues
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello")
    }

    func testParseCueLinesReturnsEmptyForGarbage() {
        let cues = driveLines("not json at all\n\nalso bad\n").cues
        XCTAssertTrue(cues.isEmpty)
    }

    func testParseSummaryLine() {
        let raw = #"{"type":"summary","keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]}"#
        let kp = driveLines(raw).keyPhrases
        XCTAssertEqual(kp.first?.expression, "save up")
        XCTAssertEqual(kp.first?.meaningZh, "攒钱")
        XCTAssertEqual(kp.first?.usage, "存钱")
    }

    func testParseSummaryLineReturnsEmptyWhenNoSummaryLine() {
        let raw = #"{"type":"cue","index":0,"time":0,"endTime":1,"text":"hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}"#
        let kp = driveLines(raw).keyPhrases
        XCTAssertTrue(kp.isEmpty)
    }

    func testParseSummaryLineMultipleKeyPhrases() {
        let raw = #"{"type":"summary","keyPhrases":[{"expression":"catch up","meaningZh":"赶上","usage":"用于表示追赶进度"},{"expression":"save up","meaningZh":"攒钱","usage":"存钱备用"}]}"#
        let kp = driveLines(raw).keyPhrases
        XCTAssertEqual(kp.count, 2)
        XCTAssertEqual(kp[0].expression, "catch up")
        XCTAssertEqual(kp[1].expression, "save up")
    }

    // MARK: - batches

    func testBatching() {
        let cues = (0..<120).map { i in cueFixture(index: i) }
        XCTAssertEqual(AnalysisEngine.batches(cues, size: 50).count, 3)
    }

    func testBatchingExact() {
        let cues = (0..<50).map { i in cueFixture(index: i) }
        XCTAssertEqual(AnalysisEngine.batches(cues, size: 50).count, 1)
    }

    func testBatchingEmpty() {
        XCTAssertEqual(AnalysisEngine.batches([], size: 50).count, 0)
    }

    func testBatchingPreservesAllCues() {
        let cues = (0..<73).map { i in cueFixture(index: i) }
        let batched = AnalysisEngine.batches(cues, size: 50)
        XCTAssertEqual(batched.count, 2)
        XCTAssertEqual(batched[0].count, 50)
        XCTAssertEqual(batched[1].count, 23)
    }

    // MARK: - AnalysisJson.assembled

    func testAssembledFactory() {
        let cues = (0..<3).map { i in cueFixture(index: i) }
        let kp = [KeyPhrase(expression: "save up", meaningZh: "攒钱", usage: "存钱")]
        let result = AnalysisJson.assembled(subtitles: cues, keyPhrases: kp)
        XCTAssertEqual(result.subtitles.count, 3)
        XCTAssertEqual(result.keyPhrases.count, 1)
        XCTAssertEqual(result.keyPhrases[0].expression, "save up")
    }
}

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

    // MARK: - parseCueLines

    func testParseCueLinesSkipsNonJSONAndSummary() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.6,"text":"Hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        garbage line
        {"type":"cue","index":1,"time":1.6,"endTime":3,"text":"Save up","translation":"攒钱","isKeyPoint":true,"highlightWords":["Save up"],"keyNotes":{"Save up":"攒钱的意思"},"highlightTranslations":{"Save up":"攒钱"}}
        """
        let cues = AnalysisEngine.parseCueLines(raw)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].translation, "攒钱")
        XCTAssertEqual(cues[1].highlightWords, ["Save up"])
    }

    func testParseCueLinesSkipsSummaryLine() {
        let raw = """
        {"type":"cue","index":0,"time":0,"endTime":1.0,"text":"Hello","translation":"你好","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}
        {"type":"summary","keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]}
        """
        let cues = AnalysisEngine.parseCueLines(raw)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello")
    }

    func testParseCueLinesReturnsEmptyForGarbage() {
        let cues = AnalysisEngine.parseCueLines("not json at all\n\nalso bad\n")
        XCTAssertTrue(cues.isEmpty)
    }

    // MARK: - parseSummaryLine

    func testParseSummaryLine() {
        let raw = #"{"type":"summary","keyPhrases":[{"expression":"save up","meaningZh":"攒钱","usage":"存钱"}]}"#
        let kp = AnalysisEngine.parseSummaryLine(raw)
        XCTAssertEqual(kp.first?.expression, "save up")
        XCTAssertEqual(kp.first?.meaningZh, "攒钱")
        XCTAssertEqual(kp.first?.usage, "存钱")
    }

    func testParseSummaryLineReturnsEmptyWhenNoSummaryLine() {
        let raw = #"{"type":"cue","index":0,"time":0,"endTime":1,"text":"hi","translation":"嗨","isKeyPoint":false,"highlightWords":[],"keyNotes":{},"highlightTranslations":{}}"#
        let kp = AnalysisEngine.parseSummaryLine(raw)
        XCTAssertTrue(kp.isEmpty)
    }

    func testParseSummaryLineMultipleKeyPhrases() {
        let raw = #"{"type":"summary","keyPhrases":[{"expression":"catch up","meaningZh":"赶上","usage":"用于表示追赶进度"},{"expression":"save up","meaningZh":"攒钱","usage":"存钱备用"}]}"#
        let kp = AnalysisEngine.parseSummaryLine(raw)
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

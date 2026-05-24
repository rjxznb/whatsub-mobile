import XCTest
@testable import whatsub_mobile

final class QuizIPATests: XCTestCase {
    func testAssembleJoinsPerWord() {
        let dict = ["kick": "kɪk", "the": "ðə", "bucket": "ˈbʌkət"]
        XCTAssertEqual(IPADict.assemble(phrase: "Kick the Bucket") { dict[$0] }, "kɪk ðə ˈbʌkət")
    }
    func testAssembleSkipsMissingWords() {
        let dict = ["hello": "həˈloʊ"]
        XCTAssertEqual(IPADict.assemble(phrase: "hello zzzqqq") { dict[$0] }, "həˈloʊ")
    }
    func testAssembleTrimsPunctuation() {
        let dict = ["wow": "waʊ"]
        XCTAssertEqual(IPADict.assemble(phrase: "wow!") { dict[$0] }, "waʊ")
    }
    func testAssembleNilWhenNoneFound() {
        XCTAssertNil(IPADict.assemble(phrase: "zzz qqq") { _ in nil })
    }
}

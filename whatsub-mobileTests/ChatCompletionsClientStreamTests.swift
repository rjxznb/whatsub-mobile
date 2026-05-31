import XCTest
@testable import whatsub_mobile

/// Mocks any URLRequest, returns a fixed SSE-encoded body. Registered once
/// per test via URLSessionConfiguration.protocolClasses.
final class StubSSEProtocol: URLProtocol {
    static var responseBody: String = ""
    static var status: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatCompletionsClientStreamTests: XCTestCase {
    private func sse(_ lines: [String]) -> String {
        lines.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }

    func testStreamYieldsContentChunksInOrder() async throws {
        StubSSEProtocol.status = 200
        StubSSEProtocol.responseBody = sse([
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"content":" there"}}]}"#,
            #"{"choices":[{"delta":{"content":"!"}}]}"#,
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        var got: [String] = []
        for try await chunk in client.stream([ChatMessage(role: "user", content: "hi")]) {
            got.append(chunk)
        }
        XCTAssertEqual(got, ["Hello", " there", "!"])
    }

    func testStreamFinishesOnDONESentinel() async throws {
        StubSSEProtocol.status = 200
        StubSSEProtocol.responseBody = "data: \(#"{"choices":[{"delta":{"content":"x"}}]}"#)\n\ndata: [DONE]\n\ndata: \(#"{"choices":[{"delta":{"content":"AFTER_DONE"}}]}"#)\n\n"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        var got: [String] = []
        for try await chunk in client.stream([ChatMessage(role: "user", content: "hi")]) {
            got.append(chunk)
        }
        XCTAssertEqual(got, ["x"], "anything after [DONE] is discarded")
    }

    func testStreamThrowsOnNon2xxStatus() async {
        StubSSEProtocol.status = 401
        StubSSEProtocol.responseBody = "data: unauthorized\n\n"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let session = URLSession(configuration: config)
        let client = ChatCompletionsClient(
            settings: LlmSettings(baseUrl: "https://stub.test/v1", apiKey: "k", model: "m"),
            session: session
        )
        do {
            for try await _ in client.stream([ChatMessage(role: "user", content: "hi")]) {}
            XCTFail("expected throw")
        } catch {
            // pass — any error type is fine; we just want it to surface
        }
    }
}

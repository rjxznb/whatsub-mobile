import XCTest
@testable import whatsub_mobile

private final class RequestCaptureURLProtocol: URLProtocol {
    static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(#"{"email":"ios@example.com","hasActiveLicense":false}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WhatsubAPIClientSourceTests: XCTestCase {
    func testMeIdentifiesIosClient() async throws {
        RequestCaptureURLProtocol.capturedRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        let api = WhatsubAPI(session: URLSession(configuration: configuration))

        _ = try await api.me(token: "TOK")

        let captured = try XCTUnwrap(RequestCaptureURLProtocol.capturedRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer TOK")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-Whatsub-Client"), "ios")
        XCTAssertTrue(captured.url?.path.hasSuffix("/auth/me") == true)
    }
}

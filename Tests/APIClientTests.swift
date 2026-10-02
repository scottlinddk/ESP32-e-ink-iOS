import XCTest
@testable import EInk

final class APIClientTests: XCTestCase {
    private let origin = URL(string: "https://example.invalid")!
    private let deviceID = "7c5e8a50-31ad-4dc8-bb4c-a17b735fb606"

    override func tearDown() {
        APIStubProtocol.handler = nil
        super.tearDown()
    }

    private func client(tokenProvider: @escaping () async throws -> String = { "test-token" }) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStubProtocol.self]
        return APIClient(baseURL: origin, tokenProvider: tokenProvider, configuration: configuration)
    }

    func testDevicePreferencesUseCorrectRouteAndPartialPatch() async throws {
        APIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/devices/\(self.deviceID)/display")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = try JSONDecoder().decode(Preferences.self, from: Self.body(of: request))
            XCTAssertEqual(body, ["display_timezone": .string("Europe/Copenhagen")])
            return self.response(request, json: #"{"preferences":{"display_timezone":"Europe/Copenhagen","unrelated":{"enabled":true}},"inherited":false}"#)
        }
        let result = try await client().savePreferences(["display_timezone": .string("Europe/Copenhagen")], deviceID: deviceID)
        XCTAssertEqual(result.preferences["unrelated"], .object(["enabled": .bool(true)]))
        XCTAssertEqual(result.inherited, false)
    }

    func testRetrievesFreshBearerForEveryRequest() async throws {
        let counter = TokenCounter()
        let api = client { await counter.next() }
        APIStubProtocol.handler = { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(token == "Bearer token-1" || token == "Bearer token-2")
            return self.response(request, json: #"{"devices":[]}"#)
        }
        _ = try await api.devices()
        _ = try await api.devices()
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testCancelledTaskDoesNotRequestAnotherBearer() async throws {
        let api = client {
            XCTFail("A cancelled request must not ask the current account for a token")
            return "token"
        }
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.devices()
        }
        do { try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testRawPreviewKeepsPixelsAndMetadataTogether() async throws {
        APIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/image/preview/raw")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "device_id", value: self.deviceID)])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: self.previewHeaders(device: self.deviceID))!, Data(repeating: 0xff, count: 3904))
        }
        let frame = try await client().previewRaw(deviceID: deviceID)
        XCTAssertEqual(frame.profile.byteLength, frame.pixels.count)
        XCTAssertEqual(frame.metadata.deviceId, deviceID)
        XCTAssertEqual(frame.metadata.layoutName, "Kitchen display")
    }

    func testProvisioningURLNormalizesSupportedAPIOrigins() {
        for path in ["", "/", "/api", "/api/"] {
            let api = APIClient(baseURL: URL(string: "https://example.invalid:8443\(path)")!) { "token" }
            XCTAssertEqual(api.provisioningURL.absoluteString, "https://example.invalid:8443/api")
        }
    }

    func testBMPPreviewAcceptsServerFormatAndRejectsMismatchOrTruncation() async throws {
        // Same 1-bit top-down DIB/palette format as backend bmpGenerator.ts.
        var valid = Data(repeating: 0, count: 62 + 8 * 64)
        func write32(_ offset: Int, _ value: UInt32) {
            for index in 0..<4 { valid[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        valid[0] = 0x42; valid[1] = 0x4d
        write32(2, UInt32(valid.count)); write32(10, 62); write32(14, 40)
        write32(18, 64); write32(22, UInt32(bitPattern: -64))
        valid[26] = 1; valid[28] = 1
        write32(38, 2835); write32(42, 2835); write32(46, 2); write32(50, 2)
        valid[58] = 255; valid[59] = 255; valid[60] = 255
        for index in 62..<valid.count { valid[index] = 255 }

        for mutation in 0..<3 {
            APIStubProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/image/preview")
                var headers = self.previewHeaders(device: self.deviceID)
                headers["Content-Type"] = "image/bmp"
                headers["X-Display-Width"] = "64"
                headers["X-Display-Height"] = "64"
                headers["X-Display-Row-Bytes"] = "8"
                var bytes = valid
                if mutation == 1 { bytes[18] = 65 }
                if mutation == 2 { bytes.removeLast() }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, bytes)
            }
            do {
                let image = try await client().previewBMP(deviceID: deviceID)
                XCTAssertEqual(mutation, 0, "Accepted invalid BMP variant \(mutation)")
                XCTAssertEqual(image.data, valid)
                XCTAssertEqual(image.metadata.profile, DisplayProfile(width: 64, height: 64))
            } catch is APIError {
                XCTAssertNotEqual(mutation, 0, "Rejected a valid backend BMP")
            }
        }
    }

    func testRawPreviewRejectsWrongDeviceTruncationAndEncoding() async throws {
        for mutation in 0..<3 {
            APIStubProtocol.handler = { request in
                var headers = self.previewHeaders(device: self.deviceID)
                var bytes = Data(repeating: 0xff, count: 3904)
                if mutation == 0 { headers["X-Preview-Device-ID"] = "other-device" }
                if mutation == 1 { bytes.removeLast() }
                if mutation == 2 { headers["X-Display-Encoding"] = "mono-lsb-white0" }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, bytes)
            }
            do {
                _ = try await client().previewRaw(deviceID: deviceID)
                XCTFail("Accepted invalid frame variant \(mutation)")
            } catch is APIError { /* Expected trust-boundary validation. */ }
        }
    }

    func testBackendErrorIsShownWithoutDecodingAsSuccess() async throws {
        APIStubProtocol.handler = { request in
            self.response(request, status: 409, json: #"{"error":"Create a delivery token first"}"#)
        }
        do {
            _ = try await client().requestRefresh(deviceID: deviceID)
            XCTFail("Expected server error")
        } catch APIError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "Create a delivery token first")
        }
    }

    func testHTMLIsRejectedAndHTTPOriginCannotSendToken() async throws {
        APIStubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "text/html"])!, Data("<html>Sign in</html>".utf8))
        }
        do { _ = try await client().devices(); XCTFail("Accepted HTML") }
        catch is APIError { }

        let unsafe = APIClient(baseURL: URL(string: "http://example.invalid")!) {
            XCTFail("An insecure origin must be rejected before requesting a token")
            return "token"
        }
        do { _ = try await unsafe.devices(); XCTFail("Accepted HTTP") }
        catch APIError.invalidConfiguration { }
    }

    func testRedirectDelegateRejectsCrossOriginAndDowngrade() {
        let delegate = APIOriginRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin.appendingPathComponent("api/devices"))
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for destination in ["https://untrusted.invalid/", "http://example.invalid/", "https://example.invalid:444/"] {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: destination)!)) { result in
                XCTAssertNil(result)
            }
        }
        XCTAssertTrue(APIOriginRedirectDelegate.sameOrigin(origin, URL(string: "https://example.invalid:443/api/devices")!))
    }

    private func response(_ request: URLRequest, status: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!, Data(json.utf8))
    }

    private func previewHeaders(device: String) -> [String: String] {
        ["Content-Type": "application/octet-stream", "X-Preview-Device-ID": device,
         "X-Preview-Layout-ID": "", "X-Preview-Layout-Name": "Kitchen%20display", "X-Preview-Mode": "single",
         "X-Preview-Quiet": "false", "X-Preview-Rendered-At": "2026-10-02T10:00:00.000Z",
         "X-Display-Width": "250", "X-Display-Height": "122", "X-Display-Rotation": "0",
         "X-Display-Row-Bytes": "32", "X-Display-Encoding": "mono-msb-white1"]
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private actor TokenCounter {
    var count = 0
    func next() -> String { count += 1; return "token-\(count)" }
}

private final class APIStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

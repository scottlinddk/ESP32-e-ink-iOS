import Foundation

final class APIClient {
    private let baseURL: URL
    var provisioningURL: URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = "/api"
        return components.url ?? baseURL
    }
    private let tokenProvider: () async throws -> String
    private let session: URLSession

    init(baseURL: URL, tokenProvider: @escaping () async throws -> String,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: APIOriginRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func preferences(deviceID: String? = nil) async throws -> PreferencesResponse {
        try await json(preferencesPath(deviceID))
    }

    func savePreferences(_ patch: Preferences, deviceID: String? = nil) async throws -> PreferencesResponse {
        try await json(preferencesPath(deviceID), method: deviceID == nil ? "POST" : "PUT", body: patch)
    }

    func devices() async throws -> [Device] {
        let response: DevicesResponse = try await json(["devices"])
        return response.devices
    }

    func addDevice(name: String, bleName: String? = nil) async throws -> Device {
        var body: Preferences = ["device_name": .string(name)]
        if let bleName, !bleName.isEmpty {
            body["ble_name"] = .string(bleName)
            body["device_id"] = .string(bleName)
        }
        let response: DeviceResponse = try await json(["devices"], method: "POST", body: body)
        return response.device
    }

    func renameDevice(id: String, name: String) async throws -> Device {
        let response: DeviceResponse = try await json(["devices", id], method: "PUT", body: ["device_name": .string(name)])
        return response.device
    }

    func deleteDevice(id: String) async throws {
        let _: Preferences = try await json(["devices", id], method: "DELETE")
    }

    func deliveryStatus(deviceID: String) async throws -> DeviceDeliveryStatus {
        try await json(["devices", deviceID, "delivery"])
    }

    func requestRefresh(deviceID: String) async throws -> DeviceDeliveryStatus {
        try await json(["devices", deviceID, "refresh"], method: "POST")
    }

    func createDeliveryToken(deviceID: String) async throws -> String {
        let response: TokenResponse = try await json(["devices", deviceID, "delivery", "token"], method: "POST")
        return response.token
    }

    func revokeDeliveryToken(deviceID: String) async throws {
        let _: ConfiguredResponse = try await json(["devices", deviceID, "delivery", "token"], method: "DELETE")
    }

    func apiKeys() async throws -> [MaskedApiKey] {
        let response: KeysResponse = try await json(["preferences", "api-keys"])
        return response.api_keys
    }

    @discardableResult
    func saveAPIKey(provider: String, key: String) async throws -> MaskedApiKey {
        let response: KeyResponse = try await json(["preferences", "api-keys"], method: "POST",
            body: ["provider": .string(provider), "api_key": .string(key)])
        return response.api_key
    }

    func deleteAPIKey(provider: String) async throws {
        let _: Preferences = try await json(["preferences", "api-keys", provider], method: "DELETE")
    }

    func calendarCredentialConfigured() async throws -> Bool {
        let response: ConfiguredResponse = try await json(["preferences", "calendar-credentials"])
        return response.configured
    }

    @discardableResult
    func saveCalendarCredential(url: String) async throws -> Bool {
        let response: ConfiguredResponse = try await json(["preferences", "calendar-credentials"], method: "POST", body: ["url": .string(url)])
        return response.configured
    }

    @discardableResult
    func deleteCalendarCredential() async throws -> Bool {
        let response: ConfiguredResponse = try await json(["preferences", "calendar-credentials"], method: "DELETE")
        return response.configured
    }

    func previewData(deviceID: String? = nil) async throws -> Preferences {
        try await json(["preview"], query: deviceQuery(deviceID))
    }

    func previewBMP(deviceID: String? = nil) async throws -> PreviewImage {
        let (data, response) = try await request(["image", "preview"], query: deviceQuery(deviceID), accept: "image/bmp")
        try requireContentType(response, "image/bmp")
        let metadata = try previewMetadata(response, deviceID: deviceID)
        try validateBMP(data, profile: metadata.profile)
        return PreviewImage(data: data, metadata: metadata)
    }

    func previewRaw(deviceID: String? = nil) async throws -> PreviewFrame {
        let (data, response) = try await request(["image", "preview", "raw"], query: deviceQuery(deviceID), accept: "application/octet-stream")
        try requireContentType(response, "application/octet-stream")
        let metadata = try previewMetadata(response, deviceID: deviceID)
        guard data.count == metadata.profile.byteLength else {
            throw APIError.invalidResponse("The display image length does not match its panel profile.")
        }
        return PreviewFrame(pixels: data, metadata: metadata)
    }

    private func preferencesPath(_ deviceID: String?) -> [String] {
        deviceID.map { ["devices", $0, "display"] } ?? ["preferences"]
    }

    private func deviceQuery(_ deviceID: String?) -> [URLQueryItem] {
        deviceID.map { [URLQueryItem(name: "device_id", value: $0)] } ?? []
    }

    private func json<T: Decodable>(_ path: [String], method: String = "GET", body: Preferences? = nil,
                                     query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await request(path, method: method, body: body, query: query)
        try requireContentType(response, "application/json")
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.invalidResponse("The server returned an unexpected response. Check that the backend is up to date.") }
    }

    private func request(_ path: [String], method: String = "GET", body: Preferences? = nil,
                         query: [URLQueryItem] = [], accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              ["", "/", "/api", "/api/"].contains(components.path) else { throw APIError.invalidConfiguration }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedPath = "/api/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidConfiguration }
        try Task.checkCancellation()
        let token = try await tokenProvider()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\r"), !token.contains("\n") else { throw APIError.missingToken }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, rawResponse) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = rawResponse as? HTTPURLResponse,
              let responseURL = response.url, APIOriginRedirectDelegate.sameOrigin(url, responseURL) else {
            throw APIError.invalidResponse("The API redirected to an untrusted origin.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            throw APIError.http(status: response.statusCode, message: error?.error ?? "The server could not complete this request.")
        }
        guard data.count <= 2_097_152 else { throw APIError.invalidResponse("The API response was too large.") }
        if let header = response.value(forHTTPHeaderField: "Content-Length"),
           response.value(forHTTPHeaderField: "Content-Encoding") == nil {
            guard let length = Int(header), length == data.count else {
                throw APIError.invalidResponse("The server response was incomplete.")
            }
        }
        return (data, response)
    }

    private func requireContentType(_ response: HTTPURLResponse, _ expected: String) throws {
        guard response.mimeType?.lowercased() == expected else {
            throw APIError.invalidResponse("The server returned an unexpected content type.")
        }
    }

    private struct DevicesResponse: Decodable { let devices: [Device] }
    private struct DeviceResponse: Decodable { let device: Device }
    private struct TokenResponse: Decodable { let token: String }
    private struct ConfiguredResponse: Decodable { let configured: Bool }
    private struct KeysResponse: Decodable { let api_keys: [MaskedApiKey] }
    private struct KeyResponse: Decodable { let api_key: MaskedApiKey }
    private struct ServerError: Decodable { let error: String }
}

// URLSession must reject the redirect before it could forward a bearer credential.
final class APIOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == "https" && second.scheme?.lowercased() == "https"
            && first.host?.lowercased() == second.host?.lowercased()
            && (first.port ?? 443) == (second.port ?? 443)
            && second.user == nil && second.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              Self.sameOrigin(original, destination) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private func previewMetadata(_ response: HTTPURLResponse, deviceID: String?) throws -> PreviewMetadata {
    func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    guard let device = header("X-Preview-Device-ID"), device.lowercased() == (deviceID ?? "").lowercased() else {
        throw APIError.invalidResponse("Preview device does not match the selected device. Reload the preview.")
    }
    guard let layout = header("X-Preview-Layout-ID"),
          layout.isEmpty || layout.range(of: "^[A-Za-z0-9_-]{1,48}$", options: .regularExpression) != nil,
          let encodedName = header("X-Preview-Layout-Name"), let name = encodedName.removingPercentEncoding,
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 80,
          let mode = header("X-Preview-Mode"), ["single", "slideshow"].contains(mode),
          let quiet = header("X-Preview-Quiet"), ["true", "false"].contains(quiet),
          let renderedAt = header("X-Preview-Rendered-At"), validPreviewTime(renderedAt),
          let width = header("X-Display-Width").flatMap(Int.init),
          let height = header("X-Display-Height").flatMap(Int.init),
          let rotation = header("X-Display-Rotation").flatMap(Int.init) else {
        throw APIError.invalidResponse("Invalid preview metadata. Check that the backend is up to date.")
    }
    let nextTransition = header("X-Preview-Next-Transition")
    guard nextTransition.map(validPreviewTime) ?? true,
          mode != "slideshow" || (nextTransition != nil && !layout.isEmpty),
          mode == "slideshow" || (nextTransition == nil && quiet == "false") else {
        throw APIError.invalidResponse("The preview schedule metadata is invalid.")
    }
    let profile = try DisplayProfile(width: width, height: height, rotation: rotation).validated()
    guard header("X-Display-Encoding") == "mono-msb-white1",
          header("X-Display-Row-Bytes").flatMap(Int.init) == profile.rowBytes else {
        throw APIError.invalidResponse("The display image encoding is unsupported.")
    }
    return PreviewMetadata(deviceId: device.isEmpty ? nil : device, layoutId: layout.isEmpty ? nil : layout,
                           layoutName: name, mode: mode, renderedAt: renderedAt, quiet: quiet == "true",
                           nextTransition: nextTransition, profile: profile)
}

private func validPreviewTime(_ value: String) -> Bool {
    guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,3})?Z$", options: .regularExpression) != nil else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: value) != nil
}

private func validateBMP(_ data: Data, profile: DisplayProfile) throws {
    guard data.count >= 62 else { throw APIError.invalidResponse("The preview BMP is incomplete.") }
    let bytes = [UInt8](data)
    func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) } }
    let pixelBytes = ((profile.width + 31) / 32) * 4 * profile.height
    guard bytes[0] == 0x42, bytes[1] == 0x4d, u32(2) == data.count,
          u32(10) == 62, u32(14) == 40, Int32(bitPattern: u32(18)) == profile.width,
          Int32(bitPattern: u32(22)) == -profile.height,
          u16(26) == 1, u16(28) == 1, u32(30) == 0, data.count == 62 + pixelBytes else {
        throw APIError.invalidResponse("The preview BMP does not match its display profile.")
    }
}

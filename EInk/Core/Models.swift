import Foundation

// Retain fields this version of the app does not edit when the server adds settings.
typealias Preferences = [String: JSONValue]

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }

    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

struct PreferencesResponse: Codable, Sendable {
    let preferences: Preferences
    let inherited: Bool?
}

struct Device: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let device_id: String
    let device_name: String
    let ble_name: String?
    let license_key: String?
    let firmware_version: String?
    let last_seen_at: String?
}

struct DeviceDeliveryStatus: Codable, Sendable {
    let configured: Bool
    let rotatedAt: String?
    let lastSeenAt: String?
    let firmwareVersion: String?
    let batteryPercent: Int?
    let rssi: Int?
    let lastAppliedHash: String?
    let refreshRequestId: String?
    let refreshRequestedAt: String?
    let refreshAppliedAt: String?

    var refreshPending: Bool { refreshRequestId != nil && refreshAppliedAt == nil }
}

struct MaskedApiKey: Codable, Identifiable, Sendable {
    let id: String
    let provider: String
    let api_key: String
    let created_at: String
}

struct DisplayProfile: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let rotation: Int
    let colorMode: String

    init(width: Int = 250, height: Int = 122, rotation: Int = 0, colorMode: String = "bw") {
        self.width = width
        self.height = height
        self.rotation = rotation
        self.colorMode = colorMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decode(Int.self, forKey: .width),
                  height: try values.decode(Int.self, forKey: .height),
                  rotation: try values.decode(Int.self, forKey: .rotation),
                  colorMode: try values.decode(String.self, forKey: .colorMode))
        try validate()
    }

    func validate() throws {
        guard (64...1600).contains(width), (64...1600).contains(height),
              width * height <= 1_920_000, [0, 90, 180, 270].contains(rotation), colorMode == "bw" else {
            throw APIError.invalidResponse("Unsupported display profile. Use a monochrome panel, 64–1600 pixels per side, at most 1,920,000 pixels, and a right-angle rotation.")
        }
    }

    func validated() throws -> DisplayProfile { try validate(); return self }
    var rowBytes: Int { (width + 7) / 8 }
    var byteLength: Int { rowBytes * height }
}

struct PreviewMetadata: Sendable {
    let deviceId: String?
    let layoutId: String?
    let layoutName: String
    let mode: String
    let renderedAt: String
    let quiet: Bool
    let nextTransition: String?
    let profile: DisplayProfile
}

struct PreviewImage: Sendable {
    let data: Data
    let metadata: PreviewMetadata
}

struct PreviewFrame: Sendable {
    let pixels: Data
    let metadata: PreviewMetadata
    var profile: DisplayProfile { metadata.profile }
}

enum APIError: Error, LocalizedError {
    case invalidConfiguration
    case missingToken
    case http(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Configure an HTTPS API origin without a query, fragment, or credentials."
        case .missingToken: return "Sign in again to continue."
        case .http(let status, let message):
            return status == 401 ? "Your session expired. Sign in again." : "\(message) (HTTP \(status))"
        case .invalidResponse(let message): return message
        }
    }
}

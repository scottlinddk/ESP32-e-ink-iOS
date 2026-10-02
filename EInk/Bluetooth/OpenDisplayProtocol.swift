import Foundation

struct DisplayBluetoothError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum OpenDisplayProtocol {
    static let serviceUUID = "00002446-0000-1000-8000-00805f9b34fb"
    static let bundledServiceUUID = "c9c10001-7a6b-4c31-8a98-89e539e43805"
    static let bundledCharacteristicUUID = "c9c10002-7a6b-4c31-8a98-89e539e43805"

    struct PanelCapabilities: Equatable {
        let width: Int
        let height: Int
        let color: Int
    }

    static func frame(_ command: UInt16, payload: Data = Data()) -> Data {
        Data([UInt8(command >> 8), UInt8(command & 0xff)]) + payload
    }

    static func validateFrame(pixels: Data, profile: DisplayProfile) throws {
        try profile.validate()
        guard pixels.count == profile.byteLength else {
            throw DisplayBluetoothError("Invalid monochrome image dimensions or pixel length.")
        }
    }

    static func validatePanel(_ panel: PanelCapabilities, profile: DisplayProfile, bundled: Bool) throws {
        guard panel.color == 0, panel.width == profile.width, panel.height == profile.height else {
            throw DisplayBluetoothError("Display mismatch: device is \(panel.width)×\(panel.height), color \(panel.color). Choose its native monochrome profile before sending.")
        }
        guard bundled || panel.width.isMultiple(of: 8) else {
            throw DisplayBluetoothError("This OpenDisplay panel needs verified row-padding support. Use bundled firmware for 250×122 Bluetooth updates, or export a BMP.")
        }
    }

    static func chunkSize(maximumWriteLength: Int, bundled: Bool) throws -> Int {
        guard maximumWriteLength > 2 else { throw DisplayBluetoothError("The display cannot accept a complete Bluetooth command.") }
        // The bundled firmware's receiver is limited to 20 bytes even with a larger ATT MTU.
        return min(bundled ? 18 : 230, maximumWriteLength - 2)
    }

    static func parseBundledCapabilities(_ data: Data) throws -> PanelCapabilities {
        let bytes = [UInt8](data)
        guard bytes.count == 6, bytes[0] == 1 else {
            throw DisplayBluetoothError("Unsupported bundled display protocol. Update the device firmware.")
        }
        return PanelCapabilities(width: littleEndian(bytes, 1), height: littleEndian(bytes, 3), color: Int(bytes[5]))
    }

    static func acknowledgement(_ data: Data) throws -> UInt16 {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw DisplayBluetoothError("Malformed display acknowledgement.") }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard raw & 0xff00 != 0xff00 else { throw DisplayBluetoothError("Display rejected command 0x\(String(raw & 0xff, radix: 16)).") }
        let code = raw & 0x7fff
        guard code != 0x74 else { throw DisplayBluetoothError("The display reported a refresh timeout; refresh was not confirmed.") }
        return code
    }

    static func parsePanelConfig(_ data: Data) throws -> PanelCapabilities {
        let bytes = [UInt8](data)
        guard (5...8192).contains(bytes.count), bytes[2] == 1 else {
            throw DisplayBluetoothError("Unsupported OpenDisplay configuration.")
        }
        let sizes: [UInt8: Int] = [1:22, 2:22, 4:30, 0x20:46, 0x21:22, 0x23:30, 0x24:30,
                                  0x25:30, 0x26:160, 0x27:64, 0x28:32, 0x29:32, 0x2a:32, 0x2b:32, 0x2c:288]
        var panels: [PanelCapabilities] = []
        var offset = 3
        let end = bytes.count - 2
        while offset < end {
            guard offset + 2 <= end else { throw DisplayBluetoothError("Truncated OpenDisplay configuration.") }
            let type = bytes[offset + 1]
            let remaining = end - offset - 2
            // Upstream also accepts a 65-byte legacy Wi-Fi record, only as the last record.
            let size: Int? = type == 0x26 && remaining == 65 ? 65 : sizes[type]
            guard let size, size <= remaining else { throw DisplayBluetoothError("Incomplete or unsupported OpenDisplay configuration.") }
            let start = offset + 2
            if type == 0x20 {
                panels.append(PanelCapabilities(width: littleEndian(bytes, start + 4), height: littleEndian(bytes, start + 6), color: Int(bytes[start + 21])))
            }
            offset = start + size
        }
        guard offset == end, panels.count == 1 else { throw DisplayBluetoothError("Exactly one configured display is required.") }
        return panels[0]
    }

    struct ConfigurationReply {
        private var expected: Int?
        private var sequence = 0
        private var bytes = Data()

        mutating func append(_ data: Data) throws -> PanelCapabilities? {
            let packet = [UInt8](data)
            guard packet.count >= 2 else { throw DisplayBluetoothError("Malformed configuration reply.") }
            let code = UInt16(packet[0]) << 8 | UInt16(packet[1])
            if code == 0xfe40 || (packet.count == 3 && code == 0x40 && packet[2] == 0xfe) {
                throw DisplayBluetoothError("This OpenDisplay requires an encryption key. Use an authenticated OpenDisplay client.")
            }
            guard code != 0xff40 else { throw DisplayBluetoothError("Display configuration is unavailable or requires authentication.") }
            guard code == 0x40 || code == 0x8040 else { return nil }
            let header = expected == nil ? 6 : 4
            guard packet.count > header, OpenDisplayProtocol.littleEndian(packet, 2) == sequence else {
                throw DisplayBluetoothError("Malformed or out-of-order configuration chunks.")
            }
            sequence += 1
            if expected == nil { expected = OpenDisplayProtocol.littleEndian(packet, 4) }
            guard let expected, (5...8192).contains(expected), bytes.count + packet.count - header <= expected else {
                throw DisplayBluetoothError("Display configuration length is invalid.")
            }
            bytes.append(contentsOf: packet[header...])
            if bytes.count == expected { return try OpenDisplayProtocol.parsePanelConfig(bytes) }
            return nil
        }
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
}

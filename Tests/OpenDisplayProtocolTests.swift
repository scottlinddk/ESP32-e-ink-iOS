import Foundation
import XCTest
@testable import EInk

final class OpenDisplayProtocolTests: XCTestCase {
    func testCommandsAndNegotiatedChunkLimits() throws {
        XCTAssertEqual(OpenDisplayProtocol.frame(0x72, payload: Data([0])), Data([0, 0x72, 0]))
        XCTAssertEqual(try OpenDisplayProtocol.chunkSize(maximumWriteLength: 512, bundled: false), 230)
        XCTAssertEqual(try OpenDisplayProtocol.chunkSize(maximumWriteLength: 20, bundled: false), 18)
        XCTAssertEqual(try OpenDisplayProtocol.chunkSize(maximumWriteLength: 512, bundled: true), 18)
        XCTAssertThrowsError(try OpenDisplayProtocol.chunkSize(maximumWriteLength: 2, bundled: false))
    }

    func testBundledReceiverAcceptsPadded250RowsButOpenDisplayDoesNot() throws {
        let profile = DisplayProfile()
        let panel = try OpenDisplayProtocol.parseBundledCapabilities(Data([1, 250, 0, 122, 0, 0]))
        XCTAssertEqual(panel, .init(width: 250, height: 122, color: 0))
        XCTAssertNoThrow(try OpenDisplayProtocol.validateFrame(pixels: Data(repeating: 0xff, count: 3904), profile: profile))
        XCTAssertNoThrow(try OpenDisplayProtocol.validatePanel(panel, profile: profile, bundled: true))
        XCTAssertThrowsError(try OpenDisplayProtocol.validatePanel(panel, profile: profile, bundled: false))
        XCTAssertThrowsError(try OpenDisplayProtocol.validateFrame(pixels: Data(repeating: 0xff, count: 3903), profile: profile))
        XCTAssertThrowsError(try OpenDisplayProtocol.parseBundledCapabilities(Data([2, 250, 0, 122, 0, 0])))
        XCTAssertThrowsError(try OpenDisplayProtocol.parseBundledCapabilities(Data([1, 250])))
    }

    func testPanelDimensionsAndColorMustMatch() throws {
        let panel = OpenDisplayProtocol.PanelCapabilities(width: 800, height: 480, color: 0)
        XCTAssertNoThrow(try OpenDisplayProtocol.validatePanel(panel, profile: DisplayProfile(width: 800, height: 480), bundled: false))
        XCTAssertThrowsError(try OpenDisplayProtocol.validatePanel(panel, profile: DisplayProfile(), bundled: true))
        XCTAssertThrowsError(try OpenDisplayProtocol.validatePanel(.init(width: 800, height: 480, color: 1), profile: DisplayProfile(width: 800, height: 480), bundled: true))
    }

    func testAcknowledgementsRejectFailureAndRefreshTimeout() throws {
        XCTAssertEqual(try OpenDisplayProtocol.acknowledgement(Data([0, 0x71])), 0x71)
        XCTAssertEqual(try OpenDisplayProtocol.acknowledgement(Data([0x80, 0x73])), 0x73)
        XCTAssertThrowsError(try OpenDisplayProtocol.acknowledgement(Data([0xff, 0x71])))
        XCTAssertThrowsError(try OpenDisplayProtocol.acknowledgement(Data([0, 0x74])))
        XCTAssertThrowsError(try OpenDisplayProtocol.acknowledgement(Data([0])))
    }

    func testConfigurationParsesPanelAndRejectsUnknownTruncatedOrMultiplePanels() throws {
        let config = configuration()
        XCTAssertEqual(try OpenDisplayProtocol.parsePanelConfig(config), .init(width: 800, height: 480, color: 0))
        var unknown = config
        unknown[4] = 0xef
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(unknown))
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(config.dropLast()))
        let twoPanels = Data(config.prefix(3)) + Data(config[3..<51]) + Data(config[3..<51]) + Data([0, 0])
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(twoPanels))
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(Data([0, 0, 1, 0, 0])))
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(Data([0, 0, 1, 0, 0, 0])))
    }

    func testLegacyWiFiConfigAllowedOnlyAtEnd() throws {
        let base = configuration()
        let record = Data([0, 0x26]) + Data(repeating: 0, count: 65)
        let legacy = Data(base.dropLast(2)) + record + Data([0, 0])
        XCTAssertNoThrow(try OpenDisplayProtocol.parsePanelConfig(legacy))
        let legacyBeforePanel = Data(base.prefix(3)) + record + Data(base.dropFirst(3))
        XCTAssertThrowsError(try OpenDisplayProtocol.parsePanelConfig(legacyBeforePanel))
    }

    func testChunkAssemblyRejectsSequenceLengthAndEncryptedDevices() throws {
        let config = configuration()
        var reply = OpenDisplayProtocol.ConfigurationReply()
        let first = Data([0, 0x40, 0, 0, UInt8(config.count), 0]) + config.prefix(20)
        XCTAssertNil(try reply.append(first))
        let second = Data([0x80, 0x40, 1, 0]) + config.dropFirst(20)
        XCTAssertEqual(try reply.append(second), .init(width: 800, height: 480, color: 0))
        var outOfOrder = OpenDisplayProtocol.ConfigurationReply()
        XCTAssertThrowsError(try outOfOrder.append(Data([0, 0x40, 1, 0, 53, 0, 1])))
        var overflow = OpenDisplayProtocol.ConfigurationReply()
        XCTAssertThrowsError(try overflow.append(Data([0, 0x40, 0, 0, 5, 0, 1, 2, 3, 4, 5, 6])))
        var oversized = OpenDisplayProtocol.ConfigurationReply()
        XCTAssertThrowsError(try oversized.append(Data([0, 0x40, 0, 0, 1, 0x20, 1])))
        for packet in [Data([0xfe, 0x40]), Data([0, 0x40, 0xfe]), Data([0xff, 0x40])] {
            var encrypted = OpenDisplayProtocol.ConfigurationReply()
            XCTAssertThrowsError(try encrypted.append(packet))
        }
    }

    private func configuration() -> Data {
        var bytes = [UInt8](repeating: 0, count: 53)
        bytes[2] = 1
        bytes[4] = 0x20
        bytes[9] = 0x20; bytes[10] = 0x03 // width 800 LE
        bytes[11] = 0xe0; bytes[12] = 0x01 // height 480 LE
        return Data(bytes)
    }
}

import XCTest
@testable import EInk

final class ModelTests: XCTestCase {
    func testUnknownPreferenceFieldsSurviveEditingAndEncoding() throws {
        let data = Data(#"{"show_weather":true,"future_widget":{"threshold":42,"labels":["one",null]}}"#.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: data)
        preferences["show_weather"] = .bool(false)
        let result = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(result["show_weather"], .bool(false))
        XCTAssertEqual(result["future_widget"], .object(["threshold": .number(42), "labels": .array([.string("one"), .null])]))
    }

    func testProfileUsesPaddedRowsAndRejectsUnsupportedDimensions() throws {
        let profile = try DisplayProfile().validated()
        XCTAssertEqual(profile.rowBytes, 32)
        XCTAssertEqual(profile.byteLength, 3904)
        XCTAssertThrowsError(try DisplayProfile(width: 1600, height: 1600).validate())
        XCTAssertThrowsError(try DisplayProfile(width: 0).validate())
        XCTAssertThrowsError(try DisplayProfile(rotation: 45).validate())
        XCTAssertThrowsError(try DisplayProfile(colorMode: "red").validate())
        let invalid = Data(#"{"width":250,"height":122,"rotation":45,"colorMode":"bw"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayProfile.self, from: invalid))
    }

    func testJSONValueDoesNotTreatBooleansAsNumbers() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"enabled":true,"count":1}"#.utf8))
        XCTAssertEqual(preferences["enabled"]?.boolValue, true)
        XCTAssertNil(preferences["enabled"]?.intValue)
        XCTAssertEqual(preferences["count"]?.intValue, 1)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
    }

    func testLayoutAcceptsAdjacentWidgetsAndRejectsOverlapOrOverflow() {
        func widget(_ id: String, x: Int, width: Int) -> JSONValue {
            .object(["i": .string(id), "x": .number(Double(x)), "y": .number(0),
                     "w": .number(Double(width)), "h": .number(2)])
        }
        XCTAssertNil(layoutValidationError([widget("energy", x: 0, width: 5), widget("weather", x: 5, width: 5)]))
        XCTAssertNotNil(layoutValidationError([widget("energy", x: 0, width: 6), widget("weather", x: 5, width: 5)]))
        XCTAssertNotNil(layoutValidationError([widget("energy", x: 9, width: 2)]))
        XCTAssertNotNil(layoutValidationError([widget("energy", x: 0, width: 5), widget("energy", x: 5, width: 5)]))
    }
}

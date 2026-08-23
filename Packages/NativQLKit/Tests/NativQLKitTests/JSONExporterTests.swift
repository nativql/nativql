import XCTest
import Foundation
@testable import NativQLKit

final class JSONExporterTests: XCTestCase {
    func testArrayOfObjectsWithNullsAndBooleans() throws {
        let json = JSONExporter.export(
            columns: [ColumnInfo(name: "id", dataType: "int4"),
                      ColumnInfo(name: "active", dataType: "bool"),
                      ColumnInfo(name: "note", dataType: "text")],
            rows: [[.int(1), .bool(true), .null]]
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["id"] as? Int, 1)
        XCTAssertEqual(parsed[0]["active"] as? Bool, true)
        XCTAssertTrue(parsed[0]["note"] is NSNull)
    }

    func testExplicitNullsAreEmittedNotOmitted() throws {
        let json = JSONExporter.export(
            columns: [ColumnInfo(name: "a", dataType: "int4"),
                      ColumnInfo(name: "b", dataType: "text")],
            rows: [[.int(1), .null]]
        )
        XCTAssertTrue(json.contains("\"b\""))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertTrue(parsed[0]["b"] is NSNull)
    }
}

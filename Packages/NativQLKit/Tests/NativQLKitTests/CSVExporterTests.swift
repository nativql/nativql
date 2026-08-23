import XCTest
import Foundation
@testable import NativQLKit

final class CSVExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", dataType: "int4"),
        ColumnInfo(name: "name", dataType: "text"),
        ColumnInfo(name: "note", dataType: "text"),
    ]

    func testBasicExport() {
        let csv = CSVExporter.export(
            columns: columns,
            rows: [[.int(1), .string("ada"), .null]]
        )
        XCTAssertEqual(csv, "id,name,note\n1,ada,\n")
    }

    func testQuotesValuesWithCommasQuotesAndNewlines() {
        let csv = CSVExporter.export(
            columns: columns,
            rows: [[.int(2), .string("say \"hi\", ok"), .string("line1\nline2")]]
        )
        XCTAssertEqual(csv, "id,name,note\n2,\"say \"\"hi\"\", ok\",\"line1\nline2\"\n")
    }

    func testBoolRendering() {
        let csv = CSVExporter.export(
            columns: [ColumnInfo(name: "flag", dataType: "bool")],
            rows: [[.bool(true)], [.bool(false)]]
        )
        XCTAssertEqual(csv, "flag\ntrue\nfalse\n")
    }
}

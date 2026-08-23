import XCTest
@testable import NativQLKit

final class InsertStatementBuilderTests: XCTestCase {
    func testBuildsParameterizedInsertPerRow() {
        let ref = TableRef(database: "shop", schema: "public", name: "users")
        let columns = [ColumnInfo(name: "name", dataType: "text"),
                       ColumnInfo(name: "age", dataType: "int4")]
        let result = InsertStatementBuilder.build(
            table: ref,
            columns: columns,
            rows: [[.string("ada"), .int(36)], [.string("grace"), .null]]
        )
        XCTAssertEqual(
            result.sql,
            "INSERT INTO \"public\".\"users\" (\"name\", \"age\") VALUES (?, ?);"
        )
        XCTAssertEqual(result.batches.count, 2)
        XCTAssertEqual(result.batches[0], [.string("ada"), .int(36)])
        XCTAssertEqual(result.batches[1], [.string("grace"), .null])
    }
}

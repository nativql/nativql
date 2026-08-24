import XCTest
@testable import NativQLKit

final class RowBuildersTests: XCTestCase {
    // MARK: - UpdateStatementBuilder

    func testUpdateBuildsParameterizedSQLWithSingleBatch() throws {
        let ref = TableRef(database: "shop", schema: "public", name: "users")
        let result = UpdateStatementBuilder.build(
            table: ref,
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            changes: [
                (columnName: "email", newValue: SQLValue.string("new@x.io")),
                (columnName: "age", newValue: SQLValue.int(37)),
            ],
            pkValues: ["id": .int(1)]
        )

        let statement = try XCTUnwrap(result)
        XCTAssertEqual(statement.kind, .update)
        XCTAssertEqual(statement.table, ref)
        XCTAssertEqual(
            statement.sql,
            "UPDATE \"public\".\"users\" SET \"email\" = ?, \"age\" = ? WHERE \"id\" = ?"
        )
        XCTAssertEqual(statement.batches.count, 1)
        XCTAssertEqual(statement.batches[0], [.string("new@x.io"), .int(37), .int(1)])
    }

    func testUpdateOmitsSchemaWhenAbsent() throws {
        let result = UpdateStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            changes: [(columnName: "email", newValue: SQLValue.string("a@x.io"))],
            pkValues: ["id": .int(1)]
        )
        XCTAssertEqual(
            try XCTUnwrap(result).sql,
            "UPDATE \"users\" SET \"email\" = ? WHERE \"id\" = ?"
        )
    }

    func testUpdateBindingOrderFollowsPkColumnOrderNotDictionaryOrder() throws {
        let result = UpdateStatementBuilder.build(
            table: TableRef(database: "shop", name: "memberships"),
            pkColumns: [
                ColumnInfo(name: "org_id", dataType: "int4"),
                ColumnInfo(name: "user_id", dataType: "int4"),
            ],
            changes: [(columnName: "role", newValue: SQLValue.string("admin"))],
            pkValues: ["user_id": .int(7), "org_id": .int(3)]
        )
        let statement = try XCTUnwrap(result)
        XCTAssertTrue(statement.sql.hasSuffix("WHERE \"org_id\" = ? AND \"user_id\" = ?"))
        XCTAssertEqual(statement.batches[0], [.string("admin"), .int(3), .int(7)])
    }

    func testUpdateQuotesIdentifiersWithDoubling() throws {
        let result = UpdateStatementBuilder.build(
            table: TableRef(database: "sh\"op", schema: "pu\"b", name: "we\"ird"),
            pkColumns: [ColumnInfo(name: "k\"y", dataType: "int4")],
            changes: [(columnName: "co\"l", newValue: SQLValue.string("v"))],
            pkValues: ["k\"y": .int(1)]
        )
        XCTAssertEqual(
            try XCTUnwrap(result).sql,
            "UPDATE \"pu\"\"b\".\"we\"\"ird\" SET \"co\"\"l\" = ? WHERE \"k\"\"y\" = ?"
        )
    }

    func testUpdateReturnsNilWhenChangesEmpty() throws {
        XCTAssertNil(UpdateStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            changes: [],
            pkValues: ["id": .int(1)]
        ))
    }

    func testUpdateReturnsNilWhenPkColumnsEmpty() throws {
        XCTAssertNil(UpdateStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [],
            changes: [(columnName: "email", newValue: SQLValue.string("a@x.io"))],
            pkValues: [:]
        ))
    }

    func testUpdateMissingPkValueBindsNull() throws {
        let result = UpdateStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            changes: [(columnName: "email", newValue: SQLValue.string("a@x.io"))],
            pkValues: [:]
        )
        XCTAssertEqual(try XCTUnwrap(result).batches[0].last, .null)
    }

    // MARK: - DeleteStatementBuilder

    func testDeleteBuildsOneSqlWithPerRowBatches() throws {
        let ref = TableRef(database: "shop", schema: "public", name: "users")
        let result = DeleteStatementBuilder.build(
            table: ref,
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            rows: [[.int(1)], [.int(2)], [.int(3)]]
        )

        let statement = try XCTUnwrap(result)
        XCTAssertEqual(statement.kind, .delete)
        XCTAssertEqual(statement.table, ref)
        XCTAssertEqual(statement.sql, "DELETE FROM \"public\".\"users\" WHERE \"id\" = ?")
        XCTAssertEqual(statement.batches, [[.int(1)], [.int(2)], [.int(3)]])
    }

    func testDeleteCompositePkUsesAndChainInColumnOrder() throws {
        let result = DeleteStatementBuilder.build(
            table: TableRef(database: "shop", name: "memberships"),
            pkColumns: [
                ColumnInfo(name: "org_id", dataType: "int4"),
                ColumnInfo(name: "user_id", dataType: "int4"),
            ],
            rows: [[.int(3), .int(7)], [.int(4), .int(8)]]
        )
        let statement = try XCTUnwrap(result)
        XCTAssertEqual(statement.sql, "DELETE FROM \"memberships\" WHERE \"org_id\" = ? AND \"user_id\" = ?")
        XCTAssertEqual(statement.batches, [[.int(3), .int(7)], [.int(4), .int(8)]])
    }

    func testDeleteQuotesIdentifiersWithDoubling() throws {
        let result = DeleteStatementBuilder.build(
            table: TableRef(database: "sh\"op", schema: "pu\"b", name: "we\"ird"),
            pkColumns: [ColumnInfo(name: "k\"y", dataType: "int4")],
            rows: [[.int(1)]]
        )
        XCTAssertEqual(
            try XCTUnwrap(result).sql,
            "DELETE FROM \"pu\"\"b\".\"we\"\"ird\" WHERE \"k\"\"y\" = ?"
        )
    }

    func testDeletePadsShortRowsWithNull() throws {
        let result = DeleteStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [
                ColumnInfo(name: "a", dataType: "int4"),
                ColumnInfo(name: "b", dataType: "int4"),
            ],
            rows: [[.int(1)]]
        )
        XCTAssertEqual(try XCTUnwrap(result).batches, [[.int(1), .null]])
    }

    func testDeleteReturnsNilWhenRowsEmpty() throws {
        XCTAssertNil(DeleteStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [ColumnInfo(name: "id", dataType: "int4")],
            rows: []
        ))
    }

    func testDeleteReturnsNilWhenPkColumnsEmpty() throws {
        XCTAssertNil(DeleteStatementBuilder.build(
            table: TableRef(database: "shop", name: "users"),
            pkColumns: [],
            rows: [[.int(1)]]
        ))
    }
}

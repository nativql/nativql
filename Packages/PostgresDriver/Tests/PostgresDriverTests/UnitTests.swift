import XCTest
import NativQLKit
import NIOCore
import PostgresNIO
@testable import PostgresDriver

/// Pure mapper decisions — no connection required.
final class SQLValueMapperUnitTests: XCTestCase {
    // MARK: - Helpers

    private func text(_ string: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }

    private func binary(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // MARK: - Text-format forward map

    func testTextIntegerFamiliesMapToInt() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "42", typeName: "int2"), .int(42))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "-7", typeName: "int4"), .int(-7))
        XCTAssertEqual(
            SQLValueMapper.sqlValue(fromText: "9007199254740993", typeName: "int8"),
            .int(9_007_199_254_740_993)
        )
    }

    func testTextFloatsMapToDouble() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "1.5", typeName: "float8"), .double(1.5))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "0.25", typeName: "float4"), .double(0.25))
    }

    func testTextNumericStaysRawDecimal() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "1.10", typeName: "numeric"), .decimal("1.10"))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "-0.000001", typeName: "numeric"), .decimal("-0.000001"))
    }

    func testTextBool() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "t", typeName: "bool"), .bool(true))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "false", typeName: "bool"), .bool(false))
    }

    func testTextDateMapsToDateAtUTCMidnight() throws {
        guard case .date(let date) = SQLValueMapper.sqlValue(fromText: "2024-06-15", typeName: "date") else {
            return XCTFail("expected .date")
        }
        let components = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
    }

    func testTextTimestampWithFractionAndTSeparator() throws {
        guard case .datetime(let date) =
            SQLValueMapper.sqlValue(fromText: "2024-01-15T10:30:00.123456", typeName: "timestamp") else {
            return XCTFail("expected .datetime")
        }
        let components = Self.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
    }

    func testTextTimestamptzAppliesOffset() throws {
        // +05:30 means the UTC instant is 05:00.
        guard case .datetime(let date) =
            SQLValueMapper.sqlValue(fromText: "2024-01-15 10:30:00+05:30", typeName: "timestamptz") else {
            return XCTFail("expected .datetime")
        }
        let components = Self.utcCalendar.dateComponents([.hour, .minute], from: date)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 0)
    }

    func testTextTimeAndTimetzBecomeSeconds() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "10:30:00", typeName: "time"), .time(37_800))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "00:00:00.5", typeName: "time"), .time(0.5))
        // Zone suffix dropped per plan.
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "10:30:00+02", typeName: "timetz"), .time(37_800))
    }

    func testTextJsonVerbatim() {
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "{\"a\":1}", typeName: "json"), .json("{\"a\":1}"))
        XCTAssertEqual(SQLValueMapper.sqlValue(fromText: "[1,2]", typeName: "jsonb"), .json("[1,2]"))
    }

    func testTextByteaHexDecode() {
        XCTAssertEqual(
            SQLValueMapper.sqlValue(fromText: "\\xDEADBEEF", typeName: "bytea"),
            .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        )
    }

    func testTextExoticTypesStayStrings() {
        for (text, name) in [
            ("a9b88f52-2c67-4d17-8e6a-5b0f3c1d2e4f", "uuid"),
            ("$1,234.56", "money"),
            ("<root/>", "xml"),
            ("192.168.1.5/24", "inet"),
            ("2001:db8::/32", "cidr"),
            ("01:02:03", "interval"),
            ("{1,2,3}", "_int4"),
            ("hello", "varchar"),
        ] {
            XCTAssertEqual(SQLValueMapper.sqlValue(fromText: text, typeName: name), .string(text), name)
        }
    }

    // MARK: - Binary-format forward map

    func testBinaryIntegers() throws {
        try XCTAssertEqual(mapBinary(Int16(300).bigEndianBytes, name: "int2"), .int(300))
        try XCTAssertEqual(mapBinary(Int32(-7).bigEndianBytes, name: "int4"), .int(-7))
        try XCTAssertEqual(mapBinary(Int64(9_007_199_254_740_993).bigEndianBytes, name: "int8"), .int(9_007_199_254_740_993))
    }

    func testBinaryFloats() throws {
        let doubleBits = withUnsafeBytes(of: Double(2.5).bitPattern.bigEndian) { Data($0) }
        try XCTAssertEqual(mapBinary([UInt8](doubleBits), name: "float8"), .double(2.5))

        let floatBits = withUnsafeBytes(of: Float(-0.75).bitPattern.bigEndian) { Data($0) }
        try XCTAssertEqual(mapBinary([UInt8](floatBits), name: "float4"), .double(-0.75))
    }

    func testBinaryBool() throws {
        try XCTAssertEqual(mapBinary([1], name: "bool"), .bool(true))
        try XCTAssertEqual(mapBinary([0], name: "bool"), .bool(false))
    }

    func testBinaryNumericPreservesDisplayScale() throws {
        // 1.50: ndigits=2 groups [1,5000], weight=0, sign=0, dscale=2
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 2, weight: 0, sign: 0x0000, dscale: 2, groups: [1, 5000]), name: "numeric"),
            .decimal("1.50")
        )
        // 0.0049: one group [49] below the point
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 1, weight: -1, sign: 0x0000, dscale: 4, groups: [49]), name: "numeric"),
            .decimal("0.0049")
        )
        // -12.34
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 2, weight: 0, sign: 0x4000, dscale: 2, groups: [12, 3400]), name: "numeric"),
            .decimal("-12.34")
        )
        // 123456.789 → groups [12,3456,7890], weight=1
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 3, weight: 1, sign: 0x0000, dscale: 3, groups: [12, 3456, 7890]), name: "numeric"),
            .decimal("123456.789")
        )
        // zero keeps its declared scale
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 0, weight: 0, sign: 0x0000, dscale: 2, groups: []), name: "numeric"),
            .decimal("0.00")
        )
    }

    func testBinaryNumericSpecialValues() throws {
        try XCTAssertEqual(
            mapBinary(numericBuffer(ndigits: 0, weight: 0, sign: 0xC000, dscale: 0, groups: []), name: "numeric"),
            .decimal("NaN")
        )
    }

    func testBinaryTimestampMicrosecondsSincePGEpoch() throws {
        // 2000-01-02 03:04:05 UTC == 97_445 seconds after PG epoch.
        let micros = Int64(97_445) * 1_000_000
        var buffer = binary(withUnsafeBytes(of: micros.bigEndian) { [UInt8]($0) })
        guard case .datetime(let date)? = try? SQLValueMapper.sqlValue(fromBinary: &buffer, typeName: "timestamp") else {
            return XCTFail("expected .datetime")
        }
        // Absolute assertion pins the epoch (2000-01-01 UTC == unix 946_684_800).
        XCTAssertEqual(date.timeIntervalSince1970, 946_782_245, accuracy: 1e-6)
    }

    func testBinaryTimeSecondsSinceMidnight() throws {
        let micros = Int64(36_615) * 1_000_000 // 10:10:15
        var buffer = binary(withUnsafeBytes(of: micros.bigEndian) { [UInt8]($0) })
        try XCTAssertEqual(SQLValueMapper.sqlValue(fromBinary: &buffer, typeName: "time"), .time(36_615))
    }

    func testBinaryJsonbStripsVersionByte() throws {
        var payload: [UInt8] = [1]
        payload.append(contentsOf: [UInt8]("{}".utf8))
        var buffer = binary(payload)
        try XCTAssertEqual(SQLValueMapper.sqlValue(fromBinary: &buffer, typeName: "jsonb"), .json("{}"))
    }

    func testBinaryUuid() throws {
        let expected = UUID(uuidString: "A9B88F52-2C67-4D17-8E6A-5B0F3C1D2E4F")!
        let raw = withUnsafeBytes(of: expected.uuid) { [UInt8]($0) }
        var buffer = binary(raw)
        try XCTAssertEqual(SQLValueMapper.sqlValue(fromBinary: &buffer, typeName: "uuid"), .string(expected.uuidString))
    }

    private func mapBinary(_ bytes: [UInt8], name: String, file: StaticString = #filePath, line: UInt = #line) throws -> SQLValue {
        var buffer = binary(bytes)
        return try SQLValueMapper.sqlValue(fromBinary: &buffer, typeName: name)
    }

    private func numericBuffer(ndigits: Int16, weight: Int16, sign: UInt16, dscale: Int16, groups: [Int16]) -> [UInt8] {
        var bytes: [UInt8] = []
        func append16(_ value: UInt16) { bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { [UInt8]($0) }) }
        append16(UInt16(bitPattern: ndigits))
        append16(UInt16(bitPattern: weight))
        append16(sign)
        append16(UInt16(bitPattern: dscale))
        groups.forEach { append16(UInt16(bitPattern: $0)) }
        return bytes
    }

    // MARK: - NULL handling through the cell dispatcher

    func testNullCellBecomesNullRegardlessOfType() {
        let nullCell = PostgresCell(bytes: nil, dataType: .int4, format: .binary, columnName: "x", columnIndex: 0)
        XCTAssertEqual(try SQLValueMapper.map(nullCell), .null)

        let nullText = PostgresCell(bytes: nil, dataType: .text, format: .text, columnName: "y", columnIndex: 1)
        XCTAssertEqual(try SQLValueMapper.map(nullText), .null)
    }

    func testBinaryCellDispatchThroughPublicInit() throws {
        let payload = withUnsafeBytes(of: Int32(1234).bigEndian) { Data($0) }
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        let cell = PostgresCell(bytes: buffer, dataType: PostgresDataType(23), format: .binary, columnName: "n", columnIndex: 0)
        XCTAssertEqual(try SQLValueMapper.map(cell), .int(1234))
    }

    func testTypeNameForOids() {
        XCTAssertEqual(SQLValueMapper.typeName(for: .int8), "int8")
        XCTAssertEqual(SQLValueMapper.typeName(for: PostgresDataType(1700)), "numeric")
        XCTAssertEqual(SQLValueMapper.typeName(for: PostgresDataType(2950)), "uuid")
        XCTAssertEqual(SQLValueMapper.typeName(for: PostgresDataType(1184)), "timestamptz")
        XCTAssertEqual(SQLValueMapper.typeName(for: PostgresDataType(999_999)), "unknown")
    }

    // MARK: - Reverse map (SQLValue → bindable)

    func testBindableNullIsNil() {
        XCTAssertNil(SQLValueMapper.bindable(.null))
    }

    func testBindableScalarsRoundTrip() throws {
        XCTAssertEqual(SQLValueMapper.bindable(.bool(true))?.bool, true)
        XCTAssertEqual(SQLValueMapper.bindable(.int(42))?.int64, 42)
        XCTAssertEqual(SQLValueMapper.bindable(.double(2.5))?.double, 2.5)
        XCTAssertEqual(SQLValueMapper.bindable(.string("hi"))?.string, "hi")
        XCTAssertEqual(SQLValueMapper.bindable(.json("{\"a\":1}"))?.string, "{\"a\":1}")
        XCTAssertEqual(SQLValueMapper.bindable(.bytes(Data([1, 2, 3])))?.bytes, [1, 2, 3])
        XCTAssertEqual(SQLValueMapper.bindable(.decimal("1.25"))?.decimal, Decimal(string: "1.25"))
    }

    func testTemporalValuesBindAsISOText() {
        // Documented choice: dates bind as ISO text so PG infers the exact
        // target type from column context.
        let day = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        XCTAssertEqual(SQLValueMapper.bindable(.date(day))?.string, "2024-01-01")

        let instant = Date(timeIntervalSince1970: 1_704_067_230.5)
        let timestampBinding = SQLValueMapper.bindable(.datetime(instant))!.string!
        XCTAssertTrue(timestampBinding.hasPrefix("2024-01-01 00:00:30"), timestampBinding)

        XCTAssertEqual(SQLValueMapper.bindable(.time(37_800))!.string!, "10:30:00")
        XCTAssertEqual(SQLValueMapper.bindable(.time(0.5))!.string!, "00:00:00.500000")
    }
}

extension Int16 {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { [UInt8]($0) } }
}

/// Pure identifier quoting — no connection required.
final class IdentifierQuotingUnitTests: XCTestCase {
    func testQuotesPlainIdentifier() {
        XCTAssertEqual(IdentifierQuoting.quote("users"), "\"users\"")
        XCTAssertEqual(IdentifierQuoting.quote("b2c_test"), "\"b2c_test\"")
    }

    func testDoublesEmbeddedQuotes() {
        XCTAssertEqual(IdentifierQuoting.quote("we\"ird"), "\"we\"\"ird\"")
        XCTAssertEqual(IdentifierQuoting.quote("\""), "\"\"\"\"")
    }

    func testPreservesCaseSpacesAndSpecials() {
        XCTAssertEqual(IdentifierQuoting.quote("MixedCase"), "\"MixedCase\"")
        XCTAssertEqual(IdentifierQuoting.quote("with space"), "\"with space\"")
        XCTAssertEqual(IdentifierQuoting.quote("order"), "\"order\"")
        XCTAssertEqual(IdentifierQuoting.quote(""), "\"\"")
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { [UInt8]($0) } }
}

extension Int64 {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { [UInt8]($0) } }
}

/// Pure EXPLAIN (FORMAT JSON) parsing against realistic PG-shaped fixtures.
final class ExplainParserUnitTests: XCTestCase {
    /// Nested Loop root with a Seq Scan (outer, filtered) and an Index Scan
    /// (inner, index-cond driven) child — the shape real ANALYZE plans emit.
    private static let nestedFixture = """
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Join Type": "Inner",
          "Inner Unique": true,
          "Join Filter": "(u.id = o.user_id)",
          "Rows Removed by Join Filter": 2,
          "Actual Rows": 3,
          "Actual Loops": 1,
          "Actual Total Time": 0.245,
          "Shared Hit Blocks": 8,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Relation Name": "users",
              "Alias": "u",
              "Filter": "(age > 21)",
              "Rows Removed by Filter": 4,
              "Actual Rows": 5,
              "Actual Loops": 1,
              "Actual Total Time": 0.112
            },
            {
              "Node Type": "Index Scan",
              "Parent Relationship": "Inner",
              "Scan Direction": "Forward",
              "Index Name": "orders_user_id_idx",
              "Relation Name": "orders",
              "Alias": "o",
              "Index Cond": "(user_id = u.id)",
              "Actual Rows": 3,
              "Actual Loops": 5,
              "Actual Total Time": 0.087
            }
          ]
        },
        "Planning Time": 0.183,
        "Execution Time": 0.402
      }
    ]
    """

    func testParsesRootOperationAndActuals() throws {
        let plan = try ExplainParser.parse(Self.nestedFixture)
        XCTAssertEqual(plan.operation, "Nested Loop")
        XCTAssertEqual(plan.actualRows, 3)
        XCTAssertEqual(plan.actualTimeMilliseconds!, 0.245, accuracy: 1e-9)
    }

    func testJoinsNonNullDetailInfoInStableOrder() throws {
        let plan = try ExplainParser.parse(Self.nestedFixture)
        XCTAssertEqual(
            plan.detail,
            "Join Filter: (u.id = o.user_id), Rows Removed by Join Filter: 2"
        )
    }

    func testParsesChildrenRecursively() throws {
        let plan = try ExplainParser.parse(Self.nestedFixture)
        XCTAssertEqual(plan.children.count, 2)

        let seqScan = plan.children[0]
        XCTAssertEqual(seqScan.operation, "Seq Scan")
        XCTAssertEqual(seqScan.actualRows, 5)
        XCTAssertEqual(seqScan.detail, "Relation Name: users, Alias: u, Filter: (age > 21), Rows Removed by Filter: 4")
        XCTAssertTrue(seqScan.children.isEmpty)

        let indexScan = plan.children[1]
        XCTAssertEqual(indexScan.operation, "Index Scan")
        XCTAssertEqual(indexScan.actualRows, 3)
        XCTAssertEqual(indexScan.actualTimeMilliseconds!, 0.087, accuracy: 1e-9)
        XCTAssertTrue(indexScan.detail?.contains("Index Name: orders_user_id_idx") ?? false)
        XCTAssertTrue(indexScan.detail?.contains("Index Cond: (user_id = u.id)") ?? false)
    }

    func testPlainExplainWithoutActualsLeavesOptionalsNil() throws {
        let fixture = """
        [
          {"Plan": {"Node Type": "Seq Scan", "Relation Name": "t", "Plan Rows": 100}}
        ]
        """
        let plan = try ExplainParser.parse(fixture)
        XCTAssertEqual(plan.operation, "Seq Scan")
        XCTAssertNil(plan.actualRows)
        XCTAssertNil(plan.actualTimeMilliseconds)
        XCTAssertEqual(plan.detail, "Relation Name: t")
        XCTAssertTrue(plan.children.isEmpty)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try ExplainParser.parse("{not json"))
        XCTAssertThrowsError(try ExplainParser.parse("[]"))
        XCTAssertThrowsError(try ExplainParser.parse("[{\"Execution Time\": 1}]"))
    }
}

/// ANSI `?` → `$n` rewriting that never touches strings, comments, dollar
/// quotes, or quoted identifiers.
final class PlaceholderRewriterUnitTests: XCTestCase {
    private func rewritten(_ sql: String) -> String {
        PlaceholderRewriter.rewrite(sql).text
    }

    func testRewritesEachPlaceholderToNextPosition() {
        let result = PlaceholderRewriter.rewrite("UPDATE t SET a = ? WHERE b = ? AND c = ?")
        XCTAssertEqual(result.placeholderCount, 3)
        XCTAssertEqual(result.text, "UPDATE t SET a = $1 WHERE b = $2 AND c = $3")
    }

    func testIgnoresPlaceholdersInsideStringLiterals() {
        XCTAssertEqual(
            rewritten("UPDATE t SET a = 'x ? y' WHERE b = ?"),
            "UPDATE t SET a = 'x ? y' WHERE b = $1"
        )
        // Doubled quote inside the literal must not terminate it early.
        XCTAssertEqual(
            rewritten("SELECT * FROM t WHERE note = 'it''s ? here' AND id = ?"),
            "SELECT * FROM t WHERE note = 'it''s ? here' AND id = $1"
        )
    }

    func testBackslashEscapedQuoteKeepsPlaceholderInsideString() {
        XCTAssertEqual(
            rewritten(#"UPDATE t SET a = 'don\'t?' WHERE b = ?"#),
            #"UPDATE t SET a = 'don\'t?' WHERE b = $1"#
        )
    }

    func testIgnoresPlaceholdersInsideLineComment() {
        XCTAssertEqual(
            rewritten("-- filter rows ?\nWHERE id = ?"),
            "-- filter rows ?\nWHERE id = $1"
        )
    }

    func testIgnoresPlaceholdersInsideNestedBlockComments() {
        XCTAssertEqual(
            rewritten("/* outer ? /* inner ? */ still commented ? */ WHERE x = ?"),
            "/* outer ? /* inner ? */ still commented ? */ WHERE x = $1"
        )
    }

    func testIgnoresPlaceholdersInsideDollarQuotedBodies() {
        XCTAssertEqual(
            rewritten("$tag$ body ? 'even quotes' ? $tag$ WHERE x = ?"),
            "$tag$ body ? 'even quotes' ? $tag$ WHERE x = $1"
        )
        XCTAssertEqual(
            rewritten("$$ anonymous dollar ? $$ WHERE x = ?"),
            "$$ anonymous dollar ? $$ WHERE x = $1"
        )
    }

    func testIgnoresPlaceholdersInsideQuotedIdentifiers() {
        XCTAssertEqual(
            rewritten(#"UPDATE t SET "weird ? col" = ? WHERE id = ?"#),
            #"UPDATE t SET "weird ? col" = $1 WHERE id = $2"#
        )
    }

    func testLiteralBackslashOutsideStringsPassesThrough() {
        XCTAssertEqual(rewritten(#"WHERE path LIKE 'a\%' OR p = ?"#), #"WHERE path LIKE 'a\%' OR p = $1"#)
        XCTAssertEqual(rewritten(#"WHERE p = ? -- trailing backslash \"#), #"WHERE p = $1 -- trailing backslash \"#)
    }

    func testNoPlaceholdersYieldsUnchangedSQL() {
        let sql = "DELETE FROM t WHERE id = 7; /* ? */ SELECT '?'"
        XCTAssertEqual(PlaceholderRewriter.rewrite(sql).placeholderCount, 0)
        XCTAssertEqual(rewritten(sql), sql)
    }
}

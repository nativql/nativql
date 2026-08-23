import XCTest
@testable import NativQLKit

final class SQLStatementSplitterTests: XCTestCase {
    func testSplitsSimpleStatements() {
        let result = SQLStatementSplitter.split("SELECT 1; SELECT 2;")
        XCTAssertEqual(result, ["SELECT 1;", "SELECT 2;"])
    }

    func testKeepsSemicolonInsideStringLiteral() {
        let result = SQLStatementSplitter.split(#"SELECT 'a;b'; SELECT 2;"#)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], #"SELECT 'a;b';"#)
    }

    func testIgnoresSemicolonInLineComment() {
        let result = SQLStatementSplitter.split("""
        SELECT 1; -- comment; ignored
        SELECT 2;
        """)
        XCTAssertEqual(result.count, 2)
    }

    func testIgnoresSemicolonInBlockComment() {
        let result = SQLStatementSplitter.split("SELECT /* a;b */ 1; SELECT 2;")
        XCTAssertEqual(result.count, 2)
    }

    func testDollarQuotingPostgresFunctionBody() {
        let sql = """
        CREATE FUNCTION f() RETURNS void AS $$
        BEGIN
          RAISE NOTICE 'hi; there';
        END;
        $$ LANGUAGE plpgsql; SELECT 42;
        """
        let result = SQLStatementSplitter.split(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("RAISE NOTICE"))
    }

    func testDoubleQuotedIdentifiers() {
        let result = SQLStatementSplitter.split(#"SELECT "weird;name" FROM t; SELECT 2;"#)
        XCTAssertEqual(result.count, 2)
    }

    func testTaggedDollarQuoting() {
        let sql = """
        CREATE FUNCTION f() RETURNS void AS $fn$
        BEGIN
          PERFORM 1; -- semis inside are safe
        END;
        $fn$ LANGUAGE plpgsql; SELECT 42;
        """
        let result = SQLStatementSplitter.split(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("PERFORM 1;"))
        XCTAssertEqual(result[1], "SELECT 42;")
    }

    func testPositionalParamsDoNotStartDollarQuoting() {
        let result = SQLStatementSplitter.split("SELECT $1, $2 FROM t WHERE x = $1; SELECT 3;")
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("$1"))
    }

    func testTrailingContentWithoutTerminator() {
        let result = SQLStatementSplitter.split("SELECT 1; SELECT 2")
        XCTAssertEqual(result, ["SELECT 1;", "SELECT 2"])
    }

    func testEmptyInputYieldsNoStatements() {
        XCTAssertEqual(SQLStatementSplitter.split("  ;;  \n"), [])
    }
}

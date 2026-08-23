import XCTest
@testable import NativQLKit

final class QueryTypeDetectorTests: XCTestCase {
    func testSelectDetection() {
        XCTAssertEqual(QueryTypeDetector.type(of: "SELECT * FROM users"), .select)
    }

    func testSkipsLeadingCommentsAndWhitespace() {
        XCTAssertEqual(QueryTypeDetector.type(of: "-- hi\n /* yo */ \n  select 1"), .select)
    }

    func testMutations() {
        XCTAssertEqual(QueryTypeDetector.type(of: "insert into t values (1)"), .insert)
        XCTAssertEqual(QueryTypeDetector.type(of: "UPDATE t SET a=1"), .update)
        XCTAssertEqual(QueryTypeDetector.type(of: "DELETE FROM t"), .delete)
    }

    func testDDLAndUtility() {
        XCTAssertEqual(QueryTypeDetector.type(of: "CREATE TABLE t(id int)"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "DROP TABLE t"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "ALTER TABLE t ADD c int"), .ddl)
        XCTAssertEqual(QueryTypeDetector.type(of: "EXPLAIN ANALYZE SELECT 1"), .explain)
    }

    func testTransactionStatements() {
        XCTAssertEqual(QueryTypeDetector.type(of: "BEGIN"), .transactionControl)
        XCTAssertEqual(QueryTypeDetector.type(of: "COMMIT"), .transactionControl)
        XCTAssertEqual(QueryTypeDetector.type(of: "ROLLBACK"), .transactionControl)
    }

    func testUnknownFallsBackToOther() {
        XCTAssertEqual(QueryTypeDetector.type(of: ""), .other)
        XCTAssertEqual(QueryTypeDetector.type(of: "VACUUM"), .other)
    }
}

import XCTest
@testable import NativQLKit

final class ConnectionStringParserTests: XCTestCase {
    func testParsesFullPostgresURL() throws {
        let config = try ConnectionStringParser.parse(
            "postgresql://bob:hunter2@db.example.com:6543/shop?sslmode=require"
        )
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual(config.user, "bob")
        XCTAssertEqual(config.password, "hunter2")
        XCTAssertEqual(config.host, "db.example.com")
        XCTAssertEqual(config.port, 6543)
        XCTAssertEqual(config.database, "shop")
        XCTAssertEqual(config.sslMode, .require)
    }

    func testPostgresSchemeAliasAndDefaults() throws {
        let config = try ConnectionStringParser.parse("postgres://alice@localhost/mydb")
        XCTAssertEqual(config.kind, .postgres)
        XCTAssertEqual(config.port, 5432)          // default filled in
        XCTAssertEqual(config.sslMode, .prefer)     // default when absent
        XCTAssertNil(config.password)
    }

    func testParsesMySQLURLWithEncodedPassword() throws {
        let config = try ConnectionStringParser.parse(
            "mysql://root:s3cret%40x@127.0.0.1:3307/app"
        )
        XCTAssertEqual(config.kind, .mysql)
        XCTAssertEqual(config.password, "s3cret@x")  // %40 decoded
        XCTAssertEqual(config.user, "root")
        XCTAssertEqual(config.port, 3307)
        XCTAssertEqual(config.database, "app")
    }

    func testRejectsUnknownScheme() {
        XCTAssertThrowsError(try ConnectionStringParser.parse("sqlite:///tmp/db.sqlite"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ConnectionStringParser.parse("not a url at all"))
    }
}

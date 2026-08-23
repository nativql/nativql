import XCTest
@testable import NativQLKit

final class DatabaseKindTests: XCTestCase {
    func testDefaultPorts() {
        XCTAssertEqual(DatabaseKind.postgres.defaultPort, 5432)
        XCTAssertEqual(DatabaseKind.mysql.defaultPort, 3306)
    }

    func testDisplayNames() {
        XCTAssertEqual(DatabaseKind.postgres.displayName, "PostgreSQL")
        XCTAssertEqual(DatabaseKind.mysql.displayName, "MySQL")
    }
}

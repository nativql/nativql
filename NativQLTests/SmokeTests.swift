import XCTest
@testable import NativQLKit

final class SmokeTests: XCTestCase {
    func testAppLinksKit() {
        XCTAssertEqual(DatabaseKind.postgres.displayName, "PostgreSQL")
    }
}

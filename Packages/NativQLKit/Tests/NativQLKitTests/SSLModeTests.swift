import XCTest
@testable import NativQLKit

final class SSLModeTests: XCTestCase {
    func testPostgresAvailableModes() {
        XCTAssertEqual(
            SSLMode.availableModes(for: .postgres),
            [.disable, .prefer, .require, .verifyFull]
        )
    }

    func testMySQLAvailableModes() {
        XCTAssertEqual(
            SSLMode.availableModes(for: .mysql),
            [.disable, .prefer, .require, .verifyCA, .verifyFull]
        )
    }
}

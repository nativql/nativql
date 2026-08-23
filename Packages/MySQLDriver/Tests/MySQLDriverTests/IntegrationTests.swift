import XCTest
import NativQLKit
@testable import MySQLDriver

/// Live-server round-trips against the Batch 1 docker compose MySQL 8
/// (127.0.0.1:53306, user/pass `nativql`, db `nativql_test`).
///
/// Skipped entirely unless `NATIVQL_INTEGRATION=1`, so plain CI runs stay green:
///
///     swift test
///     NATIVQL_INTEGRATION=1 swift test
final class IntegrationTests: XCTestCase {
    private static let envKey = "NATIVQL_INTEGRATION"

    /// Throws XCTSkip unless live-server tests were explicitly requested.
    private func requireLiveServer() throws {
        guard ProcessInfo.processInfo.environment[Self.envKey] == "1" else {
            throw XCTSkip("set \(Self.envKey)=1 to run live MySQL integration tests")
        }
    }

    func makeLiveDriver() throws -> MySQLDriver {
        try requireLiveServer()
        return MySQLDriver()
    }

    private func makeConfig(
        password: String? = "nativql",
        port: Int = 53306,
        sslMode: SSLMode = .disable
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: "integration-mysql",
            kind: .mysql,
            host: "127.0.0.1",
            port: port,
            user: "nativql",
            password: password,
            database: "nativql_test",
            sslMode: sslMode
        )
    }

    // MARK: - Connection lifecycle

    func testConnectCapturesSessionIDThenDisconnects() async throws {
        let driver = try makeLiveDriver()

        try await driver.connect(makeConfig())
        let id = await driver.sessionID()
        let connected = await driver.isConnected()
        XCTAssertNotNil(id)
        XCTAssertGreaterThan(id ?? 0, 0, "CONNECTION_ID() must be a positive session id")
        XCTAssertTrue(connected)

        await driver.disconnect()
        let connectedAfterDisconnect = await driver.isConnected()
        let idAfterDisconnect = await driver.sessionID()
        XCTAssertFalse(connectedAfterDisconnect, "isConnected must be false after disconnect")
        XCTAssertNil(idAfterDisconnect, "session id must be cleared on disconnect")
    }

    func testConnectIsIdempotentAcrossReconnects() async throws {
        let driver = try makeLiveDriver()

        for _ in 0..<2 {
            try await driver.connect(makeConfig())
            let connected = await driver.isConnected()
            XCTAssertTrue(connected)
            await driver.disconnect()
        }
    }

    func testBadPasswordThrowsAuthenticationFailed() async throws {
        let driver = try makeLiveDriver()

        do {
            try await driver.connect(makeConfig(password: "definitely-not-the-password"))
            XCTFail("connect with a wrong password must throw")
            await driver.disconnect()
        } catch let error as DriverError {
            guard case .authenticationFailed(let message) = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testWrongPortThrowsConnectionFailed() async throws {
        let driver = try makeLiveDriver()

        do {
            try await driver.connect(makeConfig(port: 53399))
            XCTFail("connect to a closed port must throw")
            await driver.disconnect()
        } catch let error as DriverError {
            guard case .connectionFailed = error else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
        }
    }
}

// MARK: - Task B (appended; kept as extension to avoid touching original class body)
extension IntegrationTests {
    // MARK: - Execution & type mapping (Task B)

    func testFullTypeRoundTrip() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }
        try await driver.connect(makeConfig())

        _ = try await driver.execute("""
        CREATE TEMPORARY TABLE t_types (
            id INT PRIMARY KEY AUTO_INCREMENT,
            f_biguint BIGINT UNSIGNED,
            f_dec DECIMAL(10,2),
            f_text TEXT,
            f_bool TINYINT(1),
            f_dt DATETIME,
            f_json JSON,
            f_blob BLOB
        );
        """)

        _ = try await driver.execute("""
        INSERT INTO t_types (f_biguint, f_dec, f_text, f_bool, f_dt, f_json, f_blob)
        VALUES (1844674407370955161, 1234.57, 'héllo', 1, '2026-08-23 12:34:56', '{"k": [1, 2]}', _binary'DEADBEEF');
        """)
        let result = try await driver.execute("SELECT * FROM t_types ORDER BY id;")

        XCTAssertEqual(result.statementType, .select)
        XCTAssertEqual(result.rows.count, 1)
        let row = result.rows[0]
        // id (auto-increment), f_biguint fits Int64? 1.8e18 < 9.2e18 → int
        XCTAssertEqual(row[0], .int(1))
        XCTAssertEqual(row[1], .int(1_844_674_407_370_955_161))
        XCTAssertEqual(row[2], .decimal("1234.57"))
        XCTAssertEqual(row[3], .string("héllo"))
        XCTAssertEqual(row[4], .int(1))  // TINYINT(1) surfaces as int (documented)
        if case .datetime(let dt) = row[5] {
            let comps = Calendar(identifier: .gregorian)
                .dateComponents(in: TimeZone(identifier: "UTC")!, from: dt)
            XCTAssertEqual(comps.year, 2026)
            XCTAssertEqual(comps.month, 8)
            XCTAssertEqual(comps.day, 23)
            XCTAssertEqual(comps.hour, 12)
        } else {
            XCTFail("expected datetime, got \(row[5])")
        }
        XCTAssertEqual(row[6], .json(#"{"k": [1, 2]}"#))
        if case .bytes(let data) = row[7] {
            XCTAssertEqual(String(data: data, encoding: .utf8), "DEADBEEF")
        } else {
            XCTFail("expected bytes, got \(row[7])")
        }

        // NULL round trip on second row
        _ = try await driver.execute(
            "INSERT INTO t_types (f_biguint, f_dec) VALUES (NULL, NULL);"
        )
        let nulls = try await driver.execute(
            "SELECT f_biguint, f_dec FROM t_types WHERE f_biguint IS NULL;"
        )
        XCTAssertEqual(nulls.rows.count, 1)
        XCTAssertEqual(nulls.rows[0][0], SQLValue.null)
        XCTAssertEqual(nulls.rows[0][1], SQLValue.null)
    }

    func testMultiStatementScriptReturnsLastRowProducingResult() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }
        try await driver.connect(makeConfig())

        let result = try await driver.execute("""
        CREATE TEMPORARY TABLE x(a INT);
        INSERT INTO x VALUES (7);
        SELECT * FROM x;
        """)
        XCTAssertEqual(result.rows, [[.int(7)]])
        XCTAssertGreaterThanOrEqual(result.affectedRows ?? 0, 1)

        // Zero-row SELECT: MySQLNIO 1.x exposes no column definitions when
        // no rows flow back (documented limitation), so headers are empty
        // while rows stay correct.
        let headers = try await driver.execute(
            "SELECT a AS alias_a FROM x WHERE a > 100;"
        )
        XCTAssertEqual(headers.rows.count, 0)
        XCTAssertTrue(headers.columns.isEmpty)
    }

    func testSyntaxErrorThrowsQueryFailedWithServerMessage() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }
        try await driver.connect(makeConfig())

        do {
            _ = try await driver.execute("SELEC bogus;")
            XCTFail("expected error")
        } catch let error as DriverError {
            guard case .queryFailed(let message) = error else {
                return XCTFail("wrong error case: \(error)")
            }
            XCTAssertTrue(message.contains("syntax"), "unexpected message: \(message)")
        }
    }
}

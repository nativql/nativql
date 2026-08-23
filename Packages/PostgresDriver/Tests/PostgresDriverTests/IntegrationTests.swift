import XCTest
import NativQLKit
@testable import PostgresDriver

/// Live-server round-trips against the Batch 1 docker compose PostgreSQL
/// (127.0.0.1:55432, user/pass `nativql`, db `nativql_test`).
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
            throw XCTSkip("set \(Self.envKey)=1 to run live PostgreSQL integration tests")
        }
    }

    func makeLiveDriver() throws -> PostgresDriver {
        try requireLiveServer()
        return PostgresDriver()
    }

    private func makeConfig(
        password: String? = "nativql",
        port: Int = 55432,
        sslMode: SSLMode = .disable
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: "integration-pg",
            kind: .postgres,
            host: "127.0.0.1",
            port: port,
            user: "nativql",
            password: password,
            database: "nativql_test",
            sslMode: sslMode
        )
    }

    // MARK: - Connection lifecycle

    func testConnectCapturesBackendPIDThenDisconnects() async throws {
        let driver = try makeLiveDriver()

        try await driver.connect(makeConfig())
        let pid = await driver.backendPID()
        let connected = await driver.isConnected()
        XCTAssertNotNil(pid)
        XCTAssertGreaterThan(pid ?? 0, 0, "pg_backend_pid must be a positive backend process id")
        XCTAssertTrue(connected)

        await driver.disconnect()
        let connectedAfterDisconnect = await driver.isConnected()
        let pidAfterDisconnect = await driver.backendPID()
        XCTAssertFalse(connectedAfterDisconnect, "isConnected must be false after disconnect")
        XCTAssertNil(pidAfterDisconnect, "pid must be cleared on disconnect")
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
            try await driver.connect(makeConfig(port: 55499))
            XCTFail("connect to a closed port must throw")
            await driver.disconnect()
        } catch let error as DriverError {
            guard case .connectionFailed = error else {
                return XCTFail("expected connectionFailed, got \(error)")
            }
        }
    }

    // MARK: - Query execution & type mapping (Task B)

    /// Full round-trip over every SQLValue-relevant column type, including
    /// NULLs, through the real binary wire format.
    func testExecuteRoundTripsAllValueTypes() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP TABLE IF EXISTS t_types;
            CREATE TABLE t_types(
                id int4 PRIMARY KEY,
                f_text text,
                f_bool bool,
                f_num numeric(10,2),
                f_ts timestamp,
                f_json jsonb,
                f_bytea bytea
            );
            """
        )

        let insert = try await driver.execute(
            """
            INSERT INTO t_types VALUES (
                1,
                'héllo wörld',
                true,
                123.45,
                '2024-06-15 12:34:56',
                '{"a": [1, 2], "b": "x"}',
                '\\xDEADBEEF'
            );
            INSERT INTO t_types VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL);
            """
        )
        XCTAssertEqual(insert.affectedRows, 2, "both INSERT tags must accumulate")

        let select = try await driver.execute("SELECT * FROM t_types ORDER BY id")
        XCTAssertEqual(select.columns.map(\.dataType), ["int4", "text", "bool", "numeric", "timestamp", "jsonb", "bytea"])
        XCTAssertEqual(select.rows.count, 2)
        XCTAssertEqual(select.statementType, .select)

        let row1 = select.rows[0]
        XCTAssertEqual(row1[0], .int(1))
        XCTAssertEqual(row1[1], .string("héllo wörld"))
        XCTAssertEqual(row1[2], .bool(true))
        XCTAssertEqual(row1[3], .decimal("123.45"), "numeric must preserve display scale")

        guard case .datetime(let ts) = row1[4] else {
            return XCTFail("expected .datetime, got \(row1[4])")
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts),
                       DateComponents(year: 2024, month: 6, day: 15, hour: 12, minute: 34, second: 56))

        guard case .json(let json) = row1[5] else {
            return XCTFail("expected .json, got \(row1[5])")
        }
        XCTAssertTrue(json.contains("\"a\""), "jsonb text should carry parsed content: \(json)")

        XCTAssertEqual(row1[6], .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))

        let row2 = select.rows[1]
        for (index, value) in row2.enumerated() {
            if index == 0 {
                XCTAssertEqual(value, .int(2))
            } else {
                XCTAssertEqual(value, .null, "column \(index) must be .null")
            }
        }

        _ = try await driver.execute("DROP TABLE t_types")
    }

    func testMultiStatementScriptKeepsLastSelectAndAccumulatesAffectedRows() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let result = try await driver.execute(
            "CREATE TEMP TABLE x(a int); INSERT INTO x VALUES (7); SELECT * FROM x;"
        )

        XCTAssertEqual(result.rows, [[.int(7)]])
        XCTAssertNotNil(result.affectedRows)
        XCTAssertGreaterThanOrEqual(result.affectedRows ?? 0, 1)
        XCTAssertEqual(result.statementType, .select)
    }

    func testSyntaxErrorThrowsQueryFailedWithServerMessage() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        do {
            _ = try await driver.execute("SELEC bogus")
            XCTFail("syntax error must throw")
        } catch let error as DriverError {
            guard case .queryFailed(let message) = error else {
                return XCTFail("expected queryFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("SELEC"), "server message should quote the offending token: \(message)")
            XCTAssertTrue(message.lowercased().contains("syntax"), "message should hint at syntax: \(message)")
        }
    }

    func testEmptyScriptReturnsEmptyOtherResult() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let result = try await driver.execute("   \n   ")
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.statementType, .other)
        XCTAssertEqual(result.executionMilliseconds, 0)
    }

    func testUpdateCommandTagCountsAffectedRows() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let setup = try await driver.execute(
            "CREATE TEMP TABLE u(id int); INSERT INTO u VALUES (1), (2), (3);"
        )
        XCTAssertEqual(setup.affectedRows, 3)

        let update = try await driver.execute("UPDATE u SET id = id WHERE id > 1")
        XCTAssertEqual(update.affectedRows, 2)

        let delete = try await driver.execute("DELETE FROM u")
        XCTAssertEqual(delete.affectedRows, 3)
        XCTAssertTrue(delete.rows.isEmpty)
    }
}

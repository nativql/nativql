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

    // MARK: - Introspection (Task C)

    /// Batch 2 Task C fixture: composite PK, identity column, defaults,
    /// FK, a PK-less table, and view/matview kind samples under one schema.
    private func makeIntrospectionFixture(_ driver: PostgresDriver) async throws {
        _ = try await driver.execute(
            """
            DROP SCHEMA IF EXISTS b2c_test CASCADE;
            CREATE SCHEMA b2c_test;
            CREATE TABLE b2c_test.users(
                id int8 GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                email text NOT NULL UNIQUE
            );
            CREATE TABLE b2c_test.orders(
                id int4,
                user_id int8 REFERENCES b2c_test.users(id),
                amount numeric(12,2),
                note text DEFAULT 'none',
                PRIMARY KEY(id, user_id)
            );
            CREATE TABLE b2c_test.no_pk(id int4);
            CREATE VIEW b2c_test.user_emails AS SELECT id, email FROM b2c_test.users;
            CREATE MATERIALIZED VIEW b2c_test.order_totals_mv AS SELECT id, amount FROM b2c_test.orders;
            """
        )
    }

    private func dropIntrospectionFixture(_ driver: PostgresDriver) async {
        _ = try? await driver.execute("DROP SCHEMA IF EXISTS b2c_test CASCADE")
    }

    func testListDatabasesIncludesConnectedDatabaseAndExcludesTemplates() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        let databases = try await driver.listDatabases()

        XCTAssertTrue(databases.contains { $0.name == "nativql_test" })
        XCTAssertFalse(databases.contains { $0.name == "template0" }, "template DBs must be filtered")
        XCTAssertFalse(databases.contains { $0.name == "template1" }, "template DBs must be filtered")
    }

    func testListTablesFiltersSystemSchemasAndReportsKindsAndEstimates() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        // Default listing: system schemas excluded.
        let all = try await driver.listTables(database: "nativql_test", schema: nil)
        XCTAssertFalse(all.isEmpty)
        for table in all {
            let schema = table.ref.schema ?? ""
            XCTAssertNotEqual(schema, "pg_catalog", "system schema must be excluded by default")
            XCTAssertNotEqual(schema, "information_schema", "system schema must be excluded by default")
            XCTAssertFalse(schema.hasPrefix("pg_"), "pg_% schemas must be excluded by default")
        }
        XCTAssertTrue(all.contains { $0.ref.schema == "b2c_test" && $0.ref.name == "users" && $0.kind == .table })

        // Explicit schema filter narrows to exactly that schema, with kinds
        // and non-negative estimates.
        let scoped = try await driver.listTables(database: "nativql_test", schema: "b2c_test")
        XCTAssertEqual(Set(scoped.map { $0.ref.schema ?? "" }), ["b2c_test"])

        let users = scoped.first { $0.ref.name == "users" }
        XCTAssertEqual(users?.kind, .table)
        XCTAssertGreaterThanOrEqual(users?.estimatedRowCount ?? -1, 0, "estimate must be ≥ 0")

        let orders = scoped.first { $0.ref.name == "orders" }
        XCTAssertEqual(orders?.kind, .table)
        XCTAssertGreaterThanOrEqual(orders?.estimatedRowCount ?? -1, 0, "estimate must be ≥ 0")

        let emailsView = scoped.first { $0.ref.name == "user_emails" }
        XCTAssertEqual(emailsView?.kind, .view)
        let matview = scoped.first { $0.ref.name == "order_totals_mv" }
        XCTAssertEqual(matview?.kind, .view, "matviews surface as .view (Kit has no matview kind)")
    }

    func testListColumnsOrdinalOrderAndPrimaryKeyFlags() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersRef = TableRef(database: "nativql_test", schema: "b2c_test", name: "orders")
        let columns = try await driver.listColumns(ordersRef)

        // NOTE: fixture defines FOUR columns (id, user_id, amount, note);
        // asserted in exact ordinal order.
        XCTAssertEqual(columns.map(\.name), ["id", "user_id", "amount", "note"])
        XCTAssertEqual(columns.map(\.dataType), ["integer", "bigint", "numeric", "text"],
                       "data_type must be verbatim information_schema values")

        // PK flags: true exactly for (id, user_id), preserving ordinal order.
        XCTAssertEqual(columns.map(\.isPrimaryKey), [true, true, false, false])

        // Nullable/default details.
        XCTAssertTrue(columns[3].isNullable, "DEFAULT does not imply NOT NULL")
        XCTAssertNotNil(columns[3].defaultValue)
        XCTAssertTrue(columns[3].defaultValue?.contains("'none'") ?? false)
        XCTAssertNil(columns[0].defaultValue, "id carries no default")

        // Default schema resolution: unqualified ref hits public, which must
        // NOT see through to same-named tables elsewhere — assert miss throws.
        do {
            _ = try await driver.listColumns(TableRef(database: "nativql_test", schema: nil, name: "orders"))
            XCTFail("public.orders does not exist; lookup must throw")
        } catch is DriverError {
            // expected
        }
    }

    func testPrimaryKeyOrderAndAbsence() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersPK = try await driver.primaryKey(of: TableRef(database: "nativql_test", schema: "b2c_test", name: "orders"))
        XCTAssertEqual(ordersPK, ["id", "user_id"], "composite PK order must match constraint declaration")

        let usersPK = try await driver.primaryKey(of: TableRef(database: "nativql_test", schema: "b2c_test", name: "users"))
        XCTAssertEqual(usersPK, ["id"])

        let noPK = try await driver.primaryKey(of: TableRef(database: "nativql_test", schema: "b2c_test", name: "no_pk"))
        XCTAssertNil(noPK, "PK-less table must return nil")
    }

    func testTableDDLReconstruction() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersDDL = try await driver.tableDDL(TableRef(database: "nativql_test", schema: "b2c_test", name: "orders"))
        XCTAssertTrue(ordersDDL.hasPrefix("CREATE TABLE \"b2c_test\".\"orders\""), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("PRIMARY KEY (\"id\", \"user_id\")"), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("DEFAULT 'none'"), "note's default must appear: \(ordersDDL)")
        XCTAssertTrue(ordersDDL.contains("numeric(12,2)"), "formatted type must keep scale: \(ordersDDL)")
        XCTAssertTrue(ordersDDL.hasSuffix(";"), "statement must end with a semicolon")

        let usersDDL = try await driver.tableDDL(TableRef(database: "nativql_test", schema: "b2c_test", name: "users"))
        XCTAssertTrue(usersDDL.hasPrefix("CREATE TABLE \"b2c_test\".\"users\""), usersDDL)
        XCTAssertTrue(usersDDL.contains("\"email\" text NOT NULL"), "NOT NULL must render: \(usersDDL)")
        XCTAssertTrue(usersDDL.contains("PRIMARY KEY (\"id\")"), usersDDL)

        do {
            _ = try await driver.tableDDL(TableRef(database: "nativql_test", schema: "b2c_test", name: "does_not_exist"))
            XCTFail("DDL of a missing table must throw")
        } catch is DriverError {
            // expected
        }
    }

    // MARK: - Browsing, explain, admin, mutations, cancel (Task D)

    /// 25 seeded rows (id 1…25) with an index-free sort column; ANALYZE makes
    /// reltuples a usable total estimate.
    private func makeBrowseFixture(_ driver: PostgresDriver) async throws {
        _ = try await driver.execute(
            """
            DROP SCHEMA IF EXISTS b2d_test CASCADE;
            CREATE SCHEMA b2d_test;
            CREATE TABLE b2d_test.nums(id int4 PRIMARY KEY, val text);
            """
        )
        let inserts = (1...25).map { "INSERT INTO b2d_test.nums VALUES (\($0), 'row-\(String(format: "%02d", $0))')" }
        _ = try await driver.execute(inserts.joined(separator: "; "))
        _ = try await driver.execute("ANALYZE b2d_test.nums")
    }

    private func dropBrowseFixture(_ driver: PostgresDriver) async {
        _ = try? await driver.execute("DROP SCHEMA IF EXISTS b2d_test CASCADE")
    }

    private var numsRef: TableRef {
        TableRef(database: "nativql_test", schema: "b2d_test", name: "nums")
    }

    func testBrowseSortsAndWindowsExactly() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeBrowseFixture(driver)
        defer { Task { await self.dropBrowseFixture(driver) } }

        // Ascending first page.
        let asc = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id", ascending: true), limit: 10, offset: 0)
        XCTAssertEqual(asc.columns.map(\.name), ["id", "val"])
        XCTAssertEqual(asc.rows.map { $0[0] }, (1...10).map(SQLValue.int))
        XCTAssertNotNil(asc.totalCountEstimate, "reltuples estimate must be populated after ANALYZE")
        XCTAssertGreaterThanOrEqual(asc.totalCountEstimate ?? 0, 25)

        // Descending tail window: ids 5…1.
        let descTail = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id", ascending: false), limit: 5, offset: 20)
        XCTAssertEqual(descTail.rows.map { $0[0] }, stride(from: 5, through: 1, by: -1).map(SQLValue.int))

        // Middle window of the descending order (25…1): offset 8 starts at id 17.
        let midDesc = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id", ascending: false), limit: 5, offset: 8)
        XCTAssertEqual(midDesc.rows.map { $0[0] }, stride(from: 17, through: 13, by: -1).map(SQLValue.int))

        // Offset past the end → empty grid, headers intact.
        let beyond = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id"), limit: 10, offset: 30)
        XCTAssertTrue(beyond.rows.isEmpty)
        XCTAssertEqual(beyond.columns.map(\.name), ["id", "val"])

        // Invalid windows must be rejected client-side.
        do {
            _ = try await driver.browseRows(self.numsRef, sort: nil, limit: 0, offset: 0)
            XCTFail("limit must be > 0")
        } catch is DriverError {}
        do {
            _ = try await driver.browseRows(self.numsRef, sort: nil, limit: 5, offset: -1)
            XCTFail("offset must be ≥ 0")
        } catch is DriverError {}
    }

    func testExplainParsesTreeWithChildrenAndActuals() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeBrowseFixture(driver)
        defer { Task { await self.dropBrowseFixture(driver) } }

        // ORDER BY the unindexed `val` forces Limit → Sort → Seq Scan nesting;
        // ANALYZE fills Actual Rows / Actual Total Time.
        let analyzed = try await driver.explain(
            "SELECT * FROM b2d_test.nums WHERE id > 3 ORDER BY val LIMIT 5",
            analyze: true
        )
        XCTAssertEqual(analyzed.operation, "Limit")
        let sort = analyzed.children.first
        XCTAssertEqual(sort?.operation, "Sort")
        let scan = sort?.children.first
        XCTAssertEqual(scan?.operation, "Seq Scan")
        XCTAssertNotNil(scan?.actualRows, "ANALYZE must populate Actual Rows")
        XCTAssertGreaterThan(scan?.actualRows ?? -1, 0)
        XCTAssertNotNil(scan?.actualTimeMilliseconds)
        XCTAssertTrue(scan?.detail?.contains("Relation Name: nums") ?? false, scan?.detail ?? "no detail")
        XCTAssertTrue(scan?.detail?.contains("Filter") ?? false, "seq scan should carry the WHERE filter")

        // Without ANALYZE there are no actuals.
        let plain = try await driver.explain("SELECT * FROM b2d_test.nums WHERE id = 7", analyze: false)
        XCTAssertNil(plain.actualRows)
        XCTAssertNil(plain.actualTimeMilliseconds)
        XCTAssertTrue(plain.children.isEmpty)

        // Server-side failures surface as queryFailed.
        do {
            _ = try await driver.explain("SELECT * FROM b2d_test.does_not_exist", analyze: false)
            XCTFail("EXPLAIN of a missing relation must throw")
        } catch let error as DriverError {
            guard case .queryFailed = error else {
                return XCTFail("expected queryFailed, got \(error)")
            }
        }
    }

    func testCreateAndDropDatabaseRoundTrip() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let name = "b2d_admin_" + UUID().uuidString.prefix(8).lowercased()
        let before = try await driver.listDatabases()
        XCTAssertFalse(before.contains { $0.name == name })

        try await driver.createDatabase(named: name)
        let during = try await driver.listDatabases()
        XCTAssertTrue(during.contains { $0.name == name }, "created database must be listed")

        try await driver.dropDatabase(named: name)
        let after = try await driver.listDatabases()
        XCTAssertFalse(after.contains { $0.name == name }, "dropped database must disappear")

        // Dropping again must fail cleanly with a server message.
        do {
            try await driver.dropDatabase(named: name)
            XCTFail("drop of nonexistent database must throw")
        } catch let error as DriverError {
            guard case .queryFailed(let message) = error else {
                return XCTFail("expected queryFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("does not exist"), message)
        }
    }

    func testExecuteMutationSumsAffectedRowsAndPersists() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP SCHEMA IF EXISTS b2d_mut CASCADE;
            CREATE SCHEMA b2d_mut;
            CREATE TABLE b2d_mut.t_upd(id int4 PRIMARY KEY, score int4);
            INSERT INTO b2d_mut.t_upd VALUES (1, 0), (2, 0), (3, 0);
            """
        )
        defer { Task { _ = try? await driver.execute("DROP SCHEMA IF EXISTS b2d_mut CASCADE") } }

        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "nativql_test", schema: "b2d_mut", name: "t_upd"),
            sql: "UPDATE b2d_mut.t_upd SET score = ? WHERE id = ?",
            batches: [
                [.int(100), .int(1)],
                [.int(200), .int(2)],
                [.int(300), .int(3)],
            ]
        )

        let total = try await driver.executeMutation(statement)
        XCTAssertEqual(total, 3, "one affected row per batch must accumulate")

        let check = try await driver.execute("SELECT id, score FROM b2d_mut.t_upd ORDER BY id")
        XCTAssertEqual(check.rows, [[.int(1), .int(100)], [.int(2), .int(200)], [.int(3), .int(300)]],
                       "all batches must have committed")
    }

    func testExecuteMutationRollsBackEverythingOnConstraintViolation() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP SCHEMA IF EXISTS b2d_mut CASCADE;
            CREATE SCHEMA b2d_mut;
            CREATE TABLE b2d_mut.t_rb(id int4 PRIMARY KEY, v int4);
            INSERT INTO b2d_mut.t_rb VALUES (1, 0), (2, 0);
            """
        )
        defer { Task { _ = try? await driver.execute("DROP SCHEMA IF EXISTS b2d_mut CASCADE") } }

        // Batch 1 succeeds; batch 2 collides on the primary key → the whole
        // transaction (including batch 1's change) must roll back.
        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "nativql_test", schema: "b2d_mut", name: "t_rb"),
            sql: "UPDATE b2d_mut.t_rb SET id = ? WHERE id = ?",
            batches: [
                [.int(11), .int(1)],
                [.int(11), .int(2)],
            ]
        )

        do {
            _ = try await driver.executeMutation(statement)
            XCTFail("constraint violation must throw")
        } catch let error as DriverError {
            guard case .mutationFailed(let message) = error else {
                return XCTFail("expected mutationFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("duplicate"), "server message expected: \(message)")
        }

        let after = try await driver.execute("SELECT id, v FROM b2d_mut.t_rb ORDER BY id")
        XCTAssertEqual(after.rows, [[.int(1), .int(0)], [.int(2), .int(0)]],
                       "zero changes may persist after the failed transaction")
    }

    func testExecuteMutationRejectsBatchBindCountMismatch() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "nativql_test", schema: "public", name: "whatever"),
            sql: "UPDATE x SET a = ? WHERE b = ?",
            batches: [[.int(1)]]
        )
        do {
            _ = try await driver.executeMutation(statement)
            XCTFail("bind-count mismatch must throw before touching the server")
        } catch let error as DriverError {
            guard case .mutationFailed = error else {
                return XCTFail("expected mutationFailed, got \(error)")
            }
        }
    }

    func testCancelRunningQueryAbortsPgSleepPromptly() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let clock = ContinuousClock()
        let execTask = Task { try await driver.execute("SELECT pg_sleep(10)") }
        try await Task.sleep(for: .milliseconds(200))

        let cancelStart = clock.now
        await driver.cancelRunningQuery()

        do {
            _ = try await execTask.value
            XCTFail("the cancelled pg_sleep must not complete successfully")
        } catch let error as DriverError {
            guard case .cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
            let elapsed = clock.now - cancelStart
            XCTAssertLessThan(elapsed, .seconds(5), "cancellation must take effect promptly")
        }

        // The primary connection stays usable after the cancellation.
        let stillAlive = try await driver.execute("SELECT 42")
        XCTAssertEqual(stillAlive.rows, [[.int(42)]])
    }

    func testCancelRunningQueryWithoutConnectionIsNoop() async throws {
        let driver = try makeLiveDriver()
        // Not connected: must neither throw nor hang.
        await driver.cancelRunningQuery()
    }
}

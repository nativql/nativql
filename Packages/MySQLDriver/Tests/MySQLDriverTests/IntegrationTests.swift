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
            f_blob BLOB,
            f_time TIME,
            f_ntime TIME,
            f_longtime TIME,
            f_year YEAR,
            f_bit BIT(16)
        );
        """)

        _ = try await driver.execute("""
        INSERT INTO t_types (f_biguint, f_dec, f_text, f_bool, f_dt, f_json, f_blob,
                             f_time, f_ntime, f_longtime, f_year, f_bit)
        VALUES (1844674407370955161, 1234.57, 'héllo', 1, '2026-08-23 12:34:56', '{"k": [1, 2]}', _binary'DEADBEEF',
                '13:45:30', '-01:30:05', '25:01:01', 2026, 258);
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
        // TIME sign/days coverage (binary wire layout parsed directly)
        XCTAssertEqual(row[8], .time(49_530))       // 13:45:30
        XCTAssertEqual(row[9], .time(-5_405))       // -01:30:05
        XCTAssertEqual(row[10], .time(90_061))      // 25:01:01 (>24h via days)
        XCTAssertEqual(row[11], .int(2_026))        // YEAR
        XCTAssertEqual(row[12], .int(258))          // BIT(16) big-endian 0x0102

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

// MARK: - Introspection (Batch 3 Task C)
extension IntegrationTests {
    /// Batch 3 Task C fixture: composite PK, auto-increment identity PK,
    /// defaults, a PK-less table, and a view — inside database `b3c_test`
    /// (MySQL schema == database).
    private func makeIntrospectionFixture(_ driver: MySQLDriver) async throws {
        _ = try await driver.execute(
            """
            DROP TABLE IF EXISTS nativql_test.b3c_scope_probe;
            DROP DATABASE IF EXISTS b3c_test;
            CREATE DATABASE b3c_test;
            CREATE TABLE b3c_test.users(
                id INT PRIMARY KEY AUTO_INCREMENT,
                email VARCHAR(255) NOT NULL UNIQUE
            );
            CREATE TABLE b3c_test.orders(
                id INT NOT NULL,
                user_id INT NOT NULL,
                amount DECIMAL(12,2),
                note VARCHAR(255) DEFAULT 'none',
                PRIMARY KEY(id, user_id)
            );
            CREATE TABLE b3c_test.no_pk(id INT);
            CREATE VIEW b3c_test.user_emails AS SELECT id, email FROM b3c_test.users;
            INSERT INTO b3c_test.users(email) VALUES ('a@x.dev'), ('b@x.dev');
            ANALYZE TABLE b3c_test.users;
            CREATE TABLE nativql_test.b3c_scope_probe(id INT);
            """
        )
    }

    private func dropIntrospectionFixture(_ driver: MySQLDriver) async {
        _ = try? await driver.execute("DROP TABLE IF EXISTS nativql_test.b3c_scope_probe")
        _ = try? await driver.execute("DROP DATABASE IF EXISTS b3c_test")
    }

    func testListDatabasesExcludesSystemSchemas() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        let databases = try await driver.listDatabases()

        XCTAssertTrue(databases.contains { $0.name == "nativql_test" })
        for system in ["information_schema", "mysql", "performance_schema", "sys"] {
            XCTAssertFalse(databases.contains { $0.name == system }, "\(system) must be filtered")
        }
        // Deterministic ordering (SHOW DATABASES output order is not).
        XCTAssertEqual(databases.map(\.name), databases.map(\.name).sorted())
    }

    func testListTablesScopesToDatabaseAndReportsKindsAndEstimates() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        // Default listing: the connected database only — the probe table is
        // visible, b3c_test objects are not.
        let all = try await driver.listTables(database: "nativql_test", schema: nil)
        XCTAssertTrue(all.contains { $0.ref.name == "b3c_scope_probe" })
        XCTAssertFalse(all.contains { $0.ref.name == "users" }, "other databases must not leak in")
        for table in all {
            XCTAssertEqual(table.ref.schema, "nativql_test", "schema carries the database name")
        }

        // Scoped listing narrows to exactly b3c_test with kinds + estimates.
        let scoped = try await driver.listTables(database: "whatever-arg", schema: "b3c_test")
        XCTAssertEqual(Set(scoped.map { $0.ref.schema ?? "" }), ["b3c_test"])

        let names = Set(scoped.map(\.ref.name))
        XCTAssertEqual(names, ["users", "orders", "no_pk", "user_emails"])

        let users = scoped.first { $0.ref.name == "users" }
        XCTAssertEqual(users?.kind, .table)
        XCTAssertGreaterThanOrEqual(users?.estimatedRowCount ?? -1, 2,
                                    "ANALYZEd table must carry a ≥ 2 estimate")

        let orders = scoped.first { $0.ref.name == "orders" }
        XCTAssertEqual(orders?.kind, .table)
        XCTAssertEqual(orders?.estimatedRowCount, 0, "empty table estimates 0")

        let emailsView = scoped.first { $0.ref.name == "user_emails" }
        XCTAssertEqual(emailsView?.kind, .view)
        XCTAssertNil(emailsView?.estimatedRowCount, "view TABLE_ROWS is NULL → nil estimate")

        // A nonexistent database yields no rows rather than an error.
        let empty = try await driver.listTables(database: "b3c_does_not_exist", schema: nil)
        XCTAssertTrue(empty.isEmpty)
    }

    func testListColumnsOrdinalOrderTypesAndPrimaryKeyFlags() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersRef = TableRef(database: "b3c_test", schema: nil, name: "orders")
        let columns = try await driver.listColumns(ordersRef)

        XCTAssertEqual(columns.map(\.name), ["id", "user_id", "amount", "note"])
        XCTAssertEqual(
            columns.map(\.dataType),
            ["int", "int", "decimal(12,2)", "varchar(255)"],
            "dataType must be the full COLUMN_TYPE form"
        )
        XCTAssertEqual(columns.map(\.isPrimaryKey), [true, true, false, false])
        XCTAssertEqual(columns.map(\.isNullable), [false, false, true, true])

        // Defaults stay raw: COLUMN_DEFAULT carries the literal text.
        XCTAssertEqual(columns[3].defaultValue, "none")
        XCTAssertNil(columns[0].defaultValue)
        XCTAssertNil(columns[2].defaultValue)

        // Schema-nil resolution falls back to the ref's own database; an
        // explicit-schema call must agree exactly.
        let explicit = try await driver.listColumns(
            TableRef(database: "unused", schema: "b3c_test", name: "orders")
        )
        XCTAssertEqual(explicit, columns)

        // A truly missing relation must throw instead of returning [].
        do {
            _ = try await driver.listColumns(
                TableRef(database: "nativql_test", schema: nil, name: "orders")
            )
            XCTFail("nativql_test.orders does not exist; lookup must throw")
        } catch is DriverError {}
    }

    func testPrimaryKeyOrderAndAbsence() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersPK = try await driver.primaryKey(of: TableRef(database: "b3c_test", name: "orders"))
        XCTAssertEqual(ordersPK, ["id", "user_id"], "composite PK order must match constraint declaration")

        let usersPK = try await driver.primaryKey(of: TableRef(database: "b3c_test", name: "users"))
        XCTAssertEqual(usersPK, ["id"])

        let noPK = try await driver.primaryKey(of: TableRef(database: "b3c_test", name: "no_pk"))
        XCTAssertNil(noPK, "PK-less table must return nil")

        let viewPK = try await driver.primaryKey(of: TableRef(database: "b3c_test", name: "user_emails"))
        XCTAssertNil(viewPK, "views have no primary key")
    }

    func testTableDDLReturnsVerbatimShowCreateTable() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        try await self.makeIntrospectionFixture(driver)
        defer { Task { await self.dropIntrospectionFixture(driver) } }

        let ordersDDL = try await driver.tableDDL(TableRef(database: "b3c_test", name: "orders"))
        // Server output verbatim: unqualified name header, engine suffix.
        XCTAssertTrue(ordersDDL.hasPrefix("CREATE TABLE `orders` ("), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("`amount` decimal(12,2) DEFAULT NULL"), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("PRIMARY KEY (`id`,`user_id`)"), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("ENGINE=InnoDB"), ordersDDL)
        XCTAssertTrue(ordersDDL.contains("DEFAULT CHARSET=utf8mb4"), ordersDDL)
        XCTAssertTrue(ordersDDL.hasSuffix("utf8mb4_0900_ai_ci"), ordersDDL)

        let usersDDL = try await driver.tableDDL(TableRef(database: "b3c_test", name: "users"))
        XCTAssertTrue(usersDDL.contains("`id` int NOT NULL AUTO_INCREMENT"), usersDDL)
        XCTAssertTrue(usersDDL.contains("PRIMARY KEY (`id`)"), usersDDL)
        XCTAssertTrue(usersDDL.contains("UNIQUE KEY"), usersDDL)

        do {
            _ = try await driver.tableDDL(TableRef(database: "b3c_test", name: "does_not_exist"))
            XCTFail("DDL of a missing table must throw")
        } catch let error as DriverError {
            guard case .queryFailed(let message) = error else {
                return XCTFail("expected queryFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("doesn't exist"),
                          "server message expected: \(message)")
        }
    }
}

// MARK: - Quoted identifier translation (Batch 6 review C1)
extension IntegrationTests {
    /// The app's inline-editing pipeline builds statements with the Kit
    /// builders, which emit PostgreSQL-canonical `"ident"` spans. MySQL's
    /// default sql_mode lexes those as string literals → ER_PARSE_ERROR
    /// (1064). `executeMutation` must translate to backticks before binding,
    /// and the row must ACTUALLY change with a truthful affected count.
    func testExecuteMutationTranslatesKitQuotedIdentifiers() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP DATABASE IF EXISTS b3d_qi;
            CREATE DATABASE b3d_qi;
            CREATE TABLE b3d_qi.users(id INT PRIMARY KEY, email VARCHAR(255));
            INSERT INTO b3d_qi.users VALUES (1, 'before@x.dev');
            """
        )
        defer { Task { _ = try? await driver.execute("DROP DATABASE IF EXISTS b3d_qi") } }

        // App-shaped ref: MySQL introspection carries the database as schema.
        let ref = TableRef(database: "b3d_qi", schema: "b3d_qi", name: "users")
        let statement = try XCTUnwrap(UpdateStatementBuilder.build(
            table: ref,
            pkColumns: [ColumnInfo(name: "id", dataType: "int", isPrimaryKey: true)],
            changes: [(columnName: "email", newValue: SQLValue.string("after@x.dev"))],
            pkValues: ["id": .int(1)]
        ))
        XCTAssertTrue(statement.sql.contains("\"users\""),
                      "Kit emits double quotes verbatim: \(statement.sql)")

        let affected = try await driver.executeMutation(statement)
        XCTAssertEqual(affected, 1)

        let check = try await driver.execute("SELECT email FROM b3d_qi.users WHERE id = 1")
        XCTAssertEqual(check.rows, [[.string("after@x.dev")]],
                       "the translated statement must have committed")
    }
}

// MARK: - Browse, explain, admin, mutations, cancel (Batch 3 Task D)
extension IntegrationTests {
    /// 25 seeded rows (id 1…25) with an index-free sort column; ANALYZE makes
    /// TABLE_ROWS a usable total estimate.
    private func makeBrowseFixture(_ driver: MySQLDriver) async throws {
        _ = try await driver.execute(
            """
            DROP DATABASE IF EXISTS b3d_test;
            CREATE DATABASE b3d_test;
            CREATE TABLE b3d_test.nums(id INT PRIMARY KEY, val VARCHAR(20));
            """
        )
        var insertValues: [String] = []
        for n in 1...25 {
            insertValues.append("(\(n), 'row-\(String(format: "%02d", n))')")
        }
        _ = try await driver.execute(
            "INSERT INTO b3d_test.nums VALUES " + insertValues.joined(separator: ", ")
        )
        _ = try await driver.execute("ANALYZE TABLE b3d_test.nums")
    }

    private func dropBrowseFixture(_ driver: MySQLDriver) async {
        _ = try? await driver.execute("DROP DATABASE IF EXISTS b3d_test")
    }

    private var numsRef: TableRef {
        TableRef(database: "b3d_test", name: "nums")
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
        XCTAssertEqual(asc.rows[1][1], .string("row-02"))
        XCTAssertNotNil(asc.totalCountEstimate, "TABLE_ROWS estimate must be populated after ANALYZE")
        XCTAssertGreaterThanOrEqual(asc.totalCountEstimate ?? 0, 20,
                                    "InnoDB estimate may drift slightly below the exact count")

        // Descending tail window: ids 5…1.
        let descTail = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id", ascending: false), limit: 5, offset: 20)
        XCTAssertEqual(descTail.rows.map { $0[0] }, stride(from: 5, through: 1, by: -1).map(SQLValue.int))

        // Middle window of the descending order (25…1): offset 8 starts at id 17.
        let midDesc = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id", ascending: false), limit: 5, offset: 8)
        XCTAssertEqual(midDesc.rows.map { $0[0] }, stride(from: 17, through: 13, by: -1).map(SQLValue.int))

        // Offset past the end → empty grid. Known MySQLNIO 1.x limitation:
        // no rows flow back means no column definitions either (documented).
        let beyond = try await driver.browseRows(self.numsRef, sort: SortSpec(columnName: "id"), limit: 10, offset: 30)
        XCTAssertTrue(beyond.rows.isEmpty)

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

        // WHERE id > 3 forces Filter over a range scan under the sort+limit;
        // captured live shape: Limit → Sort → Filter → Index range scan.
        let analyzed = try await driver.explain(
            "SELECT * FROM b3d_test.nums WHERE id > 3 ORDER BY val LIMIT 5",
            analyze: true
        )
        XCTAssertTrue(analyzed.operation.hasPrefix("Limit"), analyzed.operation)
        XCTAssertNotNil(analyzed.actualRows)
        XCTAssertNotNil(analyzed.actualTimeMilliseconds)
        XCTAssertNotNil(analyzed.detail?.hasPrefix("cost="), "root carries a cost group")

        XCTAssertEqual(analyzed.children.count, 1)
        let sort = analyzed.children[0]
        XCTAssertTrue(sort.operation.hasPrefix("Sort:"), sort.operation)

        XCTAssertEqual(sort.children.count, 1)
        let filter = sort.children[0]
        XCTAssertTrue(filter.operation.hasPrefix("Filter:"), filter.operation)
        XCTAssertEqual(filter.actualRows, 22, "22 rows survive id > 3")

        XCTAssertEqual(filter.children.count, 1)
        let scan = filter.children[0]
        XCTAssertTrue(scan.operation.contains("Index range scan"), scan.operation)
        XCTAssertTrue(scan.operation.contains("using PRIMARY"), scan.operation)
        XCTAssertNotNil(scan.actualRows)
        XCTAssertGreaterThan(scan.actualRows ?? -1, 0)
        XCTAssertNotNil(scan.actualTimeMilliseconds)
        XCTAssertTrue(scan.children.isEmpty)

        // Without ANALYZE there are no actuals, but FORMAT=TREE keeps shape.
        let plain = try await driver.explain(
            "SELECT * FROM b3d_test.nums WHERE id > 3 ORDER BY val LIMIT 5",
            analyze: false
        )
        XCTAssertNil(plain.actualRows)
        XCTAssertNil(plain.actualTimeMilliseconds)
        XCTAssertTrue(plain.operation.hasPrefix("Limit"), plain.operation)
        XCTAssertEqual(plain.children.count, 1)
        XCTAssertNotNil(plain.children[0].detail?.hasPrefix("cost="), "cost groups survive without ANALYZE")

        // Server-side failures surface as queryFailed.
        do {
            _ = try await driver.explain("SELECT * FROM b3d_test.does_not_exist", analyze: false)
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

        let name = "b3d_admin_" + UUID().uuidString.prefix(8).lowercased()
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
            XCTAssertTrue(message.lowercased().contains("exist"), message)
        }
    }

    func testExecuteMutationSumsAffectedRowsAndPersists() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP DATABASE IF EXISTS b3d_mut;
            CREATE DATABASE b3d_mut;
            CREATE TABLE b3d_mut.t_upd(id INT PRIMARY KEY, score INT);
            INSERT INTO b3d_mut.t_upd VALUES (1, 0), (2, 0), (3, 0);
            """
        )
        defer { Task { _ = try? await driver.execute("DROP DATABASE IF EXISTS b3d_mut") } }

        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "b3d_mut", name: "t_upd"),
            sql: "UPDATE b3d_mut.t_upd SET score = ? WHERE id = ?",
            batches: [
                [.int(100), .int(1)],
                [.int(200), .int(2)],
                [.int(300), .int(3)],
            ]
        )

        let total = try await driver.executeMutation(statement)
        XCTAssertEqual(total, 3, "one affected row per batch must accumulate")

        let check = try await driver.execute("SELECT id, score FROM b3d_mut.t_upd ORDER BY id")
        XCTAssertEqual(check.rows, [[.int(1), .int(100)], [.int(2), .int(200)], [.int(3), .int(300)]],
                       "all batches must have committed")
    }

    func testExecuteMutationRollsBackEverythingOnConstraintViolation() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())
        _ = try await driver.execute(
            """
            DROP DATABASE IF EXISTS b3d_mut;
            CREATE DATABASE b3d_mut;
            CREATE TABLE b3d_mut.t_rb(id INT PRIMARY KEY, v INT);
            INSERT INTO b3d_mut.t_rb VALUES (1, 0), (2, 0);
            """
        )
        defer { Task { _ = try? await driver.execute("DROP DATABASE IF EXISTS b3d_mut") } }

        // Batch 1 succeeds; batch 2 collides on the primary key → the whole
        // transaction (including batch 1's change) must roll back.
        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "b3d_mut", name: "t_rb"),
            sql: "UPDATE b3d_mut.t_rb SET id = ? WHERE id = ?",
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

        let after = try await driver.execute("SELECT id, v FROM b3d_mut.t_rb ORDER BY id")
        XCTAssertEqual(after.rows, [[.int(1), .int(0)], [.int(2), .int(0)]],
                       "zero changes may persist after the failed transaction")
    }

    func testExecuteMutationRejectsBatchBindCountMismatch() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        let statement = MutationStatement(
            kind: .update,
            table: TableRef(database: "nativql_test", name: "whatever"),
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

    func testCancelRunningQueryAbortsSleepPromptly() async throws {
        let driver = try makeLiveDriver()
        defer { Task { await driver.disconnect() } }

        try await driver.connect(makeConfig())

        // Row-streaming probe: a cartesian COUNT over information_schema runs
        // for many seconds and surfaces ER 1317 when killed mid-stream.
        // NOTE: function-only probes like `SELECT SLEEP(10)` are unsuitable —
        // on MySQL 8.4 they consume the kill flag inside the function and
        // return a normal result early (documented in cancelRunningQuery).
        let clock = ContinuousClock()
        let execTask = Task {
            try await driver.execute(
                "SELECT COUNT(*) FROM information_schema.columns x, information_schema.columns y"
            )
        }
        try await Task.sleep(for: .milliseconds(200))

        let cancelStart = clock.now
        await driver.cancelRunningQuery()

        do {
            _ = try await execTask.value
            XCTFail("the cancelled query must not complete successfully")
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

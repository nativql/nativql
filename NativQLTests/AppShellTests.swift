import XCTest
import NativQLKit
import MySQLDriver
import PostgresDriver
@testable import NativQL

final class AppShellTests: XCTestCase {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativql-appshell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func configFile(in directory: URL) -> URL {
        directory.appendingPathComponent("connections.json")
    }

    private func makeConfig(
        name: String = "local",
        password: String? = "secret",
        colorLabel: String? = "blue"
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: name,
            kind: .postgres,
            host: "127.0.0.1",
            port: 55432,
            user: "nativql",
            password: password,
            database: "nativql_test",
            sslMode: .disable,
            colorLabel: colorLabel
        )
    }

    // MARK: - ConnectionStore round-trips

    func testSaveThenLoadRoundTripsSpecialCharsUnicodePasswordAndColor() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        let trickyPassword = "p@$$\"w\\rd \u{1F512} ünïcode ✓"
        let config = makeConfig(
            name: "prod 🗄️ \"quoted\"",
            password: trickyPassword,
            colorLabel: "purple"
        )

        try store.save([config])

        let reloaded = ConnectionStore(directory: dir).load()
        XCTAssertEqual(reloaded, [config])
        XCTAssertEqual(reloaded.first?.password, trickyPassword)
        XCTAssertEqual(reloaded.first?.colorLabel, "purple")
    }

    func testRoundTripPreservesMultipleConnectionsInOrder() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        let pg = makeConfig(name: "pg")
        var mysql = makeConfig(name: "mysql")
        mysql.kind = .mysql
        mysql.port = 3306

        try store.save([pg, mysql])

        XCTAssertEqual(ConnectionStore(directory: dir).load(), [pg, mysql])
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let dir = try makeTempDirectory()

        XCTAssertTrue(ConnectionStore(directory: dir).load().isEmpty)
    }

    func testLoadReturnsEmptyWhenFileCorrupt() throws {
        let dir = try makeTempDirectory()
        try Data("{{{ not json".utf8).write(to: configFile(in: dir))

        XCTAssertTrue(ConnectionStore(directory: dir).load().isEmpty)
    }

    func testInitLoadsExistingFileSoCrudDoesNotWipeIt() throws {
        let dir = try makeTempDirectory()
        let seeded = makeConfig(name: "seeded")
        try ConnectionStore(directory: dir).save([seeded])

        let store = ConnectionStore(directory: dir)

        XCTAssertEqual(store.connections, [seeded])
    }

    func testSavedFileHasOwnerOnlyPermissions() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)

        try store.save([makeConfig()])

        let attributes = try FileManager.default.attributesOfItem(atPath: configFile(in: dir).path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    // MARK: - CRUD helpers

    func testAddAppendsAndPersists() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        let first = makeConfig(name: "first")
        let second = makeConfig(name: "second")

        store.add(first)
        store.add(second)

        XCTAssertEqual(store.connections, [first, second])
        XCTAssertEqual(ConnectionStore(directory: dir).load(), [first, second])
    }

    func testUpdateReplacesMatchingIdAndPersists() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        let original = makeConfig(name: "before")
        store.add(original)

        var renamed = original
        renamed.name = "after"
        renamed.password = "new-pass"
        let updated = store.update(renamed)

        XCTAssertTrue(updated)
        XCTAssertEqual(store.connections, [renamed])
        XCTAssertEqual(ConnectionStore(directory: dir).load(), [renamed])
    }

    func testUpdateUnknownIdReturnsFalseWithoutChanges() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        store.add(makeConfig(name: "kept"))

        XCTAssertFalse(store.update(makeConfig(name: "stranger")))

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections.first?.name, "kept")
    }

    func testRemoveDeletesByIdAndPersists() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)
        let keep = makeConfig(name: "keep")
        let drop = makeConfig(name: "drop")
        store.add(keep)
        store.add(drop)

        let removed = store.remove(id: drop.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(store.connections, [keep])
        XCTAssertEqual(ConnectionStore(directory: dir).load(), [keep])
    }

    func testRemoveUnknownIdReturnsFalse() throws {
        let dir = try makeTempDirectory()
        let store = ConnectionStore(directory: dir)

        XCTAssertFalse(store.remove(id: UUID()))
    }

    // MARK: - DatabaseConnectionManager (no server required)

    @MainActor
    func testTestUnreachablePostgresThrowsConnectionFailedQuicklyWithoutStoring() async throws {
        let manager = DatabaseConnectionManager()
        var config = makeConfig(name: "refused")
        config.port = 1
        let start = Date()

        do {
            try await manager.test(config)
            XCTFail("expected DriverError.connectionFailed")
        } catch DriverError.connectionFailed {
            // expected
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "connection refused must fail fast")
        XCTAssertNil(manager.driver(for: config.id), "test() must never store its throwaway driver")
    }

    @MainActor
    func testTestUnreachableMySQLThrowsConnectionFailedQuicklyWithoutStoring() async throws {
        let manager = DatabaseConnectionManager()
        var config = makeConfig(name: "refused")
        config.kind = .mysql
        config.port = 1
        let start = Date()

        do {
            try await manager.test(config)
            XCTFail("expected DriverError.connectionFailed")
        } catch DriverError.connectionFailed {
            // expected
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "connection refused must fail fast")
        XCTAssertNil(manager.driver(for: config.id), "test() must never store its throwaway driver")
    }

    @MainActor
    func testConnectFailureLeavesNoStoredDriverOrConnectedState() async throws {
        let manager = DatabaseConnectionManager()
        var config = makeConfig(name: "refused")
        config.port = 1

        do {
            try await manager.connect(config)
            XCTFail("expected connect to throw")
        } catch DriverError.connectionFailed {
            // expected
        }

        XCTAssertNil(manager.driver(for: config.id))
        let connected = await manager.isConnected(config.id)
        XCTAssertFalse(connected)
    }

    // MARK: - DatabaseConnectionManager (live servers, NATIVQL_INTEGRATION=1)

    private func requireLiveServer() throws {
        guard ProcessInfo.processInfo.environment["NATIVQL_INTEGRATION"] == "1" else {
            throw XCTSkip("set NATIVQL_INTEGRATION=1 to run live-server integration tests")
        }
    }

    private func makeLiveConfig(kind: DatabaseKind, name: String) -> ConnectionConfig {
        var config = ConnectionConfig(
            name: name,
            kind: kind,
            host: "127.0.0.1",
            port: kind == .postgres ? 55432 : 53306,
            user: "nativql",
            password: "nativql",
            database: "nativql_test",
            sslMode: .disable
        )
        return config
    }

    @MainActor
    func testConnectLivePostgresThenMySQLExposesRightDriversAndDisconnectClears() async throws {
        try requireLiveServer()
        let manager = DatabaseConnectionManager()
        let pg = makeLiveConfig(kind: .postgres, name: "live-pg")
        let my = makeLiveConfig(kind: .mysql, name: "live-mysql")

        defer { Task { await manager.disconnectAll() } }

        try await manager.connect(pg)
        let pgConnected = await manager.isConnected(pg.id)
        XCTAssertTrue(pgConnected)
        let pgDriver = manager.driver(for: pg.id)
        XCTAssertEqual(pgDriver?.kind, .postgres)
        XCTAssertTrue(pgDriver is PostgresDriver)

        try await manager.connect(my)
        let myConnected = await manager.isConnected(my.id)
        XCTAssertTrue(myConnected)
        let myDriver = manager.driver(for: my.id)
        XCTAssertEqual(myDriver?.kind, .mysql)
        XCTAssertTrue(myDriver is MySQLDriver)

        await manager.disconnect(pg.id)
        let pgAfterDisconnect = await manager.isConnected(pg.id)
        XCTAssertFalse(pgAfterDisconnect)
        XCTAssertNil(manager.driver(for: pg.id))
        let myStillConnected = await manager.isConnected(my.id)
        XCTAssertTrue(myStillConnected, "disconnecting one id must not touch others")

        await manager.disconnectAll()
        let myAfterDisconnectAll = await manager.isConnected(my.id)
        XCTAssertFalse(myAfterDisconnectAll)
        XCTAssertNil(manager.driver(for: my.id))
    }

    @MainActor
    func testReconnectingLiveIdTearsDownPreviousDriverFirst() async throws {
        try requireLiveServer()
        let manager = DatabaseConnectionManager()
        let pg = makeLiveConfig(kind: .postgres, name: "live-pg-reconnect")

        defer { Task { await manager.disconnectAll() } }

        try await manager.connect(pg)
        let firstDriver = manager.driver(for: pg.id)
        XCTAssertNotNil(firstDriver)

        try await manager.connect(pg)
        let secondDriver = manager.driver(for: pg.id)
        XCTAssertTrue(secondDriver != nil && secondDriver !== firstDriver, "reconnect must replace the old driver instance")
        let stillConnected = await manager.isConnected(pg.id)
        XCTAssertTrue(stillConnected)
    }

    @MainActor
    func testTestWithValidLiveConfigSucceedsWithoutStoring() async throws {
        try requireLiveServer()
        let manager = DatabaseConnectionManager()
        let pg = makeLiveConfig(kind: .postgres, name: "live-pg-test-only")
        let my = makeLiveConfig(kind: .mysql, name: "live-mysql-test-only")

        try await manager.test(pg)
        try await manager.test(my)

        XCTAssertNil(manager.driver(for: pg.id), "test() must not leave a stored driver")
        XCTAssertNil(manager.driver(for: my.id), "test() must not leave a stored driver")
    }
}

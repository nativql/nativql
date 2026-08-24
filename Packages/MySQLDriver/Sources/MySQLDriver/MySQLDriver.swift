import Foundation
import Logging
import NativQLKit
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO

/// A resolved connection target: everything `MySQLConnection.connect(to:)`
/// needs, derived once from the Kit's `ConnectionConfig`. Kept around after a
/// successful connect so later tasks (e.g. `cancelRunningQuery`) can open a
/// short-lived control connection with identical settings.
///
/// MySQLNIO 1.x has no `Configuration` aggregate (unlike PostgresNIO) — its
/// `connect` takes individual parameters plus a raw NIOSSL `TLSConfiguration?`,
/// so this struct fills that role for the driver.
struct MySQLEndpoint: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var database: String?
    /// `nil` means plaintext-only (`sslMode = .disable`); non-nil requests the
    /// TLS upgrade during the handshake.
    var tlsConfiguration: TLSConfiguration?
    /// SNI / certificate-validation name passed as `serverHostname` when TLS
    /// is enabled.
    var serverName: String?

    static func make(from config: ConnectionConfig) -> Self {
        let tls = TLSConfiguration.makeMySQLClient(for: config.sslMode)
        // SNI and hostname verification only matter once TLS is requested.
        let serverName = tls == nil ? nil : config.host
        return MySQLEndpoint(
            host: config.host,
            port: config.port,
            username: config.user,
            password: config.password,
            database: config.database,
            tlsConfiguration: tls,
            serverName: serverName
        )
    }

    var socketAddress: SocketAddress {
        get throws {
            try SocketAddress.makeAddressResolvingHost(self.host, port: self.port)
        }
    }
}

/// MySQL `DatabaseDriver` backed by one long-lived `MySQLConnection`
/// per driver instance (the app holds one instance per connected tab).
///
/// Concurrency: this class is `@unchecked Sendable` because it owns mutable
/// NIO lifecycle state (`MySQLConnection`, the event loop group, the cached
/// session id). All state mutations happen inside the async `connect` /
/// `disconnect` methods, which the app serializes per tab — mirroring the
/// protocol contract ("safe to hold long-term per connected tab"). The wrapped
/// `MySQLConnection` is itself `Sendable`.
///
/// Resource ownership: `connect` creates a private two-thread event loop group;
/// `disconnect` closes the connection and shuts that group down. `deinit`
/// cannot await, so it performs **no** cleanup — callers MUST call
/// `disconnect()` before dropping the driver or the group's threads leak until
/// process exit.
public final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    public var kind: DatabaseKind { .mysql }

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var connection: MySQLConnection?
    /// Server session id captured at connect time via `SELECT CONNECTION_ID()`.
    private var sessionID: UInt64?
    /// Resolved target of the last successful `connect`, reused by later tasks
    /// that need an identical control connection.
    private var cachedEndpoint: MySQLEndpoint?

    /// Internal so same-module extensions reuse the session-scoped logger.
    let logger = Logger(label: "nativql.mysql-driver")

    /// Live connection for same-module extensions; `nil` while disconnected.
    var activeConnection: MySQLConnection? { self.connection }

    /// Session id + endpoint for same-module extensions; `nil` while disconnected.
    var activeSessionID: UInt64? { self.sessionID }
    var activeEndpoint: MySQLEndpoint? { self.cachedEndpoint }

    public init() {}

    // MARK: - Lifecycle

    public func connect(_ config: ConnectionConfig) async throws {
        // Reconnecting on a live driver tears the previous session down first,
        // so connect/disconnect pairs always stay balanced.
        await disconnect()

        let endpoint = MySQLEndpoint.make(from: config)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        do {
            let address = try endpoint.socketAddress
            let connection = try await MySQLConnection.connect(
                to: address,
                username: endpoint.username,
                database: endpoint.database ?? "",
                password: endpoint.password,
                tlsConfiguration: endpoint.tlsConfiguration,
                serverHostname: endpoint.serverName,
                logger: self.logger,
                on: group.next()
            ).get()

            let id = try await Self.captureSessionID(on: connection)

            self.eventLoopGroup = group
            self.connection = connection
            self.sessionID = id
            self.cachedEndpoint = endpoint
        } catch {
            // No session survived: release the freshly created group before
            // surfacing the failure so failed connects leak nothing.
            try? await group.shutdownGracefully()
            throw Self.classify(error)
        }
    }

    public func disconnect() async {
        if let connection = self.connection {
            self.connection = nil
            self.sessionID = nil
            self.cachedEndpoint = nil
            try? await connection.close().get()
        }
        if let group = self.eventLoopGroup {
            self.eventLoopGroup = nil
            try? await group.shutdownGracefully()
        }
    }

    public func isConnected() async -> Bool {
        guard let connection = self.connection else { return false }
        return !connection.isClosed
    }

    /// The server session id captured at connect time via
    /// `SELECT CONNECTION_ID()`; `nil` while disconnected. This is the value
    /// `KILL QUERY <id>` targets (later task).
    public func sessionID() async -> UInt64? {
        self.sessionID
    }

    // MARK: - Configuration & helpers

    /// Captures this session's `CONNECTION_ID()` right after authentication
    /// succeeds, over the text protocol (`simpleQuery`) so no statement
    /// preparation is involved.
    ///
    /// A failure here means the handshake completed but the session is unusable;
    /// the caller closes the half-open connection and surfaces `.queryFailed`.
    static func captureSessionID(on connection: MySQLConnection) async throws -> UInt64 {
        let rows = try await connection.simpleQuery("SELECT CONNECTION_ID() AS id").get()
        guard let row = rows.first,
              let raw = row.column("id")?.string,
              let id = UInt64(raw.trimmingCharacters(in: .whitespaces)) else {
            throw DriverError.queryFailed("CONNECTION_ID() returned no usable value")
        }
        return id
    }

    /// Classifies a thrown error into the Kit's `DriverError` taxonomy.
    ///
    /// - Structured wins over sniffed: a server `ERR_Packet` carries a typed
    ///   error code, so access denied (1045) is detected without string
    ///   matching. Any other server code at connect time (unknown database,
    ///   unsupported auth plugin data, …) lands on `.connectionFailed`.
    /// - Authentication also wins over TLS in the text path, since servers
    ///   report credential rejections over established TLS sessions.
    /// - `MySQLError.secureConnectionRequired` maps to `.tlsFailed`: the
    ///   remedy is connecting over TLS (caching_sha2_password full
    ///   authentication refuses plaintext transport).
    /// - Task cancellation maps to `.cancelled` rather than a connection error.
    static func classify(_ error: Error) -> DriverError {
        if error is CancellationError {
            return .cancelled
        }

        if case MySQLError.server(let packet) = error {
            if packet.errorCode == .ACCESS_DENIED_ERROR {
                return .authenticationFailed(packet.errorMessage)
            }
            return .connectionFailed(packet.errorMessage)
        }

        let message = String(reflecting: error)
        let text = message.lowercased()

        if case MySQLError.secureConnectionRequired = error {
            return .tlsFailed(message)
        }
        if text.contains("access denied")
            || text.contains("password")
            || text.contains("authentication")
            || text.contains("auth plugin")
            || text.contains("credential") {
            return .authenticationFailed(message)
        }
        if text.contains("ssl")
            || text.contains("tls")
            || text.contains("certificate") {
            return .tlsFailed(message)
        }
        return .connectionFailed(message)
    }

    // MARK: - Queries (Task B)

    /// Executes one or more statements sequentially (client-side split via
    /// Kit's splitter — MySQLNIO has no multi-statement support).
    ///
    /// Semantics match PostgresDriver: the result surfaces the LAST statement
    /// that produced rows; affected rows from INSERT/UPDATE/DELETE accumulate.
    ///
    /// Known limitation (MySQLNIO 1.x): column definitions are only exposed
    /// when at least one row flows back, so a zero-row SELECT returns no
    /// headers. Verified against the pinned API — derived-table probes still
    /// yield empty definition lists — so this is unfixable without replacing
    /// the command layer. PostgresDriver keeps full header behavior.
    public func execute(_ sql: String) async throws -> QueryResult {
        let statements = SQLStatementSplitter.split(sql)
        guard !statements.isEmpty else {
            return QueryResult(
                columns: [], rows: [],
                executionMilliseconds: 0,
                statementType: .other
            )
        }
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("not connected")
        }

        let clock = ContinuousClock()
        let start = clock.now

        var lastRowProducing: (columns: [ColumnInfo], rows: [[SQLValue]])?
        var affectedRows: Int64 = 0

        do {
            for statement in statements {
                try Task.checkCancellation()
                let outcome = try await Self.runStatement(connection, sql: statement, logger: self.logger)
                affectedRows += outcome.affectedRowsDelta
                if let columns = outcome.columnDefinitions {
                    let mapped = outcome.rows.map { Self.cells(of: $0) }
                    let columnInfos = columns.map {
                        ColumnInfo(name: $0.name, dataType: SQLValueMapper.typeName($0.columnType))
                    }
                    lastRowProducing = (columnInfos, mapped)
                }
            }
        } catch {
            throw Self.mapExecutionError(error)
        }

        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let finalType = QueryTypeDetector.type(of: statements.last ?? "")

        return QueryResult(
            columns: lastRowProducing?.columns ?? [],
            rows: lastRowProducing?.rows ?? [],
            affectedRows: affectedRows > 0 ? affectedRows : nil,
            executionMilliseconds: milliseconds,
            statementType: finalType
        )
    }

    // MARK: Execution internals

    struct StatementOutcome {
        /// Wire column definitions; nil when the statement cannot produce rows.
        var columnDefinitions: [MySQLProtocol.ColumnDefinition41]?
        var rows: [MySQLRow]
        var affectedRowsDelta: Int64
    }

    private static func runStatement(
        _ connection: MySQLConnection,
        sql: String,
        logger: Logger
    ) async throws -> StatementOutcome {
        var collected: [MySQLRow] = []
        var delta: Int64 = 0
        let future = connection.query(sql, [], onRow: { row in
            collected.append(row)
        }, onMetadata: { metadata in
            delta = Int64(metadata.affectedRows)
        })
        _ = try await future.get()
        logger.trace("statement finished", metadata: ["affected": "\(delta)"])
        return StatementOutcome(
            columnDefinitions: collected.first?.columnDefinitions,
            rows: collected,
            affectedRowsDelta: delta
        )
    }

    /// Zips a row's definitions with its value buffers into Kit values.
    static func cells(of row: MySQLRow) -> [SQLValue] {
        row.columnDefinitions.indices.map { index in
            let definition = row.columnDefinitions[index]
            let data = MySQLData(
                type: definition.columnType,
                format: row.format,
                buffer: row.values[index],
                isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
            )
            return SQLValueMapper.map(
                data,
                isBinaryCharset: definition.characterSet == .binary
            )
        }
    }

    /// Maps execution-phase errors into the Kit taxonomy. Structured cases
    /// win over text sniffing:
    /// - `MySQLError.invalidSyntax` (1064 arrives outside the `.server` case)
    ///   → `.queryFailed` with the server's message
    /// - server 1317 `ER_QUERY_INTERRUPTED` → `.cancelled` (KILL QUERY)
    /// - `CancellationError` (Swift task cancellation) → `.cancelled`
    static func mapExecutionError(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError {
            return driverError
        }
        if error is CancellationError {
            return .cancelled
        }
        if case MySQLError.invalidSyntax(let message) = error {
            return .queryFailed(message)
        }
        if case MySQLError.server(let packet) = error {
            if packet.errorCode == .QUERY_INTERRUPTED {
                return .cancelled
            }
            return .queryFailed(packet.errorMessage)
        }
        return .queryFailed(String(reflecting: error))
    }

    /// Best-effort by contract: opens a short-lived control connection from
    /// the cached endpoint, asks the server to interrupt this session's
    /// running statement, and closes again. `KILL QUERY` (unlike
    /// `KILL CONNECTION`) aborts only the in-flight statement, so the session
    /// stays usable afterwards. Any failure is swallowed so the primary
    /// connection's state is never touched; no-op while disconnected.
    ///
    /// Interpolation safety: `sessionID` is a server-generated UInt64
    /// (`CONNECTION_ID()`), which Swift renders as bare decimal digits — the
    /// command text cannot be broken out of or injected into.
    ///
    /// Server quirk (observed on 8.4.4, cf. bug #45679): statements whose
    /// entire work happens inside a function (`SELECT SLEEP(n)`,
    /// `SELECT BENCHMARK(…)`) can return a normal result early instead of
    /// surfacing ER 1317, because the kill flag is consumed inside the
    /// function rather than by the executor between streamed rows. Row-
    /// producing statements surface ER 1317, which ``mapExecutionError``
    /// maps to `.cancelled`.
    public func cancelRunningQuery() async {
        guard let endpoint = self.activeEndpoint,
              let sessionID = self.activeSessionID,
              let eventLoopGroup = self.eventLoopGroup else {
            return
        }

        do {
            let address = try endpoint.socketAddress
            let control = try await MySQLConnection.connect(
                to: address,
                username: endpoint.username,
                database: endpoint.database ?? "",
                password: endpoint.password,
                tlsConfiguration: endpoint.tlsConfiguration,
                serverHostname: endpoint.serverName,
                logger: self.logger,
                on: eventLoopGroup.next()
            ).get()

            do {
                _ = try await control.simpleQuery("KILL QUERY \(sessionID)").get()
            } catch {
                // A failed kill must not prevent the control teardown below.
                self.logger.debug("cancelRunningQuery: KILL failed: \(String(describing: error))")
            }
            try? await control.close().get()
        } catch {
            self.logger.debug("cancelRunningQuery: control connection failed: \(String(reflecting: error))")
        }
    }

    // MARK: - Introspection (Task C)
    //
    // listDatabases / listTables / listColumns / primaryKey / tableDDL live
    // in Introspection.swift, mirroring PostgresDriver's file layout.

    // MARK: - Browsing & plans (Task D)

    /// Reads one sorted window of rows (implementation in Introspection.swift,
    /// next to the shared TABLE_ROWS helper).
    public func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        try await self.browseRowsImpl(table, sort: sort, limit: limit, offset: offset)
    }

    /// Runs `EXPLAIN ANALYZE <sql>` (or `EXPLAIN FORMAT=TREE <sql>` without
    /// actuals) and parses the single tree cell into a plan node tree.
    ///
    /// Plain `EXPLAIN` returns the legacy tabular format rather than a tree,
    /// hence FORMAT=TREE for `analyze: false`. The statement travels over
    /// `simpleQuery` — EXPLAIN variants take no bind parameters, and the text
    /// protocol avoids any prepared-statement restrictions on EXPLAIN forms.
    /// The embedded SQL is the app editor's statement by definition of
    /// EXPLAIN (same policy as PostgresDriver).
    ///
    /// The plan column has no binary wire encoding; the server always sends
    /// it as text regardless of protocol.
    public func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        let statement = analyze ? "EXPLAIN ANALYZE \(sql)" : "EXPLAIN FORMAT=TREE \(sql)"

        do {
            let rows = try await connection.simpleQuery(statement).get()
            try Task.checkCancellation()
            guard let row = rows.first,
                  let cell = row.column("EXPLAIN")?.string, !cell.isEmpty else {
                throw DriverError.queryFailed("EXPLAIN produced no parsable output")
            }
            do {
                return try ExplainParser.parse(cell)
            } catch {
                throw DriverError.queryFailed("unparseable EXPLAIN output: \(error)")
            }
        } catch {
            throw Self.mapExecutionError(error)
        }
    }

    // MARK: - Admin (Task D)

    /// Creates a database. Identifiers go through ``IdentifierQuoting``;
    /// these statements carry no bindable values.
    public func createDatabase(named name: String) async throws {
        try await self.runAdmin("CREATE DATABASE \(IdentifierQuoting.quote(name))")
    }

    /// Drops a database. Plain `DROP DATABASE` per plan: dropping a missing
    /// database surfaces the server's error.
    public func dropDatabase(named name: String) async throws {
        try await self.runAdmin("DROP DATABASE \(IdentifierQuoting.quote(name))")
    }

    private func runAdmin(_ sql: String) async throws {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            _ = try await connection.simpleQuery(sql).get()
        } catch {
            throw Self.mapExecutionError(error)
        }
    }

    // MARK: - Mutations (Task D)

    /// Executes all batches in ONE transaction via ``MutationExecutor``
    /// (see MutationExecutor.swift); returns total affected rows.
    public func executeMutation(_ statement: MutationStatement) async throws -> Int64 {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        return try await MutationExecutor.execute(statement, on: connection, logger: self.logger)
    }
}

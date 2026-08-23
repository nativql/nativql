import Foundation
import Logging
import NativQLKit
import NIOCore
import PostgresNIO

/// PostgreSQL `DatabaseDriver` backed by one long-lived `PostgresConnection`
/// per driver instance (the app holds one instance per connected tab).
///
/// Concurrency: this class is `@unchecked Sendable` because it owns mutable
/// NIO lifecycle state (`PostgresConnection`, the event loop group, the cached
/// backend PID). All state mutations happen inside the async `connect` /
/// `disconnect` methods, which the app serializes per tab — mirroring the
/// protocol contract ("safe to hold long-term per connected tab"). The wrapped
/// `PostgresConnection` is itself `@unchecked Sendable`.
///
/// Resource ownership: `connect` creates a private two-thread event loop group;
/// `disconnect` closes the connection and shuts that group down. `deinit`
/// cannot await, so it performs **no** cleanup — callers MUST call
/// `disconnect()` before dropping the driver or the group's threads leak until
/// process exit.
public final class PostgresDriver: DatabaseDriver, @unchecked Sendable {
    public var kind: DatabaseKind { .postgres }

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var connection: PostgresConnection?
    private var connectionPID: Int32?
    /// Cached wire configuration from the last successful `connect`, reused by
    /// later tasks (e.g. `cancelRunningQuery` opens a short-lived control
    /// connection with identical settings).
    private var cachedConfiguration: PostgresConnection.Configuration?

    /// Internal so same-module extensions (`Introspection.swift`) reuse the
    /// session-scoped logger.
    let logger = Logger(label: "nativql.postgres-driver")

    /// Live connection for same-module extensions; `nil` while disconnected.
    var activeConnection: PostgresConnection? { self.connection }

    public init() {}

    // MARK: - Lifecycle

    public func connect(_ config: ConnectionConfig) async throws {
        // Reconnecting on a live driver tears the previous session down first,
        // so connect/disconnect pairs always stay balanced.
        await disconnect()

        let pgConfig = try Self.makeConfiguration(from: config)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        do {
            // The ID is log metadata only; uniqueness is best-effort.
            let connection = try await PostgresConnection.connect(
                on: group.next(),
                configuration: pgConfig,
                id: Int.random(in: 1..<Int.max),
                logger: self.logger
            )

            let pid = try await Self.captureBackendPID(on: connection, logger: self.logger)

            self.eventLoopGroup = group
            self.connection = connection
            self.connectionPID = pid
            self.cachedConfiguration = pgConfig
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
            self.connectionPID = nil
            self.cachedConfiguration = nil
            try? await connection.close()
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

    /// The server backend process id captured at connect time via
    /// `SELECT pg_backend_pid()`; `nil` while disconnected. Useful for matching
    /// entries in `pg_stat_activity`.
    public func backendPID() async -> Int32? {
        self.connectionPID
    }

    // MARK: - Configuration & helpers

    private static func makeConfiguration(
        from config: ConnectionConfig
    ) throws -> PostgresConnection.Configuration {
        let tls = try PostgresConnection.Configuration.TLS.makeTLS(for: config.sslMode)
        return PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.user,
            password: config.password,
            database: config.database,
            tls: tls
        )
    }

    /// Captures the backend PID right after authentication succeeds.
    ///
    /// A failure here means the handshake completed but the session is unusable;
    /// the caller closes the half-open connection and surfaces `.queryFailed`.
    private static func captureBackendPID(
        on connection: PostgresConnection,
        logger: Logger
    ) async throws -> Int32 {
        let sequence = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT pg_backend_pid()::int4"),
            logger: logger
        )
        let rows = try await sequence.collect()
        guard let row = rows.first else {
            throw DriverError.queryFailed("pg_backend_pid returned no rows")
        }
        return try PostgresRandomAccessRow(row)[0].decode(Int32.self)
    }

    /// Classifies a thrown error into the Kit's `DriverError` taxonomy by
    /// inspecting the error's text (covers `PSQLError` descriptions, NIOSSL and
    /// POSIX transport errors alike).
    ///
    /// Uses `String(reflecting:)` because PostgresNIO redacts
    /// `String(describing:)` for PSQLError to prevent accidental leakage of
    /// sensitive details.
    ///
    /// - Authentication wins over TLS when both keywords appear, since servers
    ///   report credential rejections over established TLS sessions.
    /// - Task cancellation maps to `.cancelled` rather than a connection error.
    static func classify(_ error: Error) -> DriverError {
        if error is CancellationError {
            return .cancelled
        }

        let message = String(reflecting: error)
        let text = message.lowercased()

        if text.contains("password")
            || text.contains("authentication")
            || text.contains("sasl")
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

    /// Executes one or more statements sequentially on the live connection.
    ///
    /// Per-statement transport (PostgresNIO 1.x reality):
    /// - INSERT/UPDATE/DELETE go through the `EventLoopFuture` query API,
    ///   the only surface exposing the command tag (`PostgresQueryMetadata`)
    ///   needed for affected-row counts. `INSERT … RETURNING` still keeps its
    ///   rows because that API collects them too.
    /// - Everything else goes through the async row-sequence API, whose
    ///   `.columns` survives zero-row results (empty grids keep headers).
    ///
    /// The result reports the LAST row-producing statement's columns+rows and
    /// the accumulated affected rows of all INSERT/UPDATE/DELETE tags.
    ///
    /// Known gap: `WITH`-led DML (`WITH … INSERT/UPDATE/DELETE`) is classified
    /// as `.other` by the type detector, routes through the row-sequence
    /// transport, and therefore misses command tags (contributes no affected
    /// rows).
    public func execute(_ sql: String) async throws -> QueryResult {
        guard let connection = self.connection else {
            throw DriverError.connectionFailed("Not connected")
        }

        let statements = SQLStatementSplitter.split(sql)
        guard !statements.isEmpty else {
            return QueryResult(
                columns: [],
                rows: [],
                executionMilliseconds: 0,
                statementType: .other
            )
        }

        let clock = ContinuousClock()
        let start = clock.now

        var totalAffectedRows: Int64?
        var lastColumns: [ColumnInfo]?
        var lastRows: [[SQLValue]] = []

        do {
            for statement in statements {
                if Task.isCancelled { throw CancellationError() }
                let outcome = try await Self.runStatement(statement, on: connection, logger: self.logger)
                if let affected = outcome.affectedRows {
                    totalAffectedRows = (totalAffectedRows ?? 0) + affected
                }
                if !(outcome.columns.isEmpty && outcome.rows.isEmpty) {
                    lastColumns = outcome.columns
                    lastRows = outcome.rows
                }
            }
        } catch {
            throw Self.mapExecutionError(error)
        }

        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15

        return QueryResult(
            columns: lastColumns ?? [],
            rows: lastRows,
            affectedRows: totalAffectedRows,
            executionMilliseconds: max(0, milliseconds),
            statementType: QueryTypeDetector.type(of: statements.last!)
        )
    }

    private struct StatementOutcome {
        var columns = [ColumnInfo]()
        var rows = [[SQLValue]]()
        var affectedRows: Int64?
    }

    /// Runs one statement on the given connection using the transport that
    /// fits its detected kind (see ``execute(_:)``).
    private static func runStatement(
        _ sql: String,
        on connection: PostgresConnection,
        logger: Logger
    ) async throws -> StatementOutcome {
        switch QueryTypeDetector.type(of: sql) {
        case .insert, .update, .delete:
            let query = PostgresQuery(unsafeSQL: sql)
            // Typed annotation pins the EventLoopFuture overload — the only
            // one surfacing the command tag.
            let result: PostgresQueryResult = try await connection.query(query, logger: logger).get()

            var outcome = StatementOutcome()
            if ["INSERT", "UPDATE", "DELETE"].contains(result.metadata.command),
               let rowCount = result.metadata.rows {
                outcome.affectedRows = Int64(rowCount)
            }
            outcome.rows = try result.rows.map { row in try row.map { try SQLValueMapper.map($0) } }
            // Column metadata only exists here when RETURNING produced cells;
            // empty DML legitimately has none.
            if let firstRow = result.rows.first {
                outcome.columns = firstRow.map { cell in
                    ColumnInfo(name: cell.columnName, dataType: SQLValueMapper.typeName(for: cell.dataType))
                }
            }
            return outcome

        default:
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            var outcome = StatementOutcome()
            outcome.columns = sequence.columns.map { column in
                ColumnInfo(name: column.name, dataType: SQLValueMapper.typeName(for: column.dataType))
            }
            var rows = [[SQLValue]]()
            for try await row in sequence {
                rows.append(try row.map { try SQLValueMapper.map($0) })
            }
            outcome.rows = rows
            return outcome
        }
    }

    /// Maps execution failures into the Kit taxonomy. Structured `PSQLError`
    /// codes win over text sniffing; server-provided message/detail/hint are
    /// surfaced verbatim so users see PostgreSQL's own diagnostics.
    ///
    /// Cancellation covers both flavors: client-side task cancellation maps to
    /// PostgresNIO's `.queryCancelled` code, while a server-side cancel
    /// (`cancelRunningQuery` via `pg_cancel_backend`) arrives as an ordinary
    /// server error carrying SQLSTATE `57014`.
    static func mapExecutionError(_ error: Error) -> DriverError {
        if error is CancellationError {
            return .cancelled
        }
        if let psql = error as? PSQLError {
            if psql.code == .queryCancelled || Self.isSQLStateCancelled(psql) {
                return .cancelled
            }
            if psql.code == .server, let info = psql.serverInfo {
                var parts: [String] = []
                if let message = info[.message] { parts.append(message) }
                if let detail = info[.detail] { parts.append(detail) }
                if let hint = info[.hint] { parts.append(hint) }
                if !parts.isEmpty {
                    return .queryFailed(parts.joined(separator: "\n"))
                }
            }
            return .queryFailed(String(reflecting: error))
        }
        return .queryFailed(String(reflecting: error))
    }

    /// True when the PSQLError is the server's "query canceled" (SQLSTATE 57014).
    static func isSQLStateCancelled(_ psql: PSQLError) -> Bool {
        psql.serverInfo?[.sqlState] == "57014"
    }

    public func cancelRunningQuery() async {
        // Best-effort by contract: opens a short-lived control connection with
        // the cached configuration, asks the server to cancel this session's
        // running statement, and closes again. Any failure is swallowed so the
        // primary connection's state is never touched.
        guard let configuration = self.cachedConfiguration, let pid = self.connectionPID else {
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let control = try await PostgresConnection.connect(
                on: group.next(),
                configuration: configuration,
                id: Int.random(in: 1..<Int.max),
                logger: self.logger
            )
            var binds = PostgresBindings()
            binds.append(pid)
            _ = try? await control.query(
                PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend($1::int4)", binds: binds),
                logger: self.logger
            ).collect()
            try? await control.close()
        } catch {
            self.logger.debug("cancelRunningQuery: control connection failed: \(String(reflecting: error))")
        }
        try? await group.shutdownGracefully()
    }

    // MARK: - Browsing & plans (Task D)

    /// Reads one sorted window of rows (implementation in Introspection.swift,
    /// next to the shared reltuples helper).
    public func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        try await self.browseRowsImpl(table, sort: sort, limit: limit, offset: offset)
    }

    /// Runs `EXPLAIN (ANALYZE<, FORMAT JSON>) <sql>` and parses the single JSON
    /// cell into a plan tree. With `analyze: true` the statement actually
    /// executes, so "Actual Rows"/"Actual Total Time" are populated.
    ///
    /// The plan column has no binary wire encoding; the server sends it as
    /// text regardless of the requested format, and the mapper surfaces it as
    /// `.json` (`.string` fallback for exotic servers).
    public func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        let options = analyze ? "ANALYZE, FORMAT JSON" : "FORMAT JSON"
        let statement = "EXPLAIN (\(options)) \(sql)"

        do {
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: statement), logger: self.logger)
            let rows = try await sequence.collect()
            guard let row = rows.first else {
                throw DriverError.queryFailed("EXPLAIN produced no rows")
            }
            let text: String
            switch try SQLValueMapper.map(PostgresRandomAccessRow(row)[0]) {
            case .json(let json): text = json
            case .string(let string): text = string
            default:
                throw DriverError.queryFailed("EXPLAIN returned a non-text payload")
            }
            do {
                return try ExplainParser.parse(text)
            } catch {
                throw DriverError.queryFailed("unparseable EXPLAIN output: \(error)")
            }
        } catch {
            if error is CancellationError { throw DriverError.cancelled }
            if let driverError = error as? DriverError { throw driverError }
            throw Self.mapExecutionError(error)
        }
    }

    // MARK: - Admin (Task D)

    /// Creates a database. `CREATE DATABASE` cannot run inside a transaction
    /// block; PostgresNIO 1.x always uses the extended protocol whose
    /// statements auto-commit outside explicit BEGIN blocks, which the server
    /// accepts here.
    public func createDatabase(named name: String) async throws {
        try await runAdmin("CREATE DATABASE \(IdentifierQuoting.quote(name))")
    }

    /// Drops a database, force-disconnecting remaining sessions first
    /// (`WITH (FORCE)` requires PostgreSQL 13+).
    public func dropDatabase(named name: String) async throws {
        try await runAdmin("DROP DATABASE \(IdentifierQuoting.quote(name)) WITH (FORCE)")
    }

    private func runAdmin(_ sql: String) async throws {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: self.logger).collect()
        } catch {
            throw Self.mapExecutionError(error)
        }
    }

    // MARK: - Mutations (Task D)

    /// Executes all batches in ONE transaction via ``MutationExecutor``
    /// (see MutationExecutor.swift); returns total affected rows.
    public func executeMutation(_ statement: MutationStatement) async throws -> Int64 {
        guard let connection = self.connection else {
            throw DriverError.connectionFailed("Not connected")
        }
        return try await MutationExecutor.execute(statement, on: connection, logger: self.logger)
    }
}

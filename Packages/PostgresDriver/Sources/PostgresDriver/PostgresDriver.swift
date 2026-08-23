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

    private let logger = Logger(label: "nativql.postgres-driver")

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

    public func execute(_ sql: String) async throws -> QueryResult {
        throw DriverError.unsupportedFeature("execute() is implemented in Batch 2 Task B")
    }

    public func cancelRunningQuery() async {
        // Implemented in Batch 2 Task D together with the control connection.
    }

    // MARK: - Introspection (Task C)

    public func listDatabases() async throws -> [DatabaseInfo] {
        throw DriverError.unsupportedFeature("listDatabases() is implemented in Batch 2 Task C")
    }

    public func listTables(database: String, schema: String?) async throws -> [TableInfo] {
        throw DriverError.unsupportedFeature("listTables(database:schema:) is implemented in Batch 2 Task C")
    }

    public func listColumns(_ table: TableRef) async throws -> [ColumnInfo] {
        throw DriverError.unsupportedFeature("listColumns(_:) is implemented in Batch 2 Task C")
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        throw DriverError.unsupportedFeature("primaryKey(of:) is implemented in Batch 2 Task C")
    }

    public func tableDDL(_ table: TableRef) async throws -> String {
        throw DriverError.unsupportedFeature("tableDDL(_:) is implemented in Batch 2 Task C")
    }

    // MARK: - Browsing & plans (Task D)

    public func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        throw DriverError.unsupportedFeature("browseRows(...) is implemented in Batch 2 Task D")
    }

    public func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode {
        throw DriverError.unsupportedFeature("explain(_:analyze:) is implemented in Batch 2 Task D")
    }

    // MARK: - Admin (Task D)

    public func createDatabase(named name: String) async throws {
        throw DriverError.unsupportedFeature("createDatabase(named:) is implemented in Batch 2 Task D")
    }

    public func dropDatabase(named name: String) async throws {
        throw DriverError.unsupportedFeature("dropDatabase(named:) is implemented in Batch 2 Task D")
    }

    // MARK: - Mutations (Task D)

    public func executeMutation(_ statement: MutationStatement) async throws -> Int64 {
        throw DriverError.unsupportedFeature("executeMutation(_:) is implemented in Batch 2 Task D")
    }
}

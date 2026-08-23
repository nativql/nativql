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

    public func execute(_ sql: String) async throws -> QueryResult {
        throw DriverError.unsupportedFeature("query execution arrives in Batch 3 Task B")
    }

    public func cancelRunningQuery() async {
        // Implemented in Task D alongside KILL QUERY.
    }

    // MARK: - Introspection (Task C)

    public func listDatabases() async throws -> [DatabaseInfo] {
        throw DriverError.unsupportedFeature("introspection arrives in Batch 3 Task C")
    }

    public func listTables(database: String, schema: String?) async throws -> [TableInfo] {
        throw DriverError.unsupportedFeature("introspection arrives in Batch 3 Task C")
    }

    public func listColumns(_ table: TableRef) async throws -> [ColumnInfo] {
        throw DriverError.unsupportedFeature("introspection arrives in Batch 3 Task C")
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        throw DriverError.unsupportedFeature("introspection arrives in Batch 3 Task C")
    }

    public func tableDDL(_ table: TableRef) async throws -> String {
        throw DriverError.unsupportedFeature("introspection arrives in Batch 3 Task C")
    }

    // MARK: - Browsing & plans (Task D)

    public func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        throw DriverError.unsupportedFeature("row browsing arrives in Batch 3 Task D")
    }

    public func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode {
        throw DriverError.unsupportedFeature("EXPLAIN parsing arrives in Batch 3 Task D")
    }

    // MARK: - Admin (Task D)

    public func createDatabase(named name: String) async throws {
        throw DriverError.unsupportedFeature("database admin arrives in Batch 3 Task D")
    }

    public func dropDatabase(named name: String) async throws {
        throw DriverError.unsupportedFeature("database admin arrives in Batch 3 Task D")
    }

    // MARK: - Mutations (Task D)

    public func executeMutation(_ statement: MutationStatement) async throws -> Int64 {
        throw DriverError.unsupportedFeature("mutations arrive in Batch 3 Task D")
    }
}

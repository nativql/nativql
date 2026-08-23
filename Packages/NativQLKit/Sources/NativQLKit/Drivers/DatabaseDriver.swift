/// One implementation per engine (PostgresNIO / MySQLNIO).
/// All methods are async-throwing; implementers must be safe to hold long-term
/// per connected tab. Cancellation of the surrounding Swift Task must abort
/// in-flight network work where the protocol supports it.
public protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }

    // Lifecycle
    func connect(_ config: ConnectionConfig) async throws
    func disconnect() async
    func isConnected() async -> Bool

    // Queries
    /// Executes one or more statements sequentially. Multi-statement input
    /// returns the result of the LAST statement that produces rows, or an
    /// aggregate result otherwise. Must honor task cancellation.
    func execute(_ sql: String) async throws -> QueryResult
    func cancelRunningQuery() async

    // Introspection
    func listDatabases() async throws -> [DatabaseInfo]
    func listTables(database: String, schema: String?) async throws -> [TableInfo]
    func listColumns(_ table: TableRef) async throws -> [ColumnInfo]
    func primaryKey(of table: TableRef) async throws -> [String]?
    func tableDDL(_ table: TableRef) async throws -> String

    // Browsing & plans
    func browseRows(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage
    func explain(_ sql: String, analyze: Bool) async throws -> ExplainPlanNode

    // Admin
    func createDatabase(named: String) async throws
    func dropDatabase(named: String) async throws

    // Mutations — statement built above the driver, bound and executed here.
    /// Returns total affected rows across all batches, executed in ONE transaction.
    func executeMutation(_ statement: MutationStatement) async throws -> Int64
}

extension DatabaseDriver {
    /// Default implementation backing the connection form's "Test" button;
    /// drivers may override with a cheaper ping.
    public func testConnection(_ config: ConnectionConfig) async throws {
        try await connect(config)
        await disconnect()
    }
}

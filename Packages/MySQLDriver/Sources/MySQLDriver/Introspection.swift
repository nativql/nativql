import Foundation
import NativQLKit
import NIOCore
import MySQLNIO

// MARK: - Catalog introspection (Task C)
//
// Two execution paths, chosen deliberately:
// - `fetch(_:binds:transform:)` runs **prepared** statements (`connection.query`)
//   so every user-influenced value travels as a positional `?` bind — never
//   interpolated into SQL text — and row data decodes through the same binary
//   wire path as `execute`.
// - Statements that cannot take bind parameters at all (`SHOW DATABASES`,
//   `SHOW CREATE TABLE`) run over `simpleQuery`; their identifiers go through
//   ``IdentifierQuoting`` before embedding, mirroring PostgresDriver's policy
//   for reconstructed DDL.

extension MySQLDriver {
    /// Lists databases visible to this session, excluding MySQL's system
    /// schemas (`information_schema`, `mysql`, `performance_schema`, `sys`),
    /// ordered by name (`SHOW DATABASES` output order is not guaranteed).
    public func listDatabases() async throws -> [DatabaseInfo] {
        let excluded: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            let rows = try await connection.simpleQuery("SHOW DATABASES").get()
            try Task.checkCancellation()
            let names = rows
                .compactMap { $0.column("Database")?.string }
                .filter { !excluded.contains($0) }
                .sorted()
            return names.map { DatabaseInfo(name: $0) }
        } catch {
            throw Self.mapExecutionError(error)
        }
    }

    /// Lists tables and views of one database.
    ///
    /// In MySQL a "database" IS a schema, so `schema` carries the database
    /// name (matching how ``TableRef/schema`` is populated throughout the
    /// app); `nil` falls back to the `database` argument. Row counts come
    /// from `information_schema.TABLES.TABLE_ROWS` — an InnoDB estimate that
    /// can be stale and is NULL for views (surfaced as `nil`).
    public func listTables(database: String, schema: String?) async throws -> [TableInfo] {
        let target = schema ?? database

        return try await self.fetch(
            """
            SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = ?
            ORDER BY TABLE_NAME
            """,
            binds: [MySQLData(string: target)]
        ) { row in
            guard let name = row.column("TABLE_NAME")?.string else {
                throw DriverError.introspectionFailed("TABLES row missing TABLE_NAME")
            }
            let kindCode = row.column("TABLE_TYPE")?.string
            // Views carry a NULL TABLE_ROWS estimate.
            let estimate = row.column("TABLE_ROWS")?.uint64.map { Int64(clamping: $0) }
            return TableInfo(
                ref: TableRef(database: database, schema: target, name: name),
                kind: kindCode == "BASE TABLE" ? .table : .view,
                estimatedRowCount: estimate
            )
        }
    }

    /// Lists a table's columns in ordinal order with verbatim
    /// `information_schema.COLUMN_TYPE` data types (the full form, e.g.
    /// `decimal(10,2)` / `int unsigned`) and raw default expressions.
    /// Primary-key membership comes from ``primaryKey(of:)``.
    public func listColumns(_ table: TableRef) async throws -> [ColumnInfo] {
        let database = Self.resolvedDatabase(for: table)

        let columns = try await self.fetch(
            """
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
            """,
            binds: [MySQLData(string: database), MySQLData(string: table.name)]
        ) { row in
            ColumnInfo(
                name: try Self.required(row.column("COLUMN_NAME")?.string, column: "COLUMN_NAME"),
                dataType: try Self.required(row.column("COLUMN_TYPE")?.string, column: "COLUMN_TYPE"),
                isNullable: row.column("IS_NULLABLE")?.string == "YES",
                isPrimaryKey: false,
                defaultValue: row.column("COLUMN_DEFAULT")?.string
            )
        }

        guard !columns.isEmpty else {
            throw DriverError.queryFailed(
                "table \(database).\(table.name) has no columns (does it exist?)"
            )
        }

        let pkNames = Set(try await self.primaryKey(of: table) ?? [])
        return columns.map { column in
            var column = column
            column.isPrimaryKey = pkNames.contains(column.name)
            return column
        }
    }

    /// Returns the primary-key column names in constraint order, or `nil`
    /// when the table has no primary key.
    public func primaryKey(of table: TableRef) async throws -> [String]? {
        let database = Self.resolvedDatabase(for: table)

        let names = try await self.fetch(
            """
            SELECT COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND CONSTRAINT_NAME = 'PRIMARY'
            ORDER BY ORDINAL_POSITION
            """,
            binds: [MySQLData(string: database), MySQLData(string: table.name)]
        ) { row in
            try Self.required(row.column("COLUMN_NAME")?.string, column: "COLUMN_NAME")
        }
        return names.isEmpty ? nil : names
    }

    /// Returns the server's verbatim `SHOW CREATE TABLE \`db\`.\`tbl\`` text.
    ///
    /// Unlike PostgresDriver's reconstruction this is byte-exact server
    /// output (engine, charset, secondary indexes included).
    public func tableDDL(_ table: TableRef) async throws -> String {
        let database = Self.resolvedDatabase(for: table)
        let sql = "SHOW CREATE TABLE \(IdentifierQuoting.quote(database)).\(IdentifierQuoting.quote(table.name))"

        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            let rows = try await connection.simpleQuery(sql).get()
            guard let row = rows.first,
                  let ddl = row.column("Create Table")?.string, !ddl.isEmpty else {
                throw DriverError.queryFailed(
                    "SHOW CREATE TABLE returned nothing for \(database).\(table.name)"
                )
            }
            return ddl
        } catch {
            throw Self.mapExecutionError(error)
        }
    }

    // MARK: - Row browsing (Task D)

    /// Reads one window of rows from a table (or view).
    ///
    /// Identifiers travel through ``IdentifierQuoting``; the numeric
    /// LIMIT/OFFSET are validated integers interpolated directly (same policy
    /// as PostgresDriver). The total count comes from the same
    /// `information_schema.TABLES.TABLE_ROWS` estimate
    /// ``listTables(database:schema:)`` surfaces — best effort (`nil` when
    /// unknown).
    ///
    /// Known limitation (MySQLNIO 1.x): column definitions only flow back
    /// with at least one row, so an empty window reports no headers (same
    /// behavior as zero-row selects in ``MySQLDriver/execute(_:)``).
    func browseRowsImpl(
        _ table: TableRef,
        sort: SortSpec?,
        limit: Int,
        offset: Int
    ) async throws -> RowPage {
        guard limit > 0 else {
            throw DriverError.queryFailed("limit must be greater than 0")
        }
        guard offset >= 0 else {
            throw DriverError.queryFailed("offset must be ≥ 0")
        }

        let database = Self.resolvedDatabase(for: table)
        var sql = "SELECT * FROM \(IdentifierQuoting.quote(database)).\(IdentifierQuoting.quote(table.name))"
        if let sort {
            let direction = sort.ascending ? "ASC" : "DESC"
            sql += " ORDER BY \(IdentifierQuoting.quote(sort.columnName)) \(direction)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"

        var rows: [[SQLValue]] = []
        var columns: [ColumnInfo] = []

        do {
            guard let connection = self.activeConnection else {
                throw DriverError.connectionFailed("Not connected")
            }
            let collected = try await connection.query(sql, []).get()
            try Task.checkCancellation()
            if let first = collected.first {
                columns = first.columnDefinitions.map {
                    ColumnInfo(name: $0.name, dataType: SQLValueMapper.typeName($0.columnType))
                }
                rows = collected.map(Self.cells(of:))
            }
        } catch {
            throw Self.mapExecutionError(error)
        }

        return RowPage(
            columns: columns,
            rows: rows,
            totalCountEstimate: try await self.rowCountEstimate(database: database, name: table.name)
        )
    }

    /// Best-effort `TABLE_ROWS` estimate for one relation; `nil` when the
    /// table/view does not exist.
    private func rowCountEstimate(database: String, name: String) async throws -> Int64? {
        let estimates = try await self.fetch(
            """
            SELECT TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
              AND TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            """,
            binds: [MySQLData(string: database), MySQLData(string: name)]
        ) { row in
            row.column("TABLE_ROWS")?.uint64.map { Int64(clamping: $0) }
        }
        return estimates.first ?? nil
    }

    // MARK: - Internals

    /// A table ref without an explicit schema resolves against its own
    /// database (MySQL database == schema).
    static func resolvedDatabase(for table: TableRef) -> String {
        table.schema ?? table.database
    }

    /// Unwraps a required textual catalog cell into a readable error.
    private static func required(_ value: String?, column: String) throws -> String {
        guard let value else {
            throw DriverError.introspectionFailed("catalog row missing \(column)")
        }
        return value
    }

    /// Runs one parameterized read-only statement over the **prepared**
    /// protocol and maps every returned row through `transform`. Errors funnel
    /// through the shared execution-error mapping so callers see Kit
    /// `DriverError`s.
    func fetch<T>(
        _ sql: String,
        binds: [MySQLData] = [],
        transform: @escaping (MySQLRow) throws -> T
    ) async throws -> [T] {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            let rows = try await connection.query(sql, binds).get()
            try Task.checkCancellation()
            return try rows.map(transform)
        } catch {
            throw Self.mapExecutionError(error)
        }
    }
}

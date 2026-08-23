import Foundation
import NativQLKit
import NIOCore
import PostgresNIO

// MARK: - Catalog introspection (Task C)
//
// Every query here is a constant statement whose user-influenced values travel
// exclusively through `$n` bind parameters (extended protocol) — never string
// interpolation into SQL text. The only place names are embedded into SQL is
// reconstructed DDL *output*, where they go through `IdentifierQuoting`.

extension PostgresDriver {
    /// Lists non-template databases on the server, ordered by name.
    public func listDatabases() async throws -> [DatabaseInfo] {
        try await fetch(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        ) { row in
            DatabaseInfo(name: try row[0].decode(String.self))
        }
    }

    /// Lists tables and views of one schema.
    ///
    /// The driver session is bound to its connected database; PostgreSQL's
    /// catalogs only describe that database, so the `database` argument cannot
    /// select another one — mismatches are ignored (results always reflect the
    /// current database).
    ///
    /// `schema == nil` excludes system schemas (`pg_catalog`,
    /// `information_schema`, and anything matching `pg_%`); an explicit schema
    /// name narrows to exactly that schema. Row counts come from
    /// `pg_class.reltuples` (catalog estimates: 0 until first ANALYZE/VACUUM,
    /// clamped so never-negative). Materialized views surface as `.view`
    /// because the Kit's `TableInfo.Kind` has no separate matview case.
    public func listTables(database: String, schema: String?) async throws -> [TableInfo] {
        var binds = PostgresBindings()
        if let schema {
            binds.append(schema)
        } else {
            binds.appendNull()
        }

        return try await fetch(
            """
            SELECT n.nspname,
                   c.relname,
                   CASE c.relkind WHEN 'r' THEN 'table' ELSE 'view' END,
                   GREATEST(c.reltuples, 0)::float8
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'v', 'm')
              AND (($1::text IS NULL
                    AND n.nspname <> 'pg_catalog'
                    AND n.nspname <> 'information_schema'
                    AND n.nspname NOT LIKE 'pg\\_%')
                OR ($1::text IS NOT NULL AND n.nspname = $1))
            ORDER BY n.nspname, c.relname
            """,
            bindings: binds
        ) { row in
            let ref = TableRef(
                database: database,
                schema: try row[0].decode(String.self),
                name: try row[1].decode(String.self)
            )
            let kindCode = try row[2].decode(String.self)
            let estimate = try row[3].decode(Double.self)
            return TableInfo(
                ref: ref,
                kind: kindCode == "table" ? .table : .view,
                estimatedRowCount: Int64(estimate.rounded())
            )
        }
    }

    /// Lists a table's columns in ordinal order with verbatim
    /// `information_schema` data types and raw default expressions.
    /// Primary-key membership comes from ``primaryKey(of:)``.
    public func listColumns(_ table: TableRef) async throws -> [ColumnInfo] {
        var binds = PostgresBindings()
        binds.append(Self.resolvedSchemaName(for: table))
        binds.append(table.name)

        let columns = try await fetch(
            """
            SELECT column_name, data_type, is_nullable, column_default
            FROM information_schema.columns
            WHERE table_schema = $1 AND table_name = $2
            ORDER BY ordinal_position
            """,
            bindings: binds
        ) { row in
            ColumnInfo(
                name: try row[0].decode(String.self),
                dataType: try row[1].decode(String.self),
                isNullable: try row[2].decode(String.self) == "YES",
                isPrimaryKey: false,
                defaultValue: try row[3].decode(String?.self)
            )
        }

        guard !columns.isEmpty else {
            throw DriverError.queryFailed(
                "relation \(Self.resolvedSchemaName(for: table)).\(table.name) has no columns (does it exist?)"
            )
        }

        let pkNames = Set(try await self.primaryKey(of: table) ?? [])
        return columns.map { column in
            var column = column
            column.isPrimaryKey = pkNames.contains(column.name)
            return column
        }
    }

    /// Returns the primary-key column names in index order, or `nil` when the
    /// table has no primary key.
    ///
    /// `unnest(indkey) WITH ORDINALITY` preserves the composite key order
    /// declared in the constraint.
    public func primaryKey(of table: TableRef) async throws -> [String]? {
        var binds = PostgresBindings()
        binds.append(Self.resolvedSchemaName(for: table))
        binds.append(table.name)

        let names = try await fetch(Self.primaryKeySQL, bindings: binds) { row in
            try row[0].decode(String.self)
        }
        return names.isEmpty ? nil : names
    }

    /// Reconstructs a `CREATE TABLE "schema"."name" (...);` statement from the
    /// catalogs.
    ///
    /// - Important: This is a **reconstruction**, not a byte-exact `pg_dump`
    ///   equivalent: indexes beyond the primary key, storage parameters,
    ///   inheritance, RLS policies, comments, and identity/GENERATED markers
    ///   are not represented (identity columns surface their underlying
    ///   `nextval(...)` default verbatim).
    ///
    /// Column lines render as `"name" type [NOT NULL] [DEFAULT <raw expr>]`,
    /// followed by a `PRIMARY KEY (...)` clause when a primary key exists.
    public func tableDDL(_ table: TableRef) async throws -> String {
        var binds = PostgresBindings()
        binds.append(Self.resolvedSchemaName(for: table))
        binds.append(table.name)

        let columns = try await fetch(
            """
            SELECT a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE n.nspname = $1
              AND c.relname = $2
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            bindings: binds
        ) { row in
            DDLColumn(
                name: try row[0].decode(String.self),
                type: try row[1].decode(String.self),
                notNull: try row[2].decode(Bool.self),
                defaultValue: try row[3].decode(String?.self)
            )
        }

        guard !columns.isEmpty else {
            throw DriverError.queryFailed(
                "relation \(Self.resolvedSchemaName(for: table)).\(table.name) not found"
            )
        }

        let primaryKey = try await self.primaryKey(of: table) ?? []

        var lines = columns.map { column -> String in
            var line = "    \(IdentifierQuoting.quote(column.name)) \(column.type)"
            if column.notNull { line += " NOT NULL" }
            if let defaultValue = column.defaultValue { line += " DEFAULT \(defaultValue)" }
            return line
        }
        if !primaryKey.isEmpty {
            let quotedColumns = primaryKey.map(IdentifierQuoting.quote).joined(separator: ", ")
            lines.append("    PRIMARY KEY (\(quotedColumns))")
        }

        return """
        CREATE TABLE \(IdentifierQuoting.quote(Self.resolvedSchemaName(for: table))).\(IdentifierQuoting.quote(table.name)) (
        \(lines.joined(separator: ",\n"))
        );
        """
    }

    // MARK: - Internals

    private struct DDLColumn {
        var name: String
        var type: String
        var notNull: Bool
        var defaultValue: String?
    }

    private static let primaryKeySQL = """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indisprimary
          AND n.nspname = $1
          AND c.relname = $2
        ORDER BY k.ord
        """

    /// Tables without an explicit schema resolve against `public`.
    private static func resolvedSchemaName(for table: TableRef) -> String {
        table.schema ?? "public"
    }

    /// Runs one read-only statement (optionally parameterized via `$n` binds)
    /// and maps every returned row through `transform`. Errors funnel through
    /// the shared execution-error mapping so callers see Kit `DriverError`s.
    private func fetch<T>(
        _ sql: String,
        bindings: PostgresBindings = PostgresBindings(),
        transform: (PostgresRandomAccessRow) throws -> T
    ) async throws -> [T] {
        guard let connection = self.activeConnection else {
            throw DriverError.connectionFailed("Not connected")
        }
        do {
            let sequence = try await connection.query(
                PostgresQuery(unsafeSQL: sql, binds: bindings),
                logger: self.logger
            )
            var mapped = [T]()
            for try await row in sequence {
                try Task.checkCancellation()
                mapped.append(try transform(PostgresRandomAccessRow(row)))
            }
            return mapped
        } catch {
            throw Self.mapExecutionError(error)
        }
    }
}

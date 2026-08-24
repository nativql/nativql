/// Kit emits PostgreSQL-style double-quoted identifiers as canonical form;
/// MySQLDriver translates those double-quoted identifiers to backticks in its
/// mutation executor (`IdentifierTranslation`) before binding.
public enum InsertStatementBuilder {
    public static func build(
        table: TableRef,
        columns: [ColumnInfo],
        rows: [[SQLValue]]
    ) -> MutationStatement {
        let qualified: String
        if let schema = table.schema {
            qualified = quote(schema) + "." + quote(table.name)
        } else {
            qualified = quote(table.name)
        }
        let columnList = columns.map { quote($0.name) }.joined(separator: ", ")
        let placeholders = "(" + Array(repeating: "?", count: columns.count).joined(separator: ", ") + ")"
        let sql = "INSERT INTO \(qualified) (\(columnList)) VALUES \(placeholders);"

        let batches = rows.map { row in
            (0..<columns.count).map { idx in idx < row.count ? row[idx] : SQLValue.null }
        }
        return MutationStatement(kind: .insert, table: table, sql: sql, batches: batches)
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

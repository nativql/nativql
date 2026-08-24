/// Builds parameterized single-row UPDATE statements; one batch of bindings
/// per statement in `changes`-then-`pkColumns` order.
public enum UpdateStatementBuilder {
    /// Returns nil when there is nothing to set or no primary key to filter by;
    /// missing pk values bind `.null`.
    public static func build(
        table: TableRef,
        pkColumns: [ColumnInfo],
        changes: [(columnName: String, newValue: SQLValue)],
        pkValues: [String: SQLValue]
    ) -> MutationStatement? {
        guard !changes.isEmpty, !pkColumns.isEmpty else { return nil }

        let setClause = changes
            .map { "\(InsertStatementBuilder.quote($0.columnName)) = ?" }
            .joined(separator: ", ")
        let whereClause = pkColumns
            .map { "\(InsertStatementBuilder.quote($0.name)) = ?" }
            .joined(separator: " AND ")
        let sql = "UPDATE \(qualifiedName(of: table)) SET \(setClause) WHERE \(whereClause)"

        let newValues = changes.map(\.newValue)
        let keyValues = pkColumns.map { pkValues[$0.name] ?? .null }
        return MutationStatement(kind: .update, table: table, sql: sql, batches: [newValues + keyValues])
    }

    static func qualifiedName(of table: TableRef) -> String {
        if let schema = table.schema {
            return InsertStatementBuilder.quote(schema) + "." + InsertStatementBuilder.quote(table.name)
        }
        return InsertStatementBuilder.quote(table.name)
    }
}

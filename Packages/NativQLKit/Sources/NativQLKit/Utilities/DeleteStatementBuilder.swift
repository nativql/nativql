/// Builds ONE parameterized DELETE filtered by an AND-chained primary key;
/// each deleted row contributes its own binding batch so drivers can wrap all
/// rows in a single transaction without tuple-IN syntax (not portable to MySQL).
public enum DeleteStatementBuilder {
    /// Returns nil when there are no rows or no primary key columns; short rows
    /// pad with `.null` (mirrors InsertStatementBuilder).
    public static func build(
        table: TableRef,
        pkColumns: [ColumnInfo],
        rows: [[SQLValue]]
    ) -> MutationStatement? {
        guard !rows.isEmpty, !pkColumns.isEmpty else { return nil }

        let whereClause = pkColumns
            .map { "\(InsertStatementBuilder.quote($0.name)) = ?" }
            .joined(separator: " AND ")
        let sql = "DELETE FROM \(UpdateStatementBuilder.qualifiedName(of: table)) WHERE \(whereClause)"

        let batches = rows.map { row in
            (0..<pkColumns.count).map { idx in idx < row.count ? row[idx] : SQLValue.null }
        }
        return MutationStatement(kind: .delete, table: table, sql: sql, batches: batches)
    }
}

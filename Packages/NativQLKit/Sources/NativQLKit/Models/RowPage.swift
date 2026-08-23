public struct RowPage: Sendable {
    public var columns: [ColumnInfo]
    public var rows: [[SQLValue]]
    /// Server-side total estimate when cheaply available.
    public var totalCountEstimate: Int64?

    public init(columns: [ColumnInfo], rows: [[SQLValue]], totalCountEstimate: Int64? = nil) {
        self.columns = columns
        self.rows = rows
        self.totalCountEstimate = totalCountEstimate
    }
}

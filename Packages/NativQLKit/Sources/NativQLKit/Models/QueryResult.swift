import Foundation

public struct QueryResult: Sendable {
    public var columns: [ColumnInfo]
    public var rows: [[SQLValue]]
    public var affectedRows: Int64?
    public var executionMilliseconds: Double
    public var statementType: StatementType

    public init(
        columns: [ColumnInfo],
        rows: [[SQLValue]],
        affectedRows: Int64? = nil,
        executionMilliseconds: Double,
        statementType: StatementType
    ) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.executionMilliseconds = executionMilliseconds
        self.statementType = statementType
    }
}

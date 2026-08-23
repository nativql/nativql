/// Built by the app's row-operations layer using ANSI `?` placeholders;
/// drivers bind `bindings` positionally and execute transactionally.
public struct MutationStatement: Sendable {
    public enum Kind: String, Sendable {
        case update, insert, delete
    }

    public var kind: Kind
    public var table: TableRef
    public var sql: String
    /// One binding list per affected row; drivers wrap all lists in one transaction.
    public var batches: [[SQLValue]]

    public init(kind: Kind, table: TableRef, sql: String, batches: [[SQLValue]]) {
        self.kind = kind
        self.table = table
        self.sql = sql
        self.batches = batches
    }
}

public struct TableInfo: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case table
        case view
    }

    public var ref: TableRef
    public var kind: Kind
    /// Approximate row count from catalog stats; nil when unknown.
    public var estimatedRowCount: Int64?

    public init(ref: TableRef, kind: Kind = .table, estimatedRowCount: Int64? = nil) {
        self.ref = ref
        self.kind = kind
        self.estimatedRowCount = estimatedRowCount
    }
}

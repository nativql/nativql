public struct SortSpec: Hashable, Sendable {
    public var columnName: String
    public var ascending: Bool

    public init(columnName: String, ascending: Bool = true) {
        self.columnName = columnName
        self.ascending = ascending
    }
}

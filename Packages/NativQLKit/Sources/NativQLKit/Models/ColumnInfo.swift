public struct ColumnInfo: Hashable, Codable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var defaultValue: String?

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
    }
}

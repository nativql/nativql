public struct TableRef: Hashable, Codable, Sendable {
    public var database: String
    public var schema: String?
    public var name: String

    public init(database: String, schema: String? = nil, name: String) {
        self.database = database
        self.schema = schema
        self.name = name
    }
}

public enum DatabaseKind: String, Codable, Sendable, CaseIterable {
    case postgres
    case mysql

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: return 5432
        case .mysql: return 3306
        }
    }
}

import Foundation

public struct ConnectionConfig: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    public var database: String?
    public var sslMode: SSLMode
    public var colorLabel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        host: String,
        port: Int? = nil,
        user: String,
        password: String? = nil,
        database: String? = nil,
        sslMode: SSLMode = .prefer,
        colorLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.user = user
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.colorLabel = colorLabel
    }
}

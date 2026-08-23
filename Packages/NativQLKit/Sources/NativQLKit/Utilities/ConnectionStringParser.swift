import Foundation

public enum ConnectionStringParserError: Error, Equatable {
    case invalidURL(String)
    case unsupportedScheme(String)
}

public enum ConnectionStringParser {
    public static func parse(_ raw: String) throws -> ConnectionConfig {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw ConnectionStringParserError.invalidURL(raw)
        }

        let kind: DatabaseKind
        switch scheme {
        case "postgres", "postgresql": kind = .postgres
        case "mysql": kind = .mysql
        default: throw ConnectionStringParserError.unsupportedScheme(scheme)
        }

        let user = url.user.map(decodePercentEscapes) ?? ""
        let password = url.password.map(decodePercentEscapes)

        let path = url.path
        let database = (path.isEmpty || path == "/") ? nil : String(path.dropFirst())

        var config = ConnectionConfig(
            name: "\(user)@\(host)",
            kind: kind,
            host: host,
            port: url.port,
            user: user,
            password: password,
            database: database
        )

        if let components = URLComponents(string: trimmed),
           let queryItems = components.queryItems {
            if let mode = queryItems.first(where: { $0.name == "sslmode" })?.value,
               let ssl = SSLMode(rawValue: mode) {
                config.sslMode = ssl
            }
        }
        return config
    }

    private static func decodePercentEscapes(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

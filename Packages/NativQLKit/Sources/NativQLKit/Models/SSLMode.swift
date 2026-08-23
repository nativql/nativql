public enum SSLMode: String, Codable, Sendable, CaseIterable {
    case disable
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public static func availableModes(for kind: DatabaseKind) -> [SSLMode] {
        switch kind {
        case .postgres: return [.disable, .prefer, .require, .verifyFull]
        case .mysql: return [.disable, .prefer, .require, .verifyCA, .verifyFull]
        }
    }
}

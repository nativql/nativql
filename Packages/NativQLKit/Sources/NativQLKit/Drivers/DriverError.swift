public enum DriverError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case tlsFailed(String)
    case queryFailed(String)
    case cancelled
    case timeout
    case introspectionFailed(String)
    case mutationFailed(String)
    case unsupportedFeature(String)

    public var message: String {
        switch self {
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .tlsFailed(let m): return "TLS error: \(m)"
        case .queryFailed(let m): return m
        case .cancelled: return "Query cancelled"
        case .timeout: return "Query timed out"
        case .introspectionFailed(let m): return "Introspection failed: \(m)"
        case .mutationFailed(let m): return "Update failed: \(m)"
        case .unsupportedFeature(let m): return "Not supported: \(m)"
        }
    }
}

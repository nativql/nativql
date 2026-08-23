import Foundation

public enum SQLValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    /// NUMERIC/DECIMAL kept as raw text to preserve precision; views format it.
    case decimal(String)
    case string(String)
    case date(Date)          // DATE only
    case time(TimeInterval)  // TIME as seconds since midnight
    case datetime(Date)      // TIMESTAMP / DATETIME
    case json(String)        // raw text; JSON viewer parses on demand
    case bytes(Data)
}

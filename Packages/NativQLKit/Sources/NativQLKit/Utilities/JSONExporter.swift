import Foundation

public enum JSONExporter {
    /// Exports rows as a JSON array of objects, one object per row.
    /// Duplicate column names collapse (last one wins); non-finite doubles
    /// (NaN, ±inf) are exported as their string form to keep output valid JSON.
    public static func export(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        var objects: [[String: Any]] = []
        objects.reserveCapacity(rows.count)
        for row in rows {
            var obj: [String: Any] = [:]
            for (i, col) in columns.enumerated() where i < row.count {
                obj[col.name] = jsonObject(row[i])
            }
            objects.append(obj)
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func jsonObject(_ value: SQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d):
            return d.isFinite ? NSNumber(value: d) : String(d)
        case .decimal(let s): return s
        case .string(let s): return s
        case .date(let d): return CSVExporter.dateFormatter.string(from: d)
        case .time(let s): return CSVExporter.timeFormatter.string(from: s) ?? ""
        case .datetime(let d): return Self.iso8601Formatter.string(from: d)
        case .json(let raw):
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return parsed
            }
            return raw
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    static let iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()
}

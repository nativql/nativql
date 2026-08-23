import Foundation

public enum CSVExporter {
    public static func export(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        var lines = [columns.map(\.name).map(escape).joined(separator: ",")]
        for row in rows {
            lines.append(row.map(render).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ value: SQLValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .decimal(let s): return s
        case .string(let s): return s
        case .date(let date):
            return Self.dateFormatter.string(from: date)
        case .time(let seconds):
            return Self.timeFormatter.string(from: seconds) ?? ""
        case .datetime(let date):
            return Self.datetimeFormatter.string(from: date)
        case .json(let s): return s
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let datetimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()
}

import Foundation
import NativQLKit
import NIOCore
import MySQLNIO

/// Maps between MySQL wire values (`MySQLData`) and the Kit's `SQLValue`.
///
/// Dispatch is driven by the wire-level `MySQLProtocol.DataType` of each cell
/// (not column DDL strings), mirroring how PostgresDriver dispatches on
/// `RowDescription` types.
///
/// Known limitations (documented deliberately):
/// - VARBINARY/BINARY columns are reported by the server as `varString` /
///   `string`, so they surface as `.string`. Only true BLOB-family columns
///   arrive as `.bytes`. This matches server behavior; a v1.x refinement can
///   consult `ColumnDefinition41.flags.charset` to disambiguate.
/// - DATE/DATETIME/TIMESTAMP cells are decoded by MySQLNIO into Foundation
///   `Date` treating components as UTC; no session-timezone conversion is
///   attempted (same policy as PostgresDriver for naive timestamps).
enum SQLValueMapper {
    // MARK: - Wire type naming

    /// Canonical type label for grid headers, derived from the wire data type
    /// (DDL-level precision like DECIMAL(10,2) is only available through
    /// information_schema introspection).
    static func typeName(_ t: MySQLProtocol.DataType) -> String {
        switch t {
        case .decimal, .newdecimal: return "decimal"
        case .tiny: return "tinyint"
        case .short: return "smallint"
        case .long: return "int"
        case .int24: return "mediumint"
        case .longlong: return "bigint"
        case .float: return "float"
        case .double: return "double"
        case .null: return "null"
        case .timestamp, .timestamp2: return "timestamp"
        case .date, .newdate: return "date"
        case .time, .time2: return "time"
        case .datetime, .datetime2: return "datetime"
        case .year: return "year"
        case .varchar: return "varchar"
        case .bit: return "bit"
        case .json: return "json"
        case .enum: return "enum"
        case .set: return "set"
        case .tinyBlob: return "tinyblob"
        case .mediumBlob: return "mediumblob"
        case .longBlob: return "longblob"
        case .blob: return "blob"
        case .varString: return "varbinary-or-varchar"
        case .string: return "char"
        case .geometry: return "geometry"
        default: return "\(t)"
        }
    }

    // MARK: - Forward mapping

    /// - Parameters:
    ///   - data: the wire cell
    ///   - isBinaryCharset: `true` when the column's charset is 63 (binary).
    ///     Only meaningful for the BLOB family, where MySQL also reports TEXT
    ///     columns — charset 63 separates real bytes from text.
    static func map(_ data: MySQLData, isBinaryCharset: Bool = false) -> SQLValue {
        guard data.buffer != nil, data.type != .null else { return .null }

        let t = data.type

        if t == .double || t == .float {
            return .double(data.double ?? 0)
        }
        if t == .newdecimal || t == .decimal {
            // MySQLData.string doesn't handle binary-format decimals — read
            // raw so exact scale text survives ("1234.57", trailing zeros kept).
            var buffer = data.buffer!
            let raw = buffer.readBytes(length: buffer.readableBytes) ?? []
            return .decimal(String(bytes: raw, encoding: .utf8) ?? "0")
        }
        if t == .longlong || t == .long || t == .int24 || t == .short {
            return mapInteger(data)
        }
        if t == .tiny {
            // TINYINT(1) is conventionally BOOL but is not distinguishable at
            // the protocol level from TINYINT — surface as int (documented).
            return mapInteger(data)
        }
        if t == .year {
            // Fixed 2-byte LE payload (length prefix consumed by row parser).
            var buffer = data.buffer!
            return .int(Int64(buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0))
        }
        if t == .bit {
            // MySQL stores bit-fields big-endian; width is 1–8 bytes.
            var buffer = data.buffer!
            let n = buffer.readableBytes
            let raw = buffer.readBytes(length: n) ?? []
            var value: UInt64 = 0
            for byte in raw {
                value = (value << 8) | UInt64(byte)
            }
            return Int64(exactly: value).map(SQLValue.int) ?? .string("0x" + String(value, radix: 16))
        }
        if t == .date || t == .newdate {
            guard let date = data.date else { return .null }
            return .date(date)
        }
        if t == .datetime || t == .timestamp || t == .datetime2 || t == .timestamp2 {
            guard let date = data.date else { return .null }
            return .datetime(date)
        }
        if t == .time || t == .time2 {
            return mapTime(data)
        }
        if t == .json {
            // MySQLData.string doesn't handle binary-format JSON — read raw.
            var buffer = data.buffer!
            let raw = buffer.readBytes(length: buffer.readableBytes) ?? []
            return .json(String(bytes: raw, encoding: .utf8) ?? "")
        }
        if isBlobFamily(t) {
            // BLOB-family covers TEXT too; charset 63 (binary) means bytes.
            guard isBinaryCharset else {
                return .string(data.string ?? "")
            }
            var buffer = data.buffer!
            return .bytes(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        // varchar / varString / string / enum / set / geometry fallbacks and
        // anything unrecognized: textual rendering.
        return .string(data.string ?? "")
    }

    private static func mapInteger(_ data: MySQLData) -> SQLValue {
        if data.isUnsigned {
            var buffer = data.buffer!
            let size = buffer.readableBytes
            switch size {
            case 8:
                if let u: UInt64 = buffer.readInteger(endianness: .little) {
                    return Int64(exactly: u).map(SQLValue.int) ?? .string(String(u))
                }
            case 4:
                if let u: UInt32 = buffer.readInteger(endianness: .little) { return .int(Int64(u)) }
            case 2:
                if let u: UInt16 = buffer.readInteger(endianness: .little) { return .int(Int64(u)) }
            case 1:
                if let u: UInt8 = buffer.readInteger(endianness: .little) { return .int(Int64(u)) }
            default:
                break
            }
            // fall through to text decoding for odd sizes
        }
        if let i = data.int64 { return .int(i) }
        if let i = data.int { return .int(Int64(i)) }
        return .string(data.string ?? "")
    }

    /// MySQL TIME spans −838:59:59 … 838:59:59 (hours may exceed 24, days
    /// carry the magnitude). Binary wire layout after the row parser strips
    /// the length prefix: `[neg:u8][days:u32 LE][h][m][s]([us:u32 LE])` —
    /// 8 or 12 bytes. MySQLNIO's own `readMySQLTime()` discards sign+days,
    /// so we parse the buffer directly. Kit represents TIME as signed total
    /// seconds; microseconds are truncated in v1.
    private static func mapTime(_ data: MySQLData) -> SQLValue {
        if data.format == .binary, var buffer = data.buffer {
            let size = buffer.readableBytes
            if size == 8 || size == 12 {
                let neg = buffer.readInteger(endianness: .little, as: UInt8.self) ?? 0
                let days = Int64(buffer.readInteger(endianness: .little, as: UInt32.self) ?? 0)
                let h = Int64(buffer.readInteger(endianness: .little, as: UInt8.self) ?? 0)
                let m = Int64(buffer.readInteger(endianness: .little, as: UInt8.self) ?? 0)
                let s = Int64(buffer.readInteger(endianness: .little, as: UInt8.self) ?? 0)
                var total = days * 86_400 + h * 3_600 + m * 60 + s
                if neg == 1 { total = -total }
                return .time(TimeInterval(total))
            }
        }
        // Text-protocol fallback: "-HHH:MM:SS"
        guard let raw = data.string else { return .null }
        if let parsed = parseTimeString(raw) { return .time(parsed) }
        return .string(raw)
    }

    static func parseTimeString(_ raw: String) -> TimeInterval? {
        var body = raw
        var sign: Double = 1
        if body.hasPrefix("-") {
            sign = -1
            body.removeFirst()
        }
        let parts = body.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    private static func isBlobFamily(_ t: MySQLProtocol.DataType) -> Bool {
        t == .blob || t == .tinyBlob || t == .mediumBlob || t == .longBlob || t == .geometry
    }

    // MARK: - Reverse mapping (binding)

    /// Converts a Kit value into a bindable parameter. Dates bind as ISO-ish
    /// strings — MySQL casts string parameters contextually against the target
    /// column type in prepared statements, which sidesteps timezone handling
    /// (same policy as PostgresDriver's ISO-text binding).
    static func bindable(_ value: SQLValue) -> MySQLData {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return MySQLData(bool: b)
        case .int(let i):
            return MySQLData(int: Int(truncatingIfNeeded: i))
        case .double(let d):
            return MySQLData(double: d)
        case .decimal(let s):
            return MySQLData(string: s)
        case .string(let s):
            return MySQLData(string: s)
        case .json(let s):
            return MySQLData(string: s)
        case .date(let date):
            return MySQLData(string: Formatters.date.string(from: date))
        case .datetime(let date):
            return MySQLData(string: Formatters.datetime.string(from: date))
        case .time(let seconds):
            return MySQLData(string: timeBindingString(seconds))
        case .bytes(let data):
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return MySQLData(type: .blob, format: .binary, buffer: buffer, isUnsigned: true)
        }
    }

    static func timeBindingString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : ""
        let absSeconds = abs(total)
        return String(
            format: "%@%02d:%02d:%02d",
            sign,
            absSeconds / 3600,
            (absSeconds % 3600) / 60,
            absSeconds % 60
        )
    }

    enum Formatters {
        static let date: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()

        static let datetime: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()
    }
}

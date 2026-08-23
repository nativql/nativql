import Foundation
import NativQLKit
import NIOCore
import PostgresNIO

/// Maps PostgreSQL cells to Kit `SQLValue`s and back into bindable parameters.
///
/// Wire reality (PostgresNIO 1.x extended protocol): every result column is
/// requested in **binary** format, so this mapper implements binary decodings
/// for the types where fidelity matters (numeric scale, timestamps, jsonb,
/// bytea, uuid). Text decodings exist for completeness and are what the pure
/// `sqlValue(fromText:typeName:)` entry point exercises in unit tests.
///
/// Type dispatch is driven by canonical lowercase type-name strings
/// ("int4", "numeric", …) produced by ``typeName(for:)``; keeping those
/// functions pure makes them testable without a live connection.
enum SQLValueMapper {
    /// PostgreSQL's epoch: 2000-01-01 00:00:00 UTC, the zero of binary
    /// date/time encodings on the wire. Expressed against Foundation's
    /// reference date (2001-01-01): 2000 is a leap year, hence 31,622,400 s.
    private static let postgresEpochInterval = TimeInterval(-31_622_400)

    // MARK: - OID → type name

    /// Canonical lowercase PostgreSQL type name for a wire data type.
    ///
    /// Unknown OIDs (user-defined enums, domains, extensions) fall back to the
    /// library's known-SQL name lowercased; anything still unknown becomes
    /// `"unknown"` and maps to `.string`.
    static func typeName(for dataType: PostgresDataType) -> String {
        switch dataType {
        case .bool: return "bool"
        case .bytea: return "bytea"
        case .char: return "char"
        case .name: return "name"
        case .int8: return "int8"
        case .int2: return "int2"
        case .int4: return "int4"
        case .oid: return "oid"
        case .text: return "text"
        case .json: return "json"
        case .xml: return "xml"
        case .float4: return "float4"
        case .float8: return "float8"
        case .money: return "money"
        case .inet: return "inet"
        case .cidr: return "cidr"
        case .bpchar: return "bpchar"
        case .varchar: return "varchar"
        case .date: return "date"
        case .time: return "time"
        case .timetz: return "timetz"
        case .timestamp: return "timestamp"
        case .timestamptz: return "timestamptz"
        case .interval: return "interval"
        case .numeric: return "numeric"
        case .uuid: return "uuid"
        default:
            return dataType.knownSQLName?.lowercased() ?? "unknown"
        }
    }

    // MARK: - Forward map: cell → SQLValue

    /// Maps one result cell. NULL cells become `.null` regardless of type.
    static func map(_ cell: PostgresCell) throws -> SQLValue {
        guard var bytes = cell.bytes else { return .null }
        let name = typeName(for: cell.dataType)
        switch cell.format {
        case .text:
            let text = bytes.readString(length: bytes.readableBytes) ?? ""
            return sqlValue(fromText: text, typeName: name)
        case .binary:
            return try sqlValue(fromBinary: &bytes, typeName: name)
        }
    }

    /// Pure text-format mapping, keyed by canonical type name. Unparseable
    /// temporal values degrade to `.string` rather than failing whole grids.
    static func sqlValue(fromText text: String, typeName name: String) -> SQLValue {
        switch name {
        case "bool":
            switch text.lowercased() {
            case "t", "true", "y", "yes", "1": return .bool(true)
            default: return .bool(false)
            }
        case "int2", "int4", "int8", "oid", "xid", "cid":
            return Int64(text).map(SQLValue.int) ?? .string(text)
        case "float4", "float8":
            return Double(text).map(SQLValue.double) ?? .string(text)
        case "numeric":
            return .decimal(text)
        case "date":
            return parseDateOnly(text)
        case "timestamp":
            return parseNaiveTimestamp(text)
        case "timestamptz":
            return parseOffsetTimestamp(text)
        case "time", "timetz":
            return parseTimeSeconds(text).map(SQLValue.time) ?? .string(text)
        case "json", "jsonb":
            return .json(text)
        case "bytea":
            return decodeHexBytea(text)
        case "uuid", "money", "xml", "inet", "cidr", "interval":
            return .string(text)
        default:
            // Arrays, composites, text-family and every exotic type stay strings.
            return .string(text)
        }
    }

    /// Binary-format mapping, keyed by canonical type name.
    static func sqlValue(
        fromBinary buffer: inout ByteBuffer,
        typeName name: String
    ) throws -> SQLValue {
        switch name {
        case "bool":
            guard let byte: UInt8 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .bool(byte != 0)
        case "int2":
            guard let value: Int16 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .int(Int64(value))
        case "int4", "oid":
            guard let value: Int32 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .int(Int64(value))
        case "int8":
            guard let value: Int64 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .int(value)
        case "float4":
            guard let bits: UInt32 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .double(Double(Float(bitPattern: bits)))
        case "float8":
            guard let bits: UInt64 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .double(Double(bitPattern: bits))
        case "numeric":
            return .decimal(try decodeNumericText(&buffer))
        case "date":
            guard let days: Int32 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .date(Date(timeIntervalSinceReferenceDate: postgresEpochInterval + TimeInterval(days) * 86_400))
        case "timestamp", "timestamptz":
            // Naive timestamps are interpreted as UTC (documented choice);
            // timestamptz arrives as a true instant either way.
            guard let micros: Int64 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .datetime(Date(timeIntervalSinceReferenceDate: postgresEpochInterval + TimeInterval(micros) / 1_000_000))
        case "time":
            guard let micros: Int64 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .time(TimeInterval(micros) / 1_000_000)
        case "timetz":
            guard let micros: Int64 = buffer.readInteger(),
                  let _: Int32 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .time(TimeInterval(micros) / 1_000_000)
        case "json":
            guard let text = buffer.readString(length: buffer.readableBytes) else { throw MappingError.truncated(name) }
            return .json(text)
        case "jsonb":
            guard let version: UInt8 = buffer.readInteger(), version == 1,
                  let text = buffer.readString(length: buffer.readableBytes) else { throw MappingError.truncated(name) }
            return .json(text)
        case "bytea":
            return .bytes(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        case "uuid":
            guard let bytes = buffer.readBytes(length: 16), bytes.count == 16 else { throw MappingError.truncated(name) }
            let uuid = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            return .string(uuid.uuidString)
        case "money":
            // Binary money is int64 cents; rendered without currency symbol.
            guard let cents: Int64 = buffer.readInteger() else { throw MappingError.truncated(name) }
            let sign = cents < 0 ? "-" : ""
            let absCents = String(abs(cents))
            let dollars = absCents.count > 2 ? String(absCents.dropLast(2)) : "0"
            let fraction = absCents.count >= 2 ? String(absCents.suffix(2)) : String(repeating: "0", count: 2 - absCents.count) + absCents
            return .string("\(sign)\(dollars).\(fraction)")
        case "interval":
            // Binary interval: microseconds (i64), days (i32), months (i32).
            guard let micros: Int64 = buffer.readInteger(),
                  let days: Int32 = buffer.readInteger(),
                  let months: Int32 = buffer.readInteger() else { throw MappingError.truncated(name) }
            return .string(renderInterval(micros: micros, days: days, months: months))
        default:
            // Exotic user-defined types degrade to best-effort UTF-8.
            let text = buffer.readString(length: buffer.readableBytes) ?? ""
            return .string(text)
        }
    }

    enum MappingError: Error {
        case truncated(String)
    }

    // MARK: - Exact binary NUMERIC decoding

    /// Decodes binary `NUMERIC` into exactly the digits PostgreSQL itself
    /// would print (display scale preserved, e.g. `1.50`). Foundation's
    /// `Decimal` would silently drop trailing zeros, hence this decoder.
    ///
    /// Layout: ndigits(i16), weight(i16), sign(u16), dscale(i16),
    /// then ndigits × base-10000 digit groups (i16 each).
    static func decodeNumericText(_ buffer: inout ByteBuffer) throws -> String {
        guard let ndigits: Int16 = buffer.readInteger(),
              let weight: Int16 = buffer.readInteger(),
              let signCode: UInt16 = buffer.readInteger(),
              let dscale: Int16 = buffer.readInteger() else {
            throw MappingError.truncated("numeric")
        }

        switch signCode {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }

        var groups: [Int] = []
        groups.reserveCapacity(Int(max(ndigits, 0)))
        for _ in 0..<max(ndigits, 0) {
            guard let digit: Int16 = buffer.readInteger() else { throw MappingError.truncated("numeric") }
            groups.append(Int(digit))
        }

        var integerPart = ""
        if weight >= 0 {
            for index in 0...Int(weight) {
                let group = index < groups.count ? groups[index] : 0
                if index == 0 {
                    integerPart += String(group)
                } else {
                    integerPart += padGroup(group)
                }
            }
        } else {
            integerPart = "0"
        }

        var fractionPart = ""
        if weight < 0 {
            fractionPart += String(repeating: "0", count: (-Int(weight) - 1) * 4)
            for group in groups { fractionPart += padGroup(group) }
        } else if groups.count > Int(weight) + 1 {
            for index in (Int(weight) + 1)..<groups.count {
                fractionPart += padGroup(groups[index])
            }
        }

        let targetScale = Int(dscale)
        if fractionPart.count > targetScale {
            fractionPart = String(fractionPart.prefix(targetScale))
        } else if fractionPart.count < targetScale {
            fractionPart += String(repeating: "0", count: targetScale - fractionPart.count)
        }

        var text = signCode == 0x4000 ? "-" : ""
        text += integerPart
        if !fractionPart.isEmpty { text += "." + fractionPart }
        return text
    }

    private static func padGroup(_ group: Int) -> String {
        var padded = String(group)
        while padded.count < 4 { padded = "0" + padded }
        return padded
    }

    private static func renderInterval(micros: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        if months != 0 { parts.append("\(months) mons") }
        if days != 0 { parts.append("\(days) days") }
        let totalSeconds = TimeInterval(micros) / 1_000_000
        let sign = totalSeconds < 0 ? "-" : ""
        let remaining = abs(totalSeconds)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = remaining.truncatingRemainder(dividingBy: 60)
        var clock = String(format: "%@%02d:%02d:%06.3f", sign, hours, minutes, seconds)
        if clock.hasSuffix(".000") { clock = String(clock.dropLast(4)) }
        if parts.isEmpty && totalSeconds == 0 { return "00:00:00" }
        parts.append(clock)
        return parts.joined(separator: " ")
    }

    // MARK: - Text temporal parsers

    private static func parseDateOnly(_ text: String) -> SQLValue {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return .string(text) }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: components) else { return .string(text) }
        return .date(date)
    }

    /// "yyyy-MM-dd[ T]HH:mm[:ss[.ffffff]]", interpreted as UTC.
    private static func parseNaiveTimestamp(_ text: String) -> SQLValue {
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let pieces = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .string(text) }

        guard case .date(let day) = parseDateOnly(String(pieces[0])) else { return .string(text) }
        guard let seconds = parseClock(pieces[1].lowercased()) else { return .string(text) }
        return .datetime(day.addingTimeInterval(seconds))
    }

    /// "yyyy-MM-dd[ T]HH:mm[:ss[.ffffff]]±HH[:MM]", offset applied to get UTC.
    private static func parseOffsetTimestamp(_ text: String) -> SQLValue {
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let pieces = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .string(text) }

        guard case .date(let day) = parseDateOnly(String(pieces[0])) else { return .string(text) }
        var clockBody = Substring(pieces[1].lowercased())

        var offsetSeconds = 0
        if let signIndex = clockBody.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let offsetText = clockBody[signIndex...].dropFirst()
            clockBody = clockBody[..<signIndex]
            let digits = offsetText.filter { $0.isNumber }
            if digits.count == 2 {
                offsetSeconds = (Int(digits) ?? 0) * 3600
            } else if digits.count == 4 {
                offsetSeconds = ((Int(digits.prefix(2)) ?? 0) * 3600) + ((Int(digits.suffix(2)) ?? 0) * 60)
            }
            if offsetText.hasPrefix("-") { offsetSeconds.negate() }
        }

        guard let seconds = parseClock(clockBody) else { return .string(text) }
        return .datetime(day.addingTimeInterval(seconds - TimeInterval(offsetSeconds)))
    }

    /// Parses "hh:mm[:ss[.fff…]]" into seconds-since-midnight.
    private static func parseClock(_ body: some StringProtocol) -> TimeInterval? {
        let segments = body.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count == 2 || segments.count == 3 else { return nil }
        guard let hours = Int(segments[0]), let minutes = Int(segments[1]) else { return nil }
        var seconds = TimeInterval(hours * 3600 + minutes * 60)
        if segments.count == 3 {
            guard let secondComponent = Double(segments[2]) else { return nil }
            seconds += secondComponent
        }
        return seconds
    }

    /// TIME and TIME WITH TIME ZONE → seconds since midnight (zone dropped).
    private static func parseTimeSeconds(_ text: String) -> TimeInterval? {
        var body = text.lowercased()
        if let signIndex = body.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            body = String(body[..<signIndex])
        }
        return parseClock(body)
    }

    /// `\xDEADBEEF` hex escape (modern output_format); other payloads fall
    /// back to their raw UTF-8 bytes.
    private static func decodeHexBytea(_ text: String) -> SQLValue {
        guard text.hasPrefix("\\x") else { return .bytes(Data(text.utf8)) }
        let hex = String(text.dropFirst(2))
        var data = Data(capacity: hex.count / 2)
        var current: UInt8 = 0
        var hasHighNibble = false
        for character in hex.utf8 {
            guard let nibble = Self.hexNibble(character) else { return .bytes(Data(text.utf8)) }
            if hasHighNibble {
                data.append(current | nibble)
                hasHighNibble = false
            } else {
                current = nibble << 4
                hasHighNibble = true
            }
        }
        return .bytes(data)
    }

    private static func hexNibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x61...0x66: return ascii - 0x61 + 10
        case 0x41...0x46: return ascii - 0x41 + 10
        default: return nil
        }
    }

    // MARK: - Reverse map: SQLValue → bindable parameter

    /// Binds a `SQLValue` as a positional parameter payload.
    ///
    /// Encoding choices (documented):
    /// - Temporal values bind as **ISO text** rather than native binary dates:
    ///   PostgreSQL resolves untyped text parameters to the target column's
    ///   type directly, sidestepping session-timezone ambiguity entirely.
    /// - JSON binds as text; the server casts to `json`/`jsonb`.
    /// - Bytes bind natively (hex-escaping text would be lossier).
    static func bindable(_ value: SQLValue) -> PostgresData? {
        switch value {
        case .null:
            return nil
        case .bool(let boolean):
            return PostgresData(bool: boolean)
        case .int(let integer):
            return PostgresData(int64: integer)
        case .double(let double):
            return PostgresData(double: double)
        case .decimal(let text):
            if let decimal = Decimal(string: text) {
                return PostgresData(decimal: decimal)
            }
            return PostgresData(string: text)
        case .string(let text), .json(let text):
            return PostgresData(string: text)
        case .date(let date):
            return PostgresData(string: Self.isoDayFormatter.string(from: date))
        case .datetime(let date):
            return PostgresData(string: Self.isoTimestampFormatter.string(from: date))
        case .time(let seconds):
            return PostgresData(string: Self.clockText(seconds: seconds))
        case .bytes(let data):
            return PostgresData(bytes: data)
        }
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter
    }()

    private static func clockText(seconds: TimeInterval) -> String {
        let clamped = max(0, min(86_399, seconds))
        let whole = Int(clamped)
        let fraction = clamped - TimeInterval(whole)
        let base = String(format: "%02d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
        return fraction > 0 ? "\(base).\(String(format: "%06d", Int((fraction * 1_000_000).rounded())))" : base
    }
}

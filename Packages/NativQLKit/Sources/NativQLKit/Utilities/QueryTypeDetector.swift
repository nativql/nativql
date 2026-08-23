public enum StatementType: String, Sendable {
    case select, insert, update, delete, ddl, explain, transactionControl, other
}

public enum QueryTypeDetector {
    public static func type(of sql: String) -> StatementType {
        let stripped = stripComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = stripped
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ";" })
            .first?.lowercased() else { return .other }
        switch firstWord {
        case "select", "with", "table", "values": return .select
        case "insert": return .insert
        case "update": return .update
        case "delete": return .delete
        case "explain": return .explain
        case "create", "alter", "drop", "truncate", "comment": return .ddl
        case "begin", "start", "commit", "rollback", "savepoint", "release",
             "set", "show", "use":
            return .transactionControl
        default: return .other
        }
    }

    /// Removes -- and /* */ comments while preserving string literals.
    /// Reuses SQLStatementSplitter.scanQuoted so both stay consistent.
    static func stripComments(_ sql: String) -> String {
        let chars = Array(sql)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'":
                out.append(ch); i += 1
                i = SQLStatementSplitter.scanQuoted(chars, from: i, terminator: "'", into: &out)
            case "\"":
                out.append(ch); i += 1
                i = SQLStatementSplitter.scanQuoted(chars, from: i, terminator: "\"", into: &out)
            case "-":
                if i + 1 < chars.count, chars[i + 1] == "-" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    if i < chars.count { out.append("\n"); i += 1 }
                } else { out.append(ch); i += 1 }
            case "/":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            depth += 1; i += 2
                        } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            depth -= 1; i += 2
                        } else { i += 1 }
                    }
                    out.append(" ")
                } else { out.append(ch); i += 1 }
            default:
                out.append(ch); i += 1
            }
        }
        return out
    }
}

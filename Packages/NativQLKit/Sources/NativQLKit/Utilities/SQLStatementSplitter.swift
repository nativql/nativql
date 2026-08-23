/// Splits multi-statement SQL on top-level semicolons only, respecting
/// '...' strings, "..." identifiers, -- line comments, /* */ block comments
/// (with nesting), and $$ / $tag$ dollar-quoting (PostgreSQL).
///
/// Limitations: backslash escapes inside strings are honored (MySQL-style);
/// PostgreSQL standard-conforming strings are unaffected except for the
/// pathological trailing-backslash-before-quote case.
public enum SQLStatementSplitter {
    public static func split(_ sql: String) -> [String] {
        let chars = Array(sql)
        var statements: [String] = []
        var current = ""
        var i = 0

        func emit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { statements.append(trimmed) }
            current = ""
        }

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'":
                current.append(ch); i += 1
                i = scanQuoted(chars, from: i, terminator: "'", into: &current)
            case "\"":
                current.append(ch); i += 1
                i = scanQuoted(chars, from: i, terminator: "\"", into: &current)
            case "$":
                if let tag = dollarTag(at: chars, from: i) {
                    for c in tag { current.append(c) }
                    i += tag.count
                    i = scanDollarQuoted(chars, from: i, closingTag: tag, into: &current)
                } else {
                    current.append(ch); i += 1
                }
            case "-":
                if i + 1 < chars.count, chars[i + 1] == "-" {
                    while i < chars.count {
                        current.append(chars[i])
                        let atNewline = chars[i] == "\n"
                        i += 1
                        if atNewline { break }
                    }
                } else {
                    current.append(ch); i += 1
                }
            case "/":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    current.append("/"); current.append("*"); i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        current.append(chars[i])
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            current.append("*"); depth += 1; i += 2
                        } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            current.append("/"); depth -= 1; i += 2
                        } else {
                            i += 1
                        }
                    }
                } else {
                    current.append(ch); i += 1
                }
            case ";":
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current = ""
                } else {
                    current.append(ch)
                    emit()
                }
                i += 1
            default:
                current.append(ch); i += 1
            }
        }
        emit()
        return statements
    }

    /// Scans until the closing quote (inclusive). Handles doubled quotes ('')
    /// and backslash escapes. Returns the index AFTER the closing quote,
    /// consuming no further characters (the caller must see any ';').
    static func scanQuoted(
        _ chars: [Character], from start: Int, terminator: Character, into out: inout String
    ) -> Int {
        var i = start
        while i < chars.count {
            let ch = chars[i]
            out.append(ch); i += 1
            if ch == "\\" {
                if i < chars.count { out.append(chars[i]); i += 1 }
            } else if ch == terminator {
                if i < chars.count, chars[i] == terminator {
                    out.append(chars[i]); i += 1   // doubled quote — keep scanning
                } else {
                    return i
                }
            }
        }
        return i
    }

    /// Returns "$$", "$tag$", or nil if this '$' doesn't start a dollar-quote.
    private static func dollarTag(at chars: [Character], from i: Int) -> String? {
        guard chars[i] == "$" else { return nil }
        var j = i + 1
        var tag = "$"
        while j < chars.count, chars[j] != "$" {
            let c = chars[j]
            guard c.isLetter || c.isNumber || c == "_" else { return nil }
            tag.append(c); j += 1
        }
        guard j < chars.count else { return nil }
        tag.append("$")
        return tag
    }

    private static func scanDollarQuoted(
        _ chars: [Character], from start: Int, closingTag: String, into out: inout String
    ) -> Int {
        let tag = Array(closingTag)
        var i = start
        while i < chars.count {
            if chars[i] == tag[0], i + tag.count <= chars.count,
               Array(chars[i..<i + tag.count]) == tag {
                for c in tag { out.append(c) }
                return i + tag.count
            }
            out.append(chars[i]); i += 1
        }
        return i
    }
}

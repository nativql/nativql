// MARK: - Identifier translation (Batch 6 review C1)
//
// Kit builders emit PostgreSQL-canonical double-quoted identifiers, but the
// MySQL executor passes `statement.sql` through COM_STMT_PREPARE verbatim and
// MySQL's default sql_mode lexes `"…"` as a string literal — so UI-driven
// edits die with ER_PARSE_ERROR (1064). This is the mirror of PostgreSQL's
// `?` → `$n` rewriter hook: a lexical pass over live SQL text only.
//
// The state machine reuses `MutationExecutor.placeholderCount`'s scanner:
// '…' strings (backslash escapes + '' doubling), `…` identifiers (`` doubling,
// no backslash escapes), `--` line comments (whitespace-gated per MySQL),
// `#` line comments, and non-nesting /* … */ block comments.

enum IdentifierTranslation {
    /// Rewrites every `"…"` span in live SQL text as a backtick-quoted
    /// identifier: the ANSI content is unescaped first (`""` → `"`), then
    /// re-escaped for MySQL (`\``  → ``` `` ```). String literals, backtick
    /// identifiers, and comments pass through byte-for-byte; an unterminated
    /// span is left verbatim rather than half-translated.
    static func translateQuotedIdentifiers(_ sql: String) -> String {
        let chars = Array(sql)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'":
                // MySQL string literal: backslash escapes + doubled quotes.
                out.append(ch)
                i += 1
                while i < chars.count {
                    out.append(chars[i])
                    if chars[i] == "\\" {
                        i += 1
                        if i < chars.count {
                            out.append(chars[i])
                            i += 1
                        }
                    } else if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" {
                            i += 2
                        } else {
                            i += 1
                            break
                        }
                    } else {
                        i += 1
                    }
                }
            case "\"":
                i = translateDoubleQuotedSpan(chars, from: i + 1, into: &out)
            case "`":
                // Quoted identifier: only doubling, backslash is literal.
                out.append(ch)
                i += 1
                while i < chars.count {
                    out.append(chars[i])
                    i += 1
                    if chars[i - 1] == "`" {
                        if i < chars.count, chars[i] == "`" {
                            out.append("`") // doubled: emit both, stay inside
                            i += 1
                        } else {
                            break // closing quote
                        }
                    }
                }
            case "-":
                // "--" starts a comment ONLY when followed by whitespace or
                // control character / end of input (MySQL rule).
                if i + 1 < chars.count, chars[i + 1] == "-",
                   i + 2 >= chars.count || chars[i + 2] == " "
                       || chars[i + 2] == "\t" || chars[i + 2] == "\n"
                       || chars[i + 2] == "\r" {
                    while i < chars.count, chars[i] != "\n" {
                        out.append(chars[i])
                        i += 1
                    }
                } else {
                    out.append(ch)
                    i += 1
                }
            case "#":
                while i < chars.count, chars[i] != "\n" {
                    out.append(chars[i])
                    i += 1
                }
            case "/":
                // Block comments do NOT nest in MySQL; first */ closes.
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out.append("/*")
                    i += 2
                    while i < chars.count {
                        if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            out.append("*/")
                            i += 2
                            break
                        }
                        out.append(chars[i])
                        i += 1
                    }
                } else {
                    out.append(ch)
                    i += 1
                }
            default:
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    /// Consumes a `"…"` span starting just after its opening quote, appending
    /// its backticked form to `out`; returns the index of the next unconsumed
    /// character. Doubled quotes unescape to one `"` before any embedded
    /// backticks are doubled for MySQL. An unterminated span re-emits the raw
    /// remainder so malformed input round-trips instead of half-translating.
    private static func translateDoubleQuotedSpan(
        _ chars: [Character],
        from start: Int,
        into out: inout String
    ) -> Int {
        var inner = ""
        var i = start
        var terminated = false

        while i < chars.count {
            if chars[i] == "\\" {
                // Backslash escape inside the quoted span: keep both bytes.
                inner.append(chars[i])
                i += 1
                if i < chars.count {
                    inner.append(chars[i])
                    i += 1
                }
            } else if chars[i] == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    inner.append("\"")
                    i += 2
                } else {
                    i += 1
                    terminated = true
                    break
                }
            } else {
                inner.append(chars[i])
                i += 1
            }
        }

        if terminated {
            out.append("`")
            out.append(inner.replacingOccurrences(of: "`", with: "``"))
            out.append("`")
        } else {
            out.append("\"")
            out.append(inner)
        }
        return i
    }
}

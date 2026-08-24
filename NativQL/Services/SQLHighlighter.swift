import AppKit

/// Lightweight regex-based SQL syntax highlighter.
///
/// Passes over the whole string are fine for editor-sized documents (≤100k
/// chars). Only `foregroundColor` is added; existing font attributes are
/// preserved so the editor's monospaced font stays intact.
enum SQLHighlighter {
    enum TokenKind: Equatable {
        case keyword
        case string
        case comment
        case number
        case quotedIdentifier
    }

    /// Statement-level keywords from the Batch 5 plan; matched case-insensitively.
    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
        "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "INSERT",
        "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP",
        "ALTER", "VIEW", "INDEX", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "NOT", "NULL", "DEFAULT", "DISTINCT", "AS", "AND", "OR", "IN", "IS",
        "LIKE", "BETWEEN", "UNION", "ALL", "CASE", "WHEN", "THEN", "ELSE",
        "END", "EXPLAIN", "ANALYZE", "BEGIN", "COMMIT", "ROLLBACK", "SHOW",
        "DESCRIBE", "USE", "TRUNCATE",
    ]

    private static let commentRegex = makeRegex("--[^\\n]*|/\\*[\\s\\S]*?(?:\\*/|$)")
    // Strings never cross a newline: SQL literals don't span lines here, and
    // bounding them keeps an apostrophe inside a comment ('don't') from
    // opening a phantom string that swallows following lines.
    private static let stringRegex = makeRegex("'(?:[^'\\n]|'')*'")
    private static let quotedIdentifierRegex = makeRegex("\"(?:[^\"]|\"\")*\"")
    private static let numberRegex = makeRegex("\\b\\d+(?:\\.\\d+)?\\b")
    private static let identifierRegex = makeRegex("[A-Za-z_][A-Za-z_0-9]*")

    private static let colors: [TokenKind: NSColor] = [
        .keyword: .controlAccentColor,
        .string: .systemOrange,
        .comment: .secondaryLabelColor,
        .number: .systemPurple,
        .quotedIdentifier: .systemTeal,
    ]

    /// Applies token colors to the given text storage in place.
    static func apply(to textStorage: NSTextStorage) {
        let text = textStorage.string
        guard (text as NSString).length > 0 else { return }

        // Strings are claimed before comments so a `--` inside a literal
        // (e.g. 'a -- b') can never swallow the rest of the line as a comment;
        // commentRanges() rescans past such literals so a genuine trailing
        // comment on the same line still colors.
        var claimed = ranges(of: .string, in: text)
        claim(&claimed, commentRanges(in: text, avoiding: claimed))
        claim(&claimed, unclaimed(ranges(of: .quotedIdentifier, in: text), avoiding: claimed))
        claim(&claimed, unclaimed(ranges(of: .number, in: text), avoiding: claimed))

        var tokens: [(range: NSRange, color: NSColor)] = []
        for range in claimed {
            tokens.append((range, color(for: range, in: text)))
        }
        for range in keywordRanges(in: text, avoiding: claimed) {
            tokens.append((range, colors[.keyword]!))
        }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        // Clear previous pass first so re-typed tokens never keep stale colors.
        textStorage.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: (text as NSString).length))
        for token in tokens {
            textStorage.addAttribute(.foregroundColor, value: token.color, range: token.range)
        }
    }

    /// Token color for tests and callers that need the palette without a range.
    static func color(for kind: TokenKind) -> NSColor {
        colors[kind]!
    }

    /// The color of a claimed (non-keyword) token, inferred from its source text.
    private static func color(for range: NSRange, in text: String) -> NSColor {
        let snippet = (text as NSString).substring(with: range)
        if snippet.hasPrefix("--") || snippet.hasPrefix("/*") {
            return colors[.comment]!
        }
        if snippet.hasPrefix("'") {
            return colors[.string]!
        }
        if snippet.hasPrefix("\"") {
            return colors[.quotedIdentifier]!
        }
        return colors[.number]!
    }

    // MARK: - Pure helpers (unit-testable)

    /// All token ranges of `kind` within `text`, in ascending order.
    static func ranges(of kind: TokenKind, in text: String) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch kind {
        case .comment:
            return commentRegex.matches(in: text, range: full).map(\.range)
        case .string:
            return stringRegex.matches(in: text, range: full).map(\.range)
        case .quotedIdentifier:
            return quotedIdentifierRegex.matches(in: text, range: full).map(\.range)
        case .number:
            return numberRegex.matches(in: text, range: full).map(\.range)
        case .keyword:
            return identifierRegex.matches(in: text, range: full)
                .filter { keywords.contains(ns.substring(with: $0.range).uppercased()) }
                .map(\.range)
        }
    }

    /// Keyword ranges that do not overlap any already-claimed range.
    static func keywordRanges(in text: String, avoiding reserved: [NSRange]) -> [NSRange] {
        unclaimed(ranges(of: .keyword, in: text), avoiding: reserved)
    }

    /// Comment ranges claimed after strings. A raw candidate that begins
    /// inside an already-claimed literal (`SELECT 'a -- b' -- tail`) is
    /// re-scanned from the literal's end so the genuine trailing comment is
    /// kept; candidates that merely intersect a claimed token are dropped.
    static func commentRanges(in text: String, avoiding claimed: [NSRange]) -> [NSRange] {
        let ns = text as NSString
        guard !claimed.isEmpty else { return ranges(of: .comment, in: text) }

        func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
            (a.intersection(b)?.length ?? 0) > 0
        }

        var results: [NSRange] = []
        for candidate in ranges(of: .comment, in: text) {
            if let container = claimed.first(where: { NSLocationInRange(candidate.location, $0) }) {
                let scanStart = NSMaxRange(container)
                guard scanStart < ns.length else { continue }
                let scanRange = NSRange(location: scanStart, length: ns.length - scanStart)
                for match in commentRegex.matches(in: text, range: scanRange) where !claimed.contains(where: { intersects($0, match.range) }) {
                    results.append(match.range)
                }
            } else if !claimed.contains(where: { intersects($0, candidate) }) {
                results.append(candidate)
            }
        }
        return results
    }

    private static func unclaimed(_ candidates: [NSRange], avoiding reserved: [NSRange]) -> [NSRange] {
        guard !reserved.isEmpty else { return candidates }
        return candidates.filter { range in
            !reserved.contains { other in
                (other.intersection(range)?.length ?? 0) > 0
            }
        }
    }

    private static func claim(_ claimed: inout [NSRange], _ additional: [NSRange]) {
        claimed.append(contentsOf: additional)
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

import Foundation
import NativQLKit

// MARK: - EXPLAIN tree parsing (Task D)
//
// MySQL 8 renders EXPLAIN output in two shapes:
// - plain `EXPLAIN …` returns the legacy tabular format (no tree) — the
//   driver therefore uses `EXPLAIN FORMAT=TREE` for non-analyze plans;
// - `EXPLAIN ANALYZE` / `EXPLAIN FORMAT=TREE` return a single-cell,
//   indentation-based tree:
//
//     -> Limit: 10 row(s)  (cost=23.8 rows=10) (actual time=0.0859..0.0998 rows=10 loops=1)
//         -> Nested loop inner join  (cost=23.8 rows=20) (actual time=0.0855..0.0988 rows=10 loops=1)
//             -> Sort: u.`name`  (cost=2.75 rows=25) (actual time=0.0574..0.0577 rows=7 loops=1)
//                 -> Table scan on u  (cost=2.75 rows=25) (actual time=0.0345..0.0387 rows=25 loops=1)
//             -> Filter: (o.amount > 20.00)  (cost=0.603 rows=0.8) (actual time=0.00521..0.00553 rows=1.43 loops=7)
//                 -> Index lookup on o using idx_user (user_id=u.id)  (cost=0.603 rows=2.4) (actual time=0.00473..0.00499 rows=2.14 loops=7)
//
// Parsing decisions (documented):
// - operation = the descriptive text before annotation groups, verbatim
//   (inline conditions like `(user_id=u.id)` stay part of it);
// - detail = the cost group verbatim without parentheses, e.g.
//   `cost=0.603 rows=2.4`; nil when the node carries none;
// - actualRows/actualTimeMilliseconds from the `actual time=A..B rows=R
//   loops=L` group; time is already milliseconds, R can be fractional
//   (per-loop average — rounded to nearest Int64);
// - a branch that never ran reports `(never executed)` instead of actuals,
//   which leaves both optional fields nil;
// - nesting follows 4-space indentation levels.

/// Recursive decoder for MySQL's EXPLAIN tree text into Kit `ExplainPlanNode`s.
enum ExplainParser {
    enum ParseError: Error, CustomStringConvertible {
        case emptyOutput

        var description: String {
            switch self {
            case .emptyOutput: return "EXPLAIN output carried no tree lines"
            }
        }
    }

    /// One flattened tree line before assembly.
    struct LineFacts {
        var depth: Int
        var operation: String
        /// Verbatim cost annotation, e.g. `cost=2.75 rows=25`.
        var costDetail: String?
        var actualRows: Int64?
        var actualTimeMilliseconds: Double?
    }

    /// Parses the full single-column cell into its root plan node.
    static func parse(_ text: String) throws -> ExplainPlanNode {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(facts(ofLine:))
        guard let root = lines.first else {
            throw ParseError.emptyOutput
        }

        var index = 0
        // MySQL trees have exactly one root; extra depth-0 lines would be
        // siblings, and only the first is returned.
        return assemble(lines: lines, index: &index, depth: root.depth) ?? ExplainPlanNode(operation: "Unknown")
    }

    // MARK: - Line scanning

    private static func facts(ofLine rawLine: Substring) -> LineFacts? {
        let line = String(rawLine)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 }
            else if ch == "\t" { indent += 4 }
            else { break }
        }
        let body = line.dropFirst(indent)
        guard body.hasPrefix("->") else { return nil }
        var remainder = Substring(body.dropFirst(2))
        if remainder.hasPrefix(" ") { remainder = remainder.dropFirst() }

        // Strip recognized annotation groups off the tail (balanced parens).
        // Inline conditions such as `(user_id=u.id)` are not annotations and
        // stay part of the operation text.
        var costDetail: String?
        var actualRows: Int64?
        var actualTimeMilliseconds: Double?
        while true {
            // Groups are separated by whitespace ("…rows=10) (actual …)"), so
            // re-trim before testing for another tail group.
            while let last = remainder.last, last == " " || last == "\t" {
                remainder = remainder.dropLast()
            }
            guard remainder.hasSuffix(")"),
                  let open = matchingOpenParen(in: remainder),
                  let group = groupContent(in: remainder, openParen: open),
                  Self.isAnnotationGroup(group) else {
                break
            }
            applyAnnotation(group, into: &costDetail, rows: &actualRows, ms: &actualTimeMilliseconds)
            remainder = remainder[..<open]
        }

        return LineFacts(
            depth: indent / 4,
            operation: String(remainder).trimmingCharacters(in: .whitespaces),
            costDetail: costDetail,
            actualRows: actualRows,
            actualTimeMilliseconds: actualTimeMilliseconds
        )
    }

    /// Index of the "(" matching the final ")" of `text`, or nil when the
    /// trailing parenthesis run is unbalanced.
    private static func matchingOpenParen(in text: Substring) -> String.Index? {
        var depth = 0
        for i in text.indices.reversed() {
            switch text[i] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    /// Text between the given "(" and the final ")" of `text`.
    private static func groupContent(in text: Substring, openParen: String.Index) -> String? {
        guard openParen < text.index(before: text.endIndex) else { return nil }
        return String(text[text.index(after: openParen)..<text.index(before: text.endIndex)])
    }

    /// Only these tails are annotations; anything else belongs to the
    /// operation description and stops stripping.
    private static func isAnnotationGroup(_ group: String) -> Bool {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("cost=")
            || trimmed.hasPrefix("actual time=")
            || trimmed == "never executed"
    }

    private static func applyAnnotation(
        _ group: String,
        into costDetail: inout String?,
        rows: inout Int64?,
        ms: inout Double?
    ) {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        if trimmed == "never executed" {
            return // branch never ran: actuals stay nil
        }
        if trimmed.hasPrefix("cost=") {
            costDetail = trimmed
            return
        }
        // "actual time=A..B rows=R loops=L"
        for token in trimmed.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "time":
                // Total time is the second half of "A..B".
                if let total = pair[1].split(separator: "..").last, let value = Double(total) {
                    ms = value
                }
            case "rows":
                // Per-loop averages can be fractional ("rows=1.43").
                if let double = Double(pair[1]) {
                    rows = Int64(double.rounded())
                }
            default:
                break // loops=… and friends are ignored
            }
        }
    }

    // MARK: - Tree assembly

    /// Recursively builds nodes: consumes `lines[index]` at `depth`, then any
    /// deeper lines as children. Depth jumps are tolerated by treating an
    /// over-indented line as a child of the current level.
    private static func assemble(
        lines: [LineFacts],
        index: inout Int,
        depth: Int
    ) -> ExplainPlanNode? {
        guard index < lines.count, lines[index].depth >= depth else { return nil }

        let fact = lines[index]
        index += 1

        var children: [ExplainPlanNode] = []
        while index < lines.count, lines[index].depth > depth {
            guard let child = assemble(lines: lines, index: &index, depth: fact.depth + 1) else {
                break
            }
            children.append(child)
        }

        return ExplainPlanNode(
            operation: fact.operation,
            detail: fact.costDetail,
            actualRows: fact.actualRows,
            actualTimeMilliseconds: fact.actualTimeMilliseconds,
            children: children
        )
    }
}

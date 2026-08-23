import Foundation
import Logging
import NativQLKit
import PostgresNIO

// MARK: - ANSI placeholder rewriting (Task D)
//
// The app's mutation layer emits statements with ANSI `?` placeholders;
// PostgreSQL's extended protocol needs `$n` positional parameters. The
// rewriter below mirrors Kit `SQLStatementSplitter`'s scanning (same quote,
// comment, and dollar-quote rules) so a `?` is only ever rewritten when it
// sits in live SQL text — never inside '…' strings, "…" identifiers,
// -- line comments, /* … */ block comments (nested), or $tag$ dollar quotes.

enum PlaceholderRewriter {
    /// Rewrites every unquoted `?` into the next `$n`. Returns the rewritten
    /// SQL plus how many placeholders were found (the required bind count).
    static func rewrite(_ sql: String) -> (text: String, placeholderCount: Int) {
        let chars = Array(sql)
        var out = ""
        var count = 0
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'", "\"":
                out.append(ch)
                i += 1
                i = scanQuoted(chars, from: i, terminator: ch, into: &out)
            case "$":
                if let tag = dollarTag(at: chars, from: i) {
                    out.append(contentsOf: tag)
                    i += tag.count
                    i = scanDollarQuoted(chars, from: i, closingTag: tag, into: &out)
                } else {
                    out.append(ch)
                    i += 1
                }
            case "-":
                if i + 1 < chars.count, chars[i + 1] == "-" {
                    while i < chars.count {
                        out.append(chars[i])
                        let atNewline = chars[i] == "\n"
                        i += 1
                        if atNewline { break }
                    }
                } else {
                    out.append(ch)
                    i += 1
                }
            case "/":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out.append("/*")
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            out.append("/*")
                            depth += 1
                            i += 2
                        } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            out.append("*/")
                            depth -= 1
                            i += 2
                        } else {
                            out.append(chars[i])
                            i += 1
                        }
                    }
                } else {
                    out.append(ch)
                    i += 1
                }
            case "?":
                count += 1
                out.append("$\(count)")
                i += 1
            default:
                out.append(ch)
                i += 1
            }
        }
        return (out, count)
    }

    /// Same contract as `SQLStatementSplitter.scanQuoted`: consumes through the
    /// closing quote (honoring `''` doubling and backslash escapes).
    private static func scanQuoted(
        _ chars: [Character], from start: Int, terminator: Character, into out: inout String
    ) -> Int {
        var i = start
        while i < chars.count {
            let ch = chars[i]
            out.append(ch)
            i += 1
            if ch == "\\" {
                if i < chars.count { out.append(chars[i]); i += 1 }
            } else if ch == terminator {
                if i < chars.count, chars[i] == terminator {
                    out.append(chars[i])
                    i += 1
                } else {
                    return i
                }
            }
        }
        return i
    }

    /// Returns "$$", "$tag$", or nil for a '$' that doesn't start a dollar-quote.
    private static func dollarTag(at chars: [Character], from i: Int) -> String? {
        guard chars[i] == "$" else { return nil }
        var j = i + 1
        var tag = "$"
        while j < chars.count, chars[j] != "$" {
            let c = chars[j]
            guard c.isLetter || c.isNumber || c == "_" else { return nil }
            tag.append(c)
            j += 1
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
                out.append(contentsOf: tag)
                return i + tag.count
            }
            out.append(chars[i])
            i += 1
        }
        return i
    }
}

// MARK: - Transactional batch execution (Task D)

/// Runs a `MutationStatement`'s batches inside ONE transaction on the given
/// connection: BEGIN → per-batch positional execution with command-tag row
/// counting → COMMIT; any failure triggers ROLLBACK (best effort) and surfaces
/// `.mutationFailed` carrying the server's message.
enum MutationExecutor {
    static func execute(
        _ statement: MutationStatement,
        on connection: PostgresConnection,
        logger: Logger
    ) async throws -> Int64 {
        let rewritten = PlaceholderRewriter.rewrite(statement.sql)

        for (index, batch) in statement.batches.enumerated()
        where batch.count != rewritten.placeholderCount {
            throw DriverError.mutationFailed(
                "batch \(index) binds \(batch.count) value(s) but the statement "
                    + "has \(rewritten.placeholderCount) placeholder(s)"
            )
        }

        do {
            try await run("BEGIN", on: connection, logger: logger)

            var totalAffectedRows: Int64 = 0
            for batch in statement.batches {
                var binds = PostgresBindings()
                for value in batch {
                    if let data = SQLValueMapper.bindable(value) {
                        binds.append(data)
                    } else {
                        binds.appendNull()
                    }
                }

                // The EventLoopFuture overload is the one surfacing the
                // command tag ("UPDATE 3") needed for affected-row counts.
                let query = PostgresQuery(unsafeSQL: rewritten.text, binds: binds)
                let result: PostgresQueryResult = try await connection.query(query, logger: logger).get()
                if ["INSERT", "UPDATE", "DELETE"].contains(result.metadata.command),
                   let rowCount = result.metadata.rows {
                    totalAffectedRows += Int64(rowCount)
                }
            }

            try await run("COMMIT", on: connection, logger: logger)
            return totalAffectedRows
        } catch {
            // Roll back best effort — the original failure is what matters.
            try? await run("ROLLBACK", on: connection, logger: logger)
            throw Self.failure(error)
        }
    }

    // MARK: - Internals

    private static func run(_ sql: String, on connection: PostgresConnection, logger: Logger) async throws {
        _ = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger).collect()
    }

    /// Cancellation stays `.cancelled` (client-side `.queryCancelled` code or
    /// the server's SQLSTATE 57014 from `pg_cancel_backend`); everything else
    /// becomes `.mutationFailed` with the server diagnostics verbatim.
    private static func failure(_ error: Error) -> DriverError {
        if error is CancellationError { return .cancelled }
        if let psql = error as? PSQLError {
            if psql.code == .queryCancelled || PostgresDriver.isSQLStateCancelled(psql) {
                return .cancelled
            }
            if let info = psql.serverInfo {
                var parts: [String] = []
                if let message = info[.message] { parts.append(message) }
                if let detail = info[.detail] { parts.append(detail) }
                if let hint = info[.hint] { parts.append(hint) }
                if !parts.isEmpty { return .mutationFailed(parts.joined(separator: "\n")) }
            }
        }
        return .mutationFailed(String(reflecting: error))
    }
}

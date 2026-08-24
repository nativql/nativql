import Foundation
import Logging
import NativQLKit
import MySQLNIO

// MARK: - Transactional batch execution (Task D)
//
// Unlike PostgreSQL's extended protocol, MySQLNIO binds `?` placeholders
// natively (COM_STMT_PREPARE/EXECUTE are positional) — no `$n` rewriter is
// needed. But `statement.sql` CANNOT go to the server verbatim either: Kit
// builders emit PostgreSQL-canonical `"ident"` spans, which MySQL's default
// sql_mode lexes as string literals (ER_PARSE_ERROR / 1064). So before
// binding, double-quoted identifier spans are translated to backtick quoting
// (`IdentifierTranslation`) — the mirror of PG's rewriter hook.
//
// The placeholder counter below exists for bind validation only: it must
// agree with MySQLNIO's own lexer about WHERE a `?` is live SQL text, so it
// mirrors MySQL lexing rules — '…' strings ('' doubling, backslash escapes),
// "…" strings (same rules), `…` identifiers (`` doubling, no backslash
// escapes), `--` line comments (which require trailing whitespace per
// MySQL), `#` line comments, and non-nesting /* … */ block comments.

/// Runs a `MutationStatement`'s batches inside ONE transaction on the given
/// connection: BEGIN → per-batch positional execution accumulating affected
/// rows → COMMIT; any failure triggers ROLLBACK (best effort) and surfaces
/// `.mutationFailed` carrying the server's message.
enum MutationExecutor {
    /// Counts unquoted `?` placeholders under MySQL lexing rules.
    static func placeholderCount(in sql: String) -> Int {
        let chars = Array(sql)
        var count = 0
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "'", "\"":
                // MySQL string literals: backslash escapes + doubled quotes.
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" {
                        i += 2
                    } else if chars[i] == ch {
                        if i + 1 < chars.count, chars[i + 1] == ch {
                            i += 2
                        } else {
                            i += 1
                            break
                        }
                    } else {
                        i += 1
                    }
                }
            case "`":
                // Quoted identifiers: only doubling, backslash is literal.
                i += 1
                while i < chars.count {
                    if chars[i] == "`" {
                        if i + 1 < chars.count, chars[i + 1] == "`" {
                            i += 2
                        } else {
                            i += 1
                            break
                        }
                    } else {
                        i += 1
                    }
                }
            case "-":
                // MySQL: "--" starts a comment ONLY when followed by
                // whitespace/control or end of input.
                if i + 1 < chars.count, chars[i + 1] == "-",
                   i + 2 >= chars.count || chars[i + 2] == " "
                       || chars[i + 2] == "\t" || chars[i + 2] == "\n"
                       || chars[i + 2] == "\r" {
                    i += 2
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                } else {
                    i += 1
                }
            case "#":
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "/":
                // Block comments do NOT nest in MySQL; first */ closes.
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    while i < chars.count {
                        if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            i += 2
                            break
                        }
                        i += 1
                    }
                } else {
                    i += 1
                }
            case "?":
                count += 1
                i += 1
            default:
                i += 1
            }
        }
        return count
    }

    static func execute(
        _ statement: MutationStatement,
        on connection: MySQLConnection,
        logger: Logger
    ) async throws -> Int64 {
        // Kit's PG-canonical "ident" spans → MySQL backtick quoting.
        let sql = IdentifierTranslation.translateQuotedIdentifiers(statement.sql)
        let placeholders = Self.placeholderCount(in: sql)

        for (index, batch) in statement.batches.enumerated()
        where batch.count != placeholders {
            throw DriverError.mutationFailed(
                "batch \(index) binds \(batch.count) value(s) but the statement "
                    + "has \(placeholders) placeholder(s)"
            )
        }

        do {
            try await run("BEGIN", on: connection, logger: logger)

            var totalAffectedRows: Int64 = 0
            for batch in statement.batches {
                let binds = batch.map(SQLValueMapper.bindable)
                var delta: Int64 = 0
                _ = try await connection.query(
                    sql,
                    binds,
                    onMetadata: { metadata in
                        delta = Int64(clamping: metadata.affectedRows)
                    }
                ).get()
                totalAffectedRows += delta
            }

            try await run("COMMIT", on: connection, logger: logger)
            logger.trace("mutation committed", metadata: ["affectedRows": "\(totalAffectedRows)"])
            return totalAffectedRows
        } catch {
            // Roll back best effort — the original failure is what matters.
            try? await run("ROLLBACK", on: connection, logger: logger)
            throw Self.failure(error)
        }
    }

    // MARK: - Internals

    private static func run(_ sql: String, on connection: MySQLConnection, logger: Logger) async throws {
        _ = try await connection.simpleQuery(sql).get()
    }

    /// Cancellation stays `.cancelled`; every server rejection becomes
    /// `.mutationFailed` with the server message verbatim.
    static func failure(_ error: Error) -> DriverError {
        if error is CancellationError { return .cancelled }
        switch error {
        case MySQLError.server(let packet):
            return .mutationFailed(packet.errorMessage)
        case MySQLError.duplicateEntry(let message):
            return .mutationFailed(message)
        case MySQLError.invalidSyntax(let message):
            return .mutationFailed(message)
        default:
            return .mutationFailed(String(reflecting: error))
        }
    }
}

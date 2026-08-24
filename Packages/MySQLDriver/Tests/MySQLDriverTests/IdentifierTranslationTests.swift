import XCTest
@testable import MySQLDriver

/// Double-quoted → backtick identifier translation (Batch 6 review C1).
///
/// Kit builders emit PostgreSQL-canonical `"ident"` spans; MySQL's default
/// sql_mode lexes those as string literals, so UI-driven mutations die with
/// ER_PARSE_ERROR (1064). Translation must touch ONLY live-SQL spans — never
/// '…' string literals or comments.
final class IdentifierTranslationUnitTests: XCTestCase {
    func testTranslatesQualifiedUpdateStatement() {
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(
                #"UPDATE "public"."users" SET "email" = ? WHERE "id" = ?"#
            ),
            "UPDATE `public`.`users` SET `email` = ? WHERE `id` = ?"
        )
    }

    func testTranslatesPlainAndEmptyIdentifiers() {
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers(#"SELECT "name" FROM "t""#),
                       "SELECT `name` FROM `t`")
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers(#""""#), "``")
    }

    func testUnescapesDoubledQuotesBeforeBacktickEscaping() {
        // ANSI "" → literal ", which needs no escaping inside backticks.
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers(#""a""b""#),
                       #"`a"b`"#)
    }

    func testEscapesEmbeddedBackticksAfterUnescaping() {
        // A raw backtick inside a double-quoted span is legal ANSI content;
        // it must be doubled for MySQL.
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers("\"we`ird\""),
                       "`we``ird`")
    }

    func testStringLiteralsPassThroughUntouched() {
        // Double quotes inside single-quoted strings stay verbatim.
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(#"SELECT '"not ident"' FROM t"#),
            #"SELECT '"not ident"' FROM t"#
        )
        // MySQL backslash escapes and '' doubling stay inside the literal.
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(#"UPDATE t SET a = 'don\'t "x"' WHERE b = ?"#),
            #"UPDATE t SET a = 'don\'t "x"' WHERE b = ?"#
        )
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(#"SELECT 'say ""hi""' FROM t"#),
            #"SELECT 'say ""hi""' FROM t"#
        )
    }

    func testCommentsPassThroughUntouched() {
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers("-- \"hint\" stays\nSELECT \"a\""),
            "-- \"hint\" stays\nSELECT `a`"
        )
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers("# \"note\"\nSELECT \"a\""),
            "# \"note\"\nSELECT `a`"
        )
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(/*non-nesting*/ "/* \"doc\" */ SELECT \"a\" /* trailing */"),
            "/* \"doc\" */ SELECT `a` /* trailing */"
        )
        // "--" without trailing whitespace is subtraction per MySQL, so the
        // following span is still live SQL… and the next one translates.
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers(#"SELECT a--b FROM "t""#),
            #"SELECT a--b FROM `t`"#
        )
    }

    func testBacktickIdentifiersPassThroughUntouched() {
        // A " inside backticks is ordinary content — no translation.
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers("SELECT `we\"ird` FROM t"),
            "SELECT `we\"ird` FROM t"
        )
        // Doubled backticks stay doubled and opaque.
        XCTAssertEqual(
            IdentifierTranslation.translateQuotedIdentifiers("SELECT `a``b\"c` FROM t"),
            "SELECT `a``b\"c` FROM t"
        )
    }

    func testUnterminatedSpanIsLeftVerbatim() {
        // Malformed input must round-trip rather than half-translate.
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers(#"SELECT "oops"#),
                       #"SELECT "oops"#)
    }

    func testNoDoubleQuotesMeansUnchanged() {
        let sql = "UPDATE t SET a = ? WHERE `b` = ? -- done\n"
        XCTAssertEqual(IdentifierTranslation.translateQuotedIdentifiers(sql), sql)
    }
}

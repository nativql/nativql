import XCTest
@testable import NativQL

final class SQLHighlighterTests: XCTestCase {
    private func firstRange(_ kind: SQLHighlighter.TokenKind, in text: String) -> NSRange {
        let ranges = SQLHighlighter.ranges(of: kind, in: text)
        return ranges.first ?? NSRange(location: NSNotFound, length: 0)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    // MARK: - Keywords

    func testKeywordsMatchCaseInsensitively() {
        let text = "select name from users"
        XCTAssertEqual(firstRange(.keyword, in: text), range(of: "select", in: text))
        XCTAssertEqual(SQLHighlighter.ranges(of: .keyword, in: text).count, 2)
    }

    func testNonKeywordIdentifiersAreIgnored() {
        let text = "SELECTX banana"
        XCTAssertTrue(SQLHighlighter.ranges(of: .keyword, in: text).isEmpty)
    }

    // MARK: - Strings & identifiers

    func testStringWithDoubledQuoteIsOneToken() {
        let text = #"INSERT INTO t VALUES ('it''s ok');"#
        let stringRanges = SQLHighlighter.ranges(of: .string, in: text)
        XCTAssertEqual(stringRanges, [range(of: "'it''s ok'", in: text)])
    }

    func testDoubleQuotedIdentifierIsTokenized() {
        let text = #"SELECT "order" FROM t"#
        XCTAssertEqual(
            SQLHighlighter.ranges(of: .quotedIdentifier, in: text),
            [range(of: #""order""#, in: text)]
        )
    }

    // MARK: - Comments & precedence

    func testLineCommentAndBlockCommentRanges() {
        let text = "-- hi\nSELECT /* mid */ 1"
        let comments = SQLHighlighter.ranges(of: .comment, in: text)
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0], range(of: "-- hi", in: text))
        XCTAssertEqual(comments[1], range(of: "/* mid */", in: text))
    }

    func testUnterminatedBlockCommentExtendsToEnd() {
        let text = "SELECT 1 /* trailing"
        let comment = firstRange(.comment, in: text)
        XCTAssertEqual(comment.location, range(of: "/* trailing", in: text).location)
        XCTAssertEqual(comment.upperBound, (text as NSString).length)
    }

    func testKeywordsInsideCommentsAndStringsDoNotColorAsKeywords() {
        let text = "-- SELECT hidden\nx := 'SELECT too'"
        XCTAssertTrue(SQLHighlighter.keywordRanges(in: text, avoiding: claimedTokens(in: text)).isEmpty)
    }

    func testNumbersInsideStringsAreNotNumbers() {
        let text = "'abc123'"
        XCTAssertTrue(SQLHighlighter.ranges(of: .number, in: text).isEmpty)
    }

    private func claimedTokens(in text: String) -> [NSRange] {
        SQLHighlighter.ranges(of: .comment, in: text)
            + SQLHighlighter.ranges(of: .string, in: text)
            + SQLHighlighter.ranges(of: .quotedIdentifier, in: text)
    }

    // MARK: - apply(to:)

    func testApplyRemovesStaleColorsWhenTokensDisappear() {
        let storage = NSTextStorage(string: "SELECT 1")
        SQLHighlighter.apply(to: storage)
        let keywordLocation = range(of: "SELECT", in: storage.string).location
        XCTAssertNotNil(storage.attribute(.foregroundColor, at: keywordLocation, effectiveRange: nil))

        storage.mutableString.setString("plain words only")
        SQLHighlighter.apply(to: storage)

        for index in 0..<storage.length {
            XCTAssertNil(
                storage.attribute(.foregroundColor, at: index, effectiveRange: nil),
                "character \(index) kept a stale token color"
            )
        }
    }

    func testApplyAddsForegroundOnlyAndKeepsFont() {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "SELECT 'a' -- c",
            attributes: [.font: baseFont]
        ))
        SQLHighlighter.apply(to: storage)

        for needle in ["SELECT", "'a'", "-- c"] {
            let location = range(of: needle, in: storage.string).location
            let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil)
            XCTAssertNotNil(color, "'\(needle)' should receive a token color")
        }
        let keywordLocation = range(of: "SELECT", in: storage.string).location
        XCTAssertEqual(storage.attribute(.font, at: keywordLocation, effectiveRange: nil) as? NSFont, baseFont)
    }
}

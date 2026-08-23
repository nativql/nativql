import XCTest
@testable import NativQLKit

final class EditabilityRulesTests: XCTestCase {
    func testSimpleBrowsedTableIsEditable() {
        let decision = EditabilityRules.evaluate(
            source: .tableBrowse, hasPrimaryKey: true
        )
        XCTAssertEqual(decision, .editable)
    }

    func testBrowseWithoutPKIsLocked() {
        let decision = EditabilityRules.evaluate(source: .tableBrowse, hasPrimaryKey: false)
        XCTAssertEqual(
            decision,
            .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        )
    }

    func testJoinedQueryIsLocked() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: false, usesAggregation: true),
            hasPrimaryKey: true
        )
        XCTAssertEqual(
            decision,
            .readOnly(reason: "Only single-table queries without joins or aggregation are editable.")
        )
    }

    func testSingleTablePlainQueryIsEditable() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: true, usesAggregation: false),
            hasPrimaryKey: true
        )
        XCTAssertEqual(decision, .editable)
    }

    func testAggregateQueryIsLocked() {
        let decision = EditabilityRules.evaluate(
            source: .query(singleTable: true, usesAggregation: true),
            hasPrimaryKey: true
        )
        XCTAssertTrue(isReadOnly(decision))
    }

    private func isReadOnly(_ d: EditabilityDecision) -> Bool {
        if case .readOnly = d { return true }
        return false
    }
}

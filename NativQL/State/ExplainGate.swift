import Foundation
import NativQLKit

/// Pure rules deciding whether the Explain affordance is enabled and which SQL
/// it would run. Kept side-effect-free for tests.
enum ExplainGate {
    /// Enabled when the active tab shows a select-shaped result or its editor
    /// text starts with SELECT/WITH.
    static func canRun(activeTab: QueryTab?) -> Bool {
        guard let tab = activeTab else { return false }
        if tab.result.value?.statementType == .select { return true }
        return explainableSQL(for: tab) != nil
    }

    /// The statement EXPLAIN would run: trimmed editor text when it starts
    /// with SELECT/WITH (any case), otherwise a whole-table probe for browse
    /// tabs; nil when nothing is explainable.
    static func explainableSQL(for tab: QueryTab) -> String? {
        let trimmed = tab.editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("SELECT") || upper.hasPrefix("WITH") {
            return trimmed
        }
        guard let browse = tab.browse else { return nil }
        let ref = browse.ref
        if let schema = ref.schema {
            return "SELECT * FROM \"\(schema)\".\"\(ref.name)\""
        }
        return "SELECT * FROM \"\(ref.name)\""
    }
}

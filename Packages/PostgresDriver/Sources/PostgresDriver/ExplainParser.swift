import Foundation
import NativQLKit

// MARK: - EXPLAIN (FORMAT JSON) parsing (Task D)
//
// PostgreSQL renders `EXPLAIN (FORMAT JSON)` as a single-cell JSON document:
//
//     [ { "Plan": { "Node Type": "Seq Scan", …, "Plans": [ …recursive… ] },
//         "Planning Time": 0.1, "Execution Time": 0.2 } ]
//
// This parser is pure (String in, ExplainPlanNode out) so unit tests can feed
// realistic fixtures without a live server. Values that only exist under
// `ANALYZE` ("Actual Rows", "Actual Total Time") stay optional.

/// Recursive decoder for PG's EXPLAIN JSON shape into Kit `ExplainPlanNode`s.
enum ExplainParser {
    enum ParseError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case missingPlan

        var description: String {
            switch self {
            case .invalidJSON(let reason): return "invalid EXPLAIN JSON: \(reason)"
            case .missingPlan: return "EXPLAIN JSON carries no root \"Plan\" object"
            }
        }
    }

    /// Plan attributes surfaced (in this order) as the node's human-readable
    /// `detail`, joined with ", ". Structural keys (costs, widths, loops,
    /// blocks) are intentionally omitted — the UI shows operation + the
    /// distinguishing extras.
    private static let detailKeys = [
        "Relation Name",
        "Alias",
        "Index Name",
        "Index Cond",
        "Recheck Cond",
        "Filter",
        "Rows Removed by Filter",
        "Hash Cond",
        "Join Filter",
        "Merge Cond",
        "Rows Removed by Join Filter",
        "Sort Key",
        "Sort Method",
        "Group Key",
        "CTE Name",
        "Function Name",
        "Subquery Name",
        "Rows Removed by Index Recheck",
        "Rows Removed by Hash Filter",
    ]

    /// Parses the full single-element-array document into its root node.
    static func parse(_ jsonText: String) throws -> ExplainPlanNode {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: Data(jsonText.utf8))
        } catch {
            throw ParseError.invalidJSON(String(describing: error))
        }
        guard let array = raw as? [Any], let top = array.first as? [String: Any],
              let plan = top["Plan"] as? [String: Any] else {
            throw ParseError.missingPlan
        }
        return self.node(from: plan)
    }

    private static func node(from object: [String: Any]) -> ExplainPlanNode {
        var detailParts: [String] = []
        for key in detailKeys {
            if let value = object[key] {
                detailParts.append("\(key): \(render(value))")
            }
        }

        let children = (object["Plans"] as? [[String: Any]] ?? []).map(self.node(from:))

        return ExplainPlanNode(
            operation: object["Node Type"] as? String ?? "Unknown",
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: ", "),
            actualRows: (object["Actual Rows"] as? NSNumber).map { $0.int64Value },
            actualTimeMilliseconds: (object["Actual Total Time"] as? NSNumber)?.doubleValue,
            children: children
        )
    }

    private static func render(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map(self.render).joined(separator: ", ")
        default: return String(describing: value)
        }
    }
}

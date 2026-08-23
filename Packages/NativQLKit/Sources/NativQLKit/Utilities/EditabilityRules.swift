public enum EditabilitySource: Sendable {
    case tableBrowse
    case query(singleTable: Bool, usesAggregation: Bool)
}

public enum EditabilityDecision: Equatable, Sendable {
    case editable
    case readOnly(reason: String)
}

public enum EditabilityRules {
    public static func evaluate(
        source: EditabilitySource,
        hasPrimaryKey: Bool
    ) -> EditabilityDecision {
        switch source {
        case .tableBrowse:
            return hasPrimaryKey
                ? .editable
                : .readOnly(reason: "Table has no primary key, so rows can't be updated safely.")
        case .query(let singleTable, let usesAggregation):
            guard singleTable, !usesAggregation else {
                return .readOnly(
                    reason: "Only single-table queries without joins or aggregation are editable."
                )
            }
            return hasPrimaryKey
                ? .editable
                : .readOnly(reason: "Underlying table has no primary key.")
        }
    }
}

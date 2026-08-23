public struct ExplainPlanNode: Sendable {
    public var operation: String
    public var detail: String?
    public var actualRows: Int64?
    public var actualTimeMilliseconds: Double?
    public var children: [ExplainPlanNode]

    public init(
        operation: String,
        detail: String? = nil,
        actualRows: Int64? = nil,
        actualTimeMilliseconds: Double? = nil,
        children: [ExplainPlanNode] = []
    ) {
        self.operation = operation
        self.detail = detail
        self.actualRows = actualRows
        self.actualTimeMilliseconds = actualTimeMilliseconds
        self.children = children
    }
}

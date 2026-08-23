public enum StatementType: String, Sendable {
    case select, insert, update, delete, ddl, explain, transactionControl, other
}

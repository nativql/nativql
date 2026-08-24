import Foundation
import SwiftData

/// One executed statement in the query history (Batch 7). `kind` mirrors the
/// originating surface ("query" for editor runs); `ok` records success/failure.
@Model
final class QueryHistoryEntry {
    var sql: String
    var connectionName: String
    var kind: String
    var executedAt: Date
    var durationMs: Double
    var ok: Bool

    init(
        sql: String,
        connectionName: String,
        kind: String,
        executedAt: Date = .init(),
        durationMs: Double,
        ok: Bool
    ) {
        self.sql = sql
        self.connectionName = connectionName
        self.kind = kind
        self.executedAt = executedAt
        self.durationMs = durationMs
        self.ok = ok
    }
}

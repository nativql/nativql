import Foundation
import SwiftData

/// Where a recorded statement came from.
enum HistoryKind: String {
    case query
    case browse
}

/// Persists one history entry per executed run, keeping the table capped at
/// `capacity` rows (oldest evicted first). Whitespace-only SQL is never stored.
@MainActor
final class HistoryRecorder {
    static let capacity = 500

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(
        sql: String,
        connectionName: String,
        kind: HistoryKind,
        executedAt: Date = .init(),
        ok: Bool,
        durationMs: Double
    ) {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        context.insert(QueryHistoryEntry(
            sql: sql,
            connectionName: connectionName,
            kind: kind.rawValue,
            executedAt: executedAt,
            durationMs: durationMs,
            ok: ok
        ))
        trimToCapacity()
        // Persist immediately instead of relying on mainContext autosave so an
        // abrupt quit cannot drop the just-recorded entry.
        try? context.save()
    }

    /// Deletes oldest entries beyond the cap; runs on every insert so the
    /// table can never grow unbounded even when seeded externally.
    private func trimToCapacity() {
        do {
            let count = try context.fetchCount(FetchDescriptor<QueryHistoryEntry>())
            guard count > Self.capacity else { return }
            var descriptor = FetchDescriptor<QueryHistoryEntry>(
                sortBy: [SortDescriptor(\.executedAt)]
            )
            descriptor.fetchLimit = count - Self.capacity
            for stale in try context.fetch(descriptor) {
                context.delete(stale)
            }
        } catch {
            // Trimming is best-effort; a failed prune must not lose the insert.
        }
    }
}

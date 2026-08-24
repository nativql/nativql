import Foundation
import SwiftData
import Observation

/// Read-side view model over the query history: newest-first entries with a
/// case-insensitive search across sql + connection name, plus delete.
@MainActor
@Observable
final class HistoryViewModel {
    private let context: ModelContext

    var searchText: String = ""
    private(set) var entries: [QueryHistoryEntry] = []

    init(context: ModelContext) {
        self.context = context
    }

    /// Reloads from the store, newest first.
    func refresh() {
        let descriptor = FetchDescriptor<QueryHistoryEntry>(
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
        )
        entries = (try? context.fetch(descriptor)) ?? []
    }

    /// `entries` filtered by `searchText` (sql or connection name contains,
    /// case- and whitespace-insensitive).
    var visibleEntries: [QueryHistoryEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.sql.lowercased().contains(needle) || $0.connectionName.lowercased().contains(needle)
        }
    }

    func delete(_ entry: QueryHistoryEntry) {
        context.delete(entry)
        try? context.save()
        refresh()
    }
}

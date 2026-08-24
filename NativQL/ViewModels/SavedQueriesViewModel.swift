import Foundation
import SwiftData
import Observation

/// CRUD over saved queries plus minimal folder management. Folders are flat
/// path strings ("Reports/Q3"); queries reference them via `folderPath`.
@MainActor
@Observable
final class SavedQueriesViewModel {
    private let context: ModelContext

    private(set) var queries: [SavedQuery] = []
    private(set) var folders: [SavedFolder] = []

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Queries

    func refresh() {
        // fullPath is computed, so SwiftData cannot sort by it — sort in memory.
        queries = ((try? context.fetch(FetchDescriptor<SavedQuery>())) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folders = ((try? context.fetch(FetchDescriptor<SavedFolder>())) ?? [])
            .sorted { $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending }
    }

    func add(name: String, sql: String, folderPath: String? = nil) {
        context.insert(SavedQuery(name: name, sql: sql, folderPath: folderPath))
        try? context.save()
        refresh()
    }

    func rename(_ query: SavedQuery, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        query.name = name
        try? context.save()
        refresh()
    }

    func updateSQL(_ query: SavedQuery, text: String) {
        query.sql = text
        try? context.save()
        refresh()
    }

    /// Moves the query to `folderPath` (nil = root).
    func move(_ query: SavedQuery, to folderPath: String?) {
        query.folderPath = folderPath
        try? context.save()
        refresh()
    }

    func delete(_ query: SavedQuery) {
        context.delete(query)
        try? context.save()
        refresh()
    }

    /// Queries living directly in `folderPath` (nil = root).
    func queries(inFolder folderPath: String?) -> [SavedQuery] {
        queries.filter { $0.folderPath == folderPath }
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(named name: String, parentPath: String?) -> SavedFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = SavedFolder(name: trimmed, parentPath: parentPath)
        context.insert(folder)
        try? context.save()
        refresh()
        return folder
    }
}

import Foundation
import SwiftData

/// Owns the SwiftData schema for Batch 7 stores (history, saved queries,
/// folders). The shared container persists to the default location; tests and
/// previews use `inMemory()`.
enum NativQLModelContainer {
    static let schema = Schema([QueryHistoryEntry.self, SavedQuery.self, SavedFolder.self])

    /// App-facing container backed by the platform-default store URL.
    static func shared() -> ModelContainer {
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("NativQL: could not open SwiftData store: \(error.localizedDescription)")
        }
    }

    /// Isolated in-memory container for tests and SwiftUI previews.
    static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

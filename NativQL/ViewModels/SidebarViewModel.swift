import Foundation
import NativQLKit
import Observation

/// One database and its (lazily loaded) tables/views inside the sidebar tree.
struct DatabaseNode: Identifiable {
    let info: DatabaseInfo
    var tables: Loadable<[TableInfo]> = .idle

    var id: String { info.name }
}

enum SidebarViewModelError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        }
    }
}

/// Loads the database → table tree for ONE connected profile, expanding
/// databases on demand.
@MainActor
@Observable
final class SidebarViewModel {
    private let driverProvider: () -> (any DatabaseDriver)?

    private(set) var nodes: [DatabaseNode] = []
    private(set) var databases: Loadable<Void> = .idle

    init(driverProvider: @escaping () -> (any DatabaseDriver)?) {
        self.driverProvider = driverProvider
    }

    /// Live driver snapshot for ad-hoc operations (export / DDL sheets).
    func currentDriver() -> (any DatabaseDriver)? {
        driverProvider()
    }

    /// Loads the top-level database list.
    func loadDatabases() async {
        guard let driver = driverProvider() else {
            databases = .error(SidebarViewModelError.notConnected.localizedDescription)
            return
        }
        if case .loading = databases { return }
        databases = .loading
        do {
            let infos = try await driver.listDatabases()
            nodes = infos.map { DatabaseNode(info: $0) }
            databases = .loaded(())
        } catch {
            databases = .error(error.localizedDescription)
        }
    }

    /// Lazy per-expand load; a no-op when already loading/loaded unless forced.
    func loadTables(for nodeName: String, force: Bool = false) async {
        guard let index = nodes.firstIndex(where: { $0.id == nodeName }) else { return }
        if !force {
            guard case .idle = nodes[index].tables else { return }
        }
        guard let driver = driverProvider() else {
            nodes[index].tables = .error(SidebarViewModelError.notConnected.localizedDescription)
            return
        }
        nodes[index].tables = .loading
        do {
            let tables = try await driver.listTables(database: nodeName, schema: nil)
            nodes[index].tables = .loaded(tables)
        } catch {
            nodes[index].tables = .error(error.localizedDescription)
        }
    }

    /// Re-fetches one database's tables (row context-menu Refresh).
    func reloadTables(for nodeName: String) async {
        guard let index = nodes.firstIndex(where: { $0.id == nodeName }) else { return }
        nodes[index].tables = .idle
        await loadTables(for: nodeName)
    }

    /// Rebuilds the whole tree from scratch.
    func reloadAll(expandedNames: Set<String> = []) async {
        await loadDatabases()
        for name in expandedNames {
            await loadTables(for: name, force: true)
        }
    }

    func dropDatabase(named name: String) async throws {
        guard let driver = driverProvider() else {
            throw SidebarViewModelError.notConnected
        }
        try await driver.dropDatabase(named: name)
        await reloadAll()
    }
}

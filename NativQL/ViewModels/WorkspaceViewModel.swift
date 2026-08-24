import Foundation
import NativQLKit
import Observation

enum WorkspaceViewModelError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        }
    }
}

/// Owns the multi-tab query workspace: tab lifecycle, run-all/run-selection,
/// and browse-mode pagination + server-side sorting. Views stay thin.
@MainActor
@Observable
final class WorkspaceViewModel {
    private let drivers: any DriverProviding

    private(set) var tabs: [QueryTab] = []
    var activeTabId: UUID?
    /// Bumped whenever a tab's result transitions to `.loaded`; lets the
    /// results grid distinguish fresh data from unrelated re-renders.
    private(set) var gridRevision = 0

    /// Invoked with a tab id whenever that tab's rendered browse snapshot
    /// changes (page move or sort change). Row-index-keyed staging is only
    /// valid within ONE rendered page snapshot — after navigation the same
    /// index addresses a different row — so all staged edits for the tab must
    /// be discarded before new rows render.
    var onBrowseSnapshotChange: ((UUID) -> Void)?

    /// Set by the workspace view at bootstrap; when present every completed
    /// run (success OR failure) is recorded into history, fire-and-forget.
    var historyRecorder: HistoryRecorder?
    /// Maps a connection id to its display name for history rows.
    var connectionNameProvider: ((UUID) -> String)?

    /// Monotonic "Query N" counters, per connection.
    private var queryCounters: [UUID: Int] = [:]

    init(drivers: any DriverProviding) {
        self.drivers = drivers
    }

    var activeTab: QueryTab? {
        tabs.first { $0.id == activeTabId }
    }

    // MARK: - Tab lifecycle

    /// Opens (or reuses) the free-query tab for a connection. Reuse returns the
    /// existing non-browse tab unless `forceNew` creates an extra one.
    @discardableResult
    func openQueryTab(connectionId: UUID, forceNew: Bool = false) -> QueryTab {
        if !forceNew, let existing = tabs.first(where: { $0.connectionId == connectionId && !$0.isBrowseMode }) {
            activeTabId = existing.id
            return existing
        }
        let number = (queryCounters[connectionId] ?? 0) + 1
        queryCounters[connectionId] = number
        let tab = QueryTab(title: "Query \(number)", connectionId: connectionId)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    /// Opens (or reuses) the browse tab for a table within one connection,
    /// titled "database.table". `pageSize` overrides the default page size
    /// (used to honor the settings preference for new browse tabs).
    @discardableResult
    func openBrowseTable(_ ref: TableRef, connectionId: UUID, pageSize: Int? = nil) -> QueryTab {
        if let existing = tabs.first(where: { $0.browse?.ref == ref && $0.connectionId == connectionId }) {
            activeTabId = existing.id
            return existing
        }
        let tab = QueryTab(
            title: "\(ref.database).\(ref.name)",
            connectionId: connectionId,
            browse: BrowseState(ref: ref, pageSize: pageSize ?? 200)
        )
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    /// Removes a tab; closing the active one activates the next sibling
    /// (or the previous when closing the last tab).
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTabId == id
        tabs.remove(at: index)
        if wasActive {
            activeTabId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    // MARK: - Editor bindings

    func setEditorText(_ text: String, for tabId: UUID) {
        mutate(tabId) { $0.editorText = text }
    }

    func setSelection(start: Int, end: Int, for tabId: UUID) {
        mutate(tabId) {
            $0.selectionStart = start
            $0.selectionEnd = end
        }
    }

    // MARK: - Run

    /// Runs the selection when non-empty else the whole editor text via the
    /// connection's driver; empty text is a no-op. Disconnected → error result.
    /// Every completed run (success or failure) is recorded into history when
    /// a recorder is attached.
    func runActive() async {
        guard let tab = activeTab else { return }
        let text = tab.resolvedRunText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let driver = await connectedDriver(for: tab.connectionId) else {
            mutate(tab.id) { $0.result = .error(WorkspaceViewModelError.notConnected.localizedDescription) }
            return
        }
        mutate(tab.id) { $0.result = .loading }
        let startedAt = Date()
        do {
            let result = try await driver.execute(text)
            gridRevision += 1
            mutate(tab.id) { $0.result = .loaded(result) }
            recordHistory(text, connectionId: tab.connectionId, ok: true, durationMs: result.executionMilliseconds)
        } catch {
            mutate(tab.id) { $0.result = .error(error.localizedDescription) }
            recordHistory(
                text,
                connectionId: tab.connectionId,
                ok: false,
                durationMs: Date().timeIntervalSince(startedAt) * 1000
            )
        }
    }

    /// Fire-and-forget persistence of one finished run; no-op without a recorder.
    private func recordHistory(_ sql: String, connectionId: UUID, ok: Bool, durationMs: Double) {
        guard let historyRecorder else { return }
        let name = connectionNameProvider?(connectionId) ?? "Unknown"
        Task { [historyRecorder] in
            historyRecorder.record(sql: sql, connectionName: name, kind: .query, ok: ok, durationMs: durationMs)
        }
    }

    // MARK: - Browse pagination & sort

    /// Loads the current browse page into the tab result as a SELECT-shaped QueryResult.
    func loadCurrentPage() async {
        guard let tab = activeTab, let browse = tab.browse else { return }
        let pageIndex = max(browse.pageIndex, 0)
        if pageIndex != browse.pageIndex {
            mutate(tab.id) { $0.browse?.pageIndex = pageIndex }
        }

        guard let driver = await connectedDriver(for: tab.connectionId) else {
            mutate(tab.id) { $0.result = .error(WorkspaceViewModelError.notConnected.localizedDescription) }
            return
        }
        mutate(tab.id) { $0.result = .loading }
        let startedAt = Date()
        do {
            let page = try await driver.browseRows(
                browse.ref,
                sort: browse.sort,
                limit: browse.pageSize,
                offset: pageIndex * browse.pageSize
            )
            let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1000
            gridRevision += 1
            mutate(tab.id) {
                var state = $0.browse
                let previousEstimate = state?.totalEstimate
                state?.totalEstimate = page.totalCountEstimate ?? previousEstimate
                $0.browse = state
                $0.result = .loaded(QueryResult(
                    columns: page.columns,
                    rows: page.rows,
                    executionMilliseconds: elapsedMilliseconds,
                    statementType: .select
                ))
            }
        } catch {
            mutate(tab.id) { $0.result = .error(error.localizedDescription) }
        }
    }

    /// Advances one page; stops at the last partial page when a total estimate exists.
    func nextPage() async {
        guard let tab = activeTab, let browse = tab.browse else { return }
        let nextIndex = max(browse.pageIndex, 0) + 1
        if let total = browse.totalEstimate, nextIndex * browse.pageSize >= total { return }
        mutate(tab.id) { $0.browse?.pageIndex = nextIndex }
        onBrowseSnapshotChange?(tab.id)
        await loadCurrentPage()
    }

    /// Steps back one page; no-op at the floor (page 0).
    func prevPage() async {
        guard let tab = activeTab, let browse = tab.browse, browse.pageIndex > 0 else { return }
        let previousIndex = browse.pageIndex - 1
        mutate(tab.id) { $0.browse?.pageIndex = previousIndex }
        onBrowseSnapshotChange?(tab.id)
        await loadCurrentPage()
    }

    /// Clicking a column header: new column sorts ascending, same column toggles;
    /// either way the grid reloads from page 0.
    func setSort(columnName: String) async {
        guard let tab = activeTab, tab.browse != nil else { return }
        mutate(tab.id) { tab in
            guard var state = tab.browse else { return }
            if state.sort?.columnName == columnName {
                state.sort?.ascending.toggle()
            } else {
                state.sort = SortSpec(columnName: columnName, ascending: true)
            }
            state.pageIndex = 0
            tab.browse = state
        }
        onBrowseSnapshotChange?(tab.id)
        await loadCurrentPage()
    }

    // MARK: - Browse state helpers

    func setPageSize(_ pageSize: Int, for tabId: UUID) {
        mutate(tabId) { $0.browse?.pageSize = pageSize }
    }

    func setPageIndex(_ pageIndex: Int, for tabId: UUID) {
        mutate(tabId) { $0.browse?.pageIndex = pageIndex }
    }

    func setTotalEstimate(_ estimate: Int64?, for tabId: UUID) {
        mutate(tabId) { $0.browse?.totalEstimate = estimate }
    }

    // MARK: - Private

    /// Connected driver for the active tab's connection; nil when disconnected.
    func connectedDriverForActiveTab() async -> (any DatabaseDriver)? {
        guard let tab = activeTab else { return nil }
        return await connectedDriver(for: tab.connectionId)
    }

    private func connectedDriver(for connectionId: UUID) async -> (any DatabaseDriver)? {
        guard let driver = drivers.driver(for: connectionId) else { return nil }
        return await drivers.isConnected(connectionId) ? driver : nil
    }

    private func mutate(_ tabId: UUID, _ change: (inout QueryTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        change(&tabs[index])
    }
}

import Foundation
import NativQLKit
import Observation

/// Thin bridge between the results grid and `RowOperationsService` for the
/// active browse tab: editability banner state, dirty counts, and the
/// stage/commit/revert handlers the grid and footer invoke.
@MainActor
@Observable
final class BrowseEditorViewModel {
    private let service: RowOperationsService
    private let tabProvider: () -> QueryTab?
    private let driverResolver: () async -> (any DatabaseDriver)?

    /// Invoked after a fully successful commit so the workspace can reload.
    var onCommitSuccess: (() -> Void)?
    private(set) var decision: EditabilityDecision?
    private(set) var lastCommitError: String?

    init(
        service: RowOperationsService,
        tabProvider: @escaping () -> QueryTab?,
        driverResolver: @escaping () async -> (any DatabaseDriver)?
    ) {
        self.service = service
        self.tabProvider = tabProvider
        self.driverResolver = driverResolver
    }

    // MARK: - State

    var isEditable: Bool { decision == .editable }

    /// Verbatim read-only reason from Kit's EditabilityRules, or nil when editable.
    var reasonText: String? {
        guard case .readOnly(let reason) = decision else { return nil }
        return reason
    }

    var dirtyCount: Int {
        guard let tab = tabProvider() else { return 0 }
        return service.dirtyCount(for: tab.id)
    }

    /// "2 edited · 1 added · 3 deleted"-style summary for the footer.
    var stagedSummary: String {
        guard let tab = tabProvider(), let staged = service.stagedEdits(for: tab.id) else { return "" }
        var edited = 0, added = 0, deleted = 0
        for change in staged.changes {
            switch change {
            case .cell: edited += 1
            case .insert: added += 1
            case .delete: deleted += 1
            }
        }
        var parts: [String] = []
        if edited > 0 { parts.append("\(edited) edited") }
        if added > 0 { parts.append("\(added) added") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        return parts.joined(separator: " · ")
    }

    func isCellStaged(row: Int, columnName: String) -> Bool {
        guard let tab = tabProvider() else { return false }
        return service.isCellStaged(tabId: tab.id, rowIndex: row, columnName: columnName)
    }

    func stagedValue(row: Int, columnName: String) -> SQLValue? {
        guard let tab = tabProvider() else { return nil }
        return service.stagedValue(tabId: tab.id, rowIndex: row, columnName: columnName)
    }

    func pendingInserts() -> [RowInsert] {
        guard let tab = tabProvider() else { return [] }
        return service.pendingInserts(for: tab.id)
    }

    /// Cached primary key column names for the browsed table (empty until a
    /// decision has been resolved).
    func primaryKeyNames() -> [String] {
        guard let ref = tabProvider()?.browse?.ref else { return [] }
        return service.cachedPrimaryKeyInfos(for: ref).map(\.name)
    }

    /// Primary key bindings for one browsed row, keyed by column name; empty
    /// for out-of-range rows (pending inserts carry no key).
    func pkBindings(rowIndex: Int, rows: [[SQLValue]], columns: [ColumnInfo]) -> [String: SQLValue] {
        guard let ref = tabProvider()?.browse?.ref, rowIndex < rows.count else { return [:] }
        let row = rows[rowIndex]
        var bindings: [String: SQLValue] = [:]
        for primaryKey in service.cachedPrimaryKeyInfos(for: ref) {
            guard let columnIndex = columns.firstIndex(where: { $0.name == primaryKey.name }),
                  columnIndex < row.count else { continue }
            bindings[primaryKey.name] = row[columnIndex]
        }
        return bindings
    }

    /// Staged values keyed by grid position so cells can render amber + dot.
    func stagedCellMap(columns: [ColumnInfo]) -> [StagedCellRef: SQLValue] {
        guard let tab = tabProvider(), let staged = service.stagedEdits(for: tab.id) else { return [:] }
        var map: [StagedCellRef: SQLValue] = [:]
        for change in staged.changes {
            guard case .cell(let edit) = change,
                  let columnIndex = columns.firstIndex(where: { $0.name == edit.columnName }) else { continue }
            map[StagedCellRef(row: edit.rowIndex, column: columnIndex)] = edit.newValue
        }
        return map
    }

    // MARK: - Handlers

    func refreshDecision() async {
        guard let tab = tabProvider() else {
            decision = nil
            return
        }
        guard let driver = await driverResolver() else {
            decision = .readOnly(reason: "Not connected.")
            return
        }
        decision = await service.resolveEditability(for: tab, driver: driver)
    }

    /// Stages typed text as a string value; NULL goes through `setCellNull`.
    func stageCell(
        row: Int,
        columnName: String,
        original: SQLValue,
        text: String,
        pkValues: [String: SQLValue]
    ) {
        guard let tab = tabProvider() else { return }
        _ = service.stageCellEdit(
            tabId: tab.id,
            rowIndex: row,
            columnName: columnName,
            original: original,
            newValue: .string(text),
            pkValues: pkValues
        )
    }

    func setCellNull(row: Int, columnName: String, original: SQLValue, pkValues: [String: SQLValue]) {
        guard let tab = tabProvider() else { return }
        _ = service.stageCellEdit(
            tabId: tab.id,
            rowIndex: row,
            columnName: columnName,
            original: original,
            newValue: .null,
            pkValues: pkValues
        )
    }

    func stageInsertedCell(insertIndex: Int, columnIndex: Int, text: String) {
        guard let tab = tabProvider() else { return }
        service.stageInsertedCell(
            tabId: tab.id,
            insertIndex: insertIndex,
            columnIndex: columnIndex,
            newValue: .string(text)
        )
    }

    func deleteRows(at indexes: IndexSet, rows: [[SQLValue]], columns: [ColumnInfo], pkColumnNames: [String]) {
        guard let tab = tabProvider() else { return }
        for rowIndex in indexes.sorted() where rowIndex < rows.count {
            let row = rows[rowIndex]
            let bindings: [SQLValue] = pkColumnNames.map { columnName in
                guard let columnIndex = columns.firstIndex(where: { $0.name == columnName }),
                      columnIndex < row.count else { return .null }
                return row[columnIndex]
            }
            let preview = zip(pkColumnNames, bindings)
                .map { "\($0)=\(CellFormatter.text(for: $1))" }
                .joined(separator: ", ")
            service.stageRowDelete(
                tabId: tab.id,
                rowIndex: rowIndex,
                pkValues: bindings,
                displayPreview: preview
            )
        }
    }

    func revertCell(row: Int, columnName: String) {
        guard let tab = tabProvider() else { return }
        service.revertCell(tabId: tab.id, rowIndex: row, columnName: columnName)
    }

    func revertAll() {
        guard let tab = tabProvider() else { return }
        service.revertAll(tabId: tab.id)
    }

    @discardableResult
    func insertRow(columns: [ColumnInfo]) -> [SQLValue] {
        guard let tab = tabProvider() else { return [] }
        return service.stageRowInsert(tabId: tab.id, columns: columns)
    }

    func commit() async {
        guard let tab = tabProvider(), let driver = await driverResolver() else { return }
        do {
            try await service.commit(tab: tab, driver: driver)
            lastCommitError = nil
            onCommitSuccess?()
        } catch {
            lastCommitError = error.localizedDescription
        }
    }

    // MARK: - Private
}

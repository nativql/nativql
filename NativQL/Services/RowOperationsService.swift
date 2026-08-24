import Foundation
import NativQLKit
import Observation

/// Stages inline row edits per workspace tab and commits them transactionally:
/// UPDATEs for edited rows, INSERTs for added rows, DELETEs for removed rows —
/// each built by the Kit statement builders and executed sequentially through
/// the driver's `executeMutation`. Staging survives a failed commit.
@MainActor
@Observable
final class RowOperationsService {
    enum OperationError: LocalizedError {
        case notBrowsing
        case missingPrimaryKey

        var errorDescription: String? {
            switch self {
            case .notBrowsing: return "Editing is available only when browsing a table."
            case .missingPrimaryKey: return "Table has no primary key, so rows can't be updated safely."
            }
        }
    }

    private(set) var stagedByTab: [UUID: TabStagedEdits] = [:]
    private var tableColumns: [UUID: [ColumnInfo]] = [:]
    /// Per-table primary key lookup cache; value is the driver's optional list.
    private var primaryKeyCache: [TableRef: [String]?] = [:]

    // MARK: - Inspection

    func stagedEdits(for tabId: UUID) -> TabStagedEdits? {
        guard let staged = stagedByTab[tabId], !staged.changes.isEmpty else { return nil }
        return staged
    }

    func dirtyCount(for tabId: UUID) -> Int {
        stagedEdits(for: tabId)?.changes.count ?? 0
    }

    func pendingInserts(for tabId: UUID) -> [RowInsert] {
        (stagedEdits(for: tabId)?.changes ?? []).compactMap {
            if case .insert(let row) = $0 { return row }
            return nil
        }
    }

    func isCellStaged(tabId: UUID, rowIndex: Int, columnName: String) -> Bool {
        cellEdit(tabId: tabId, rowIndex: rowIndex, columnName: columnName) != nil
    }

    func stagedValue(tabId: UUID, rowIndex: Int, columnName: String) -> SQLValue? {
        cellEdit(tabId: tabId, rowIndex: rowIndex, columnName: columnName)?.newValue
    }

    // MARK: - Editability

    /// Resolves whether a browse tab may edit rows, caching the driver's
    /// primary key lookup per table reference. Introspection failure counts as
    /// no primary key (safe default).
    func resolveEditability(for tab: QueryTab, driver: any DatabaseDriver) async -> EditabilityDecision {
        guard let browse = tab.browse else {
            return .readOnly(reason: OperationError.notBrowsing.localizedDescription)
        }
        let names = await primaryKeyNames(for: browse.ref, driver: driver)
        return EditabilityRules.evaluate(
            source: .tableBrowse,
            hasPrimaryKey: !(names ?? []).isEmpty
        )
    }

    /// Cached primary key columns as minimal ColumnInfos for the builders,
    /// which only consume identifier names.
    func primaryKeyColumnInfos(for ref: TableRef, driver: any DatabaseDriver) async -> [ColumnInfo] {
        ((await primaryKeyNames(for: ref, driver: driver)) ?? [])
            .map { ColumnInfo(name: $0, dataType: "", isPrimaryKey: true) }
    }

    /// Synchronous read of an already-resolved primary key cache; empty when
    /// `resolveEditability` has not run for this table yet.
    func cachedPrimaryKeyInfos(for ref: TableRef) -> [ColumnInfo] {
        ((primaryKeyCache[ref] ?? []) ?? [])
            .map { ColumnInfo(name: $0, dataType: "", isPrimaryKey: true) }
    }

    private func primaryKeyNames(for ref: TableRef, driver: any DatabaseDriver) async -> [String]? {
        if let cached = primaryKeyCache[ref] { return cached }
        let resolved = try? await driver.primaryKey(of: ref)
        primaryKeyCache[ref] = resolved
        return resolved
    }

    // MARK: - Staging

    @discardableResult
    func stageCellEdit(
        tabId: UUID,
        rowIndex: Int,
        columnName: String,
        original: SQLValue,
        newValue: SQLValue,
        pkValues: [String: SQLValue]
    ) -> Bool {
        guard newValue != original else { return false }
        guard !isRowDeleted(tabId: tabId, rowIndex: rowIndex) else { return false }

        var edits = stagedByTab[tabId] ?? TabStagedEdits()
        if let index = indexOfCellEdit(edits, rowIndex: rowIndex, columnName: columnName),
           case .cell(var existing) = edits.changes[index] {
            existing.newValue = newValue
            edits.changes[index] = .cell(existing)
        } else {
            edits.changes.append(.cell(CellEdit(
                rowIndex: rowIndex,
                columnName: columnName,
                original: original,
                newValue: newValue,
                pkValues: pkValues
            )))
        }
        stagedByTab[tabId] = edits
        return true
    }

    func stageRowDelete(tabId: UUID, rowIndex: Int, pkValues: [SQLValue], displayPreview: String) {
        var edits = stagedByTab[tabId] ?? TabStagedEdits()
        edits.changes.removeAll { change in
            switch change {
            case .cell(let edit): return edit.rowIndex == rowIndex
            case .delete(let delete): return delete.rowIndex == rowIndex
            case .insert: return false
            }
        }
        edits.changes.append(.delete(RowDelete(
            rowIndex: rowIndex,
            pkValues: pkValues,
            displayPreview: displayPreview
        )))
        stagedByTab[tabId] = edits
    }

    /// Appends an all-NULL placeholder row honoring simple column defaults
    /// (integer and single-quoted string literals); returns the template.
    @discardableResult
    func stageRowInsert(tabId: UUID, columns: [ColumnInfo]) -> [SQLValue] {
        tableColumns[tabId] = columns
        let row = RowInsert(values: columns.map { placeholderValue(for: $0.defaultValue) })
        var edits = stagedByTab[tabId] ?? TabStagedEdits()
        edits.changes.append(.insert(row))
        stagedByTab[tabId] = edits
        return row.values
    }

    func stageInsertedCell(tabId: UUID, insertIndex: Int, columnIndex: Int, newValue: SQLValue) {
        var edits = stagedByTab[tabId] ?? TabStagedEdits()
        var seenInserts = -1
        for index in edits.changes.indices {
            guard case .insert(var row) = edits.changes[index] else { continue }
            seenInserts += 1
            guard seenInserts == insertIndex else { continue }
            while columnIndex >= row.values.count { row.values.append(.null) }
            row.values[columnIndex] = newValue
            edits.changes[index] = .insert(row)
            stagedByTab[tabId] = edits
            return
        }
    }

    func revertCell(tabId: UUID, rowIndex: Int, columnName: String) {
        guard var edits = stagedByTab[tabId] else { return }
        edits.changes.removeAll { change in
            if case .cell(let edit) = change {
                return edit.rowIndex == rowIndex && edit.columnName == columnName
            }
            return false
        }
        stagedByTab[tabId] = edits.changes.isEmpty ? nil : edits
    }

    func revertAll(tabId: UUID) {
        stagedByTab[tabId] = nil
    }

    // MARK: - Commit

    /// Builds and executes updates → inserts → deletes; clears staging only
    /// after every statement succeeds, rethrowing otherwise with staging intact.
    func commit(tab: QueryTab, driver: any DatabaseDriver) async throws {
        guard let staged = stagedEdits(for: tab.id) else { return }
        guard let browse = tab.browse else { throw OperationError.notBrowsing }

        let pkColumns = await primaryKeyColumnInfos(for: browse.ref, driver: driver)
        guard !pkColumns.isEmpty else { throw OperationError.missingPrimaryKey }

        var statements: [MutationStatement] = []

        var updateOrder: [Int] = []
        var changesByRow: [Int: [(columnName: String, newValue: SQLValue)]] = [:]
        var keysByRow: [Int: [String: SQLValue]] = [:]
        for change in staged.changes {
            guard case .cell(let edit) = change else { continue }
            if changesByRow[edit.rowIndex] == nil { updateOrder.append(edit.rowIndex) }
            changesByRow[edit.rowIndex, default: []].append((edit.columnName, edit.newValue))
            keysByRow[edit.rowIndex] = edit.pkValues
        }
        for rowIndex in updateOrder {
            guard let changes = changesByRow[rowIndex], let pkValues = keysByRow[rowIndex],
                  let statement = UpdateStatementBuilder.build(
                    table: browse.ref,
                    pkColumns: pkColumns,
                    changes: changes,
                    pkValues: pkValues
                  ) else { continue }
            statements.append(statement)
        }

        let inserts = staged.changes.compactMap {
            if case .insert(let row) = $0 { return row }
            return nil
        }
        if !inserts.isEmpty {
            statements.append(InsertStatementBuilder.build(
                table: browse.ref,
                columns: tableColumns[tab.id] ?? [],
                rows: inserts.map(\.values)
            ))
        }

        let deletes = staged.changes.compactMap {
            if case .delete(let deletion) = $0 { return deletion }
            return nil
        }
        if !deletes.isEmpty, let deleteStatement = DeleteStatementBuilder.build(
            table: browse.ref,
            pkColumns: pkColumns,
            rows: deletes.map(\.pkValues)
        ) {
            statements.append(deleteStatement)
        }

        for statement in statements {
            _ = try await driver.executeMutation(statement)
        }

        stagedByTab[tab.id] = nil
        tableColumns[tab.id] = nil
    }

    // MARK: - Private

    private func indexOfCellEdit(_ edits: TabStagedEdits, rowIndex: Int, columnName: String) -> Int? {
        edits.changes.firstIndex { change in
            if case .cell(let edit) = change {
                return edit.rowIndex == rowIndex && edit.columnName == columnName
            }
            return false
        }
    }

    private func cellEdit(tabId: UUID, rowIndex: Int, columnName: String) -> CellEdit? {
        guard let index = indexOfCellEdit(stagedEdits(for: tabId) ?? TabStagedEdits(), rowIndex: rowIndex, columnName: columnName),
              case .cell(let edit) = stagedByTab[tabId]?.changes[index] else { return nil }
        return edit
    }

    private func isRowDeleted(tabId: UUID, rowIndex: Int) -> Bool {
        (stagedEdits(for: tabId)?.changes ?? []).contains {
            if case .delete(let deletion) = $0 { return deletion.rowIndex == rowIndex }
            return false
        }
    }

    private func placeholderValue(for defaultValue: String?) -> SQLValue {
        guard let raw = defaultValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .null }
        if raw.lowercased() == "null" { return .null }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return .string(inner.replacingOccurrences(of: "''", with: "'"))
        }
        if let integer = Int64(raw) { return .int(integer) }
        return .null
    }
}

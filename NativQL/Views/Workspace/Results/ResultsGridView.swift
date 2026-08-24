import AppKit
import NativQLKit
import SwiftUI

/// SwiftUI wrapper around a virtualized, view-based `NSTableView` for query
/// results. Columns rebuild only when the column set changes; rows reload only
/// when the caller-provided `reloadKey` changes, so unrelated SwiftUI updates
/// never disturb selection or scroll position.
///
/// In editable browse mode the grid additionally supports double-click inline
/// editing with staged-change overlays, pending-insert placeholder rows, and a
/// row/cell context menu (Set NULL · Delete Row(s) · Revert staged cell).
struct ResultsGridView: NSViewRepresentable {
    var columns: [ColumnInfo]
    var rows: [[SQLValue]]
    /// Bump to force a row reload (e.g. tab id + result revision).
    var reloadKey: String
    /// Header sort clicking is active only in browse mode.
    var allowsSort: Bool
    /// Current server-side sort reflected in header indicators.
    var sort: SortSpec?
    var onSortClick: (String) -> Void

    // MARK: Editing (all no-ops unless allowsEditing)

    /// Enables inline editing affordances; supplied by the workspace only in
    /// editable browse tabs.
    var allowsEditing: Bool = false
    /// Staged values keyed by grid position; rendered over the database value.
    var stagedCells: [StagedCellRef: SQLValue] = [:]
    /// Pending inserted rows appended after the data rows.
    var pendingInsertRows: [[SQLValue]] = []
    var onStageCell: (_ row: Int, _ column: Int, _ text: String) -> Void = { _, _, _ in }
    var onStageInsertedCell: (_ insertIndex: Int, _ column: Int, _ text: String) -> Void = { _, _, _ in }
    var onSetNull: (_ row: Int, _ column: Int) -> Void = { _, _ in }
    var onDeleteRows: (_ indexes: IndexSet) -> Void = { _ in }
    var onRevertCell: (_ row: Int, _ column: Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copyHandler = { indexes in
            context.coordinator.copy(rowsAt: indexes)
        }
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = table
        if let clipView = scrollView.contentView as? NSClipView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.scrollDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        context.coordinator.installContextMenu(on: table)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        context.coordinator.rebuildColumnsIfNeeded(in: table)
        table.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scrollView.documentView as? ResultsTableView else { return }

        coordinator.rebuildColumnsIfNeeded(in: table)
        coordinator.syncSortPrototypes(in: table)
        if coordinator.reloadKey != reloadKey || table.numberOfRows != totalRowCount {
            coordinator.dismissEditor()
            coordinator.reloadKey = reloadKey
            table.reloadData()
        }
        if table.allowsMultipleSelection != allowsEditing {
            table.allowsMultipleSelection = allowsEditing
        }
        syncSortDescriptors(into: table, coordinator: coordinator)
    }

    private var totalRowCount: Int {
        rows.count + pendingInsertRows.count
    }

    private func syncSortDescriptors(into table: ResultsTableView, coordinator: Coordinator) {
        let descriptors: [NSSortDescriptor]
        if allowsSort, let sort {
            descriptors = [NSSortDescriptor(key: sort.columnName, ascending: sort.ascending)]
        } else {
            descriptors = []
        }
        if table.sortDescriptors != descriptors {
            coordinator.isSyncingSort = true
            table.sortDescriptors = descriptors
            coordinator.isSyncingSort = false
        }
    }

    // MARK: - Coordinator (dataSource + delegate + editing)

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ResultsGridView
        var reloadKey: String
        private var activeEditor: EditableCellView?
        // Empty on purpose: the first rebuildColumnsIfNeeded must build.
        private var columnNames: [String] = []

        init(_ parent: ResultsGridView) {
            self.parent = parent
            self.reloadKey = parent.reloadKey
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private var dataRowCount: Int { parent.rows.count }
        private var totalRowCount: Int { parent.rows.count + parent.pendingInsertRows.count }

        func numberOfRows(in tableView: NSTableView) -> Int {
            totalRowCount
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let columnIndex = parent.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }),
                  rowIndexes(row, within: totalRowCount) else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("nativql.cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CellContentView)
                ?? CellContentView(identifier: identifier)

            if row < dataRowCount {
                guard columnIndex < parent.rows[row].count else { return nil }
                let stagedValue = parent.stagedCells[StagedCellRef(row: row, column: columnIndex)]
                let value = stagedValue ?? parent.rows[row][columnIndex]
                cell.render(value)
                cell.setStaged(stagedValue != nil)
            } else {
                let values = parent.pendingInsertRows[row - dataRowCount]
                cell.render(columnIndex < values.count ? values[columnIndex] : SQLValue.null)
                cell.setStaged(true)
            }
            return cell
        }

        private func rowIndexes(_ row: Int, within count: Int) -> Bool {
            row >= 0 && row < count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            22
        }

        // MARK: Inline editing

        @objc func rowDoubleClicked(_ sender: Any?) {
            guard let table = sender as? ResultsTableView else { return }
            beginEditing(row: table.clickedRow, column: table.clickedColumn, in: table)
        }

        func beginEditing(row: Int, column: Int, in table: ResultsTableView) {
            guard parent.allowsEditing,
                  rowIndexes(row, within: totalRowCount),
                  column >= 0, column < parent.columns.count else { return }


            dismissEditor()

            let initialText: String
            let placeholder: String?
            if row < dataRowCount {
                let displayed = parent.stagedCells[StagedCellRef(row: row, column: column)]
                    ?? parent.rows[row][column]
                if case .null = displayed {
                    initialText = ""
                    placeholder = "NULL"
                } else {
                    initialText = CellFormatter.text(for: displayed)
                    placeholder = nil
                }
            } else {
                let values = parent.pendingInsertRows[row - dataRowCount]
                let displayed: SQLValue = column < values.count ? values[column] : .null
                if case .null = displayed {
                    initialText = ""
                    placeholder = "NULL"
                } else {
                    initialText = CellFormatter.text(for: displayed)
                    placeholder = nil
                }
            }

            let columnRect = table.rect(ofColumn: column)
            let rowRect = table.rect(ofRow: row)
            let cellRect = columnRect.intersection(rowRect)
            activeEditor = EditableCellView.present(
                in: table,
                cellRect: cellRect,
                initialValue: initialText,
                placeholder: placeholder,
                onCommit: { [weak self] text in
                    guard let self else { return }
                    if row < dataRowCount {
                        self.parent.onStageCell(row, column, text)
                    } else {
                        self.parent.onStageInsertedCell(row - dataRowCount, column, text)
                    }
                    self.activeEditor = nil
                },
                onCancel: { [weak self] in
                    self?.activeEditor = nil
                }
            )
        }

        func dismissEditor() {
            activeEditor?.dismiss()
            activeEditor = nil
        }

        @objc func scrollDidChange() {
            dismissEditor()
        }

        // MARK: Context menu

        func installContextMenu(on table: ResultsTableView) {
            contextTable = table
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self

            let setNull = NSMenuItem(title: "Set NULL", action: #selector(setNullClicked(_:)), keyEquivalent: "")
            setNull.target = self
            menu.addItem(setNull)

            let deleteRows = NSMenuItem(title: "Delete Row(s)", action: #selector(deleteRowsClicked(_:)), keyEquivalent: "")
            deleteRows.target = self
            menu.addItem(deleteRows)

            let revertCell = NSMenuItem(title: "Revert Staged Cell", action: #selector(revertCellClicked(_:)), keyEquivalent: "")
            revertCell.target = self
            menu.addItem(revertCell)

            table.menu = menu
        }

        private weak var contextTable: ResultsTableView?

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table = contextTable else { return }
            let row = table.clickedRow
            let column = table.clickedColumn
            let isDataCell = parent.allowsEditing && row >= 0 && row < dataRowCount && column >= 0 && column < parent.columns.count

            for item in menu.items {
                switch item.title {
                case "Set NULL":
                    item.isEnabled = isDataCell
                        && column < parent.rows[row].count
                        && parent.rows[row][column] != SQLValue.null
                case "Delete Row(s)":
                    item.isEnabled = parent.allowsEditing && hasDeletableSelection(in: table)
                case "Revert Staged Cell":
                    item.isEnabled = isDataCell
                        && parent.stagedCells[StagedCellRef(row: row, column: column)] != nil
                default:
                    item.isEnabled = false
                }
            }
        }

        private func hasDeletableSelection(in table: ResultsTableView) -> Bool {
            deletableSelectionIndexes(in: table).isEmpty == false
        }

        private func deletableSelectionIndexes(in table: ResultsTableView) -> IndexSet {
            var indexes = table.selectedRowIndexes
            if table.clickedRow >= 0 { indexes.insert(table.clickedRow) }
            return IndexSet(indexes.filter { $0 >= 0 && $0 < dataRowCount })
        }

        @objc func setNullClicked(_ sender: Any?) {
            guard let table = contextTable, parent.allowsEditing else { return }
            let row = table.clickedRow
            let column = table.clickedColumn
            guard row >= 0, row < dataRowCount, column >= 0, column < parent.columns.count else { return }
            parent.onSetNull(row, column)
        }

        @objc func deleteRowsClicked(_ sender: Any?) {
            guard let table = contextTable, parent.allowsEditing else { return }
            let indexes = deletableSelectionIndexes(in: table)
            guard !indexes.isEmpty else { return }
            parent.onDeleteRows(indexes)
        }

        @objc func revertCellClicked(_ sender: Any?) {
            guard let table = contextTable, parent.allowsEditing else { return }
            let row = table.clickedRow
            let column = table.clickedColumn
            guard row >= 0, row < dataRowCount, column >= 0, column < parent.columns.count else { return }
            parent.onRevertCell(row, column)
        }

        // MARK: Sort

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isSyncingSort, parent.allowsSort,
                  let columnName = tableView.sortDescriptors.first?.key else { return }
            parent.onSortClick(columnName)
        }

        var isSyncingSort = false

        // MARK: Columns

        func rebuildColumnsIfNeeded(in table: NSTableView) {
            let names = parent.columns.map(\.name)
            if names == columnNames { return }
            columnNames = names
            for existing in table.tableColumns {
                table.removeTableColumn(existing)
            }
            for columnInfo in parent.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnInfo.name))
                column.title = columnInfo.name
                column.headerToolTip = columnInfo.dataType
                column.width = 130
                column.minWidth = 60
                column.maxWidth = 1_000
                column.resizingMask = [.userResizingMask, .autoresizingMask]
                // Header-click sorting rides the sortDescriptors machinery;
                // prototypes exist only in browse mode so a click on a
                // free-query header can never flash-sort the rows client-side.
                if parent.allowsSort {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: columnInfo.name, ascending: true)
                }
                table.addTableColumn(column)
            }
        }

        /// Installs or clears header sort prototypes as `allowsSort` flips
        /// between browse and free-query tabs sharing an identical column set.
        func syncSortPrototypes(in table: NSTableView) {
            for column in table.tableColumns {
                let desired: NSSortDescriptor? = parent.allowsSort
                    ? NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
                    : nil
                let current = column.sortDescriptorPrototype
                let isUpToDate: Bool
                switch (current, desired) {
                case (nil, nil):
                    isUpToDate = true
                case (let existing?, let wanted?):
                    isUpToDate = existing.key == wanted.key && existing.ascending == wanted.ascending
                default:
                    isUpToDate = false
                }
                if !isUpToDate {
                    column.sortDescriptorPrototype = desired
                }
            }
        }

        // MARK: Copy

        /// Copies the selected row's cells as TSV onto the general pasteboard.
        func copy(rowsAt indexes: IndexSet) {
            let lines = indexes.sorted().compactMap { rowIndex -> String? in
                guard rowIndex < dataRowCount, rowIndexes(rowIndex, within: dataRowCount) else { return nil }
                let values = parent.rows[rowIndex]
                return parent.columns.indices.compactMap { columnIndex in
                    columnIndex < values.count ? CellFormatter.text(for: values[columnIndex]) : nil
                }.joined(separator: "\t")
            }
            guard !lines.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }
}

/// Table view hooking ⌘C (responder-chain `copy:`) into the grid's copy handler.
final class ResultsTableView: NSTableView {
    var copyHandler: ((IndexSet) -> Void)?

    /// Exposes NSResponder's `copy:` action without clashing with NSObject.copy.
    @objc(copy:)
    func copySelectedRows(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty else { return }
        copyHandler?(selectedRowIndexes)
    }

}

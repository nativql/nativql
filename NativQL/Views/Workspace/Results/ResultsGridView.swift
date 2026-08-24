import AppKit
import NativQLKit
import SwiftUI

/// SwiftUI wrapper around a virtualized, view-based `NSTableView` for query
/// results. Columns rebuild only when the column set changes; rows reload only
/// when the caller-provided `reloadKey` changes, so unrelated SwiftUI updates
/// never disturb selection or scroll position.
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

        let scrollView = NSScrollView()
        scrollView.documentView = table
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
        if coordinator.reloadKey != reloadKey || table.numberOfRows != rows.count {
            coordinator.reloadKey = reloadKey
            table.reloadData()
        }
        syncSortDescriptors(into: table, coordinator: coordinator)
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

    // MARK: - Coordinator (dataSource + delegate)

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResultsGridView
        var reloadKey: String
        // Empty on purpose: the first rebuildColumnsIfNeeded must build.
        private var columnNames: [String] = []

        init(_ parent: ResultsGridView) {
            self.parent = parent
            self.reloadKey = parent.reloadKey
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let columnIndex = parent.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }),
                  rowIndexes(row, within: parent.rows.count),
                  columnIndex < parent.rows[row].count else {
                return nil
            }
            let identifier = NSUserInterfaceItemIdentifier("nativql.cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CellContentView)
                ?? CellContentView(identifier: identifier)
            cell.render(parent.rows[row][columnIndex])
            return cell
        }

        private func rowIndexes(_ row: Int, within count: Int) -> Bool {
            row >= 0 && row < count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            22
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
                // Enables header-click sorting via the sortDescriptors machinery.
                column.sortDescriptorPrototype = NSSortDescriptor(key: columnInfo.name, ascending: true)
                table.addTableColumn(column)
            }
        }

        // MARK: Copy

        /// Copies the selected row's cells as TSV onto the general pasteboard.
        func copy(rowsAt indexes: IndexSet) {
            let lines = indexes.sorted().compactMap { rowIndex -> String? in
                guard rowIndexes(rowIndex, within: parent.rows.count) else { return nil }
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

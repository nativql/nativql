import SwiftUI
import SwiftData
import NativQLKit
import UniformTypeIdentifiers

/// The per-connection query workspace: tab strip, editor above results grid,
/// ⌘T / ⌘R / ⌘↩ / ⌘S / ⌘E shortcuts, table-browse wiring from the sidebar
/// tree, history recording, page export, explain sheet, and toasts.
struct WorkspaceView: View {
    let connectionId: UUID

    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: WorkspaceViewModel?
    @State private var editorViewModel: BrowseEditorViewModel?
    @State private var topFraction: CGFloat = 0.4
    @State private var commitErrorMessage: String?
    @State private var explainSQL: String?
    @State private var explainDriver: (any DatabaseDriver)?
    @State private var isShowingSaveQueryPrompt = false
    @State private var saveQueryName = ""

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: connectionId) {
            bootstrapIfNeeded()
        }
        .onChange(of: appState.selectedTable) { _, selected in
            guard let viewModel, let selected else { return }
            openBrowse(viewModel, table: selected)
        }
        .onChange(of: appState.pendingEditorLoad) { _, pending in
            guard let text = pending, let viewModel, let tab = viewModel.activeTab else { return }
            viewModel.setEditorText(text, for: tab.id)
            appState.pendingEditorLoad = nil
            if appState.pendingEditorAutorun {
                appState.pendingEditorAutorun = false
                run(viewModel)
            }
        }
        .sheet(isPresented: Binding(
            get: { explainSQL != nil },
            set: { if !$0 { explainSQL = nil; explainDriver = nil } }
        )) {
            if let sql = explainSQL, let driver = explainDriver {
                ExplainSheet(sql: sql, driver: driver)
            }
        }
        .alert(
            "Save Query",
            isPresented: $isShowingSaveQueryPrompt
        ) {
            TextField("Name", text: $saveQueryName)
            Button("Save") { saveActiveEditorAsQuery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the active editor's SQL to Saved Queries.")
        }
        .alert(
            "Commit failed",
            isPresented: Binding(
                get: { commitErrorMessage != nil },
                set: { if !$0 { commitErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(commitErrorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            ToastView(center: toastCenter)
        }
    }

    private func content(_ viewModel: WorkspaceViewModel) -> some View {
        VStack(spacing: 0) {
            TabBarView(viewModel: viewModel, connectionId: connectionId)
            Divider()
            VSplitLayout(topFraction: $topFraction) {
                editorPane(viewModel)
            } bottom: {
                resultsPane(viewModel)
            }
        }
        .background(invisibleShortcutButtons(viewModel))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    prepareExplain(viewModel)
                } label: {
                    Label("Explain", systemImage: "tree")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!ExplainGate.canRun(activeTab: viewModel.activeTab))
                .help("Explain the current statement (⌘E)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    saveQueryName = ""
                    isShowingSaveQueryPrompt = true
                } label: {
                    Label("Save Query", systemImage: "bookmark")
                }
                .disabled((viewModel.activeTab?.editorText.isEmpty ?? true))
                .help("Save the active editor's SQL")
            }
        }
        .onChange(of: viewModel.activeTabId) { _, _ in
            loadBrowsePageIfIdle(viewModel)
            refreshEditorDecision()
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private func editorPane(_ viewModel: WorkspaceViewModel) -> some View {
        if let tab = viewModel.activeTab {
            if tab.isBrowseMode, let browse = tab.browse {
                browsingBanner(browse.ref)
            } else {
                QueryEditorView(
                    text: editorBinding(viewModel, tabId: tab.id),
                    restoredSelection: restoredSelection(tab),
                    onSelectionChange: { start, end in
                        viewModel.setSelection(start: start, end: end, for: tab.id)
                    },
                    onRun: { run(viewModel) },
                    fontSize: settings.editorFontSize
                )
            }
        }
    }

    private func resultsPane(_ viewModel: WorkspaceViewModel) -> some View {
        VStack(spacing: 0) {
            if isBrowseMode(viewModel), let reason = editorViewModel?.reasonText {
                ReadOnlyBanner(reason: reason)
                Divider()
            }
            ResultsGridView(
                columns: activeColumns,
                rows: activeRows,
                reloadKey: reloadKey(viewModel),
                allowsSort: viewModel.activeTab?.isBrowseMode ?? false,
                sort: viewModel.activeTab?.browse?.sort,
                onSortClick: { columnName in
                    Task { await viewModel.setSort(columnName: columnName) }
                },
                allowsEditing: editorViewModel?.isEditable ?? false,
                stagedCells: editorStagedCells,
                pendingInsertRows: editorViewModel?.pendingInserts().map(\.values) ?? [],
                onStageCell: { row, column, text in
                    stageCellEdit(row: row, column: column, text: text)
                },
                onStageInsertedCell: { insertIndex, column, text in
                    editorViewModel?.stageInsertedCell(insertIndex: insertIndex, columnIndex: column, text: text)
                },
                onSetNull: { row, column in
                    setCellNull(row: row, column: column)
                },
                onDeleteRows: { indexes in
                    editorViewModel?.deleteRows(
                        at: indexes,
                        rows: activeRows,
                        columns: activeColumns,
                        pkColumnNames: editorViewModel?.primaryKeyNames() ?? []
                    )
                },
                onRevertCell: { row, column in
                    guard column < activeColumns.count else { return }
                    editorViewModel?.revertCell(row: row, columnName: activeColumns[column].name)
                }
            )
            Divider()
            ResultsFooterView(
                result: viewModel.activeTab?.result,
                browse: viewModel.activeTab?.browse,
                dirtyCount: editorViewModel?.dirtyCount ?? 0,
                dirtySummary: editorViewModel?.stagedSummary ?? "",
                onCommit: { commitStagedEdits(viewModel) },
                onRevertAll: { editorViewModel?.revertAll() },
                showsInsertRow: editorViewModel?.isEditable ?? false,
                onInsertRow: { insertStagedRow(viewModel) },
                canExport: !activeRows.isEmpty,
                onSaveCSV: { exportCurrentPage(as: .csv) },
                onSaveJSON: { exportCurrentPage(as: .json) },
                onNextPage: { Task { await viewModel.nextPage() } },
                onPrevPage: { Task { await viewModel.prevPage() } }
            )
        }
    }

    private func browsingBanner(_ ref: TableRef) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
            Text("Browsing \(ref.database).\(ref.name) — server-side sorted and paged")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func invisibleShortcutButtons(_ viewModel: WorkspaceViewModel) -> some View {
        Group {
            Button("New Tab") {
                let target = viewModel.activeTab?.connectionId ?? connectionId
                viewModel.openQueryTab(connectionId: target, forceNew: true)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Run Query (⌘R)") { run(viewModel) }
                .keyboardShortcut("r", modifiers: .command)

            Button("Run Query (⌘↩)") { run(viewModel) }
                .keyboardShortcut(.return, modifiers: .command)

            Button("Commit Staged Edits (⌘S)") { commitStagedEdits(viewModel) }
                .keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
    }

    // MARK: - Row editing helpers

    private var activeColumns: [ColumnInfo] {
        viewModel?.activeTab?.result.value?.columns ?? []
    }

    private var activeRows: [[SQLValue]] {
        viewModel?.activeTab?.result.value?.rows ?? []
    }

    private var editorStagedCells: [StagedCellRef: SQLValue] {
        editorViewModel?.stagedCellMap(columns: activeColumns) ?? [:]
    }

    private func isBrowseMode(_ viewModel: WorkspaceViewModel) -> Bool {
        viewModel.activeTab?.isBrowseMode ?? false
    }

    private func stageCellEdit(row: Int, column: Int, text: String) {
        guard let editor = editorViewModel,
              column < activeColumns.count, row < activeRows.count else { return }
        let columnName = activeColumns[column].name
        editor.stageCell(
            row: row,
            columnName: columnName,
            original: activeRows[row][column],
            text: text,
            pkValues: editor.pkBindings(rowIndex: row, rows: activeRows, columns: activeColumns)
        )
    }

    private func setCellNull(row: Int, column: Int) {
        guard let editor = editorViewModel,
              column < activeColumns.count, row < activeRows.count else { return }
        let columnName = activeColumns[column].name
        editor.setCellNull(
            row: row,
            columnName: columnName,
            original: activeRows[row][column],
            pkValues: editor.pkBindings(rowIndex: row, rows: activeRows, columns: activeColumns)
        )
    }

    /// "+ Row": stages an all-defaults insert that renders as an editable
    /// empty row at the bottom of the grid; committing includes inserts.
    private func insertStagedRow(_ viewModel: WorkspaceViewModel) {
        guard let editor = editorViewModel, editor.isEditable,
              viewModel.activeTab?.isBrowseMode ?? false,
              !activeColumns.isEmpty else { return }
        _ = editor.insertRow(columns: activeColumns)
    }

    /// Commits staged edits for the active tab; success reloads the browse
    /// page, fires a toast, and failure shows an alert keeping staging.
    private func commitStagedEdits(_ viewModel: WorkspaceViewModel) {
        guard let editor = editorViewModel, editor.dirtyCount > 0 else { return }
        let stagedCount = editor.dirtyCount
        Task {
            await editor.commit()
            if let error = editor.lastCommitError {
                commitErrorMessage = error
            } else {
                toastCenter.show("\(stagedCount) change\(stagedCount == 1 ? "" : "s") applied")
                await viewModel.loadCurrentPage()
                refreshEditorDecision()
            }
        }
    }

    // MARK: - Export

    private enum PageExportFormat {
        case csv, json

        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            }
        }

        var contentType: UTType {
            switch self {
            case .csv: return .commaSeparatedText
            case .json: return .json
            }
        }
    }

    /// Saves the active page (or selection rows — v1 exports the whole page)
    /// via NSSavePanel; ExportService builds the payload.
    private func exportCurrentPage(as format: PageExportFormat) {
        guard !activeRows.isEmpty else { return }
        let service = ExportService()
        let content: String
        switch format {
        case .csv: content = service.buildCSV(columns: activeColumns, rows: activeRows)
        case .json: content = service.buildJSON(columns: activeColumns, rows: activeRows)
        }

        let baseName = exportBaseName()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = service.suggestedFilename(tableOrQuery: baseName, ext: format.fileExtension)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            toastCenter.show("Exported \(activeRows.count) rows to \(url.lastPathComponent)")
        } catch {
            toastCenter.show("Export failed: \(error.localizedDescription)")
        }
    }

    private func exportBaseName() -> String {
        if let browse = viewModel?.activeTab?.browse {
            return "\(browse.ref.database).\(browse.ref.name)"
        }
        return viewModel?.activeTab?.title ?? "results"
    }

    // MARK: - Explain

    private func prepareExplain(_ viewModel: WorkspaceViewModel) {
        guard let tab = viewModel.activeTab,
              let sql = ExplainGate.explainableSQL(for: tab) else { return }
        Task {
            guard let driver = await viewModel.connectedDriverForActiveTab() else { return }
            explainSQL = sql
            explainDriver = driver
        }
    }

    // MARK: - Saved queries

    /// Persists the active tab's editor text as a saved query.
    private func saveActiveEditorAsQuery() {
        guard let tab = viewModel?.activeTab else { return }
        let sql = tab.editorText
        let name = saveQueryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.isEmpty else { return }
        modelContext.insert(SavedQuery(name: name, sql: sql))
        try? modelContext.save()
        toastCenter.show("Saved “\(name)”")
    }

    private func refreshEditorDecision() {
        Task {
            await editorViewModel?.refreshDecision()
        }
    }

    // MARK: - Helpers

    private func run(_ viewModel: WorkspaceViewModel) {
        Task { await viewModel.runActive() }
    }

    private func reloadKey(_ viewModel: WorkspaceViewModel) -> String {
        let tabId = viewModel.activeTabId?.uuidString ?? "none"
        let revision = viewModel.gridRevision
        let dirty = editorViewModel?.dirtyCount ?? 0
        return "\(tabId)#\(revision)#\(dirty)"
    }

    private func editorBinding(
        _ viewModel: WorkspaceViewModel,
        tabId: UUID
    ) -> Binding<String> {
        Binding(
            get: { viewModel.tabs.first { $0.id == tabId }?.editorText ?? "" },
            set: { viewModel.setEditorText($0, for: tabId) }
        )
    }

    private func restoredSelection(_ tab: QueryTab) -> NSRange? {
        NSRange(location: tab.selectionStart, length: max(tab.selectionEnd - tab.selectionStart, 0))
    }

    private func bootstrapIfNeeded() {
        guard viewModel == nil else { return }
        let model = WorkspaceViewModel(drivers: appState.driverProvider)
        model.openQueryTab(connectionId: connectionId)
        // Batch 7: every finished run lands in the SwiftData history store.
        model.historyRecorder = HistoryRecorder(context: modelContext)
        model.connectionNameProvider = { id in
            appState.config(withID: id)?.name ?? "Unknown"
        }
        viewModel = model
        let service = RowOperationsService()
        editorViewModel = BrowseEditorViewModel(
            service: service,
            tabProvider: { [weak model] in model?.activeTab },
            driverResolver: { [weak model] in
                await model?.connectedDriverForActiveTab()
            }
        )
        // Row-index-keyed staging only describes the currently rendered page;
        // any page move or re-sort invalidates the whole tab's staged set.
        model.onBrowseSnapshotChange = { [weak service] tabId in
            service?.revertAll(tabId: tabId)
        }
        refreshEditorDecision()
        if let selected = appState.selectedTable,
           appState.selectedConnectionId == connectionId {
            openBrowse(model, table: selected)
        }
    }

    private func openBrowse(_ viewModel: WorkspaceViewModel, table ref: TableRef) {
        // New browse tabs honor the settings preference for page size.
        viewModel.openBrowseTable(ref, connectionId: connectionId, pageSize: settings.defaultRowLimit)
        refreshEditorDecision()
        Task {
            await viewModel.loadCurrentPage()
        }
    }

    /// Refreshes a browse tab when the user switches onto it while it has no data.
    private func loadBrowsePageIfIdle(_ viewModel: WorkspaceViewModel) {
        guard let tab = viewModel.activeTab, tab.isBrowseMode, tab.result.isIdleOrMissing else { return }
        Task {
            await viewModel.loadCurrentPage()
        }
    }
}

/// Thin strip above the results explaining why a browsed table is read-only.
private struct ReadOnlyBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read only: \(reason)")
    }
}

private extension Loadable {
    var isIdleOrMissing: Bool {
        switch self {
        case .idle: return true
        default: return false
        }
    }
}

import SwiftUI
import NativQLKit

/// The per-connection query workspace: tab strip, editor above results grid,
/// ⌘T / ⌘R / ⌘↩ shortcuts, and table-browse wiring from the sidebar tree.
struct WorkspaceView: View {
    let connectionId: UUID

    @Environment(AppState.self) private var appState
    @State private var viewModel: WorkspaceViewModel?
    @State private var topFraction: CGFloat = 0.4

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
        .onChange(of: viewModel.activeTabId) { _, _ in
            loadBrowsePageIfIdle(viewModel)
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
                    onRun: { run(viewModel) }
                )
            }
        }
    }

    private func resultsPane(_ viewModel: WorkspaceViewModel) -> some View {
        VStack(spacing: 0) {
            ResultsGridView(
                columns: viewModel.activeTab?.result.value?.columns ?? [],
                rows: viewModel.activeTab?.result.value?.rows ?? [],
                reloadKey: reloadKey(viewModel),
                allowsSort: viewModel.activeTab?.isBrowseMode ?? false,
                sort: viewModel.activeTab?.browse?.sort,
                onSortClick: { columnName in
                    Task { await viewModel.setSort(columnName: columnName) }
                }
            )
            Divider()
            ResultsFooterView(
                result: viewModel.activeTab?.result,
                browse: viewModel.activeTab?.browse,
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
        }
        .opacity(0)
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
    }

    // MARK: - Helpers

    private func run(_ viewModel: WorkspaceViewModel) {
        Task { await viewModel.runActive() }
    }

    private func reloadKey(_ viewModel: WorkspaceViewModel) -> String {
        let tabId = viewModel.activeTabId?.uuidString ?? "none"
        return "\(tabId)#\(viewModel.gridRevision)"
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
        viewModel = model
        if let selected = appState.selectedTable,
           appState.selectedConnectionId == connectionId {
            openBrowse(model, table: selected)
        }
    }

    private func openBrowse(_ viewModel: WorkspaceViewModel, table ref: TableRef) {
        viewModel.openBrowseTable(ref, connectionId: connectionId)
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

private extension Loadable {
    var isIdleOrMissing: Bool {
        switch self {
        case .idle: return true
        default: return false
        }
    }
}

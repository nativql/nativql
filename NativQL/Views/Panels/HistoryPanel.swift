import SwiftUI
import SwiftData
import Observation

/// Sidebar History panel: newest-first query history with search, double-click
/// to load a statement into the active editor, and per-row actions.
struct HistoryPanel: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @State private var viewModel: HistoryViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let model = HistoryViewModel(context: context)
            model.refresh()
            viewModel = model
        }
    }

    private func content(_ viewModel: HistoryViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()

            let entries = viewModel.visibleEntries
            if entries.isEmpty {
                ContentUnavailableView(
                    viewModel.searchText.isEmpty ? "No History Yet" : "No Matches",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(viewModel.searchText.isEmpty
                                      ? "Run a query and it will appear here."
                                      : "Try a different search.")
                )
            } else {
                List(entries, id: \.persistentModelID) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: QueryHistoryEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(entry.ok ? Color.secondary : Color.red)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(firstLine(of: entry.sql))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                Text("\(entry.connectionName) · \(Self.timeFormatter.localizedString(for: entry.executedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            loadIntoEditor(entry.sql)
        }
        .contextMenu {
            Button("Load into Editor") { loadIntoEditor(entry.sql) }
            Button("Copy SQL") { copy(entry.sql) }
            Divider()
            Button("Delete from History", role: .destructive) {
                viewModel?.delete(entry)
            }
        }
        .help("Double-click to load into the active editor")
    }

    private func loadIntoEditor(_ sql: String) {
        appState.pendingEditorLoad = sql
        appState.pendingEditorAutorun = false
    }

    private func copy(_ sql: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    private func firstLine(of sql: String) -> String {
        sql.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sql
    }

    private static let timeFormatter = RelativeDateTimeFormatter()
}

import SwiftUI
import SwiftData
import AppKit

/// Sidebar Saved panel: saved queries grouped by folder path with Run / Rename
/// / Move-to-folder / Delete context actions, plus minimal folder creation.
struct SavedQueriesPanel: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @State private var viewModel: SavedQueriesViewModel?
    @State private var isAddingFolder = false
    @State private var newFolderName = ""

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
            let model = SavedQueriesViewModel(context: context)
            model.refresh()
            viewModel = model
        }
    }

    private func content(_ viewModel: SavedQueriesViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Queries")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    newFolderName = ""
                    isAddingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New Folder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if viewModel.queries.isEmpty && viewModel.folders.isEmpty {
                ContentUnavailableView(
                    "Nothing Saved",
                    systemImage: "bookmark",
                    description: Text("Save the active editor from the workspace toolbar.")
                )
            } else {
                List {
                    section(viewModel.queries(inFolder: nil), title: nil, viewModel: viewModel)
                    ForEach(folderPaths(viewModel), id: \.self) { path in
                        section(viewModel.queries(inFolder: path), title: path, viewModel: viewModel)
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("New Folder", isPresented: $isAddingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Add") {
                viewModel.addFolder(named: newFolderName, parentPath: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Folders are flat in v1; queries can still be moved into them by path.")
        }
    }

    /// Known folders plus any (possibly dangling) paths referenced by queries.
    private func folderPaths(_ viewModel: SavedQueriesViewModel) -> [String] {
        let known = Set(viewModel.folders.map(\.fullPath))
        let used = Set(viewModel.queries.compactMap(\.folderPath))
        return known.union(used).sorted()
    }

    @ViewBuilder
    private func section(
        _ queries: [SavedQuery],
        title: String?,
        viewModel: SavedQueriesViewModel
    ) -> some View {
        if let title {
            DisclosureGroup {
                ForEach(queries, id: \.persistentModelID) { row($0, viewModel: viewModel) }
            } label: {
                Label(title, systemImage: "folder")
                    .font(.callout.weight(.medium))
            }
        } else {
            ForEach(queries, id: \.persistentModelID) { row($0, viewModel: viewModel) }
        }
    }

    private func row(_ query: SavedQuery, viewModel: SavedQueriesViewModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(query.name)
                .font(.callout)
                .lineLimit(1)
            Text(firstLine(of: query.sql))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { run(query) }
        .contextMenu {
            Button("Run") { run(query) }
            Button("Copy SQL") { copy(query.sql) }
            Menu("Move to Folder") {
                Button("No Folder") { viewModel.move(query, to: nil) }
                ForEach(folderPaths(viewModel).filter { $0 != query.folderPath }, id: \.self) { path in
                    Button(path) { viewModel.move(query, to: path) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { viewModel.delete(query) }
        }
        .help("Double-click to run")
    }

    private func run(_ query: SavedQuery) {
        appState.pendingEditorLoad = query.sql
        appState.pendingEditorAutorun = true
    }

    private func copy(_ sql: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    private func firstLine(of sql: String) -> String {
        sql.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sql
    }
}

import SwiftUI
import NativQLKit

/// Databases → tables/views disclosure tree for the connected profile.
/// Tables load lazily on expand; clicking a table selects it for Batch 5.
struct DatabaseTreeView: View {
    let viewModel: SidebarViewModel

    @Environment(AppState.self) private var appState
    @State private var expandedNames: Set<String> = []
    @State private var pendingDrop: DatabaseNode?
    @State private var dropFailure: String?

    var body: some View {
        List {
            switch viewModel.databases {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            case .error(let message):
                ContentUnavailableView(
                    "Could Not Load Databases",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded:
                ForEach(viewModel.nodes) { node in
                    databaseRow(node)
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: expandedNames) { _, names in
            Task {
                for name in names {
                    await viewModel.loadTables(for: name)
                }
            }
        }
        .confirmationDialog(
            "Drop database “\(pendingDrop?.info.name ?? "")”? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDrop != nil },
                set: { if !$0 { pendingDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Drop Database", role: .destructive) {
                if let name = pendingDrop?.info.name {
                    Task {
                        do {
                            try await viewModel.dropDatabase(named: name)
                            // Re-hydrate still-expanded databases after the tree rebuilt.
                            for expanded in expandedNames {
                                await viewModel.loadTables(for: expanded, force: true)
                            }
                        } catch {
                            dropFailure = error.localizedDescription
                        }
                    }
                }
                pendingDrop = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Drop Failed",
            isPresented: Binding(
                get: { dropFailure != nil },
                set: { if !$0 { dropFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropFailure ?? "")
        }
    }

    // MARK: - Rows

    private func databaseRow(_ node: DatabaseNode) -> some View {
        DisclosureGroup(isExpanded: expansion(for: node.id)) {
            tablesSection(node)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(.tint)
                Text(node.info.name)
                    .fontWeight(.medium)
                Spacer()
            }
            .contextMenu {
                Button("Refresh") {
                    Task { await viewModel.reloadTables(for: node.id) }
                }
                Divider()
                Button("Drop Database…", role: .destructive) {
                    pendingDrop = node
                }
            }
        }
    }

    @ViewBuilder
    private func tablesSection(_ node: DatabaseNode) -> some View {
        switch node.tables {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.mini)
                Text("Loading…").foregroundStyle(.secondary).font(.caption)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded(let tables):
            if tables.isEmpty {
                Text("No tables")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tables, id: \.ref) { table in
                    tableRow(table)
                }
            }
        }
    }

    private func tableRow(_ table: TableInfo) -> some View {
        let isSelected = appState.selectedTable == table.ref
        return HStack(spacing: 6) {
            Image(systemName: table.kind == .view ? "eye" : "tablecells")
                .foregroundStyle(.secondary)
            Text(table.ref.name)
                .lineLimit(1)
            Spacer()
            if let count = table.estimatedRowCount {
                Text(count.formatted())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedTable = table.ref
        }
    }

    // MARK: - Expansion

    private func expansion(for name: String) -> Binding<Bool> {
        Binding(
            get: { expandedNames.contains(name) },
            set: { isExpanded in
                if isExpanded {
                    expandedNames.insert(name)
                } else {
                    expandedNames.remove(name)
                }
            }
        )
    }
}

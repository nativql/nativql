import SwiftUI
import NativQLKit

/// App shell: connections sidebar on the left, welcome screen or per-
/// connection detail on the right.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .background {
            ShortcutsHelpOpener()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = appState.selectedConnectionId,
           case .connected = appState.state(for: id),
           let config = appState.config(withID: id) {
            ConnectionDetailView(connection: config)
        } else {
            WelcomeView()
        }
    }
}

/// Bridges the Help-menu notification (⌘/) into an openWindow call; lives
/// inside window content so it has access to the openWindow environment.
private struct ShortcutsHelpOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openShortcutsHelp)) { _ in
                openWindow(id: "shortcuts-help")
            }
    }
}

/// Which panel fills the tree column above the workspace.
enum SidebarSection: String, CaseIterable, Identifiable {
    case tables, history, saved

    var title: String {
        switch self {
        case .tables: return "Tables"
        case .history: return "History"
        case .saved: return "Saved"
        }
    }

    var id: Self { self }
}

/// Header + section-switchable tree column + Batch 5 query workspace for a
/// connected profile.
struct ConnectionDetailView: View {
    let connection: ConnectionConfig

    @Environment(AppState.self) private var appState
    @State private var treeViewModel: SidebarViewModel?
    @State private var section: SidebarSection = .tables

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                treeColumn
                    .frame(width: 240)
                Divider()
                WorkspaceView(connectionId: connection.id)
                    // Recreates the workspace (and its @State view model) when
                    // the detail switches to another connection; without this,
                    // stable structural identity lets the old VM survive and
                    // bootstrapIfNeeded() early-returns.
                    .id(connection.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Disconnect") {
                    Task { await appState.disconnect(connection.id) }
                }
            }
        }
        .task(id: connection.id) {
            let model = SidebarViewModel { appState.driver(for: connection.id) }
            treeViewModel = model
            await model.loadDatabases()
        }
    }

    private var treeColumn: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(SidebarSection.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            switch section {
            case .tables:
                if let treeViewModel {
                    DatabaseTreeView(viewModel: treeViewModel)
                } else {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                }
            case .history:
                HistoryPanel()
            case .saved:
                SavedQueriesPanel()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ColorLabelPalette.color(for: connection.colorLabel))
                .frame(width: 10, height: 10)
            Text(connection.name)
                .font(.title3.weight(.semibold))
            Text(connection.kind.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            statusGlyph
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch appState.state(for: connection.id) {
        case .connecting:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }
}

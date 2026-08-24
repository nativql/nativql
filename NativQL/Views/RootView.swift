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

/// Header + database tree + Batch 5 query workspace for a connected profile.
struct ConnectionDetailView: View {
    let connection: ConnectionConfig

    @Environment(AppState.self) private var appState
    @State private var treeViewModel: SidebarViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                tree
                Divider()
                WorkspaceView(connectionId: connection.id)
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

    @ViewBuilder
    private var tree: some View {
        if let treeViewModel {
            DatabaseTreeView(viewModel: treeViewModel)
                .frame(width: 240)
        } else {
            ProgressView()
                .frame(width: 240)
                .frame(maxHeight: .infinity)
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

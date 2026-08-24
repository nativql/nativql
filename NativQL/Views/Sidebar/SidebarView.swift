import SwiftUI
import NativQLKit

/// Left column: saved connection profiles with status, context-menu actions,
/// and a bottom bar "+" that opens the connection form.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    @State private var showForm = false
    @State private var editing: ConnectionConfig?
    @State private var pendingDelete: ConnectionConfig?
    @State private var connectFailure: String?

    var body: some View {
        @Bindable var appState = appState
        return VStack(spacing: 0) {
            List(selection: $appState.selectedConnectionId) {
                ForEach(appState.connections) { config in
                    row(config)
                        .contextMenu { contextActions(config) }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if appState.connections.isEmpty {
                    Text("No connections")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button {
                    editing = nil
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Connection")
                .padding(8)
            }
        }
        .sheet(isPresented: $showForm) {
            ConnectionFormView(editing: editing)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id {
                    appState.deleteConnection(id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Connection Failed",
            isPresented: Binding(
                get: { connectFailure != nil },
                set: { if !$0 { connectFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectFailure ?? "")
        }
    }

    // MARK: - Row

    private func row(_ config: ConnectionConfig) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ColorLabelPalette.color(for: config.colorLabel))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .bold()
                    .lineLimit(1)
                Text("\(config.user)@\(config.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            statusGlyph(for: config.id)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusGlyph(for id: UUID) -> some View {
        switch appState.state(for: id) {
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .disconnected:
            EmptyView()
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func contextActions(_ config: ConnectionConfig) -> some View {
        switch appState.state(for: config.id) {
        case .connected, .connecting:
            Button("Disconnect") {
                Task { await appState.disconnect(config.id) }
            }
        case .disconnected, .failed:
            Button("Connect") {
                connect(config)
            }
        }
        Divider()
        Button("Edit…") {
            editing = config
            showForm = true
        }
        Button("Delete…", role: .destructive) {
            pendingDelete = config
        }
    }

    private func connect(_ config: ConnectionConfig) {
        Task {
            await appState.connect(config.id)
            if case .failed(let message) = appState.state(for: config.id) {
                connectFailure = message
            }
        }
    }
}

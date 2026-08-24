import SwiftUI
import NativQLKit

/// Landing screen: title, prominent new-connection CTA, and a grid of saved
/// profiles (click to connect, double-click to edit).
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    @State private var showForm = false
    @State private var editing: ConnectionConfig?
    @State private var connectFailure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("NativQL")
                        .font(.system(size: 34, weight: .bold))
                    Text("Native PostgreSQL & MySQL client")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                Button {
                    editing = nil
                    showForm = true
                } label: {
                    Label("New Connection", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if appState.connections.isEmpty {
                    Text("No connections yet — create one to get started.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(appState.connections) { config in
                            profileCard(config)
                                .onTapGesture(count: 2) {
                                    editing = config
                                    showForm = true
                                }
                                .onTapGesture {
                                    connect(config)
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showForm) {
            ConnectionFormView(editing: editing)
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

    private func profileCard(_ config: ConnectionConfig) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(ColorLabelPalette.color(for: config.colorLabel))
                .frame(width: 14, height: 14)
            Text(config.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text("\(config.user)@\(config.host)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            statusGlyph(for: config.id)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help("Click to connect · double-click to edit")
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

    private func connect(_ config: ConnectionConfig) {
        Task {
            await appState.connect(config.id)
            if case .failed(let message) = appState.state(for: config.id) {
                connectFailure = message
            }
        }
    }
}

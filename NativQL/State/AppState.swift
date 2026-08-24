import Foundation
import NativQLKit
import Observation

/// Lifecycle of one saved connection profile in the UI.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Root observable app state. Views stay thin; mutations funnel through here
/// and the per-connection view models.
@MainActor
@Observable
final class AppState {
    private let store: ConnectionStore
    private let manager: DatabaseConnectionManager

    private(set) var connections: [ConnectionConfig]
    var connectionStates: [UUID: ConnectionState] = [:]
    var selectedConnectionId: UUID?
    /// Stub for Batch 5's query workspace; the tree writes, the workspace reads.
    var selectedTable: TableRef?

    /// One-shot text handoff from the history/saved panels into the active
    /// tab's editor; the workspace consumes it and resets to nil.
    var pendingEditorLoad: String?
    /// When true, a pending editor load should also run immediately
    /// ("Run" on a saved query).
    var pendingEditorAutorun = false

    init(
        store: ConnectionStore? = nil,
        manager: DatabaseConnectionManager? = nil
    ) {
        self.store = store ?? ConnectionStore.default()
        self.manager = manager ?? DatabaseConnectionManager()
        self.connections = self.store.connections
    }

    // MARK: - Profiles

    func refreshConnections() {
        connections = store.load()
    }

    func saveConnection(_ config: ConnectionConfig) throws {
        var updated = store.connections
        if let index = updated.firstIndex(where: { $0.id == config.id }) {
            updated[index] = config
        } else {
            updated.append(config)
        }
        try store.save(updated)
        refreshConnections()
    }

    func deleteConnection(_ id: UUID) {
        if selectedConnectionId == id {
            selectedConnectionId = nil
            selectedTable = nil
        }
        connectionStates[id] = nil
        store.remove(id: id)
        refreshConnections()
        // Teardown is async; the profile disappears from the UI immediately.
        Task { await manager.disconnect(id) }
    }

    // MARK: - Connections

    func connect(_ id: UUID) async {
        guard let config = connections.first(where: { $0.id == id }) else { return }
        connectionStates[id] = .connecting
        do {
            try await manager.connect(config)
            connectionStates[id] = .connected
        } catch {
            connectionStates[id] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ id: UUID) async {
        await manager.disconnect(id)
        connectionStates[id] = .disconnected
        if selectedConnectionId == id {
            selectedTable = nil
        }
    }

    /// Scene-phase hook (background/terminating): tear down every live driver.
    func disconnectAllIfNeeded() async {
        await manager.disconnectAll()
        connectionStates = connectionStates.mapValues { state in
            state == .connected || state == .connecting ? .disconnected : state
        }
    }

    func testConnection(_ config: ConnectionConfig) async throws {
        try await manager.test(config)
    }

    // MARK: - Helpers

    func state(for id: UUID?) -> ConnectionState {
        guard let id else { return .disconnected }
        return connectionStates[id] ?? .disconnected
    }

    func config(withID id: UUID?) -> ConnectionConfig? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    /// Live driver for a connected profile; nil otherwise.
    func driver(for id: UUID) -> (any DatabaseDriver)? {
        manager.driver(for: id)
    }

    /// Dependency slice for workspace view models (the live-driver registry).
    var driverProvider: any DriverProviding { manager }
}

import Foundation
import MySQLDriver
import NativQLKit
import PostgresDriver

/// App-level owner of live driver instances, keyed by connection profile id.
///
/// All access is MainActor-isolated; long-running network work happens inside
/// the drivers' async methods.
@MainActor
final class DatabaseConnectionManager {
    private var drivers: [UUID: any DatabaseDriver] = [:]

    /// Live driver for `id`, or nil when nothing is connected under it.
    func driver(for id: UUID) -> (any DatabaseDriver)? {
        drivers[id]
    }

    func isConnected(_ id: UUID) async -> Bool {
        guard let driver = drivers[id] else { return false }
        return await driver.isConnected()
    }

    /// Connects a profile. Connecting an already-connected id tears down the
    /// previous driver first, mirroring driver-level reconnect semantics.
    func connect(_ config: ConnectionConfig) async throws {
        if let existing = drivers[config.id] {
            await existing.disconnect()
            drivers[config.id] = nil
        }
        let driver = makeDriver(for: config.kind)
        try await driver.connect(config)
        drivers[config.id] = driver
    }

    func disconnect(_ id: UUID) async {
        guard let driver = drivers.removeValue(forKey: id) else { return }
        await driver.disconnect()
    }

    /// Tears down every live connection (app quit).
    func disconnectAll() async {
        for driver in drivers.values {
            await driver.disconnect()
        }
        drivers.removeAll()
    }

    /// Validates a config with a throwaway driver; never stores anything.
    func test(_ config: ConnectionConfig) async throws {
        let driver = makeDriver(for: config.kind)
        try await driver.testConnection(config)
    }

    private func makeDriver(for kind: DatabaseKind) -> any DatabaseDriver {
        switch kind {
        case .postgres: return PostgresDriver()
        case .mysql: return MySQLDriver()
        }
    }
}

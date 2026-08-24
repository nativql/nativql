import Foundation
import NativQLKit

/// The slice of DatabaseConnectionManager the workspace view models depend on.
/// Tests inject a fake to drive run/browse logic without live connections.
protocol DriverProviding {
    /// Live driver for `id`, or nil when nothing is connected under it.
    func driver(for id: UUID) -> (any DatabaseDriver)?
    func isConnected(_ id: UUID) async -> Bool
}

extension DatabaseConnectionManager: DriverProviding {}

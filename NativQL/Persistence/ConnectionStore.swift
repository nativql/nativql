import Foundation
import NativQLKit
import os

/// Versioned on-disk envelope for saved connection profiles.
///
/// Bump `schemaVersion` whenever the shape of stored data changes; loaders
/// should tolerate unknown future versions gracefully.
struct ConnectionStoreDocument: Codable {
    var schemaVersion: Int = 1
    var connections: [ConnectionConfig] = []
}

/// Persists connection profiles to `<directory>/connections.json`.
///
/// - The file is written atomically (temp file + rename) and chmod'ed 600 on a
///   best-effort basis; permission failures (e.g. exotic temp dirs) are logged,
///   never fatal.
/// - `load` is tolerant: a missing or corrupt file yields an empty list rather
///   than throwing, so first launch and damaged files never block the app.
final class ConnectionStore {
    static let fileName = "connections.json"

    private let directory: URL
    private let fileURL: URL
    private let logger = Logger(subsystem: "dev.nativql.app", category: "ConnectionStore")

    private(set) var connections: [ConnectionConfig]

    /// App-facing factory: ensures the Application Support directory exists and
    /// returns a store rooted there.
    static func `default`() -> ConnectionStore {
        let directory = defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConnectionStore(directory: directory)
    }

    /// - Parameter directory: Storage directory; defaults to the app's
    ///   `~/Library/Application Support/NativQL`.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fileURL = self.directory.appendingPathComponent(Self.fileName)
        self.connections = Self.readConnections(from: fileURL, logger: logger)
    }

    /// Re-reads connections from disk, returning them.
    @discardableResult
    func load() -> [ConnectionConfig] {
        connections = Self.readConnections(from: fileURL, logger: logger)
        return connections
    }

    /// Replaces the entire saved list with `connections` and writes it to disk.
    func save(_ connections: [ConnectionConfig]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = ConnectionStoreDocument(connections: connections)
        let data = try JSONEncoder().encode(document)

        let temporaryURL = directory.appendingPathComponent(
            "\(Self.fileName).tmp-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL)
        restrictToOwnerOnly(temporaryURL)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }

        self.connections = connections
    }

    /// Appends a profile and persists immediately.
    func add(_ config: ConnectionConfig) {
        var updated = connections
        updated.append(config)
        persist(updated)
    }

    /// Replaces the profile matching `config.id`. Returns `false` when no
    /// match exists, leaving stored data untouched.
    @discardableResult
    func update(_ config: ConnectionConfig) -> Bool {
        guard let index = connections.firstIndex(where: { $0.id == config.id }) else {
            return false
        }
        var updated = connections
        updated[index] = config
        persist(updated)
        return true
    }

    /// Deletes the profile with `id`. Returns `false` when nothing matched.
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard connections.contains(where: { $0.id == id }) else { return false }
        persist(connections.filter { $0.id != id })
        return true
    }

    /// In-memory state always advances; disk-write failures are surfaced via
    /// the log rather than thrown from mutation helpers.
    private func persist(_ updated: [ConnectionConfig]) {
        do {
            try save(updated)
        } catch {
            logger.error("Failed to persist connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NativQL", isDirectory: true)
    }

    private static func readConnections(from url: URL, logger: Logger) -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.debug("No saved connections yet at \(url.path, privacy: .public)")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(ConnectionStoreDocument.self, from: data)
            return document.connections
        } catch {
            logger.warning(
                "Ignoring unreadable connections file at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// Best-effort `chmod 600`; never fatal (sandboxed/exotic dirs may refuse).
    private func restrictToOwnerOnly(_ url: URL) {
        let result = chmod(url.path, 0o600)
        if result != 0 {
            logger.notice(
                "Could not restrict permissions on \(url.path, privacy: .public): errno \(result)"
            )
        }
    }
}

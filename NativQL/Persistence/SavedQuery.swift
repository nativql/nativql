import Foundation
import SwiftData

/// A user-saved SQL snippet. `folderPath` is nil for root-level entries and
/// otherwise a slash-separated path ("Reports/Q3") matching SavedFolder chains.
@Model
final class SavedQuery {
    var name: String
    var sql: String
    var folderPath: String?
    var createdAt: Date

    init(name: String, sql: String, folderPath: String? = nil, createdAt: Date = .init()) {
        self.name = name
        self.sql = sql
        self.folderPath = folderPath
        self.createdAt = createdAt
    }
}

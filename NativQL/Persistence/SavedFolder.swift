import Foundation
import SwiftData

/// A saved-queries folder. Hierarchy is path-string based: a folder under
/// "Reports" named "Q3" stores name="Q3", parentPath="Reports", and exposes
/// fullPath "Reports/Q3". Deleting a folder does not cascade; queries keep
/// their (now dangling) path until moved.
@Model
final class SavedFolder {
    var name: String
    var parentPath: String?
    var createdAt: Date

    /// Slash-joined location, e.g. "Reports/Q3"; root-level folders yield name.
    var fullPath: String {
        parentPath.map { "\($0)/\(name)" } ?? name
    }

    init(name: String, parentPath: String? = nil, createdAt: Date = .init()) {
        self.name = name
        self.parentPath = parentPath
        self.createdAt = createdAt
    }
}

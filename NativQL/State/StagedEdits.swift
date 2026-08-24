import Foundation
import NativQLKit

/// One staged cell modification on an existing browsed row.
/// `original` always holds the database value; `newValue` is what ⌘S will write.
struct CellEdit: Equatable {
    let rowIndex: Int
    let columnName: String
    let original: SQLValue
    var newValue: SQLValue
    /// Primary key snapshot of the row at staging time; drives the UPDATE WHERE clause.
    let pkValues: [String: SQLValue]
}

/// A pending new row; values are ordered by the table's column list.
struct RowInsert: Equatable {
    var values: [SQLValue]
}

/// A queued deletion identified by primary key bindings ordered per PK columns.
struct RowDelete: Equatable {
    let rowIndex: Int
    let pkValues: [SQLValue]
    /// Human-readable identity (e.g. "id=2") for menus and summaries.
    let displayPreview: String
}

enum StagedChange: Equatable {
    case cell(CellEdit)
    case insert(RowInsert)
    case delete(RowDelete)
}

/// All pending edits for one workspace tab, oldest first.
struct TabStagedEdits: Equatable {
    var changes: [StagedChange] = []
}

/// Identifies one grid cell by data-row index and result-column index for
/// staged-edit overlays and badges.
struct StagedCellRef: Hashable {
    let row: Int
    let column: Int
}

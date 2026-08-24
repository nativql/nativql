import Foundation
import NativQLKit

/// Pagination + sort state for a tab that is browsing a table's rows.
struct BrowseState: Equatable {
    var ref: TableRef
    var sort: SortSpec?
    var pageSize: Int = 200
    var pageIndex: Int
    /// Server-side row count estimate; nil while unknown.
    var totalEstimate: Int64?

    init(ref: TableRef, sort: SortSpec? = nil, pageSize: Int = 200, pageIndex: Int = 0, totalEstimate: Int64? = nil) {
        self.ref = ref
        self.sort = sort
        self.pageSize = pageSize
        self.pageIndex = pageIndex
        self.totalEstimate = totalEstimate
    }
}

/// One workspace tab: either a free-form query editor or a table browser.
struct QueryTab: Identifiable {
    let id: UUID
    var title: String
    let connectionId: UUID
    var editorText: String
    /// Editor selection as UTF-16 offsets (NSTextView semantics); empty when start == end.
    var selectionStart: Int
    var selectionEnd: Int
    var result: Loadable<QueryResult>
    var browse: BrowseState?

    init(
        id: UUID = UUID(),
        title: String,
        connectionId: UUID,
        editorText: String = "",
        selectionStart: Int = 0,
        selectionEnd: Int = 0,
        result: Loadable<QueryResult> = .idle,
        browse: BrowseState? = nil
    ) {
        self.id = id
        self.title = title
        self.connectionId = connectionId
        self.editorText = editorText
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.result = result
        self.browse = browse
    }

    var isBrowseMode: Bool { browse != nil }

    var hasSelection: Bool { selectionEnd > selectionStart }

    /// Row offset into the table this tab browses; 0 outside browse mode.
    var currentOffset: Int {
        guard let browse else { return 0 }
        return max(browse.pageIndex, 0) * browse.pageSize
    }

    /// The text ⌘R should run: the selected substring when non-empty, else all editor text.
    /// Offsets are UTF-16 based and clamped to the text bounds.
    var resolvedRunText: String {
        guard hasSelection else { return editorText }
        let ns = editorText as NSString
        let length = ns.length
        let lower = max(min(selectionStart, length), 0)
        let upper = max(min(selectionEnd, length), lower)
        return ns.substring(with: NSRange(location: lower, length: upper - lower))
    }
}

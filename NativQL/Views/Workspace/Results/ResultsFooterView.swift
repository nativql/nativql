import SwiftUI
import NativQLKit

/// Status strip under the results grid: row count · elapsed time, or the
/// error message; browse mode adds ‹ prev / page i/N / next › controls and,
/// when edits are staged, the ● N staged · ⌘S commit · Revert all group.
struct ResultsFooterView: View {
    let result: Loadable<QueryResult>?
    let browse: BrowseState?
    var dirtyCount: Int = 0
    var dirtySummary: String = ""
    var onCommit: () -> Void = {}
    var onRevertAll: () -> Void = {}
    var onNextPage: () -> Void
    var onPrevPage: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let result, case .loading = result {
                ProgressView()
                    .controlSize(.small)
            }
            status
            Spacer(minLength: 8)
            if browse != nil, dirtyCount > 0 {
                stagedGroup
                Divider()
                    .frame(height: 14)
            }
            if browse != nil {
                pager
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var stagedGroup: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            Text("\(dirtyCount) staged")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(dirtySummary.isEmpty ? "Staged changes" : "Staged: \(dirtySummary)")
            Button("Commit") {
                onCommit()
            }
            .controlSize(.small)
            .help("Commit staged changes (⌘S)")
            Button("Revert all") {
                onRevertAll()
            }
            .controlSize(.small)
            .help("Discard all staged changes")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let result {
            switch result {
            case .idle:
                Text("Ready")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .loading:
                Text("Running…")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .loaded(let queryResult):
                Text(summary(for: queryResult))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(message)
            }
        } else {
            Text("Ready")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(for queryResult: QueryResult) -> String {
        let rowCount = queryResult.rows.count
        let rows = "\(rowCount) \(rowCount == 1 ? "row" : "rows")"
        if let affected = queryResult.affectedRows, queryResult.statementType != .select {
            return "\(rows) · \(affected) affected · \(elapsed(queryResult))"
        }
        return "\(rows) · \(elapsed(queryResult))"
    }

    private func elapsed(_ queryResult: QueryResult) -> String {
        let milliseconds = queryResult.executionMilliseconds
        return milliseconds < 1 ? "<1 ms" : "\(Int(milliseconds.rounded())) ms"
    }

    // MARK: - Pager

    private var pager: some View {
        HStack(spacing: 6) {
            Button {
                onPrevPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Text(pageLabel)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(pageTooltip)

            Button {
                onNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var canGoBack: Bool {
        guard let browse else { return false }
        return browse.pageIndex > 0
    }

    private var canGoForward: Bool {
        guard let browse else { return false }
        guard let total = browse.totalEstimate else { return true }
        return (browse.pageIndex + 1) * browse.pageSize < total
    }

    private var pageCount: Int? {
        guard let browse, let total = browse.totalEstimate, total > 0 else { return nil }
        return max(Int((Double(total) / Double(browse.pageSize)).rounded(.up)), 1)
    }

    private var pageLabel: String {
        guard let browse else { return "" }
        let current = max(browse.pageIndex, 0) + 1
        return "Page \(current)\(pageCount.map { "/\($0)" } ?? "")"
    }

    private var pageTooltip: String {
        guard let browse else { return "" }
        guard let total = browse.totalEstimate else { return "Total unknown" }
        return "\(total.formatted()) rows total (estimate)"
    }
}

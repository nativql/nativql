import SwiftUI
import NativQLKit
import UniformTypeIdentifiers

/// Whole-table export sheet (sidebar table context menu): fetches pages via
/// `browseRows` up to the entered row limit (blank = all rows), shows progress,
/// then saves a CSV through NSSavePanel. `onFinish` receives a toast message on
/// success, nil when the user cancels.
struct TableExportSheet: View {
    let ref: TableRef
    let driver: any DatabaseDriver
    var onFinish: (String?) -> Void

    @State private var limitText = "1000"
    @State private var isExporting = false
    @State private var fetchedRows = 0
    @State private var errorText: String?
    @State private var isCancelled = false

    private let chunkSize = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export \(ref.database).\(ref.name)", systemImage: "tablecells")
                .font(.headline)

            if !isExporting {
                LabeledContent("Row limit") {
                    TextField("blank = all rows", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                .help("Leave blank to export every row; export loops through pages")

                Text("Exports the table as CSV in natural (unsorted) order.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(fetchedRows) rows fetched…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { isCancelled = true }
                }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()

            if !isExporting {
                HStack {
                    Spacer()
                    Button("Cancel") { onFinish(nil) }
                        .keyboardShortcut(.cancelAction)
                    Button("Export…") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }

    private func start() {
        errorText = nil
        isExporting = true
        Task { await performExport() }
    }

    /// Loops `browseRows` pages until the limit, table end, or cancellation.
    private func performExport() async {
        let parsedLimit = Int(limitText.trimmingCharacters(in: .whitespaces))
        var columns: [ColumnInfo] = []
        var rows: [[SQLValue]] = []
        var offset = 0

        do {
            while !isCancelled {
                let remaining = parsedLimit.map { max($0 - rows.count, 0) }
                let fetchSize = min(chunkSize, remaining ?? chunkSize)
                guard fetchSize > 0 else { break }
                let page = try await driver.browseRows(ref, sort: nil, limit: fetchSize, offset: offset)
                if columns.isEmpty { columns = page.columns }
                rows.append(contentsOf: page.rows)
                fetchedRows = rows.count
                if page.rows.count < fetchSize { break }
                offset += fetchSize
            }
        } catch {
            isExporting = false
            errorText = error.localizedDescription
            return
        }

        guard !isCancelled else {
            onFinish(nil)
            return
        }

        let content = ExportService().buildCSV(columns: columns, rows: rows)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = ExportService().suggestedFilename(tableOrQuery: "\(ref.database).\(ref.name)", ext: "csv")

        isExporting = false
        guard panel.runModal() == .OK, let url = panel.url else {
            onFinish(nil)
            return
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            onFinish("Exported \(rows.count) rows from \(ref.database).\(ref.name)")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

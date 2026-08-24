import SwiftUI

/// Export ▾ menu in the results footer: saves the current page as CSV/JSON.
/// Panel presentation and file writing live in the workspace view layer; the
/// string building happens in ExportService.
struct ResultsGridExportMenu: View {
    var canExport: Bool
    var onSaveCSV: () -> Void
    var onSaveJSON: () -> Void

    var body: some View {
        Menu {
            Button("Save CSV…") { onSaveCSV() }
            Button("Save JSON…") { onSaveJSON() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(!canExport)
        .help("Export the current page to a file")
    }
}

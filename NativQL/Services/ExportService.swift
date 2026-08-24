import Foundation
import NativQLKit

/// Builds export payloads by delegating to the Kit exporters and suggests
/// filenames. NSSavePanel presentation stays in the view layer so tests never
/// touch UI.
struct ExportService {
    func buildCSV(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        CSVExporter.export(columns: columns, rows: rows)
    }

    func buildJSON(columns: [ColumnInfo], rows: [[SQLValue]]) -> String {
        JSONExporter.export(columns: columns, rows: rows)
    }

    /// "public.users" + "csv" → "public.users.csv"; filesystem-hostile
    /// characters in `tableOrQuery` are flattened to underscores.
    func suggestedFilename(tableOrQuery: String, ext: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = tableOrQuery
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "export" : sanitized
        return "\(base).\(ext)"
    }
}

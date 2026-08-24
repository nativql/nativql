import AppKit
import SwiftUI
import NativQLKit

/// Read-only monospaced DDL viewer with a Copy button (sidebar table context
/// menu). Loads `driver.tableDDL` on appear.
struct DDLSheet: View {
    let ref: TableRef
    let driver: any DatabaseDriver

    @Environment(\.dismiss) private var dismiss
    @State private var ddlText: String?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DDL")
                        .font(.headline)
                    Text("\(ref.database).\(ref.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                if let ddlText {
                    ScrollView {
                        Text(ddlText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else if let errorText {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Button("Copy") { copyToPasteboard() }
                    .disabled(ddlText == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 440)
        .task(id: ref) {
            do {
                ddlText = try await driver.tableDDL(ref)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func copyToPasteboard() {
        guard let ddlText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ddlText, forType: .string)
    }
}

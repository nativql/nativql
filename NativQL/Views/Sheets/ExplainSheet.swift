import SwiftUI
import NativQLKit

/// EXPLAIN viewer: ANALYZE toggle re-runs the plan through the driver and the
/// ExplainPlanNode tree renders as a recursive DisclosureGroup list showing
/// operation, detail, actual rows, and actual time when present.
struct ExplainSheet: View {
    let sql: String
    let driver: any DatabaseDriver

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ExplainViewModel()
    @State private var analyze = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tree")
                    .foregroundStyle(.secondary)
                Text("Query Plan")
                    .font(.headline)
                Spacer()
                Toggle("ANALYZE", isOn: $analyze)
                    .controlSize(.small)
                    .help("Execute the statement and report real row counts and timings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Text(sql)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText = viewModel.errorText {
                    ScrollView {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let plan = viewModel.plan {
                    ScrollView {
                        List {
                            PlanNodeRow(node: plan)
                        }
                        .listStyle(.inset)
                    }
                } else {
                    Text("No plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Text("⌘E — EXPLAIN\(analyze ? " ANALYZE" : "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 580, minHeight: 420)
        .task(id: analyze) {
            await viewModel.run(sql: sql, driver: driver, analyze: analyze)
        }
    }
}

/// One recursive plan-tree row; leaf nodes render bare, parents get a
/// DisclosureGroup (expanded by default).
private struct PlanNodeRow: View {
    let node: ExplainPlanNode
    @State private var isExpanded = true

    var body: some View {
        Group {
            if node.children.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(node.children.indices, id: \.self) { index in
                        PlanNodeRow(node: node.children[index])
                    }
                } label: {
                    label
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(node.operation)
                .fontWeight(node.children.isEmpty ? .regular : .medium)
            if let detail = node.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            metrics
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metrics: some View {
        HStack(spacing: 8) {
            if let rows = node.actualRows {
                Text("\(rows.formatted()) rows")
            }
            if let time = node.actualTimeMilliseconds {
                Text(String(format: "%.2f ms", time))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .help("Actual rows · actual time (ANALYZE)")
    }
}

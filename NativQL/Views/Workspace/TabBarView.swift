import SwiftUI

/// Horizontal tab strip for the workspace: title + close button per tab and a
/// "+" button appending a new query tab. ⌘T lives at the workspace level.
struct TabBarView: View {
    let viewModel: WorkspaceViewModel
    let connectionId: UUID

    var body: some View {
        HStack(spacing: 4) {
            ForEach(viewModel.tabs) { tab in
                TabButton(
                    title: tab.title,
                    isActive: tab.id == viewModel.activeTabId,
                    onSelect: { viewModel.activeTabId = tab.id },
                    onClose: { viewModel.closeTab(id: tab.id) }
                )
            }
            Spacer(minLength: 8)
            Button {
                let target = viewModel.activeTab?.connectionId ?? connectionId
                viewModel.openQueryTab(connectionId: target, forceNew: true)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("New query tab (⌘T)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabButton: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout.weight(isActive ? .medium : .regular))
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

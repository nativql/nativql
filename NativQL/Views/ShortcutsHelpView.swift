import SwiftUI

/// Static keyboard-shortcut reference, opened via the Help menu (⌘/) or the
/// Window menu entry for the "shortcuts-help" window scene.
struct ShortcutsHelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    private let entries: [Entry] = [
        Entry(keys: "⌘R  /  ⌘↩", action: "Run query (selection or whole editor)"),
        Entry(keys: "⌘T", action: "New query tab"),
        Entry(keys: "⌘S", action: "Commit staged edits"),
        Entry(keys: "⌘E", action: "Explain current statement"),
        Entry(keys: "⌘/", action: "This help"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.title2.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.keys)
                            .font(.body.monospaced().weight(.medium))
                            .frame(minWidth: 110, alignment: .trailing)
                        Text(entry.action)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 240)
    }
}

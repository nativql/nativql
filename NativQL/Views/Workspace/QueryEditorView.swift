import AppKit
import SwiftUI

/// SwiftUI wrapper around a horizontally-scrollable SQL editor
/// (`NSTextView` + line-number ruler), highlighting on every change.
struct QueryEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Applied when the underlying content is replaced externally (tab switch).
    var restoredSelection: NSRange?
    var onSelectionChange: ((Int, Int) -> Void)?
    var onRun: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = QueryEditorTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont(name: "Menlo-Regular", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.documentView = textView

        Self.synchronizeFrame(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? QueryEditorTextView else { return }
        textView.onRun = onRun

        if textView.string != text {
            let desired = restoredSelection ?? textView.selectedRanges.first?.rangeValue
            textView.string = text
            SQLHighlighter.apply(to: textView.textStorage!)
            if let desired {
                let length = (text as NSString).length
                let location = min(max(desired.location, 0), length)
                let upperBound = min(max(desired.location + desired.length, location), length)
                textView.setSelectedRange(NSRange(location: location, length: upperBound - location))
            }
            Self.synchronizeFrame(textView)
        }
    }

    // MARK: - Layout

    /// Sizes the text view to its laid-out content so horizontal scrolling has
    /// an exact document width and no wrap occurs.
    private static func synchronizeFrame(_ textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let used = layoutManager.usedRect(for: container)
        let insets = scrollView.contentInsets
        textView.frame.size = NSSize(
            width: max(
                used.maxX + used.minX + textView.textContainerInset.width * 2
                    + insets.left + insets.right,
                scrollView.contentSize.width
            ),
            height: max(
                used.maxY + textView.textContainerInset.height * 2 + insets.top + insets.bottom,
                scrollView.contentSize.height
            )
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryEditorView

        init(_ parent: QueryEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            SQLHighlighter.apply(to: textView.textStorage!)
            QueryEditorView.synchronizeFrame(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRanges.first?.rangeValue
                ?? NSRange(location: 0, length: 0)
            parent.onSelectionChange?(range.location, range.location + range.length)
        }
    }
}

/// Text view adding ⌘↩ / ⌘R run handling before default key equivalents.
final class QueryEditorTextView: NSTextView {
    var onRun: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command,
              let key = event.charactersIgnoringModifiers,
              key == "\r" || key.lowercased() == "r" else {
            return super.performKeyEquivalent(with: event)
        }
        onRun?()
        return true
    }
}

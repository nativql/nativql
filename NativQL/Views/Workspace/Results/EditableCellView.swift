import AppKit

/// Inline cell editor: a single bordered text field overlaid on the results
/// grid. Return (or focus loss) commits the typed text, Esc cancels.
final class EditableCellView: NSView {
    private let field: NSTextField
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void
    /// Guards against double-firing when dismissal itself ends text editing.
    private var finished = false

    init(
        initialValue: String,
        placeholder: String?,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let textField = NSTextField(string: initialValue)
        field = textField
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.placeholderString = placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Places the editor over `cellRect` inside `host` and focuses it.
    static func present(
        in host: NSView,
        cellRect: CGRect,
        initialValue: String,
        placeholder: String?,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> EditableCellView {
        let editor = EditableCellView(
            initialValue: initialValue,
            placeholder: placeholder,
            onCommit: onCommit,
            onCancel: onCancel
        )
        let frame = cellRect.insetBy(dx: 1, dy: 1)
        editor.frame = frame.isEmpty ? cellRect : frame
        host.addSubview(editor)
        editor.field.selectText(nil)
        DispatchQueue.main.async {
            editor.window?.makeFirstResponder(editor.field)
        }
        return editor
    }

    func dismiss() {
        finished = true
        if field.currentEditor() != nil {
            window?.makeFirstResponder(superview)
        }
        removeFromSuperview()
    }
}

extension EditableCellView: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = textView.string
            dismiss()
            onCommit(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            onCancel()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !finished else { return }
        let text = field.stringValue
        dismiss()
        onCommit(text)
    }
}

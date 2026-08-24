import AppKit
import NativQLKit

/// Display text for a SQL value; shared by the grid cell and copy-to-clipboard.
enum CellFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let datetimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func text(for value: SQLValue) -> String {
        switch value {
        case .null: return "NULL"
        case .bool(let bool): return bool ? "true" : "false"
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .decimal(let raw): return raw
        case .string(let string): return string
        case .date(let date): return dateFormatter.string(from: date)
        case .time(let seconds):
            let total = Int(seconds.rounded(.down))
            return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        case .datetime(let date): return datetimeFormatter.string(from: date)
        case .json(let raw): return raw
        case .bytes(let data): return "\(data.count) bytes"
        }
    }

    /// Numeric values render right-aligned in the grid.
    static func isRightAligned(_ value: SQLValue) -> Bool {
        switch value {
        case .int, .double, .decimal: return true
        default: return false
        }
    }
}

/// One grid cell: a non-editable text field rendering a single SQLValue.
/// NULL renders as italic gray placeholder-style "NULL".
final class CellContentView: NSTableCellView {
    private let label: NSTextField

    init(identifier: NSUserInterfaceItemIdentifier) {
        let field = NSTextField(labelWithString: "")
        label = field
        super.init(frame: .zero)
        self.identifier = identifier

        field.isEditable = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(_ value: SQLValue?) {
        guard let value else {
            label.stringValue = ""
            return
        }
        label.stringValue = CellFormatter.text(for: value)
        label.alignment = CellFormatter.isRightAligned(value) ? .right : .left
        if value == .null {
            label.font = NSFont.systemFont(ofSize: 12).italicized()
            label.textColor = .tertiaryLabelColor
        } else {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
        }
    }
}

private extension NSFont {
    func italicized() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

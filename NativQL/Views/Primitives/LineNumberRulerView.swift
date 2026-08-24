import AppKit

/// Vertical ruler drawing monospaced line numbers alongside a text view.
final class LineNumberRulerView: NSRulerView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var cachedLineCount = 0
    private var cachedTextLength = -1

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let storage = textView.textStorage else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        adjustThickness(for: storage)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let nsText = storage.string as NSString
        guard nsText.length > 0 else {
            NSAttributedString(string: "1", attributes: attributes)
                .draw(at: NSPoint(x: bounds.width - 14, y: bounds.minY + 3))
            return
        }

        let visibleRect = textView.visibleRect
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard visibleGlyphs.length > 0 else { return }

        let firstVisibleCharacter = layoutManager.characterIndexForGlyph(at: visibleGlyphs.location)
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        let probeRange = NSRange(location: min(firstVisibleCharacter, nsText.length - 1), length: 0)
        nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: probeRange)
        var lineNumber = countNewlines(before: lineStart, in: nsText) + 1

        while true {
            let drawn = draw(
                number: lineNumber,
                atLineStartIndex: lineStart,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer,
                attributes: attributes,
                textLength: nsText.length
            )
            if !drawn { break } // scrolled past the visible bottom
            if lineEnd >= nsText.length { break }
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: lineEnd, length: 0))
            lineNumber += 1
        }
    }

    /// Draws one number aligned to its line's first fragment; returns false once
    /// the line starts below the visible area.
    @discardableResult
    private func draw(
        number: Int,
        atLineStartIndex lineStart: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        attributes: [NSAttributedString.Key: Any],
        textLength: Int
    ) -> Bool {
        let characterRange = NSRange(location: lineStart, length: max(textLength - lineStart, 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphs.location != NSNotFound else { return false }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let localRect = convert(fragment, from: textView)
        guard localRect.maxY >= bounds.minY else { return true }
        guard localRect.minY <= bounds.maxY else { return false }

        let label = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = label.size()
        label.draw(at: NSPoint(
            x: bounds.width - size.width - 5,
            y: localRect.minY + (localRect.height - size.height) / 2
        ))
        return true
    }

    private func countNewlines(before index: Int, in text: NSString) -> Int {
        var count = 0
        for i in 0..<min(index, text.length) where text.character(at: i) == unichar(0x0A) {
            count += 1
        }
        return count
    }

    private func adjustThickness(for storage: NSTextStorage) {
        if cachedTextLength != storage.length {
            cachedTextLength = storage.length
            cachedLineCount = countNewlines(before: storage.length, in: storage.string as NSString) + 1
        }
        let digits = max(String(cachedLineCount).count, 1)
        let charWidth = "\(String(repeating: "8", count: digits))".size(withAttributes: [.font: font]).width
        let needed = (charWidth + 12).rounded(.up)
        if abs(ruleThickness - needed) > 0.5 {
            ruleThickness = needed
        }
    }
}

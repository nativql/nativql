import SwiftUI

/// The six fixed profile-color swatches offered by the connection form.
enum ColorLabelPalette {
    static let presets: [String] = [
        "FF453A", // red
        "FF9F0A", // orange
        "32D74B", // green
        "0A84FF", // blue
        "BF5AF2", // purple
        "FF375F", // pink
    ]

    /// Resolves a saved `colorLabel` hex string to a color, falling back to
    /// the engine accent when unset or malformed. Uses sRGB components so the
    /// dots read correctly in light and dark mode alike.
    static func color(for label: String?) -> Color {
        guard let hex = label?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return .accentColor
        }
        return color(hex: hex)
    }

    static func color(hex: String) -> Color {
        var sanitized = hex.trimmingCharacters(in: .whitespaces)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6,
              let value = UInt64(sanitized, radix: 16) else {
            return .accentColor
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

import Foundation
import Observation

enum SettingsKey {
    static let editorFontSize = "editorFontSize"
    static let defaultRowLimit = "defaultRowLimit"
}

/// User-facing editor + browse settings, persisted to UserDefaults and clamped
/// to their valid ranges. Query timeout is intentionally absent: drivers do
/// not enforce timeouts yet, so there is nothing to store.
@MainActor
@Observable
final class SettingsStore {
    static let fontSizeRange: ClosedRange<Double> = 11...20
    static let rowLimitRange: ClosedRange<Int> = 50...1000

    private let defaults: UserDefaults
    // Backing storage keeps clamping inside the setters without reassigning
    // the observed property from its own didSet (which would recurse).
    private var fontSizeStorage: Double
    private var rowLimitStorage: Int

    var editorFontSize: Double {
        get { fontSizeStorage }
        set {
            fontSizeStorage = Self.clamp(newValue, to: Self.fontSizeRange)
            defaults.set(fontSizeStorage, forKey: SettingsKey.editorFontSize)
        }
    }

    var defaultRowLimit: Int {
        get { rowLimitStorage }
        set {
            rowLimitStorage = Self.clamp(newValue, to: Self.rowLimitRange)
            defaults.set(rowLimitStorage, forKey: SettingsKey.defaultRowLimit)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontSizeStorage = Self.clamp(
            defaults.object(forKey: SettingsKey.editorFontSize) as? Double ?? 13,
            to: Self.fontSizeRange
        )
        self.rowLimitStorage = Self.clamp(
            defaults.object(forKey: SettingsKey.defaultRowLimit) as? Int ?? 200,
            to: Self.rowLimitRange
        )
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

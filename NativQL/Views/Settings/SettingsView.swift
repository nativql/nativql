import SwiftUI

/// Settings scene: editor font size, default browse page size for new tabs,
/// and a note that query timeout is stored-but-not-yet-enforced (v1 drivers
/// have no timeout support, so no such preference exists yet).
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Editor") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(
                            value: $settings.editorFontSize,
                            in: SettingsStore.fontSizeRange,
                            step: 1
                        )
                        Text(Int(settings.editorFontSize).formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }

            Section("Data Browser") {
                Stepper(
                    "Rows per new tab: \(settings.defaultRowLimit)",
                    value: $settings.defaultRowLimit,
                    in: SettingsStore.rowLimitRange,
                    step: 50
                )
            }

            Section {
                Label(
                    "Query timeout is not yet enforced by database drivers.",
                    systemImage: "hourglass"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
    }
}

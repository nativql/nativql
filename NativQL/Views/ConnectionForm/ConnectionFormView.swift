import SwiftUI
import NativQLKit

/// Sheet for creating or editing a connection profile: identity fields, SSL,
/// color swatches, paste-URL import, live test, and validated save.
struct ConnectionFormView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private let existing: ConnectionConfig?

    @State private var name: String
    @State private var kind: DatabaseKind
    @State private var host: String
    @State private var port: Int
    @State private var user: String
    @State private var password: String
    @State private var database: String
    @State private var sslMode: SSLMode
    @State private var colorLabel: String?
    /// Set once the user edits the port manually or pastes a URL, so the kind
    /// picker stops overriding it with engine defaults.
    @State private var portTouched = false

    @State private var showPasteField = false
    @State private var pastedURL = ""
    @State private var parseError: String?

    private enum TestOutcome: Equatable {
        case idle, running, success, failure(String)
    }
    @State private var testOutcome: TestOutcome = .idle

    @State private var saveError: String?

    init(editing: ConnectionConfig?) {
        existing = editing
        _name = State(initialValue: editing?.name ?? "")
        _kind = State(initialValue: editing?.kind ?? .postgres)
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: editing?.port ?? DatabaseKind.postgres.defaultPort)
        _user = State(initialValue: editing?.user ?? "")
        _password = State(initialValue: editing?.password ?? "")
        _database = State(initialValue: editing?.database ?? "")
        _sslMode = State(initialValue: editing?.sslMode ?? .prefer)
        _colorLabel = State(initialValue: editing?.colorLabel)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Marks the port as user-touched only when the field itself writes, so the
    /// kind picker can keep restoring defaults until then.
    private var portBinding: Binding<Int> {
        Binding(
            get: { port },
            set: {
                port = $0
                portTouched = true
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Connection") {
                        TextField("Name", text: $name)
                        Picker("Kind", selection: $kind) {
                            ForEach(DatabaseKind.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .onChange(of: kind) { _, newKind in
                            if !portTouched {
                                port = newKind.defaultPort
                            }
                            if !SSLMode.availableModes(for: newKind).contains(sslMode) {
                                sslMode = .prefer
                            }
                        }

                        TextField("Host", text: $host)
                        TextField("Port", value: portBinding, format: .number.grouping(.never))
                        TextField("User", text: $user)
                        SecureField("Password", text: $password)
                        TextField("Database (optional)", text: $database)
                        Picker("SSL Mode", selection: $sslMode) {
                            ForEach(SSLMode.availableModes(for: kind), id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }

                    Section("Color") {
                        swatches
                    }

                    Section("Import") {
                        pasteURLSection
                    }
                }
                .formStyle(.grouped)

                Divider()
                footer
            }
            .frame(width: 460)
            .navigationTitle(existing == nil ? "New Connection" : "Edit Connection")
            .alert(
                "Could Not Save",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var pasteURLSection: some View {
        DisclosureGroup("Paste URL…", isExpanded: $showPasteField) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "postgresql://user:pass@host:5432/db",
                    text: $pastedURL
                )
                HStack {
                    Button("Apply") { applyPastedURL() }
                        .disabled(pastedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let parseError {
                        Text(parseError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Sections

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(ColorLabelPalette.presets, id: \.self) { hex in
                Circle()
                    .fill(ColorLabelPalette.color(hex: hex))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle()
                            .strokeBorder(colorLabel == hex ? Color.primary : .clear, lineWidth: 1.5)
                            .padding(-3)
                    }
                    .contentShape(Circle())
                    .onTapGesture { colorLabel = hex }
                    .accessibilityLabel("Color \(hex)")
            }
            Spacer()
            Button("None") { colorLabel = nil }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            testControls
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(12)
    }

    @ViewBuilder
    private var testControls: some View {
        HStack(spacing: 8) {
            Button("Test Connection") { runTest() }
                .disabled(!canSave || testOutcome == .running)
            switch testOutcome {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Connection succeeded")
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
    }

    // MARK: - Actions

    private func applyPastedURL() {
        parseError = nil
        do {
            let parsed = try ConnectionStringParser.parse(pastedURL)
            kind = parsed.kind
            host = parsed.host
            port = parsed.port
            user = parsed.user
            password = parsed.password ?? ""
            database = parsed.database ?? ""
            sslMode = parsed.sslMode
            portTouched = true
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = parsed.name
            }
            pastedURL = ""
        } catch ConnectionStringParserError.unsupportedScheme(let scheme) {
            parseError = "Unsupported scheme “\(scheme)” — use postgresql:// or mysql://"
        } catch {
            parseError = "Not a valid connection URL."
        }
    }

    private func buildConfig() -> ConnectionConfig {
        ConnectionConfig(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            user: user.trimmingCharacters(in: .whitespaces),
            password: password.isEmpty ? nil : password,
            database: database.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : database.trimmingCharacters(in: .whitespaces),
            sslMode: sslMode,
            colorLabel: colorLabel
        )
    }

    private func runTest() {
        let config = buildConfig()
        testOutcome = .running
        Task {
            do {
                try await appState.testConnection(config)
                testOutcome = .success
            } catch {
                testOutcome = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        do {
            try appState.saveConnection(buildConfig())
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

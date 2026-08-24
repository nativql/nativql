import SwiftUI
import Observation

/// App-wide transient toast queue (v1 shows one message at a time).
@MainActor
@Observable
final class ToastCenter {
    private(set) var message: String?
    private var dismissTask: Task<Void, Never>?

    /// Shows `message` bottom-center; auto-dismisses after 3 seconds.
    func show(_ message: String) {
        self.message = message
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// Bottom-center overlay rendering the active toast; non-interactive.
struct ToastView: View {
    let center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let message = center.message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.callout)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 26)
        .animation(.spring(duration: 0.25), value: center.message)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(center.message ?? "")
    }
}

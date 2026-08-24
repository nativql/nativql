import SwiftUI

/// Vertical split container: `top` above `bottom` with a draggable divider.
/// The divider is a thin visual line inside a wider hit area.
struct VSplitLayout<Top: View, Bottom: View>: View {
    @Binding var topFraction: CGFloat
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    private let hotZoneHeight: CGFloat = 8
    private let limits: ClosedRange<CGFloat> = 0.15...0.85

    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = max(geometry.size.height - hotZoneHeight, 0)
            let clamped = min(max(topFraction, limits.lowerBound), limits.upperBound)
            VStack(spacing: 0) {
                top()
                    .frame(height: available * clamped)
                divider(height: available)
                bottom()
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func divider(height available: CGFloat) -> some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
        }
        .frame(height: hotZoneHeight)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStartFraction ?? topFraction
                    if dragStartFraction == nil { dragStartFraction = topFraction }
                    guard available > 0 else { return }
                    let next = (start * available + value.translation.height) / available
                    topFraction = min(max(next, limits.lowerBound), limits.upperBound)
                }
                .onEnded { _ in dragStartFraction = nil }
        )
    }
}

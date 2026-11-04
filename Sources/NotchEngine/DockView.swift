import SwiftUI
import NotchKit

/// Row of app icons for switching the expanded notch's content.
struct DockView: View {
    let model: NotchViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.apps, id: \.id) { app in
                DockItem(app: app, isSelected: app.id == model.selectedAppID) {
                    model.select(app.id)
                }
            }
        }
    }
}

private struct DockItem: View {
    let app: any NotchApp
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    /// The name label, shown after resting on the icon briefly (like a browser tab's tooltip). macOS tooltips
    /// (`.help`) don't reliably show here: NotchMan is never the active app.
    @State private var showsName = false
    @State private var nameDelay: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: app.iconSystemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(isSelected ? 0.18 : hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let badge = app.dockBadge { BadgeMark(badge: badge).offset(x: 1, y: -1) }
        }
        .overlay(alignment: .top) {
            if showsName {
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(white: 0.22))
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    )
                    .offset(y: 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            hovering = inside
            nameDelay?.cancel()
            if inside {
                nameDelay = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.12)) { showsName = true }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) { showsName = false }
            }
        }
    }
}

private struct BadgeMark: View {
    let badge: NotchBadge
    @State private var pulse = false

    var body: some View {
        switch badge {
        case .dot(let color):
            Circle().fill(color).frame(width: 6, height: 6)
        case .busy:
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
        }
    }
}

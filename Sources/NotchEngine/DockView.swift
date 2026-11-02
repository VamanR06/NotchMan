import SwiftUI
import NotchKit

/// Row of app icons for switching the expanded notch's content: as many as fit beside the physical notch,
/// then an All Apps button for the rest (see `NotchViewModel.dockApps`).
struct DockView: View {
    let model: NotchViewModel

    var body: some View {
        let dock = model.dockApps
        HStack(spacing: model.dockSpacing) {
            ForEach(dock.shown, id: \.id) { app in
                DockItem(name: app.name, systemImage: app.iconSystemName, badge: app.dockBadge,
                         isSelected: app.id == model.selectedAppID && !model.isLauncherOpen) {
                    model.select(app.id)
                }
            }
            if dock.overflow {
                DockItem(name: "All Apps", systemImage: "square.grid.2x2", badge: hiddenBadge(shown: dock.shown),
                         isSelected: model.isLauncherOpen, action: model.toggleLauncher)
            }
        }
        .frame(width: model.expandedWingWidth, alignment: .leading)
    }

    /// The most pressing badge among apps not in the row, so nothing waiting goes unseen.
    private func hiddenBadge(shown: [any NotchApp]) -> NotchBadge? {
        let ids = Set(shown.map(\.id))
        let badges = model.apps.filter { !ids.contains($0.id) }.compactMap(\.dockBadge)
        return badges.first { if case .dot = $0 { true } else { false } } ?? badges.first
    }
}

/// Every app as a tile, over the selected app's content. Opened from the dock's All Apps button.
struct AppLauncher: View {
    let model: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 8)], spacing: 8) {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    LauncherTile(app: app, shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                                 isSelected: app.id == model.selectedAppID) {
                        model.select(app.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }
}

private struct LauncherTile: View {
    let app: any NotchApp
    let shortcut: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: app.iconSystemName)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if let badge = app.dockBadge { BadgeMark(badge: badge).offset(x: 5, y: -2) }
                    }
                Text(app.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .foregroundStyle(.white.opacity(isSelected || hovering ? 1 : 0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(isSelected ? 0.16 : hovering ? 0.1 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DockItem: View {
    let name: String
    let systemImage: String
    let badge: NotchBadge?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    /// The name label, shown after resting on the icon briefly (like a browser tab's tooltip). macOS tooltips
    /// (`.help`) don't reliably show here: NotchMan is never the active app.
    @State private var showsName = false
    @State private var nameDelay: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
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
            if let badge { BadgeMark(badge: badge).offset(x: 1, y: -1) }
        }
        .overlay(alignment: .top) {
            if showsName {
                Text(name)
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

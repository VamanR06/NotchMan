import SwiftUI
import NotchKit

/// Row of app icons for switching the expanded notch's content. It stays left of the notch: when the icons don't
/// fit there (a laptop's real notch would hide them), they get tighter, and then the last ones move into a » menu.
struct DockView: View {
    let model: NotchViewModel

    var body: some View {
        let selected = model.apps.firstIndex { $0.id == model.selectedApp?.id }
        let layout = DockLayout.fit(count: model.apps.count, selected: selected, width: model.dockWidth)
        HStack(spacing: layout.spacing) {
            ForEach(layout.shown, id: \.self) { index in
                let app = model.apps[index]
                DockItem(app: app, isSelected: index == selected, width: layout.itemWidth) {
                    model.select(app.id)
                }
            }
            if !layout.overflow.isEmpty {
                MoreApps(model: model, apps: layout.overflow.map { model.apps[$0] })
            }
        }
    }
}

/// How the dock fits its room: full-size icons if they fit, else tighter ones, else as many tight ones as fit
/// followed by a » menu of the rest. The selected app always shows, taking the last slot if it would be hidden.
struct DockLayout: Equatable {
    var itemWidth: CGFloat
    var spacing: CGFloat
    /// Apps shown as icons, by index, in dock order.
    var shown: [Int]
    /// Apps in the » menu, by index.
    var overflow: [Int]

    /// Icon slot widths and gaps, roomiest first.
    static let sizes: [(item: CGFloat, spacing: CGFloat)] = [(28, 4), (24, 2), (22, 1)]
    static let moreWidth: CGFloat = 20

    static func fit(count: Int, selected: Int?, width: CGFloat) -> DockLayout {
        func needed(_ size: (item: CGFloat, spacing: CGFloat)) -> CGFloat {
            CGFloat(count) * size.item + CGFloat(max(count - 1, 0)) * size.spacing
        }
        for size in sizes where needed(size) <= width {
            return DockLayout(itemWidth: size.item, spacing: size.spacing, shown: Array(0..<count), overflow: [])
        }
        let size = sizes[sizes.count - 1]
        let fitting = Int((width - moreWidth) / (size.item + size.spacing))
        var shown = Array(0..<min(max(fitting, 1), count))
        if let selected, selected >= shown.count { shown[shown.count - 1] = selected }
        let overflow = (0..<count).filter { !shown.contains($0) }
        return DockLayout(itemWidth: size.item, spacing: size.spacing, shown: shown, overflow: overflow)
    }
}

/// » — the apps that didn't fit in the dock, with a dot when one of them has a badge.
private struct MoreApps: View {
    let model: NotchViewModel
    let apps: [any NotchApp]

    var body: some View {
        Menu {
            ForEach(apps, id: \.id) { app in
                Button { model.select(app.id) } label: { Label(app.name, systemImage: app.iconSystemName) }
            }
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: DockLayout.moreWidth, height: 24)
        .overlay(alignment: .topTrailing) {
            if apps.contains(where: { $0.dockBadge != nil }) {
                Circle().fill(.white.opacity(0.8)).frame(width: 5, height: 5).offset(x: 1, y: 1)
            }
        }
        .help(apps.map(\.name).joined(separator: ", "))
    }
}

private struct DockItem: View {
    let app: any NotchApp
    let isSelected: Bool
    let width: CGFloat
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
                .frame(width: width, height: 24)
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

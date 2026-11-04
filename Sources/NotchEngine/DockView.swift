import SwiftUI
import NotchKit

/// Row of app icons for switching the expanded notch's content. It stays left of the notch: when not every icon
/// fits there (a laptop's real notch would hide them), the ones that fit are followed by an Apps button that opens
/// every app as a grid, like Launchpad.
struct DockView: View {
    let model: NotchViewModel

    var body: some View {
        let selected = model.apps.firstIndex { $0.id == model.selectedApp?.id }
        let layout = DockLayout.fit(count: model.apps.count, selected: selected, width: model.dockWidth)
        HStack(spacing: DockLayout.spacing) {
            ForEach(layout.shown, id: \.self) { index in
                let app = model.apps[index]
                DockItem(app: app, isSelected: index == selected && !model.showingAppGrid) {
                    model.select(app.id)
                }
            }
            if layout.hasAppsButton {
                AppsButton(model: model, hidden: model.apps.indices.filter { !layout.shown.contains($0) }.map { model.apps[$0] })
            }
        }
    }
}

/// How the dock fits its room: every icon if they fit, else as many as fit followed by the Apps button. The
/// selected app always shows, taking the last slot if it would be left out.
struct DockLayout: Equatable {
    /// Apps shown as icons, by index, in dock order.
    var shown: [Int]
    var hasAppsButton: Bool

    static let itemWidth: CGFloat = 28
    static let spacing: CGFloat = 4
    /// A touch narrower than an icon, so a fifth icon fits beside a laptop's notch.
    static let appsButtonWidth: CGFloat = 26

    static func fit(count: Int, selected: Int?, width: CGFloat) -> DockLayout {
        let all = CGFloat(count) * itemWidth + CGFloat(max(count - 1, 0)) * spacing
        guard all > width else { return DockLayout(shown: Array(0..<count), hasAppsButton: false) }
        // Icons, each followed by a gap, then the Apps button.
        let fitting = Int((width - appsButtonWidth) / (itemWidth + spacing))
        var shown = Array(0..<min(max(fitting, 1), count))
        if let selected, selected >= shown.count { shown[shown.count - 1] = selected }
        return DockLayout(shown: shown, hasAppsButton: true)
    }
}

/// Opens (or closes) the Apps grid; a dot when an app that isn't in the dock has a badge.
private struct AppsButton: View {
    @Bindable var model: NotchViewModel
    /// Apps not in the dock.
    let hidden: [any NotchApp]
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.showingAppGrid.toggle() }
        } label: {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.showingAppGrid ? .white : .white.opacity(0.55))
                .frame(width: DockLayout.appsButtonWidth, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(model.showingAppGrid ? 0.18 : hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if let badge = hidden.lazy.compactMap(\.dockBadge).first { BadgeMark(badge: badge).offset(x: 1, y: -1) }
        }
    }
}

/// Every app as a grid, like Launchpad, over the expanded content. Click one to open it; click outside the grid or
/// press Esc to close it.
struct AppGrid: View {
    let model: NotchViewModel

    var body: some View {
        // Two rows for up to a dozen apps.
        let columns = min(model.apps.count, min(max(4, (model.apps.count + 1) / 2), 6))
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.6))
                .contentShape(Rectangle())
                .onTapGesture { close() }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 8), count: columns), spacing: 10) {
                ForEach(model.apps, id: \.id) { app in
                    AppTile(app: app, isSelected: app.id == model.selectedApp?.id) { model.select(app.id) }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.showingAppGrid = false }
    }
}

/// One app in the grid: its icon on a tile, its name underneath.
private struct AppTile: View {
    let app: any NotchApp
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: app.iconSystemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.white.opacity(isSelected ? 0.28 : hovering ? 0.2 : 0.12))
                    )
                    .overlay(alignment: .topTrailing) {
                        if let badge = app.dockBadge { BadgeMark(badge: badge).offset(x: 2, y: -2) }
                    }
                Text(app.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
                    .lineLimit(1)
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                .frame(width: DockLayout.itemWidth, height: 24)
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

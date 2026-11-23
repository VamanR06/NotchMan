import SwiftUI
import NotchKit

struct NotchRootView: View {
    let model: NotchViewModel
    let commandBar: CommandBarModel
    let openSettings: () -> Void
    let openCommandBar: () -> Void
    let closeCommandBar: () -> Void

    var body: some View {
        let shape = NotchShape(topRadius: model.topCornerRadius, bottomRadius: model.bottomCornerRadius)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch model.state {
                case .collapsed:
                    collapsedContent
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                case .expanded:
                    // Laid out at full expanded size so it never reflows while the shape animates;
                    // the shrinking shape clips it and it fades out quickly on close.
                    expandedContent
                        .frame(width: model.expandedSize.width, height: model.expandedSize.height, alignment: .top)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))
                        ))
                }
            }
            .frame(width: model.shapeSize.width, height: model.shapeSize.height, alignment: .top)
            // No focus rings on the notch's buttons (with Full Keyboard Access on, taking the keyboard drew them).
            .focusEffectDisabled()
            .clipShape(shape)
            .background(
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(model.state == .expanded ? 0.45 : 0), radius: 14, y: 6)
            )
            .offset(x: model.shapeOffsetX)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.shapeSize)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.shapeOffsetX)
            .scaleEffect(model.pulsing ? 1.08 : 1, anchor: .top)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var collapsedContent: some View {
        let layout = model.collapsedLayout
        if let transient = model.transient {
            TransientView(transient: transient, sideWidth: model.transientSideWidth,
                          notchWidth: model.geometry.notchSize.width)
                .padding(.horizontal, model.topCornerRadius)
                .frame(maxHeight: .infinity)
        } else if !layout.isEmpty {
            HStack(spacing: 0) {
                // Left side, outer edge → notch. Chips hug the notch side of their slot so gaps stay even.
                HStack(spacing: model.activitySpacing) {
                    ForEach(layout.left.reversed(), id: \.id) { entry in
                        chipSlot(entry)
                    }
                    if let split = layout.split?.activity {
                        (split.leading ?? AnyView(EmptyView()))
                            .frame(width: model.splitSideWidth, alignment: .leading)
                    }
                }
                .padding(.leading, layout.leftWidth > 0 ? model.activityEdgeInset : 0)
                .frame(width: layout.leftWidth, alignment: .trailing)

                Color.clear.frame(width: model.geometry.notchSize.width)

                // Right side, notch → outer edge.
                HStack(spacing: model.activitySpacing) {
                    if let split = layout.split?.activity {
                        (split.trailing ?? AnyView(EmptyView()))
                            .frame(width: model.splitSideWidth, alignment: .trailing)
                    }
                    ForEach(layout.right, id: \.id) { entry in
                        chipSlot(entry)
                    }
                }
                .padding(.trailing, layout.rightWidth > 0 ? model.activityEdgeInset : 0)
                .frame(width: layout.rightWidth, alignment: .leading)
            }
            .padding(.horizontal, model.topCornerRadius)
            .frame(maxHeight: .infinity)
            .onPreferenceChange(ChipWidthKey.self) { widths in
                MainActor.assumeIsolated {
                    for (id, width) in widths where abs((model.chipWidths[id] ?? 0) - width) > 0.5 {
                        model.chipWidths[id] = width
                    }
                }
            }
        }
    }

    /// A chip at its natural width (reported up so the notch can fit it exactly).
    private func chipSlot(_ entry: NotchViewModel.ActivityEntry) -> some View {
        entry.activity.chip
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ChipWidthKey.self, value: [entry.id: proxy.size.width])
            })
            .frame(width: model.chipWidth(entry.id), height: model.geometry.notchSize.height)
            .clipped()
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Top row sits beside the physical notch; the center stays empty.
            HStack(spacing: 0) {
                DockView(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.geometry.notchSize.width)
                // Just two controls: the dock already says which app this is, and "keep open" lives in the menu
                // (a pin shows here only while it's on, to turn it off).
                HStack(spacing: 12) {
                    if model.isPinned { PinButton(model: model) }
                    Button(action: openCommandBar) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Find anything, or say what to do (⌥Space)")
                    EngineMenu(model: model, openSettings: openSettings)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: model.geometry.notchSize.height)
            // Above the app's content, so dock name labels can hang over it.
            .zIndex(1)

            if let app = model.selectedApp {
                app.makeExpandedView()
                    .id(app.id)
                    .frame(maxWidth: .infinity)
                    .frame(height: app.expandedHeight)
                    .padding(.top, 6)
                    .overlay {
                        if model.isLauncherOpen {
                            AppLauncher(model: model)
                                .padding(.top, 6)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        } else if model.isCommandBarShown {
                            CommandBarView(bar: commandBar, close: closeCommandBar)
                                .transition(.opacity)
                        }
                    }
            }
        }
        .padding(.horizontal, model.expandedSideInset)
        .padding(.bottom, model.expandedBottomPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A HUD beside the collapsed notch: icon on the left wing, a level bar or text on the right.
private struct TransientView: View {
    let transient: NotchTransient
    let sideWidth: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: transient.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(transient.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: sideWidth, alignment: .center)
            Color.clear.frame(width: notchWidth)
            Group {
                if let level = transient.level {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(transient.tint).frame(width: proxy.size.width * level)
                        }
                    }
                    .frame(height: 5)
                    .animation(.easeOut(duration: 0.12), value: level)
                } else if let text = transient.text {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(transient.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: sideWidth)
        }
    }
}

/// Keeps the notch open while the mouse is elsewhere (e.g. reading a long reply).
private struct PinButton: View {
    @Bindable var model: NotchViewModel

    var body: some View {
        Button { model.isPinned.toggle() } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(45))
        }
        .buttonStyle(.plain)
        .help("Kept open — click to let it close when the mouse leaves")
    }
}

private struct EngineMenu: View {
    @Bindable var model: NotchViewModel
    let openSettings: () -> Void

    var body: some View {
        Menu {
            Toggle("Keep Open", isOn: $model.isPinned)
            Button("Settings…", action: openSettings)
            Divider()
            Button("Quit NotchMan") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ChipWidthKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

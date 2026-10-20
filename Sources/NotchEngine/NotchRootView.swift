import SwiftUI
import NotchKit

struct NotchRootView: View {
    let model: NotchViewModel
    let openSettings: () -> Void

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
            .clipShape(shape)
            .background(
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(model.state == .expanded ? 0.45 : 0), radius: 14, y: 6)
            )
            .scaleEffect(model.pulsing ? 1.08 : 1, anchor: .top)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if let activity = model.topActivity {
            // Each side area is `activitySideWidth` wide; content keeps `activityEdgeInset` clear of
            // the outer edge so it doesn't crowd the rounded corners.
            HStack(spacing: 0) {
                (activity.leading ?? AnyView(EmptyView()))
                    .frame(width: model.activitySideWidth - model.activityEdgeInset, alignment: .leading)
                    .padding(.leading, model.activityEdgeInset)
                Spacer(minLength: model.geometry.notchSize.width)
                (activity.trailing ?? AnyView(EmptyView()))
                    .frame(width: model.activitySideWidth - model.activityEdgeInset, alignment: .trailing)
                    .padding(.trailing, model.activityEdgeInset)
            }
            .padding(.horizontal, model.topCornerRadius)
            .frame(maxHeight: .infinity)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Top row sits beside the physical notch; the center stays empty.
            HStack(spacing: 0) {
                DockView(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.geometry.notchSize.width)
                HStack(spacing: 10) {
                    Text(model.selectedApp?.name ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    PinButton(model: model)
                    EngineMenu(openSettings: openSettings)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: model.geometry.notchSize.height)

            if let app = model.selectedApp {
                app.makeExpandedView()
                    .id(app.id)
                    .frame(maxWidth: .infinity)
                    .frame(height: app.expandedHeight)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, model.topCornerRadius + 16)
        .padding(.bottom, model.expandedBottomPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Keeps the notch open while the mouse is elsewhere (e.g. reading a long reply).
private struct PinButton: View {
    @Bindable var model: NotchViewModel

    var body: some View {
        Button { model.isPinned.toggle() } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(model.isPinned ? .orange : .white.opacity(0.7))
                .rotationEffect(.degrees(45))
        }
        .buttonStyle(.plain)
        .help(model.isPinned ? "Unpin (collapse when the mouse leaves)" : "Pin open")
    }
}

private struct EngineMenu: View {
    let openSettings: () -> Void

    var body: some View {
        Menu {
            Button("Settings…", action: openSettings)
            Divider()
            Button("Quit NotchMan") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

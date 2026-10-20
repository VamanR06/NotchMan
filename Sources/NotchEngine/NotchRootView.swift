import SwiftUI
import NotchKit

struct NotchRootView: View {
    let model: NotchViewModel
    let openSettings: () -> Void

    var body: some View {
        let shape = NotchShape(topRadius: model.topCornerRadius, bottomRadius: model.bottomCornerRadius)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(model.state == .expanded ? 0.45 : 0), radius: 14, y: 6)

                Group {
                    switch model.state {
                    case .collapsed:
                        collapsedContent
                    case .expanded:
                        expandedContent
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                .clipShape(shape)
            }
            .frame(width: model.shapeSize.width, height: model.shapeSize.height)
            .scaleEffect(model.pulsing ? 1.08 : 1, anchor: .top)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if let activity = model.topActivity {
            HStack(spacing: 0) {
                (activity.leading ?? AnyView(EmptyView()))
                    .frame(width: model.activitySideWidth, alignment: .leading)
                    .padding(.leading, 8)
                Spacer(minLength: model.geometry.notchSize.width)
                (activity.trailing ?? AnyView(EmptyView()))
                    .frame(width: model.activitySideWidth, alignment: .trailing)
                    .padding(.trailing, 8)
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

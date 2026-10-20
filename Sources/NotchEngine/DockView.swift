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
        .help(app.name)
        .onHover { hovering = $0 }
    }
}

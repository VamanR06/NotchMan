import AppKit
import ServiceManagement
import SwiftUI
import NotchKit

@MainActor @Observable
final class SettingsModel {
    var selection: String = SettingsModel.generalID
    static let generalID = "_general"
}

@MainActor
final class SettingsWindowController {
    private let apps: [any NotchApp]
    private let model = SettingsModel()
    private var window: NSWindow?

    init(apps: [any NotchApp]) {
        self.apps = apps
    }

    func show(appID: String? = nil) {
        if let appID, apps.contains(where: { $0.id == appID && $0.makeSettingsView() != nil }) {
            model.selection = appID
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchMan Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(apps: apps, model: model))
        window.center()
        return window
    }
}

private struct SettingsView: View {
    let apps: [any NotchApp]
    @Bindable var model: SettingsModel

    private var configurableApps: [any NotchApp] {
        apps.filter { $0.makeSettingsView() != nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("General", systemImage: "gearshape").tag(SettingsModel.generalID)
                Section("Apps") {
                    ForEach(configurableApps, id: \.id) { app in
                        Label(app.name, systemImage: app.iconSystemName).tag(app.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                Group {
                    if let app = configurableApps.first(where: { $0.id == model.selection }),
                       let view = app.makeSettingsView() {
                        view
                    } else {
                        GeneralSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(NotchEngine.allDisplaysKey) private var allDisplays = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Toggle(isOn: $allDisplays) {
                Text("Show notch on all displays")
                Text("Displays without a hardware notch get a virtual one at the top center.")
            }
        }
        .formStyle(.grouped)
    }
}

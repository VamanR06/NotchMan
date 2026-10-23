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
    @AppStorage(NotchViewModel.hoverDelayKey) private var hoverDelay = NotchViewModel.defaultHoverDelay
    @AppStorage(HotKey.defaultsKey) private var hotKey = HotKey.Preset.optionSpace.rawValue
    @AppStorage(SystemHUDs.volumeKey) private var hudVolume = true
    @AppStorage(SystemHUDs.brightnessKey) private var hudBrightness = true
    @AppStorage(SystemHUDs.batteryKey) private var hudBattery = true
    @AppStorage(SystemHUDs.bluetoothKey) private var hudBluetooth = true
    @State private var hasAccessibility = SystemHUDs.hasAccessibility
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
            Picker(selection: $hotKey) {
                ForEach(HotKey.Preset.allCases) { preset in Text(preset.title).tag(preset.rawValue) }
            } label: {
                Text("Open the notch with")
                Text("From any app. Then ⌘1–9 switch apps, ↑/↓ and Return pick in lists, Esc closes.")
            }
            LabeledContent {
                HStack {
                    Slider(value: $hoverDelay, in: 0.1...1.0, step: 0.05)
                        .frame(width: 180)
                    Text(String(format: "%.2f s", hoverDelay))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            } label: {
                Text("Open after hovering for")
                Text("Longer means brushing the top of the screen won't open the notch.")
            }
            Section {
                Toggle("Volume", isOn: $hudVolume)
                Toggle("Brightness", isOn: $hudBrightness)
                Toggle("Charging and low battery", isOn: $hudBattery)
                Toggle("Headphones connecting", isOn: $hudBluetooth)
                LabeledContent("Accessibility") {
                    if hasAccessibility {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("Allow…") { SystemHUDs.requestAccessibility() }
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
            } header: {
                Text("System HUDs")
            } footer: {
                Text("Shown in the notch. With Accessibility allowed, the volume and brightness keys are handled by NotchMan so macOS's own overlay doesn't appear (⌥⇧ for finer steps); without it, volume changes show in the notch alongside macOS's overlay. External displays' brightness is left to macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                hasAccessibility = SystemHUDs.hasAccessibility
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

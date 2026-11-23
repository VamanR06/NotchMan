import AppKit
import NotchKit
import SwiftUI

/// A generated notch app in the dock: its script's drawing, chip and notifications, plus a menu to change it with
/// Claude, show its files, or remove it.
@MainActor @Observable
public final class ModApp: NotchApp {
    public let id: String
    public private(set) var name: String
    public private(set) var iconSystemName: String
    public private(set) var expandedHeight: CGFloat
    public let folder: URL

    private(set) var tree: ModNode?
    /// Why it isn't drawing (a script error, a bad drawing).
    private(set) var problem: String?
    /// The last error a callback or hook threw (shown under the drawing).
    private(set) var lastError: String?
    private(set) var chip: ModChip?
    /// The script has been stuck in one call for a while.
    private(set) var notResponding = false
    /// Claude is changing it.
    private(set) var isChanging = false
    private(set) var changeError: String?

    /// Set by the library: rewrites the app with Claude.
    @ObservationIgnored var change: ((String) async throws -> Void)?
    /// Set by the library: moves its folder to the Trash.
    @ObservationIgnored var remove: (() -> Void)?
    @ObservationIgnored private var runtime: ModRuntime?
    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var script: String
    @ObservationIgnored private var manifest: ModManifest

    public init(folder: URL, manifest: ModManifest, script: String) {
        id = "mod." + folder.lastPathComponent
        self.folder = folder
        self.manifest = manifest
        name = manifest.name
        iconSystemName = Self.symbol(manifest.symbol)
        expandedHeight = Self.height(manifest.height)
        self.script = script
    }

    public func activate(context: NotchContext) {
        self.context = context
        start()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkResponding() }
        }
    }

    public func deactivate() {
        watchdog?.invalidate()
        runtime?.stop()
        runtime = nil
    }

    /// Loads (or reloads, after its files changed) the manifest and script.
    func load(manifest: ModManifest, script: String) {
        self.manifest = manifest
        name = manifest.name
        iconSystemName = Self.symbol(manifest.symbol)
        expandedHeight = Self.height(manifest.height)
        self.script = script
        if context != nil { start() }
    }

    private func start() {
        runtime?.stop()
        tree = nil
        problem = nil
        lastError = nil
        notResponding = false
        let runtime = ModRuntime(manifest: manifest, storeURL: folder.appending(path: "store.json"))
        runtime.onTree = { [weak self] result in
            switch result {
            case .success(let node):
                self?.tree = node
                self?.problem = nil
            case .failure(let error):
                self?.problem = error.localizedDescription
            }
        }
        runtime.onError = { [weak self] in self?.lastError = $0 }
        runtime.onChip = { [weak self] in self?.chip = $0 }
        runtime.onToast = { [weak self] text in
            self?.context?.showTransient(NotchTransient(id: self?.id ?? "mod", systemImage: self?.iconSystemName ?? "app",
                                                        text: text, duration: 2.5))
        }
        runtime.onNotify = { [weak self] title, body in self?.context?.notify(title: title, body: body) }
        self.runtime = runtime
        runtime.start(script: script)
    }

    func send(_ handler: String, _ value: JSONValue?) {
        runtime?.send(handler, value: value)
    }

    func restart() {
        start()
    }

    private func checkResponding() {
        let stuck = (runtime?.busy?.seconds ?? 0) > 3
        if stuck != notResponding { notResponding = stuck }
    }

    func requestChange(_ request: String) {
        guard let change, !isChanging else { return }
        isChanging = true
        changeError = nil
        Task {
            do {
                try await change(request)
            } catch {
                changeError = error.localizedDescription
            }
            isChanging = false
        }
    }

    public func notchWillOpen() {
        runtime?.notchOpened()
    }

    public var activity: NotchActivity? {
        guard let chip, !chip.text.isEmpty else { return nil }
        return NotchActivity(priority: 4) {
            NotchChip(chip.text, systemImage: chip.symbol ?? iconSystemName, tint: color(chip.color) ?? .white)
        }
    }

    public var relevance: NotchRelevance? {
        chip.map { NotchRelevance("\(name) (a notch app the user made): \($0.text)") }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ModAppView(app: self))
    }

    static func symbol(_ name: String?) -> String {
        guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return "app.badge" }
        return name
    }

    static func height(_ value: Double?) -> CGFloat {
        CGFloat(min(max(value ?? 200, 120), 420))
    }
}

/// The app's drawing, or why it can't draw, with its menu in the corner.
struct ModAppView: View {
    let app: ModApp
    @State private var changing = false
    @State private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                menu
            }
            if let error = app.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            if changing || app.isChanging || app.changeError != nil { changeBar }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var content: some View {
        if app.notResponding {
            notice("\(app.name) isn't responding.", detail: "Its script may be stuck in a loop.") {
                Button("Restart", action: app.restart)
            }
        } else if let problem = app.problem {
            notice("\(app.name) couldn't draw.", detail: problem) {
                Button("Fix with Claude") { app.requestChange("Fix this error: \(problem)") }
                    .disabled(app.isChanging)
                Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting([app.folder.appending(path: "app.js")]) }
            }
        } else if let tree = app.tree {
            ModNodeView(node: tree) { handler, value in app.send(handler, value) }
        } else {
            NotchSpinner(size: 14, lineWidth: 2).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice<Buttons: View>(_ title: String, detail: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                .lineLimit(4).textSelection(.enabled)
            HStack { buttons() }.controlSize(.small)
        }
    }

    private var menu: some View {
        Menu {
            Button("Change with Claude…") { changing = true }
            Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting([app.folder.appending(path: "app.js")]) }
            Button("Restart", action: app.restart)
            Divider()
            Button("Remove \(app.name)", role: .destructive) { app.remove?() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(app.name): change, show files, remove")
    }

    private var changeBar: some View {
        HStack(spacing: 6) {
            if app.isChanging {
                NotchSpinner(size: 10, lineWidth: 1.5)
                Text("Claude is changing \(app.name)…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            } else if let error = app.changeError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                Button("Dismiss") { changing = false; request = "" }.buttonStyle(.plain).font(.system(size: 10))
            } else {
                Image(systemName: "sparkle").foregroundStyle(.orange).font(.system(size: 11))
                TextField("What should change? e.g. “make it 50 minutes”", text: $request)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .onSubmit {
                        let text = request.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        app.requestChange(text)
                        request = ""
                        changing = false
                    }
                Button("Cancel") { changing = false; request = "" }.buttonStyle(.plain).font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
    }
}

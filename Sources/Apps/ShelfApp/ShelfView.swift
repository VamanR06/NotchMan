import AppKit
import NotchKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct ShelfView: View {
    @Bindable var app: ShelfApp

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch app.tab {
            case .shelf:
                HStack(alignment: .top, spacing: 10) {
                    ShelfGrid(app: app)
                    DestinationColumn(app: app)
                        .frame(width: 260)
                }
            case .downloads:
                DownloadsList(app: app)
            }
            if let drop = app.lastDrop {
                LastDropBar(app: app, drop: drop)
            }
        }
        .onAppear(perform: app.pruneMissing)
    }

    private var header: some View {
        HStack(spacing: 6) {
            tabButton("Shelf", count: app.items.count, tab: .shelf)
            tabButton("Downloads", count: app.activeDownloads.count + app.commands.count, tab: .downloads)
            Spacer()
            if app.tab == .shelf && !app.items.isEmpty {
                Button("AirDrop All") { app.airDrop(app.items) }
                Button("Clear") { app.clearShelf() }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.6))
    }

    private func tabButton(_ title: String, count: Int, tab: ShelfApp.Tab) -> some View {
        Button { app.tab = tab } label: {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold)
                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.white.opacity(0.5)) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(app.tab == tab ? 0.14 : 0)))
            .foregroundStyle(app.tab == tab ? .white : .white.opacity(0.6))
        }
    }
}

// MARK: - Drop targets

/// Takes dropped files; with `spring`, hovering a drag over it for a moment runs `spring` (opens the folder).
/// Takes file links and file contents alike (`DroppedItems`), so drags from any app work, not just Finder.
private struct FileDropTarget: ViewModifier {
    let label: String
    let onDrop: ([URL]) -> Void
    var spring: (() -> Void)?
    var cornerRadius: CGFloat = 8
    @State private var targeted = false
    @State private var springTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.accentColor.opacity(targeted ? 0.35 : 0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.accentColor.opacity(targeted ? 0.9 : 0), lineWidth: 1.5))
            .onDrop(of: DroppedItems.acceptedTypes, isTargeted: $targeted) { providers in
                springTask?.cancel()
                shelfLog.notice("Drop on \(label, privacy: .public): \(providers.count) items")
                guard !providers.isEmpty else { return false }
                Task { @MainActor in
                    let urls = await DroppedItems.fileURLs(from: providers)
                    shelfLog.notice("Drop on \(label, privacy: .public): \(urls.count) files")
                    if !urls.isEmpty { onDrop(urls) }
                }
                return true
            }
            .onChange(of: targeted) { _, isTargeted in
                springTask?.cancel()
                guard isTargeted, let spring else { return }
                springTask = Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    if !Task.isCancelled { spring() }
                }
            }
    }
}

private extension View {
    func fileDropTarget(_ label: String = "", cornerRadius: CGFloat = 8, spring: (() -> Void)? = nil,
                        onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropTarget(label: label, onDrop: onDrop, spring: spring, cornerRadius: cornerRadius))
    }

    /// Lets a file be dragged out to Finder, Mail, a chat, …
    func draggableFile(_ url: URL) -> some View {
        onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

// MARK: - Shelf

private struct ShelfGrid: View {
    let app: ShelfApp

    var body: some View {
        Group {
            if app.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drop files here to keep them for later")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                        ForEach(app.items, id: \.self) { url in
                            ShelfTile(app: app, url: url)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .fileDropTarget("shelf", cornerRadius: 10) { app.addToShelf($0) }
    }
}

private struct ShelfTile: View {
    let app: ShelfApp
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 36, height: 36)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 74, height: 72)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovering ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { app.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .draggableFile(url)
        .help(url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { app.airDrop([url]) }
            Menu(app.moveFiles ? "Move To" : "Copy To") {
                ForEach(app.recentFolders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { app.drop([url], into: folder) }
                }
                if !app.recentFolders.isEmpty && !app.projects.isEmpty { Divider() }
                ForEach(app.projects) { project in
                    Button(project.folderName) { app.drop([url], into: URL(fileURLWithPath: project.cwd)) }
                }
            }
            Divider()
            Button("Remove from Shelf") { app.remove(url) }
        }
    }
}

// MARK: - Destinations

/// Where files can go: recent folders, running Claude Code projects and the usual places, or any folder via
/// Choose Folder…. Hold a drag over one to open it and keep going down; drop to put files there.
private struct DestinationColumn: View {
    let app: ShelfApp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let browsing = app.browsing {
                FolderBrowser(app: app, browsing: browsing)
            } else {
                HStack {
                    Text("Drop into a folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                    Spacer()
                    CopyMoveSwitch(app: app)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        let recents = app.recentFolders
                        if !recents.isEmpty {
                            group("Recent") {
                                ForEach(recents, id: \.self) { folder in
                                    DestinationRow(app: app, folder: folder, symbol: "clock",
                                                   title: folder.lastPathComponent,
                                                   subtitle: ProjectDrop.displayPath(folder.deletingLastPathComponent(), project: nil))
                                        .contextMenu { Button("Remove from Recents") { app.forgetRecent(folder) } }
                                }
                            }
                        }
                        if !app.projects.isEmpty {
                            group("Claude Code projects") {
                                ForEach(app.projects) { project in
                                    DestinationRow(app: app, folder: URL(fileURLWithPath: project.cwd),
                                                   symbol: project.agentID != nil ? "terminal.fill" : "folder.fill",
                                                   title: project.folderName, subtitle: project.name, tint: .orange)
                                }
                            }
                        }
                        group("Places") {
                            ForEach(ShelfApp.places, id: \.url) { place in
                                DestinationRow(app: app, folder: place.url, symbol: place.symbol, title: place.name, subtitle: nil)
                            }
                            Button(action: app.chooseFolder) {
                                Label("Choose Folder…", systemImage: "folder.badge.questionmark")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
            content()
        }
    }
}

/// A folder to start from: click to open it, drop onto it, or hold a drag over it to open it.
private struct DestinationRow: View {
    let app: ShelfApp
    let folder: URL
    let symbol: String
    let title: String
    let subtitle: String?
    var tint: Color = .white.opacity(0.7)

    var body: some View {
        Button { app.browse(folder) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fileDropTarget(folder.lastPathComponent, cornerRadius: 7, spring: { app.browse(folder) }) { app.drop($0, into: folder) }
        .help("Drop to put files in \(folder.path); hold a drag here to open it. ⌥ does the other of Copy/Move.")
    }
}

/// Copy or Move for drops into folders (⌥ while dropping does the other).
private struct CopyMoveSwitch: View {
    @Bindable var app: ShelfApp

    var body: some View {
        Picker("", selection: $app.moveFiles) {
            Text("Copy").tag(false)
            Text("Move").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help("What dropping into a folder does. Hold ⌥ while dropping for the other.")
    }
}

/// A folder anywhere on the Mac: go up or jump to a parent from the path, filter by name, open folders (also by
/// holding a drag over them), drop on "Drop here" or onto a folder, make a new folder, and drag folders onto
/// each other to reorganize (with Move). Files show greyed, to see where you are, and can be dragged out.
private struct FolderBrowser: View {
    let app: ShelfApp
    let browsing: ShelfApp.Browsing
    @State private var naming = false
    @State private var newName = ""
    @State private var filter = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var filterFocused: Bool

    private var projectRef: BoardProjectRef? { browsing.project.map { BoardProjectRef(cwd: $0.cwd) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: app.closeBrowser) { Image(systemName: "list.bullet") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .help("Back to Recent, Projects and Places")
                Button(action: app.up) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .disabled(browsing.folder.path == "/")
                    .fileDropTarget(spring: app.up) { _ in }
                    .help("Up to the enclosing folder (hold a drag here to go up)")
                Menu {
                    ForEach(ProjectDrop.ancestors(of: browsing.folder), id: \.self) { folder in
                        Button(ProjectDrop.displayPath(folder, project: projectRef)) { app.open(folder: folder) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: browsing.project == nil ? "folder.fill" : "terminal.fill").foregroundStyle(.orange)
                        Text(ProjectDrop.displayPath(browsing.folder, project: projectRef))
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.head)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Jump to an enclosing folder")
                Spacer(minLength: 0)
                Button {
                    newName = ""
                    naming = true
                } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .help("New folder here")
                CopyMoveSwitch(app: app)
            }
            if naming {
                HStack(spacing: 6) {
                    TextField("Folder name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($nameFocused)
                        .onSubmit(create)
                        .onExitCommand { naming = false }
                    Button("Create", action: create)
                        .controlSize(.small)
                        .disabled(ProjectDrop.folderName(newName) == nil)
                }
                .onAppear { nameFocused = true }
                .onChange(of: nameFocused) { _, typing in app.setTyping(typing) }
            }
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($filterFocused)
                .onChange(of: filterFocused) { _, typing in app.setTyping(typing) }
            ScrollView(.vertical, showsIndicators: false) {
                let _ = app.folderRevision
                let entries = ProjectDrop.entries(of: browsing.folder, hidingBuildFolders: browsing.project != nil, matching: filter)
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries.folders, id: \.self) { folder in
                        Button { app.open(folder: folder) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").foregroundStyle(.white.opacity(0.6))
                                Text(folder.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .draggableFile(folder)
                        .fileDropTarget(folder.lastPathComponent, cornerRadius: 6, spring: { app.open(folder: folder) }) {
                            app.drop($0, into: folder)
                        }
                    }
                    ForEach(entries.files.prefix(200), id: \.self) { file in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 13, height: 13)
                            Text(file.lastPathComponent).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .draggableFile(file)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(file) }
                    }
                    if entries.folders.isEmpty && entries.files.isEmpty {
                        Text(filter.isEmpty ? "Empty folder" : "Nothing matches “\(filter)”")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(6)
                    }
                }
            }
        }
        // Anywhere else in the browser (between rows, the empty space below them) drops into the open folder.
        .contentShape(Rectangle())
        .fileDropTarget("browser: \(browsing.folder.lastPathComponent)", cornerRadius: 9) { app.drop($0, into: browsing.folder) }
        .onChange(of: browsing.folder) { _, _ in filter = "" }
    }
}

extension FolderBrowser {
    private func create() {
        if app.createFolder(named: newName) {
            naming = false
            app.setTyping(false)
        }
    }
}

/// After a drop: in a project, "@src/assets/logo.png copied · Insert in session"; elsewhere, where it went.
private struct LastDropBar: View {
    let app: ShelfApp
    let drop: ShelfApp.ProjectDropResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            if let references = drop.references {
                Text(references)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("copied").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            } else {
                Text("\(drop.files.count == 1 ? drop.files[0].lastPathComponent : "\(drop.files.count) items") → \(ProjectDrop.displayPath(drop.folder, project: nil))")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let project = drop.project, app.canInsert(into: project) {
                Button(drop.inserted ? "Inserted" : "Insert in Session", action: app.insertLastDrop)
                    .disabled(drop.inserted)
                    .help("Types the reference into \(project.name)'s terminal in the notch (open it first)")
            }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(drop.files) }
            Button(action: app.dismissLastDrop) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
        }
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

// MARK: - Downloads

private struct DownloadsList: View {
    let app: ShelfApp

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(app.commands) { command in
                    HStack(spacing: 8) {
                        NotchSpinner(size: 12, lineWidth: 1.8)
                        Text(command.title).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(command.started, style: .timer)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
                if app.downloads.isEmpty && app.commands.isEmpty {
                    Text("Nothing in Downloads.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(app.downloads) { item in
                    DownloadRow(app: app, item: item)
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let app: ShelfApp
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if item.isInProgress {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).controlSize(.mini)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    }
                }
            }
            Spacer(minLength: 4)
            Text(item.isInProgress
                 ? ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
                 : item.date.formatted(.relative(presentation: .named)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !item.isInProgress { NSWorkspace.shared.open(item.url) } }
        .draggableFile(item.url)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }.disabled(item.isInProgress)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Keep on Shelf") { app.addToShelf([item.url]) }.disabled(item.isInProgress)
        }
    }
}

// MARK: - Settings

struct ShelfSettingsView: View {
    let app: ShelfApp

    var body: some View {
        Form {
            Section {
                LabeledContent("notchman-run") {
                    if app.runInstalled {
                        Label("Installed in ~/.local/bin", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install", action: app.installRun)
                    }
                }
            } header: {
                Text("Long-running commands")
            } footer: {
                Text("Prefix a command with notchman-run (e.g. `notchman-run make release`) to see it in the notch while it runs and get a ping when it finishes — a notification too if it took more than 10 seconds. ~/.local/bin needs to be on your PATH.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

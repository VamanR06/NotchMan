import AppKit
import NotchKit
import SwiftUI

struct ShelfView: View {
    @Bindable var app: ShelfApp

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch app.tab {
            case .shelf:
                HStack(alignment: .top, spacing: 10) {
                    ShelfGrid(app: app)
                    ProjectColumn(app: app)
                        .frame(width: 240)
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
private struct FileDropTarget: ViewModifier {
    let onDrop: ([URL]) -> Void
    var spring: (() -> Void)?
    var cornerRadius: CGFloat = 8
    @State private var targeted = false
    @State private var springTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.accentColor.opacity(targeted ? 0.35 : 0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.accentColor.opacity(targeted ? 0.9 : 0), lineWidth: 1.5))
            .dropDestination(for: URL.self) { urls, _ in
                springTask?.cancel()
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onDrop(files)
                return true
            } isTargeted: { isTargeted in
                targeted = isTargeted
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
    func fileDropTarget(cornerRadius: CGFloat = 8, spring: (() -> Void)? = nil, onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropTarget(onDrop: onDrop, spring: spring, cornerRadius: cornerRadius))
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
        .fileDropTarget(cornerRadius: 10) { app.addToShelf($0) }
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
            if !app.projects.isEmpty {
                Menu("Copy to Project") {
                    ForEach(app.projects) { project in
                        Button(project.folderName) { app.drop([url], into: URL(fileURLWithPath: project.cwd), of: project) }
                    }
                }
            }
            Divider()
            Button("Remove from Shelf") { app.remove(url) }
        }
    }
}

// MARK: - Projects

/// Active Claude Code projects to drop files into; hover a drag over one to open its folders.
private struct ProjectColumn: View {
    let app: ShelfApp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let browsing = app.browsing {
                FolderBrowser(app: app, browsing: browsing)
            } else {
                Text("Drop into a project")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                if app.projects.isEmpty {
                    Text("Projects of running Claude Code sessions show here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(app.projects) { project in
                                ProjectTile(app: app, project: project)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ProjectTile: View {
    let app: ShelfApp
    let project: BoardProject

    var body: some View {
        Button { app.browse(project) } label: {
            HStack(spacing: 8) {
                Image(systemName: project.agentID != nil ? "terminal.fill" : "folder.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.folderName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(project.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fileDropTarget(spring: { app.browse(project) }) { files in
            app.drop(files, into: URL(fileURLWithPath: project.cwd), of: project)
        }
        .help("Drop to add to \(project.folderName); hold a drag here to pick a folder. ⌥ moves instead of copying.")
    }
}

/// One folder of a project: drop on the header to put files here, or hover a drag over a subfolder to open it.
private struct FolderBrowser: View {
    let app: ShelfApp
    let browsing: ShelfApp.Browsing

    var body: some View {
        let label = ProjectDrop.label(for: browsing.folder, in: browsing.root)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: app.up) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .fileDropTarget(spring: app.up) { _ in }
                    .help("Back (hold a drag here to go up)")
                Image(systemName: "folder.fill").foregroundStyle(.orange)
                Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            Text("Drop here")
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4])))
                .fileDropTarget { app.drop($0, into: browsing.folder, of: browsing.project) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ProjectDrop.subfolders(of: browsing.folder), id: \.self) { folder in
                        Button { app.open(folder: folder) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder").foregroundStyle(.white.opacity(0.6))
                                Text(folder.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fileDropTarget(cornerRadius: 6, spring: { app.open(folder: folder) }) { files in
                            app.drop(files, into: folder, of: browsing.project)
                        }
                    }
                }
            }
        }
    }
}

/// "Added src/assets/logo.png · @src/assets/logo.png copied · Insert in session".
private struct LastDropBar: View {
    let app: ShelfApp
    let drop: ShelfApp.ProjectDropResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(drop.references)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("copied").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            if app.canInsert(into: drop.project) {
                Button(drop.inserted ? "Inserted" : "Insert in Session", action: app.insertLastDrop)
                    .disabled(drop.inserted)
                    .help("Types the reference into \(drop.project.name)'s terminal in the notch (open it first)")
            }
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

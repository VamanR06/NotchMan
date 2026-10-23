import Foundation

/// A file in ~/Downloads, finished or still arriving.
struct DownloadItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    /// The name it will have once done (".crdownload" etc. removed).
    let name: String
    let date: Date
    let size: Int64
    let isInProgress: Bool
    /// 0…1 when the browser publishes progress (Safari, Finder copies); nil for indeterminate.
    var fraction: Double?

    /// Browsers' partial-download names: Safari's ".download" bundle, Chrome's ".crdownload", Firefox's ".part".
    static let partialExtensions: Set<String> = ["download", "crdownload", "part"]

    static func finalName(of url: URL) -> String {
        partialExtensions.contains(url.pathExtension.lowercased()) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}

enum DownloadsFolder {
    static var url: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// The newest `limit` items, newest first (by when they were added to the folder).
    static func list(in folder: URL = url, limit: Int = 20, fileManager: FileManager = .default) -> [DownloadItem] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .totalFileSizeKey, .fileSizeKey]
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { url -> DownloadItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
            let partial = DownloadItem.partialExtensions.contains(url.pathExtension.lowercased())
            let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            return DownloadItem(url: url, name: DownloadItem.finalName(of: url), date: date,
                                size: partial && url.pathExtension == "download" ? bundleSize(url, fileManager) : size,
                                isInProgress: partial)
        }
        .sorted { $0.date > $1.date }
        .prefix(limit)
        .map { $0 }
    }

    /// Safari's .download is a folder holding the partial file.
    private static func bundleSize(_ url: URL, _ fileManager: FileManager) -> Int64 {
        let files = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// A command wrapped in `notchman-run`, reported over the hook server.
struct RunningCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let started: Date
}

enum NotchmanRun {
    static var installURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/notchman-run")
    }

    /// The script: pings NotchMan when the command starts and ends (quietly does nothing if NotchMan isn't
    /// running), then exits with the command's status.
    static let script = #"""
    #!/bin/sh
    # notchman-run: run a command and show it in the NotchMan notch until it finishes.
    #   notchman-run make release
    TOKEN_FILE="$HOME/Library/Application Support/NotchMan/hook-token"
    ID="$$-$(date +%s)"
    TITLE=$(printf '%s' "$*" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-120)
    ping() {
      [ -r "$TOKEN_FILE" ] || return 0
      curl -s -m 2 -o /dev/null -X POST -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        -H "Content-Type: application/json" --data "$1" http://127.0.0.1:43822/progress || true
    }
    ping "{\"id\":\"$ID\",\"title\":\"$TITLE\",\"state\":\"start\"}"
    "$@"
    STATUS=$?
    ping "{\"id\":\"$ID\",\"title\":\"$TITLE\",\"state\":\"done\",\"exitCode\":$STATUS}"
    exit $STATUS
    """#

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: installURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: installURL.path) }
}

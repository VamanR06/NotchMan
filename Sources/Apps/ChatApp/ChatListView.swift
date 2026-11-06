import NotchKit
import SwiftUI

/// The toolbar's Chats button: your conversations as a list, in place of the chat page.
struct ChatsButton: View {
    @Bindable var app: ChatApp

    var body: some View {
        Button(action: app.toggleChatList) {
            Label("Chats", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(app.showingChatList ? 0.25 : 0.12)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(app.showingChatList ? "Back to the chat" : "Your ChatGPT, Claude and Muse chats")
    }
}

/// Reads every chat from the sites, not just the newest, and drops ones you deleted there.
struct SyncChatsButton: View {
    @Bindable var app: ChatApp

    var body: some View {
        let which = app.chatListFilter?.name ?? "ChatGPT, Claude and Muse"
        Button { Task { await app.syncAllChats() } } label: {
            HStack(spacing: 5) {
                if app.chatListSyncing {
                    NotchSpinner(size: 10, lineWidth: 1.5)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(app.chatListSyncing ? "Syncing…" : "Sync")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(app.chatListSyncing)
        .help("Read every \(which) chat from the site, and remove ones you deleted there")
    }
}

/// Every conversation on ChatGPT, Claude and Muse in one list — searchable, by date, pinned ones first — so
/// you can jump to one without the site's sidebar (which the notch is too narrow to show).
struct ChatListView: View {
    @Bindable var app: ChatApp
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = app.shownChats
        let groups = ChatThreads.grouped(shown, pinned: app.pinnedChats)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                search(count: shown.count)
                filters
            }
            if shown.isEmpty {
                emptyState
            } else {
                list(groups)
            }
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: app.chatListQuery) { _, _ in app.chatListSelection.index = app.shownChats.isEmpty ? nil : 0 }
        .onChange(of: app.chatListFilter) { _, _ in
            app.chatListSelection.index = nil
            Task { await app.refreshChats() }
        }
    }

    private func search(count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            TextField("Search chats", text: $app.chatListQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .focused($searchFocused)
                // The list keys work while typing a search.
                .onKeyPress(.downArrow) { app.chatListSelection.move(1, count: app.shownChats.count); return .handled }
                .onKeyPress(.upArrow) { app.chatListSelection.move(-1, count: app.shownChats.count); return .handled }
                .onKeyPress(.return) {
                    let shown = app.shownChats
                    guard let row = app.chatListSelection.index ?? (shown.isEmpty ? nil : 0), row < shown.count else {
                        return .ignored
                    }
                    app.open(shown[row])
                    return .handled
                }
                .onExitCommand {
                    if app.chatListQuery.isEmpty { app.showingChatList = false } else { app.chatListQuery = "" }
                }
            if !app.chatListQuery.isEmpty {
                Button { app.chatListQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
    }

    /// All | ChatGPT | Claude | Muse.
    private var filters: some View {
        HStack(spacing: 2) {
            filter(nil, "All")
            ForEach(ChatService.allCases) { service in filter(service, service.name) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .fixedSize()
    }

    private func filter(_ service: ChatService?, _ name: String) -> some View {
        let selected = app.chatListFilter == service
        return Button { app.chatListFilter = service } label: {
            HStack(spacing: 4) {
                if let service, app.chatListLoading.contains(service) {
                    NotchSpinner(size: 9, lineWidth: 1.4)
                }
                Text(name)
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : .white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(selected ? 0.2 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ groups: [(section: ChatThreads.Section, threads: [ChatThread])]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ChatListRows(app: app, groups: groups, lazy: true)
            }
            .onChange(of: app.chatListSelection.index) { _, row in
                let shown = groups.flatMap(\.threads)
                if let row, shown.indices.contains(row) { proxy.scrollTo(shown[row].id) }
            }
        }
    }

    private var emptyState: some View {
        let loading = !app.chatListLoading.isEmpty
        let text = if !app.chatListQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            "No chats match “\(app.chatListQuery)”."
        } else if loading {
            "Reading your chats…"
        } else if let service = app.chatListFilter {
            "No \(service.name) chats yet. Open one in the \(service.name) tab (sign in there first)."
        } else {
            "No chats yet. Open one in the ChatGPT, Claude or Muse tab (sign in there first)."
        }
        return VStack(spacing: 8) {
            if loading { NotchSpinner(size: 14, lineWidth: 1.8) }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the last sync found, and why a service's list couldn't be read (usually: not signed in yet).
    @ViewBuilder
    private var footer: some View {
        let services = app.chatListFilter.map { [$0] } ?? ChatService.allCases
        let notes = [app.chatListSyncSummary].compactMap { $0 } + services.compactMap { app.chatListErrors[$0] }
        if !notes.isEmpty {
            Text(notes.joined(separator: " "))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
        }
    }
}

/// The Chats list's sections and rows.
struct ChatListRows: View {
    let app: ChatApp
    let groups: [(section: ChatThreads.Section, threads: [ChatThread])]
    /// Lazy inside the scroll view; plain when rendered on its own (e.g. in tests).
    var lazy = false

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) { sections }
        } else {
            VStack(alignment: .leading, spacing: 1) { sections }
        }
    }

    private var sections: some View {
        // Row numbers across sections, for the keyboard selection.
        let starts = groups.indices.map { index in groups[..<index].reduce(0) { $0 + $1.threads.count } }
        return ForEach(Array(groups.enumerated()), id: \.element.section) { index, group in
            Section {
                ForEach(Array(group.threads.enumerated()), id: \.element.id) { offset, thread in
                    ChatThreadRow(app: app, thread: thread, showsService: app.chatListFilter == nil,
                                  selected: app.chatListSelection.isSelected(starts[index] + offset))
                        .id(thread.id)
                }
            } header: {
                Text(group.section.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.top, index == 0 ? 0 : 8)
                    .padding(.bottom, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black)
            }
        }
    }
}

private struct ChatThreadRow: View {
    let app: ChatApp
    let thread: ChatThread
    let showsService: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let pinned = app.pinnedChats.contains(thread.id)
        Button { app.open(thread) } label: {
            HStack(spacing: 8) {
                status
                if showsService {
                    Text(thread.service.shortName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(thread.service.tint)
                        .frame(width: 40, alignment: .leading)
                }
                Text(thread.displayTitle)
                    .font(.system(size: 12, weight: app.isCurrent(thread) ? .semibold : .regular))
                    .foregroundStyle(thread.title.isEmpty ? .white.opacity(0.5) : .white)
                    .lineLimit(1)
                if let project = thread.project {
                    Label(project, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                if hovering || pinned {
                    Button { app.togglePin(thread) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(pinned ? 0.7 : 0.5))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pinned ? "Unpin" : "Pin to the top")
                }
                if let date = thread.lastActive {
                    Text(Self.when(date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovering ? 0.08 : 0)))
            .notchSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(thread.displayTitle)
        .contextMenu {
            Button("Open") { app.open(thread) }
            Button("Open in Browser") { if let url = URL(string: thread.url) { NSWorkspace.shared.open(url) } }
            Button("Copy Link") { app.copyLink(thread) }
            Divider()
            Button(pinned ? "Unpin" : "Pin to Top") { app.togglePin(thread) }
            Button("Remove from List") { app.removeFromList(thread) }
        }
    }

    /// Writing a reply (spinner) — open in its tab or one you left mid-reply — or a reply you haven't read
    /// (green dot).
    @ViewBuilder
    private var status: some View {
        if app.isWriting(thread) {
            NotchSpinner(size: 10, lineWidth: 1.5)
        } else if app.isUnread(thread) {
            Circle().fill(.green).frame(width: 6, height: 6).frame(width: 10)
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// "3:42 PM" today, "Tue" this week, "Oct 3" this year, else "Oct 3, 2025".
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

extension ChatService {
    /// Each service's color in the mixed list.
    var tint: Color {
        switch self {
        case .chatgpt: Color(red: 0.36, green: 0.80, blue: 0.62)
        case .claude: Color(red: 0.85, green: 0.55, blue: 0.38)
        case .muse: Color(red: 0.70, green: 0.56, blue: 0.95)
        }
    }
}

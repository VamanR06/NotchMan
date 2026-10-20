import NotchKit
import SwiftUI

struct JobsView: View {
    let app: JobsApp

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Pipeline(app: app)
                .frame(width: 120, alignment: .leading)

            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)

            if !app.isSignedIn {
                placeholder("Sign in to JobManager to see your applications.", settings: true)
            } else if !app.hasLoaded {
                placeholder(app.error ?? "Loading…", settings: app.error != nil)
            } else {
                VStack(spacing: 6) {
                    FilterBar(app: app)
                    JobList(app: app)
                }
            }
        }
        .task { await app.refreshIfStale() }
    }

    private func placeholder(_ text: String, settings: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            if settings {
                Button("Open Settings", action: app.openSettings).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Counts per stage, plus refresh / open-dashboard controls.
private struct Pipeline: View {
    let app: JobsApp

    var body: some View {
        let counts = app.board.counts
        let active = (counts[.oa] ?? 0) + (counts[.interview] ?? 0) + (counts[.pending] ?? 0)
        VStack(alignment: .leading, spacing: 3) {
            Text("Applications")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("\(active)")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("in progress")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                stat(.applied, counts)
                stat(.oa, counts)
                stat(.interview, counts)
            }
            HStack(spacing: 8) {
                stat(.accepted, counts)
                stat(.rejected, counts)
            }
            HStack(spacing: 8) {
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button(action: app.openDashboard) { Image(systemName: "safari") }
                    .help("Open JobManager")
                if let error = app.error, app.hasLoaded {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Tapping a count filters the list to that stage.
    private func stat(_ status: JobStatus, _ counts: [JobStatus: Int]) -> some View {
        Button { app.filter = .status(status) } label: {
            HStack(spacing: 3) {
                Circle().fill(status.color).frame(width: 5, height: 5)
                Text("\(counts[status] ?? 0)").monospacedDigit()
            }
            .foregroundStyle(app.filter == .status(status) ? .white : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("Show \(status.name)")
    }
}

private struct JobList: View {
    let app: JobsApp

    var body: some View {
        let board = app.board
        let searching = !app.query.trimmingCharacters(in: .whitespaces).isEmpty
        if app.filter == .active && !searching {
            if board.count(.active) == 0 {
                empty("No active applications.")
            } else {
                sections(board)
            }
        } else {
            // Searching from Active looks through everything.
            let jobs = board.jobs(for: app.filter == .active ? .all : app.filter, matching: app.query)
            if jobs.isEmpty {
                empty(searching ? "No matches for \u{201C}\(app.query)\u{201D}." : "No \(app.filter.name.lowercased()) applications.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(jobs) { job in
                            JobRow(app: app, job: job, action: board.comingUp.first { $0.job.id == job.id })
                        }
                    }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sections(_ board: JobBoard) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if !board.comingUp.isEmpty {
                    Section {
                        ForEach(board.comingUp) { action in
                            JobRow(app: app, job: action.job, action: action)
                        }
                    } header: { header("Coming up", board.comingUp.count) }
                }
                if !board.inProgress.isEmpty {
                    Section {
                        ForEach(board.inProgress) { job in JobRow(app: app, job: job, action: nil) }
                    } header: { header("In progress", board.inProgress.count) }
                }
                if !board.toApply.isEmpty {
                    Section {
                        ForEach(board.toApply) { job in JobRow(app: app, job: job, action: nil) }
                    } header: { header("To apply", board.toApply.count) }
                }
            }
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .background(.black)
    }
}

/// Search field plus a chip per filter (with counts).
private struct FilterBar: View {
    @Bindable var app: JobsApp
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Search", text: $app.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                    .onExitCommand { app.query = ""; searchFocused = false }
                if !app.query.isEmpty {
                    Button { app.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(width: 120)
            .background(Capsule().fill(.white.opacity(searchFocused ? 0.16 : 0.08)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(JobFilter.chips, id: \.self) { filter in
                        chip(filter)
                    }
                }
            }
        }
    }

    private func chip(_ filter: JobFilter) -> some View {
        let selected = app.filter == filter
        let tint: Color = if case .status(let status) = filter { status.color } else { .white }
        return Button { app.filter = filter } label: {
            HStack(spacing: 3) {
                Text(filter.name)
                Text("\(app.board.count(filter))")
                    .monospacedDigit()
                    .foregroundStyle(selected ? .black.opacity(0.6) : .white.opacity(0.4))
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? tint.opacity(0.9) : .white.opacity(0.08)))
            .foregroundStyle(selected ? .black : .white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }
}

/// ✨ menu: open ChatGPT with one of the prompt presets filled in for this job.
private struct AskMenu: View {
    let app: JobsApp
    let job: TrackedJob

    var body: some View {
        Menu {
            Section("Ask ChatGPT") {
                ForEach(app.templates) { template in
                    Button(template.name) { app.ask(template, about: job) }
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ask ChatGPT about this job")
    }
}

private struct JobRow: View {
    let app: JobsApp
    let job: TrackedJob
    let action: JobAction?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(job.badge)
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .frame(minWidth: 34)
                .background(Capsule().fill(job.status.color.opacity(0.25)))
                .foregroundStyle(job.status.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.company)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(job.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if job.status == .toApply && !app.templates.isEmpty {
                AskMenu(app: app, job: job)
            }
            if let link = actionLink {
                Button { NSWorkspace.shared.open(link.url) } label: {
                    Text(link.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(job.status.color.opacity(0.85)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            Text(detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(detailColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.open(job) }
        .help("Open in JobManager")
        .contextMenu {
            if job.status == .toApply && !app.templates.isEmpty {
                Section("Job prompts") {
                    ForEach(app.templates) { template in
                        Button(template.name) { app.ask(template, about: job) }
                    }
                }
                Divider()
            }
            AskMenuItems { askText }
        }
    }

    /// What "Ask ChatGPT/Claude/Muse" sends about this job.
    private var askText: String {
        var lines = ["Job application: \(job.title) at \(job.company)", "Status: \(job.status.name)\(job.round.map { " (round \($0))" } ?? "")"]
        if let deadline = job.oaDeadline { lines.append("OA due: \(deadline.formatted(date: .complete, time: .shortened))") }
        if let interview = job.interviewAt { lines.append("Interview: \(interview.formatted(date: .complete, time: .shortened))") }
        if let url = job.url { lines.append("Posting: \(url)") }
        return lines.joined(separator: "\n")
    }

    /// OA or interview link, shown for upcoming items (and on hover otherwise).
    private var actionLink: (label: String, url: URL)? {
        guard action != nil || hovering else { return nil }
        switch job.status {
        case .oa: return job.oaLink.map { ("Open OA", $0) }
        case .interview: return job.interviewLink.map { ("Join", $0) }
        default: return nil
        }
    }

    private var detail: String {
        let now = app.now
        guard let action else {
            if job.status == .pending, let after = job.pendingAfter { return "after \(after.name)" }
            return relativeTime(job.statusDate, now: now)
        }
        switch action.kind {
        case .oaDeadline:
            return action.date < now ? "OA overdue" : "due \(relativeTime(action.date, now: now))"
        case .interview:
            if action.date.timeIntervalSince(now) < 12 * 3600 { return relativeTime(action.date, now: now) }
            return action.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
    }

    private var detailColor: Color {
        guard let action else { return .white.opacity(0.45) }
        let until = action.date.timeIntervalSince(app.now)
        if until < 0 && action.kind == .oaDeadline { return .red }
        return until < 24 * 3600 ? .orange : .white.opacity(0.7)
    }
}

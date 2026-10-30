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
                    if app.draft != nil {
                        AddJobForm(app: app)
                    } else {
                        if let match = app.pageMatch {
                            ThisPageCard(app: app, match: match)
                        } else if app.unlinkedPage != nil {
                            UnlinkedPageRow(app: app)
                        }
                        FilterBar(app: app)
                        JobList(app: app)
                    }
                    if let change = app.lastChange {
                        UndoBar(app: app, change: change)
                    }
                }
            }
        }
        .task { await app.refreshIfStale() }
        .task { await app.checkPage() }
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

/// The tracked job open in the browser: its resume and cover letter to drag onto the page, and Autofill.
private struct ThisPageCard: View {
    let app: JobsApp
    let match: PageMatch
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .foregroundStyle(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.job.company).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(sourceLine).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 6)
                DocumentTile(app: app, kind: .resume, document: match.info.resume, file: match.resumeFile)
                DocumentTile(app: app, kind: .cover_letter, document: match.info.cover_letter, file: match.coverLetterFile)
                if app.isAutofilling {
                    HStack(spacing: 5) {
                        NotchSpinner(size: 10, lineWidth: 1.6)
                        Text("Filling…").font(.system(size: 11, weight: .semibold))
                        Button("Stop", action: app.stopAutofill)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Button(action: app.autofill) {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                            Text("Autofill")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Fills the form with your JobManager Profile and saved answers and attaches the resume. Never submits.")
                }
                if match.source == .tracked {
                    Button(action: app.dismissPage) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Hide")
                } else {
                    Button(action: app.unlinkPage) { Image(systemName: "link.badge.plus").symbolVariant(.slash) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Not this job: forget the link for this page")
                }
            }
            if let report = app.autofillReport {
                HStack(spacing: 6) {
                    Image(systemName: report.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.problem == nil ? .green : .orange)
                    Text(report.summary).lineLimit(2)
                    Spacer(minLength: 4)
                    if let form = report.embeddedForm {
                        Button("Open Form") { app.openEmbeddedForm(form) }.buttonStyle(.plain).foregroundStyle(.orange)
                    }
                    if !report.needsYou.isEmpty || !report.check.isEmpty {
                        Button(showDetails ? "Hide" : "Details") { showDetails.toggle() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .font(.system(size: 10.5))
                if showDetails {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.needsYou, id: \.self) { Text("• \($0)") }
                        ForEach(report.check, id: \.self) { Text("• Check \($0)").foregroundStyle(.orange.opacity(0.9)) }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
    }
}

extension ThisPageCard {
    /// The job's title, and how the page got tied to it when it isn't JobManager's own match.
    fileprivate var sourceLine: String {
        switch match.source {
        case .tracked: match.job.title
        case .followed: "\(match.job.title) · followed from its page"
        case .linked: "\(match.job.title) · linked page"
        case .picked: "\(match.job.title) · linked just now"
        }
    }
}

/// A job-looking page that isn't tied to a job: pick which one it is.
private struct UnlinkedPageRow: View {
    let app: JobsApp

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text("This page isn't linked to a job").font(.system(size: 11, weight: .medium))
                Text(app.unlinkedPage?.url.host() ?? "").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer()
            Menu("Link…") {
                let candidates = app.linkCandidates
                ForEach(candidates.prefix(12)) { job in
                    Button("\(job.company) — \(job.title)") { app.link(job) }
                }
                if candidates.count > 12 {
                    Menu("More") {
                        ForEach(candidates.dropFirst(12)) { job in
                            Button("\(job.company) — \(job.title)") { app.link(job) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tie this page to one of your jobs to get its resume and Autofill here")
            Button(action: app.dismissPage) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
        }
        .font(.system(size: 11))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}

/// A document you can drag onto the page's upload box (or anywhere else), with a menu to choose which one.
private struct DocumentTile: View {
    let app: JobsApp
    let kind: DocumentKind
    let document: PageDocument?
    let file: URL?

    private var label: String { kind.label }

    var body: some View {
        HStack(spacing: 2) {
            tile
            DocumentMenu(app: app, kind: kind, current: document?.id)
        }
    }

    @ViewBuilder
    private var tile: some View {
        Group {
            if let file {
                HStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
                    Text(label).font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                .help("Drag \(file.lastPathComponent) onto the page's upload box")
            } else if document != nil {
                NotchSpinner(size: 10, lineWidth: 1.6).help("Downloading \(label.lowercased())…")
            } else {
                Text("No \(label.lowercased())")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Link a \(label.lowercased()) to this job in JobManager")
            }
        }
    }
}

/// Pick which resume (or cover letter) goes with this job: newest first, archived ones tucked away, or none.
private struct DocumentMenu: View {
    let app: JobsApp
    let kind: DocumentKind
    let current: Int?

    var body: some View {
        let documents = app.documentChoices[kind] ?? []
        Menu {
            let active = documents.filter { !$0.isArchived }
            if active.isEmpty {
                Text(documents.isEmpty ? "Loading…" : "No \(kind.label.lowercased())s yet")
            }
            ForEach(active) { document in
                choice(document)
            }
            let archived = documents.filter(\.isArchived)
            if !archived.isEmpty {
                Menu("Archived") {
                    ForEach(archived) { document in choice(document) }
                }
            }
            if current != nil {
                Divider()
                Button("None") { app.choose(nil, as: kind) }
            }
            Divider()
            Button("Open \(kind == .resume ? "Resumes" : "Cover Letters") in JobManager") { app.openDocuments(kind) }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the \(kind.label.lowercased()) for this job (it's linked to the job in JobManager, and Autofill attaches it)")
        .task { await app.loadDocumentChoices() }
    }

    private func choice(_ document: JobDocument) -> some View {
        Button {
            app.choose(document, as: kind)
        } label: {
            if document.id == current {
                Label(document.menuTitle, systemImage: "checkmark")
            } else {
                Text(document.menuTitle)
            }
        }
    }
}

/// Confirms a job read from the browser before adding it to JobManager.
private struct AddJobForm: View {
    @Bindable var app: JobsApp

    var body: some View {
        if let draft = app.draft {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Add to apply")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(draft.url.host() ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                field("Company", text: Binding(get: { app.draft?.company ?? "" }, set: { app.draft?.company = $0 }))
                field("Title", text: Binding(get: { app.draft?.title ?? "" }, set: { app.draft?.title = $0 }))
                if draft.posting == nil {
                    Text("JobManager couldn't read this page; check the details.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                if let duplicate = draft.duplicate {
                    Text(duplicate)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: app.cancelDraft)
                    if draft.duplicate != nil {
                        Button("Add Anyway") { app.saveDraft(allowDuplicate: true) }
                    } else {
                        Button("Add") { app.saveDraft() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(draft.company.trimmingCharacters(in: .whitespaces).isEmpty
                                      || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .controlSize(.small)
                .disabled(draft.isSaving)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }
}

/// "Moved Acme to Interview · Undo", for a few seconds after a status change.
private struct UndoBar: View {
    let app: JobsApp
    let change: JobsApp.StatusChange

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(change.status.color)
            Text("\(change.company) → \(change.status.name)")
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Undo", action: app.undoLastChange)
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                Button(action: app.addFromBrowser) {
                    if app.isReadingTab { NotchSpinner(size: 10) } else { Image(systemName: "plus.rectangle.on.rectangle") }
                }
                .help("Add the job open in your browser")
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
                                .notchSelected(job.id == app.selectedJob?.id)
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
                                .notchSelected(action.job.id == app.selectedJob?.id)
                        }
                    } header: { header("Coming up", board.comingUp.count) }
                }
                if !board.inProgress.isEmpty {
                    Section {
                        ForEach(board.inProgress) { job in
                            JobRow(app: app, job: job, action: nil).notchSelected(job.id == app.selectedJob?.id)
                        }
                    } header: { header("In progress", board.inProgress.count) }
                }
                if !board.toApply.isEmpty {
                    Section {
                        ForEach(board.toApply) { job in
                            JobRow(app: app, job: job, action: nil).notchSelected(job.id == app.selectedJob?.id)
                        }
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
        .opacity(app.updating.contains(job.id) ? 0.5 : 1)
        .contextMenu {
            Menu("Set Status") {
                ForEach(JobStatus.allCases, id: \.self) { status in
                    Button {
                        app.setStatus(status, for: job)
                    } label: {
                        if status == job.status {
                            Label(status == .interview ? "Interview (next round)" : status.name, systemImage: "checkmark")
                        } else {
                            Text(status.name)
                        }
                    }
                    .disabled(status == job.status && status != .interview)
                }
            }
            Divider()
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

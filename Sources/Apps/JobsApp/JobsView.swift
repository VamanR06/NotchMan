import NotchKit
import SwiftUI

struct JobsView: View {
    let app: JobsApp

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The pipeline only means something once signed in.
            if app.isSignedIn {
                Pipeline(app: app)
                    .frame(width: 120, alignment: .leading)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            }

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

/// The tracked job open in the browser: one header row (the job, its documents, Autofill), one status line, then
/// the form's open questions with their drafts.
struct ThisPageCard: View {
    let app: JobsApp
    let match: PageMatch
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let report = app.autofillReport {
                status(report)
                if let error = app.draftError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
                if showDetails { details(report) }
                if !app.drafts.isEmpty {
                    DraftList(app: app)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(match.job.company).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(sourceLine).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 6)
            document(.resume, linked: match.info.resume != nil, file: match.resumeFile)
            document(.cover_letter, linked: match.info.cover_letter != nil, file: match.coverLetterFile)
            DocumentsMenu(app: app, resume: match.info.resume?.id, coverLetter: match.info.cover_letter?.id)
            autofill
            if match.source == .tracked {
                Button(action: app.dismissPage) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .help("Hide")
            } else {
                Button(action: app.unlinkPage) { Image(systemName: "link.badge.plus").symbolVariant(.slash) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Not this job: forget the link for this page")
            }
        }
    }

    /// Only documents the job has: draggable once downloaded.
    @ViewBuilder
    private func document(_ kind: DocumentKind, linked: Bool, file: URL?) -> some View {
        if let file {
            DocumentChip(kind: kind, file: file)
        } else if linked {
            NotchSpinner(size: 9, lineWidth: 1.4).help("Downloading the \(kind.label.lowercased())…")
        }
    }

    @ViewBuilder
    private var autofill: some View {
        if app.isAutofilling {
            HStack(spacing: 5) {
                NotchSpinner(size: 9, lineWidth: 1.4)
                Button("Stop", action: app.stopAutofill)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 11, weight: .semibold))
        } else {
            Button(action: app.autofill) {
                Label("Autofill", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Fills the form with your JobManager Profile and saved answers and attaches the resume. Never submits.")
        }
    }

    // MARK: Status

    private func status(_ report: AutofillReport) -> some View {
        HStack(spacing: 6) {
            Image(systemName: report.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.problem == nil ? .green : .orange)
            Text(report.summary).lineLimit(1).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 4)
            if let form = report.embeddedForm {
                Button("Open Form") { app.openEmbeddedForm(form) }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            if !app.drafts.isEmpty {
                if app.isDrafting {
                    NotchSpinner(size: 9, lineWidth: 1.4)
                    Text("Writing…").foregroundStyle(.white.opacity(0.6))
                    Button("Stop", action: app.stopDrafting).buttonStyle(.plain).foregroundStyle(.orange)
                } else {
                    let drafted = app.drafts.contains { !$0.text.isEmpty }
                    Button(drafted ? "Redraft all" : "Draft answers", action: app.draftAnswers)
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .help("Writes every open question with \(app.draftSettings.modelName), from the job description, the job's resume and your notes. Nothing goes into the page until you Insert.")
                }
            }
            if report.hasDetails {
                Button { showDetails.toggle() } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showDetails ? 180 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
                .help(showDetails ? "Hide details" : "What else needs you")
            }
        }
        .font(.system(size: 10.5))
    }

    private func details(_ report: AutofillReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(report.otherNeeds, id: \.self) { Text($0) }
            ForEach(report.check, id: \.self) { Text("Check \($0)").foregroundStyle(.orange.opacity(0.9)) }
            if !report.attached.isEmpty { Text("Attached \(report.attached.joined(separator: ", "))") }
            if let experience = report.workExperience { Text("Work experience: \(experience)") }
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
        .padding(.leading, 17)
    }
}

/// The form's open questions, each with its draft and your note. Most forms have one to three: shown in full.
private struct DraftList: View {
    let app: JobsApp

    var body: some View {
        if app.drafts.count > 3 {
            ScrollView { rows }.scrollIndicators(.never).frame(maxHeight: 170)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.drafts) { draft in
                Divider().overlay(.white.opacity(0.06))
                DraftRow(app: app, draft: draft)
            }
        }
    }
}

/// One open question: what it asks, your note, the draft. Insert is always there once there's a draft; note,
/// redraft and copy show on hover.
private struct DraftRow: View {
    let app: JobsApp
    let draft: DraftItem
    @State private var hovering = false
    @State private var editing = false
    @State private var noteOpen = false
    @FocusState private var noteFocused: Bool

    private var writing: Bool { app.draftingKeys.contains(draft.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(draft.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .help(draft.label)
                if draft.inserted {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).help("Inserted")
                }
                Spacer(minLength: 4)
                if hovering && !app.isDrafting {
                    icon("text.bubble", help: draft.note.isEmpty ? "Add a note for this answer" : "Edit your note") {
                        noteOpen = true
                        noteFocused = true
                    }
                    icon("arrow.clockwise", help: "Redraft this one") { app.redraft(draft.key) }
                    if !draft.text.isEmpty {
                        icon("doc.on.doc", help: "Copy") { app.copyDraft(draft.key) }
                    }
                }
                if !draft.text.isEmpty && !draft.inserted && !writing {
                    Button("Insert") { app.insertDraft(draft.key) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .disabled(app.isDrafting)
                }
            }
            if noteOpen || !draft.note.isEmpty {
                note
            }
            answer
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Your note: a quiet line, a field while you're writing it.
    @ViewBuilder
    private var note: some View {
        if noteOpen {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                TextField("Pointers for this answer, then Return to redraft", text: Binding(
                    get: { draft.note }, set: { app.setNote(draft.key, note: $0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .focused($noteFocused)
                    .onSubmit {
                        noteOpen = false
                        app.redraft(draft.key)
                    }
                    .onExitCommand { noteOpen = false }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06)))
        } else {
            Label(draft.note, systemImage: "text.bubble")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    noteOpen = true
                    noteFocused = true
                }
                .help("Your note for this answer. Click to edit")
        }
    }

    @ViewBuilder
    private var answer: some View {
        if writing && draft.text.isEmpty {
            Text("Writing…").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
        } else if editing {
            TextEditor(text: Binding(get: { draft.text }, set: { app.editDraft(draft.key, text: $0) }))
                .font(.system(size: 10.5))
                .scrollContentBackground(.hidden)
                .frame(height: 78)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
        } else if !draft.text.isEmpty {
            Text(draft.text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if !writing { editing = true } }
                .help("Click to edit")
        }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .help(help)
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

/// A document the job has, to drag onto the page's upload box (or anywhere else).
private struct DocumentChip: View {
    let kind: DocumentKind
    let file: URL

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 15, height: 15)
            Text(kind == .resume ? "Resume" : "Cover").font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.09)))
        .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
        .help("Drag \(file.lastPathComponent) onto the page's upload box")
    }
}

/// Any resume, ready to drag onto any application, whatever page is open: the chip drags, the chevron picks.
/// Picking here doesn't change any job's resume.
struct QuickResume: View {
    let app: JobsApp

    var body: some View {
        HStack(spacing: 2) {
            if let document = app.quickResume, let file = app.quickResumeFile {
                HStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 15, height: 15)
                    Text(document.name.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive, .anchored, .backwards]))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.09)))
                .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                .help("Drag \(file.lastPathComponent) onto any upload box")
            } else if app.quickResume != nil {
                NotchSpinner(size: 9, lineWidth: 1.4).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No resume").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            picker
        }
        .task { await app.loadDocumentChoices() }
    }

    private var picker: some View {
        let resumes = app.documentChoices[.resume] ?? []
        return Menu {
            let active = resumes.filter { !$0.isArchived }
            if resumes.isEmpty { Text("Loading…") }
            ForEach(active) { choice($0) }
            let archived = resumes.filter(\.isArchived)
            if !archived.isEmpty {
                Menu("Archived") { ForEach(archived) { choice($0) } }
            }
            Divider()
            Button("Open Resumes in JobManager") { app.openDocuments(.resume) }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick a resume to drag (doesn't change any job's resume)")
    }

    private func choice(_ document: JobDocument) -> some View {
        Button { app.pickQuickResume(document) } label: {
            if document.id == app.quickResume?.id {
                Label(document.menuTitle, systemImage: "checkmark")
            } else {
                Text(document.menuTitle)
            }
        }
    }
}

/// Pick the job's resume and cover letter in one menu: newest first, archived ones tucked away, or none.
private struct DocumentsMenu: View {
    let app: JobsApp
    let resume: Int?
    let coverLetter: Int?

    var body: some View {
        Menu {
            section(.resume, current: resume)
            section(.cover_letter, current: coverLetter)
        } label: {
            Image(systemName: "paperclip")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose this job's resume and cover letter (linked in JobManager; Autofill attaches them)")
        .task { await app.loadDocumentChoices() }
    }

    @ViewBuilder
    private func section(_ kind: DocumentKind, current: Int?) -> some View {
        let documents = app.documentChoices[kind] ?? []
        Section(kind.label) {
            let active = documents.filter { !$0.isArchived }
            if active.isEmpty {
                Text(documents.isEmpty ? "Loading…" : "No \(kind.label.lowercased())s yet")
            }
            ForEach(active) { choice($0, as: kind, current: current) }
            let archived = documents.filter(\.isArchived)
            if !archived.isEmpty {
                Menu("Archived") {
                    ForEach(archived) { choice($0, as: kind, current: current) }
                }
            }
            if current != nil {
                Button("No \(kind.label.lowercased())") { app.choose(nil, as: kind) }
            }
            Button("Open \(kind == .resume ? "Resumes" : "Cover Letters") in JobManager") { app.openDocuments(kind) }
        }
    }

    private func choice(_ document: JobDocument, as kind: DocumentKind, current: Int?) -> some View {
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
            let stages = [JobStatus.applied, .oa, .interview, .accepted, .rejected].filter { (counts[$0] ?? 0) > 0 }
            ForEach(Array(stride(from: 0, to: stages.count, by: 3)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(stages[start..<min(start + 3, stages.count)], id: \.self) { stat($0, counts) }
                }
            }
            QuickResume(app: app)
                .padding(.top, 4)
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

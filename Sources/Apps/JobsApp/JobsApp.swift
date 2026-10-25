import AppKit
import SwiftUI
import NotchKit

/// Job applications from JobManager: upcoming OA deadlines and interviews, what's in progress, and what to apply to.
@MainActor @Observable
public final class JobsApp: NotchApp {
    public let id = "jobs"
    public let name = "Jobs"
    public let iconSystemName = "briefcase"
    public var expandedHeight: CGFloat { pageMatch == nil ? 190 : 250 }

    private(set) var board = JobBoard.empty
    private(set) var isSignedIn = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var now = Date()
    /// List filter and search; kept here so they survive the notch collapsing.
    var filter: JobFilter = .active
    var query = ""
    /// ChatGPT prompt presets for jobs, editable in settings.
    var templates: [PromptTemplate] = PromptTemplate.defaults {
        didSet { saveTemplates() }
    }
    /// ChatGPT project that job chats start in unless a prompt names its own ("" = a normal new chat).
    var defaultProjectURL = "" {
        didSet { context?.defaults.set(defaultProjectURL, forKey: "defaultProjectURL") }
    }

    /// The last status change, offered for undo for a few seconds.
    private(set) var lastChange: StatusChange?
    /// Jobs with a status change in flight.
    private(set) var updating: Set<TrackedJob.ID> = []

    struct StatusChange: Equatable {
        let jobID: TrackedJob.ID
        let company: String
        let status: JobStatus
        let eventID: Int
    }

    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private(set) var client: JobManagerClient!
    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshQueued = false

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        BrowserTab.startTracking()
        opensOnJobPages = context.defaults.object(forKey: "opensOnJobPages") as? Bool ?? true
        client = JobManagerClient(keychain: context.keychain, defaults: context.defaults)
        isSignedIn = client.isSignedIn
        defaultProjectURL = context.defaults.string(forKey: "defaultProjectURL") ?? ""
        if let data = context.defaults.data(forKey: "promptTemplates"),
           let saved = try? JSONDecoder().decode([PromptTemplate].self, from: data) {
            templates = saved
        }

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.now = Date()
            }
        })
    }

    public func deactivate() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    // MARK: - Account

    func signIn(server: String, password: String) async throws {
        try await client.signIn(server: server, password: password)
        isSignedIn = true
        await refresh()
    }

    func signOut() {
        client.signOut()
        isSignedIn = false
        board = .empty
        hasLoaded = false
        error = nil
    }

    // MARK: - Loading

    func refresh() async {
        guard isSignedIn else { return }
        guard !isLoading else {
            refreshQueued = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if refreshQueued {
                refreshQueued = false
                Task { await refresh() }
            }
        }
        do {
            let jobs = try await client.jobs()
            now = Date()
            board = JobBoard(jobs: jobs, now: now)
            publishBoard()
            hasLoaded = true
            error = nil
            context?.logger.notice("Loaded \(jobs.count, privacy: .public) jobs")
        } catch {
            self.error = error.localizedDescription
            context?.logger.error("Jobs refresh failed: \(error.localizedDescription, privacy: .public)")
            if case JobManagerClient.ClientError.notSignedIn = error { isSignedIn = client.isSignedIn }
        }
        lastRefresh = Date()
    }

    /// Refreshes on expand, but not more than once a minute.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    // MARK: - Actions

    // MARK: - Board

    /// OA deadlines and interviews in the next three days, for the Today app.
    private func publishBoard() {
        let soon = board.comingUp.filter { $0.date.timeIntervalSince(now) < 72 * 3600 }
        NotchBoard.shared.publish(soon.map { action in
            let job = action.job
            let link = action.kind == .oaDeadline ? job.oaLink : job.interviewLink
            return BoardItem(id: "job:\(job.id):\(action.kind)", kind: .deadline,
                             title: job.company,
                             subtitle: action.kind == .oaDeadline ? "OA due · \(job.title)" : "Interview · \(job.title)",
                             date: action.date, tint: job.status.color,
                             primary: link.map { url in
                                 BoardAction(action.kind == .oaDeadline ? "Open OA" : "Join",
                                             systemImage: action.kind == .oaDeadline ? "doc.text" : "video.fill") {
                                     NSWorkspace.shared.open(url)
                                 }
                             },
                             open: BoardAction("Open", systemImage: "arrow.up.right") { [weak self] in self?.open(job) })
        }, from: id)
    }

    // MARK: - The job open in the browser

    /// The tracked job the browser is showing (posting or application form), with its documents.
    private(set) var pageMatch: PageMatch?
    private(set) var autofillReport: AutofillReport?
    private(set) var isAutofilling = false
    /// Hovering the notch open while the browser shows a tracked job opens Jobs.
    var opensOnJobPages = true {
        didSet { context?.defaults.set(opensOnJobPages, forKey: "opensOnJobPages") }
    }
    /// Set when this opening started over a browser; the claim only applies to that opening.
    @ObservationIgnored private var openedOverBrowser = false
    /// Pages already looked up (so hovering again doesn't ask JobManager each time).
    @ObservationIgnored private var checkedPages: [URL: Date] = [:]

    public func notchWillOpen() {
        openedOverBrowser = isSignedIn && BrowserTab.frontmostIsBrowser
        guard openedOverBrowser else { return }
        Task { await checkPage() }
    }

    public var claimsNotchOnOpen: Bool { opensOnJobPages && openedOverBrowser && pageMatch != nil }

    /// Looks up the browser's page in JobManager; keeps the match while the page stays the same.
    func checkPage() async {
        guard isSignedIn, let tab = try? await BrowserTab.current() else { return }
        if pageMatch?.tab.url == tab.url { return }
        if pageMatch != nil {
            pageMatch = nil
            autofillReport = nil
        }
        if let checked = checkedPages[tab.url], Date().timeIntervalSince(checked) < 60 { return }
        checkedPages[tab.url] = Date()
        // Older JobManager servers don't have this endpoint; that just means no match.
        guard let info = try? await client.pageInfo(for: tab.url), info.job != nil else { return }
        pageMatch = PageMatch(tab: BrowserTabRef(url: tab.url, bundleID: tab.bundleID, browser: tab.browser), info: info)
        if let resume = info.resume { pageMatch?.resumeFile = try? await client.download(resume) }
        if let cover = info.cover_letter { pageMatch?.coverLetterFile = try? await client.download(cover) }
    }

    func dismissPage() {
        pageMatch = nil
        autofillReport = nil
    }

    /// Fills the application in the browser by JobManager's rules, attaching the job's resume. Never submits.
    func autofill() {
        guard let match = pageMatch, !isAutofilling else { return }
        isAutofilling = true
        autofillReport = nil
        context?.holdOpen(true)
        Task {
            let report = await runAutofill(match)
            autofillReport = report
            isAutofilling = false
            context?.holdOpen(false)
        }
    }

    private func runAutofill(_ match: PageMatch) async -> AutofillReport {
        do {
            let scripts = try await client.applyScripts()
            // The page may have moved on (posting → its application form); it must still be this job.
            let current = try await BrowserTab.current()
            if current.url != match.tab.url {
                let info = try await client.pageInfo(for: current.url)
                guard info.job?.id == match.job.id else {
                    return AutofillReport(problem: "The browser is on a different page now. Open the application form for \(match.job.company).")
                }
            }
            let scan = try await PageForm.scan(in: current, script: scripts.scan)
            if scan.fields.isEmpty {
                let frames = try? await PageForm.embeddedForms(in: current, script: scripts.frames)
                if let frame = frames?.first {
                    return AutofillReport(problem: "This form is embedded from \(frame.host() ?? "another site"); open it on its own to fill it.",
                                          embeddedForm: frame)
                }
                if let blocker = scan.blockers.first { return AutofillReport(problem: blocker) }
                return AutofillReport(problem: scan.hasApplyButton
                                      ? "Click Apply on the page to show the form, then Autofill again."
                                      : "No application form on this page.")
            }
            let first = try await client.resolve(jobID: match.job.id, fields: scan.fields)
            let files = PageForm.files(for: match)
            var results = try await PageForm.fill(in: current, script: scripts.fill, steps: first.fill, files: files)
            var plans = first.fields
            // Answers can reveal follow-up questions; resolve and fill those once.
            try await Task.sleep(for: .milliseconds(1200))
            let again = try await PageForm.scan(in: current, script: scripts.scan)
            let known = Set(plans.map(\.key))
            let fresh = again.fields.filter { !known.contains($0["key"] as? String ?? "") }
            if !fresh.isEmpty {
                let second = try await client.resolve(jobID: match.job.id, fields: fresh)
                results += try await PageForm.fill(in: current, script: scripts.fill, steps: second.fill, files: files)
                plans += second.fields
            }
            return AutofillReport.from(plans: plans, results: results)
        } catch {
            return AutofillReport(problem: error.localizedDescription)
        }
    }

    // MARK: - Add from browser

    /// A job about to be added from the browser, shown for confirmation so the company and title can be fixed.
    struct JobDraft {
        var url: URL
        var company: String
        var title: String
        /// JobManager's parse of the page, saved as the posting snapshot (nil if it couldn't read the page).
        var posting: [String: Any]?
        var duplicate: String?
        var isSaving = false
    }

    var draft: JobDraft?
    private(set) var isReadingTab = false

    /// Reads the browser's current page, asks JobManager to parse it, and opens the confirm form.
    func addFromBrowser() {
        guard !isReadingTab else { return }
        isReadingTab = true
        context?.holdOpen(true)
        Task {
            defer { isReadingTab = false }
            do {
                let tab = try await BrowserTab.current()
                let posting = try? await client.parse(tab.url)
                let guess = Self.guess(from: tab)
                draft = JobDraft(url: tab.url,
                                 company: (posting?["company"] as? String).flatMap(Self.nonEmpty) ?? guess.company,
                                 title: (posting?["title"] as? String).flatMap(Self.nonEmpty) ?? guess.title,
                                 posting: posting)
                error = nil
            } catch {
                self.error = error.localizedDescription
                context?.holdOpen(false)
            }
        }
    }

    func saveDraft(allowDuplicate: Bool = false) {
        guard var draft, !draft.isSaving else { return }
        draft.isSaving = true
        self.draft = draft
        Task {
            do {
                let result = try await client.createJob(company: draft.company.trimmingCharacters(in: .whitespaces),
                                                        title: draft.title.trimmingCharacters(in: .whitespaces),
                                                        url: draft.url, posting: draft.posting, allowDuplicate: allowDuplicate)
                switch result {
                case .created:
                    self.draft = nil
                    context?.holdOpen(false)
                    context?.showTransient(NotchTransient(id: "jobs", systemImage: "briefcase.fill", text: "Added", tint: .green))
                    await refresh()
                case .duplicate(let message):
                    self.draft?.duplicate = message
                    self.draft?.isSaving = false
                }
            } catch {
                self.error = error.localizedDescription
                self.draft?.isSaving = false
            }
        }
    }

    func cancelDraft() {
        draft = nil
        context?.holdOpen(false)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A starting point when JobManager can't read the page: the tab title's first part, and the company from
    /// the job board path (boards.greenhouse.io/acme, jobs.lever.co/acme, acme.wd5.myworkdayjobs.com) or the
    /// site name. Shown for editing, never saved unseen.
    static func guess(from tab: BrowserTab) -> (company: String, title: String) {
        let title = tab.title
            .components(separatedBy: CharacterSet(charactersIn: "|–—"))
            .first?
            .components(separatedBy: " - ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let host = tab.url.host() ?? ""
        let boards = ["greenhouse.io", "lever.co", "ashbyhq.com", "workable.com", "smartrecruiters.com"]
        var company: String
        if boards.contains(where: host.hasSuffix), let first = tab.url.pathComponents.dropFirst().first {
            company = first
        } else if host.contains("myworkdayjobs.com") {
            company = String(host.split(separator: ".").first ?? "")
        } else {
            let parts = host.split(separator: ".").filter { !["www", "jobs", "careers", "boards", "apply"].contains($0) }
            company = parts.count >= 2 ? String(parts[parts.count - 2]) : String(parts.first ?? "")
        }
        company = company.replacingOccurrences(of: "-", with: " ").capitalized
        return (company, title)
    }

    // MARK: - Status

    func setStatus(_ status: JobStatus, for job: TrackedJob) {
        guard status != job.status || status == .interview, !updating.contains(job.id) else { return }
        updating.insert(job.id)
        Task {
            defer { updating.remove(job.id) }
            do {
                let eventID = try await client.setStatus(status, for: job)
                offerUndo(StatusChange(jobID: job.id, company: job.company, status: status, eventID: eventID))
                await refresh()
            } catch {
                self.error = "Couldn't change status: \(error.localizedDescription)"
            }
        }
    }

    func undoLastChange() {
        guard let change = lastChange else { return }
        lastChange = nil
        Task {
            do {
                try await client.deleteEvent(change.eventID)
                await refresh()
            } catch {
                self.error = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }

    private func offerUndo(_ change: StatusChange) {
        lastChange = change
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.lastChange == change else { return }
            withAnimation { self?.lastChange = nil }
        }
    }

    // MARK: - Keyboard

    let selection = NotchListSelection()

    /// Jobs in the order the list shows them.
    var displayedJobs: [TrackedJob] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if filter == .active && !searching {
            var seen = Set<TrackedJob.ID>()
            return (board.comingUp.map(\.job) + board.inProgress + board.toApply).filter { seen.insert($0.id).inserted }
        }
        return board.jobs(for: filter == .active ? .all : filter, matching: query)
    }

    var selectedJob: TrackedJob? {
        let shown = displayedJobs
        return selection.index.flatMap { shown.indices.contains($0) ? shown[$0] : nil }
    }

    /// ↑/↓ select, Return opens the job in JobManager.
    public func handleKey(_ event: NSEvent) -> Bool {
        let shown = displayedJobs
        return selection.handle(event, count: shown.count, open: { self.open(shown[$0]) })
    }

    func open(_ job: TrackedJob) {
        if let url = client.pageURL(for: job) { NSWorkspace.shared.open(url) }
    }

    /// Opens a new ChatGPT chat in the notch with the template filled in for this job (not sent).
    func ask(_ template: PromptTemplate, about job: TrackedJob) {
        Task {
            // The posting is best-effort: without it the prompt falls back to the job's link.
            let posting = try? await client.posting(for: job)
            let text = template.render(job: job, url: job.url, posting: posting)
            let project = [template.projectURL ?? "", defaultProjectURL]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            context?.send(.chatPrompt(text, url: project), to: "chat")
        }
    }

    private func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) { context?.defaults.set(data, forKey: "promptTemplates") }
    }

    func openDashboard() {
        if let url = URL(string: client.serverURL) { NSWorkspace.shared.open(url) }
    }

    func openSettings() {
        context?.openSettings()
    }

    // MARK: - Notch

    /// Chip: "OA 1d" for an OA deadline, or the interview icon and time until the interview.
    public var activity: NotchActivity? {
        guard let action = board.urgent(now: now) else { return nil }
        let until = action.date.timeIntervalSince(now)
        let imminent = until <= 3600
        let time = until <= 0 ? "now" : relativeTime(action.date, now: now).replacingOccurrences(of: "in ", with: "")
        return NotchActivity(priority: imminent ? 15 : 4) {
            switch action.kind {
            case .oaDeadline:
                NotchChip("OA \(time)", systemImage: "briefcase.fill", tint: imminent ? .orange : .white)
            case .interview:
                NotchChip(time, systemImage: "person.2.fill", tint: imminent ? .orange : .white)
            }
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(JobsView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(JobsSettingsView(app: self))
    }
}

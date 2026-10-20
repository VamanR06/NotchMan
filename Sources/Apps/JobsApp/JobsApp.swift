import AppKit
import SwiftUI
import NotchKit

/// Job applications from JobManager: upcoming OA deadlines and interviews, what's in progress, and what to apply to.
@MainActor @Observable
public final class JobsApp: NotchApp {
    public let id = "jobs"
    public let name = "Jobs"
    public let iconSystemName = "briefcase"
    public var expandedHeight: CGFloat { 190 }

    private(set) var board = JobBoard.empty
    private(set) var isSignedIn = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var now = Date()

    @ObservationIgnored private(set) var client: JobManagerClient!
    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshQueued = false

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        client = JobManagerClient(keychain: context.keychain, defaults: context.defaults)
        isSignedIn = client.isSignedIn

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

    func open(_ job: TrackedJob) {
        if let url = client.pageURL(for: job) { NSWorkspace.shared.open(url) }
    }

    func openDashboard() {
        if let url = URL(string: client.serverURL) { NSWorkspace.shared.open(url) }
    }

    func openSettings() {
        context?.openSettings()
    }

    // MARK: - Notch

    public var activity: NotchActivity? {
        guard let action = board.urgent(now: now) else { return nil }
        let until = action.date.timeIntervalSince(now)
        let imminent = until <= 3600
        return NotchActivity(priority: imminent ? 15 : 4) {
            HStack(spacing: 5) {
                Image(systemName: action.kind == .interview ? "person.2.fill" : "doc.text.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(action.job.status.color)
                Text(action.job.company)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        } trailing: {
            Text(until <= 0 ? "now" : relativeTime(action.date, now: now).replacingOccurrences(of: "in ", with: ""))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(imminent ? .orange : .white.opacity(0.7))
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(JobsView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(JobsSettingsView(app: self))
    }
}

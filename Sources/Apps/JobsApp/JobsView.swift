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
            } else if app.board.comingUp.isEmpty && app.board.inProgress.isEmpty && app.board.toApply.isEmpty {
                placeholder("No active applications.", settings: false)
            } else {
                JobList(app: app)
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

    private func stat(_ status: JobStatus, _ counts: [JobStatus: Int]) -> some View {
        HStack(spacing: 3) {
            Circle().fill(status.color).frame(width: 5, height: 5)
            Text("\(counts[status] ?? 0)").monospacedDigit()
        }
        .help(status.name)
    }
}

private struct JobList: View {
    let app: JobsApp

    var body: some View {
        let board = app.board
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

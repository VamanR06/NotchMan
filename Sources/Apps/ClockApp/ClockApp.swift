import AppKit
import SwiftUI
import NotchKit

/// The time here and in other cities, timers, and a stopwatch. Timers and the stopwatch are stored as dates, so
/// they keep going while the notch is closed or NotchMan restarts; a timer that finishes rings, posts a
/// notification and opens the notch.
@MainActor @Observable
public final class ClockApp: NotchApp {
    public let id = "clock"
    public let name = "Clock"
    public let iconSystemName = "clock"
    public var expandedHeight: CGFloat { 210 }
    public var expandedWidth: CGFloat { 640 }

    enum Tab: String, CaseIterable {
        case clock, timer, stopwatch
        var title: String { rawValue.capitalized }
    }

    var tab: Tab = .clock {
        didSet { context?.defaults.set(tab.rawValue, forKey: "tab") }
    }

    private(set) var timers: [CountdownTimer] = []
    private(set) var stopwatch = Stopwatch()
    /// Time zone identifiers shown beside the local time.
    private(set) var worldClocks: [String] = []
    /// What's typed in the new-timer field.
    var timerText = ""
    /// A finished timer's sound is playing.
    private(set) var isRinging = false

    /// Quick starts on the Timer tab, in minutes.
    let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sound: NSSound?
    @ObservationIgnored private var ringStop: Task<Void, Never>?

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        let defaults = context.defaults
        tab = defaults.string(forKey: "tab").flatMap(Tab.init(rawValue:)) ?? .clock
        timers = Self.decode([CountdownTimer].self, defaults.data(forKey: "timers")) ?? []
        stopwatch = Self.decode(Stopwatch.self, defaults.data(forKey: "stopwatch")) ?? Stopwatch()
        worldClocks = defaults.stringArray(forKey: "worldClocks") ?? []
        // Timers that ran out while NotchMan was closed: mark them done without ringing late.
        let now = Date()
        for index in timers.indices where timers[index].isDue(at: now) { timers[index].hasRung = true }
        saveTimers()
        updateTicker()
    }

    public func deactivate() {
        ticker?.cancel()
        stopRinging()
    }

    // MARK: - Timers

    var canStartTypedTimer: Bool { TimerInput.parse(timerText) != nil }

    /// Starts what's typed in the field ("10m tea", "1:30", "25").
    func startTypedTimer() {
        guard let (duration, label) = TimerInput.parse(timerText) else { return }
        startTimer(duration, label: label)
        timerText = ""
    }

    func startTimer(_ duration: TimeInterval, label: String = "") {
        timers.insert(CountdownTimer(label: label, duration: duration, startingAt: Date()), at: 0)
        changedTimers()
    }

    func togglePause(_ timer: CountdownTimer) {
        update(timer) { timer, now in
            if timer.isRunning { timer.pause(at: now) } else { timer.resume(at: now) }
        }
    }

    func restart(_ timer: CountdownTimer) {
        stopRinging()
        update(timer) { timer, now in timer.restart(at: now) }
    }

    func addMinute(_ timer: CountdownTimer) {
        stopRinging()
        update(timer) { timer, now in timer.add(60, at: now) }
    }

    func remove(_ timer: CountdownTimer) {
        timers.removeAll { $0.id == timer.id }
        if !timers.contains(where: \.hasRung) { stopRinging() }
        changedTimers()
    }

    func clearFinished() {
        timers.removeAll(where: \.hasRung)
        stopRinging()
        changedTimers()
    }

    private func update(_ timer: CountdownTimer, _ change: (inout CountdownTimer, Date) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }) else { return }
        change(&timers[index], Date())
        changedTimers()
    }

    private func changedTimers() {
        saveTimers()
        updateTicker()
    }

    /// Checks for finished timers while anything runs. The views draw their own time; this only rings.
    private func updateTicker() {
        let needed = timers.contains(where: \.isRunning)
        if needed, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.tick()
                }
            }
        } else if !needed {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func tick() {
        let now = Date()
        let due = timers.indices.filter { timers[$0].isDue(at: now) }
        guard !due.isEmpty else { return }
        for index in due {
            timers[index].hasRung = true
            ring(timers[index])
        }
        changedTimers()
    }

    private func ring(_ timer: CountdownTimer) {
        let title = timer.label.isEmpty ? "Timer done" : timer.label
        let body = timer.label.isEmpty ? ClockFormat.spoken(timer.duration) : "\(ClockFormat.spoken(timer.duration)) timer done"
        context?.notify(title: title, body: body, payload: ["timer": timer.id.uuidString],
                        actions: [NotchNotificationAction(id: "restart", title: "Restart"),
                                  NotchNotificationAction(id: "minute", title: "+1 Min")])
        context?.showTransient(NotchTransient(id: "clock.timer", systemImage: "timer", text: title, tint: .orange, duration: 4))
        tab = .timer
        context?.requestAttention(.expand(duration: 8))
        startRinging()
    }

    /// Plays the alarm for up to 30 seconds, or until it's silenced or a finished timer is touched.
    private func startRinging() {
        guard !isRinging else { return }
        let alarm = NSSound(named: "Glass") ?? NSSound(named: "Ping")
        alarm?.loops = true
        alarm?.play()
        sound = alarm
        isRinging = true
        ringStop?.cancel()
        ringStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.stopRinging()
        }
    }

    func stopRinging() {
        sound?.stop()
        sound = nil
        ringStop?.cancel()
        isRinging = false
    }

    private func saveTimers() {
        context?.defaults.set(try? JSONEncoder().encode(timers), forKey: "timers")
    }

    // MARK: - Stopwatch

    func toggleStopwatch() {
        stopwatch.toggle(at: Date())
        saveStopwatch()
    }

    func lap() {
        stopwatch.lap(at: Date())
        saveStopwatch()
    }

    func resetStopwatch() {
        stopwatch.reset()
        saveStopwatch()
    }

    private func saveStopwatch() {
        context?.defaults.set(try? JSONEncoder().encode(stopwatch), forKey: "stopwatch")
    }

    // MARK: - World clocks

    func addWorldClock(_ identifier: String) {
        guard TimeZone(identifier: identifier) != nil, !worldClocks.contains(identifier) else { return }
        worldClocks.append(identifier)
        context?.defaults.set(worldClocks, forKey: "worldClocks")
    }

    func removeWorldClock(_ identifier: String) {
        worldClocks.removeAll { $0 == identifier }
        context?.defaults.set(worldClocks, forKey: "worldClocks")
    }

    func moveWorldClocks(from source: IndexSet, to destination: Int) {
        worldClocks.move(fromOffsets: source, toOffset: destination)
        context?.defaults.set(worldClocks, forKey: "worldClocks")
    }

    func openSettings() {
        context?.openSettings()
    }

    func setTyping(_ typing: Bool) {
        context?.holdOpen(typing)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: - NotchApp

    public func receive(_ message: NotchMessage) {
        guard message.name == NotchMessage.notificationOpenedName,
              let id = message.payload["timer"].flatMap(UUID.init(uuidString:)),
              let timer = timers.first(where: { $0.id == id }) else { return }
        switch message.payload["action"] {
        case "restart": restart(timer)
        case "minute": addMinute(timer)
        default:
            stopRinging()
            tab = .timer
        }
    }

    /// Space starts/stops the stopwatch (or pauses the newest timer on the Timer tab), L laps, R resets, and
    /// ←/→ switch tabs. Any key silences a ringing timer.
    public func handleKey(_ event: NSEvent) -> Bool {
        if isRinging {
            stopRinging()
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: shiftTab(-1); return true
        case 124: shiftTab(1); return true
        default: break
        }
        switch (tab, event.charactersIgnoringModifiers?.lowercased()) {
        case (.stopwatch, " "): toggleStopwatch()
        case (.stopwatch, "l"): lap()
        case (.stopwatch, "r"): if !stopwatch.isRunning { resetStopwatch() }
        case (.timer, " "):
            guard let timer = timers.first(where: { !$0.hasRung }) else { return false }
            togglePause(timer)
        default: return false
        }
        return true
    }

    private func shiftTab(_ delta: Int) {
        let all = Tab.allCases
        let index = all.firstIndex(of: tab) ?? 0
        tab = all[(index + delta + all.count) % all.count]
    }

    /// The soonest running timer counts down beside the notch; a finished one says so; else a running stopwatch.
    public var activity: NotchActivity? {
        if let done = timers.first(where: \.hasRung) {
            let label = done.label.isEmpty ? "Done" : done.label
            return NotchActivity(priority: 22) { NotchChip(label, systemImage: "bell.fill", tint: .orange) }
        }
        let now = Date()
        if let next = timers.filter(\.isRunning).min(by: { $0.remaining(at: now) < $1.remaining(at: now) }) {
            return NotchActivity(priority: 12) { TimerChip(timer: next) }
        }
        if stopwatch.isRunning {
            let watch = stopwatch
            return NotchActivity(priority: 8) { StopwatchChip(stopwatch: watch) }
        }
        return nil
    }

    public var dockBadge: NotchBadge? {
        if timers.contains(where: \.hasRung) { return .dot(.orange) }
        return timers.contains(where: \.isRunning) || stopwatch.isRunning ? .busy : nil
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ClockView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(ClockSettingsView(app: self))
    }
}

/// Counts down on its own, so the app doesn't have to publish a change every second.
private struct TimerChip: View {
    let timer: CountdownTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            NotchChip(ClockFormat.countdown(timer.remaining(at: context.date)), systemImage: "timer")
        }
    }
}

private struct StopwatchChip: View {
    let stopwatch: Stopwatch

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            NotchChip(ClockFormat.countdown(stopwatch.elapsed(at: context.date).rounded(.down)), systemImage: "stopwatch")
        }
    }
}

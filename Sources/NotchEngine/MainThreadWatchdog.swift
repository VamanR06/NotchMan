import Foundation
import os

/// Logs whenever the main thread stops answering for a noticeable moment (and for how long), so a freeze shows up in
/// the log with a time to line up against. Checks four times a second from a background thread; costs nothing while
/// the main thread is free.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private static let log = Logger(subsystem: "com.notchman", category: "watchdog")
    /// Stalls shorter than this aren't worth a line.
    static let threshold: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "com.notchman.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        self.timer = timer
    }

    private var waiting = false

    private func ping() {
        guard !waiting else { return }
        waiting = true
        let sent = Date()
        DispatchQueue.main.async { [weak self] in
            let delay = Date().timeIntervalSince(sent)
            if delay >= Self.threshold {
                Self.log.error("Main thread was blocked for \(Int(delay * 1000), privacy: .public)ms")
            }
            guard let self else { return }
            self.queue.async { self.waiting = false }
        }
    }
}

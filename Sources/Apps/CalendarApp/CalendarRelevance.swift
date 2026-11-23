import Foundation
import NotchKit

extension CalendarApp {
    /// The next meeting within the hour; urgent when it's on now or starts within five minutes.
    public var relevance: NotchRelevance? {
        guard let event = nextEvent, !event.isAllDay else { return nil }
        if event.isOngoing(at: now) { return NotchRelevance("Meeting “\(event.title)” is happening now", urgent: true) }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        guard minutes <= 60 else { return nil }
        return NotchRelevance("Meeting “\(event.title)” starts in \(minutes) min", urgent: minutes <= 5)
    }
}

import Foundation
import NotchKit

extension TasksApp {
    public var relevance: NotchRelevance? {
        let overdue = overdueCount, today = dueTodayCount
        if overdue > 0 { return NotchRelevance("\(overdue) overdue task(s)" + (today > 0 ? ", \(today) due today" : "")) }
        return today > 0 ? NotchRelevance("\(today) task(s) due today") : nil
    }
}

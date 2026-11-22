import Foundation
import NotchKit

extension ChatApp {
    /// Approvals waiting are urgent; sessions that need you or are working are worth knowing.
    public var relevance: NotchRelevance? {
        if let first = approvals.first {
            let more = approvals.count > 1 ? " and \(approvals.count - 1) more" : ""
            return NotchRelevance("Claude Code is waiting for permission to use \(first.toolName)\(more)", urgent: true)
        }
        let agents = agentMonitor?.agents ?? []
        let needYou = agents.filter { $0.phase == .needsYou }.count
        let working = agents.filter { $0.phase == .working }.count
        if needYou > 0 { return NotchRelevance("\(needYou) Claude Code session(s) need your reply") }
        if working > 0 {
            let doing = agents.filter { $0.phase == .working }
                .compactMap { agent in sessionActivity[agent.id].flatMap { $0.isFresh() ? "\($0.lastAction) in \(agent.project)" : nil } }
            return NotchRelevance("\(working) Claude Code session(s) working" + (doing.isEmpty ? "" : ": " + doing.prefix(2).joined(separator: "; ")))
        }
        return nil
    }
}

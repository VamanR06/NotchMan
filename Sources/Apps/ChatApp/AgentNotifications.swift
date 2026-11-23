import Foundation
import NotchKit

/// The Agents app's notifications: one line that says what happened, the detail underneath, buttons to act right
/// there, and one per session (a later one replaces it; it's withdrawn once you've seen the session).
enum AgentNotifications {
    static func approval(_ request: ApprovalRequest, agentName: String?) -> NotchNotification {
        var actions = [NotchNotificationAction(id: "allow", title: "Allow")]
        if let always = request.always { actions.append(NotchNotificationAction(id: "always", title: always.label)) }
        actions.append(NotchNotificationAction(id: "deny", title: "Deny", isDestructive: true))
        return NotchNotification(id: "approval:" + request.id,
                                 title: "\(agentName ?? request.project) · \(request.action)",
                                 subtitle: request.risk.map { "⚠ \($0.prefix(1).uppercased() + $0.dropFirst())" },
                                 body: request.summary,
                                 payload: ["approval": request.id],
                                 actions: actions, urgency: .urgent, thread: request.sessionID)
    }

    static func needsYou(_ agent: ClaudeAgent, said: String) -> NotchNotification {
        NotchNotification(id: "agent:" + agent.id, title: "\(agent.name) needs you", body: said,
                          payload: ["agent": agent.id],
                          actions: [NotchNotificationAction(id: "reply", title: "Reply", textInput: "Reply to Claude…")],
                          urgency: .normal, thread: agent.id)
    }

    static func finished(_ agent: ClaudeAgent, said: String) -> NotchNotification {
        NotchNotification(id: "agent:" + agent.id, title: "\(agent.name) finished", body: said,
                          payload: ["agent": agent.id],
                          actions: [NotchNotificationAction(id: "reply", title: "Reply", textInput: "Ask a follow-up…")],
                          urgency: .quiet, thread: agent.id)
    }

    /// The first meaningful line of Claude's reply, without Markdown marks, cut to fit a notification.
    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        let plain = line.replacingOccurrences(of: #"^#+\s*|^[-*]\s+|\*\*|`"#, with: "", options: .regularExpression)
        return plain.count > 140 ? String(plain.prefix(140)) + "…" : plain
    }
}

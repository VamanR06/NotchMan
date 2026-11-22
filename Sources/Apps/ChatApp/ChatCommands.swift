import Foundation
import NotchKit

/// What the command bar can find and do in Agents: Claude Code sessions and approvals waiting on you; open a session,
/// allow or deny a request.
extension ChatApp {
    public func commands(for query: String) -> NotchCommands {
        let agents = (agentMonitor?.agents ?? []).sorted { $0.phase < $1.phase }
        var items = agents.map { agent in
            CommandItem(id: "agent:" + agent.id, title: agent.name,
                        subtitle: agent.project + " · " + AgentTerminalScreen.status(agent),
                        symbol: agent.phase == .needsYou ? "hand.raised" : "terminal", kind: "Agent",
                        keywords: [agent.project, AgentTerminalScreen.status(agent)], revealsApp: id) { [weak self] in
                self?.open(agent)
            }
        }
        items += approvals.map { request in
            CommandItem(id: "approval:" + request.id, title: "\(request.toolName): \(request.summary)",
                        subtitle: request.project, symbol: "hand.raised.fill", kind: "Approval",
                        keywords: ["approve", "allow", "permission"], revealsApp: id) { [weak self] in
                self?.showingOverview = true
                self?.backToOverview()
            }
        }
        let agent = CommandParameter(
            name: "agent", description: "Claude Code session",
            choices: agents.map { CommandChoice(id: $0.id, label: "\($0.name) (project \($0.project), \(AgentTerminalScreen.status($0)))") })
        let request = CommandParameter(
            name: "request", description: "pending permission request",
            choices: approvals.map { CommandChoice(id: $0.id, label: "\($0.toolName) wants to run \($0.summary) in project \($0.project)") })
        let name = { (choice: CommandChoice?) in agents.first { $0.id == choice?.id }?.name ?? "session" }
        let tool = { [approvals] (choice: CommandChoice?) in approvals.first { $0.id == choice?.id }.map { "\($0.toolName) in \($0.project)" } ?? "request" }
        var actions = [
            CommandAction(id: "open_agent", description: "Open a Claude Code session", risk: .safe, symbol: "terminal",
                          parameters: [agent], revealsApp: id, summary: { "Open \(name($0["agent"]))" },
                          perform: { [weak self] choices in
                              if let found = agents.first(where: { $0.id == choices["agent"]?.id }) { self?.open(found) }
                          }),
        ]
        if !approvals.isEmpty {
            actions += [
                CommandAction(id: "allow_request", description: "Allow (approve) a pending permission request",
                              risk: .confirm, symbol: "checkmark.shield", parameters: [request],
                              summary: { "Allow \(tool($0["request"]))" },
                              perform: { [weak self] in if let id = $0["request"]?.id { self?.resolveApproval(id, .allow) } }),
                CommandAction(id: "deny_request", description: "Deny a pending permission request", risk: .confirm,
                              symbol: "xmark.shield", parameters: [request], summary: { "Deny \(tool($0["request"]))" },
                              perform: { [weak self] in if let id = $0["request"]?.id { self?.resolveApproval(id, .deny) } }),
            ]
        }
        return NotchCommands(items: items, actions: actions)
    }
}

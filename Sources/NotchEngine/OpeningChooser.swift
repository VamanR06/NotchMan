import Foundation
import NotchKit

/// Which app the notch opens to: the one that fits what you're doing. Jev picks among the apps from their one-line
/// states (redacted), the app in front and the time of day; without Jev, only an urgent app (a meeting about to start,
/// an approval waiting) takes over. An app that claims the opening (`claimsNotchOnOpen`) still wins over both.
enum OpeningChooser {
    static let keep = "keep"
    /// How sure Jev must be before the notch opens somewhere other than where you left it.
    static let minProbability = 0.55
    /// Settings → General: open to what's relevant.
    static let enabledKey = "openToRelevantApp"

    struct AppState: Equatable {
        let id: String
        let name: String
        let relevance: NotchRelevance?
    }

    @MainActor
    static func request(apps: [AppState], current: String, context: IntentContext, redactor: Redactor)
        -> (state: JSONValue, questions: [String: JevQuestion]) {
        var described: [String: JSONValue] = [:]
        var options: [String: String] = [keep: "Stay on the app shown last"]
        for app in apps {
            let status = app.relevance.map { redactor.text($0.summary) } ?? "nothing new"
            described[app.id] = ["name": .string(app.name), "status": .string(status)]
            options[app.id] = "\(app.name) (\(status))"
        }
        let currentName = apps.first { $0.id == current }?.name ?? current
        let state: JSONValue = ["context": context.json, "shown_last": .string(currentName), "apps": .object(described)]
        let question = JevQuestion.choice(
            "The user is opening a panel of small apps at the top of their screen. Given `context` and each app's status "
                + "in `apps`, which app do they most likely want to see right now? Choose keep to stay on `shown_last` "
                + "unless another app clearly matters more.",
            options)
        return (state, ["app": question])
    }

    /// Jev's pick, if it's sure enough and it's somewhere else.
    static func pick(_ answers: [String: JevAnswer], current: String, apps: [AppState]) -> String? {
        guard case .choice(let choice, _, let probabilities)? = answers["app"], choice != keep, choice != current,
              apps.contains(where: { $0.id == choice }), (probabilities[choice] ?? 0) >= minProbability else { return nil }
        return choice
    }

    /// Without Jev: the first urgent app, unless you're already on an urgent one.
    static func localPick(apps: [AppState], current: String) -> String? {
        if apps.first(where: { $0.id == current })?.relevance?.isUrgent == true { return nil }
        return apps.first { $0.relevance?.isUrgent == true }?.id
    }
}

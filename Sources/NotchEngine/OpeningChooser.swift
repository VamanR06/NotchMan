import Foundation
import NotchKit

/// Which app the notch opens to. Plain rules, no model: an app with something that needs you (an approval waiting, a
/// meeting about to start, an agent stuck or asking) takes over; otherwise it stays where you left it. Guessing what
/// you want from a few status lines got it wrong too often, and a wrong switch on hover is worse than none. An app
/// that claims the opening (`claimsNotchOnOpen`) still wins.
enum OpeningChooser {
    /// Settings → General: open to what needs you.
    static let enabledKey = "openToRelevantApp"

    struct AppState: Equatable {
        let id: String
        let name: String
        let relevance: NotchRelevance?
    }

    /// The first app with something urgent, unless you're already on one.
    static func pick(apps: [AppState], current: String) -> String? {
        if apps.first(where: { $0.id == current })?.relevance?.isUrgent == true { return nil }
        return apps.first { $0.relevance?.isUrgent == true }?.id
    }
}

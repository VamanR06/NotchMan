import Foundation
import NotchKit

extension JobsApp {
    public var relevance: NotchRelevance? {
        pageMatch == nil ? nil : NotchRelevance("The browser shows one of the user's tracked job applications")
    }
}

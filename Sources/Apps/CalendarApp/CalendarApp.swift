import SwiftUI
import NotchKit

@MainActor @Observable
public final class CalendarApp: NotchApp {
    public let id = "calendar"
    public let name = "Calendar"
    public let iconSystemName = "calendar"

    public init() {}

    public func activate(context: NotchContext) {}

    public func makeExpandedView() -> AnyView {
        AnyView(Text("Calendar").foregroundStyle(.white))
    }
}

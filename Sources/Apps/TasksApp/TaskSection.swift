/// The list's groups, in display order.
enum TaskSection: Int, CaseIterable {
    case overdue, today, upcoming, noDate

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .noDate: "No due date"
        }
    }
}

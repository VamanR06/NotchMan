import Foundation
import Testing
@testable import TasksApp

@MainActor @Suite struct TaskCommandsTests {
    @Test func addTodoOrTaskStartsAQuickAdd() {
        #expect(TasksApp.quickAddText("add call recruiter fri 3pm") == "call recruiter fri 3pm")
        #expect(TasksApp.quickAddText("TODO buy milk") == "buy milk")
        #expect(TasksApp.quickAddText("task   ship it") == "ship it")
        #expect(TasksApp.quickAddText("address book") == nil)
        #expect(TasksApp.quickAddText("add ") == nil)
    }
}

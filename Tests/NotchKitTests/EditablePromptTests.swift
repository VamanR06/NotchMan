import Foundation
import Testing
@testable import NotchKit

@Suite struct EditablePromptTests {
    let prompt = EditablePrompt(
        id: "test.prompt", group: "Test", title: "Test", detail: "",
        placeholders: [.init("request", "what you typed"), .init("app", "the app", required: false)],
        defaultText: "Answer briefly.\n{app}\n\nRequest: {request}")

    func freshStore() -> UserDefaults {
        let name = "notchman.tests.prompts.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func usesTheDefaultUntilEdited() {
        let store = freshStore()
        #expect(prompt.text(in: store) == prompt.defaultText)
        #expect(!prompt.isEdited(in: store))
        prompt.setText("Be terse. {request}", in: store)
        #expect(prompt.text(in: store) == "Be terse. {request}")
        #expect(prompt.isEdited(in: store))
        prompt.setText("   \n", in: store)
        #expect(prompt.text(in: store) == prompt.defaultText, "blank goes back to the default")
        prompt.setText("Be terse. {request}", in: store)
        prompt.setText(prompt.defaultText, in: store)
        #expect(store.string(forKey: "prompt.test.prompt") == nil, "the default itself isn't stored")
        prompt.setText("x", in: store)
        prompt.setText(nil, in: store)
        #expect(!prompt.isEdited(in: store))
    }

    @Test func fillsPlaceholdersAndKeepsRequiredData() {
        let store = freshStore()
        #expect(prompt.render(["request": "weather?", "app": "The user is in Safari."], in: store)
                == "Answer briefly.\nThe user is in Safari.\n\nRequest: weather?")
        #expect(prompt.render(["request": "weather?"], in: store) == "Answer briefly.\n\nRequest: weather?",
                "an empty optional placeholder leaves no extra blank line")
        #expect(prompt.render(["request": "a\n\n\n\nb"], in: store).hasSuffix("Request: a\n\n\n\nb"), "data is left alone")
        prompt.setText("Just answer.", in: store)
        #expect(prompt.render(["request": "weather?", "app": "Safari"], in: store) == "Just answer.\n\nweather?",
                "a deleted required placeholder is added at the end; an optional one isn't")
    }
}

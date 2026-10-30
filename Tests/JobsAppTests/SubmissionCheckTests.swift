import Foundation
import JavaScriptCore
import Testing
@testable import JobsApp

/// Runs the confirmation check against a stand-in page: its text, and how many form fields are still showing.
@MainActor private func check(text: String, visibleFields: Int = 0) throws -> PageForm.Confirmation {
    let js = try #require(JSContext())
    js.setObject(text, forKeyedSubscript: "pageText" as NSString)
    js.setObject(visibleFields, forKeyedSubscript: "fieldCount" as NSString)
    js.evaluateScript("""
    var field = { getBoundingClientRect: () => ({ width: 100, height: 20 }) };
    var document = { body: { innerText: pageText }, querySelectorAll: () => Array(fieldCount).fill(field) };
    """)
    let output = try #require(js.evaluateScript("JSON.stringify(\(PageForm.confirmScript))")?.toString())
    return try JSONDecoder().decode(PageForm.Confirmation.self, from: Data(output.utf8))
}

@MainActor @Suite struct SubmissionCheckTests {
    @Test func confirmationPageCounts() throws {
        let result = try check(text: "Acme\nThank you for applying!\nYour application has been submitted. We'll be in touch.")
        #expect(result.confirmed)
        #expect(result.snippet?.contains("Thank you for applying") == true)
        #expect(try check(text: "We've received your application for Software Engineer.").confirmed)
    }

    @Test func formStillShowingDoesNotCount() throws {
        // A posting's blurb ("…thanks for your interest in…") above a form that hasn't been sent yet.
        #expect(try !check(text: "Thanks for your interest in Acme. Apply below.", visibleFields: 3).confirmed)
    }

    @Test func ordinaryPageDoesNotCount() throws {
        let result = try check(text: "Software Engineer · Remote · Apply for this job")
        #expect(!result.confirmed)
        #expect(result.snippet == nil)
    }
}

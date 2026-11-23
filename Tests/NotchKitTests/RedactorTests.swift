import Foundation
import Testing
@testable import NotchKit

/// Personal details come out before anything is sent to Jev, and what's left still means something.
@Suite struct RedactorTests {
    private let identity = ["Jane Doe", "jane.doe@gmail.com"]

    @Test func yourOwnNameBecomesMyName() {
        let redactor = Redactor(identity: identity)
        #expect(redactor.text("Jane_Doe_Resume_2026.pdf", as: .fileName) == "MY_NAME_Resume_2026.pdf")
        #expect(redactor.text("janedoe-cover-letter.docx", as: .fileName) == "MY_NAME-cover-letter.docx")
        #expect(redactor.text("Notes for jane", as: .fileName) == "Notes for MY_NAME")
    }

    @Test func contactDetailsBecomePlaceholders() {
        let redactor = Redactor(identity: identity)
        #expect(redactor.text("mail jane.doe@gmail.com or bob@acme.io") == "mail MY_EMAIL or EMAIL_1")
        #expect(!redactor.text("call me at (415) 555-0134 tomorrow").contains("555"))
        #expect(redactor.text("card 4242 4242 4242 4242 exp") == "card NUMBER_1 exp")
        #expect(redactor.text("ssn 123-45-6789") == "ssn NUMBER_2")  // numbering continues within a request
        #expect(redactor.text("key sk-ant-abcdefghijklmnop1234") == "key SECRET_1")
    }

    @Test func theSameDetailGetsTheSamePlaceholder() {
        let redactor = Redactor(identity: [])
        let first = redactor.text("from bob@acme.io")
        let second = redactor.text("reply to bob@acme.io, cc amy@acme.io")
        #expect(first == "from EMAIL_1")
        #expect(second == "reply to EMAIL_1, cc EMAIL_2")
    }

    @Test func otherPeoplesNamesInTextAreReplaced() {
        let redactor = Redactor(identity: [])
        let title = redactor.text("Interview with Michael Chen at Stripe")
        #expect(!title.contains("Michael") && !title.contains("Chen"), "got: \(title)")
        #expect(title.hasPrefix("Interview with PERSON_1"), "got: \(title)")
    }

    @Test func fileNamesKeepWhatTheyAreFor() {
        let redactor = Redactor(identity: identity)
        // Organizations and places stay in file and folder names: they say what the folder is for.
        #expect(redactor.text("GitHub", as: .fileName) == "GitHub")
        #expect(redactor.text("Screenshot 2026-11-22 at 10.15.03.png", as: .fileName) == "Screenshot 2026-11-22 at 10.15.03.png")
        #expect(redactor.text("Invoice-0042.pdf", as: .fileName) == "Invoice-0042.pdf")
    }

    @Test func pathsStartAtHomeAndAreRedactedPartByPart() {
        let redactor = Redactor(identity: identity)
        let home = NSHomeDirectory()
        #expect(redactor.path(home + "/Documents/Jane Doe/Resumes") == "~/Documents/MY_NAME/Resumes")
        #expect(redactor.path(home) == "~")
        #expect(redactor.path("/tmp/build") == "/tmp/build")
    }

    @Test func urlsKeepTheSiteAndTheShapeOfThePath() {
        let redactor = Redactor(identity: identity)
        #expect(redactor.url("https://boards.greenhouse.io/acme/jobs/4123456?gh_src=jane.doe") == "boards.greenhouse.io/acme/jobs/<id>")
        #expect(redactor.url("https://github.com/janedoe/notchman/pull/12") == "github.com/MY_NAME/notchman/pull/12")
    }

    @Test func theFinalCheckCatchesAnythingLeftOver() {
        let clean: JSONValue = ["file": "MY_NAME_Resume.pdf", "folder": "~/Documents/Resumes", "size": 2]
        #expect(Redactor.leaks(in: clean, identity: identity).isEmpty)
        let planted: JSONValue = ["file": "resume.pdf", "note": ["sent by Jane Doe", "jane.doe@gmail.com"]]
        let leaks = Redactor.leaks(in: planted, identity: identity)
        #expect(leaks.contains("jane doe") && leaks.contains("jane.doe@gmail.com"), "got: \(leaks)")
        #expect(!Redactor.leaks(in: ["n": "4242 4242 4242 4242"], identity: []).isEmpty)
    }

    @Test func aNameInsideAnotherWordIsNotYourName() {
        let redactor = Redactor(identity: identity)
        #expect(redactor.text("Does it belong in Docs?") == "Does it belong in Docs?")
        #expect(Redactor.leaks(in: ["q": "Does the user want to move it?"], identity: identity).isEmpty)
    }

    @Test func luhnTellsCardNumbersFromOtherLongNumbers() {
        #expect(Redactor.passesLuhn("4242 4242 4242 4242"))
        #expect(!Redactor.passesLuhn("1234 5678 9012 3456"))
    }
}

import Foundation
import Testing
import NotchKit
@testable import JobsApp

@MainActor @Suite struct AddFromBrowserTests {
    private func tab(_ url: String, _ title: String) -> BrowserTab {
        BrowserTab(url: URL(string: url)!, title: title, browser: "Safari")
    }

    @Test func jobBoardPathNamesTheCompany() {
        let guess = JobsApp.guess(from: tab("https://boards.greenhouse.io/acme-robotics/jobs/123",
                                            "Job Application for Software Engineer Intern at Acme Robotics"))
        #expect(guess.company == "Acme Robotics")
        #expect(guess.title == "Job Application for Software Engineer Intern at Acme Robotics")
    }

    @Test func workdaySubdomainNamesTheCompany() {
        let guess = JobsApp.guess(from: tab("https://globex.wd5.myworkdayjobs.com/en-US/careers/job/123", "Backend Engineer"))
        #expect(guess.company == "Globex")
    }

    @Test func otherwiseTheSiteNameAndFirstTitlePart() {
        let guess = JobsApp.guess(from: tab("https://careers.initech.com/jobs/42", "ML Intern | Initech Careers"))
        #expect(guess.company == "Initech")
        #expect(guess.title == "ML Intern")
        #expect(JobsApp.guess(from: tab("https://www.hooli.com/x", "Data Scientist - Hooli")).title == "Data Scientist")
    }
}

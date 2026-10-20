import Foundation
import Testing
@testable import CalendarApp

@Suite struct MeetingLinksTests {
    @Test func conferenceDataBeatsHangoutBeatsLocation() {
        let link = MeetingLinks.link(conferenceVideo: "https://ibm.zoom.us/j/1", hangoutLink: "https://meet.google.com/abc",
                                     location: "https://ibm.webex.com/meet/x")
        #expect(link?.host() == "ibm.zoom.us")
        #expect(MeetingLinks.link(conferenceVideo: nil, hangoutLink: "https://meet.google.com/abc",
                                  location: "https://ibm.webex.com/meet/x")?.host() == "meet.google.com")
        #expect(MeetingLinks.link(conferenceVideo: nil, hangoutLink: nil,
                                  location: "https://ibm.webex.com/meet/x")?.host() == "ibm.webex.com")
    }

    @Test func locationLinksBeyondZoomMeetTeams() {
        #expect(MeetingLinks.link(inText: "Webex: https://ibm.webex.com/meet/jdoe")?.host() == "ibm.webex.com")
        #expect(MeetingLinks.link(inText: "https://company.zoomgov.com/j/123")?.host() == "company.zoomgov.com")
        #expect(MeetingLinks.link(inText: "https://meet.jit.si/standup")?.host() == "meet.jit.si")
    }

    @Test func linksWithoutSchemeAndAnyWebLinkCount() {
        #expect(MeetingLinks.link(inText: "zoom.us/j/123456")?.host() == "zoom.us")
        // A non-meeting link in the location still gets a Join button.
        #expect(MeetingLinks.link(inText: "Inside IBM https://www.ibm.com/events/inside")?.host() == "www.ibm.com")
    }

    @Test func meetingServicePreferredOverOtherLinks() {
        let text = "Agenda https://docs.google.com/doc/1 — join https://acme.webex.com/meet/x"
        #expect(MeetingLinks.link(inText: text)?.host() == "acme.webex.com")
    }

    @Test func ignoresNonWebLinksAndPlainPlaces() {
        #expect(MeetingLinks.link(inText: "Room 3B, Building 2") == nil)
        #expect(MeetingLinks.link(inText: "mailto:someone@ibm.com") == nil)
        #expect(MeetingLinks.link(conferenceVideo: "tel:+15551234", hangoutLink: nil, location: nil) == nil)
        #expect(MeetingLinks.link(inText: nil) == nil)
    }

    @Test func lookalikeHostsDontCountAsMeetings() {
        #expect(!MeetingLinks.isMeeting(URL(string: "https://notzoom.us.example.com/j/1")!))
        #expect(MeetingLinks.isMeeting(URL(string: "https://app.slack.com/huddle/T1/C1")!))
        #expect(!MeetingLinks.isMeeting(URL(string: "https://app.slack.com/client/T1")!))
    }
}

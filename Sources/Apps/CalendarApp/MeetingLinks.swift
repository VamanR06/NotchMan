import Foundation

/// Finds the link the Join button opens for a calendar event.
enum MeetingLinks {
    /// Video-meeting services (a link on any subdomain counts, e.g. ibm.webex.com, company.zoom.us).
    static let knownHosts = [
        "zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "meet.jit.si", "gotomeeting.com", "goto.com", "bluejeans.com", "chime.aws", "whereby.com",
        "meetings.ringcentral.com", "around.co", "discord.gg", "join.skype.com",
    ]

    /// In order: the event's conference video link (Meet, or Zoom/Teams/Webex add-ons), Google's
    /// `hangoutLink`, then a link in the location.
    static func link(conferenceVideo: String?, hangoutLink: String?, location: String?) -> URL? {
        if let video = web(conferenceVideo) { return video }
        if let hangout = web(hangoutLink) { return hangout }
        return link(inText: location)
    }

    /// A meeting link in free text. Known meeting services win; otherwise the first web link (a link put in the
    /// location is almost always the meeting). Links without `https://` are recognized too.
    static func link(inText text: String?) -> URL? {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        return links.first(where: isMeeting) ?? links.first
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host == "app.slack.com" { return url.path().contains("huddle") }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func web(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

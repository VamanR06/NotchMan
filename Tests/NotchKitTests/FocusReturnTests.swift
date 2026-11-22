import Testing
@testable import NotchKit

/// Where the keyboard goes when the notch closes.
@MainActor @Suite struct FocusReturnTests {
    private func target(active: Bool = true, toNotchMan: Bool = false, window: Bool = false, keyKeeps: Bool = false,
                        app: Bool = true) -> NotchFocus.ReturnTarget {
        NotchFocus.returnTarget(isActive: active, returnToNotchMan: toNotchMan, hasReturnWindow: window,
                                keyWindowKeepsFocus: keyKeeps, hasOtherApp: app)
    }

    @Test func notchManInactiveMeansTheAppYouWereInStillHasIt() {
        #expect(target(active: false) == .nothing)
        #expect(target(active: false, toNotchMan: true, window: true) == .nothing)
    }

    @Test func typingInTheNotchGoesBackToTheAppYouWereIn() {
        // A web page or text field activated NotchMan; no Settings window involved.
        #expect(target() == .otherApp)
    }

    @Test func activatedWithoutRememberingTheAppStillGoesBack() {
        // `previous` was never set, but the last other app is known: focus mustn't stay in a closed notch.
        #expect(target(app: true) == .otherApp)
        #expect(target(app: false) == .nothing)
    }

    @Test func comingFromSettingsGoesBackToSettings() {
        #expect(target(toNotchMan: true, window: true) == .notchManWindow)
    }

    @Test func settingsOpenBehindIsNotWhereYouWere() {
        // You were in another app with Settings open behind it: focus goes back to that app, not Settings.
        #expect(target(toNotchMan: false, window: true) == .otherApp)
    }

    @Test func aDialogOrSettingsInFrontKeepsTheKeyboard() {
        #expect(target(keyKeeps: true) == .nothing)
    }

    @Test func theNotchManWindowYouCameFromWasClosed() {
        #expect(target(toNotchMan: true, window: false) == .otherApp)
    }
}

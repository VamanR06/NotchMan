import Testing
@testable import NotchEngine

@MainActor @Suite struct SystemHUDTests {
    @Test func volumeStepsSnapToSixteenthsOrFineSixtyFourths() {
        #expect(SystemVolume.stepped(0.5, up: true, fine: false) == Float(9) / 16)
        #expect(SystemVolume.stepped(0.5, up: false, fine: false) == Float(7) / 16)
        // Off-grid levels snap first, then step.
        #expect(SystemVolume.stepped(0.51, up: true, fine: false) == Float(9) / 16)
        #expect(SystemVolume.stepped(0.5, up: true, fine: true) == Float(33) / 64)
        #expect(SystemVolume.stepped(1, up: true, fine: false) == 1)
        #expect(SystemVolume.stepped(0, up: false, fine: false) == 0)
    }

    @Test func volumeSymbols() {
        #expect(SystemVolume.symbol(level: 0.8, muted: true) == "speaker.slash.fill")
        #expect(SystemVolume.symbol(level: 0, muted: false) == "speaker.slash.fill")
        #expect(SystemVolume.symbol(level: 0.2, muted: false) == "speaker.wave.1.fill")
        #expect(SystemVolume.symbol(level: 0.9, muted: false) == "speaker.wave.3.fill")
    }

    @Test func powerMessagesOnPlugAndThresholds() {
        #expect(SystemHUDs.powerMessage(before: (false, 50), now: (true, 50))?.text == "50%")
        #expect(SystemHUDs.powerMessage(before: (false, 50), now: (true, 50))?.symbol == "battery.100percent.bolt")
        #expect(SystemHUDs.powerMessage(before: (true, 80), now: (false, 80))?.symbol == "battery.75percent")
        #expect(SystemHUDs.powerMessage(before: (false, 21), now: (false, 20))?.text == "20% left")
        #expect(SystemHUDs.powerMessage(before: (false, 11), now: (false, 10))?.symbol == "battery.0percent")
        // Nothing new: same state, or already past the threshold, or charging.
        #expect(SystemHUDs.powerMessage(before: (false, 19), now: (false, 18)) == nil)
        #expect(SystemHUDs.powerMessage(before: (true, 21), now: (true, 20)) == nil)
    }
}

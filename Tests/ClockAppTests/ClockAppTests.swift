import Foundation
import Testing
@testable import ClockApp

@Suite struct TimerInputTests {
    @Test func aBareNumberIsMinutes() {
        #expect(TimerInput.parse("5")?.duration == 300)
        #expect(TimerInput.parse("2.5")?.duration == 150)
    }

    @Test func unitsAddUp() {
        #expect(TimerInput.parse("90s")?.duration == 90)
        #expect(TimerInput.parse("1h30m")?.duration == 5400)
        #expect(TimerInput.parse("1 hour 15 min")?.duration == 4500)
        #expect(TimerInput.parse("2 Minutes")?.duration == 120)
    }

    @Test func colonsAreMinutesSecondsOrHoursMinutesSeconds() {
        #expect(TimerInput.parse("1:30")?.duration == 90)
        #expect(TimerInput.parse("1:00:05")?.duration == 3605)
    }

    @Test func leftoverWordsAreTheLabel() {
        let tea = TimerInput.parse("10m green tea")
        #expect(tea?.duration == 600)
        #expect(tea?.label == "green tea")
        #expect(TimerInput.parse("pasta 12 min")?.label == "pasta")
        #expect(TimerInput.parse("25")?.label == "")
    }

    @Test func nothingToTimeIsRejected() {
        #expect(TimerInput.parse("") == nil)
        #expect(TimerInput.parse("tea") == nil)
        #expect(TimerInput.parse("0") == nil)
    }
}

@Suite struct CountdownTimerTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsDownAndComesDue() {
        let timer = CountdownTimer(duration: 60, startingAt: start)
        #expect(timer.remaining(at: start + 15) == 45)
        #expect(timer.progress(at: start + 15) == 0.25)
        #expect(!timer.isDue(at: start + 59))
        #expect(timer.isDue(at: start + 60))
        #expect(timer.remaining(at: start + 100) == 0)
    }

    @Test func pausingHoldsTheTimeLeft() {
        var timer = CountdownTimer(duration: 60, startingAt: start)
        timer.pause(at: start + 20)
        #expect(!timer.isRunning)
        #expect(timer.remaining(at: start + 500) == 40)
        #expect(!timer.isDue(at: start + 500))
        timer.resume(at: start + 500)
        #expect(timer.remaining(at: start + 510) == 30)
    }

    @Test func addingAMinuteExtendsRunningPausedOrFinished() {
        var running = CountdownTimer(duration: 60, startingAt: start)
        running.add(60, at: start + 30)
        #expect(running.remaining(at: start + 30) == 90)
        #expect(running.duration == 120)

        var paused = CountdownTimer(duration: 60, startingAt: start)
        paused.pause(at: start + 10)
        paused.add(60, at: start + 10)
        #expect(paused.remaining(at: start + 99) == 110)

        var done = CountdownTimer(duration: 60, startingAt: start)
        done.hasRung = true
        done.add(60, at: start + 300)
        #expect(done.isRunning)
        #expect(done.remaining(at: start + 300) == 60)
    }

    @Test func restartGoesBackToTheFullLength() {
        var timer = CountdownTimer(duration: 60, startingAt: start)
        timer.hasRung = true
        timer.restart(at: start + 200)
        #expect(timer.isRunning)
        #expect(timer.remaining(at: start + 200) == 60)
    }

    @Test func survivesEncoding() throws {
        let timer = CountdownTimer(label: "Tea", duration: 180, startingAt: start)
        let data = try JSONEncoder().encode([timer])
        #expect(try JSONDecoder().decode([CountdownTimer].self, from: data) == [timer])
    }
}

@Suite struct StopwatchTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func runsAcrossStartsAndStops() {
        var watch = Stopwatch()
        watch.start(at: start)
        #expect(watch.elapsed(at: start + 5) == 5)
        watch.stop(at: start + 5)
        #expect(watch.elapsed(at: start + 100) == 5)
        watch.start(at: start + 100)
        #expect(watch.elapsed(at: start + 103) == 8)
    }

    @Test func lapsRecordEachLapsOwnLength() {
        var watch = Stopwatch()
        watch.start(at: start)
        watch.lap(at: start + 10)
        watch.lap(at: start + 14)
        watch.lap(at: start + 30)
        #expect(watch.laps == [10, 4, 16])
        #expect(watch.currentLap(at: start + 32) == 2)
        #expect(watch.bestAndWorstLap?.best == 1)
        #expect(watch.bestAndWorstLap?.worst == 2)
    }

    @Test func resetClearsEverything() {
        var watch = Stopwatch()
        watch.start(at: start)
        watch.lap(at: start + 3)
        watch.stop(at: start + 4)
        watch.reset()
        #expect(watch.isReset)
    }
}

@Suite struct ClockFormatTests {
    @Test func countdownsRoundUpAndShowHoursWhenNeeded() {
        #expect(ClockFormat.countdown(59.2) == "1:00")
        #expect(ClockFormat.countdown(0) == "0:00")
        #expect(ClockFormat.countdown(3725) == "1:02:05")
    }

    @Test func stopwatchShowsHundredths() {
        #expect(ClockFormat.stopwatch(65.27) == "1:05.27")
        #expect(ClockFormat.stopwatch(3600.5) == "1:00:00.50")
    }

    @Test func spokenLengths() {
        #expect(ClockFormat.spoken(300) == "5 min")
        #expect(ClockFormat.spoken(5400) == "1 h 30 min")
        #expect(ClockFormat.spoken(45) == "45 sec")
    }

    @Test func offsetsAndDaysBetweenZones() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        // 2026-01-15 22:00 in New York (EST, UTC−5) is 12:00 the next day in Tokyo.
        let now = Date(timeIntervalSince1970: 1_768_532_400)
        #expect(ClockFormat.offset(of: tokyo, from: newYork, at: now) == "+14h")
        #expect(ClockFormat.offset(of: newYork, from: kolkata, at: now) == "−10h 30m")
        #expect(ClockFormat.offset(of: newYork, from: newYork, at: now) == "Same time")
        #expect(ClockFormat.relativeDay(in: tokyo, from: newYork, at: now) == "Tomorrow")
        #expect(ClockFormat.relativeDay(in: newYork, from: tokyo, at: now) == "Yesterday")
    }

    @Test func cityNames() {
        #expect(ClockFormat.city("America/New_York") == "New York")
        #expect(ClockFormat.city("UTC") == "UTC")
    }
}

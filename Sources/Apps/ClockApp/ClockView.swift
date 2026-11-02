import NotchKit
import SwiftUI

struct ClockView: View {
    @Bindable var app: ClockApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch app.tab {
            case .clock: ClockTab(app: app)
            case .timer: TimerTab(app: app)
            case .stopwatch: StopwatchTab(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(ClockApp.Tab.allCases, id: \.self) { tab in
                Button { app.tab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.title).fontWeight(.semibold)
                        if let mark = mark(for: tab) {
                            Circle().fill(mark).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(app.tab == tab ? 0.14 : 0)))
                    .foregroundStyle(app.tab == tab ? .white : .white.opacity(0.6))
                }
            }
            Spacer()
            if app.isRinging {
                Button { app.stopRinging() } label: {
                    Label("Silence", systemImage: "bell.slash.fill")
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.orange))
                        .foregroundStyle(.black)
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
    }

    /// A dot on tabs with something going: orange for a finished timer, green while running.
    private func mark(for tab: ClockApp.Tab) -> Color? {
        switch tab {
        case .clock: nil
        case .timer:
            app.timers.contains(where: \.hasRung) ? .orange : app.timers.contains(where: \.isRunning) ? .green : nil
        case .stopwatch: app.stopwatch.isRunning ? .green : nil
        }
    }
}

// MARK: - Clock

private struct ClockTab: View {
    let app: ClockApp

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(now, format: .dateTime.hour().minute().second())
                        .font(.system(size: 46, weight: .light).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(now, format: .dateTime.weekday(.wide).month(.wide).day().year())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(localZoneName(at: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(width: 250, alignment: .leading)
                .padding(.top, 4)

                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)

                worldClocks(now: now)
            }
        }
    }

    private func localZoneName(at now: Date) -> String {
        let zone = TimeZone.current
        let name = zone.localizedName(for: zone.isDaylightSavingTime(for: now) ? .daylightSaving : .standard, locale: .current)
        return name ?? ClockFormat.city(zone.identifier)
    }

    @ViewBuilder
    private func worldClocks(now: Date) -> some View {
        if app.worldClocks.isEmpty {
            VStack(spacing: 6) {
                Text("See the time in other cities here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Button("Add Cities…") { app.openSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(app.worldClocks, id: \.self) { identifier in
                        if let zone = TimeZone(identifier: identifier) {
                            WorldClockRow(identifier: identifier, zone: zone, now: now)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct WorldClockRow: View {
    let identifier: String
    let zone: TimeZone
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ClockFormat.city(identifier))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(ClockFormat.relativeDay(in: zone, at: now)), \(ClockFormat.offset(of: zone, at: now))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            Image(systemName: isDaytime ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 10))
                .foregroundStyle(isDaytime ? .yellow.opacity(0.8) : .white.opacity(0.4))
            Text(now, format: Date.FormatStyle(timeZone: zone).hour().minute())
                .font(.system(size: 20, weight: .light).monospacedDigit())
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private var isDaytime: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (7..<19).contains(calendar.component(.hour, from: now))
    }
}

// MARK: - Timer

private struct TimerTab: View {
    @Bindable var app: ClockApp
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                newTimerField
                ForEach(app.presets, id: \.self) { minutes in
                    Button { app.startTimer(minutes * 60) } label: {
                        Text(minutes >= 60 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Start a \(ClockFormat.spoken(minutes * 60)) timer")
                }
            }
            if app.timers.isEmpty {
                Text("Pick a length or type one — “10m tea”, “1:30”, “1h 15m”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(app.timers) { timer in
                            TimerCard(app: app, timer: timer)
                        }
                    }
                }
                if app.timers.contains(where: \.hasRung) {
                    HStack {
                        Spacer()
                        Button("Clear Finished") { app.clearFinished() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private var newTimerField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("New timer", text: $app.timerText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(app.startTypedTimer)
            if app.canStartTypedTimer {
                Button(action: app.startTypedTimer) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(focused ? 0.12 : 0.06)))
        .frame(maxWidth: .infinity)
        .onChange(of: focused) { _, typing in app.setTyping(typing) }
    }
}

private struct TimerCard: View {
    let app: ClockApp
    let timer: CountdownTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.isRunning ? 0.25 : 60)) { context in
            let now = context.date
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: 1 - timer.progress(at: now))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: timer.progress(at: now))
                    if timer.hasRung {
                        Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(timer.hasRung ? "Done" : ClockFormat.countdown(timer.remaining(at: now)))
                        .font(.system(size: 20, weight: .light).monospacedDigit())
                        .foregroundStyle(timer.hasRung ? .orange : timer.isRunning ? .white : .white.opacity(0.6))
                    Text(timer.label.isEmpty ? ClockFormat.spoken(timer.duration) : timer.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                controls
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(timer.hasRung ? 0.1 : 0.06)))
    }

    private var tint: Color { timer.hasRung ? .orange : timer.isRunning ? .green : .white.opacity(0.4) }

    private var controls: some View {
        HStack(spacing: 4) {
            if timer.hasRung {
                iconButton("arrow.counterclockwise", help: "Restart") { app.restart(timer) }
            } else {
                iconButton(timer.isRunning ? "pause.fill" : "play.fill", help: timer.isRunning ? "Pause" : "Resume") {
                    app.togglePause(timer)
                }
            }
            iconButton("goforward.60", help: "Add a minute") { app.addMinute(timer) }
            iconButton("xmark", help: "Remove") { app.remove(timer) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Stopwatch

private struct StopwatchTab: View {
    let app: ClockApp

    var body: some View {
        let watch = app.stopwatch
        TimelineView(.periodic(from: .now, by: watch.isRunning ? 0.03 : 60)) { context in
            let now = context.date
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ClockFormat.stopwatch(watch.elapsed(at: now)))
                        .font(.system(size: 46, weight: .light).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    HStack(spacing: 8) {
                        if watch.isRunning {
                            pill("Lap", tint: .white.opacity(0.15), text: .white, action: app.lap)
                        } else {
                            pill("Reset", tint: .white.opacity(0.15), text: .white, action: app.resetStopwatch)
                                .disabled(watch.isReset)
                                .opacity(watch.isReset ? 0.4 : 1)
                        }
                        pill(watch.isRunning ? "Stop" : "Start", tint: watch.isRunning ? .red.opacity(0.85) : .green,
                             text: .black, action: app.toggleStopwatch)
                    }
                    Text("Space start/stop · L lap · R reset")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(width: 270, alignment: .leading)

                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)

                laps(watch, now: now)
            }
        }
    }

    @ViewBuilder
    private func laps(_ watch: Stopwatch, now: Date) -> some View {
        if watch.laps.isEmpty && !watch.isRunning {
            Text("Laps show here.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let marks = watch.bestAndWorstLap
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if watch.isRunning || !watch.laps.isEmpty {
                        lapRow(watch.laps.count + 1, ClockFormat.stopwatch(watch.currentLap(at: now)), color: .white.opacity(0.7))
                    }
                    ForEach(watch.laps.indices.reversed(), id: \.self) { index in
                        let color: Color = index == marks?.best ? .green : index == marks?.worst ? .red : .white
                        lapRow(index + 1, ClockFormat.stopwatch(watch.laps[index]), color: color)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func lapRow(_ number: Int, _ time: String, color: Color) -> some View {
        HStack {
            Text("Lap \(number)")
            Spacer()
            Text(time).monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private func pill(_ title: String, tint: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 74, height: 28)
                .background(Capsule().fill(tint))
                .foregroundStyle(text)
        }
        .buttonStyle(.plain)
    }
}

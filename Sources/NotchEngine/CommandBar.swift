import AppKit
import NotchKit
import SwiftUI
import os

/// The command bar: type to find anything the apps offer, or say what you want done. Local matches show as you type;
/// a moment after you pause, Jev reads the request and offers the action it means at the top.
@MainActor @Observable
final class CommandBarModel {
    enum Row: Identifiable {
        case action(CommandInterpretation, CommandAction)
        case item(CommandItem)
        /// Opens a Claude chat with the text typed in, when no app offers its own fallbacks.
        case askClaude(String)

        var id: String {
            switch self {
            case .action(let interpretation, _): "action:" + interpretation.actionID
            case .item(let item): "item:" + item.id
            case .askClaude: "ask"
            }
        }
    }

    /// An item's answer, shown in place of the rows.
    struct Answer {
        let title: String
        var text: String?
        var error: String?
        var isLoading: Bool { text == nil && error == nil }
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            confirming = nil
            if answer != nil { closeAnswer() }  // typing again goes back to the results
            update()
        }
    }
    private(set) var rows: [Row] = []
    var selection = 0
    /// Jev is reading the request.
    private(set) var isAsking = false
    /// A risky action waiting for a second Return.
    private(set) var confirming: String?
    /// An answer being shown (Esc goes back to the rows).
    private(set) var answer: Answer?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var fallbacks: [CommandItem] = []

    /// What the apps offer for a query.
    @ObservationIgnored var commands: (String) -> NotchCommands = { _ in .none }
    /// Something ran: show `app` (or close the notch when nil).
    @ObservationIgnored var onRun: (String?) -> Void = { _ in }
    /// Pause after typing before asking Jev.
    @ObservationIgnored var debounce: Duration = .milliseconds(250)
    @ObservationIgnored private var interpretation: (CommandInterpretation, CommandAction)?
    @ObservationIgnored private var jevTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.notchman", category: "command-bar")

    func reset() {
        jevTask?.cancel()
        answerTask?.cancel()
        answer = nil
        query = ""
        interpretation = nil
        rows = []
        selection = 0
        confirming = nil
        isAsking = false
    }

    /// Local results at once; Jev after a pause, for requests of two or more words.
    func update() {
        jevTask?.cancel()
        isAsking = false
        interpretation = nil
        let text = query.trimmingCharacters(in: .whitespaces)
        let offered = commands(text)
        fallbacks = text.isEmpty ? [] : offered.fallbacks
        rebuild(items: text.isEmpty ? [] : CommandRouting.search(text, in: offered.items))
        guard Self.shouldAskJev(text), !offered.actions.isEmpty, JevSettings.isAvailable else { return }
        let request = CommandRouting.request(query: text, actions: offered.actions, context: .current(),
                                             redactor: Jev.redactor())
        isAsking = true
        jevTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            do {
                let answers = try await Jev.ask(state: request.state, questions: request.questions, timeout: 2)
                guard let self, !Task.isCancelled, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
                self.isAsking = false
                if let reading = CommandRouting.interpret(answers, actions: offered.actions, options: request.options),
                   let action = offered.actions.first(where: { $0.id == reading.actionID }) {
                    self.interpretation = (reading, action)
                    self.rebuild(items: CommandRouting.search(text, in: offered.items))
                }
            } catch {
                self?.isAsking = false
                self?.log.notice("Jev couldn't read the request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func show(_ produce: @escaping @MainActor () async throws -> String, title: String) {
        answerTask?.cancel()
        answer = Answer(title: title)
        answerTask = Task { [weak self] in
            do {
                let text = try await produce()
                guard !Task.isCancelled else { return }
                self?.answer?.text = text
            } catch {
                guard !Task.isCancelled else { return }
                self?.answer?.error = error.localizedDescription
            }
        }
    }

    /// Back from an answer to the rows (Esc).
    func closeAnswer() {
        answerTask?.cancel()
        answer = nil
    }

    /// One word is a search; two or more might be a request.
    static func shouldAskJev(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 2
    }

    private func rebuild(items: [CommandItem]) {
        let selectedID = rows.indices.contains(selection) ? rows[selection].id : nil
        var rows: [Row] = []
        if let (reading, action) = interpretation { rows.append(.action(reading, action)) }
        rows += items.map(Row.item)
        let text = query.trimmingCharacters(in: .whitespaces)
        rows += fallbacks.map(Row.item)
        if !text.isEmpty && fallbacks.isEmpty { rows.append(.askClaude(text)) }
        self.rows = rows
        // Jev's reading arriving moves the selection to it only if you hadn't moved off the first row.
        selection = interpretation != nil && (selection == 0 || selectedID == nil) ? 0
            : min(rows.firstIndex { $0.id == selectedID } ?? 0, max(rows.count - 1, 0))
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + step, 0), rows.count - 1)
        confirming = nil
    }

    func runSelected() {
        guard answer == nil, rows.indices.contains(selection) else { return }
        run(rows[selection])
    }

    func run(_ row: Row) {
        switch row {
        case .action(let reading, let action):
            if action.risk == .confirm && confirming != row.id {
                confirming = row.id
                return
            }
            action.perform(reading.choices)
            onRun(action.revealsApp)
        case .item(let item):
            if item.needsConfirm && confirming != row.id {
                confirming = row.id
                return
            }
            if let produce = item.answer {
                show(produce, title: item.title)
                return
            }
            item.run()
            onRun(item.revealsApp)
        case .askClaude(let text):
            AskAI.shared.send(text, service: "claude")
            onRun("chat")
        }
        reset()
    }
}

/// The bar's view: a field, then the rows. Over the selected app's content while it's open.
struct CommandBarView: View {
    @Bindable var bar: CommandBarModel
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Find anything, or say what to do — “move the pdf I downloaded to Resumes”", text: $bar.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(bar.runSelected)
                    .onKeyPress(.downArrow) { bar.move(1); return .handled }
                    .onKeyPress(.upArrow) { bar.move(-1); return .handled }
                    .onKeyPress(.escape) {
                        if bar.answer != nil { bar.closeAnswer() } else if bar.query.isEmpty { close() } else { bar.query = "" }
                        return .handled
                    }
                if bar.isAsking { NotchSpinner(size: 11, lineWidth: 1.6) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))

            if let answer = bar.answer {
                AnswerView(answer: answer, back: bar.closeAnswer)
            } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(bar.rows.enumerated()), id: \.element.id) { index, row in
                            CommandRowView(row: row, selected: index == bar.selection,
                                           confirming: bar.confirming == row.id)
                                .id(row.id)
                                .onTapGesture {
                                    bar.selection = index
                                    bar.run(row)
                                }
                        }
                        if bar.rows.isEmpty { hints }
                    }
                }
                .onChange(of: bar.selection) { _, index in
                    if bar.rows.indices.contains(index) { proxy.scrollTo(bar.rows[index].id) }
                }
            }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .onAppear { focused = true }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Find shelved files, downloads, folders, agents and tasks by name.")
            Text(JevSettings.isAvailable
                 ? "Or describe what you want: “approve the agent in NotchMan”, “check off call recruiter”."
                 : "Connect Jev in Settings → Intelligence to describe what you want in your own words.")
            Text("↑↓ to choose · Return to run · Esc to close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 12).padding(.top, 4)
    }
}

/// Claude's answer (or the error), with the question above it.
private struct AnswerView: View {
    let answer: CommandBarModel.Answer
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(.orange)
                Text(answer.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Back (Esc)", action: back).buttonStyle(.plain).font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(.vertical) {
                Group {
                    if let text = answer.text {
                        Text(text).textSelection(.enabled)
                    } else if let error = answer.error {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 6) {
                            NotchSpinner(size: 11, lineWidth: 1.6)
                            Text("Claude is thinking…").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct CommandRowView: View {
    let row: CommandBarModel.Row
    let selected: Bool
    let confirming: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(isAction ? Color.accentColor : .white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: isAction ? .semibold : .regular)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Text(trailing)
                .font(.system(size: 10, weight: confirming ? .semibold : .regular))
                .foregroundStyle(confirming ? .orange : .white.opacity(selected ? 0.6 : 0.35))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
    }

    private var isAction: Bool { if case .action = row { true } else { false } }

    private var symbol: String {
        switch row {
        case .action(_, let action): action.symbol
        case .item(let item): item.symbol
        case .askClaude: "sparkle"
        }
    }

    private var title: String {
        switch row {
        case .action(let reading, let action): action.summary(reading.choices)
        case .item(let item): item.title
        case .askClaude(let text): "Ask Claude: “\(text)”"
        }
    }

    private var subtitle: String? {
        switch row {
        case .action(let reading, _): "Jev · \(Int((reading.confidence * 100).rounded()))% sure"
        case .item(let item): [item.kind, item.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .askClaude: "Opens a new Claude chat with this typed in"
        }
    }

    private var trailing: String {
        if confirming { return "Return again to confirm" }
        if case .item(let item) = row, item.needsConfirm, selected { return "↩ (asks first)" }
        if case .action(_, let action) = row, action.risk == .confirm, selected { return "↩ (asks first)" }
        return selected ? "↩" : ""
    }
}

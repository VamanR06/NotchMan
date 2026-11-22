import Charts
import NotchKit
import SwiftUI

/// One element of what a notch app draws, as its `render` hook returned it: a type, props, children. Callbacks are
/// `{ "__handler": "h3" }` props, run back in the app's script when used.
public struct ModNode: Equatable, Sendable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [ModNode]

    public init(type: String, props: [String: JSONValue] = [:], children: [ModNode] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    /// The element types the renderer draws (and the authoring guide documents).
    public static let types: Set<String> = [
        "Box", "Row", "Column", "Text", "Button", "Input", "Toggle", "Select", "List", "ProgressBar", "Countdown",
        "Chart", "Badge", "Divider", "Spacer", "Symbol", "Grid", "Markdown", "Link", "Scroll",
    ]

    /// Reads a tree from its JSON; throws with the path of the first thing wrong, for the author (Claude) to fix.
    public static func decode(_ value: JSONValue, path: String = "root") throws -> ModNode {
        guard case .object(let object) = value else { throw ModError.badTree("\(path) is not an element") }
        guard case .string(let type)? = object["type"] else { throw ModError.badTree("\(path) has no type") }
        guard types.contains(type) else {
            throw ModError.badTree("\(path) is a \"\(type)\", which isn't an element (use one of: \(types.sorted().joined(separator: ", ")))")
        }
        var props: [String: JSONValue] = [:]
        if case .object(let given)? = object["props"] { props = given }
        var children: [ModNode] = []
        if case .array(let items)? = object["children"] {
            children = try items.enumerated().map { try decode($1, path: "\(path).\(type)[\($0)]") }
        }
        return ModNode(type: type, props: props, children: children)
    }

    func string(_ key: String) -> String? {
        switch props[key] {
        case .string(let value)?: value
        case .number(let value)?: value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value)?: String(value)
        default: nil
        }
    }

    func number(_ key: String) -> Double? {
        if case .number(let value)? = props[key] { return value }
        return nil
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let value)? = props[key] { return value }
        return false
    }

    func handler(_ key: String) -> String? {
        if case .object(let object)? = props[key], case .string(let id)? = object["__handler"] { return id }
        return nil
    }

    /// Text from a `text` prop, else from text children.
    var text: String {
        string("text") ?? string("label") ?? children.compactMap { $0.type == "Text" ? $0.text : nil }.joined()
    }
}

public enum ModError: LocalizedError, Equatable {
    case badTree(String)
    case script(String)
    case noRender
    case timeout(String)
    case badManifest(String)

    public var errorDescription: String? {
        switch self {
        case .badTree(let detail): "The drawing isn't valid: \(detail)"
        case .script(let detail): "Script error: \(detail)"
        case .noRender: "The app doesn't register a render hook (on('render', ...))."
        case .timeout(let what): "The app took too long in \(what) (it may loop forever)."
        case .badManifest(let detail): "manifest.json: \(detail)"
        }
    }
}

/// Draws a `ModNode` tree with the notch's look; `send` runs a callback in the app's script.
struct ModNodeView: View {
    let node: ModNode
    let send: (String, JSONValue?) -> Void

    var body: some View {
        switch node.type {
        case "Box", "Column":
            VStack(alignment: alignment, spacing: spacing(default: 6)) { children }
                .modifier(BoxStyle(node: node))
        case "Row":
            HStack(alignment: .center, spacing: spacing(default: 8)) { children }
                .modifier(BoxStyle(node: node))
        case "Grid":
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing(default: 6)),
                                     count: max(1, Int(node.number("columns") ?? 2))),
                      spacing: spacing(default: 6)) { children }
                .modifier(BoxStyle(node: node))
        case "Scroll":
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: spacing(default: 6)) { children }
            }
        case "Text":
            Text(node.text)
                .font(.system(size: size, weight: weight, design: node.bool("mono") ? .monospaced : .default))
                .foregroundStyle(color(node.string("color")) ?? .white.opacity(node.bool("dim") ? 0.5 : 0.9))
                .monospacedDigit()
        case "Markdown":
            Text((try? AttributedString(markdown: node.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(node.text))
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.9))
        case "Symbol":
            Image(systemName: node.string("name") ?? "questionmark")
                .font(.system(size: size))
                .foregroundStyle(color(node.string("color")) ?? .white.opacity(0.8))
        case "Button":
            Button { press("onPress") } label: {
                HStack(spacing: 5) {
                    let symbol = node.string("symbol")
                    if let symbol { Image(systemName: symbol) }
                    // A one-character label beside a symbol ("+" with plus) would only repeat it.
                    if !node.text.isEmpty && !(symbol != nil && node.text.count == 1) { Text(node.text) }
                }
                .fixedSize()
                .frame(minHeight: 16)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(node.string("variant") == "primary"
                                                                    ? Color.accentColor : .white.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(node.bool("disabled"))
        case "Input":
            ModInput(node: node, send: send)
        case "Toggle":
            Toggle(node.text, isOn: Binding(get: { node.bool("value") }, set: { send(node.handler("onChange") ?? "", .bool($0)) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
        case "Select":
            Picker(node.string("label") ?? "", selection: Binding(
                get: { node.string("value") ?? "" },
                set: { send(node.handler("onChange") ?? "", .string($0)) })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
        case "List":
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                    ModNodeView(node: child, send: send)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
                        .contentShape(Rectangle())
                        .onTapGesture { if let id = node.handler("onSelect") { send(id, .number(Double(index))) } }
                }
            }
        case "ProgressBar":
            // Drawn by hand: macOS's own bar ignores the tint.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color(node.string("color")) ?? .accentColor)
                        .frame(width: geo.size.width * min(max(node.number("value") ?? 0, 0), 1))
                }
            }
            .frame(height: 6)
        case "Countdown":
            ModCountdown(node: node)
        case "Chart":
            ModChart(node: node)
        case "Badge":
            Text(node.text)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((color(node.string("color")) ?? .accentColor).opacity(0.3)))
        case "Divider":
            Divider().overlay(.white.opacity(0.15))
        case "Spacer":
            Spacer(minLength: node.number("size").map { CGFloat($0) } ?? 0)
        case "Link":
            if let url = node.string("url").flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme) {
                Link(node.text.isEmpty ? url.absoluteString : node.text, destination: url).font(.system(size: 12))
            }
        default:
            EmptyView()
        }
    }

    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in ModNodeView(node: child, send: send) }
    }

    private func press(_ key: String) {
        if let id = node.handler(key) { send(id, nil) }
    }

    private var options: [String] {
        if case .array(let items)? = node.props["options"] {
            return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        return []
    }

    private var alignment: HorizontalAlignment {
        switch node.string("align") {
        case "center": .center
        case "end", "trailing": .trailing
        default: .leading
        }
    }

    private func spacing(default value: CGFloat) -> CGFloat {
        node.number("gap").map { CGFloat($0) } ?? value
    }

    private var size: CGFloat {
        switch node.string("size") {
        case "caption": 10
        case "small": 11
        case "title": 20
        case "large": 28
        case "huge": 40
        default: node.number("size").map { CGFloat($0) } ?? 12.5
        }
    }

    private var weight: Font.Weight {
        switch node.string("weight") {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: node.bool("bold") ? .semibold : .regular
        }
    }
}

/// Named colors only, so generated apps stay in the notch's palette.
func color(_ name: String?) -> Color? {
    switch name {
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "green": .green
    case "blue": .blue
    case "purple": .purple
    case "pink": .pink
    case "gray", "grey": .gray
    case "white": .white
    case "accent": .accentColor
    default: nil
    }
}

private struct BoxStyle: ViewModifier {
    let node: ModNode

    func body(content: Content) -> some View {
        content
            .padding(node.number("padding").map { CGFloat($0) } ?? 0)
            .frame(maxWidth: node.bool("fill") ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(node.bool("card") ? Color.white.opacity(0.06) : .clear))
    }
}

private struct ModInput: View {
    let node: ModNode
    let send: (String, JSONValue?) -> Void
    @State private var draft = ""

    var body: some View {
        TextField(node.string("placeholder") ?? "", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            .onAppear { draft = node.string("value") ?? "" }
            .onChange(of: draft) { _, value in if let id = node.handler("onInput") { send(id, .string(value)) } }
            .onSubmit {
                if let id = node.handler("onSubmit") { send(id, .string(draft)) }
                if node.bool("clearOnSubmit") { draft = "" }
            }
    }
}

/// Counts down to `until` (milliseconds since 1970) by itself, so the script doesn't redraw every second.
private struct ModCountdown: View {
    let node: ModNode

    var body: some View {
        let until = Date(timeIntervalSince1970: (node.number("until") ?? 0) / 1000)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            Text(left >= 3600 ? String(format: "%d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
                 : String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: node.number("size").map { CGFloat($0) } ?? 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(left == 0 ? .orange : .white)
        }
    }
}

/// A small line or bar chart: `points` is a list of `{ x, y }` (x a label or number).
private struct ModChart: View {
    let node: ModNode

    private struct Point: Identifiable {
        let id: Int
        let x: String
        let y: Double
    }

    private var points: [Point] {
        guard case .array(let items)? = node.props["points"] else { return [] }
        return items.enumerated().compactMap { index, item in
            guard case .object(let object) = item, case .number(let y)? = object["y"] else { return nil }
            let x: String = switch object["x"] {
            case .string(let s)?: s
            case .number(let n)?: n.rounded() == n ? String(Int(n)) : String(n)
            default: String(index + 1)
            }
            return Point(id: index, x: x, y: y)
        }
    }

    var body: some View {
        Chart(points) { point in
            if node.string("kind") == "line" {
                LineMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(color(node.string("color")) ?? .accentColor)
            } else {
                BarMark(x: .value("x", point.x), y: .value("y", point.y))
                    .foregroundStyle(color(node.string("color")) ?? .accentColor)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: node.number("height").map { CGFloat($0) } ?? 80)
    }
}

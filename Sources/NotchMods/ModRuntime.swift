import AppKit
import Foundation
import JavaScriptCore
import NotchKit
import os

/// A generated notch app's `manifest.json`.
public struct ModManifest: Codable, Equatable, Sendable {
    public var name: String
    /// SF Symbol for the dock.
    public var symbol: String?
    /// Content height in points (120–420).
    public var height: Double?
    public var description: String?
    /// Only `network` exists: lets the app use `$.http.fetch`.
    public var permissions: [String]?

    public init(name: String, symbol: String? = nil, height: Double? = nil, description: String? = nil,
                permissions: [String]? = nil) {
        self.name = name
        self.symbol = symbol
        self.height = height
        self.description = description
        self.permissions = permissions
    }

    public var allowsNetwork: Bool { permissions?.contains("network") == true }

    public static func decode(_ data: Data) throws -> ModManifest {
        do {
            let manifest = try JSONDecoder().decode(ModManifest.self, from: data)
            guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ModError.badManifest("name is empty") }
            return manifest
        } catch let error as ModError {
            throw error
        } catch {
            throw ModError.badManifest("not valid JSON with a name (\(error.localizedDescription))")
        }
    }
}

/// What an app shows beside the collapsed notch (`$.ui.chip({ text, symbol, color })`).
public struct ModChip: Equatable, Sendable {
    public var text: String
    public var symbol: String?
    public var color: String?
}

/// Runs one generated notch app's script in its own JavaScriptCore context, on its own queue, so a slow or stuck
/// script never blocks the notch. The script gets the same shape as a Claude Code mod — `register(on)` with hooks and a
/// `$` API — but only what a small notch app needs: drawing, a chip, saved values, timers, notifications, copy, links,
/// and the network if its manifest asks. No files, no processes.
public final class ModRuntime: @unchecked Sendable {
    // Main-actor callbacks (set before `start`).
    public var onTree: @MainActor (Result<ModNode, ModError>) -> Void = { _ in }
    /// A hook or callback threw (shown under the app without replacing its drawing).
    public var onError: @MainActor (String) -> Void = { _ in }
    public var onChip: @MainActor (ModChip?) -> Void = { _ in }
    public var onToast: @MainActor (String) -> Void = { _ in }
    public var onNotify: @MainActor (String, String) -> Void = { _, _ in }

    public let manifest: ModManifest
    private let storeURL: URL?
    private let queue: DispatchQueue
    private var context: JSContext?
    private var store: [String: String] = [:]
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextTimer = 1
    private var renderScheduled = false
    private let busyLock = NSLock()
    private var busySince: Date?
    private var busyLabel = ""
    private static let log = Logger(subsystem: "com.notchman", category: "mods")

    public init(manifest: ModManifest, storeURL: URL?) {
        self.manifest = manifest
        self.storeURL = storeURL
        queue = DispatchQueue(label: "com.notchman.mod.\(manifest.name)")
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            store = saved
        }
    }

    // MARK: Lifecycle

    /// Loads the script, runs `register(on)` and `app.start`, then draws.
    public func start(script: String) {
        perform("starting") { [self] in
            setUp()
            guard let context else { return }
            context.evaluateScript(Self.prelude)
            context.evaluateScript(Self.prepare(script))
            if reportException("loading the script") { return }
            context.evaluateScript("if (typeof register !== 'function') throw new Error('The script must define function register(on).'); register(__on)")
            if reportException("register") { return }
            context.evaluateScript("__fire('app.start')")
            _ = reportException("app.start")
            renderNow()
        }
    }

    public func stop() {
        perform("stopping") { [self] in
            context?.evaluateScript("__fire('app.stop')")
            timers.values.forEach { $0.cancel() }
            timers.removeAll()
            context = nil
        }
    }

    /// The notch opened on this app.
    public func notchOpened() {
        perform("notch.open") { [self] in
            context?.evaluateScript("__fire('notch.open')")
            _ = reportException("notch.open")
            renderNow()
        }
    }

    /// A control in the drawing was used: run its callback, then draw again.
    public func send(_ handler: String, value: JSONValue?) {
        perform("a callback") { [self] in
            guard let context, let press = context.objectForKeyedSubscript("__press") else { return }
            press.call(withArguments: [handler, Self.jsonString(value) as Any])
            _ = reportException("a callback")
            renderNow()
        }
    }

    public func render() {
        perform("render") { [self] in renderNow() }
    }

    /// How long the script has been busy in one call, and in what (for the "not responding" check).
    public var busy: (seconds: TimeInterval, label: String)? {
        busyLock.lock()
        defer { busyLock.unlock() }
        return busySince.map { (Date().timeIntervalSince($0), busyLabel) }
    }

    // MARK: Inside the queue

    private func perform(_ label: String, _ work: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            busyLock.lock(); busySince = Date(); busyLabel = label; busyLock.unlock()
            work()
            busyLock.lock(); busySince = nil; busyLock.unlock()
        }
    }

    private func setUp() {
        let context = JSContext(virtualMachine: JSVirtualMachine())!
        context.name = manifest.name
        let native = JSValue(newObjectIn: context)!
        let set = { (name: String, block: Any) in native.setObject(block, forKeyedSubscript: name as NSString) }
        set("invalidate", { [weak self] in self?.scheduleRender() } as @convention(block) () -> Void)
        set("chip", { [weak self] (json: String?) in
            let chip = json.flatMap { try? JSONDecoder().decode(ChipJSON.self, from: Data($0.utf8)) }
                .map { ModChip(text: $0.text ?? "", symbol: $0.symbol, color: $0.color) }
            self?.main { $0.onChip(chip) }
        } as @convention(block) (String?) -> Void)
        set("toast", { [weak self] (text: String) in self?.main { $0.onToast(text) } } as @convention(block) (String) -> Void)
        set("notify", { [weak self] (title: String, body: String) in self?.main { $0.onNotify(title, body) } }
            as @convention(block) (String, String) -> Void)
        set("copy", { (text: String) in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } as @convention(block) (String) -> Void)
        set("open", { (text: String) in
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme) else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        } as @convention(block) (String) -> Void)
        set("storeGet", { [weak self] (key: String) -> String? in self?.store[key] } as @convention(block) (String) -> String?)
        set("storeSet", { [weak self] (key: String, value: String?) in self?.storeSet(key, value) }
            as @convention(block) (String, String?) -> Void)
        set("timer", { [weak self] (ms: Double, repeats: Bool) -> Int in self?.addTimer(ms: ms, repeats: repeats) ?? 0 }
            as @convention(block) (Double, Bool) -> Int)
        set("cancelTimer", { [weak self] (id: Int) in self?.timers.removeValue(forKey: id)?.cancel() } as @convention(block) (Int) -> Void)
        set("fetch", { [weak self] (id: Int, url: String, initJSON: String) in self?.fetch(id: id, url: url, initJSON: initJSON) }
            as @convention(block) (Int, String, String) -> Void)
        set("error", { [weak self] (message: String) in self?.main { $0.onError(message) } } as @convention(block) (String) -> Void)
        set("allowsNetwork", manifest.allowsNetwork)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
        self.context = context
    }

    private struct ChipJSON: Decodable {
        var text: String?
        var symbol: String?
        var color: String?
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        queue.async { [self] in
            renderScheduled = false
            perform("render") { [self] in renderNow() }
        }
    }

    private func renderNow() {
        guard let context, let render = context.objectForKeyedSubscript("__render") else { return }
        let result = render.call(withArguments: [])
        if let message = takeException() {
            main { $0.onTree(.failure(.script("in render: \(message)"))) }
            return
        }
        let text = result?.isString == true ? result!.toString()! : ""
        if text == "__norender__" { main { $0.onTree(.failure(.noRender)) }; return }
        let tree: Result<ModNode, ModError>
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            tree = .success(try ModNode.decode(value))
        } catch let error as ModError {
            tree = .failure(error)
        } catch {
            tree = .failure(.badTree("render didn't return an element (got \(text.prefix(80)))"))
        }
        main { $0.onTree(tree) }
    }

    /// Reports a pending exception as a script error; true when there was one.
    private func reportException(_ phase: String) -> Bool {
        guard let message = takeException() else { return false }
        main { $0.onTree(.failure(.script("in \(phase): \(message)"))) }
        return true
    }

    private func takeException() -> String? {
        guard let exception = context?.exception, !exception.isUndefined, !exception.isNull else { return nil }
        context?.exception = nil
        let line = exception.objectForKeyedSubscript("line").flatMap { $0.isUndefined ? nil : $0.toString() }
        return (exception.toString() ?? "error") + (line.map { " (line \($0))" } ?? "")
    }

    private func storeSet(_ key: String, _ value: String?) {
        store[key] = value
        guard let storeURL else { return }
        let snapshot = store
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: storeURL, options: .atomic)
        }
    }

    private func addTimer(ms: Double, repeats: Bool) -> Int {
        let id = nextTimer
        nextTimer += 1
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(max(ms, 250)))
        timer.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
        timer.setEventHandler { [weak self] in
            self?.perform("a timer") { [weak self] in
                guard let self, let context = self.context else { return }
                context.objectForKeyedSubscript("__tick")?.call(withArguments: [id])
                _ = self.reportException("a timer")
                if !repeats { self.timers.removeValue(forKey: id) }
                self.renderNow()
            }
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    private func fetch(id: Int, url text: String, initJSON: String) {
        @Sendable func respond(_ ok: Bool, _ status: Int, _ body: String, _ error: String) {
            perform("a fetch response") { [weak self] in
                guard let self, let context = self.context else { return }
                context.objectForKeyedSubscript("__response")?.call(withArguments: [id, ok, status, body, error])
                _ = self.reportException("a fetch response")
                self.renderNow()
            }
        }
        guard manifest.allowsNetwork else {
            return respond(false, 0, "", "This app's manifest doesn't ask for the network permission.")
        }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme) else {
            return respond(false, 0, "", "Only http and https addresses can be fetched.")
        }
        struct Init: Decodable {
            var method: String?
            var headers: [String: String]?
            var body: String?
        }
        let options = (try? JSONDecoder().decode(Init.self, from: Data(initJSON.utf8))) ?? Init()
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = options.method ?? "GET"
        options.headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = options.body.map { Data($0.utf8) }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: (data ?? Data()).prefix(2_000_000), as: UTF8.self)
            respond(error == nil, status, body, error?.localizedDescription ?? "")
        }.resume()
    }

    private func main(_ work: @escaping @MainActor (ModRuntime) -> Void) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { work(self) } }
    }

    static func jsonString(_ value: JSONValue?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Scripts are written like ES modules (`export function register`); JavaScriptCore runs plain scripts.
    static func prepare(_ script: String) -> String {
        script.replacingOccurrences(of: #"(?m)^\s*export\s+(default\s+)?"#, with: "", options: .regularExpression)
    }

    // MARK: The script's side

    static let prelude = """
    'use strict';
    const __hooks = {};
    function __on(name, fn) {
      if (typeof fn !== 'function') throw new Error('on(' + name + ') needs a function');
      (__hooks[name] = __hooks[name] || []).push(fn);
    }
    function __report(error) { __native.error(String((error && (error.message || error)) || error)); }
    function __guard(result) { if (result && typeof result.then === 'function') result.then(null, __report); }
    let __handlers = new Map(), __nextHandler = 0;
    function __el(type) {
      return function (props, ...rest) {
        if (typeof props === 'string' || typeof props === 'number') props = { text: String(props) };
        props = props || {};
        const out = {};
        for (const key of Object.keys(props)) {
          if (key === 'children') continue;
          const value = props[key];
          if (typeof value === 'function') {
            const id = 'h' + (__nextHandler++);
            __handlers.set(id, value);
            out[key] = { __handler: id };
          } else if (value !== undefined) {
            out[key] = value;
          }
        }
        const kids = [].concat(props.children === undefined ? [] : props.children, rest).flat(Infinity)
          .filter(c => c !== null && c !== undefined && c !== false && c !== true)
          .map(c => (typeof c === 'string' || typeof c === 'number') ? { type: 'Text', props: { text: String(c) }, children: [] } : c);
        return { type: type, props: out, children: kids };
      };
    }
    const __elements = {};
    for (const t of [\(ModNode.types.sorted().map { "'\($0)'" }.joined(separator: ", "))]) __elements[t] = __el(t);
    const __timers = new Map();
    const __requests = new Map();
    let __nextRequest = 1;
    const $ = Object.freeze({
      ui: Object.freeze({
        elements: __elements,
        invalidate: () => __native.invalidate(),
        chip: (chip) => __native.chip(chip ? JSON.stringify(chip) : null),
        toast: (text) => __native.toast(String(text)),
      }),
      store: Object.freeze({
        get: (key) => { const v = __native.storeGet(String(key)); return (v === null || v === undefined) ? undefined : JSON.parse(v); },
        set: (key, value) => __native.storeSet(String(key), JSON.stringify(value === undefined ? null : value)),
        delete: (key) => __native.storeSet(String(key), null),
      }),
      clock: Object.freeze({
        now: () => Date.now(),
        every: (ms, fn) => { const id = __native.timer(Number(ms), true); __timers.set(id, fn); return { cancel: () => { __native.cancelTimer(id); __timers.delete(id); } }; },
        after: (ms, fn) => { const id = __native.timer(Number(ms), false); __timers.set(id, fn); return { cancel: () => { __native.cancelTimer(id); __timers.delete(id); } }; },
      }),
      http: Object.freeze({
        fetch: (url, init) => new Promise((resolve, reject) => {
          const id = __nextRequest++;
          __requests.set(id, { resolve, reject });
          __native.fetch(id, String(url), JSON.stringify(init || {}));
        }),
      }),
      notify: (title, body) => __native.notify(String(title), body === undefined || body === null ? '' : String(body)),
      copy: (text) => __native.copy(String(text)),
      open: (url) => __native.open(String(url)),
    });
    function __fire(name) { for (const fn of (__hooks[name] || [])) { try { __guard(fn($)); } catch (e) { __report(e); } } }
    function __render() {
      __handlers = new Map(); __nextHandler = 0;
      const fns = __hooks['render'] || [];
      if (!fns.length) return '__norender__';
      const tree = fns[0]($, __elements);
      if (tree && typeof tree.then === 'function') throw new Error('render must return an element, not a promise (keep render synchronous)');
      return JSON.stringify(tree === undefined ? null : tree);
    }
    function __press(id, json) {
      const fn = __handlers.get(id);
      if (!fn) return;
      try { __guard(fn(json === null || json === undefined ? undefined : JSON.parse(json))); } catch (e) { __report(e); }
    }
    function __tick(id) {
      const fn = __timers.get(id);
      if (!fn) return;
      try { __guard(fn()); } catch (e) { __report(e); }
    }
    function __response(id, ok, status, text, error) {
      const request = __requests.get(id);
      if (!request) return;
      __requests.delete(id);
      if (ok) request.resolve({ ok: status >= 200 && status < 300, status: status, text: text, json: () => JSON.parse(text) });
      else request.reject(new Error(error || 'request failed'));
    }
    """
}

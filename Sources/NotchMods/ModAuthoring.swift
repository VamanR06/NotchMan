import Foundation
import NotchKit

/// What Claude reads to write a notch app: the API, the elements, the rules, an example, and the reply format.
public enum ModAuthoring {
    public static let guide = #"""
    You write small apps for NotchMan, a panel in the Mac's notch. An app is a manifest and one JavaScript file. It runs
    in a sandbox (JavaScriptCore, no Node, no DOM, no setTimeout, no files, no processes) and draws with native elements.

    ## The script
    Define `function register(on)` and register hooks with `on(name, fn)`:
    - `on('render', ($, elements) => tree)` — required, exactly one. Return one element tree, built fresh from your
      state each time. Synchronous: never async, never a promise. It runs after every event, callback and timer.
    - `on('app.start', ($) => {})` — once when the app loads (load saved state, start timers).
    - `on('notch.open', ($) => {})` — when the notch is about to open.
    - `on('app.stop', ($) => {})` — before it unloads.
    Keep state in variables at the top of the file. Callbacks change state; the app redraws on its own afterwards.

    ## The $ API
    - `$.store.get(key)` / `$.store.set(key, value)` / `$.store.delete(key)` — JSON values saved between launches.
    - `$.clock.now()` (ms), `$.clock.every(ms, fn)` and `$.clock.after(ms, fn)` (min 250 ms; each returns
      `{ cancel() }`). Use these instead of setTimeout/setInterval.
    - `$.ui.chip({ text, symbol, color })` shows a small chip beside the collapsed notch (`$.ui.chip(null)` hides it).
      `$.ui.toast(text)` shows a brief message. `$.ui.invalidate()` redraws (rarely needed).
    - `$.notify(title, body)` posts a macOS notification. `$.copy(text)` copies. `$.open(url)` opens an http(s) link.
    - `$.http.fetch(url, { method, headers, body })` → Promise of `{ ok, status, text, json() }`. Only if the manifest's
      `permissions` include "network"; await it inside an async callback or hook, never in render.

    ## Elements (the second argument of render; call with a props object, then children)
    Layout: `Column({ gap, align: 'start'|'center'|'end', padding, card, fill }, ...children)`,
    `Row({ gap, padding, card, fill }, ...children)`, `Grid({ columns, gap }, ...children)`, `Scroll({}, ...children)`,
    `Spacer({ size })`, `Divider()`. `card: true` gives a subtle rounded background; `fill: true` takes the full width.
    Content: `Text({ text, size: 'caption'|'small'|'title'|'large'|'huge'|<number>, weight: 'medium'|'semibold'|'bold',
    color, mono, dim })` (or `Text('plain string')`), `Markdown({ text })` (inline: **bold**, *italic*, `code`, links),
    `Symbol({ name, size, color })` (SF Symbols), `Badge({ text, color })`, `ProgressBar({ value: 0...1, color })`,
    `Countdown({ until: <ms timestamp>, size })` (ticks by itself — don't redraw every second for a timer),
    `Chart({ kind: 'bar'|'line', points: [{ x, y }], color, height })`, `Link({ url, text })`.
    Controls: `Button({ label, symbol, variant: 'primary', disabled, onPress })`,
    `Input({ placeholder, value, clearOnSubmit, onSubmit: (text) => {}, onInput: (text) => {} })`,
    `Toggle({ label, value, onChange: (on) => {} })`, `Select({ label, options: [strings], value, onChange: (v) => {} })`,
    `List({ onSelect: (index) => {} }, ...rows)` (each child is a tappable row).
    Colors are names only: red, orange, yellow, green, blue, purple, pink, gray, white, accent. Strings and numbers as
    children become Text. `null`/`false` children are skipped (handy for conditionals).

    ## Design rules
    - The space is small: about 600×(manifest height) points, dark background, white text. One clear purpose; at most
      a few controls; no scrolling unless it's a list.
    - Use Countdown for timers, chips for glanceable status, notifications for things that happen while closed.
    - Save anything the user would expect to survive a restart with $.store.
    - No external libraries, no `import`, no top-level await.

    ## Example (a pomodoro timer)
    ```json
    { "name": "Pomodoro", "symbol": "timer", "height": 170, "description": "25-minute focus timer" }
    ```
    ```javascript
    let endsAt = null
    let done = 0

    function finish($) {
      endsAt = null
      done += 1
      $.store.set('done', done)
      $.ui.chip(null)
      $.notify('Pomodoro', 'Time for a break')
    }

    function register(on) {
      on('app.start', ($) => {
        done = $.store.get('done') ?? 0
        endsAt = $.store.get('endsAt') ?? null
        $.clock.every(1000, () => { if (endsAt && $.clock.now() >= endsAt) finish($) })
      })
      on('render', ($, { Column, Row, Text, Button, Countdown }) => Column({ gap: 10, align: 'center', fill: true },
        endsAt ? Countdown({ until: endsAt, size: 40 }) : Text({ text: '25:00', size: 'huge', weight: 'semibold' }),
        Row({ gap: 8 },
          Button({ label: endsAt ? 'Stop' : 'Start', variant: 'primary', onPress: () => {
            endsAt = endsAt ? null : $.clock.now() + 25 * 60 * 1000
            $.store.set('endsAt', endsAt)
            $.ui.chip(endsAt ? { text: 'focus', symbol: 'timer', color: 'orange' } : null)
          } }),
          Text({ text: done + ' done today', dim: true }))))
    }
    ```

    ## Your reply
    Reply with exactly two fenced blocks and nothing else: first ```json with the manifest (`name` — short, 1–3 words;
    `symbol` — an SF Symbol; `height` — 120 to 420; `description`; `permissions: ["network"]` only if it must fetch),
    then ```javascript with the whole script.
    """#

    /// The guide and the repair note, as you've edited them in Settings → Prompts.
    public static let guidePrompt = EditablePrompt(
        id: "mods.guide", group: "Notch apps", title: "How to write a notch app",
        detail: "Claude reads this before making or changing an app you describe; your request (and the app's current code, for a change) follows it. Keep the \"Your reply\" section: NotchMan reads the json and javascript blocks.",
        defaultText: guide)

    public static let repairNote = EditablePrompt(
        id: "mods.repair", group: "Notch apps", title: "Fixing an app that didn't load",
        detail: "Sent back to Claude, in the same conversation, when the app it wrote fails to load.",
        placeholders: [.init("problem", "the error NotchMan hit")],
        defaultText: """
            That app didn't load in NotchMan: {problem}
            Fix it and reply with the whole manifest and script again, in the same two blocks and nothing else.
            """)

    public static var prompts: [EditablePrompt] { [guidePrompt, repairNote] }

    public static func newAppPrompt(_ request: String) -> String {
        guidePrompt.text + "\n\n## The app to make\n" + request
    }

    public static func changePrompt(_ request: String, manifest: String, script: String) -> String {
        guidePrompt.text + """


        ## The app as it is
        ```json
        \(manifest)
        ```
        ```javascript
        \(script)
        ```

        ## The change to make
        \(request)

        Reply with the whole updated manifest and script, in the same two blocks.
        """
    }

    public static func repairPrompt(_ problem: String) -> String {
        repairNote.render(["problem": problem])
    }

    /// The manifest and script from a reply: the first ```json block and the first ```javascript (or ```js) block.
    public static func blocks(in reply: String) -> (manifest: String, script: String)? {
        func block(_ languages: [String]) -> String? {
            for language in languages {
                guard let open = reply.range(of: "```" + language + "\n") ?? reply.range(of: "```" + language + "\r\n") else { continue }
                guard let close = reply.range(of: "\n```", range: open.upperBound..<reply.endIndex) else { continue }
                return String(reply[open.upperBound..<close.lowerBound])
            }
            return nil
        }
        guard let manifest = block(["json"]), let script = block(["javascript", "js"]) else { return nil }
        return (manifest, script)
    }
}

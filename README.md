# NotchMan

A macOS app that lives in the MacBook notch and hosts pluggable "notch apps" switchable from a dock.
Hover the notch to expand it; move away to collapse. Apps can show a compact live indicator beside the
notch while it's collapsed (e.g. the next meeting, or what's playing).

## Build & run

Requires macOS 14+ and Xcode 16+ (Swift 6).

```sh
make run      # build, bundle into build/NotchMan.app, sign, launch
make release  # release build
swift test    # unit tests
```

Open `Package.swift` in Xcode to edit. Quit from the `…` menu in the expanded notch.

## Layout

| Path | What |
| --- | --- |
| `Sources/NotchKit` | SDK every notch app imports: `NotchApp`, `NotchActivity`, `NotchContext`, `Keychain` |
| `Sources/NotchEngine` | Host: notch window, geometry, hover, dock, settings window |
| `Sources/Apps/*` | Notch apps (Calendar, Now Playing) |
| `Sources/NotchMan` | App shell; `AppRegistry.swift` lists the enabled apps |

## Writing a notch app

1. Add `Sources/Apps/MyApp/MyApp.swift` with an `@Observable` class conforming to `NotchApp`
   (id, name, SF Symbol icon, `makeExpandedView()`, optionally `activity`, `makeSettingsView()`, `expandedHeight`).
2. Add a `.target(name: "MyApp", dependencies: ["NotchKit"], path: "Sources/Apps/MyApp")` to `Package.swift`
   and list it as a dependency of `NotchMan`.
3. Add `MyApp()` to `AppRegistry.makeApps()`.

`activate(context:)` gives you per-app `defaults`, `keychain`, a `logger`, `requestAttention(.pulse / .expand)`
and `openSettings()`. Apps keep running when not selected.

## Calendar setup (free)

**Google Calendar:** in Google Cloud Console create a project → enable *Google Calendar API* → OAuth consent
screen (External; add yourself; then *Publish app* so sign-in doesn't expire after 7 days — an unverified app
is fine for personal use) → Credentials → *OAuth client ID* of type **Desktop app**. Paste the client ID and
secret in NotchMan Settings → Calendar and sign in.

**Notion:** create an internal integration at notion.so/profile/integrations, paste its secret in settings, then
share each database with the integration (database `•••` → Connections). Choose the date property per database.
Clicking a Google event opens Notion Calendar if installed (otherwise Google Calendar); right-click for more.

## Now Playing

Controls Spotify via AppleScript. The first time, macOS asks to let NotchMan control Spotify — allow it
(or enable it in System Settings → Privacy & Security → Automation).

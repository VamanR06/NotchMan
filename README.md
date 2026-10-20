# NotchMan

A macOS app that lives in the MacBook notch and hosts pluggable "notch apps" (Calendar, Tasks, Jobs, Chat, Now Playing) switchable from a dock.
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
| `Sources/Apps/*` | Notch apps (Calendar, Tasks, Jobs, Chat, Now Playing) |
| `Sources/NotchMan` | App shell; `AppRegistry.swift` lists the enabled apps |

## Writing a notch app

1. Add `Sources/Apps/MyApp/MyApp.swift` with an `@Observable` class conforming to `NotchApp`
   (id, name, SF Symbol icon, `makeExpandedView()`, optionally `activity`, `makeSettingsView()`, `expandedHeight`, `expandedWidth`).
2. Add a `.target(name: "MyApp", dependencies: ["NotchKit"], path: "Sources/Apps/MyApp")` to `Package.swift`
   and list it as a dependency of `NotchMan`.
3. Add `MyApp()` to `AppRegistry.makeApps()`.

`activate(context:)` gives you per-app `defaults`, `keychain`, a `logger`, `requestAttention(.pulse / .expand)`
and `openSettings()`. Apps keep running when not selected.

## Calendar setup (free)

In Google Cloud Console create a project → enable *Google Calendar API* → OAuth consent screen (External; add
yourself; then *Publish app* so sign-in doesn't expire after 7 days — an unverified app is fine for personal use)
→ Credentials → *OAuth client ID* of type **Desktop app**. Paste the client ID and secret in NotchMan Settings →
Calendar and sign in. Clicking an event opens Notion Calendar if installed (otherwise Google Calendar).

## Tasks (Notion)

Create an internal integration at notion.so/profile/integrations with *Read* and *Update content*, paste its
secret in Settings → Tasks, then share each task database with it (database `•••` → Connections) and enable it.
Tasks are grouped Overdue / Today / Upcoming / No due date; done tasks are hidden. NotchMan detects the due date
property and how the board marks tasks done (a Status property's *Complete* group, a "Done" checkbox, or a select
option like "Done"); both can be overridden per database. Checking a task off writes back to Notion.

## Jobs (JobManager)

Reads applications from a [JobManager](https://github.com/VamanR06/JobManager) server. In Settings → Jobs enter
the server URL and password; NotchMan signs in like the web app and keeps the password in the Keychain to renew
the 30-day session. Shows upcoming OA deadlines and interviews (with Open OA / Join links), applications in
progress, and ones still to apply to; click a row to open it in JobManager. A local server without a password
works too (`http://localhost:3000`, empty password). Plain `http://` is refused for anything but localhost.

## Chat (ChatGPT / Claude / Muse)

The real chatgpt.com, claude.ai and muse.ai, embedded in the notch with a toggle. Sign in once with your own accounts
(you stay signed in); no API keys, and usage is exactly the same as using the websites — nothing is sent unless
you send it. Links to other sites open in your browser. Use the pin button to keep the notch open while reading.

## Now Playing

Controls Spotify via AppleScript. The first time, macOS asks to let NotchMan control Spotify — allow it
(or enable it in System Settings → Privacy & Security → Automation).

**Playlists tab** (needs Spotify Premium — Spotify's rule for developer apps since Feb 2026): at
developer.spotify.com/dashboard create an app, add the redirect URI `http://127.0.0.1:43821/callback`, tick
*Web API*, and paste the Client ID in Settings → Now Playing (no secret needed). Browse your playlists, click a
song to play it within its playlist, or press Play to start a playlist. Spotify only returns the songs of
playlists you own or collaborate on; others can still be played from the top. Liked Songs can't be listed.

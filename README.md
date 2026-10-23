# NotchMan

A macOS app that lives in the MacBook notch and hosts pluggable "notch apps" (Calendar, Tasks, Jobs, Agents, Now Playing) switchable from a dock.
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
| `Sources/Apps/*` | Notch apps (Calendar, Tasks, Jobs, Agents, Now Playing) |
| `Sources/NotchMan` | App shell; `AppRegistry.swift` lists the enabled apps |

## Writing a notch app

1. Add `Sources/Apps/MyApp/MyApp.swift` with an `@Observable` class conforming to `NotchApp`
   (id, name, SF Symbol icon, `makeExpandedView()`, optionally `activity`, `makeSettingsView()`, `expandedHeight`, `expandedWidth`).
2. Add a `.target(name: "MyApp", dependencies: ["NotchKit"], path: "Sources/Apps/MyApp")` to `Package.swift`
   and list it as a dependency of `NotchMan`.
3. Add `MyApp()` to `AppRegistry.makeApps()`.

Collapsed-notch status is a `NotchActivity`: a `chip` (use `NotchChip("2 late", systemImage: "checklist")`
so icon and label stay together), optionally with a split `leading`/`trailing` layout for media. Up to three
show at once, sized to their content.

`activate(context:)` gives you per-app `defaults`, `keychain`, a `logger`, `requestAttention(.pulse / .expand)`,
`openSettings()`, `send(_:to:)` to hand a `NotchMessage` to another app (handled in its `receive(_:)`),
`notify(title:body:payload:)` for macOS notifications, and `isVisible`. Apps keep running when not selected.
`send(_:to:reveal: false)` delivers a message without bringing the other app up, and `showTransient(_:)` briefly
shows a status (icon plus text or a level bar) in place of the chips.

To share data without importing each other, apps publish `BoardItem`s (events, tasks, deadlines, agents,
approvals) and Claude Code `BoardProject`s to `NotchBoard.shared`; the Today and Shelf apps read them. Keyboard
support: implement `handleKey(_:)` and keep a `NotchListSelection` for ↑/↓/Return in lists.

## Keyboard

Press **⌥Space** (change it in Settings → General) from any app to open the notch with the keyboard. Then
**⌘1–9** switch apps, **↑/↓** select in lists, **Return** opens the selection, **⌘Return** runs its second
action (join the meeting, check off the task), **Space** checks off a task, and **Esc** or the hotkey again
closes the notch. Text fields, terminals and chats keep their keys while you type in them.

## Calendar setup (free)

In Google Cloud Console create a project → enable *Google Calendar API* → OAuth consent screen (External; add
yourself; then *Publish app* so sign-in doesn't expire after 7 days — an unverified app is fine for personal use)
→ Credentials → *OAuth client ID* of type **Desktop app**. Paste the client ID and secret in NotchMan Settings →
Calendar and sign in. Clicking an event opens Notion Calendar if installed (otherwise Google Calendar).
Right-click an event → **Reschedule** (15 min / 1 hour later, tomorrow or next week at the same time, or pick a
date and time); it keeps its length, and guests are emailed as in Google Calendar. This needs permission to change
events — if you signed in before it existed, use **Reconnect** in Settings → Calendar. Only calendars you own or
can edit offer it.

## Tasks (Notion)

Create an internal integration at notion.so/profile/integrations with *Read* and *Update content*, paste its
secret in Settings → Tasks, then share each task database with it (database `•••` → Connections) and enable it.
Tasks are grouped Overdue / Today / Upcoming / No due date; done tasks are hidden. NotchMan detects the due date
property and how the board marks tasks done (a Status property's *Complete* group, a "Done" checkbox, or a select
option like "Done"); both can be overridden per database. Checking a task off writes back to Notion. Right-click a task → **Reschedule** (Today, Tomorrow, Next Monday,
Push 1 Week, Pick Date…, Remove Due Date) to change its due date in Notion.

## Jobs (JobManager)

Reads applications from a [JobManager](https://github.com/VamanR06/JobManager) server. In Settings → Jobs enter
the server URL and password; NotchMan signs in like the web app and keeps the password in the Keychain to renew
the 30-day session. Shows upcoming OA deadlines and interviews (with Open OA / Join links), applications in
progress, and ones still to apply to; click a row to open it in JobManager. A local server without a password
works too (`http://localhost:3000`, empty password). Plain `http://` is refused for anything but localhost.

Right-click a job → **Set Status** to move it along (Applied → OA → Interview → Offer/Rejected…). This logs a
status event in JobManager just like the web app; choosing Interview on a job already interviewing starts the
next round. An **Undo** bar shows for a few seconds afterwards.

The **⧉+** button under the counts adds the job open in your browser (Safari, Chrome, Arc, Brave or Edge — the
one in front, or the one you used last). JobManager parses the page, and a short form shows the company and
title to check before adding it to *To apply*, with the posting saved. If you already track it you're asked
before adding it again. macOS asks once per browser to let NotchMan read it.

Jobs you haven't applied to have a ✨ menu of ChatGPT prompts (fit & tailoring, cover letter, interview prep, or
your own in Settings → Jobs). Picking one switches to the Chat app and types the prompt — filled with the job's
title, company, link, location and saved description — into a new ChatGPT chat without sending it. The prompt is
also copied to the clipboard as a fallback. To keep these chats in a ChatGPT project, paste the project's link
(`https://chatgpt.com/g/g-p-…/project`) under Settings → Jobs → ChatGPT Project; each prompt can override it.

## Agents (Claude Code + ChatGPT / Claude / Muse)

One place for AI work. The **Overview** tab shows the three web chats (writing / reply ready) and every Claude
Code session on this Mac — CLI, VS Code and background agents — grouped as Needs you, Working, Done and Idle,
read from `claude agents --json` whenever Claude Code's session files change. Click a background agent to open an
interactive terminal attached to it right in the notch (it keeps running when the notch closes; the notch stays
open while you type, and a click outside closes it) — or choose a new Terminal window instead (header button,
right-click, or the default in Settings). Each agent's terminal is a small workspace: **+** opens shells in the
agent's project folder as tabs next to Claude (type `exit` to close one), and the split button stacks Claude above
a shell. Interactive sessions open their folder in VS Code/Cursor.
**New Agent** starts `claude --bg "<prompt>"` in a project folder. You're notified when an agent needs you or
finishes, and one notch chip summarizes everything (needs you > working > ready). Settings → Agents.

### Chat tabs

The real chatgpt.com, claude.ai and muse.ai, embedded in the notch with a toggle. Sign in once with your own accounts
(you stay signed in); no API keys, and usage is exactly the same as using the websites — nothing is sent unless
you send it. Links to other sites open in your browser. Use the pin button to keep the notch open while reading,
or Pop out to move the chat (conversation and all) into a normal resizable window for more room — handy for
file previews, especially on non-Retina monitors. Closing the window puts it back in the notch.

When a reply that took 3+ seconds finishes while you're not looking at that chat, the notch pulses and shows a
✓ until you open it, and a macOS notification is posted (click it to jump back; turn off in Settings → Chat).
Detection watches only for the site's Stop button — it never reads the conversation.

### Ask from anywhere

Right-click an event, task, job, song, playlist or the playing track and choose **Ask ChatGPT / Claude / Muse**,
then a project (or the default, or none). A new chat opens in the notch with a prompt about that item typed in —
not sent. In Settings → Chat set the prompt wording (`{item}` = the item's details), each service's projects and
default project; **Load from ChatGPT/Claude** reads project names and links from the signed-in sidebar.
Apps opt in with `.askable { "description" }` or `AskMenuItems` inside an existing context menu.

## Now Playing

Controls Spotify via AppleScript. The first time, macOS asks to let NotchMan control Spotify — allow it
(or enable it in System Settings → Privacy & Security → Automation).

**Playlists tab** (needs Spotify Premium — Spotify's rule for developer apps since Feb 2026): at
developer.spotify.com/dashboard create an app, add the redirect URI `http://127.0.0.1:43821/callback`, tick
*Web API*, and paste the Client ID in Settings → Now Playing (no secret needed). Browse your playlists, click a
song to play it within its playlist, or press Play to start a playlist. Spotify only returns the songs of
playlists you own or collaborate on; others can still be played from the top. Liked Songs can't be listed.

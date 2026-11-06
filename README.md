# NotchMan

**Your MacBook's notch, turned into a small home for the things you check all day.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Version](https://img.shields.io/github/v/tag/VamanR06/NotchMan?label=version&sort=semver)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

NotchMan is a native macOS app that lives in the MacBook notch (no Dock icon, no menu-bar clutter). Hover the
notch and it grows into a panel with a dock of **notch apps**: your day, calendar, tasks, job applications,
Claude Code agents, AI chats, a file shelf, music and clocks. Move away and it shrinks back. While collapsed,
apps can show small live chips beside the notch — the next meeting's countdown, what's playing, an agent waiting
for approval.

The dock shows as many apps as fit left of the notch; when there are more, its last button (▦ All Apps) opens a
grid of every app with its ⌘-number. The app you're in always keeps a place in the dock.

## Contents

- [Highlights](#highlights)
- [Requirements](#requirements)
- [Install](#install)
- [First run and permissions](#first-run-and-permissions)
- Using NotchMan: [Keyboard](#keyboard) · [System HUDs](#system-huds) · [Today](#today) ·
  [Calendar](#calendar-setup-free) · [Tasks](#tasks-notion) · [Jobs](#jobs-jobmanager) ·
  [Agents & Chat](#agents-claude-code--chatgpt--claude--muse) · [Shelf](#shelf) · [Now Playing](#now-playing) ·
  [Clock](#clock)
- [Privacy and data](#privacy-and-data)
- [Development](#development)
- [Versions and releases](#versions-and-releases)
- [License](#license)

## Highlights

| App | What it does |
| --- | --- |
| **Today** | The day at a glance: next meeting with Join, tasks due, deadlines, agents that need you, and natural-language quick add ("call recruiter fri 3pm for 30m") |
| **Calendar** | Google Calendar with Join links, a meeting heads-up countdown, double-booking warnings, reschedule and edit in place |
| **Tasks** | Notion task databases grouped by due date; check off, edit, and reschedule one or many at once |
| **Jobs** | Your [JobManager](https://github.com/VamanR06/JobManager) applications: deadlines, status changes, add the job in your browser, drag the right resume, and rules-based form Autofill |
| **Agents** | Every Claude Code session on your Mac, in folders by project; interactive terminals in the notch, New Agent, tool approvals, usage limits — plus embedded ChatGPT, Claude and Muse |
| **Shelf** | Drag files to the notch to hold them or drop them into any folder or Claude Code project; downloads and long-running commands |
| **Now Playing** | Spotify controls and playlist browsing |
| **Clock** | World clocks, timers and a stopwatch |

Also: a global hotkey (**⌥Space**) with full keyboard control, volume/brightness/battery/headphone HUDs in the
notch, a notch on every display, and an SDK (`NotchKit`) for writing your own notch apps.

## Requirements

- A Mac running **macOS 14 Sonoma** or later. A notched MacBook is the intended home; external displays get a
  notch-shaped panel at the top of the screen too.
- **Xcode 16+** (Swift 6 toolchain) to build it.
- Optional, per app: a Google Cloud OAuth client (Calendar), a Notion integration (Tasks), a JobManager server
  (Jobs), the `claude` CLI (Agents), Spotify (Now Playing; Premium for playlists).

## Install

### Download

Every [release](https://github.com/VamanR06/NotchMan/releases) has a `NotchMan-vX.Y.Z.zip` with the app
(universal: Apple silicon and Intel). Unzip it and move `NotchMan.app` to `/Applications`.

The app isn't notarized by Apple, so the first launch is blocked with "can't be opened". Either right-click
NotchMan.app → **Open** → **Open**, or clear the download flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/NotchMan.app
```

The downloaded app is signed ad-hoc, so macOS asks for Accessibility again after each update you install.

### Build from source

```sh
git clone https://github.com/VamanR06/NotchMan.git
cd NotchMan
make run          # build, bundle into build/NotchMan.app, sign, launch
```

To build a specific version, check out its tag first (see [Versions and releases](#versions-and-releases)):

```sh
git checkout v1.0.0
make release      # optimized build in build/NotchMan.app
```

You can copy `build/NotchMan.app` into `/Applications` and add it to System Settings → General → Login Items to
start it at login. Quit from the `…` menu in the expanded notch.

**Signing:** `scripts/bundle.sh` signs with your Apple Development certificate if you have one, so macOS
remembers permissions across rebuilds. Without one it signs ad-hoc, which works, but macOS asks for
Accessibility again after every rebuild.

## First run and permissions

Hover the notch to open it, then open **Settings** from the `…` menu to connect the apps you want. Everything is
optional — an app with nothing set up just tells you what it needs. macOS asks for permissions only when a
feature needs them:

| Permission | Used for |
| --- | --- |
| **Accessibility** | Taking over the volume and brightness keys so the HUD shows in the notch instead of macOS's overlay |
| **Automation** (Apple Events) | Controlling Spotify; reading your browser's current page to add a job or Autofill a form |
| **Notifications** | Meeting, agent, timer, chat-reply and download alerts |
| **Bluetooth** | Showing a HUD when headphones connect |

## Keyboard

Press **⌥Space** (change it in Settings → General) from any app to open the notch with the keyboard. Then
**⌘1–9** switch apps, **↑/↓** select in lists, **Return** opens the selection, **⌘Return** runs its second
action (join the meeting, check off the task), **Space** checks off a task, and **Esc** or the hotkey again
closes the notch. Text fields, terminals and chats keep their keys while you type in them.

## System HUDs

Volume, brightness, charging, low battery and headphones connecting show in the notch as a small icon with a
level bar or text. Allow Accessibility in Settings → General and NotchMan takes over the volume and brightness
keys, so macOS's own overlay doesn't appear (⌥⇧ gives finer steps, as in macOS). Without Accessibility, volume
changes still show in the notch alongside macOS's overlay. An external display's brightness is left to macOS.
Each HUD can be turned off. If NotchMan is signed ad-hoc (no Apple Development certificate), macOS asks for
Accessibility again after every rebuild.

## Today

The first dock app shows the day at a glance, in two columns so it fits without scrolling. It's gathered from
the other apps, so there's nothing to set up. Each item is one line, and longer lists fold behind "+N more".

The left column is what's happening:
- **Next up**: the next meeting as a card with Join, then today's other meetings
- **Needs you**: pending agent approvals and blocked agents
- **Sessions**: Claude Code sessions that are working (spinner) or finished in the last two hours (✓)

The right column is what's due:
- **Due**: overdue and today's tasks, which you can check off right there
- **Deadlines**: OA deadlines and interviews in the next three days

**Quick add** is the field at the top (⌘N from Today, Tasks or Calendar). Type something like
"Call recruiter fri 3pm for 30m" or "buy milk tmrw". A line under the field shows what will be created:
- An **Event** if you gave a time. It goes on your primary Google calendar for 30 minutes, or for the length you
  gave with "for …".
- Otherwise a **Notion task**, due on the day you gave. It goes to the list chosen in Settings → Tasks, or to
  another list if you tag it, e.g. `#school`.

Flip Task/Event before pressing Return if the guess is wrong. Dates are read on your Mac with plain rules, so
the preview is exactly what you'll get.

## Calendar setup (free)

In Google Cloud Console create a project → enable *Google Calendar API* → OAuth consent screen (External; add
yourself; then *Publish app* so sign-in doesn't expire after 7 days — an unverified app is fine for personal use)
→ Credentials → *OAuth client ID* of type **Desktop app**. Paste the client ID and secret in NotchMan Settings →
Calendar and sign in. Clicking an event opens Notion Calendar if installed (otherwise Google Calendar).
Right-click an event → **Reschedule** (15 min / 1 hour later, tomorrow or next week at the same time, or pick a
date and time); it keeps its length, and guests are emailed as in Google Calendar. This needs permission to change
events — if you signed in before it existed, use **Reconnect** in Settings → Calendar. Only calendars you own or
can edit offer it.

**Editing an event:** right-click → **Edit…**, or press **E** on the selected event, to change its title, start
and end (or all-day), location and notes in place. Changing the time emails guests, as Reschedule does. A new
title, place or notes doesn't email anyone. Like Reschedule, this is only offered for calendars you can edit.

**Meeting heads-up:** 90 seconds before a meeting (change or turn off in Settings → Calendar) the notch opens
with a banner: a live countdown, a big **Join** button and any overlap. The chip counts down by the second for
the last two minutes. Events that overlap another you haven't declined are marked ⚠ (the same meeting on two of
your calendars doesn't count), and you're notified once a day if tomorrow is double-booked.

## Tasks (Notion)

Create an internal integration at notion.so/profile/integrations with *Read* and *Update content*, paste its
secret in Settings → Tasks, then share each task database with it (database `•••` → Connections) and enable it.
Tasks are grouped Overdue / Today / Upcoming / No due date; done tasks are hidden. NotchMan detects the due date
property and how the board marks tasks done (a Status property's *Complete* group, a "Done" checkbox, or a select
option like "Done"); both can be overridden per database. Checking a task off writes back to Notion. Right-click a task → **Reschedule** (Today, Tomorrow, Next Monday,
Push 1 Week, Pick Date…, Remove Due Date) to change its due date in Notion.

**Editing a task:** click the pencil that appears on hover, choose **Edit…** from the right-click menu, or press
**E** on the selected task. You can change its title and its due date (with or without a time, or none). Return
saves, Esc cancels, and the change is written to Notion.

**Rescheduling several at once:**
- **Selecting:** ⌘-click tasks to select them, or ⇧-click for a range. Each section header (Overdue, Today…)
  also has **Select**, so moving everything overdue takes two clicks. ⌘A selects all, ⇧↑/↓ extends the
  selection, and Esc clears it.
- **Moving:** while tasks are selected, a bar under the list offers **Today · Tomorrow · Next Mon · +1 Week ·
  Pick Date…**, and Remove Due Dates in its ⋯ menu.
  - Tasks with a time keep it, and +1 Week moves each task from its own due date.
  - **Pick Date…** sets one day for all of them. Tick *Same time for all* to give them one time too.
- **Saving:** the list updates right away and each task is then saved to Notion. Any that fail go back to their
  old date and are counted in an error.

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

**On a job's page** (needs JobManager v0.30+): when your browser shows a job you track, either its posting or
its application form, hovering the notch open goes straight to Jobs. You can turn that off in Settings → Jobs.
A **This page** card at the top has:
- the job's linked **resume** and **cover letter**, ready to drag onto the site's upload box. The ⌄ next to
  each picks which one goes with this job: newest first, showing where each is already used, with archived ones
  in a submenu, or None. Picking links it to the job in JobManager, so it's remembered and Autofill attaches it.
- **Autofill**, which fills the form using JobManager's own rules (the same ones as its ChatGPT autofill):
  - Your Profile, explicit work-eligibility answers, saved answers and your demographic policy. No AI guessing.
  - It attaches the resume and takes a second pass for follow-up questions your answers reveal.
  - Work Experience sections (Workday's My Experience and the like) come from the jobs under Work experience on
    JobManager's Profile page — just the ones the job's resume mentions, in the resume's order (JobManager
    v0.32+; every Profile job if there's no readable resume or it names none of them). It clicks Add until
    there's one entry per job, then fills job title, company, location, "I currently work here", From/To and the
    role description, and the report says which jobs it used.
  - Afterwards it lists what still needs you: essay questions, attestations, anything not in your Profile.
  - It never submits.
- If the form is embedded from Greenhouse or similar on a company's own site, **Open Form** opens it on its
  own in the same browser, still as this job.
- **Applied when you submit:** for a job still in *To apply*, NotchMan watches its tab for half an hour. When
  the site shows its confirmation ("Thank you for applying", "Application submitted") and the form is gone,
  the job moves to *Applied*, with Undo for a minute. It's the same check JobManager uses. Turn it off in
  Settings → Jobs.

A page doesn't have to be the exact link you saved:
- **Following:** if the tab showing a job moves on to another job-looking page (Apply, the form's next step),
  it keeps that job. These are labelled "followed from its page".
- **Remembered:** pages tied to a job this way are remembered for later visits.
- **Linking:** on a job-looking page NotchMan can't place, **Link…** lists your open applications, with ones
  whose company appears in the page's address or title first. Pick one and that page is remembered.
- **Not this job:** the slashed link button forgets a wrong match.

Autofill needs your browser to allow it once:
- Chrome, Arc, Brave or Edge: View → Developer → *Allow JavaScript from Apple Events*
- Safari: Develop → *Allow JavaScript from Apple Events*

Jobs you haven't applied to have a ✨ menu of ChatGPT prompts (fit & tailoring, cover letter, interview prep, or
your own in Settings → Jobs). Picking one switches to the Chat app and types the prompt — filled with the job's
title, company, link, location and saved description — into a new ChatGPT chat without sending it. The prompt is
also copied to the clipboard as a fallback. To keep these chats in a ChatGPT project, paste the project's link
(`https://chatgpt.com/g/g-p-…/project`) under Settings → Jobs → ChatGPT Project; each prompt can override it.

## Agents (Claude Code + ChatGPT / Claude / Muse)

One place for AI work. The **Overview** tab shows the three web chats (writing / reply ready) and every Claude
Code session on this Mac — CLI, VS Code and background agents — read from `claude agents --json` whenever Claude
Code's session files change. They're listed in folders you can fold, each showing the most urgent state among its
sessions; folders with something needing you or working come first and start open. NotchMan makes a folder per
project, which collects that project's sessions on its own (worktrees count as their repo); a project's folder
with a single session shows as just that session. Any folder can be renamed (it keeps collecting its project) or
deleted (its sessions go back to their project's folder, made afresh if needed). Make more with the folder-plus
button beside the search — say one for a session that works on two projects — then drag sessions onto a folder or
right-click a session → Move to Folder (Move All to Folder on a folder). A moved session shows its own project's
name, and Move Back returns it. The last button switches to grouping by status (Needs you, Working, Done and
Idle). Click a background agent to open an
interactive terminal attached to it right in the notch (it keeps running when the notch closes; the notch stays
open while you type, and a click outside closes it) — or choose a new Terminal window instead (header button,
right-click, or the default in Settings). Each agent's terminal is a small workspace: **+** (or ⌘T) opens shells in the
agent's project folder as tabs next to Claude (type `exit` to close one), and the split button stacks Claude above
a shell. **⌘-click** a file or folder named in a terminal (a plan Claude Code saved, a file it edited, `path:12`)
to preview it in a popup — Markdown is formatted, code shows line numbers — with Open, Show in Finder and Copy
Path; Esc or a click outside closes it. Interactive sessions open their folder in VS Code/Cursor.

**Terminal:** the Terminal pill on the Overview (or **⌘T** in the Agents app) opens a terminal of your own in
the notch, in the last folder you used; right-click the pill, a folder or a session for **Open Terminal Here**.
The keyboard goes straight to it and the notch stays open until you click outside. **+** (or ⌘T while typing)
opens another tab in the same folder, and its menu picks another one (Home, your Claude Code projects, Choose
Folder…). Tabs are named after the folder they're in and follow `cd`; **Open in VS Code** (or Cursor, per
Settings) opens that folder, and the folder button shows it in Finder. When you `git clone` in any notch terminal
(an agent's shells too), a pill in the corner shows the clone's progress, then **Open in VS Code** or **cd**
into the new folder. The terminals keep running when you go back to the Overview or the notch closes; `exit` or
× closes one.
**New Agent** starts `claude --bg "<prompt>"` in a project folder (worktree sessions are listed as their repo).
Right-click a project's folder or a session → **New Agent Here…** to open it with that project already picked.
Pick its mode first: **Plan** (the default; it plans and changes nothing until you approve), **Ask first**,
**Accept edits** or **Auto**. The last mode you used is remembered. Return starts it, ⌥Return adds a line. You're notified when an agent needs you or
finishes, and one notch chip summarizes everything (needs you > working > ready). Settings → Agents.

**Approvals in the notch:** in Settings → Agents → Approvals, click **Install Approval Hook**. When a background
agent wants permission for a tool (a command, an edit, a fetch), you can answer from:
- the chip, which shows "Allow Bash?"
- the card at the top of the Overview, with the command or file and **Allow**, **Deny** or **Ask in terminal**
- the Today app
- the notification's Allow/Deny buttons

Claude Code waits for NotchMan before showing its own prompt. If you don't answer within the wait (1 minute by
default), or NotchMan isn't running, the terminal asks as usual. Interactive sessions skip the notch unless you
turn that on. Commands matching risky patterns (`rm -rf`, `sudo`, force-push, `curl … | sh`, writes outside the
project) are marked red, and nothing is ever allowed automatically.

The hook is an HTTP hook to `127.0.0.1:43822` that carries a secret token. It's added next to your existing
hooks in `~/.claude/settings.json`, and a backup of the file is saved as `settings.json.notchman-backup`.

### Chat tabs

The real chatgpt.com, claude.ai and muse.ai, embedded in the notch with a toggle. Sign in once with your own accounts
(you stay signed in); no API keys, and usage is exactly the same as using the websites — nothing is sent unless
you send it. Links to other sites open in your browser. Use the pin button to keep the notch open while reading,
or Pop out to move the chat (conversation and all) into a normal resizable window for more room — handy for
file previews, especially on non-Retina monitors. Closing the window puts it back in the notch.

**Chats list:** the notch is too narrow for the sites' own sidebars, so the **Chats** button in the toolbar lists
your conversations from all three in one place instead — grouped by Today, Yesterday, Previous 7 Days and so on,
with each one's project and when it last changed. Type to search, filter to one service (All · ChatGPT · Claude ·
Muse), and click (or ↑/↓ and Return) to open it in its tab; Esc goes back. Hover a chat to pin it to the top;
right-click to open it in your browser, copy its link or remove it from the list. The list is read from your
signed-in accounts — ChatGPT's and Claude's own chat lists (titles and times only, never messages) plus the chats
linked in their sidebars, through a hidden copy of the site — and chats you open in the notch are added as you go
(Muse has no such list, so its come from its sidebar links and the chats you open). A chat that's writing a reply shows a spinner. Opening the list re-reads the newest
100 chats of each, at most every couple of minutes. **Sync** reads everything: every page of each site's list,
every ChatGPT project's chats, and (for Muse) the sidebar scrolled to its end — then removes chats you deleted on
the site (pinned ones stay). It takes longer, and if any part fails to load nothing is removed. Sync follows the
filter, so pick one service to sync just that one.

When a reply that took 3+ seconds finishes while you're not looking at that chat, the notch pulses and shows a
✓ until you open it, and a macOS notification is posted (click it to jump back; turn off in Settings → Chat).
Detection follows the reply's network stream, which ends exactly when the reply does (even while the notch is
closed), backed up by the site's Stop button and its "thinking" marker; a pause between a reply's steps
(searching, thinking) doesn't count as done. Pressing Stop or switching chats mid-reply doesn't notify. It only
notes when streams open and close — what they carry is discarded unread, and it never reads the conversation.
Console.app shows each decision (subsystem `com.notchman`, "Reply …") if one looks wrong.

### Ask from anywhere

Right-click an event, task, job, song, playlist or the playing track and choose **Ask ChatGPT / Claude / Muse**,
then a project (or the default, or none). A new chat opens in the notch with a prompt about that item typed in —
not sent. In Settings → Chat set the prompt wording (`{item}` = the item's details), each service's projects and
default project; **Load from ChatGPT/Claude** reads project names and links from the signed-in sidebar.
Apps opt in with `.askable { "description" }` or `AskMenuItems` inside an existing context menu.

## Shelf

Drag files from anywhere (Finder, a browser, Mail) toward the notch and it opens on the Shelf.

- **Keep on the shelf:** drop them in the big area to hold them for later. You can drag them back out anywhere,
  double-click to open, or right-click to AirDrop, reveal or remove. The chip shows how many are waiting.
- **Drop into any folder:** the right side lists where files can go:
  - **Recent:** the last 8 folders you dropped into
  - **Claude Code projects:** your running sessions' folders
  - **Places:** Home, Desktop, Documents and Downloads, plus **Choose Folder…** to start anywhere

  Drop on one to put files straight in, click it to browse it, or hold the drag over it to open it.

  While browsing:
  - Go **up** past where you started, or click the path to jump to any enclosing folder.
  - **Filter** the folder by name.
  - Files show greyed out so you can see where you are. You can drag them out or double-click to open them.
  - Drop anywhere in the browser to put files in the folder you have open, or onto a folder row to put them there. Hold a drag over a folder to go deeper.
  - Inside a project, build and dependency folders are hidden.
  - The **Copy / Move** switch sets what a drop does (hold ⌥ while dropping for the other one). If a name
    already exists you choose Keep Both (`name 2.ext`), Replace (the old file goes to the Trash) or Skip.
  - The folder button makes a **new folder** where you are and opens it. With Move selected, you can drag one
    folder onto another to reorganize.

  After a drop:
  - **Inside a Claude Code project,** the `@path/to/file` reference is on the clipboard, ready to paste into
    the session. If that agent's terminal is open in the notch, **Insert in Session** types it there for you.
  - **Elsewhere,** the bar says where the files went, with **Reveal**.
  - Shelved files can be sent too: right-click → **Copy To**, which lists recent folders and projects.
- **Downloads:** recent files in ~/Downloads, with progress while Safari, Chrome or Firefox downloads, and a
  ✓ in the notch when one finishes.
- **Long commands:** install `notchman-run` in Settings → Shelf, then run `notchman-run make release`. It
  shows in the notch while running, pings when it ends, and also notifies you if it took more than 10 seconds.

## Now Playing

Controls Spotify via AppleScript. The first time, macOS asks to let NotchMan control Spotify — allow it
(or enable it in System Settings → Privacy & Security → Automation).

**Playlists tab** (needs Spotify Premium — Spotify's rule for developer apps since Feb 2026): at
developer.spotify.com/dashboard create an app, add the redirect URI `http://127.0.0.1:43821/callback`, tick
*Web API*, and paste the Client ID in Settings → Now Playing (no secret needed). Browse your playlists, click a
song to play it within its playlist, or press Play to start a playlist. Spotify only returns the songs of
playlists you own or collaborate on; others can still be played from the top. Liked Songs can't be listed.

## Clock

The time here and in other cities, plus timers and a stopwatch.

- **World clocks:** add cities in Settings → Clock (search by city or time zone). Each shows its offset from you
  ("+5h", "−3h 30m") and whether it's already tomorrow or still yesterday there.
- **Timers:** type a length (and optionally a label) to start one, then pause, restart or add a minute while it
  runs. Several can run at once. When one ends NotchMan chimes and posts a notification with **Restart**;
  **Silence** stops the alarm.
- **Stopwatch:** start, stop and reset. Running timers and the stopwatch show as chips while the notch is closed.

## Privacy and data

NotchMan runs entirely on your Mac and has no server of its own.

- **Secrets stay in the Keychain.** OAuth tokens (Google, Spotify), the Notion secret and the JobManager password
  are stored in the macOS Keychain, not in plain files.
- **It talks only to the services you connect:** Google Calendar, Notion, Spotify and your JobManager server.
  The Chat tabs are the real websites, signed in with your own accounts; nothing is sent unless you send it, and
  reply detection only notes when the reply's stream opens and closes, and the site's Stop button. The Chats list keeps your conversations' titles,
  links, projects and times in NotchMan's preferences on this Mac — never their messages.
- **Claude Code integration is local.** Sessions are read from `claude agents --json`. The optional approval hook
  is an HTTP hook to `127.0.0.1` carrying a secret token, and `~/.claude/settings.json` is backed up before it's
  changed.
- **Logs** go to the unified log under the `com.notchman` subsystem (filter for it in Console.app).

## Development

```sh
make build    # swift build
make run      # debug build, bundle, sign, relaunch NotchMan (works from a shell inside NotchMan too)
make release  # release build into build/NotchMan.app
make zip      # universal, ad-hoc-signed build/NotchMan-v<version>.zip for a release
make clean    # remove .build and build
swift test    # unit tests
```

Open `Package.swift` in Xcode to edit and debug. The only dependency is
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), for the in-notch terminals.

### Layout

| Path | What |
| --- | --- |
| `Sources/NotchKit` | SDK every notch app imports: `NotchApp`, `NotchActivity`, `NotchContext`, `Keychain` |
| `Sources/NotchEngine` | Host: notch window, geometry, hover, dock, settings window, hotkey, HUDs |
| `Sources/Apps/*` | Notch apps (Today, Calendar, Tasks, Jobs, Chat/Agents, Now Playing, Shelf, Clock) |
| `Sources/NotchMan` | App shell; `AppRegistry.swift` lists the enabled apps in dock order |
| `Support/Info.plist` | App bundle metadata, including the version |
| `scripts/` | `bundle.sh` (build, bundle, sign), `package.sh` (release zip) and `relaunch.sh` |
| `Tests/` | Swift Testing suites, one per module |

### Writing a notch app

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

## Versions and releases

NotchMan follows [semantic versioning](https://semver.org). Each version is an annotated git tag (`v1.0.0`,
`v0.9.0`, …) with a matching GitHub release; what changed in each is in [CHANGELOG.md](CHANGELOG.md). The app's
own version is `CFBundleShortVersionString` in `Support/Info.plist`.

```sh
git tag -l 'v*' -n1      # list versions with their one-line summary
git checkout v0.5.0      # build an older version
```

To cut a release:

1. Add a section to `CHANGELOG.md`, bump the version in `Support/Info.plist`, and commit.
2. Tag and push: `git tag -a vX.Y.Z -m "NotchMan X.Y.Z — summary"` and `git push origin main vX.Y.Z`.
3. `make zip` builds a universal, ad-hoc-signed `build/NotchMan-vX.Y.Z.zip`.
4. `gh release create vX.Y.Z build/NotchMan-vX.Y.Z.zip --title "NotchMan vX.Y.Z — summary" --notes "…"`,
   with that version's changelog section as the notes.

## License

NotchMan is released under the [MIT License](LICENSE).

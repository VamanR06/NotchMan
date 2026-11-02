# NotchMan

A macOS app that lives in the MacBook notch and hosts pluggable "notch apps" (Today, Calendar, Tasks, Jobs, Agents, Now Playing, Clock) switchable from a dock.
Hover the notch to expand it; move away to collapse. Apps can show a compact live indicator beside the
notch while it's collapsed (e.g. the next meeting, or what's playing).

The dock shows as many apps as fit left of the notch; when there are more, its last button (▦ All Apps)
opens a grid of every app with its ⌘-number. The app you're in always keeps a place in the dock.

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
| `Sources/Apps/*` | Notch apps (Today, Calendar, Tasks, Jobs, Agents, Now Playing, Shelf, Clock) |
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

When a reply that took 3+ seconds finishes while you're not looking at that chat, the notch pulses and shows a
✓ until you open it, and a macOS notification is posted (click it to jump back; turn off in Settings → Chat).
Detection watches only for the site's Stop button — it never reads the conversation.

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

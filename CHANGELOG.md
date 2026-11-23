# Changelog

All notable changes to NotchMan. Versions follow [semantic versioning](https://semver.org), and each one is an
annotated git tag (`git checkout v0.5.0`). Versions before 1.0.0 were tagged after the fact at the commit that
finished each milestone; their `Info.plist` still says 0.1.0.

## [Unreleased]

## [1.2.0] — 2026-11-22

### Added
- **Agents — Session view:** a background agent's session drawn natively, half terminal and half chat:
  Markdown replies, grouped tool steps, the reply as Claude writes it, and the terminal a tab away.
  - Everything Claude Code asks or opens shows as a card you can click or drive from the keyboard: folder trust,
    questions, permissions, plans, rewind, and its menus (`/model`, `/config`, `/permissions`, `/mcp`, `/memory`,
    `/hooks`, `/status`, `/usage`, `/effort`, `/theme`, `/export`, `/resume`, background tasks).
  - Message box: `/` command and `@` file autocomplete, ↑/↓ prompt history, paste or drop images, Shift-Tab
    and a chip for the permission mode, Stop/Esc (an unanswered prompt comes back to the box), Esc Esc to rewind.
  - A prompt rail to jump through your prompts, a pinned plan from Claude's to-do list, quick commands saved per
    project (`make run` in one click), ⌘-click a command in a reply to run it, recaps above your next prompt,
    and Claude Code's notices folded into one line.
- **Agents:** stuck-agent alerts from plain rules (a call failing or looping, a hung command, no progress), with
  a one-line reason from Haiku; "What does this do?" on approval cards; approvals with Always, and
  notifications you can answer from.
- **Command bar (⌥Space):** find anything or say what to do; Ask Claude and Ask ChatGPT answer right in the bar
  (ChatGPT through the Codex CLI), or start a Claude Code agent.
- **Notch apps you make:** Claude writes small apps that run in the notch.
- **Claude Code bridge mod:** shows what each session is doing.
- **Shelf:** suggested drop folders, find and expiry, Quick Look previews and thumbnails.
- **Intelligence:** Jev (TypeSafe) for command routing, with an on-device redactor.

### Changed
- Hovering opens the notch ready to type; typing keeps it open; leaving gives the keyboard back.
- The notch opens to an app only when something needs you (an approval, a meeting, a stuck agent).
- Shelf ranks folders by your own history first; Jev only nudges, for file types you've never filed.
- Quieter notch: a single ⋯ menu in the top bar, no empty summaries, lighter Shelf rows.

### Fixed
- **Agents:** clicks in an open session no longer get lost or fall through to the app behind; no freeze while
  Claude writes; Enter in the message box submits; "Working…" clears when the turn ends.

## [1.1.0] — 2026-11-06

### Added
- MIT license.
- Downloadable app: every release, including the earlier ones, now has a universal `NotchMan-vX.Y.Z.zip`, and
  `make zip` builds one.
- **Agents:** a Chats list — your ChatGPT, Claude and Muse conversations in one searchable list by date, with
  pins, so you can open any of them in the notch without the site's sidebar. Sync reads every chat (all pages
  and ChatGPT projects) and removes ones deleted on the site.

### Changed
- **Jobs:** with no server set, the default is `http://localhost:3000` (a local JobManager).

### Fixed
- **Agents:** "writing" / "replied" for ChatGPT, Claude and Muse is more accurate: it follows the reply's
  network stream, counts reasoning models' thinking, ignores other Stop buttons (dictation, voice), doesn't end
  between a reply's steps, and doesn't notify when you stop a reply.
- **Agents:** switching chats mid-reply no longer loses the "replied" notification: NotchMan keeps following
  that chat (in a hidden page if needed) and the notification opens it.

## [1.0.0] — 2026-11-04

First public release.

### Added
- **Agents:** a terminal of your own in the notch (Terminal pill or ⌘T), with tabs per folder that follow `cd`,
  Open in VS Code/Cursor, and Open Terminal Here on folders and sessions.
- **Agents:** a progress pill for `git clone` in any notch terminal, then Open in VS Code or `cd` into the clone.
- **Agents:** New Agent Here… on a project folder's or session's right-click menu, with the project already picked.
- **Dock:** shows as many apps as fit left of the notch; the rest are under ▦ All Apps, a grid with ⌘-numbers.
  The current app always keeps a place.
- Detailed README, this changelog, and version tags.

## [0.8.0] — 2026-11-02

### Added
- **Clock:** world clocks, timers with notifications, and a stopwatch, with chips while the notch is closed.
- **Jobs:** pick the resume and cover letter for the job in the browser, linked back to JobManager.
- **Jobs:** mark a job Applied automatically when the site confirms you submitted, with Undo.
- **Jobs:** Autofill adds Work Experience entries, one per Profile job the resume mentions, in its order.
- **Agents:** pick New Agent's mode (Plan, Ask first, Accept edits, Auto) and start it with Return.
- **Agents:** sessions listed by project in foldable folders, folders of your own, and moving sessions between them.
- **Agents:** ⌘-click a file path in a terminal to preview it in a popup.

### Changed
- Settings, file pickers and alerts open in front of the notch.
- Worktree sessions are listed as their repo.

## [0.7.0] — 2026-10-27

### Added
- **Tasks:** select several tasks (⌘/⇧-click, Select per section, ⌘A) and reschedule them at once.
- **Tasks & Calendar:** edit titles, dates and times (and event location and notes) in place.
- **Shelf:** drop into any folder — recents, Claude Code projects and places — and browse the whole file tree,
  with Copy/Move and conflict handling.

### Fixed
- Calendar keeps the last good events when a refresh fails.
- Shelf accepts drags from any app, not just Finder.

## [0.6.0] — 2026-10-25

### Added
- **Jobs:** on a tracked job's page, a This page card to drag its resume and cover letter, and rules-based
  Autofill of the application form (never submits).
- **Jobs:** following, remembering and linking pages that aren't the exact saved link.

### Fixed
- Autofill no longer hangs on big forms; it has a time limit and a Stop button.
- `make run` restarts NotchMan reliably, even from a shell inside NotchMan.

## [0.5.0] — 2026-10-23

### Added
- **Today:** the day at a glance in two columns, with natural-language quick add that creates Notion tasks or
  Google Calendar events.
- **Keyboard:** a global hotkey (⌥Space), ⌘1–9 to switch apps, and arrow/Return/Space control in lists.
- **Agents:** allow or deny Claude Code tool permissions from the notch via an approval hook.
- **Shelf:** hold files, drop them into Claude Code projects, watch downloads and long commands (`notchman-run`).
- **System HUDs:** volume, brightness, battery and headphones in the notch.
- **Calendar:** meeting heads-up with countdown and Join; double-booking warnings.
- **Jobs:** change an application's status from the notch, and add the job open in your browser.
- **NotchKit:** shared board, transient status, background messages and list keyboard selection for apps.

### Fixed
- Launch crash when Bluetooth headphones are connected.

## [0.4.0] — 2026-10-23

### Added
- **Agents:** Claude Code usage card with a breakdown and Claude's own plan limits.
- **Chat:** copy-link and add-project buttons.

### Fixed
- Password AutoFill and other page pop-ups can take the keyboard from the notch, and close when you click back.

## [0.3.0] — 2026-10-21

### Added
- **Agents:** Claude Code session monitor combined with the chats, and an interactive terminal in the notch for
  background agents, with split shells; stop, delete and search sessions.
- **Tasks & Calendar:** reschedule from the notch.
- **Calendar:** clearer day sections; today's finished events fold away.
- **Chat:** opens threads at the newest message and remembers where you were.
- **Agents:** load and rename ChatGPT/Claude projects.

### Changed
- Wait a little longer before opening the notch on hover.

## [0.2.0] — 2026-10-20

### Added
- **Jobs:** applications from a JobManager server, with stage filter, search and ChatGPT prompt presets.
- **Chat:** ChatGPT, Claude and Muse embedded in the notch, with reply notifications and pop-out windows.
- **Ask from anywhere:** right-click an event, task, job or song to ask a chat about it.
- **Now Playing:** browse Spotify playlists and play songs.
- Several notch activities at once, as self-contained chips.

## [0.1.0] — 2026-10-20

### Added
- The notch engine: notch window and shape, hover to expand and collapse, the dock, and Settings.
- The NotchKit SDK, with OAuth loopback/PKCE helpers and Keychain storage.
- **Calendar:** Google Calendar events with Join links.
- **Now Playing:** Spotify controls.
- **Tasks:** Notion task boards.
- A notch on every display.

[Unreleased]: https://github.com/VamanR06/NotchMan/compare/v1.1.0...main
[1.1.0]: https://github.com/VamanR06/NotchMan/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/VamanR06/NotchMan/compare/v0.8.0...v1.0.0
[0.8.0]: https://github.com/VamanR06/NotchMan/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/VamanR06/NotchMan/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/VamanR06/NotchMan/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/VamanR06/NotchMan/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/VamanR06/NotchMan/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/VamanR06/NotchMan/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/VamanR06/NotchMan/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/VamanR06/NotchMan/releases/tag/v0.1.0

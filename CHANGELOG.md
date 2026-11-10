# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A simple setup window: `Install.cmd` now opens it (welcome with "start with Windows" and
  "open when done" options, progress, done), in English or Turkish. It also updates an existing
  install. `install.ps1` remains for console and scripted installs.

### Changed

### Deprecated

### Removed

### Fixed

- The widget and its settings window no longer appear in Alt+Tab (they are now tool windows).

### Security

## [1.0.0] - 2026-11-10

First public release.

### Added

- Desktop widget for Windows 10/11 (Windows PowerShell 5.1 + WPF, no dependencies) that shows the
  Claude sessions running right now.
- Session discovery for the Claude desktop app — local, WSL and SSH sessions — and for Claude Code CLI
  terminal sessions.
- Per-session current step, task-list progress bar (from `update_plan` / `TodoWrite`) and latest tool
  call.
- Round ✻ icon that opens the session card; spins while anything is running and shows a badge with the
  number of running sessions.
- Accordion rows: click a session title to show its location, step list and latest tool call.
- Finished alert: the icon blinks green and a Windows notification appears when a session finishes.
- System tray icon; the widget keeps running when hidden.
- Settings window: start with Windows, always on top, on-start view, language, transparency,
  notifications, blinking, terminal sessions, refresh interval and how long finished sessions stay
  listed.
- English and Turkish UI, following the Windows display language automatically.
- Transparency setting (100–60 %), fully opaque while the mouse is over the widget.
- One-click installer and uninstaller (`Install.cmd` / `Uninstall.cmd`) and a one-line installer
  (`get.ps1`); no administrator rights needed.
- Start menu shortcuts and an entry in Settings → Apps → Installed apps.
- "Running" detection from each live `claude` process's own `busy` / `idle` status record (local and
  inside WSL), with stale records of exited processes ignored; falls back to the desktop app's turn
  timestamps for SSH sessions.
- Demo mode (`-Demo`, `-DemoView`) with fake sessions, `-Screenshot` to render a view off-screen to a
  transparent PNG (used for the README screenshots), and `-Test` to print the sessions found.
- Modular source layout (`src/lib`, `src/lang`) with Pester tests.
- CI on Windows PowerShell 5.1 (script checks, PSScriptAnalyzer, Pester, smoke test) and a release
  workflow that publishes a zip on version tags.

[Unreleased]: https://github.com/hasanuzn/claude-session-widget/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/hasanuzn/claude-session-widget/releases/tag/v1.0.0

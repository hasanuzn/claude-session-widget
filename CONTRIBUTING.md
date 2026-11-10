# Contributing to Claude Session Widget

Thanks for taking the time to help! This is a small, dependency-free Windows widget written in
Windows PowerShell 5.1 + WPF. Bug reports, fixes, translations and ideas are all welcome.

> Claude Session Widget is a community project. It is not made by, or affiliated with, Anthropic.

- [Ground rules](#ground-rules)
- [Prerequisites](#prerequisites)
- [Run from source](#run-from-source)
- [Project layout](#project-layout)
- [How it works](#how-it-works)
- [Coding conventions](#coding-conventions)
- [Adding a language](#adding-a-language)
- [Testing](#testing)
- [Pull requests](#pull-requests)
- [When the Claude app changes its file formats](#when-the-claude-app-changes-its-file-formats)
- [Making a release](#making-a-release)
- [Türkçe özet](#türkçe-özet)

## Ground rules

- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).
- The widget **only reads local files** and **never uses the network**. Changes that write to Claude's
  files, call an API or send telemetry will not be accepted.
- No external dependencies at runtime: it must keep working on a fresh Windows 10/11 install.
- Security issues: please don't open a public issue — see [SECURITY.md](SECURITY.md).

## Prerequisites

- **Windows 10 or 11.**
- **Windows PowerShell 5.1** (`powershell.exe`, built into Windows). The widget targets 5.1 only.
  PowerShell 7 (`pwsh`) is *not* supported — code that works there may not parse or behave the same
  in 5.1, so always test with `powershell.exe`.
- **[Pester 5](https://pester.dev)** for the unit tests. Windows ships with Pester 3.4, which is too old:

  ```powershell
  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
  ```

- **[PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)** (optional, CI runs it):

  ```powershell
  Install-Module PSScriptAnalyzer -Scope CurrentUser
  ```

- The Claude desktop app and/or the Claude Code CLI if you want to see real sessions. `-Demo` works
  without either.

## Run from source

You don't need to install anything. From the repository root:

```powershell
# Run the widget (WPF needs -STA)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1

# Print the sessions it finds to the console and exit
powershell -NoProfile -ExecutionPolicy Bypass -File src\claude-session-widget.ps1 -Test

# Show fake sessions (for screenshots and UI work)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1 -Demo

# Open the demo straight into one view: icon, card or settings
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1 -Demo -DemoView card

# Open the settings window
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1 -OpenSettings

# Regenerate a README screenshot (rendered off-screen, transparent PNG, then exits)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1 -Demo -DemoView card -Language en -Screenshot docs\screenshots\card.png
```

The README screenshots in `docs/screenshots/` are made this way (`card`, `icon`, `settings` in
English, `card-tr` in Turkish), so please regenerate them when a UI change affects them.

If an installed copy is running, quit it from the tray icon first so you don't confuse the two.
Errors are written to `%TEMP%\claude-session-widget.log`.

## Project layout

| Path | What it is |
|---|---|
| `src/claude-session-widget.ps1` | Entry point. Switches: `-Test`, `-Demo`, `-DemoView icon\|card\|settings`, `-Language`, `-Screenshot`, `-OpenSettings`. Holds `$AppVersion`. |
| `src/lib/Scanner.ps1` | Session discovery and transcript parsing (`ConvertFrom-TranscriptLines`, `Get-ClaudeSession`). Pure functions, unit-tested. |
| `src/lib/I18n.ps1` | Language resolution and the `T 'Key'` lookup. |
| `src/lib/Settings.ps1` | Loads/saves `%APPDATA%\ClaudeSessionWidget\settings.json`; start-with-Windows shortcut. |
| `src/lib/Theme.ps1` | Colors and shared XAML styles. |
| `src/lib/MainWindow.ps1` | Icon/card window, session rows, tray icon, timers. |
| `src/lib/SettingsWindow.ps1` | Settings window. |
| `src/lang/en.psd1`, `src/lang/tr.psd1` | UI strings, one file per language. |
| `tests/*.Tests.ps1`, `tests/fixtures/` | Pester 5 tests and sample transcripts / session records. |
| `tools/Test-Scripts.ps1` | Parse check plus encoding rules (BOM, CRLF, ASCII-only files). |
| `tools/Build-Release.ps1` | Builds `dist/claude-session-widget-<version>.zip`. |
| `.github/workflows/ci.yml` | CI on `windows-latest` with Windows PowerShell 5.1: Test-Scripts, PSScriptAnalyzer, Pester, `-Test` smoke run. |
| `.github/workflows/release.yml` | On a `vX.Y.Z` tag: builds the zip and publishes a GitHub Release. |
| `install.ps1`, `uninstall.ps1`, `Install.cmd`, `Uninstall.cmd` | Per-user installer/uninstaller (no admin). Installs to `%LOCALAPPDATA%\ClaudeSessionWidget`, adds Start menu shortcuts and an *Installed apps* entry. |
| `get.ps1` | One-line installer (`irm … \| iex`). ASCII only. |

## How it works

Every refresh interval a background runspace runs the scanner, and the UI thread renders the result.
The scanner only **reads** files; it never writes to them and never opens a network connection.

### Data sources

| Source | Location | Used for |
|---|---|---|
| Desktop app session records | `%LOCALAPPDATA%\Claude-Data\…\claude-code-sessions\…\*.json` | Which desktop-app sessions (local, WSL, SSH) are running; title, `cwd`, WSL distro / remote transcript path |
| Local transcripts (JSONL) | `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` (or `%CLAUDE_CONFIG_DIR%`) | Task list and latest tool call |
| WSL transcripts | Inside the distro, read with `wsl.exe -d <distro> -e sh` (`grep`/`tail`) | Same, for WSL sessions |
| Process status records | `~/.claude/sessions/<pid>.json` (and inside each WSL distro) | Whether a session is working right now (`status: busy`, process alive); terminal sessions started with `claude` |

These are **undocumented internal formats** of the Claude app and CLI. They can change in any release
and that is the main maintenance risk of this project — see
[When the Claude app changes its file formats](#when-the-claude-app-changes-its-file-formats).

### The "running" heuristic

Every running `claude` process keeps a status record in `~/.claude/sessions/<pid>.json` with
`status: "busy"` or `"idle"` (inside WSL, the distro's own `~/.claude/sessions`, read with one
`wsl.exe` call per distro). The scanner only trusts records whose process is **still alive** — a
crashed process can leave a stale `busy` behind — and a session counts as running when its live
record says `busy`. This also catches turns that were started by a background event rather than by
the user.

When there is no live record (SSH sessions, or a format change), the scanner falls back to the
desktop-app session record: running when `latestUserFrameAt >= lastTurnEdgeAt` and there was
activity in the last 2 hours. Archived sessions are skipped, and CLI records that belong to a
desktop-app session are de-duplicated.

When a session disappears from the running list, the widget treats it as finished: it blinks green,
optionally shows a Windows notification, and keeps it listed for the *Keep finished* period.

### Plan replay

Progress comes from replaying the task-list tool calls in the transcript, in order. Only the last
few dozen matching lines plus the tail of the file are read, so large transcripts stay cheap.

- **`update_plan`** (any tool name ending in `update_plan`):
  - `items` — replaces the whole list (`content`, `status`; a missing status means `pending`).
  - `advance: true` — the `in_progress` step becomes `completed` and the next `pending` step becomes
    `in_progress`.
  - `done: [n, …]` — marks those 1-based steps `completed`.
  - `start: n` — marks the 1-based step `in_progress`.
- **`TodoWrite`** — replaces the whole list from `todos`; the `in_progress` item shows its `activeForm`.
- **`wrap_up`** (any tool name ending in `wrap_up`) — marks every step `completed` and shows
  "finishing".
- Any other `tool_use` becomes the *latest activity* line (`tool · description/file_path/pattern/…`).

Sessions without a task list show no progress bar, only the latest activity.

## Coding conventions

### Windows PowerShell 5.1 only

- No PowerShell 7 syntax: no `??`, `??=`, `?:` (ternary), `?.`, `&&` / `||` pipeline chains,
  no `ForEach-Object -Parallel`, no `-AsHashtable`. Use `if/else` and explicit `$null -eq $x` checks.
- Use [approved verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)
  for functions (`Get-`, `ConvertFrom-`, `Read-`, …). PSScriptAnalyzer in CI will flag others.
- Keep it dependency-free: only what ships with Windows (PowerShell 5.1, .NET Framework, WPF).

### File encoding

`tools\Test-Scripts.ps1` enforces these, and `.gitattributes` stores the scripts byte-for-byte
(`-text`) so ZIP downloads and raw GitHub URLs work unchanged:

| Files | Encoding | Line endings |
|---|---|---|
| `*.ps1`, `*.psd1` | UTF-8 **with BOM** (5.1 reads BOM-less files as ANSI and breaks `✻`, `ü`, …) | CRLF |
| `get.ps1`, `*.cmd` | **ASCII only** (`get.ps1` runs through `irm \| iex`) | CRLF |
| `*.md` | UTF-8 without BOM | LF |

Configure your editor accordingly (in VS Code: *UTF-8 with BOM* and *CRLF* for PowerShell files).
Git will not convert these files for you.

### Gotchas

- **Aliases shadow functions.** A function called `gl`, `gc`, `ls`, `sort`, `where`, … will lose to the
  built-in alias. Use full Verb-Noun names.
- **Automatic variables.** Don't use `$input`, `$this`, `$args`, `$_`, `$matches`, `$error`, `$host`,
  `$home`, `$pid` as your own variable or parameter names.
- **Variable names are case-insensitive.** `$Item` and `$item` are the same variable — easy to clobber
  in nested loops.
- **`Scanner.ps1` must have no top-level side effects.** It is dot-sourced into the background runspace
  and into the tests, so it may only define functions (and constants). No UI, no file writes, no
  `Add-Type` of WPF, no code that runs on load.
- **Read-only, offline.** Never write to Claude's files, never open a network connection.
- **WPF runs on the STA UI thread.** Do slow work (file scanning, `wsl.exe`) in the background runspace,
  not in a timer handler on the UI thread.
- User-visible text goes through `T 'Key'` — never hard-code English or Turkish strings in the UI.

## Adding a language

1. Copy `src/lang/en.psd1` to `src/lang/<code>.psd1`, where `<code>` is the two-letter ISO code
   (for example `de.psd1`). Save it as UTF-8 with BOM, CRLF.
2. Translate every value. Keep the keys and any `{0}` placeholders exactly as they are.
3. Set `_Name` to the language's own name (`Deutsch`, `Español`, …). It appears in the Language
   setting.
4. Run `Invoke-Pester tests`. The language tests check that every language file has exactly the same
   keys as `en.psd1`.
5. Run the widget with `-Demo`, pick your language in Settings, and check that nothing is cut off.
   Add a screenshot to the PR.

With *Auto*, the widget uses the Windows display language if a matching file exists, otherwise English.
Not able to do a full translation? Open a [translation issue](https://github.com/hasanuzn/claude-session-widget/issues/new/choose) — partial help
and reviews are welcome.

## Testing

```powershell
# Parse + encoding checks
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-Scripts.ps1

# Unit tests (Pester 5)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests -Output Detailed"

# Static analysis (optional, CI runs it)
powershell -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse"

# Smoke run against your real sessions
powershell -NoProfile -ExecutionPolicy Bypass -File src\claude-session-widget.ps1 -Test
```

Parser changes need a test in `tests/` with a fixture in `tests/fixtures/`.

### Manual checklist (UI changes)

- [ ] Icon ↔ card: clicking the ✻ icon opens the card; collapsing returns to the icon; dragging works
      and the position is remembered.
- [ ] Accordion: clicking a session title expands/collapses its location, steps and latest tool call.
- [ ] Finish: when a session finishes, the icon blinks green and a Windows notification appears
      (and neither happens when turned off).
- [ ] Settings: each option applies — start with Windows, always on top, on-start view, language,
      transparency (opaque on hover), notifications, blinking, terminal sessions, refresh interval,
      keep finished.
- [ ] Language switch restarts the widget in the new language.
- [ ] Tray icon: hide/show, *Settings…*, quit.
- [ ] `Install.cmd` and `Uninstall.cmd` (and `-KeepSettings`) still work: Start menu shortcuts,
      *Installed apps* entry, startup shortcut.
- [ ] Tested with Windows display scaling other than 100% if you touched layout.

## Pull requests

- Keep PRs **small and focused** — one fix or feature per PR. For bigger changes, open an issue first
  so we can agree on the approach.
- Fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md).
- Make sure `tools\Test-Scripts.ps1` and Pester pass locally. CI runs the same checks.
- Add an entry under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- **UI changes need screenshots taken with `-Demo`**, so no real project or session names leak.
  Likewise, scrub paths, project names and prompts from fixtures and logs before committing them.
- Write commit messages in English, in the imperative ("Add German translation").

## When the Claude app changes its file formats

If the widget suddenly shows nothing, shows sessions that aren't running, or loses progress bars after
a Claude app or CLI update, the internal file format probably changed. To investigate:

1. Run `src\claude-session-widget.ps1 -Test` and check `%TEMP%\claude-session-widget.log`.
2. Look at the raw files:
   - session records: `%LOCALAPPDATA%\Claude-Data\` → `claude-code-sessions` folders → `*.json`
     (check `cliSessionId`, `title`, `cwd`, `wslConfig`, `sshRemoteTranscriptPath`, `isArchived`,
     and for the fallback `latestUserFrameAt`, `lastTurnEdgeAt`, `lastActivityAt`);
   - transcripts: `%USERPROFILE%\.claude\projects\<cwd-slug>\<session-id>.jsonl`
     (look for `"tool_use"` lines with `update_plan`, `TodoWrite`, `wrap_up`);
   - process status records: `%USERPROFILE%\.claude\sessions\<pid>.json` (`pid`, `status`,
     `statusUpdatedAt`, `sessionId`, `cwd`, `entrypoint`, `name`).
3. Compare with what `Scanner.ps1` expects and adapt it. Prefer accepting **both** the old and the new
   format, since users update at different times.
4. Add a small, anonymized fixture of the new format to `tests/fixtures/` and a test that covers it.
5. Mention the Claude app / CLI version in the PR and the CHANGELOG.

## Making a release

Maintainers only.

1. Bump `$AppVersion` in `src/claude-session-widget.ps1` ([SemVer](https://semver.org)).
2. In `CHANGELOG.md`, move the `[Unreleased]` entries under a new `[X.Y.Z] - YYYY-MM-DD` heading and
   update the link references at the bottom.
3. Commit, then tag and push:

   ```powershell
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

4. The release workflow runs `tools\Build-Release.ps1` and publishes a GitHub Release with
   `claude-session-widget-X.Y.Z.zip`. Check the release notes and the zip.

You can build the zip locally with `tools\Build-Release.ps1` (output in `dist/`).

## Türkçe özet

Katkılarınız memnuniyetle karşılanır. Kısaca:

- **Gereksinimler:** Windows 10/11, **Windows PowerShell 5.1** (`pwsh` 7 desteklenmez), testler için
  Pester 5, isteğe bağlı PSScriptAnalyzer.
- **Kurmadan çalıştırma:**
  `powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\claude-session-widget.ps1`
  (`-Test` bulunan oturumları yazdırır, `-Demo` sahte oturumlar gösterir).
- **Kurallar:** yalnızca PS 5.1 sözdizimi (`??`, `?:`, `?.`, `&&`, `||` yok); `.ps1`/`.psd1` dosyaları
  BOM'lu UTF-8 + CRLF, `get.ps1` ve `.cmd` dosyaları yalnızca ASCII + CRLF; widget yalnızca yerel
  dosyaları okur, ağa çıkmaz; `Scanner.ps1` yüklenirken hiçbir yan etki üretmemelidir.
- **Yeni dil:** `src/lang/en.psd1` dosyasını `xx.psd1` olarak kopyalayın, çevirin, `_Name` değerine
  dilin kendi adını yazın; testler anahtarların eksiksiz olduğunu denetler.
- **Test:** `tools\Test-Scripts.ps1` ve `Invoke-Pester tests`; arayüz değişikliklerinde yukarıdaki
  elle denetim listesini uygulayın.
- **PR:** küçük ve tek konulu olsun, şablonu doldurun, ekran görüntülerini `-Demo` ile alın (gerçek
  proje/oturum adları görünmesin), `CHANGELOG.md` dosyasını güncelleyin.
- Güvenlik açıklarını herkese açık issue yerine [SECURITY.md](SECURITY.md) üzerinden bildirin.

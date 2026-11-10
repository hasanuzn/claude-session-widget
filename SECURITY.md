# Security Policy

## Supported versions

Only the **latest release** receives fixes. Please update before reporting a problem.

| Version | Supported |
|---|---|
| Latest release (1.x) | Yes |
| Older releases | No |

## What the widget accesses

Claude Session Widget is designed to be read-only and offline:

- **Reads** (never writes) the Claude desktop app's session records under
  `%LOCALAPPDATA%\Claude-Data\…\claude-code-sessions\`, Claude Code transcripts under
  `%USERPROFILE%\.claude\projects\` (or `%CLAUDE_CONFIG_DIR%`), and the CLI session registry under
  `%USERPROFILE%\.claude\sessions\`.
- For WSL sessions, runs `wsl.exe` with `grep`/`tail` to read the transcript inside the distro.
- **Writes** only its own files: settings in `%APPDATA%\ClaudeSessionWidget\settings.json`, a log in
  `%TEMP%\claude-session-widget.log`, and — when installed — files in
  `%LOCALAPPDATA%\ClaudeSessionWidget`, Start menu / startup shortcuts and a per-user
  *Installed apps* registry entry under `HKCU`.
- **Makes no network connections** at runtime. The only download is the one-line installer
  (`get.ps1`), which fetches the repository ZIP from `github.com`.
- Requires no administrator rights and sends no telemetry.

Transcripts can contain sensitive information (prompts, file paths, command lines). The widget only
shows short excerpts on your screen, but please keep that in mind when sharing logs, `-Test` output or
screenshots.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report it privately through GitHub's private vulnerability reporting: go to the repository's
[**Security** tab](https://github.com/hasanuzn/claude-session-widget/security) and choose
**Report a vulnerability**
([direct link](https://github.com/hasanuzn/claude-session-widget/security/advisories/new)).

Please include:

- what the issue is and its impact,
- steps to reproduce (a minimal example is ideal),
- the widget version and Windows version.

This is a volunteer-maintained project. You can expect an initial reply within about a week. Once a
fix is released, the advisory will be published and you will be credited unless you prefer otherwise.

Issues in the Claude app or Claude Code themselves should be reported to Anthropic, not here.

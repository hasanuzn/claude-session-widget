## Summary

<!-- What does this PR change, and why? Link the issue it fixes: "Fixes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Translation (new language or fix)
- [ ] Adapting to a Claude app / CLI file format change
- [ ] Refactoring, tests or tooling
- [ ] Documentation

## Checklist

- [ ] `tools\Test-Scripts.ps1` passes (parse + encoding: `.ps1`/`.psd1` UTF-8 with BOM + CRLF)
- [ ] `Invoke-Pester tests` passes
- [ ] Works in Windows PowerShell 5.1 (no PowerShell 7-only syntax)
- [ ] Tested on Windows version: <!-- e.g. Windows 11 24H2 -->
- [ ] UI changes: screenshots below, taken with `-Demo`
- [ ] `CHANGELOG.md` updated under `[Unreleased]` (for user-visible changes)
- [ ] No private data (real session names, project names, paths, prompts) in screenshots, fixtures or logs
- [ ] Still read-only and offline: no writes to Claude's files, no network access

## Screenshots

<!-- For UI changes: run src\claude-session-widget.ps1 -Demo (or -Demo -DemoView card|settings) -->

## Notes for reviewers

<!-- Anything you're unsure about, or that needs special attention. -->

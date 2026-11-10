@echo off
rem Opens the Claude Session Widget setup window.
rem For a console install (or extra options) run install.ps1 instead.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0installer\Setup.ps1" %*

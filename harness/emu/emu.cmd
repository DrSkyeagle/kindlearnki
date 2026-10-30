@echo off
rem Windows entry point for the emulator harness.  See emu.ps1 / README.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0emu.ps1" %*
exit /b %ERRORLEVEL%

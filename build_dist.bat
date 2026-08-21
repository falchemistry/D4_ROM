@echo off
REM Double-click wrapper for build_dist.ps1 -- refreshes d4_rom_dist (the
REM clean, end-user-facing copy) from the current dev tree. Rerun any time
REM after making changes here. Pauses at the end so the "BUILD SUCCEEDED"/
REM "BUILD FAILED" output stays on screen instead of the window closing
REM instantly.
title Building d4_rom_dist...
echo Running build_dist.ps1 -- this window will show progress in a moment...
powershell -ExecutionPolicy Bypass -File "%~dp0build_dist.ps1"
echo.
echo Done -- press any key to close this window.
pause >nul

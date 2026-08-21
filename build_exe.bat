@echo off
REM Double-click wrapper for build_exe.ps1 -- recompiles ROM_Launcher.exe
REM from exe_src/Program.cs with app_icon.ico embedded. Rerun after any
REM change to Program.cs or the icon. Pauses at the end so the "Built:..."
REM output stays on screen instead of the window closing instantly.
powershell -ExecutionPolicy Bypass -File "%~dp0build_exe.ps1"
pause

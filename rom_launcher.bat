@echo off
REM Single-window replacement for run_front_back.bat / run_left_right.bat /
REM capture_front_back.bat / capture_left_right.bat -- pick an axis and
REM click Preview or Start Recording instead of double-clicking separate
REM files. Also has a Reset button (maya_clean_reset.py).
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\rom_launcher.ps1"

@echo off
REM Opens Front/Back camera panels on the second monitor and applies the
REM natural (edge-guard) horizontal camera tracking, using the cache if it
REM already exists for this animation, or building it first if not
REM (one-time, several minutes).
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\send_to_maya.ps1" -ScriptPath "%~dp0scripts\maya_camera_panels.py"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\send_to_maya.ps1" -ScriptPath "%~dp0scripts\maya_key_from_cache.py"
echo Done. Check the Front/Back panels on your second monitor.
pause

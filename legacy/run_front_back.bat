@echo off
REM Opens Front/Back camera panels on the second monitor and applies the
REM natural (edge-guard) horizontal camera tracking, using the cache if it
REM already exists for this animation, or building it first if not
REM (one-time, several minutes).
powershell -ExecutionPolicy Bypass -File "%~dp0..\scripts\maya\send_to_maya.ps1" -ScriptPath "%~dp0..\scripts\maya\maya_camera_panels.py"
powershell -ExecutionPolicy Bypass -File "%~dp0..\scripts\maya\send_to_maya.ps1" -ScriptPath "%~dp0..\scripts\maya\maya_key_from_cache.py"
echo Done. Check the Front/Back panels on your second monitor.
pause

@echo off
REM Opens Left/Right camera panels on the second monitor and applies the
REM natural (edge-guard) horizontal camera tracking, using the cache if it
REM already exists for this animation, or building it first if not
REM (one-time, several minutes).
powershell -ExecutionPolicy Bypass -File "%~dp0..\scripts\maya\send_to_maya.ps1" -ScriptPath "%~dp0..\scripts\maya\maya_camera_panels_LR.py"
powershell -ExecutionPolicy Bypass -File "%~dp0..\scripts\maya\send_to_maya.ps1" -ScriptPath "%~dp0..\scripts\maya\maya_key_from_cache_LR.py"
echo Done. Check the Left/Right panels on your second monitor.
pause

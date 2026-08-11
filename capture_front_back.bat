@echo off
REM Opens Front/Back panels, applies camera tracking, then runs a fully
REM automated OBS capture: starts recording and Maya playback together,
REM waits for playback to finish, stops recording. No manual steps.
REM
REM The taskbar is hidden FIRST so Maya's panels size to the full monitor
REM height -- Windows caps a new window to the current work area, so panels
REM created while the taskbar is visible end up short and leave a dead strip
REM at the bottom of the recording.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\taskbar_control.ps1" -Action hide
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\send_to_maya.ps1" -ScriptPath "%~dp0scripts\maya_camera_panels.py"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\send_to_maya.ps1" -ScriptPath "%~dp0scripts\maya_key_from_cache.py"
ping -n 3 127.0.0.1 > nul
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\maya_obs_capture.ps1"
REM Always restore the taskbar, even if the capture above failed.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\taskbar_control.ps1" -Action show
echo Done. Check D:\__capture for the recorded video.
pause

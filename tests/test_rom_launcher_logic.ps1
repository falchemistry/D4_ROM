# Persistent, safe test suite for rom_launcher_logic.ps1 -- dot-sources
# ONLY the pure logic functions, never builds a WPF window or launches a
# real process. Run any time via:
#   powershell -ExecutionPolicy Bypass -File tests\test_rom_launcher_logic.ps1
# Exits 0 if all checks pass, 1 otherwise.

. (Join-Path $PSScriptRoot "..\scripts\rom_launcher_logic.ps1")

$ScriptDir = "D:\__backup\claude\d4_rom\scripts"
$failures = @()
$passed = 0

function Check($name, [scriptblock]$body) {
    try {
        & $body
        $script:passed++
    } catch {
        $script:failures += "$name`: $($_.Exception.Message)"
    }
}

function ArgsHave($stepArgs, [string]$substring) {
    # Arguments hold full paths (e.g. "...\maya_camera_panels.py"), not
    # bare filenames -- -contains does exact element matching and would
    # never find a substring, so join then -like instead.
    return (($stepArgs -join " ") -like "*$substring*")
}

Check "run_front_back matches the existing bat file" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $false -ScriptDir $ScriptDir
    if ($steps.Count -ne 2) { throw "expected 2 steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_camera_panels.py")) { throw "step 0 should open front/back panels" }
    if (-not (ArgsHave $steps[1].Arguments "maya_key_from_cache.py")) { throw "step 1 should key from cache (front/back)" }
    foreach ($s in $steps) {
        if ((ArgsHave $s.Arguments "taskbar_control") -or (ArgsHave $s.Arguments "maya_obs_capture")) {
            throw "run-only mode must not touch taskbar or OBS"
        }
    }
}

Check "run_left_right matches the existing bat file" {
    $steps = Get-CaptureSteps -Axis "LeftRight" -Recording $false -ScriptDir $ScriptDir
    if ($steps.Count -ne 2) { throw "expected 2 steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_camera_panels_LR.py")) { throw "step 0 should open left/right panels" }
    if (-not (ArgsHave $steps[1].Arguments "maya_key_from_cache_LR.py")) { throw "step 1 should key from cache (left/right)" }
}

Check "capture_front_back matches the existing bat file" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptDir
    if ($steps.Count -ne 6) { throw "expected 6 steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "hide")) { throw "step 0 should hide the taskbar" }
    if (-not (ArgsHave $steps[1].Arguments "maya_camera_panels.py")) { throw "step 1 should open front/back panels" }
    if (-not (ArgsHave $steps[2].Arguments "maya_key_from_cache.py")) { throw "step 2 should key from cache (front/back)" }
    if ($steps[3].FilePath -ne "ping") { throw "step 3 should be the short ping pause" }
    if (-not (ArgsHave $steps[4].Arguments "maya_obs_capture.ps1")) { throw "step 4 should run the OBS capture" }
    if (-not (ArgsHave $steps[5].Arguments "show")) { throw "step 5 should restore the taskbar" }
}

Check "capture_left_right matches the existing bat file" {
    $steps = Get-CaptureSteps -Axis "LeftRight" -Recording $true -ScriptDir $ScriptDir
    if ($steps.Count -ne 6) { throw "expected 6 steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[1].Arguments "maya_camera_panels_LR.py")) { throw "step 1 should open left/right panels" }
    if (-not (ArgsHave $steps[2].Arguments "maya_key_from_cache_LR.py")) { throw "step 2 should key from cache (left/right)" }
}

Check "a frame range is passed through to maya_obs_capture.ps1 when recording" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptDir -StartFrame 0 -EndFrame 100
    if ($steps.Count -ne 6) { throw "expected 6 steps, got $($steps.Count)" }
    $obsStep = $steps[4]
    if (-not (ArgsHave $obsStep.Arguments "maya_obs_capture.ps1")) { throw "step 4 should still be the OBS capture step" }
    if (-not (ArgsHave $obsStep.Arguments "-StartFrame 0")) { throw "expected -StartFrame 0 in the OBS capture arguments: $($obsStep.Arguments -join ' ')" }
    if (-not (ArgsHave $obsStep.Arguments "-EndFrame 100")) { throw "expected -EndFrame 100 in the OBS capture arguments: $($obsStep.Arguments -join ' ')" }
}

Check "no frame range means maya_obs_capture.ps1 gets no -StartFrame/-EndFrame at all" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptDir
    $obsStep = $steps[4]
    if (ArgsHave $obsStep.Arguments "-StartFrame") { throw "should not pass -StartFrame when no range was given: $($obsStep.Arguments -join ' ')" }
}

Check "a frame range on Preview is silently irrelevant -- Preview never touches maya_obs_capture.ps1" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $false -ScriptDir $ScriptDir -StartFrame 0 -EndFrame 100
    foreach ($s in $steps) {
        if (ArgsHave $s.Arguments "maya_obs_capture") { throw "Preview should never invoke maya_obs_capture.ps1, range or not" }
    }
}

Check "giving only StartFrame without EndFrame throws instead of silently misbehaving" {
    $threw = $false
    try {
        Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptDir -StartFrame 0
    } catch {
        $threw = $true
    }
    if (-not $threw) { throw "expected an error when StartFrame is given without EndFrame" }
}

Check "taskbar is always restored even though it's the last step, never skipped" {
    foreach ($axis in @("FrontBack", "LeftRight")) {
        $steps = Get-CaptureSteps -Axis $axis -Recording $true -ScriptDir $ScriptDir
        $last = $steps[$steps.Count - 1]
        if (-not (ArgsHave $last.Arguments "show")) { throw "$axis capture must end by restoring the taskbar" }
    }
}

Check "clean reset targets maya_clean_reset.py through the bridge" {
    $steps = Get-CleanResetStep -ScriptDir $ScriptDir
    if ($steps.Count -ne 1) { throw "expected exactly 1 step, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_clean_reset.py")) { throw "should target maya_clean_reset.py" }
    if (-not (ArgsHave $steps[0].Arguments "send_to_maya.ps1")) { throw "should route through send_to_maya.ps1, same as every other step" }
}

Check "every step uses -ExecutionPolicy Bypass, same as the existing bat files" {
    $allSteps = @()
    $allSteps += Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptDir
    $allSteps += Get-CaptureSteps -Axis "LeftRight" -Recording $false -ScriptDir $ScriptDir
    $allSteps += Get-CleanResetStep -ScriptDir $ScriptDir
    foreach ($s in $allSteps) {
        if ($s.FilePath -eq "powershell" -and -not (ArgsHave $s.Arguments "Bypass")) {
            throw "found a powershell step missing -ExecutionPolicy Bypass: $($s.Arguments -join ' ')"
        }
    }
}

Check "Get-PortSnippetContent reads the real open_maya_port.py file" {
    $content = Get-PortSnippetContent -ScriptDir $ScriptDir
    if ($content -eq $null) { throw "expected file content, got null -- is open_maya_port.py missing?" }
    if ($content -notmatch "commandPort") { throw "expected the snippet to mention commandPort: $content" }
    if ($content -notmatch ":7001") { throw "expected the snippet to mention port 7001: $content" }
}

Check "Get-StopCleanupSteps stops Maya playback, restores HUD, restores taskbar, stops OBS -- in that order" {
    $steps = Get-StopCleanupSteps -ScriptDir $ScriptDir
    if ($steps.Count -ne 4) { throw "expected 4 cleanup steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_stop_playback.py")) { throw "step 0 should stop Maya playback" }
    if (-not (ArgsHave $steps[0].Arguments "send_to_maya.ps1")) { throw "step 0 should route through send_to_maya.ps1, same as every other Maya-touching step" }
    if (-not (ArgsHave $steps[1].Arguments "maya_restore_hud.py")) { throw "step 1 should restore the Maya HUD" }
    if (-not (ArgsHave $steps[1].Arguments "send_to_maya.ps1")) { throw "step 1 should also route through send_to_maya.ps1" }
    if (-not (ArgsHave $steps[2].Arguments "taskbar_control.ps1")) { throw "step 2 should touch the taskbar" }
    if (-not (ArgsHave $steps[2].Arguments "show")) { throw "step 2 should SHOW the taskbar, not hide it" }
    if (-not (ArgsHave $steps[3].Arguments "obs_control.ps1")) { throw "step 3 should touch OBS" }
    if (-not (ArgsHave $steps[3].Arguments "stop")) { throw "step 3 should STOP OBS recording, not start it" }
}

Check "Get-StopCleanupSteps's HUD restore step runs before the taskbar/OBS restore, mirroring the stop-playback step" {
    # Regression guard specifically for the new step (task17, 2026-09-30):
    # both Maya-command-port steps (stop playback, restore HUD) should be
    # grouped first, ahead of the taskbar/OBS steps that don't touch Maya
    # at all.
    $steps = Get-StopCleanupSteps -ScriptDir $ScriptDir
    $mayaStepIndices = @(0..($steps.Count - 1)) | Where-Object { ArgsHave $steps[$_].Arguments "send_to_maya.ps1" }
    if (($mayaStepIndices | Sort-Object) -join "," -ne "0,1") { throw "expected the two Maya-touching steps at indices 0,1, got: $($mayaStepIndices -join ',')" }
}

Check "Get-StopCleanupSteps also uses -ExecutionPolicy Bypass, same as every other step" {
    $steps = Get-StopCleanupSteps -ScriptDir $ScriptDir
    foreach ($s in $steps) {
        if ($s.FilePath -eq "powershell" -and -not (ArgsHave $s.Arguments "Bypass")) {
            throw "found a cleanup step missing -ExecutionPolicy Bypass: $($s.Arguments -join ' ')"
        }
    }
}

Check "Get-PortSnippetContent returns null for a missing file, not an exception" {
    # ScriptDir\..\open_maya_port.py must genuinely not exist for this path --
    # a wrong "does_not_exist" subfolder under d4_rom would still resolve up
    # to the REAL d4_rom\open_maya_port.py via Split-Path -Parent
    $content = Get-PortSnippetContent -ScriptDir "D:\__backup\claude\nonexistent_project_xyz\scripts"
    if ($content -ne $null) { throw "expected null when open_maya_port.py doesn't exist at the derived path" }
}

Check "Get-NoteworthyMayaOutput returns empty for the routine success case" {
    $result = Get-NoteworthyMayaOutput -Stdout "Sent to Maya command port 127.0.0.1:7001`n"
    if ($result -ne "") { throw "expected empty string for a routine success, got '$result'" }
}

Check "Get-NoteworthyMayaOutput returns empty for blank input" {
    $result = Get-NoteworthyMayaOutput -Stdout ""
    if ($result -ne "") { throw "expected empty string for blank input, got '$result'" }
}

Check "Get-NoteworthyMayaOutput surfaces a relayed exception's text" {
    $result = Get-NoteworthyMayaOutput -Stdout "Maya response: No file references found in this scene.`nSent to Maya command port 127.0.0.1:7001`n"
    if ($result -ne "Maya response: No file references found in this scene.") { throw "expected the exception text alone, got '$result'" }
}

Check "Get-NoteworthyMayaOutput surfaces a timeout notice" {
    $result = Get-NoteworthyMayaOutput -Stdout "No response from Maya within 6000ms -- it may still be running.`nSent to Maya command port 127.0.0.1:7001`n"
    if ($result -ne "No response from Maya within 6000ms -- it may still be running.") { throw "expected the timeout notice alone, got '$result'" }
}

Check "ConvertFrom-CacheProgressOutput reports incomplete mid-build" {
    $result = ConvertFrom-CacheProgressOutput -Lines @("animation_reference=D:/anim/barM_rom_anim.ma", "frames_done=100", "frames_total=400", "percent=25.0")
    if ($result.IsComplete) { throw "expected IsComplete false while done < total" }
    if ($result.Done -ne 100) { throw "expected Done 100, got $($result.Done)" }
    if ($result.Total -ne 400) { throw "expected Total 400, got $($result.Total)" }
    if ($result.Percent -ne 25.0) { throw "expected Percent 25.0, got $($result.Percent)" }
}

Check "ConvertFrom-CacheProgressOutput reports complete once done reaches total" {
    $result = ConvertFrom-CacheProgressOutput -Lines @("frames_done=400", "frames_total=400", "percent=100.0", "note=done")
    if (-not $result.IsComplete) { throw "expected IsComplete true once done >= total" }
}

Check "ConvertFrom-CacheProgressOutput reports complete for the no-motion-detected case" {
    # maya_cache_bbox.py writes done == total here too -- still means
    # sampling itself is finished, just with a different note.
    $result = ConvertFrom-CacheProgressOutput -Lines @("frames_done=400", "frames_total=400", "percent=100.0", "note=no_motion_detected")
    if (-not $result.IsComplete) { throw "expected IsComplete true for the no-motion-detected case" }
}

Check "ConvertFrom-CacheProgressOutput does not treat a zero total as complete" {
    $result = ConvertFrom-CacheProgressOutput -Lines @("frames_done=0", "frames_total=0")
    if ($result.IsComplete) { throw "expected IsComplete false when total is 0" }
}

Check "ConvertFrom-CacheCheckOutput parses a CACHE_EXISTS line" {
    $result = ConvertFrom-CacheCheckOutput -Output "Sent to Maya command port 127.0.0.1:7001`nCACHE_EXISTS animation_reference=D:/anim/barM_rom_anim.ma cache_path=D:/cache/barM__abc123.json`n"
    if ($result.Status -ne "Exists") { throw "expected Status 'Exists', got '$($result.Status)'" }
    if ($result.AnimationReference -ne "D:/anim/barM_rom_anim.ma") { throw "expected the animation reference parsed out, got '$($result.AnimationReference)'" }
    if ($result.CachePath -ne "D:/cache/barM__abc123.json") { throw "expected the cache path parsed out, got '$($result.CachePath)'" }
}

Check "ConvertFrom-CacheCheckOutput parses a CACHE_MISSING line" {
    $result = ConvertFrom-CacheCheckOutput -Output "CACHE_MISSING animation_reference=D:/anim/druF_rom_anim.ma cache_path=D:/cache/druF__xyz789.json"
    if ($result.Status -ne "Missing") { throw "expected Status 'Missing', got '$($result.Status)'" }
}

Check "ConvertFrom-CacheCheckOutput surfaces a CACHE_CHECK_ERROR message" {
    $result = ConvertFrom-CacheCheckOutput -Output "CACHE_CHECK_ERROR No file references found in this scene to key the cache off of."
    if ($result.Status -ne "Error") { throw "expected Status 'Error', got '$($result.Status)'" }
    if ($result.ErrorMessage -notmatch "No file references") { throw "expected the error message text preserved, got '$($result.ErrorMessage)'" }
}

Check "ConvertFrom-CacheCheckOutput parses a CACHE_NO_REFERENCE line as its own distinct Status, not Error" {
    $result = ConvertFrom-CacheCheckOutput -Output "CACHE_NO_REFERENCE No file references found in this scene."
    if ($result.Status -ne "NoReference") { throw "expected Status 'NoReference', got '$($result.Status)'" }
    if ($result.ErrorMessage -notmatch "No file references") { throw "expected the message text preserved, got '$($result.ErrorMessage)'" }
    if ($result.AnimationReference -ne $null) { throw "expected no animation reference on a NoReference result" }
}

Check "ConvertFrom-CacheCheckOutput reports Unknown for empty or unrelated output, not an exception" {
    $result = ConvertFrom-CacheCheckOutput -Output ""
    if ($result.Status -ne "Unknown") { throw "expected Status 'Unknown' for empty output, got '$($result.Status)'" }

    $result2 = ConvertFrom-CacheCheckOutput -Output "Sent to Maya command port 127.0.0.1:7001"
    if ($result2.Status -ne "Unknown") { throw "expected Status 'Unknown' when no CACHE_* line is present, got '$($result2.Status)'" }
}

Check "ConvertFrom-TimeSliderOutput parses a TIME_RANGE line" {
    $result = ConvertFrom-TimeSliderOutput -Output "Sent to Maya command port 127.0.0.1:7001`nTIME_RANGE min=0 max=3240`n"
    if ($result.Success -ne $true) { throw "expected Success true, got '$($result.Success)'" }
    if ($result.Start -ne 0) { throw "expected Start 0, got '$($result.Start)'" }
    if ($result.End -ne 3240) { throw "expected End 3240, got '$($result.End)'" }
}

Check "ConvertFrom-TimeSliderOutput handles a negative min (frames before 0 are valid in Maya)" {
    $result = ConvertFrom-TimeSliderOutput -Output "TIME_RANGE min=-24 max=100"
    if ($result.Start -ne -24) { throw "expected Start -24, got '$($result.Start)'" }
    if ($result.End -ne 100) { throw "expected End 100, got '$($result.End)'" }
}

Check "ConvertFrom-TimeSliderOutput surfaces a TIME_RANGE_ERROR message" {
    $result = ConvertFrom-TimeSliderOutput -Output "TIME_RANGE_ERROR maya.cmds.playbackOptions() failed"
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.ErrorMessage -notmatch "playbackOptions") { throw "expected the error message text preserved, got '$($result.ErrorMessage)'" }
}

Check "ConvertFrom-TimeSliderOutput reports failure for empty or unrelated output, not an exception" {
    $result = ConvertFrom-TimeSliderOutput -Output ""
    if ($result.Success -ne $false) { throw "expected Success false for empty output, got '$($result.Success)'" }

    $result2 = ConvertFrom-TimeSliderOutput -Output "Sent to Maya command port 127.0.0.1:7001"
    if ($result2.Success -ne $false) { throw "expected Success false when no TIME_RANGE line is present, got '$($result2.Success)'" }
}

Check "ConvertFrom-AnimationRangeOutput parses an ANIM_RANGE line" {
    $result = ConvertFrom-AnimationRangeOutput -Output "Sent to Maya command port 127.0.0.1:7001`nANIM_RANGE min=0 max=3240`n"
    if ($result.Success -ne $true) { throw "expected Success true, got '$($result.Success)'" }
    if ($result.Start -ne 0) { throw "expected Start 0, got '$($result.Start)'" }
    if ($result.End -ne 3240) { throw "expected End 3240, got '$($result.End)'" }
}

Check "ConvertFrom-AnimationRangeOutput surfaces an ANIM_RANGE_ERROR message" {
    $result = ConvertFrom-AnimationRangeOutput -Output "ANIM_RANGE_ERROR maya.cmds.playbackOptions() failed"
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.ErrorMessage -notmatch "playbackOptions") { throw "expected the error message text preserved, got '$($result.ErrorMessage)'" }
}

Check "ConvertFrom-AnimationRangeOutput reports failure for empty or unrelated output, not an exception" {
    $result = ConvertFrom-AnimationRangeOutput -Output ""
    if ($result.Success -ne $false) { throw "expected Success false for empty output, got '$($result.Success)'" }

    $result2 = ConvertFrom-AnimationRangeOutput -Output "Sent to Maya command port 127.0.0.1:7001"
    if ($result2.Success -ne $false) { throw "expected Success false when no ANIM_RANGE line is present, got '$($result2.Success)'" }
}

Check "ConvertFrom-ObsMonitorListOutput parses multiple MONITOR_ITEM lines and marks the current one" {
    $output = 'MONITOR_ITEM name="Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)" value="\\?\DISPLAY#UGD2202#5&15d3a&0&UID4352#{guid}" current="false"' + "`n" + 'MONITOR_ITEM name="LG FHD: 1920x1080 @ 1920,0" value="\\?\DISPLAY#GSM5BC6#5&15d3a&0&UID4358#{guid}" current="true"'
    $result = ConvertFrom-ObsMonitorListOutput -Output $output
    if ($result.Success -ne $true) { throw "expected Success true, got '$($result.Success)'" }
    if ($result.Monitors.Count -ne 2) { throw "expected 2 monitors parsed, got $($result.Monitors.Count)" }
    if ($result.Monitors[0].Name -notmatch "Artist22R Pro") { throw "expected the first monitor's name parsed, got '$($result.Monitors[0].Name)'" }
    if ($result.Monitors[0].IsCurrent -ne $false) { throw "expected the first monitor IsCurrent false" }
    if ($result.Monitors[1].IsCurrent -ne $true) { throw "expected the second monitor IsCurrent true" }
    if ($result.Monitors[1].Value -notmatch "UID4358") { throw "expected the raw monitor_id value preserved, got '$($result.Monitors[1].Value)'" }
}

Check "ConvertFrom-ObsMonitorListOutput reports failure for MONITOR_SOURCE_NOT_FOUND" {
    $result = ConvertFrom-ObsMonitorListOutput -Output "MONITOR_SOURCE_NOT_FOUND"
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.Monitors.Count -ne 0) { throw "expected no monitors" }
}

Check "ConvertFrom-ObsMonitorListOutput surfaces a MONITOR_LIST_ERROR message" {
    $result = ConvertFrom-ObsMonitorListOutput -Output "MONITOR_LIST_ERROR Could not connect to OBS WebSocket."
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.ErrorMessage -notmatch "Could not connect") { throw "expected the error message text preserved, got '$($result.ErrorMessage)'" }
    if ($result.AuthFailed -ne $false) { throw "expected AuthFailed false for a plain (non-auth) error, got '$($result.AuthFailed)'" }
}

Check "ConvertFrom-ObsMonitorListOutput distinguishes MONITOR_LIST_AUTH_FAILED (wrong password) from a plain MONITOR_LIST_ERROR" {
    # User report this exists for: the OBS WebSocket status dot used to go
    # green on ANY configured password, even a wrong one. AuthFailed=$true
    # is the ONLY thing that should ever make Update-ObsPasswordVerificationIndicator
    # show red "password appears incorrect" rather than the more
    # ambiguous "can't verify" amber every other failure gets.
    $result = ConvertFrom-ObsMonitorListOutput -Output "MONITOR_LIST_AUTH_FAILED the OBS WebSocket password is incorrect."
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.AuthFailed -ne $true) { throw "expected AuthFailed true for MONITOR_LIST_AUTH_FAILED, got '$($result.AuthFailed)'" }
    if ($result.ErrorMessage -notmatch "password is incorrect") { throw "expected the message text preserved, got '$($result.ErrorMessage)'" }
}

Check "ConvertFrom-ObsMonitorListOutput reports failure for empty output, not an exception" {
    $result = ConvertFrom-ObsMonitorListOutput -Output ""
    if ($result.Success -ne $false) { throw "expected Success false for empty output, got '$($result.Success)'" }
}

Check "ConvertFrom-ObsMonitorSetOutput parses a verified (real content confirmed) result" {
    $output = "MONITOR_SET_OK`nMONITOR_SET_VERIFIED true`nMONITOR_SET_BRIGHTNESS 136.78`nMONITOR_SET_MESSAGE Confirmed showing real content (brightness=136.78).`nMONITOR_SET_PREVIEW D:\path\to\preview.png"
    $result = ConvertFrom-ObsMonitorSetOutput -Output $output
    if ($result.Success -ne $true) { throw "expected Success true, got '$($result.Success)'" }
    if ($result.Verified -ne $true) { throw "expected Verified true, got '$($result.Verified)'" }
    if ($result.Brightness -ne 136.78) { throw "expected Brightness 136.78, got '$($result.Brightness)'" }
    if ($result.Message -notmatch "Confirmed showing real content") { throw "expected the message text preserved, got '$($result.Message)'" }
    if ($result.PreviewPath -ne 'D:\path\to\preview.png') { throw "expected the preview path preserved, got '$($result.PreviewPath)'" }
}

Check "ConvertFrom-ObsMonitorSetOutput parses an unverified (still black) result with its actionable message" {
    $output = "MONITOR_SET_OK`nMONITOR_SET_VERIFIED false`nMONITOR_SET_BRIGHTNESS 0`nMONITOR_SET_MESSAGE Still showing a black/empty image (brightness=0). Try DXGI Desktop Duplication.`nMONITOR_SET_PREVIEW D:\path\to\preview.png"
    $result = ConvertFrom-ObsMonitorSetOutput -Output $output
    if ($result.Success -ne $true) { throw "expected Success true (the API call itself succeeded), got '$($result.Success)'" }
    if ($result.Verified -ne $false) { throw "expected Verified false, got '$($result.Verified)'" }
    if ($result.Message -notmatch "DXGI Desktop Duplication") { throw "expected the actionable fix text preserved, got '$($result.Message)'" }
}

Check "ConvertFrom-ObsMonitorSetOutput surfaces a MONITOR_SET_ERROR message" {
    $result = ConvertFrom-ObsMonitorSetOutput -Output "MONITOR_SET_ERROR Could not connect to OBS WebSocket."
    if ($result.Success -ne $false) { throw "expected Success false, got '$($result.Success)'" }
    if ($result.Message -notmatch "Could not connect") { throw "expected the error message text preserved, got '$($result.Message)'" }
}

Check "ConvertFrom-ObsMonitorSetOutput reports failure for empty output, not an exception" {
    $result = ConvertFrom-ObsMonitorSetOutput -Output ""
    if ($result.Success -ne $false) { throw "expected Success false for empty output, got '$($result.Success)'" }
}

Check "ConvertFrom-ObsMonitorName extracts the rect from a real OBS monitor display name" {
    $result = ConvertFrom-ObsMonitorName -Name "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"
    if ($result.Success -ne $true) { throw "expected Success true, got '$($result.Success)'" }
    if ($result.Left -ne 0) { throw "expected Left 0, got '$($result.Left)'" }
    if ($result.Top -ne 0) { throw "expected Top 0, got '$($result.Top)'" }
    if ($result.Right -ne 1920) { throw "expected Right 1920 (0 + 1920 width), got '$($result.Right)'" }
    if ($result.Bottom -ne 1080) { throw "expected Bottom 1080 (0 + 1080 height), got '$($result.Bottom)'" }
}

Check "ConvertFrom-ObsMonitorName handles a non-zero, non-primary monitor position" {
    $result = ConvertFrom-ObsMonitorName -Name "LG FHD: 1920x1080 @ 1920,0"
    if ($result.Left -ne 1920) { throw "expected Left 1920, got '$($result.Left)'" }
    if ($result.Top -ne 0) { throw "expected Top 0, got '$($result.Top)'" }
    if ($result.Right -ne 3840) { throw "expected Right 3840 (1920 + 1920 width), got '$($result.Right)'" }
    if ($result.Bottom -ne 1080) { throw "expected Bottom 1080, got '$($result.Bottom)'" }
}

Check "ConvertFrom-ObsMonitorName handles a negative monitor position (a monitor positioned above/left of the primary)" {
    $result = ConvertFrom-ObsMonitorName -Name "Some Monitor: 2560x1440 @ -2560,-360"
    if ($result.Success -ne $true) { throw "expected Success true for a negative position, got '$($result.Success)'" }
    if ($result.Left -ne -2560) { throw "expected Left -2560, got '$($result.Left)'" }
    if ($result.Top -ne -360) { throw "expected Top -360, got '$($result.Top)'" }
    if ($result.Right -ne 0) { throw "expected Right 0 (-2560 + 2560 width), got '$($result.Right)'" }
    if ($result.Bottom -ne 1080) { throw "expected Bottom 1080 (-360 + 1440 height), got '$($result.Bottom)'" }
}

Check "ConvertFrom-ObsMonitorName reports failure for a name with no parseable rect, not an exception" {
    $result = ConvertFrom-ObsMonitorName -Name "Some Unusual Monitor Name"
    if ($result.Success -ne $false) { throw "expected Success false for an unparseable name, got '$($result.Success)'" }

    $result2 = ConvertFrom-ObsMonitorName -Name ""
    if ($result2.Success -ne $false) { throw "expected Success false for an empty name, got '$($result2.Success)'" }
}

Check "ConvertFrom-ObsConfigContent reports Configured true for a real password" {
    $result = ConvertFrom-ObsConfigContent -Content "host: 127.0.0.1`nport: 4455`npassword: d4rom_capture_local_2026`n"
    if ($result.Configured -ne $true) { throw "expected Configured true for a real-looking password" }
    if ($result.CurrentPassword -ne "d4rom_capture_local_2026") { throw "expected the password parsed out, got '$($result.CurrentPassword)'" }
}

Check "ConvertFrom-ObsConfigContent reports Configured false for the REPLACE_ME placeholder" {
    $result = ConvertFrom-ObsConfigContent -Content "host: 127.0.0.1`nport: 4455`npassword: REPLACE_ME`n"
    if ($result.Configured -ne $false) { throw "expected Configured false for the unedited placeholder password" }
}

Check "ConvertFrom-ObsConfigContent reports Configured false for empty or missing content" {
    $result = ConvertFrom-ObsConfigContent -Content ""
    if ($result.Configured -ne $false) { throw "expected Configured false for empty content" }
    if ($result.CurrentPassword -ne "") { throw "expected an empty CurrentPassword, got '$($result.CurrentPassword)'" }
}

Check "Set-ObsConfigPassword replaces an existing password line, preserving the rest of the file" {
    $existing = "OBS WebSocket connection info.`n`nhost: 127.0.0.1`nport: 4455`npassword: old_password`n"
    $updated = Set-ObsConfigPassword -ExistingContent $existing -NewPassword "new_password_123"
    if ($updated -notmatch "password:\s*new_password_123") { throw "expected the new password in the output: $updated" }
    if ($updated -match "old_password") { throw "old password should not remain: $updated" }
    if ($updated -notmatch "host:\s*127\.0\.0\.1") { throw "expected the host line preserved: $updated" }
    if ($updated -notmatch "port:\s*4455") { throw "expected the port line preserved: $updated" }
}

Check "Set-ObsConfigPassword writes a full templated file when no config exists yet" {
    $updated = Set-ObsConfigPassword -ExistingContent "" -NewPassword "brand_new_password"
    if ($updated -notmatch "password:\s*brand_new_password") { throw "expected the new password in the fresh template: $updated" }
    if ($updated -notmatch "host:\s*127\.0\.0\.1") { throw "expected a default host in the fresh template: $updated" }
    if ($updated -notmatch "port:\s*4455") { throw "expected a default port in the fresh template: $updated" }
}

Check "Get-StartRecordingRequirementFailures returns no failures when everything is satisfied" {
    $result = Get-StartRecordingRequirementFailures -MayaReachable $true -ObsPasswordConfigured $true -MonitorSelected $true
    if ($result.Count -ne 0) { throw "expected zero failures, got $($result.Count): $($result -join ' | ')" }
}

Check "Get-StartRecordingRequirementFailures reports Maya unreachable" {
    $result = Get-StartRecordingRequirementFailures -MayaReachable $false -ObsPasswordConfigured $true -MonitorSelected $true
    if ($result.Count -ne 1) { throw "expected exactly one failure, got $($result.Count)" }
    if ($result[0] -notmatch "^Maya connection") { throw "expected a Maya connection failure, got '$($result[0])'" }
}

Check "Get-StartRecordingRequirementFailures reports OBS password not configured" {
    $result = Get-StartRecordingRequirementFailures -MayaReachable $true -ObsPasswordConfigured $false -MonitorSelected $true
    if ($result.Count -ne 1) { throw "expected exactly one failure, got $($result.Count)" }
    if ($result[0] -notmatch "^OBS WebSocket") { throw "expected an OBS WebSocket failure, got '$($result[0])'" }
}

Check "Get-StartRecordingRequirementFailures reports no monitor selected" {
    $result = Get-StartRecordingRequirementFailures -MayaReachable $true -ObsPasswordConfigured $true -MonitorSelected $false
    if ($result.Count -ne 1) { throw "expected exactly one failure, got $($result.Count)" }
    if ($result[0] -notmatch "^Recording Monitor") { throw "expected a Recording Monitor failure, got '$($result[0])'" }
}

Check "Get-StartRecordingRequirementFailures reports all three at once, in order" {
    $result = Get-StartRecordingRequirementFailures -MayaReachable $false -ObsPasswordConfigured $false -MonitorSelected $false
    if ($result.Count -ne 3) { throw "expected all three failures, got $($result.Count): $($result -join ' | ')" }
    if ($result[0] -notmatch "^Maya connection") { throw "expected Maya connection first, got '$($result[0])'" }
    if ($result[1] -notmatch "^OBS WebSocket") { throw "expected OBS WebSocket second, got '$($result[1])'" }
    if ($result[2] -notmatch "^Recording Monitor") { throw "expected Recording Monitor third, got '$($result[2])'" }
}

Check "Get-CaptureStepsForAxis with FrontBack/LeftRight is byte-identical to calling Get-CaptureSteps directly" {
    foreach ($axis in @("FrontBack", "LeftRight")) {
        foreach ($recording in @($true, $false)) {
            $direct = Get-CaptureSteps -Axis $axis -Recording $recording -ScriptDir $ScriptDir
            $viaWrapper = Get-CaptureStepsForAxis -Axis $axis -Recording $recording -ScriptDir $ScriptDir
            # ${name} braces on purpose: "$recording:" inside a double-quoted
            # string parses as a drive-qualified variable (like $env:PATH)
            # and is a hard parse error, not a runtime one.
            if ($direct.Count -ne $viaWrapper.Count) { throw "${axis}/Recording=${recording}: step count differs ($($direct.Count) vs $($viaWrapper.Count))" }
            for ($i = 0; $i -lt $direct.Count; $i++) {
                if (($direct[$i].Arguments -join " ") -ne ($viaWrapper[$i].Arguments -join " ")) {
                    throw "${axis}/Recording=${recording} step $i differs between Get-CaptureSteps and Get-CaptureStepsForAxis"
                }
            }
        }
    }
}

Check "Get-CaptureStepsForAxis with All concatenates FrontBack then LeftRight as two independent record cycles" {
    $steps = Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptDir
    if ($steps.Count -ne 12) { throw "expected 12 steps (6 FrontBack + 6 LeftRight), got $($steps.Count)" }
    # First leg: identical to a standalone FrontBack capture (steps 0-5).
    if (-not (ArgsHave $steps[1].Arguments "maya_camera_panels.py")) { throw "step 1 should open front/back panels" }
    if (ArgsHave $steps[1].Arguments "maya_camera_panels_LR.py") { throw "step 1 must be the FrontBack panels script, not LR" }
    if (-not (ArgsHave $steps[4].Arguments "maya_obs_capture.ps1")) { throw "step 4 should be the first leg's own OBS capture" }
    if (-not (ArgsHave $steps[5].Arguments "show")) { throw "step 5 should restore the taskbar after the first leg" }
    # Second leg: a full, independent LeftRight capture (steps 6-11) -- its
    # own hide/OBS-start/OBS-stop/show, not sharing the first leg's.
    if (-not (ArgsHave $steps[6].Arguments "hide")) { throw "step 6 should hide the taskbar again for the second leg" }
    if (-not (ArgsHave $steps[7].Arguments "maya_camera_panels_LR.py")) { throw "step 7 should open left/right panels" }
    if (-not (ArgsHave $steps[8].Arguments "maya_key_from_cache_LR.py")) { throw "step 8 should key from cache (left/right)" }
    if (-not (ArgsHave $steps[10].Arguments "maya_obs_capture.ps1")) { throw "step 10 should be the second leg's own OBS capture" }
    if (-not (ArgsHave $steps[11].Arguments "show")) { throw "step 11 should restore the taskbar after the second leg" }
}

Check "Get-CaptureStepsForAxis with All and Recording false (Preview/Run Only) has no OBS/taskbar in either leg" {
    $steps = Get-CaptureStepsForAxis -Axis "All" -Recording $false -ScriptDir $ScriptDir
    if ($steps.Count -ne 4) { throw "expected 4 steps (2 FrontBack + 2 LeftRight), got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_camera_panels.py")) { throw "step 0 should open front/back panels" }
    if (-not (ArgsHave $steps[2].Arguments "maya_camera_panels_LR.py")) { throw "step 2 should open left/right panels" }
    foreach ($s in $steps) {
        if ((ArgsHave $s.Arguments "taskbar_control") -or (ArgsHave $s.Arguments "maya_obs_capture")) {
            throw "All in run-only mode must not touch taskbar or OBS in either leg"
        }
    }
}

Check "Get-CaptureStepsForAxis with All passes the same StartFrame/EndFrame to both legs' OBS step" {
    $steps = Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptDir -StartFrame 10 -EndFrame 50
    $firstLegObs = $steps[4]
    $secondLegObs = $steps[10]
    if (-not (ArgsHave $firstLegObs.Arguments "-StartFrame 10")) { throw "first leg OBS step missing -StartFrame 10: $($firstLegObs.Arguments -join ' ')" }
    if (-not (ArgsHave $firstLegObs.Arguments "-EndFrame 50")) { throw "first leg OBS step missing -EndFrame 50: $($firstLegObs.Arguments -join ' ')" }
    if (-not (ArgsHave $secondLegObs.Arguments "-StartFrame 10")) { throw "second leg OBS step missing -StartFrame 10: $($secondLegObs.Arguments -join ' ')" }
    if (-not (ArgsHave $secondLegObs.Arguments "-EndFrame 50")) { throw "second leg OBS step missing -EndFrame 50: $($secondLegObs.Arguments -join ' ')" }
}

Check "Get-PreviewAxis maps All to FrontBack (first leg only) and leaves the single axes alone" {
    # User decision 2026-09-24 (option b): Preview with All shows only the
    # first leg, because the two panel sets cannot coexist.
    if ((Get-PreviewAxis -Axis "All") -ne "FrontBack") { throw "All must preview as FrontBack, got '$(Get-PreviewAxis -Axis 'All')'" }
    if ((Get-PreviewAxis -Axis "FrontBack") -ne "FrontBack") { throw "FrontBack must stay FrontBack" }
    if ((Get-PreviewAxis -Axis "LeftRight") -ne "LeftRight") { throw "LeftRight must stay LeftRight" }
}

Check "Get-PreviewAxis rejects an unknown axis" {
    $threw = $false
    try { Get-PreviewAxis -Axis "Diagonal" } catch { $threw = $true }
    if (-not $threw) { throw "expected ValidateSet to reject an axis other than FrontBack/LeftRight/All" }
}

Check "Preview steps for All (through Get-PreviewAxis) are the Front/Back leg only; Start Recording steps for All still have both legs" {
    $preview = Get-CaptureStepsForAxis -Axis (Get-PreviewAxis -Axis "All") -Recording $false -ScriptDir $ScriptDir
    if ($preview.Count -ne 2) { throw "expected 2 preview steps (Front/Back panels + keyer), got $($preview.Count)" }
    if (-not (ArgsHave $preview[0].Arguments "maya_camera_panels.py")) { throw "preview step 0 should open the Front/Back panels" }
    foreach ($s in $preview) {
        if (ArgsHave $s.Arguments "_LR.py") { throw "an All preview must not include any Left/Right (_LR) script, got: $($s.Arguments -join ' ')" }
    }
    $recording = Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptDir
    if ($recording.Count -ne 12) { throw "Start Recording with All must still queue both legs (12 steps), got $($recording.Count)" }
    # Cache build goes through Get-CaptureStepsForAxis directly (no
    # Get-PreviewAxis), so All there stays both legs too.
    $cacheBuild = Get-CaptureStepsForAxis -Axis "All" -Recording $false -ScriptDir $ScriptDir
    if ($cacheBuild.Count -ne 4) { throw "cache build with All must still queue both legs (4 steps), got $($cacheBuild.Count)" }
}

Check "Get-CaptureStepsForAxis rejects an unknown axis the same way Get-CaptureSteps does" {
    $threw = $false
    try {
        Get-CaptureStepsForAxis -Axis "Diagonal" -Recording $true -ScriptDir $ScriptDir
    } catch {
        $threw = $true
    }
    if (-not $threw) { throw "expected ValidateSet to reject an axis other than FrontBack/LeftRight/All" }
}

# --- Arrow / wheel stepping (task48, 2026-10-07) --------------------------
# Get-SteppedNumber / Get-NumericFieldSpec / Get-SteppedTolerance /
# Get-SteppedFrameText are the pure core of the Up/Down + wheel stepping on
# every numeric box; the launcher's handlers only add the key/modifier read.

function StepEq($actual, $expected, [string]$what) {
    # Exact comparison on purpose: a drifted 0.30000000000000004 must FAIL.
    if ($null -eq $actual -or $actual -isnot [double] -or $actual -ne $expected) { throw "$what`: expected $expected, got '$actual' ($(if ($null -ne $actual) { $actual.GetType().Name }))" }
}

Check "Get-NumericFieldSpec holds exactly the user-approved step table and ranges" {
    $rows = @(
        @("Zoom", 10, 100, 1, -50, 50, 0),
        @("OffsetX", 10, 100, 1, $null, $null, 0),
        @("OffsetY", 10, 100, 1, $null, $null, 0),
        @("Tolerance", 1, 10, 0.1, 0, 20, 1),
        @("StartFrame", 1, 10, 1, [int]::MinValue, [int]::MaxValue, 0),
        @("EndFrame", 1, 10, 1, [int]::MinValue, [int]::MaxValue, 0)
    )
    foreach ($r in $rows) {
        $s = Get-NumericFieldSpec -Field $r[0]
        if ($s.Plain -ne $r[1] -or $s.Shift -ne $r[2] -or $s.Ctrl -ne $r[3]) { throw "$($r[0]): steps $($s.Plain)/$($s.Shift)/$($s.Ctrl) != $($r[1])/$($r[2])/$($r[3])" }
        if ($s.Min -ne $r[4] -or $s.Max -ne $r[5]) { throw "$($r[0]): range $($s.Min)..$($s.Max) != $($r[4])..$($r[5])" }
        if ($s.Decimals -ne $r[6]) { throw "$($r[0]): decimals $($s.Decimals) != $($r[6])" }
    }
}

Check "Get-SteppedNumber Zoom: plain 10, Shift 100 clamps to the limit, Ctrl 1, both modifiers -> Ctrl wins, both range ends" {
    StepEq (Get-SteppedNumber -Current 0 -Direction 1 -Field Zoom) 10.0 "zoom up plain"
    StepEq (Get-SteppedNumber -Current 0 -Direction -1 -Field Zoom) -10.0 "zoom down plain"
    StepEq (Get-SteppedNumber -Current 0 -Direction 1 -Field Zoom -Shift $true) 50.0 "zoom up shift clamps to 50"
    StepEq (Get-SteppedNumber -Current 0 -Direction -1 -Field Zoom -Shift $true) -50.0 "zoom down shift clamps to -50"
    StepEq (Get-SteppedNumber -Current 7 -Direction 1 -Field Zoom -Ctrl $true) 8.0 "zoom up ctrl"
    StepEq (Get-SteppedNumber -Current 7 -Direction -1 -Field Zoom -Ctrl $true) 6.0 "zoom down ctrl"
    StepEq (Get-SteppedNumber -Current 7 -Direction 1 -Field Zoom -Shift $true -Ctrl $true) 8.0 "zoom shift+ctrl: Ctrl wins"
    StepEq (Get-SteppedNumber -Current 50 -Direction 1 -Field Zoom) 50.0 "zoom stays at +50"
    StepEq (Get-SteppedNumber -Current -50 -Direction -1 -Field Zoom) -50.0 "zoom stays at -50"
    StepEq (Get-SteppedNumber -Current 45 -Direction 1 -Field Zoom) 50.0 "zoom 45 + 10 clamps to 50"
    StepEq (Get-SteppedNumber -Current -45 -Direction -1 -Field Zoom) -50.0 "zoom -45 - 10 clamps to -50"
    StepEq (Get-SteppedNumber -Current 3 -Direction -1 -Field Zoom) -7.0 "zoom crosses zero (non-step-aligned start)"
}

Check "Get-SteppedNumber OffsetX/OffsetY: plain 10, Shift 100, Ctrl 1, unbounded, non-step-aligned start" {
    foreach ($f in @("OffsetX", "OffsetY")) {
        StepEq (Get-SteppedNumber -Current 7 -Direction 1 -Field $f) 17.0 "$f 7 -> 17"
        StepEq (Get-SteppedNumber -Current 0 -Direction -1 -Field $f) -10.0 "$f 0 -> -10"
        StepEq (Get-SteppedNumber -Current 0 -Direction 1 -Field $f -Shift $true) 100.0 "$f shift up"
        StepEq (Get-SteppedNumber -Current 0 -Direction -1 -Field $f -Shift $true) -100.0 "$f shift down"
        StepEq (Get-SteppedNumber -Current 5 -Direction 1 -Field $f -Ctrl $true) 6.0 "$f ctrl up"
        StepEq (Get-SteppedNumber -Current 5 -Direction -1 -Field $f -Shift $true -Ctrl $true) 4.0 "$f shift+ctrl: Ctrl wins"
        StepEq (Get-SteppedNumber -Current 100000 -Direction 1 -Field $f -Shift $true) 100100.0 "$f has no upper limit"
        StepEq (Get-SteppedNumber -Current -100000 -Direction -1 -Field $f -Shift $true) -100100.0 "$f has no lower limit"
    }
}

Check "Get-SteppedNumber Tolerance: plain 1, Shift 10, Ctrl 0.1, clamped 0..20, no float drift" {
    StepEq (Get-SteppedNumber -Current 5 -Direction 1 -Field Tolerance) 6.0 "tol up plain"
    StepEq (Get-SteppedNumber -Current 5 -Direction -1 -Field Tolerance) 4.0 "tol down plain"
    StepEq (Get-SteppedNumber -Current 5 -Direction 1 -Field Tolerance -Shift $true) 15.0 "tol up shift"
    StepEq (Get-SteppedNumber -Current 15 -Direction 1 -Field Tolerance -Shift $true) 20.0 "tol up shift clamps to 20"
    StepEq (Get-SteppedNumber -Current 5 -Direction -1 -Field Tolerance -Shift $true) 0.0 "tol down shift clamps to 0"
    StepEq (Get-SteppedNumber -Current 0 -Direction -1 -Field Tolerance) 0.0 "tol Down at 0 stays 0"
    StepEq (Get-SteppedNumber -Current 20 -Direction 1 -Field Tolerance) 20.0 "tol Up at 20 stays 20"
    StepEq (Get-SteppedNumber -Current 0.2 -Direction 1 -Field Tolerance -Ctrl $true) 0.3 "tol 0.2 + 0.1 must be exactly 0.3"
    StepEq (Get-SteppedNumber -Current 5 -Direction 1 -Field Tolerance -Shift $true -Ctrl $true) 5.1 "tol shift+ctrl: Ctrl wins"
    $v = 0.0
    for ($i = 0; $i -lt 10; $i++) { $v = Get-SteppedNumber -Current $v -Direction 1 -Field Tolerance -Ctrl $true }
    StepEq $v 1.0 "ten 0.1 steps from 0 must land exactly on 1.0 (drift)"
    for ($i = 0; $i -lt 3; $i++) { $v = Get-SteppedNumber -Current $v -Direction -1 -Field Tolerance -Ctrl $true }
    StepEq $v 0.7 "three 0.1 steps down from 1.0 must land exactly on 0.7"
    StepEq (Get-SteppedNumber -Current 19.95 -Direction 1 -Field Tolerance -Ctrl $true) 20.0 "tol 19.95 + 0.1 clamps to 20"
}

Check "Get-SteppedNumber rejects direction 0 and an unknown field" {
    # Positive control first: a missing function would also "throw" below.
    StepEq (Get-SteppedNumber -Current 0 -Direction 1 -Field Zoom) 10.0 "control call works"
    $threw = $false
    try { Get-SteppedNumber -Current 0 -Direction 0 -Field Zoom } catch { $threw = $true }
    if (-not $threw) { throw "expected Direction 0 to be rejected" }
    $threw = $false
    try { Get-SteppedNumber -Current 0 -Direction 1 -Field Bogus } catch { $threw = $true }
    if (-not $threw) { throw "expected an unknown field to be rejected" }
}

Check "Get-SteppedTolerance Auto rule: start from Auto's effective value (1.0 if none) THEN step; Down at 0 stays 0" {
    # No Auto value known: start at 1.0, then step.
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct $null -Direction 1) 2.0 "auto/none Up"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct $null -Direction -1) 0.0 "auto/none Down"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct $null -Direction 1 -Shift $true) 11.0 "auto/none Shift+Up"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct $null -Direction 1 -Ctrl $true) 1.1 "auto/none Ctrl+Up"
    # Auto has a known effective value (percent): seed from it (1 decimal), then step.
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 3.14159 -Direction 1) 4.1 "auto/3.14159 Up"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 3.14159 -Direction -1) 2.1 "auto/3.14159 Down"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 0.0 -Direction -1) 0.0 "auto/0 Down stays 0"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 0.0 -Direction 1) 1.0 "auto/0 Up"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 35.0 -Direction 1) 20.0 "auto/35 (out of range) clamps"
    StepEq (Get-SteppedTolerance -CurrentPct $null -AutoEffectivePct 35.0 -Direction -1) 19.0 "auto/35 Down starts from the clamped 20"
    # A real current value always wins over the Auto value.
    StepEq (Get-SteppedTolerance -CurrentPct 5.0 -AutoEffectivePct 3.14159 -Direction 1) 6.0 "manual 5 ignores Auto's value"
    StepEq (Get-SteppedTolerance -CurrentPct 0.0 -AutoEffectivePct 3.14159 -Direction -1) 0.0 "manual 0 Down stays 0 (a typed 0 is not Auto)"
    StepEq (Get-SteppedTolerance -CurrentPct 0.0 -AutoEffectivePct 3.14159 -Direction 1) 1.0 "manual 0 Up (a typed 0 is not Auto)"
}

Check "Get-SteppedFrameText: whole-number text steps (1 / Shift 10 / Ctrl 1), no lower limit; non-numeric text -> `$null (do nothing)" {
    if ((Get-SteppedFrameText -Text "5" -Direction 1 -Field StartFrame) -ne "6") { throw "5 up" }
    if ((Get-SteppedFrameText -Text "5" -Direction -1 -Field EndFrame) -ne "4") { throw "5 down" }
    if ((Get-SteppedFrameText -Text "5" -Direction 1 -Field StartFrame -Shift $true) -ne "15") { throw "5 shift up" }
    if ((Get-SteppedFrameText -Text "5" -Direction 1 -Field StartFrame -Ctrl $true) -ne "6") { throw "5 ctrl up" }
    if ((Get-SteppedFrameText -Text "5" -Direction 1 -Field StartFrame -Shift $true -Ctrl $true) -ne "6") { throw "5 shift+ctrl up: Ctrl wins" }
    if ((Get-SteppedFrameText -Text "0" -Direction -1 -Field StartFrame) -ne "-1") { throw "0 down must go negative (no lower limit), got '$(Get-SteppedFrameText -Text '0' -Direction -1 -Field StartFrame)'" }
    if ((Get-SteppedFrameText -Text "-995" -Direction -1 -Field EndFrame -Shift $true) -ne "-1005") { throw "-995 shift down" }
    if ((Get-SteppedFrameText -Text " 7 " -Direction 1 -Field StartFrame) -ne "8") { throw "padded ' 7 ' parses like Start Recording's own int parse" }
    foreach ($bad in @("", "abc", "5.5", "1e3", "--3", "  ", "12x")) {
        if ($null -ne (Get-SteppedFrameText -Text $bad -Direction 1 -Field StartFrame)) { throw "non-numeric text '$bad' must give `$null (do nothing)" }
    }
    if ((Get-SteppedFrameText -Text "2147483647" -Direction 1 -Field EndFrame) -ne "2147483647") { throw "int32 max must not overflow into text Start Recording cannot parse" }
    if ((Get-SteppedFrameText -Text "-2147483648" -Direction -1 -Field EndFrame) -ne "-2147483648") { throw "int32 min must not overflow into text Start Recording cannot parse" }
}

# --- Tolerance visual + estimate range (task48 rebuild, 2026-10-12) ---------
function Near($actual, [double]$expected, [string]$what, [double]$tol = 1e-6) {
    if ($null -eq $actual -or [Math]::Abs([double]$actual - $expected) -gt $tol) { throw "$what`: expected $expected, got '$actual'" }
}

Check "ConvertFrom-FiniteNumberText: numbers parse like TryParse; NaN / Infinity / garbage -> `$null (F4)" {
    Near (ConvertFrom-FiniteNumberText -Text "5") 5 "5"
    Near (ConvertFrom-FiniteNumberText -Text " -7.5 ") -7.5 "padded -7.5"
    foreach ($bad in @("NaN", "Infinity", "-Infinity", "abc", "", $null, "1e999")) {
        if ($null -ne (ConvertFrom-FiniteNumberText -Text $bad)) { throw "'$bad' must give `$null" }
    }
}

Check "Get-AutoTolFromZoom: (1 - 0.96/(1 - zoom))/2 floored at 0 (gate ON); fixed 2.0 with the gate OFF; NaN zoom -> `$null (F1)" {
    Near (Get-AutoTolFromZoom -ZoomPct 0) 2.0 "zoom 0"
    Near (Get-AutoTolFromZoom -ZoomPct -50) 18.0 "zoom -50"
    Near (Get-AutoTolFromZoom -ZoomPct -20) 10.0 "zoom -20"
    Near (Get-AutoTolFromZoom -ZoomPct -10) (100 * (1 - 0.96 / 1.1) / 2) "zoom -10"
    Near (Get-AutoTolFromZoom -ZoomPct 2) (100 * (1 - 0.96 / 0.98) / 2) "zoom +2"
    Near (Get-AutoTolFromZoom -ZoomPct 4) 0.0 "zoom +4"
    Near (Get-AutoTolFromZoom -ZoomPct 10) 0.0 "zoom +10 floors at 0"
    Near (Get-AutoTolFromZoom -ZoomPct 100) 0.0 "zoom 100 (no frame left)"
    foreach ($z in @(-50, 0, 20, 50)) { Near (Get-AutoTolFromZoom -ZoomPct $z -GateOn $false) 2.0 "gate OFF zoom $z" }
    if ($null -ne (Get-AutoTolFromZoom -ZoomPct ([double]::NaN))) { throw "NaN zoom must give `$null" }
    # Same number as the cache-based form the launcher's readout uses (max_w cancels out).
    foreach ($z in @(-35, -5, 1, 3)) {
        $maxW = 173.0
        $finalOrtho = ($maxW / (1.0 - 2.0 * 0.02)) * 1.02 * (1.0 - $z / 100.0)
        $cacheForm = 100.0 * [Math]::Max(0.0, (1.0 - ($maxW * 1.02 / $finalOrtho)) / 2.0)
        Near (Get-AutoTolFromZoom -ZoomPct $z) $cacheForm "zoom $z vs the cache-based formula" 1e-9
    }
}

Check "Get-ToleranceVisualGeometry / Get-ToleranceMarginPx: frame = a fifth, centred; LINEAR 10x scale (4.48 px per % at 224 px), clamped 0..20" {
    $g = Get-ToleranceVisualGeometry -CanvasWidth 224
    Near $g.FrameWidth 44.8 "frame width"
    Near $g.CenterX 112 "centre"
    Near $g.PxPerPct 4.48 "px per %"
    Near $g.Magnification 10 "magnification"
    $cases = @(@(0.5, 2.24), @(2, 8.96), @(5, 22.4), @(10, 44.8), @(20, 89.6), @(25, 89.6), @(0, 0), @(-3, 0))
    foreach ($c in $cases) { Near (Get-ToleranceMarginPx -Pct $c[0] -PxPerPct $g.PxPerPct) $c[1] "margin $($c[0])%" }
    Near (Get-ToleranceMarginPx -Pct ([double]::NaN) -PxPerPct 4.48) 0 "NaN margin"
    # 20 % on one side reaches the canvas edge exactly.
    Near ($g.CenterX + $g.FrameWidth / 2 + (Get-ToleranceMarginPx -Pct 20 -PxPerPct $g.PxPerPct)) 224 "20% reaches the right edge"
}

Check "Get-ToleranceBandSplit (W5): used = min(worst, T), slack = T - used, over = min(worst,20) - T; compared at 1 decimal; no worst -> all solid" {
    $s = Get-ToleranceBandSplit -TolerancePct 10 -WorstPct 6.3
    Near $s.UsedPct 6.3 "lt used"; Near $s.SlackPct 3.7 "lt slack" 1e-9; Near $s.OverPct 0 "lt over"
    if ($s.IsOver -or -not $s.HasWorst) { throw "lt must not be over" }
    $s = Get-ToleranceBandSplit -TolerancePct 2 -WorstPct 2.0
    Near $s.UsedPct 2 "eq used"; Near $s.SlackPct 0 "eq slack"; if ($s.IsOver) { throw "eq must not be over" }
    $s = Get-ToleranceBandSplit -TolerancePct 2 -WorstPct 2.04
    if ($s.IsOver) { throw "2.04 shows as 2.0 in the Estimated line: must not be a red over" }
    $s = Get-ToleranceBandSplit -TolerancePct 2 -WorstPct 2.06
    if (-not $s.IsOver) { throw "2.06 shows as 2.1: must be over" }
    $s = Get-ToleranceBandSplit -TolerancePct 2 -WorstPct 12
    Near $s.UsedPct 2 "gt used"; Near $s.SlackPct 0 "gt slack"; Near $s.OverPct 10 "gt over"; if (-not $s.IsOver) { throw "gt must be over" }
    $s = Get-ToleranceBandSplit -TolerancePct 2 -WorstPct 25
    Near $s.OverPct 18 "over is drawn only up to the 20 % edge"; if (-not $s.IsOver) { throw "25 > 2 must be over" }
    $s = Get-ToleranceBandSplit -TolerancePct 5 -WorstPct $null
    if ($s.HasWorst -or $s.IsOver) { throw "no worst: no marker, no over" }
    Near $s.UsedPct 5 "no worst: whole margin solid"; Near $s.SlackPct 0 "no worst: no slack"
    $s = Get-ToleranceBandSplit -TolerancePct 0 -WorstPct 0
    Near $s.UsedPct 0 "T0 used"; if ($s.IsOver) { throw "0 vs 0 is not over" }
}

Check "Get-EstimateRange: All = whole cache; Start/End parsed like Start Recording; Time Slider = last resolved or unknown; outside / reversed / garbage -> unknown with a reason" {
    [double[]]$fr = 10..19
    $r = Get-EstimateRange -Mode All -Frames $fr
    if (-not $r.Known -or $r.StartIndex -ne 0 -or $r.EndIndex -ne 9) { throw "All must be indices 0..9, got $($r.StartIndex)..$($r.EndIndex)" }
    $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText "12" -EndText "15"
    if (-not $r.Known -or $r.StartIndex -ne 2 -or $r.EndIndex -ne 5 -or $r.StartFrame -ne 12 -or $r.EndFrame -ne 15) { throw "12-15 must be indices 2..5, got $($r.StartIndex)..$($r.EndIndex)" }
    $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText " 5 " -EndText "12"
    if (-not $r.Known -or $r.StartIndex -ne 0 -or $r.EndIndex -ne 2) { throw "5-12 (partly before the cache) must clip to indices 0..2, got $($r.StartIndex)..$($r.EndIndex)" }
    $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText "15" -EndText "12"
    if ($r.Known -or $r.Reason -ne "Start is after End") { throw "reversed range must be unknown ('Start is after End'), got '$($r.Reason)'" }
    foreach ($bad in @(@("a", "12"), @("12", ""), @("1.5", "12"))) {
        $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText $bad[0] -EndText $bad[1]
        if ($r.Known -or $r.Reason -ne "Start/End must be whole numbers") { throw "'$($bad[0])'/'$($bad[1])' must be unknown (whole numbers), got '$($r.Reason)'" }
    }
    $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText "30" -EndText "40"
    if ($r.Known -or $r.Reason -notmatch "outside the cached take") { throw "30-40 must be unknown (outside), got '$($r.Reason)'" }
    $r = Get-EstimateRange -Mode TimeSlider -Frames $fr
    if ($r.Known -or $r.Reason -notmatch "Time Slider range unknown") { throw "Time Slider with nothing resolved yet must be unknown, got '$($r.Reason)'" }
    $r = Get-EstimateRange -Mode TimeSlider -Frames $fr -LastTimeSliderStart 11 -LastTimeSliderEnd 13 -StartText "junk"
    if (-not $r.Known -or $r.StartIndex -ne 1 -or $r.EndIndex -ne 3) { throw "Time Slider 11-13 must be indices 1..3 (boxes ignored), got $($r.StartIndex)..$($r.EndIndex)" }
    $r = Get-EstimateRange -Mode All -Frames @()
    if ($r.Known -or $r.Reason -ne "no cache yet") { throw "no frames must be unknown ('no cache yet'), got '$($r.Reason)'" }
    $r = Get-EstimateRange -Mode StartEnd -Frames $fr -StartText "13" -EndText "13"
    if (-not $r.Known -or $r.StartIndex -ne 3 -or $r.EndIndex -ne 3) { throw "a single frame must be a valid range" }
}

Check "Format-EstimateReadoutText: the bar's rounding rule (half away from zero) at a midpoint; the existing text format is kept" {
    $t = Format-EstimateReadoutText -Keys 70 -OverPct 0.25 -WorstPct 2.25
    if ($t -ne "Estimated: 70 keys, 0.3% of frames over tolerance, worst 2.3% of frame width.") { throw "midpoints round away from zero: got '$t'" }
    if (-not (Get-ToleranceBandSplit -TolerancePct 2.2 -WorstPct 2.25).IsOver) { throw "the bar draws 2.25 vs 2.2 as over, so the text must say 2.3" }
    $t = Format-EstimateReadoutText -Keys 3 -OverPct 0 -WorstPct 2.0
    if ($t -ne "Estimated: 3 keys, 0% of frames over tolerance, worst 2% of frame width.") { throw "format unchanged ('2%', not '2.0%'): got '$t'" }
    $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
        if ((Format-EstimateReadoutText -Keys 1 -OverPct 1.25 -WorstPct 15.75) -ne "Estimated: 1 keys, 1.3% of frames over tolerance, worst 15.8% of frame width.") { throw "invariant numbers under de-DE" }
    } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
}

Check "Get-EstimatePendingText: the user-approved 'no estimate' wording; other reasons shown as-is" {
    $want = "Estimated: -- (open Preview once to see keys and worst overshoot)"
    if ((Get-EstimatePendingText) -ne $want) { throw "no reason" }
    if ((Get-EstimatePendingText -Reason "no cache yet") -ne $want) { throw "no cache" }
    if ((Get-EstimatePendingText -Reason "Start is after End") -ne "Estimated: -- (Start is after End)") { throw "reason passthrough" }
}

Check "Get-ToleranceTooltipText: truthful parts per state; tight-value sentence only with the gate ON; numbers invariant (de-DE safe)" {
    $on = Get-ToleranceTooltipText -GateOn $true -Auto $true -TolPct 2.0 -WorstPct 6.25 -RangeText "frames 0-120"
    foreach ($part in @("blue = the allowed margin", "camera reacts LESS", "Margin shown magnified 10x", "Frame gate ON", "Auto (dashed outline, A) = 2.0%", "worst 6.3% of the frame width over frames 0-120", "Very small values (0-2%)", "Mouse wheel here steps")) {
        if ($on.IndexOf($part) -lt 0) { throw "gate-ON Auto tooltip lacks '$part'" }
    }
    $off = Get-ToleranceTooltipText -GateOn $false -Auto $true -TolPct 2.0 -WorstPct $null -PendingReason "no cache yet"
    if ($off.IndexOf("Frame gate OFF") -lt 0 -or $off.IndexOf("fixed 2.0% warning threshold") -lt 0 -or $off.IndexOf("No estimate yet (open Preview once)") -lt 0) { throw "gate-OFF tooltip parts missing: $off" }
    if ($off.IndexOf("Very small values") -ge 0) { throw "the tight-value (camera busyness) sentence must not appear with the gate OFF" }
    $man = Get-ToleranceTooltipText -GateOn $true -Auto $false -TolPct 7.25
    if ($man.IndexOf("Manual: 7.3%") -lt 0) { throw "manual value missing: $man" }
    $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
        $de = Get-ToleranceTooltipText -GateOn $true -Auto $false -TolPct 7.25 -WorstPct 6.25
        if ($de.IndexOf("Manual: 7.3%") -lt 0 -or $de.IndexOf("worst 6.3%") -lt 0) { throw "de-DE must still show '7.3' / '6.3': $de" }
    } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
}

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

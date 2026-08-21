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

Check "Get-StopCleanupSteps stops Maya playback, restores taskbar, stops OBS -- in that order" {
    $steps = Get-StopCleanupSteps -ScriptDir $ScriptDir
    if ($steps.Count -ne 3) { throw "expected 3 cleanup steps, got $($steps.Count)" }
    if (-not (ArgsHave $steps[0].Arguments "maya_stop_playback.py")) { throw "step 0 should stop Maya playback" }
    if (-not (ArgsHave $steps[0].Arguments "send_to_maya.ps1")) { throw "step 0 should route through send_to_maya.ps1, same as every other Maya-touching step" }
    if (-not (ArgsHave $steps[1].Arguments "taskbar_control.ps1")) { throw "step 1 should touch the taskbar" }
    if (-not (ArgsHave $steps[1].Arguments "show")) { throw "step 1 should SHOW the taskbar, not hide it" }
    if (-not (ArgsHave $steps[2].Arguments "obs_control.ps1")) { throw "step 2 should touch OBS" }
    if (-not (ArgsHave $steps[2].Arguments "stop")) { throw "step 2 should STOP OBS recording, not start it" }
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

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

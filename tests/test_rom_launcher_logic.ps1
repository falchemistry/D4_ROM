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

Check "a frame range on Run Only is silently irrelevant -- Run Only never touches maya_obs_capture.ps1" {
    $steps = Get-CaptureSteps -Axis "FrontBack" -Recording $false -ScriptDir $ScriptDir -StartFrame 0 -EndFrame 100
    foreach ($s in $steps) {
        if (ArgsHave $s.Arguments "maya_obs_capture") { throw "Run Only should never invoke maya_obs_capture.ps1, range or not" }
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

Check "Get-PortSnippetContent returns null for a missing file, not an exception" {
    # ScriptDir\..\open_maya_port.py must genuinely not exist for this path --
    # a wrong "does_not_exist" subfolder under d4_rom would still resolve up
    # to the REAL d4_rom\open_maya_port.py via Split-Path -Parent
    $content = Get-PortSnippetContent -ScriptDir "D:\__backup\claude\nonexistent_project_xyz\scripts"
    if ($content -ne $null) { throw "expected null when open_maya_port.py doesn't exist at the derived path" }
}

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

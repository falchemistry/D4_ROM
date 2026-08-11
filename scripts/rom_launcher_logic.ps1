# Pure step-sequencing logic for the ROM launcher UI (rom_launcher.ps1).
# No WPF, no process launching, no side effects -- safe to dot-source from
# tests/test_rom_launcher_logic.ps1 without ever showing a window or
# touching Maya/OBS. Mirrors the mayapy-logic-test split used throughout
# the MayaShelves project: keep decision logic separate from anything that
# needs a real window/widget so it stays fast and safe to test.
#
# Every step sequence here is a direct transcription of the existing,
# already-proven .bat files (run_front_back.bat, run_left_right.bat,
# capture_front_back.bat, capture_left_right.bat) -- the launcher should
# behave identically to double-clicking those, just from a UI instead.

function Get-CaptureSteps {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight")]
        [string]$Axis,
        [Parameter(Mandatory=$true)][bool]$Recording,
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        # Both optional, both-or-neither (same contract as
        # maya_obs_capture.ps1's own params) -- only meaningful when
        # $Recording is true; "Run Only" never touches maya_obs_capture.ps1
        # at all, so a range has nothing to apply to there.
        [Nullable[int]]$StartFrame = $null,
        [Nullable[int]]$EndFrame = $null
    )

    if (($StartFrame -eq $null) -ne ($EndFrame -eq $null)) {
        throw "StartFrame and EndFrame must both be given, or neither."
    }

    $panelsScript = if ($Axis -eq "FrontBack") { "maya_camera_panels.py" } else { "maya_camera_panels_LR.py" }
    $keyScript = if ($Axis -eq "FrontBack") { "maya_key_from_cache.py" } else { "maya_key_from_cache_LR.py" }

    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $taskbarControl = Join-Path $ScriptDir "taskbar_control.ps1"
    $obsCapture = Join-Path $ScriptDir "maya_obs_capture.ps1"

    $steps = @()

    if ($Recording) {
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "hide") }
    }

    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", (Join-Path $ScriptDir $panelsScript)) }
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", (Join-Path $ScriptDir $keyScript)) }

    if ($Recording) {
        # matches "ping -n 3 127.0.0.1 > nul" in the capture_*.bat files --
        # a short pause before the OBS/playback sequence starts
        $steps += [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "3", "127.0.0.1") }
        $obsArgs = @("-ExecutionPolicy", "Bypass", "-File", $obsCapture)
        if ($StartFrame -ne $null) {
            $obsArgs += @("-StartFrame", "$StartFrame", "-EndFrame", "$EndFrame")
        }
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = $obsArgs }
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "show") }
    }

    return $steps
}

function Get-CleanResetStep {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )

    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $cleanReset = Join-Path $ScriptDir "maya_clean_reset.py"

    # comma operator, not just @(...): PowerShell unwraps a single-element
    # array back to a scalar when a function returns it via `return`,
    # which broke callers expecting to always get an array back
    return ,@([PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", $cleanReset) })
}

function Get-PortSnippetContent {
    # Reads open_maya_port.py fresh every call rather than embedding a copy
    # of its text here -- single source of truth, so editing the .py file
    # is the only place this content needs to change.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    $snippetPath = Join-Path (Split-Path $ScriptDir -Parent) "open_maya_port.py"
    if (-not (Test-Path $snippetPath)) {
        return $null
    }
    return Get-Content $snippetPath -Raw
}

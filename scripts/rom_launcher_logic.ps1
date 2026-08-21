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
        # $Recording is true; "Preview" never touches maya_obs_capture.ps1
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

function Get-StopCleanupSteps {
    # Run after killing the currently-active step process. Process.Kill()
    # bypasses .NET/PowerShell `finally` blocks entirely (confirmed by
    # reading maya_obs_capture.ps1 -- its taskbar-restore/OBS-stop cleanup
    # lives in a `finally` that never runs if the process is terminated
    # externally rather than exiting on its own), so a hard stop mid-capture
    # would otherwise leave the taskbar hidden and OBS still recording.
    # Reuses the same standalone, already-proven utility scripts
    # maya_obs_capture.ps1 itself calls internally, rather than duplicating
    # their logic here.
    #
    # KNOWN GAP: if a custom sample frame range was set for this capture,
    # the ORIGINAL range (saved inside maya_obs_capture.ps1's own local
    # variable) is lost when that process is killed -- this cleanup does
    # not attempt to restore it. Only maya_obs_capture.ps1 finishing
    # naturally restores a custom range correctly.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )

    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $stopPlayback = Join-Path $ScriptDir "maya_stop_playback.py"
    $taskbarControl = Join-Path $ScriptDir "taskbar_control.ps1"
    $obsControl = Join-Path $ScriptDir "obs_control.ps1"

    $steps = @()
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", $stopPlayback) }
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "show") }
    # obs_control.ps1 has $ErrorActionPreference = "Stop" and errors if OBS
    # isn't actually recording (e.g. Stop was clicked before recording
    # started, or after it already finished) -- run it as its own process
    # regardless (a failing child process here just logs [stderr]/a
    # nonzero exit code, same as any other step, and does not abort the
    # rest of this cleanup sequence, since each step in the queue always
    # runs independently of the previous step's exit code).
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $obsControl, "-Action", "stop") }
    return $steps
}

function Get-NoteworthyMayaOutput {
    # Filters a "quick check" subprocess's raw stdout down to whatever is
    # actually worth a log line. Deliberately does NOT surface the routine
    # success case: Maya's command port only relays an exception's text
    # back over the socket (confirmed live 2026-08-22 -- print() output
    # never crosses it), so a script that completes normally without
    # raising leaves $Stdout containing only send_to_maya.ps1's own
    # generic "Sent to Maya command port..." line -- filtered out on
    # purpose here, since that RESULT is already reflected in the UI
    # (status dot/label) and re-logging it on every routine check would
    # be noise, not signal. What survives filtering is exactly the
    # interesting cases: a relayed exception's text, or a
    # "No response from Maya within Xms" timeout notice. Returns "" (not
    # $null) when there's nothing noteworthy, so callers can just check
    # truthiness.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Stdout
    )
    $lines = $Stdout -split "`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch "^Sent to Maya command port" }
    return ($lines -join ' ')
}

function ConvertFrom-CacheProgressOutput {
    # Parses _cache_build_progress.txt's key=value lines (written by
    # maya_cache_bbox.py) into a structured result -- kept separate from
    # the WPF polling code so this can be unit-tested directly.
    #
    # IsComplete is true once Done >= Total: maya_cache_bbox.py writes
    # that exact state (note=done or note=no_motion_detected) the moment
    # frame sampling itself finishes, well before the run's remaining
    # steps (e.g. the post-cache clean reset) actually exit. Callers
    # should hide the progress UI right here, not wait for the whole run
    # to finish, or it sits frozen at 100% for however long those later
    # steps take.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Lines
    )
    $data = @{}
    foreach ($line in $Lines) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $data[$parts[0]] = $parts[1] }
    }
    $done = 0
    $total = 1
    $percent = 0.0
    [void][int]::TryParse($data['frames_done'], [ref]$done)
    [void][int]::TryParse($data['frames_total'], [ref]$total)
    [void][double]::TryParse($data['percent'], [ref]$percent)
    return [PSCustomObject]@{
        Done = $done
        Total = $total
        Percent = $percent
        IsComplete = ($total -gt 0 -and $done -ge $total)
        Label = "Building animation cache: $done / $total frames ($($percent.ToString('0.0'))%) -- one time only, future runs reuse this"
    }
}

function ConvertFrom-CacheCheckOutput {
    # Parses maya_check_cache.py's stdout (relayed back through
    # send_to_maya.ps1's now-working response read) into a structured
    # result -- kept separate from the live process-launching code so this
    # parsing logic can be unit-tested without a real Maya connection.
    # Expected lines look like:
    #   CACHE_EXISTS animation_reference=D:/.../barM_rom_anim.ma cache_path=D:/.../barM__abc123.json
    #   CACHE_MISSING animation_reference=... cache_path=...
    #   CACHE_NO_REFERENCE <message>
    #   CACHE_CHECK_ERROR <message>
    # Anything else (empty output, a hung/no-response case, an unrelated
    # send_to_maya.ps1 log line) is reported as Status "Unknown" rather
    # than guessing.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $line = ($Output -split "`n" | Where-Object { $_ -match "^CACHE_(EXISTS|MISSING|NO_REFERENCE|CHECK_ERROR)" } | Select-Object -First 1)
    if (-not $line) {
        return [PSCustomObject]@{ Status = "Unknown"; AnimationReference = $null; CachePath = $null; ErrorMessage = $null }
    }
    $line = $line.Trim()

    if ($line -match "^CACHE_CHECK_ERROR\s+(.*)$") {
        return [PSCustomObject]@{ Status = "Error"; AnimationReference = $null; CachePath = $null; ErrorMessage = $Matches[1] }
    }
    if ($line -match "^CACHE_NO_REFERENCE\s+(.*)$") {
        # A DIFFERENT case from Error above: not a failure, the expected
        # result of the wrong scene being loaded (or nothing referenced in
        # yet) -- ConvertFrom-CacheCheckOutput's caller routes this to the
        # Maya-connection indicator as a "wrong scene" warning, not a
        # generic check-failed error.
        return [PSCustomObject]@{ Status = "NoReference"; AnimationReference = $null; CachePath = $null; ErrorMessage = $Matches[1] }
    }

    $status = if ($line -match "^CACHE_EXISTS") { "Exists" } else { "Missing" }
    $animRef = $null
    $cachePath = $null
    if ($line -match "animation_reference=(\S+)") { $animRef = $Matches[1] }
    if ($line -match "cache_path=(\S+)") { $cachePath = $Matches[1] }
    return [PSCustomObject]@{ Status = $status; AnimationReference = $animRef; CachePath = $cachePath; ErrorMessage = $null }
}

function ConvertFrom-TimeSliderOutput {
    # Same split-purpose reasoning as ConvertFrom-CacheCheckOutput: parses
    # maya_get_time_slider.py's result-file content, kept separate from
    # the live process-launching code so it is unit-testable without a
    # real Maya connection. Expected lines:
    #   TIME_RANGE min=0 max=3240
    #   TIME_RANGE_ERROR <message>
    # Anything else (empty, unrelated, a hung/no-response case) is
    # reported as Success=$false with a generic ErrorMessage rather than
    # guessing.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $line = ($Output -split "`n" | Where-Object { $_ -match "^TIME_RANGE" } | Select-Object -First 1)
    if (-not $line) {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "No response from Maya." }
    }
    $line = $line.Trim()

    if ($line -match "^TIME_RANGE_ERROR\s+(.*)$") {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = $Matches[1] }
    }
    if ($line -match "^TIME_RANGE min=(-?\d+) max=(-?\d+)") {
        return [PSCustomObject]@{ Success = $true; Start = [int]$Matches[1]; End = [int]$Matches[2]; ErrorMessage = $null }
    }
    return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Unrecognized response: $line" }
}

function ConvertFrom-AnimationRangeOutput {
    # Same split-purpose reasoning as ConvertFrom-TimeSliderOutput, for
    # maya_get_animation_range.py's result instead -- the outer
    # animationStartTime/animationEndTime bounds (what "All" now
    # explicitly captures), not the Range Slider's current minTime/maxTime.
    # Expected lines:
    #   ANIM_RANGE min=0 max=3240
    #   ANIM_RANGE_ERROR <message>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $line = ($Output -split "`n" | Where-Object { $_ -match "^ANIM_RANGE" } | Select-Object -First 1)
    if (-not $line) {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "No response from Maya." }
    }
    $line = $line.Trim()

    if ($line -match "^ANIM_RANGE_ERROR\s+(.*)$") {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = $Matches[1] }
    }
    if ($line -match "^ANIM_RANGE min=(-?\d+) max=(-?\d+)") {
        return [PSCustomObject]@{ Success = $true; Start = [int]$Matches[1]; End = [int]$Matches[2]; ErrorMessage = $null }
    }
    return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Unrecognized response: $line" }
}

function ConvertFrom-ObsConfigContent {
    # Parses obs_config.txt's content (same "host:/port:/password:" format
    # obs_control.ps1 itself reads) into a structured status -- kept
    # separate from file I/O so it is unit-testable without touching disk.
    # A password that is missing, empty, or still the literal placeholder
    # written by build_dist.ps1's template counts as NOT configured.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content
    )
    $password = ""
    if ($Content -match "password:\s*(\S+)") { $password = $Matches[1] }
    $configured = [bool]($password -and $password -ne "REPLACE_ME")
    return [PSCustomObject]@{ Configured = $configured; CurrentPassword = $password }
}

function Set-ObsConfigPassword {
    # Preserves the existing host:/port:/password: file's other lines
    # (comments, host, port) when one already exists -- only the password
    # value itself is replaced. Writes a fresh, fully-templated file only
    # when no config file exists yet at all.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$NewPassword
    )
    if (-not $ExistingContent) {
        return @"
OBS WebSocket connection info for d4_rom capture automation.

host: 127.0.0.1
port: 4455
password: $NewPassword

Set under OBS > Tools > WebSocket Server Settings on this machine. If this
ever needs to change, update it there and here together -- the capture
scripts read the password from this file.
"@
    }
    if ($ExistingContent -match "password:\s*\S+") {
        return $ExistingContent -replace "password:\s*\S+", "password: $NewPassword"
    }
    return $ExistingContent.TrimEnd() + "`r`npassword: $NewPassword`r`n"
}

function ConvertFrom-ObsMonitorListOutput {
    # Parses obs_monitor.ps1 -Action list's stdout into a structured
    # result -- kept separate from the live process-launching code so this
    # parsing logic can be unit-tested without a real OBS connection.
    # Expected lines:
    #   MONITOR_ITEM name="Display Name" value="raw_monitor_id" current="true|false"
    #   MONITOR_SOURCE_NOT_FOUND
    #   MONITOR_LIST_ERROR <message>
    # One line per monitor when successful; empty/unrelated output is
    # reported as Success=$false rather than guessing.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $lines = $Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not $lines -or $lines.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "No response." }
    }

    $errorLine = $lines | Where-Object { $_ -match "^MONITOR_LIST_ERROR\s+(.*)$" } | Select-Object -First 1
    if ($errorLine) {
        $errorLine -match "^MONITOR_LIST_ERROR\s+(.*)$" | Out-Null
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = $Matches[1] }
    }
    if ($lines | Where-Object { $_ -match "^MONITOR_SOURCE_NOT_FOUND" }) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "No enabled monitor-capture source found in OBS's active scene." }
    }

    $monitors = @()
    foreach ($line in $lines) {
        if ($line -match 'MONITOR_ITEM name="(.*)" value="(.*)" current="(true|false)"') {
            $monitors += [PSCustomObject]@{ Name = $Matches[1]; Value = $Matches[2]; IsCurrent = ($Matches[3] -eq "true") }
        }
    }
    if ($monitors.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "Unrecognized response: $($lines -join ' | ')" }
    }
    return [PSCustomObject]@{ Success = $true; Monitors = $monitors; ErrorMessage = $null }
}

function ConvertFrom-ObsMonitorSetOutput {
    # Parses obs_monitor.ps1 -Action set's stdout (2026-08-22 rework) into
    # a structured result -- separate from the live process-launching code
    # for the same reason as ConvertFrom-ObsMonitorListOutput. Expected
    # lines on success:
    #   MONITOR_SET_OK
    #   MONITOR_SET_VERIFIED true|false
    #   MONITOR_SET_BRIGHTNESS <number>
    #   MONITOR_SET_MESSAGE <text, possibly containing spaces>
    #   MONITOR_SET_PREVIEW <path>
    # or MONITOR_SET_ERROR <message> if the whole operation failed.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $lines = $Output -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ }
    if (-not $lines -or $lines.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Verified = $false; Brightness = $null; Message = "No response."; PreviewPath = $null }
    }

    $errorLine = $lines | Where-Object { $_ -match "^MONITOR_SET_ERROR\s+(.*)$" } | Select-Object -First 1
    if ($errorLine) {
        $errorLine -match "^MONITOR_SET_ERROR\s+(.*)$" | Out-Null
        return [PSCustomObject]@{ Success = $false; Verified = $false; Brightness = $null; Message = $Matches[1]; PreviewPath = $null }
    }
    if (-not ($lines | Where-Object { $_ -match "^MONITOR_SET_OK" })) {
        return [PSCustomObject]@{ Success = $false; Verified = $false; Brightness = $null; Message = "Unrecognized response: $($lines -join ' | ')"; PreviewPath = $null }
    }

    $verifiedLine = $lines | Where-Object { $_ -match "^MONITOR_SET_VERIFIED\s+(true|false)" } | Select-Object -First 1
    $verified = $verifiedLine -and ($Matches[1] -eq "true")
    $brightnessLine = $lines | Where-Object { $_ -match "^MONITOR_SET_BRIGHTNESS\s+([\d.]+)" } | Select-Object -First 1
    $brightness = if ($brightnessLine) { [double]$Matches[1] } else { $null }
    $messageLine = $lines | Where-Object { $_ -match "^MONITOR_SET_MESSAGE\s+(.*)$" } | Select-Object -First 1
    $message = if ($messageLine) { $messageLine -replace "^MONITOR_SET_MESSAGE\s+", "" } else { $null }
    $previewLine = $lines | Where-Object { $_ -match "^MONITOR_SET_PREVIEW\s+(.*)$" } | Select-Object -First 1
    $previewPath = if ($previewLine) { $previewLine -replace "^MONITOR_SET_PREVIEW\s+", "" } else { $null }

    return [PSCustomObject]@{ Success = $true; Verified = $verified; Brightness = $brightness; Message = $message; PreviewPath = $previewPath }
}

function ConvertFrom-ObsMonitorName {
    # Extracts (X, Y, Width, Height) directly out of an OBS monitor item's
    # own display Name string -- e.g. "Artist22R Pro: 1920x1080 @ 0,0
    # (Primary Monitor)" or "LG FHD: 1920x1080 @ 1920,0". OBS already
    # includes the monitor's Windows virtual-desktop position/size in this
    # exact human-readable format (confirmed live against a real OBS
    # instance), so this is enough to drive maya_camera_panels.py's own
    # SECONDARY_MONITOR_RECT without any extra Windows API call or a
    # second source of truth to keep in sync -- OBS's monitor_id string
    # itself has no usable position info, only this Name does.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Name
    )
    if ($Name -match '(-?\d+)x(-?\d+)\s*@\s*(-?\d+),(-?\d+)') {
        $width = [int]$Matches[1]
        $height = [int]$Matches[2]
        $x = [int]$Matches[3]
        $y = [int]$Matches[4]
        return [PSCustomObject]@{ Success = $true; Left = $x; Top = $y; Right = ($x + $width); Bottom = ($y + $height) }
    }
    return [PSCustomObject]@{ Success = $false; Left = $null; Top = $null; Right = $null; Bottom = $null }
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

function Get-StartRecordingRequirementFailures {
    # Pure decision logic for the Start Recording pre-flight gate: given
    # the current state of the three hard requirements, returns the list
    # of human-readable failure messages, or an empty array if everything
    # is satisfied. None of these three are things a recording could
    # succeed without, so this is a hard block, not a dismissible warning
    # (design confirmed 2026-08-22). Kept separate from the live status
    # checks (Test-MayaPortReachable, Get-ObsPasswordStatus,
    # Test-RecordingMonitorSelected) so this can be unit-tested without a
    # real Maya/OBS connection.
    param(
        [Parameter(Mandatory=$true)][bool]$MayaReachable,
        [Parameter(Mandatory=$true)][bool]$ObsPasswordConfigured,
        [Parameter(Mandatory=$true)][bool]$MonitorSelected
    )
    $failures = @()
    if (-not $MayaReachable) {
        $failures += "Maya connection: NOT reachable -- paste open_maya_port.py into Maya's Script Editor (Python tab) and run it."
    }
    if (-not $ObsPasswordConfigured) {
        $failures += "OBS WebSocket: not configured -- open the Settings tab and set this machine's OBS WebSocket password."
    }
    if (-not $MonitorSelected) {
        $failures += "Recording Monitor: not selected -- open the Settings tab and choose a Recording Monitor (OBS must be running)."
    }
    # comma operator: PowerShell can unwrap a 0- or 1-element array to
    # $null/a scalar across a function return (same footgun
    # Get-CleanResetStep's own header comment documents) -- this keeps
    # $failures a real array for every caller, regardless of how many
    # requirements failed.
    return ,$failures
}

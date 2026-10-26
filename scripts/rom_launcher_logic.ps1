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

# --- Tool file locations (T99) ---------------------------------------------
# The ONE place that knows which category folder under scripts\ each tool
# file lives in. "" = scripts\ itself. Every caller passes the scripts\ root
# as -ScriptDir. maya_obs_capture.ps1 (a separate child process) dot-sources
# this file for the same lookup.
function Get-ToolPathTable {
    return @{
        "rom_launcher.ps1" = ""
        "rom_launcher_logic.ps1" = ""
        "maya_cache_bbox.py" = "maya"
        "maya_camera_live_nudge.py" = "maya"
        "maya_camera_live_zoom.py" = "maya"
        "maya_camera_panels.py" = "maya"
        "maya_camera_panels_LR.py" = "maya"
        "maya_check_cache.py" = "maya"
        "maya_clean_reset.py" = "maya"
        "maya_debug_inspect.py" = "maya"
        "maya_get_animation_range.py" = "maya"
        "maya_get_scene_name.py" = "maya"
        "maya_get_time_slider.py" = "maya"
        "maya_key_from_cache.py" = "maya"
        "maya_key_from_cache_LR.py" = "maya"
        "maya_restore_hud.py" = "maya"
        "maya_stop_playback.py" = "maya"
        "send_to_maya.ps1" = "maya"
        "maya_run_hook.py" = "hooks"
        "maya_obs_capture.ps1" = "capture"
        "taskbar_control.ps1" = "capture"
        "obs_control.ps1" = "obs"
        "obs_monitor.ps1" = "obs"
        "_fps_state.txt" = "state"
        "_frame_range_state.txt" = "state"
        "_playback_state.txt" = "state"
        "_hud_state.json" = "state"
        "_hook_context.json" = "state"
        "_last_video.txt" = "state"
    }
}

function Get-ToolStateDir {
    # scripts\state\ holds the transient files each capture rewrites. A
    # fresh dist has no such folder, so it is created on first use.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    $dir = Join-Path $ScriptDir "state"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-ToolPath {
    # Full path of a tool file by its file name. Throws on a name the table
    # does not know, so a missed path shows up loudly instead of pointing at
    # a file that is not there.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $table = Get-ToolPathTable
    if (-not $table.ContainsKey($Name)) {
        throw "Get-ToolPath: unknown tool file '$Name'"
    }
    $sub = $table[$Name]
    if ($sub -eq "state") { return Join-Path (Get-ToolStateDir -ScriptDir $ScriptDir) $Name }
    if ($sub) { return Join-Path (Join-Path $ScriptDir $sub) $Name }
    return Join-Path $ScriptDir $Name
}

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
        [Nullable[int]]$EndFrame = $null,
        # T97 pre/post recording scripts. A path is only passed for a user
        # file that has code (see Get-ActiveHookPaths); "" / $null = no
        # step at all, so the default list stays exactly what it was.
        # Recording only -- Preview never runs them.
        [string]$PreHookPath = "",
        [string]$PostHookPath = "",
        [string]$HookContextPath = "",
        # Which video of the run this is (All = 0 then 1), handed to the
        # user's script as D4_CTX['leg_index'].
        [int]$LegIndex = 0,
        # T87 video file name prefix (the Prefix box). Sanitized here again
        # (Get-SafePrefix is idempotent); an empty result adds nothing, so
        # the step list stays exactly what it was. Recording only.
        [string]$NamePrefix = ""
    )

    if (($StartFrame -eq $null) -ne ($EndFrame -eq $null)) {
        throw "StartFrame and EndFrame must both be given, or neither."
    }
    $safePrefix = Get-SafePrefix -Prefix $NamePrefix

    $preHookStep = $null
    $postHookStep = $null
    if ($Recording -and ($PreHookPath -or $PostHookPath)) {
        if (-not $HookContextPath) { $HookContextPath = Get-ToolPath -ScriptDir $ScriptDir -Name "_hook_context.json" }
        if ($PreHookPath) { $preHookStep = New-HookStep -ScriptDir $ScriptDir -Kind "pre" -UserPath $PreHookPath -ContextPath $HookContextPath -LegIndex $LegIndex -LegAxis $Axis }
        if ($PostHookPath) { $postHookStep = New-HookStep -ScriptDir $ScriptDir -Kind "post" -UserPath $PostHookPath -ContextPath $HookContextPath -LegIndex $LegIndex -LegAxis $Axis }
    }

    $panelsScript = if ($Axis -eq "FrontBack") { "maya_camera_panels.py" } else { "maya_camera_panels_LR.py" }
    $keyScript = if ($Axis -eq "FrontBack") { "maya_key_from_cache.py" } else { "maya_key_from_cache_LR.py" }

    $sendToMaya = Get-ToolPath -ScriptDir $ScriptDir -Name "send_to_maya.ps1"
    $taskbarControl = Get-ToolPath -ScriptDir $ScriptDir -Name "taskbar_control.ps1"
    $obsCapture = Get-ToolPath -ScriptDir $ScriptDir -Name "maya_obs_capture.ps1"

    $steps = @()

    if ($Recording) {
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "hide") }
    }

    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", (Get-ToolPath -ScriptDir $ScriptDir -Name $panelsScript)) }
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", (Get-ToolPath -ScriptDir $ScriptDir -Name $keyScript)) }

    if ($Recording) {
        # matches "ping -n 3 127.0.0.1 > nul" in the capture_*.bat files --
        # a short pause before the OBS/playback sequence starts
        $steps += [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "3", "127.0.0.1") }
        # T97: the user's pre-record script runs right before OBS starts
        # (panels and keys are ready), the post-record script right after
        # OBS stops, before the taskbar comes back.
        if ($preHookStep) { $steps += $preHookStep }
        $obsArgs = @("-ExecutionPolicy", "Bypass", "-File", $obsCapture)
        if ($StartFrame -ne $null) {
            $obsArgs += @("-StartFrame", "$StartFrame", "-EndFrame", "$EndFrame")
        }
        # T87: the capture script renames this leg's video right after OBS
        # stops. A safe prefix has no whitespace, quote or leading '-', so
        # it needs no quoting and is never read as a switch.
        if ($safePrefix) {
            $obsArgs += @("-NamePrefix", $safePrefix, "-LegAxis", $Axis)
        }
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = $obsArgs }
        if ($postHookStep) { $steps += $postHookStep }
        $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "show") }
    }

    return $steps
}

function Get-CaptureStepsForAxis {
    # Thin wrapper around Get-CaptureSteps that adds the "All" axis choice:
    # Front/Back immediately followed by Left/Right, as two independent
    # step sequences concatenated back to back. Each Get-CaptureSteps call
    # is already fully self-contained when $Recording is true (its own
    # taskbar hide/show and its own maya_obs_capture.ps1 start/stop), so
    # concatenating two of them is exactly two independent OBS record
    # cycles -- i.e. two video files -- with zero new orchestration code.
    # This mirrors the concatenation pattern already proven in
    # tests\test_rom_launcher_logic.ps1 ("every step uses -ExecutionPolicy
    # Bypass" builds $allSteps the same way). Get-CaptureSteps itself is
    # deliberately left untouched (still only "FrontBack"/"LeftRight") so
    # none of its existing callers or tests change behavior.
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")]
        [string]$Axis,
        [Parameter(Mandatory=$true)][bool]$Recording,
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [Nullable[int]]$StartFrame = $null,
        [Nullable[int]]$EndFrame = $null,
        # T97 hooks, passed through to every leg (All = each runs twice).
        [string]$PreHookPath = "",
        [string]$PostHookPath = "",
        [string]$HookContextPath = "",
        # T87: one prefix for every leg (read once at the click); each leg
        # adds its own suffix (_front_back / _left_right).
        [string]$NamePrefix = ""
    )

    if ($Axis -ne "All") {
        return Get-CaptureSteps -Axis $Axis -Recording $Recording -ScriptDir $ScriptDir -StartFrame $StartFrame -EndFrame $EndFrame -PreHookPath $PreHookPath -PostHookPath $PostHookPath -HookContextPath $HookContextPath -LegIndex 0 -NamePrefix $NamePrefix
    }

    $steps = @()
    $steps += Get-CaptureSteps -Axis "FrontBack" -Recording $Recording -ScriptDir $ScriptDir -StartFrame $StartFrame -EndFrame $EndFrame -PreHookPath $PreHookPath -PostHookPath $PostHookPath -HookContextPath $HookContextPath -LegIndex 0 -NamePrefix $NamePrefix
    $steps += Get-CaptureSteps -Axis "LeftRight" -Recording $Recording -ScriptDir $ScriptDir -StartFrame $StartFrame -EndFrame $EndFrame -PreHookPath $PreHookPath -PostHookPath $PostHookPath -HookContextPath $HookContextPath -LegIndex 1 -NamePrefix $NamePrefix
    return $steps
}

function Get-PreviewAxis {
    # Which axis Preview actually runs for the selected Axis radio.
    # User decision (2026-09-24, option b): with "All" selected, Preview
    # shows ONLY the first leg (Front/Back). Reason: every panel script
    # closes ALL four known claude_view_* windows on startup
    # (ALL_KNOWN_VIEWS is shared by maya_camera_panels.py and _LR.py), so
    # the two panel sets can never coexist -- an "All" preview would just
    # open Front/Back and then immediately replace it with Left/Right,
    # leaving the artist looking at the LAST leg only. Start Recording and
    # the cache build keep using the real axis (All = both legs); only
    # Preview goes through this.
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")]
        [string]$Axis
    )
    if ($Axis -eq "All") { return "FrontBack" }
    return $Axis
}

function Get-CleanResetStep {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )

    $sendToMaya = Get-ToolPath -ScriptDir $ScriptDir -Name "send_to_maya.ps1"
    $cleanReset = Get-ToolPath -ScriptDir $ScriptDir -Name "maya_clean_reset.py"

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
    #
    # HUD restore (task17, 2026-09-30) does NOT share that gap: unlike the
    # frame range, Get-MayaHudState persists its saved snapshot to
    # _hud_state.json on disk BEFORE maya_obs_capture.ps1 mutates anything,
    # specifically so this step can recover it after a kill -- see
    # maya_restore_hud.py, which reads that file and is a safe no-op if it
    # doesn't exist (e.g. Stop clicked with no active capture).
    #
    # T97: -PostHookStep is the current video's post-record step when its
    # pre-record script already started (see Update-PendingPostHook); it
    # runs last, after OBS has stopped. $null (the default) = the list is
    # exactly what it always was.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        $PostHookStep = $null
    )

    $sendToMaya = Get-ToolPath -ScriptDir $ScriptDir -Name "send_to_maya.ps1"
    $stopPlayback = Get-ToolPath -ScriptDir $ScriptDir -Name "maya_stop_playback.py"
    $restoreHud = Get-ToolPath -ScriptDir $ScriptDir -Name "maya_restore_hud.py"
    $taskbarControl = Get-ToolPath -ScriptDir $ScriptDir -Name "taskbar_control.ps1"
    $obsControl = Get-ToolPath -ScriptDir $ScriptDir -Name "obs_control.ps1"

    $steps = @()
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", $stopPlayback) }
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-ScriptPath", $restoreHud) }
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $taskbarControl, "-Action", "show") }
    # obs_control.ps1 has $ErrorActionPreference = "Stop" and errors if OBS
    # isn't actually recording (e.g. Stop was clicked before recording
    # started, or after it already finished) -- run it as its own process
    # regardless (a failing child process here just logs [stderr]/a
    # nonzero exit code, same as any other step, and does not abort the
    # rest of this cleanup sequence, since each step in the queue always
    # runs independently of the previous step's exit code).
    $steps += [PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-ExecutionPolicy", "Bypass", "-File", $obsControl, "-Action", "stop") }
    if ($PostHookStep) { $steps += $PostHookStep }
    return $steps
}

# --- Pre/post recording scripts (T97) -------------------------------------
# The user's own d4_rom_pre_record.py / d4_rom_post_record.py live in
# <install root>\user_hooks\ (install root = the parent of scripts\), never
# in the zip; the zip ships comment-only templates in scripts\hooks\templates
# that Initialize-HookFiles copies there on first use, never overwriting.
# scripts\hooks\maya_run_hook.py runs a user file inside Maya.

function Get-HookFileNames {
    return @("d4_rom_pre_record.py", "d4_rom_post_record.py")
}

function Get-HookPaths {
    # Where everything lives. Creates nothing.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    $installRoot = Split-Path ([IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')) -Parent
    $userDir = Join-Path $installRoot "user_hooks"
    # templates\ sits next to the runner, so the resolver table stays the
    # one place that knows the hooks folder name
    $templateDir = Join-Path (Split-Path (Get-ToolPath -ScriptDir $ScriptDir -Name "maya_run_hook.py") -Parent) "templates"
    return [PSCustomObject]@{
        InstallRoot = $installRoot
        UserDir = $userDir
        TemplateDir = $templateDir
        Pre = Join-Path $userDir "d4_rom_pre_record.py"
        Post = Join-Path $userDir "d4_rom_post_record.py"
        PreTemplate = Join-Path $templateDir "d4_rom_pre_record.py"
        PostTemplate = Join-Path $templateDir "d4_rom_post_record.py"
    }
}

function Get-HookState {
    # "missing" (no file / unreadable), "empty" (only blank lines and lines
    # whose first non-blank character is '#': nothing runs) or "code".
    # Same rule as hook_source_has_code in maya_run_hook.py.
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "missing" }
    try {
        $lines = [IO.File]::ReadAllLines($Path)
    } catch {
        return "missing"
    }
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#")) { return "code" }
    }
    return "empty"
}

function Get-HookIndicator {
    # Status dot + tooltip for the Settings row. Amber (a file is missing)
    # wins over green (at least one has code) wins over gray (both empty:
    # nothing runs).
    param(
        [Parameter(Mandatory=$true)][string]$PreState,
        [Parameter(Mandatory=$true)][string]$PostState
    )
    $describe = @{
        "missing" = "missing"
        "empty" = "empty (nothing runs)"
        "code" = "has code (runs every video)"
    }
    $color = "gray"
    if ($PreState -eq "code" -or $PostState -eq "code") { $color = "green" }
    if ($PreState -eq "missing" -or $PostState -eq "missing") { $color = "amber" }
    $text = "Pre-record script: $($describe[$PreState])`nPost-record script: $($describe[$PostState])"
    if ($color -eq "gray") { $text += "`nBoth are empty, so nothing runs. Click to open the folder and edit them." }
    elseif ($color -eq "amber") { $text += "`nClick to recreate a missing file and open the folder." }
    else { $text += "`nClick to open the folder." }
    return [PSCustomObject]@{ Color = $color; Text = $text }
}

function Get-ActiveHookPaths {
    # The user files that will actually run (have code). A missing file is
    # skipped with one log line; an empty one is skipped silently.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    $p = Get-HookPaths -ScriptDir $ScriptDir
    $result = [PSCustomObject]@{ Pre = $null; Post = $null; Log = @() }
    foreach ($kind in @("Pre", "Post")) {
        $path = $p.$kind
        $state = Get-HookState -Path $path
        if ($state -eq "code") { $result.$kind = $path }
        elseif ($state -eq "missing") { $result.Log += "$($kind.ToLower())-record script not found, skipped: $path" }
    }
    return $result
}

function Get-HookStepCode {
    # The one-line Python payload send_to_maya.ps1 -Code sends: execs the
    # runner in its own dict with the call's arguments as globals.
    # send_to_maya passes no script arguments, and under -ScriptPath a
    # wrapper file has no __file__ to find the runner from, so the
    # arguments travel here. One line, no double quotes (Start-NextStep
    # wraps whitespace arguments in "..."). Paths are raw strings; a path
    # with an apostrophe is sent hex-encoded instead (ConvertTo-PyPathLiteral).
    param(
        [Parameter(Mandatory=$true)][string]$RunnerPath,
        [Parameter(Mandatory=$true)][ValidateSet("pre", "post")][string]$Kind,
        [Parameter(Mandatory=$true)][string]$UserPath,
        [Parameter(Mandatory=$true)][string]$ContextPath,
        [int]$LegIndex = 0,
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight")][string]$LegAxis,
        # Unique per hook step: Maya's command port executes every payload
        # twice, and maya_run_hook.py runs the user's file only for the
        # first execution of a given id (claim_run_id).
        [Parameter(Mandatory=$true)][string]$RunId
    )
    foreach ($p in @($RunnerPath, $UserPath, $ContextPath)) {
        if ($p -match "[`"\r\n]" -or $p.EndsWith("\")) {
            throw "Pre/post recording script path cannot contain a double quote, a line break or end with '\': $p"
        }
    }
    if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw "Hook run id must be letters, digits, '-' or '_': $RunId" }
    $runner = ConvertTo-PyPathLiteral $RunnerPath
    $user = ConvertTo-PyPathLiteral $UserPath
    $context = ConvertTo-PyPathLiteral $ContextPath
    return "exec(compile(open($runner).read(), $runner, 'exec'), {'__name__': 'd4_rom_hook_runner', 'D4_HOOK_KIND': '$Kind', 'D4_HOOK_USER_PATH': $user, 'D4_HOOK_CONTEXT_PATH': $context, 'D4_HOOK_LEG_INDEX': $LegIndex, 'D4_HOOK_LEG_AXIS': '$LegAxis', 'D4_HOOK_RUN_ID': '$RunId'})"
}

function ConvertTo-PyPathLiteral {
    # A Python expression for a path, safe inside the one-line payload: a
    # readable raw string normally; with an apostrophe (which would end a
    # raw string, and cannot be backslash-escaped in one) the UTF-8 bytes
    # are hex-encoded -- bytearray.fromhex works in Python 2 and 3 and
    # needs no quotes but its own single ones.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not $Path.Contains("'")) { return "r'$Path'" }
    $hex = -join ([Text.Encoding]::UTF8.GetBytes($Path) | ForEach-Object { $_.ToString("x2") })
    return "bytearray.fromhex('$hex').decode('utf-8')"
}

function New-HookRunId {
    # kind-leg-<guid>: different for every hook step ever built, so each
    # video's pre and post call (and every new recording run) gets its own.
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [int]$LegIndex = 0
    )
    return "$Kind-$LegIndex-" + [guid]::NewGuid().ToString("N")
}

function New-HookStep {
    # A queue step that runs one user hook in Maya. HookKind/LegIndex are
    # extra properties the launcher reads (Update-PendingPostHook); the
    # step runner only uses FilePath/Arguments. 5 minute timeout: a user
    # script is expected to be short, unlike a cache build.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [Parameter(Mandatory=$true)][ValidateSet("pre", "post")][string]$Kind,
        [Parameter(Mandatory=$true)][string]$UserPath,
        [Parameter(Mandatory=$true)][string]$ContextPath,
        [int]$LegIndex = 0,
        [Parameter(Mandatory=$true)][string]$LegAxis
    )
    $sendToMaya = Get-ToolPath -ScriptDir $ScriptDir -Name "send_to_maya.ps1"
    $runner = Get-ToolPath -ScriptDir $ScriptDir -Name "maya_run_hook.py"
    $runId = New-HookRunId -Kind $Kind -LegIndex $LegIndex
    $code = Get-HookStepCode -RunnerPath $runner -Kind $Kind -UserPath $UserPath -ContextPath $ContextPath -LegIndex $LegIndex -LegAxis $LegAxis -RunId $runId
    return [PSCustomObject]@{
        FilePath = "powershell"
        Arguments = @("-ExecutionPolicy", "Bypass", "-File", $sendToMaya, "-Code", $code, "-TimeoutMs", "300000")
        HookKind = $Kind
        LegIndex = $LegIndex
        RunId = $runId
    }
}

function Get-CaptureStepsWithHooks {
    # Start Recording's step list with the user's pre/post scripts. Any
    # error while preparing them (context file, a path the payload cannot
    # carry, ...) never stops the recording silently: the run gets the
    # plain steps, Error holds the reason and Log a line naming it.
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")][string]$Axis,
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [Nullable[int]]$StartFrame = $null,
        [Nullable[int]]$EndFrame = $null,
        [Parameter(Mandatory=$true)][string]$ToolVersion,
        # T87 video name prefix, passed to every leg ("" = OBS's own names)
        [string]$NamePrefix = ""
    )
    $log = @()
    $err = $null
    try {
        $hooks = Get-ActiveHookPaths -ScriptDir $ScriptDir
        $log += @($hooks.Log)
        $contextPath = ""
        if ($hooks.Pre -or $hooks.Post) {
            $contextPath = Write-HookContext -ScriptDir $ScriptDir -Axis $Axis -StartFrame $StartFrame -EndFrame $EndFrame -ToolVersion $ToolVersion
        }
        $steps = @(Get-CaptureStepsForAxis -Axis $Axis -Recording $true -ScriptDir $ScriptDir -StartFrame $StartFrame -EndFrame $EndFrame -PreHookPath $hooks.Pre -PostHookPath $hooks.Post -HookContextPath $contextPath -NamePrefix $NamePrefix)
        if ($hooks.Pre) { $log += "Pre-record script runs before each video: $($hooks.Pre)" }
        if ($hooks.Post) { $log += "Post-record script runs after each video: $($hooks.Post)" }
    } catch {
        $err = $_.Exception.Message
        $log += "Pre-Post Recording: scripts NOT run for this recording -- $err"
        $steps = @(Get-CaptureStepsForAxis -Axis $Axis -Recording $true -ScriptDir $ScriptDir -StartFrame $StartFrame -EndFrame $EndFrame -NamePrefix $NamePrefix)
    }
    return [PSCustomObject]@{ Steps = $steps; Log = $log; Error = $err }
}

function Update-PendingPostHook {
    # Which post-record step a Stop click must still run. Called as each
    # step STARTS: a PRE step arms its own video's POST step (the next POST
    # after it, if that video has one), a POST step disarms (it is already
    # running in Maya), anything else keeps the current value. So POST runs
    # on Stop only when its PRE ran, and never twice.
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Steps,
        [Parameter(Mandatory=$true)][int]$StartedIndex,
        $Pending = $null
    )
    if ($StartedIndex -lt 0 -or $StartedIndex -ge $Steps.Count) { return $Pending }
    $step = $Steps[$StartedIndex]
    $kind = if ($step.PSObject.Properties["HookKind"]) { $step.HookKind } else { $null }
    if ($kind -eq "post") { return $null }
    if ($kind -ne "pre") { return $Pending }
    for ($i = $StartedIndex + 1; $i -lt $Steps.Count; $i++) {
        $s = $Steps[$i]
        if (-not $s.PSObject.Properties["HookKind"]) { continue }
        if ($s.HookKind -eq "pre") { break }
        if ($s.HookKind -eq "post" -and $s.LegIndex -eq $step.LegIndex) { return $s }
    }
    return $null
}

function Initialize-HookFiles {
    # Creates <install root>\user_hooks\ and copies each template there
    # whose user file does not exist yet. NEVER overwrites an existing
    # file. Safe to call every launch and every click. Returns what it
    # created and which templates were missing; throws only if the folder
    # itself cannot be created.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    $p = Get-HookPaths -ScriptDir $ScriptDir
    $result = [PSCustomObject]@{ UserDir = $p.UserDir; Created = @(); MissingTemplates = @(); Errors = @() }
    if (-not (Test-Path -LiteralPath $p.UserDir -PathType Container)) {
        New-Item -ItemType Directory -Path $p.UserDir -Force | Out-Null
    }
    foreach ($name in Get-HookFileNames) {
        $target = Join-Path $p.UserDir $name
        if (Test-Path -LiteralPath $target) { continue }
        $template = Join-Path $p.TemplateDir $name
        if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
            $result.MissingTemplates += $template
            continue
        }
        try {
            # overwrite=$false: a file appearing in between is never replaced
            [IO.File]::Copy($template, $target, $false)
            $result.Created += $target
        } catch {
            $result.Errors += "${name}: $($_.Exception.Message)"
        }
    }
    return $result
}

function Open-HookFolder {
    # Shows the folder in Explorer. Kept as its own function so tests can
    # replace it and never start Explorer.
    param(
        [Parameter(Mandatory=$true)][string]$Folder
    )
    Start-Process -FilePath "explorer.exe" -ArgumentList ('"' + $Folder + '"')
}

function Invoke-HookFolderButton {
    # The Settings row's button: make sure the files exist, then open the
    # folder. Returns Status "opened", "template_missing" (Message = notice
    # text naming the exact template path; nothing is opened) or
    # "explorer_failed"/"init_failed" (Message = a log line). Never throws.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir
    )
    try {
        $init = Initialize-HookFiles -ScriptDir $ScriptDir
    } catch {
        return [PSCustomObject]@{ Status = "init_failed"; Message = "Could not create the pre/post recording folder: $($_.Exception.Message)"; Folder = $null }
    }
    if (@($init.Errors).Count) {
        $msg = "The pre/post recording script could not be created:`n`n" + (@($init.Errors) -join "`n") + "`n`nCheck that the folder is writable and the file is not open elsewhere, then try again."
        return [PSCustomObject]@{ Status = "init_failed"; Message = $msg; Folder = $init.UserDir }
    }
    if (@($init.MissingTemplates).Count) {
        $msg = "The pre/post recording template is missing, so the script file could not be created:`n`n" + (@($init.MissingTemplates) -join "`n") + "`n`nReinstall the tool (or restore that file) and try again."
        return [PSCustomObject]@{ Status = "template_missing"; Message = $msg; Folder = $init.UserDir }
    }
    try {
        Open-HookFolder -Folder $init.UserDir
    } catch {
        return [PSCustomObject]@{ Status = "explorer_failed"; Message = "Could not open $($init.UserDir) in Explorer: $($_.Exception.Message)"; Folder = $init.UserDir }
    }
    return [PSCustomObject]@{ Status = "opened"; Message = $null; Folder = $init.UserDir }
}

function ConvertTo-AsciiJsonString {
    # A JSON string literal using only ASCII: every non-ASCII character is
    # written as \uXXXX, so the file can be written as ASCII without
    # turning a user's folder name into '?'.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return "null" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 0x20 -or $code -gt 0x7E) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-HookContext {
    # Writes scripts\state\_hook_context.json (ASCII, no BOM) once before a
    # recording run; maya_run_hook.py turns it into D4_CTX and adds the
    # per-call kind, leg_index and leg_axis. Returns the file path.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")][string]$Axis,
        [Nullable[int]]$StartFrame = $null,
        [Nullable[int]]$EndFrame = $null,
        [Parameter(Mandatory=$true)][string]$ToolVersion
    )
    $path = Get-ToolPath -ScriptDir $ScriptDir -Name "_hook_context.json"
    $stateDir = Split-Path $path -Parent
    $legCount = if ($Axis -eq "All") { 2 } else { 1 }
    $sf = if ($StartFrame -eq $null) { "null" } else { "$StartFrame" }
    $ef = if ($EndFrame -eq $null) { "null" } else { "$EndFrame" }
    $fullScripts = [IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')
    $lines = @(
        "{",
        "  `"axis`": $(ConvertTo-AsciiJsonString $Axis),",
        "  `"leg_count`": $legCount,",
        "  `"start_frame`": $sf,",
        "  `"end_frame`": $ef,",
        "  `"tool_version`": $(ConvertTo-AsciiJsonString $ToolVersion),",
        "  `"scripts_dir`": $(ConvertTo-AsciiJsonString $fullScripts),",
        "  `"state_dir`": $(ConvertTo-AsciiJsonString $stateDir)",
        "}"
    )
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.ASCIIEncoding))
    return $path
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
    #   MONITOR_LIST_AUTH_FAILED <message> -- OBS reachable, wrong password
    # One line per monitor when successful; empty/unrelated output is
    # reported as Success=$false rather than guessing. AuthFailed is
    # $true ONLY for the AUTH_FAILED case -- callers (the OBS WebSocket
    # password status dot) use it to distinguish "confirmed wrong
    # password" from every other kind of failure (OBS not running, no
    # capture source, etc), which all just mean "can't verify right now."
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output
    )

    $lines = $Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not $lines -or $lines.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "No response."; AuthFailed = $false }
    }

    $authFailedLine = $lines | Where-Object { $_ -match "^MONITOR_LIST_AUTH_FAILED\s+(.*)$" } | Select-Object -First 1
    if ($authFailedLine) {
        $authFailedLine -match "^MONITOR_LIST_AUTH_FAILED\s+(.*)$" | Out-Null
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = $Matches[1]; AuthFailed = $true }
    }
    $errorLine = $lines | Where-Object { $_ -match "^MONITOR_LIST_ERROR\s+(.*)$" } | Select-Object -First 1
    if ($errorLine) {
        $errorLine -match "^MONITOR_LIST_ERROR\s+(.*)$" | Out-Null
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = $Matches[1]; AuthFailed = $false }
    }
    if ($lines | Where-Object { $_ -match "^MONITOR_SOURCE_NOT_FOUND" }) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "No enabled monitor-capture source found in OBS's active scene."; AuthFailed = $false }
    }

    $monitors = @()
    foreach ($line in $lines) {
        if ($line -match 'MONITOR_ITEM name="(.*)" value="(.*)" current="(true|false)"') {
            $monitors += [PSCustomObject]@{ Name = $Matches[1]; Value = $Matches[2]; IsCurrent = ($Matches[3] -eq "true") }
        }
    }
    if ($monitors.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Monitors = @(); ErrorMessage = "Unrecognized response: $($lines -join ' | ')"; AuthFailed = $false }
    }
    return [PSCustomObject]@{ Success = $true; Monitors = $monitors; ErrorMessage = $null; AuthFailed = $false }
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

# --- Arrow / wheel stepping for the numeric boxes (task48, 2026-10-07) ----
# Pure functions, no WPF: the step table, the clamped/drift-free step, and
# the Tolerance Auto rule live here so they are hermetically testable; the
# launcher's handlers only read the key/modifier state and call these.
#
# Step table (user-approved 2026-10-07), plain / Shift / Ctrl:
#   Zoom       10 / 100 / 1    range -50..50 (Shift's 100 simply clamps)
#   OffsetX/Y  10 / 100 / 1    unbounded
#   Tolerance   1 /  10 / 0.1  range 0..20, 1 decimal
#   Start/End   1 /  10 / 1    no practical limit (whole int32 range, the
#                              limit of the int parse Start Recording does)
# Both modifiers held: Ctrl (the finest step) wins.
function Get-NumericFieldSpec {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Zoom", "OffsetX", "OffsetY", "Tolerance", "StartFrame", "EndFrame")]
        [string]$Field
    )
    switch ($Field) {
        "Zoom"       { return [PSCustomObject]@{ Plain = 10.0; Shift = 100.0; Ctrl = 1.0; Min = -50.0; Max = 50.0; Decimals = 0 } }
        "OffsetX"    { return [PSCustomObject]@{ Plain = 10.0; Shift = 100.0; Ctrl = 1.0; Min = $null; Max = $null; Decimals = 0 } }
        "OffsetY"    { return [PSCustomObject]@{ Plain = 10.0; Shift = 100.0; Ctrl = 1.0; Min = $null; Max = $null; Decimals = 0 } }
        "Tolerance"  { return [PSCustomObject]@{ Plain = 1.0; Shift = 10.0; Ctrl = 0.1; Min = 0.0; Max = 20.0; Decimals = 1 } }
        "StartFrame" { return [PSCustomObject]@{ Plain = 1.0; Shift = 10.0; Ctrl = 1.0; Min = [double][int]::MinValue; Max = [double][int]::MaxValue; Decimals = 0 } }
        "EndFrame"   { return [PSCustomObject]@{ Plain = 1.0; Shift = 10.0; Ctrl = 1.0; Min = [double][int]::MinValue; Max = [double][int]::MaxValue; Decimals = 0 } }
    }
}

# The step size for the given modifier state (Ctrl wins over Shift).
function Get-NumericStepSize {
    param(
        [Parameter(Mandatory=$true)][string]$Field,
        [bool]$Shift = $false,
        [bool]$Ctrl = $false
    )
    $spec = Get-NumericFieldSpec -Field $Field
    if ($Ctrl) { return [double]$spec.Ctrl }
    if ($Shift) { return [double]$spec.Shift }
    return [double]$spec.Plain
}

# One clamped step from $Current. Rounds to the field's own decimals after
# the add so repeated 0.1 steps never show float drift (0.30000000000000004),
# then clamps to the field's range ($null Min/Max = unbounded on that side).
function Get-SteppedNumber {
    param(
        [Parameter(Mandatory=$true)][double]$Current,
        [Parameter(Mandatory=$true)][ValidateSet(-1, 1)][int]$Direction,
        [Parameter(Mandatory=$true)][string]$Field,
        [bool]$Shift = $false,
        [bool]$Ctrl = $false
    )
    $spec = Get-NumericFieldSpec -Field $Field
    $step = Get-NumericStepSize -Field $Field -Shift $Shift -Ctrl $Ctrl
    $value = [Math]::Round($Current + ($Direction * $step), [int]$spec.Decimals, [MidpointRounding]::AwayFromZero)
    if ($null -ne $spec.Min -and $value -lt $spec.Min) { $value = [double]$spec.Min }
    if ($null -ne $spec.Max -and $value -gt $spec.Max) { $value = [double]$spec.Max }
    return $value
}

# Tolerance step with the Auto rule (user decision 2026-10-07): from Auto
# ($CurrentPct = $null) start from Auto's current effective value in percent
# ($AutoEffectivePct, rounded to the field's 1 decimal and clamped to 0..20),
# or 1.0 if Auto has no known value ($null), THEN step. Down at 0 stays 0
# (clamp); there is no wrap back to Auto -- clearing the box is the way back.
function Get-SteppedTolerance {
    param(
        $CurrentPct = $null,
        $AutoEffectivePct = $null,
        [Parameter(Mandatory=$true)][ValidateSet(-1, 1)][int]$Direction,
        [bool]$Shift = $false,
        [bool]$Ctrl = $false
    )
    $spec = Get-NumericFieldSpec -Field "Tolerance"
    if ($null -ne $CurrentPct) {
        $start = [double]$CurrentPct
    } elseif ($null -ne $AutoEffectivePct) {
        $start = [Math]::Round([Math]::Max([double]$spec.Min, [Math]::Min([double]$spec.Max, [double]$AutoEffectivePct)), [int]$spec.Decimals, [MidpointRounding]::AwayFromZero)
    } else {
        $start = 1.0
    }
    return (Get-SteppedNumber -Current $start -Direction $Direction -Field "Tolerance" -Shift $Shift -Ctrl $Ctrl)
}

# Start/End frame text step. Returns the new whole-number text, or $null when
# the text is not a whole number (Up/Down then do nothing; the existing Start
# Recording check still complains about it). Same int parse Start Recording
# uses, so "what steps" and "what is accepted" cannot disagree.
function Get-SteppedFrameText {
    param(
        [string]$Text,
        [Parameter(Mandatory=$true)][ValidateSet(-1, 1)][int]$Direction,
        [Parameter(Mandatory=$true)][ValidateSet("StartFrame", "EndFrame")][string]$Field,
        [bool]$Shift = $false,
        [bool]$Ctrl = $false
    )
    $parsed = 0
    if (-not [int]::TryParse($Text, [ref]$parsed)) { return $null }
    $stepped = Get-SteppedNumber -Current ([double]$parsed) -Direction $Direction -Field $Field -Shift $Shift -Ctrl $Ctrl
    return ([int]$stepped).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# Typed number for the Zoom / X / Y / Tolerance boxes (task48 F4): the same
# [double]::TryParse the commits always used, but "NaN" / "Infinity" (which
# TryParse happily accepts) count as garbage too, so they revert like any
# other unparseable text instead of reaching the slider or a state file.
# Returns the number, or $null for "not a usable number".
function ConvertFrom-FiniteNumberText {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $value = 0.0
    if (-not [double]::TryParse($Text, [ref]$value)) { return $null }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
    return $value
}

# --- Tolerance visual (task48 rebuild, 2026-10-12) ---------------------------
# Auto tolerance in percent, from Zoom alone (task48 F1 + the visual's dashed
# Auto mark). Gate ON: maya_camera_panels.py compute_effective_overflow_pct
# with offset 0 (how the keyer is really called), where max_w cancels out:
# (1 - 0.96 / (1 - zoom/100)) / 2, floored at 0 -- 2.0 at zoom 0, 0 from about
# +4 on, 18.0 at -50. No cache needed. Gate OFF: Auto is the fixed 2.0
# clipping-warning threshold (Get-ClippingWarningThresholdPct). Non-finite
# zoom -> $null (unknown, never a guessed number).
function Get-AutoTolFromZoom {
    param(
        [Parameter(Mandatory=$true)][double]$ZoomPct,
        [bool]$GateOn = $true
    )
    if (-not $GateOn) { return 2.0 }
    if ([double]::IsNaN($ZoomPct) -or [double]::IsInfinity($ZoomPct)) { return $null }
    $remaining = 1.0 - $ZoomPct / 100.0
    if ($remaining -le 0) { return 0.0 }
    return ([Math]::Max(0.0, (1.0 - 0.96 / $remaining) / 2.0) * 100.0)
}

# Diagram geometry (user decision 10b): the grey frame is 100 % of the frame
# width drawn as a fifth of the canvas, centred; the allowed margin is drawn on
# a LINEAR scale magnified so 20 % reaches the canvas edge (exactly 10x for a
# fifth). Px per percent per side = ((canvas - frame) / 2) / 20.
function Get-ToleranceVisualGeometry {
    param([Parameter(Mandatory=$true)][double]$CanvasWidth)
    $frameW = $CanvasWidth / 5.0
    $pxPerPct = (($CanvasWidth - $frameW) / 2.0) / 20.0
    return [PSCustomObject]@{
        CanvasWidth = $CanvasWidth; CenterX = ($CanvasWidth / 2.0); FrameWidth = $frameW
        PxPerPct = $pxPerPct; Magnification = ($pxPerPct / ($frameW / 100.0))
    }
}

# Pixel width of a margin of $Pct percent on one side: clamped to the 0..20
# drawing range; NaN / negative -> 0.
function Get-ToleranceMarginPx {
    param([double]$Pct, [Parameter(Mandatory=$true)][double]$PxPerPct)
    if ([double]::IsNaN($Pct) -or $Pct -le 0) { return 0.0 }
    return ([Math]::Min(20.0, $Pct) * $PxPerPct)
}

# W5 split band (user decision): of the allowed margin T, SOLID = the part the
# animation actually uses (up to the worst overshoot Y), SLACK = the unused
# rest, OVER = how far Y goes past T (drawn red with "!"). Compared at the 1
# decimal the Estimated line shows, so "worst 2.0%" against a 2 % tolerance is
# used-exactly, never a float-noise red. No estimate ($WorstPct $null): the
# whole margin draws solid, no slack, no over (no worst marker).
function Get-ToleranceBandSplit {
    param(
        [Parameter(Mandatory=$true)][double]$TolerancePct,
        $WorstPct = $null
    )
    $t = [Math]::Round([Math]::Max(0.0, $TolerancePct), 1, [MidpointRounding]::AwayFromZero)
    if ($null -eq $WorstPct -or [double]::IsNaN([double]$WorstPct)) {
        return [PSCustomObject]@{ HasWorst = $false; UsedPct = $t; SlackPct = 0.0; OverPct = 0.0; IsOver = $false }
    }
    $y = [Math]::Round([Math]::Max(0.0, [double]$WorstPct), 1, [MidpointRounding]::AwayFromZero)
    $used = [Math]::Min($y, $t)
    return [PSCustomObject]@{
        HasWorst = $true
        UsedPct = $used
        SlackPct = ($t - $used)
        OverPct = [Math]::Max(0.0, [Math]::Min(20.0, $y) - $t)
        IsOver = ($y -gt $t)
    }
}

# Which cached frames the Estimated line and the visual measure (task48
# rebuild: "calculated based on what time range user choose"). Mirrors what
# Start Recording would record, without a Maya round trip:
#   All       -> the whole cached take (the cache samples the animation's
#                keyed extent, which "All" records).
#   StartEnd  -> the typed boxes, parsed exactly like Get-ResolvedTimeRange
#                ([int]::TryParse, Start must not exceed End).
#   TimeSlider-> Maya's live Range Slider is only readable through a Maya round
#                trip at click time, so this uses the last range a Preview /
#                Start Recording click resolved in that mode ($LastTimeSlider*);
#                none yet -> unknown, never a guess.
# StartIndex/EndIndex = the first/last cached frame inside [Start, End]; a
# range that covers no cached frame is unknown too. Known = $false always
# carries a short Reason for the Estimated line.
function Get-EstimateRange {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("All", "TimeSlider", "StartEnd")][string]$Mode,
        [AllowEmptyCollection()][double[]]$Frames = @(),
        [string]$StartText = "",
        [string]$EndText = "",
        $LastTimeSliderStart = $null,
        $LastTimeSliderEnd = $null
    )
    $unknown = { param($why) [PSCustomObject]@{ Known = $false; StartFrame = $null; EndFrame = $null; StartIndex = $null; EndIndex = $null; Reason = $why } }
    if ($null -eq $Frames -or $Frames.Count -eq 0) { return (& $unknown "no cache yet") }
    if ($Mode -eq "All") {
        return [PSCustomObject]@{ Known = $true; StartFrame = $Frames[0]; EndFrame = $Frames[$Frames.Count - 1]; StartIndex = 0; EndIndex = ($Frames.Count - 1); Reason = $null }
    }
    if ($Mode -eq "TimeSlider") {
        if ($null -eq $LastTimeSliderStart -or $null -eq $LastTimeSliderEnd) {
            return (& $unknown "Time Slider range unknown until Preview reads it from Maya")
        }
        $start = [double]$LastTimeSliderStart
        $end = [double]$LastTimeSliderEnd
    } else {
        $s = 0; $e = 0
        if (-not [int]::TryParse($StartText, [ref]$s) -or -not [int]::TryParse($EndText, [ref]$e)) {
            return (& $unknown "Start/End must be whole numbers")
        }
        $start = [double]$s
        $end = [double]$e
    }
    if ($start -gt $end) { return (& $unknown "Start is after End") }
    $first = -1; $last = -1
    for ($i = 0; $i -lt $Frames.Count; $i++) {
        if ($Frames[$i] -ge $start -and $Frames[$i] -le $end) {
            if ($first -lt 0) { $first = $i }
            $last = $i
        }
    }
    if ($first -lt 0) { return (& $unknown "frames $start-$end are outside the cached take") }
    return [PSCustomObject]@{ Known = $true; StartFrame = $start; EndFrame = $end; StartIndex = $first; EndIndex = $last; Reason = $null }
}

# The Estimated line with numbers (task48 fix round). Rounds with the SAME
# rule as Get-ToleranceBandSplit (1 decimal, half away from zero), so the
# text and the bar never disagree at a midpoint (worst 2.25 vs 2.2: text
# "2.3", bar red). The text FORMAT is unchanged from before: a whole number
# prints without a decimal ("worst 2%").
function Format-EstimateReadoutText {
    param(
        [Parameter(Mandatory=$true)][int]$Keys,
        [Parameter(Mandatory=$true)][double]$OverPct,
        [Parameter(Mandatory=$true)][double]$WorstPct
    )
    $over = [Math]::Round($OverPct, 1, [MidpointRounding]::AwayFromZero)
    $worst = [Math]::Round($WorstPct, 1, [MidpointRounding]::AwayFromZero)
    return "Estimated: $Keys keys, $over% of frames over tolerance, worst $worst% of frame width."
}

# The Estimated line when there is nothing to measure. No cache (or no reason
# given) -> the user-approved wording; any other reason (range unknown) is
# shown as-is so the line never pretends to have a number.
function Get-EstimatePendingText {
    param([string]$Reason = $null)
    if ([string]::IsNullOrEmpty($Reason) -or $Reason -eq "no cache yet") {
        return "Estimated: -- (open Preview once to see keys and worst overshoot)"
    }
    return "Estimated: -- ($Reason)"
}

# Tolerance diagram tooltip (task48 rebuild): truthful wording from the
# approved mock rounds (8/10/11/12). Numbers use 1 decimal, invariant culture.
# $RangeText describes the measured frames (e.g. "frames 0-120"); $WorstPct
# $null = no estimate; $PendingReason = why (passed to the no-estimate part).
function Get-ToleranceTooltipText {
    param(
        [bool]$GateOn = $true,
        [bool]$Auto = $true,
        [double]$TolPct = 0.0,
        $WorstPct = $null,
        [string]$RangeText = "",
        [string]$PendingReason = $null
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $f1 = { param($v) ([Math]::Round([double]$v, 1, [MidpointRounding]::AwayFromZero)).ToString("0.0", $inv) }
    $text = "Tolerance: how far (as % of the frame width, on each side) the character may stick out past the left or right frame edge. Grey = the capture frame, blue = the allowed margin; a WIDER blue margin means the camera reacts LESS and more of the character can be cut at the edges."
    $text += " Margin shown magnified 10x (the grey frame, 100% of the frame width, is a fifth of this bar; ticks mark 5, 10 and 20% of the frame width per side)."
    if ($GateOn) {
        $text += " Frame gate ON: the camera only moves when an edge passes this limit, and then only enough to bring it back to it."
    } else {
        $text += " Frame gate OFF: the camera never moves; this number is only the clipping-warning threshold (amber up to it, red beyond), marked with !."
    }
    if ($Auto -and $GateOn) {
        $text += " Auto (dashed outline, A) = $(& $f1 $TolPct)% at the current Zoom (2.0% at zoom 0, 0 when zoomed in about 4% or more)."
    } elseif ($Auto) {
        $text += " Auto (dashed outline, A) = the fixed 2.0% warning threshold."
    } else {
        $text += " Manual: $(& $f1 $TolPct)%."
    }
    if ($null -ne $WorstPct) {
        $over = if ($RangeText) { " over $RangeText" } else { "" }
        $text += " Solid blue = the part of your allowed margin the animation actually uses (worst $(& $f1 $WorstPct)% of the frame width$over). Pale dashed = unused slack. Red outline with ! = overshoot beyond the allowed margin."
    } else {
        $why = if ([string]::IsNullOrEmpty($PendingReason) -or $PendingReason -eq "no cache yet") { "open Preview once" } else { $PendingReason }
        $text += " No estimate yet ($why): the bar shows the allowed margin only."
    }
    if ($GateOn) {
        $text += " Very small values (0-2%): the camera follows the character's edges closely and nudges more often (on a real take at zoom 0: about 0.7 keys per second at 0%, 0.5 at 2%, 0.1 at 10%). It only gets busy and hugs the limit when the character is wider than the frame (zoomed in). Larger values keep the camera calmer but let the character be cut at the edges by up to that amount. A red outlined part in the bar means the animation goes past the allowed margin."
    }
    return ($text + " Mouse wheel here steps the number like over the box (Shift 10, Ctrl 0.1).")
}

# --- Prefix box and video names (T87) --------------------------------------
# The Prefix box (Settings tab, label "ROM video prefix") names the videos
# {prefix}_front_back_HH_mm.<ext> and {prefix}_left_right_HH_mm.<ext> (local
# rename time, e.g. barM_x_front_back_14_32.mp4). The launcher fills the box from the open Maya
# scene name (Get-PrefixFillDecision), reads it ONCE at the Start Recording
# click (Get-SafePrefix) and passes it to maya_obs_capture.ps1, which renames
# each leg's video right after OBS stops (Get-ObsRecordOutputPath,
# Rename-RecordedVideo) and writes the final path to scripts\state\
# _last_video.txt for the post-record script (D4_CTX['video_path']).
# An empty prefix keeps OBS's own names and today's step list byte for byte.

function Get-SafePrefix {
    # The prefix as it may appear in a Windows file name. Rules (user
    # answers, form_t87): surrounding whitespace is dropped; \ / : * ? " < >
    # | , control characters and whitespace become '_'; trailing dots are
    # dropped (Windows strips them); a leading '-' becomes '_' (so the value
    # can never be read as a switch on the capture script's command line); a
    # reserved device name before the first dot (CON, PRN, AUX, NUL, COM1-9,
    # LPT1-9) gets a '_' appended. Text with nothing meaningful left (empty,
    # whitespace only, only unsafe characters and dots) = "" = no prefix.
    # NO length cap: the path-length guard is Get-UniqueVideoPath's job.
    # Idempotent: Get-SafePrefix (Get-SafePrefix x) -ceq Get-SafePrefix x.
    param([AllowNull()][AllowEmptyString()][string]$Prefix)
    # T87 LOW-1: invisible format characters (zero-width space/joiners, LRM/RLM,
    # bidi embeddings/overrides, word joiner, BOM) are dropped first, so a
    # prefix made only of them is an empty prefix. Built from char codes to
    # keep this file ASCII.
    if ($Prefix) {
        $fmt = "[" + [char]0x200B + "-" + [char]0x200F + [char]0x202A + "-" + [char]0x202E + [char]0x2060 + [char]0xFEFF + "]"
        $Prefix = [regex]::Replace($Prefix, $fmt, "")
    }
    if ([string]::IsNullOrWhiteSpace($Prefix)) { return "" }
    $unsafe = '\/:*?"<>|'
    $sb = New-Object System.Text.StringBuilder
    $meaningful = $false
    foreach ($ch in $Prefix.Trim().ToCharArray()) {
        if ($unsafe.IndexOf($ch) -ge 0 -or [char]::IsControl($ch) -or [char]::IsWhiteSpace($ch)) {
            [void]$sb.Append('_')
        } else {
            [void]$sb.Append($ch)
            if ($ch -ne '.') { $meaningful = $true }
        }
    }
    if (-not $meaningful) { return "" }
    $s = $sb.ToString().TrimEnd('.')
    if (-not $s) { return "" }
    if ($s.StartsWith("-")) { $s = "_" + $s.Substring(1) }
    $dot = $s.IndexOf('.')
    $base = if ($dot -ge 0) { $s.Substring(0, $dot) } else { $s }
    if ($base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])$') {
        $s = $base + "_" + $s.Substring($base.Length)
    }
    return $s
}

function Get-LegSuffix {
    # The part of the video name that says which leg it is.
    param([Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight")][string]$LegAxis)
    if ($LegAxis -eq "FrontBack") { return "front_back" }
    return "left_right"
}

function Get-VideoRenameTime {
    # T87 clock seam: the local time a video is renamed at (tests replace it).
    return (Get-Date)
}

function Get-VideoNameStamp {
    # The time stamp at the end of a renamed video name: local 24 h HH_mm
    # (user choice 2026-10-26: {prefix}_front_back_14_32.<ext>).
    param([Parameter(Mandatory=$true)][DateTime]$Now)
    return $Now.ToString("HH'_'mm", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FittedPrefix {
    # $Prefix cut to at most $MaxLength characters, still safe: never splits
    # a surrogate pair, never ends in a dot, never leaves a reserved name
    # (Get-SafePrefix runs again; if its fix-up makes it longer, cut more).
    # "" when nothing fits.
    param([AllowEmptyString()][string]$Prefix, [int]$MaxLength)
    if ($MaxLength -lt 1 -or -not $Prefix) { return "" }
    if ($Prefix.Length -le $MaxLength) { return $Prefix }
    $len = $MaxLength
    while ($len -gt 0) {
        $cut = $Prefix.Substring(0, $len)
        if ([char]::IsHighSurrogate($cut[$cut.Length - 1])) { $len--; continue }
        $s = Get-SafePrefix -Prefix $cut
        if ($s.Length -le $MaxLength) { return $s }
        $len--
    }
    return ""
}

function Get-UniqueVideoPath {
    # The first free target in $Directory: {prefix}_{leg}<ext>, then
    # {prefix}_{leg}_2<ext>, _3 ... (an existing file is never a target).
    # Path-length guard: the whole path stays <= $MaxPathLength (255, under
    # Windows' 260 MAX_PATH); a prefix that does not fit is shortened just
    # enough (Truncated = $true). Returns Path/Prefix/Truncated/Error;
    # Path = $null with Error set when no name fits. Never throws for a
    # missing folder or a long name (an unknown -LegAxis does throw).
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory=$true)][string]$LegAxis,
        [AllowEmptyString()][string]$Extension = "",
        [int]$MaxPathLength = 255,
        [int]$MaxAttempts = 999,
        # T87: HH_mm stamp after the leg suffix ("" = none):
        # {prefix}_{leg}_HH_mm<ext>; same-minute clashes get _2, _3 after it
        [AllowEmptyString()][string]$Stamp = "",
        # an existing file that counts as free (the video being renamed, so a
        # source already carrying the target name is left in place)
        [AllowEmptyString()][string]$IgnorePath = ""
    )
    $leg = Get-LegSuffix -LegAxis $LegAxis
    $safe = Get-SafePrefix -Prefix $Prefix
    if (-not $safe) { return [PSCustomObject]@{ Path = $null; Prefix = ""; Truncated = $false; Error = "the prefix is empty" } }
    $dir = $Directory.TrimEnd('\')
    for ($n = 1; $n -le $MaxAttempts; $n++) {
        $tail = "_" + $leg + $(if ($Stamp) { "_$Stamp" } else { "" }) + $(if ($n -gt 1) { "_$n" } else { "" }) + $Extension
        $room = $MaxPathLength - ($dir.Length + 1 + $tail.Length)
        $p = Get-FittedPrefix -Prefix $safe -MaxLength $room
        if (-not $p) {
            return [PSCustomObject]@{ Path = $null; Prefix = ""; Truncated = $false; Error = "the folder path is too long for a $MaxPathLength-character video path: $dir" }
        }
        $candidate = $dir + "\" + $p + $tail
        $isSelf = $IgnorePath -and [string]::Equals($candidate, $IgnorePath, [StringComparison]::OrdinalIgnoreCase)
        if ($isSelf -or -not (Test-Path -LiteralPath $candidate)) {
            return [PSCustomObject]@{ Path = $candidate; Prefix = $p; Truncated = ($p -cne $safe); Error = $null }
        }
    }
    return [PSCustomObject]@{ Path = $null; Prefix = ""; Truncated = $false; Error = "no free name after $MaxAttempts tries ($safe" + "_" + "$leg" + "_N$Extension)" }
}

function Rename-RecordedVideo {
    # Renames one finished video to {prefix}_{leg}_HH_mm<ext> (ext = what OBS
    # wrote, HH_mm = local rename time), the next free _2/_3 if taken, never overwriting anything
    # ([IO.File]::Move throws when the target exists, then the next suffix is
    # tried). While OBS still holds the file (sharing violation / access
    # denied) the move is retried $RetryCount times, $RetryDelayMs apart
    # ($OnRetry, if given, is called with the retry number: a test seam).
    # NEVER throws: any failure is a WARNING line and the original video is
    # kept, so the post-record script, HUD and taskbar restore still run.
    # Returns Status renamed|kept|skipped, Path (the video's final path; ""
    # when OBS reported none), Log (lines; problems start with WARNING).
    param(
        [AllowNull()][AllowEmptyString()][string]$SourcePath,
        [AllowNull()][AllowEmptyString()][string]$Prefix,
        [AllowNull()][AllowEmptyString()][string]$LegAxis,
        [int]$MaxPathLength = 255,
        [int]$RetryCount = 20,
        [int]$RetryDelayMs = 500,
        [scriptblock]$OnRetry = $null,
        # T87: rename time for the _HH_mm stamp ($null = Get-VideoRenameTime, the clock seam)
        $Now = $null
    )
    $log = New-Object System.Collections.Generic.List[string]
    # T87 LOW-3: one path form everywhere (OBS may report forward slashes)
    $src = if ($SourcePath) { $SourcePath.Replace("/", "\") } else { "" }
    try {
        $safe = Get-SafePrefix -Prefix $Prefix
        if (-not $safe) {
            return [PSCustomObject]@{ Status = "skipped"; Path = $src; Log = @($log) }
        }
        if ([string]::IsNullOrWhiteSpace($src)) {
            $log.Add("WARNING: OBS did not report the video file path -- the video keeps OBS's own name.")
            return [PSCustomObject]@{ Status = "kept"; Path = ""; Log = @($log) }
        }
        if ($LegAxis -ne "FrontBack" -and $LegAxis -ne "LeftRight") {
            $log.Add("WARNING: unknown leg '$LegAxis' -- the video keeps OBS's own name: $src")
            return [PSCustomObject]@{ Status = "kept"; Path = $src; Log = @($log) }
        }
        if (-not [IO.File]::Exists($src)) {
            $log.Add("WARNING: the recorded video was not found, nothing renamed: $src")
            return [PSCustomObject]@{ Status = "kept"; Path = $src; Log = @($log) }
        }
        $src = [IO.Path]::GetFullPath($src)
        $dir = [IO.Path]::GetDirectoryName($src)
        $ext = [IO.Path]::GetExtension($src)
        if ($null -eq $Now) { $Now = Get-VideoRenameTime }
        $stamp = Get-VideoNameStamp -Now ([DateTime]$Now)
        $lockRetries = 0
        $collisions = 0
        $truncNoted = $false
        while ($true) {
            $target = Get-UniqueVideoPath -Directory $dir -Prefix $safe -LegAxis $LegAxis -Extension $ext -MaxPathLength $MaxPathLength -Stamp $stamp -IgnorePath $src
            if (-not $target.Path) {
                $log.Add("WARNING: could not build a new name ($($target.Error)) -- the video keeps OBS's own name: $src")
                return [PSCustomObject]@{ Status = "kept"; Path = $src; Log = @($log) }
            }
            if ($target.Truncated -and -not $truncNoted) {
                $log.Add("Prefix shortened to $($target.Prefix.Length) characters to stay within the Windows path limit ($MaxPathLength).")
                $truncNoted = $true
            }
            if ([string]::Equals($target.Path, $src, [StringComparison]::OrdinalIgnoreCase)) {
                # T87 LOW-2: it already carries the target name -- leave it in place
                $log.Add("Video already named $([IO.Path]::GetFileName($src)) -- left as it is.")
                return [PSCustomObject]@{ Status = "renamed"; Path = $src; Log = @($log) }
            }
            try {
                [IO.File]::Move($src, $target.Path)
                $log.Add("Video renamed: $([IO.Path]::GetFileName($src)) -> $([IO.Path]::GetFileName($target.Path))")
                return [PSCustomObject]@{ Status = "renamed"; Path = $target.Path; Log = @($log) }
            } catch {
                $ex = $_.Exception
                while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
                $code = $ex.HResult -band 0xFFFF
                if ((Test-Path -LiteralPath $target.Path) -or $code -eq 80 -or $code -eq 183) {
                    # someone took that name in between: try the next suffix
                    $collisions++
                    if ($collisions -gt 999) { throw }
                    continue
                }
                if (($code -eq 32 -or $code -eq 33 -or $code -eq 5) -and $lockRetries -lt $RetryCount) {
                    $lockRetries++
                    if ($OnRetry) { & $OnRetry $lockRetries }
                    Start-Sleep -Milliseconds $RetryDelayMs
                    continue
                }
                $log.Add("WARNING: could not rename the video after $($lockRetries + 1) tries ($($ex.Message.Trim())) -- it keeps OBS's own name: $src")
                return [PSCustomObject]@{ Status = "kept"; Path = $src; Log = @($log) }
            }
        }
    } catch {
        $log.Add("WARNING: renaming the video failed ($($_.Exception.Message)) -- it keeps OBS's own name: $src")
        return [PSCustomObject]@{ Status = "kept"; Path = $src; Log = @($log) }
    }
}

function Write-LastVideoPath {
    # scripts\state\_last_video.txt: the final path of the video the capture
    # script just finished (UTF-8, no BOM, one line; "" = none known), read
    # by maya_run_hook.py as D4_CTX['video_path'] for the post-record script.
    # Overwritten per leg and cleared when a capture starts, so a Stop click
    # (capture killed) never hands the post script the previous video.
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [AllowNull()][AllowEmptyString()][string]$Path
    )
    $file = Get-ToolPath -ScriptDir $ScriptDir -Name "_last_video.txt"
    # T87 LOW-3: backslashes, the same form as a renamed path
    $text = if ($Path) { $Path.Replace("/", "\") + "`n" } else { "" }
    [IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $file
}

function Get-ObsRecordOutputPath {
    # Where OBS saved the video, from the OBS WebSocket v5 messages seen
    # after a StopRecord request (op 7 = request response, op 5 = event).
    # Layered: (1) the StopRecord response's responseData.outputPath; (2) a
    # RecordStateChanged event with outputState OBS_WEBSOCKET_OUTPUT_STOPPED
    # and its outputPath; (3) nothing: Path "" and Source "none" (the caller
    # keeps OBS's name; it never guesses from the record folder).
    param(
        [AllowNull()][AllowEmptyCollection()][array]$Messages = @(),
        [AllowEmptyString()][string]$RequestId = ""
    )
    foreach ($m in @($Messages)) {
        if ($null -eq $m -or $m.op -ne 7 -or $m.d.requestId -ne $RequestId) { continue }
        $p = $m.d.responseData.outputPath
        if ($p -is [string] -and $p.Trim()) { return [PSCustomObject]@{ Path = $p; Source = "response" } }
    }
    foreach ($m in @($Messages)) {
        if ($null -eq $m -or $m.op -ne 5 -or $m.d.eventType -ne "RecordStateChanged") { continue }
        if ($m.d.eventData.outputState -ne "OBS_WEBSOCKET_OUTPUT_STOPPED") { continue }
        $p = $m.d.eventData.outputPath
        if ($p -is [string] -and $p.Trim()) { return [PSCustomObject]@{ Path = $p; Source = "event" } }
    }
    return [PSCustomObject]@{ Path = ""; Source = "none" }
}

function Format-ObsMessageSummary {
    # One short line describing the OBS messages seen around StopRecord, for
    # the log (the live reply shape has not been observed yet: the QA probe
    # reads this line).
    param([AllowNull()][AllowEmptyCollection()][array]$Messages = @())
    $parts = @()
    foreach ($m in @($Messages)) {
        if ($null -eq $m) { continue }
        if ($m.op -eq 7) {
            $parts += "reply $($m.d.requestType) result=$($m.d.requestStatus.result) outputPath=$($m.d.responseData.outputPath)"
        } elseif ($m.op -eq 5) {
            $parts += "event $($m.d.eventType)($($m.d.eventData.outputState)) outputPath=$($m.d.eventData.outputPath)"
        } else {
            $parts += "op$($m.op)"
        }
    }
    if (-not $parts.Count) { return "(no messages)" }
    return ($parts -join " | ")
}

function ConvertFrom-SceneNameOutput {
    # Parses maya_get_scene_name.py's result file:
    #   SCENE_NAME <name>          (file name without folder and extension)
    #   SCENE_UNTITLED             (never saved: nothing to fill)
    #   SCENE_NAME_ERROR <message>
    # Anything else (empty = no reply / timeout) is Status "Unknown". The
    # name is returned raw (spaces kept); Get-SafePrefix runs at the click.
    param([AllowNull()][AllowEmptyString()][string]$Output)
    $line = @(([string]$Output) -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match '^SCENE_(NAME|UNTITLED)' }) | Select-Object -First 1
    if (-not $line) { return [PSCustomObject]@{ Status = "Unknown"; Name = ""; ErrorMessage = "No response from Maya." } }
    if ($line -match '^SCENE_NAME_ERROR\s*(.*)$') { return [PSCustomObject]@{ Status = "Error"; Name = ""; ErrorMessage = $Matches[1].Trim() } }
    if ($line -match '^SCENE_UNTITLED') { return [PSCustomObject]@{ Status = "Untitled"; Name = ""; ErrorMessage = $null } }
    if ($line -match '^SCENE_NAME (.*)$') {
        $n = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($n)) { return [PSCustomObject]@{ Status = "Untitled"; Name = ""; ErrorMessage = $null } }
        return [PSCustomObject]@{ Status = "Named"; Name = $n; ErrorMessage = $null }
    }
    return [PSCustomObject]@{ Status = "Unknown"; Name = ""; ErrorMessage = "Unrecognized response: $line" }
}

function Get-PrefixFillDecision {
    # What the Prefix box should show after a scene-name lookup. Rules
    # (user answers): an empty (or whitespace-only) box is filled; typed
    # text is never touched; STALE RULE: text still equal (case-sensitive)
    # to the last auto-filled value counts as unedited and follows the scene;
    # -FromButton (the 'use the Maya scene name' button) replaces any text.
    # No scene name (untitled / no reply) changes nothing, button included.
    # Returns Text, LastAutoFill, Changed, Reason (filled | refreshed |
    # unchanged | button | kept_user_text | no_scene).
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentText,
        [AllowNull()][AllowEmptyString()][string]$LastAutoFill,
        [AllowNull()][AllowEmptyString()][string]$SceneName,
        [bool]$FromButton = $false
    )
    $cur = [string]$CurrentText
    $last = [string]$LastAutoFill
    if ([string]::IsNullOrWhiteSpace($SceneName)) {
        return [PSCustomObject]@{ Text = $cur; LastAutoFill = $last; Changed = $false; Reason = "no_scene" }
    }
    if ($FromButton) {
        return [PSCustomObject]@{ Text = $SceneName; LastAutoFill = $SceneName; Changed = ($cur -cne $SceneName); Reason = "button" }
    }
    if ([string]::IsNullOrWhiteSpace($cur)) {
        return [PSCustomObject]@{ Text = $SceneName; LastAutoFill = $SceneName; Changed = $true; Reason = "filled" }
    }
    if ($last -and $cur -ceq $last) {
        $changed = ($cur -cne $SceneName)
        return [PSCustomObject]@{ Text = $SceneName; LastAutoFill = $SceneName; Changed = $changed; Reason = $(if ($changed) { "refreshed" } else { "unchanged" }) }
    }
    return [PSCustomObject]@{ Text = $cur; LastAutoFill = $last; Changed = $false; Reason = "kept_user_text" }
}

function Test-PrefixFillNeeded {
    # Whether asking Maya for the scene name can change the box at all: the
    # button always; otherwise only an empty box or one still showing the
    # last auto-filled value (Get-PrefixFillDecision keeps typed text
    # whatever the scene). Saves the Maya round trip on every click once
    # the user has typed a prefix.
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentText,
        [AllowNull()][AllowEmptyString()][string]$LastAutoFill,
        [bool]$FromButton = $false
    )
    if ($FromButton) { return $true }
    if ([string]::IsNullOrWhiteSpace($CurrentText)) { return $true }
    return ([bool]$LastAutoFill -and ($CurrentText -ceq $LastAutoFill))
}

function Get-PrefixSceneApplyResult {
    # The ONE place that turns a scene-name lookup (ConvertFrom-SceneNameOutput
    # result) into the new box text + log line; used by the synchronous click
    # path (Update-PrefixFromScene) and the async connect/launch path
    # (Update-PrefixFillAsync) alike, so both follow Get-PrefixFillDecision
    # (stale rule, typed text never touched, button replaces). LogLine is ""
    # when nothing worth a line happened.
    param(
        $Scene,
        [AllowNull()][AllowEmptyString()][string]$CurrentText,
        [AllowNull()][AllowEmptyString()][string]$LastAutoFill,
        [bool]$FromButton = $false,
        [AllowNull()][AllowEmptyString()][string]$Trigger = ""
    )
    $cur = [string]$CurrentText
    $last = [string]$LastAutoFill
    $when = if ($Trigger) { " ($Trigger)" } else { "" }
    $status = if ($Scene) { [string]$Scene.Status } else { "Unknown" }
    if ($status -eq "Untitled") {
        return [PSCustomObject]@{ Text = $cur; LastAutoFill = $last; Changed = $false; LogLine = "Prefix$when`: the Maya scene is untitled (never saved) -- nothing to fill in." }
    }
    if ($status -ne "Named") {
        $msg = if ($Scene -and $Scene.ErrorMessage) { $Scene.ErrorMessage } else { "No response from Maya." }
        return [PSCustomObject]@{ Text = $cur; LastAutoFill = $last; Changed = $false; LogLine = "Prefix$when`: could not read the Maya scene name ($msg) -- the box is unchanged." }
    }
    $d = Get-PrefixFillDecision -CurrentText $cur -LastAutoFill $last -SceneName $Scene.Name -FromButton $FromButton
    $line = ""
    switch ($d.Reason) {
        "filled" { $line = "Prefix$when filled from the Maya scene name: $($d.Text)" }
        "refreshed" { $line = "Prefix$when updated to the new Maya scene name: $($d.Text)" }
        "button" { $line = "Prefix set to the Maya scene name: $($d.Text)" }
    }
    return [PSCustomObject]@{ Text = $d.Text; LastAutoFill = $d.LastAutoFill; Changed = $d.Changed; LogLine = $line }
}

function Get-BusyBarGeometry {
    # The top busy bar (look C, form_t87_bar): a segment 30% of the bar wide
    # moving back and forth between X = 0 and X = Travel (bar width minus
    # segment). Fraction = position within one sweep, clamped to 0..1 (the
    # launcher animates it with AutoReverse; offscreen renders freeze it).
    param([double]$BarWidth, [double]$Fraction = 0)
    if ($BarWidth -le 0) { return [PSCustomObject]@{ SegmentWidth = 0; Travel = 0; X = 0 } }
    $seg = [Math]::Round($BarWidth * 0.3)
    $travel = $BarWidth - $seg
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))
    return [PSCustomObject]@{ SegmentWidth = $seg; Travel = $travel; X = ($travel * $f) }
}

function Get-PrefixAsyncStartDecision {
    # Whether the async (connect / launch) scene-name fill may start now:
    # never a second one while one runs, never during a run (the port is busy
    # with the run's steps and its click already filled the box), never when
    # the answer cannot change the box (typed text; Test-PrefixFillNeeded).
    param([bool]$Busy, [bool]$RunActive, [AllowNull()][AllowEmptyString()][string]$CurrentText, [AllowNull()][AllowEmptyString()][string]$LastAutoFill)
    if ($Busy) { return [PSCustomObject]@{ Start = $false; Reason = "busy" } }
    if ($RunActive) { return [PSCustomObject]@{ Start = $false; Reason = "run_active" } }
    if (-not (Test-PrefixFillNeeded -CurrentText $CurrentText -LastAutoFill $LastAutoFill)) { return [PSCustomObject]@{ Start = $false; Reason = "not_needed" } }
    return [PSCustomObject]@{ Start = $true; Reason = "start" }
}

function Get-PrefixAsyncPollDecision {
    # One tick of the async fill: "discard" (a run started meanwhile: do not
    # touch the box), "complete" (the process exited: read its result),
    # "timeout" (still running at the limit: kill it), else "wait".
    param([bool]$HasExited, [double]$ElapsedMs, [double]$TimeoutMs, [bool]$RunActive)
    if ($RunActive) { return "discard" }
    if ($HasExited) { return "complete" }
    if ($ElapsedMs -ge $TimeoutMs) { return "timeout" }
    return "wait"
}

function Test-PrefixConnectFillDue {
    # The 5 s port tick fills the box on the FIRST connect only: Maya's port
    # going from unreachable to reachable. $null = not known yet (the launch
    # itself is handled once, after the window is shown).
    param($WasReachable, [bool]$IsReachable)
    return (($WasReachable -is [bool]) -and (-not $WasReachable) -and $IsReachable)
}

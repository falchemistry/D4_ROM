# Fully automated capture: resets Maya to frame 0 (or -StartFrame, if
# given), starts OBS recording, starts Maya playback (back-to-back with the
# recording start to avoid a static lead-in), waits for playback to reach
# the end of the range on its own (playbackOptions loop is forced to
# 'once' so there's no race to catch a loop wraparound), then stops OBS
# recording.
#
# Usage:
#   powershell -File maya_obs_capture.ps1
#   powershell -File maya_obs_capture.ps1 -StartFrame 0 -EndFrame 100
#
# -StartFrame/-EndFrame are both optional and must be given together (or
# not at all) -- when omitted, playback uses whatever range is already set
# on Maya's timeline, exactly as before this option existed. When given,
# the ORIGINAL range is queried first and restored after the capture
# finishes (success or failure), so a quick sample capture never silently
# leaves a subsequent full-range capture recording a narrowed clip.

param(
    [Nullable[int]]$StartFrame = $null,
    [Nullable[int]]$EndFrame = $null
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $ScriptDir "rom_launcher_logic.ps1")
$StateDir = Get-ToolStateDir -ScriptDir $ScriptDir
Add-Type -AssemblyName System.Drawing

if (($StartFrame -eq $null) -ne ($EndFrame -eq $null)) {
    throw "StartFrame and EndFrame must both be given, or neither."
}
if ($StartFrame -ne $null -and $StartFrame -gt $EndFrame) {
    throw "StartFrame ($StartFrame) must not be greater than EndFrame ($EndFrame)."
}

# --- Taskbar show/hide -----------------------------------------------------
# Multi-monitor setups get a second taskbar per extra display, under class
# "Shell_SecondaryTrayWnd" (the primary is "Shell_TrayWnd") -- FindWindow
# only returns one match, so enumerate top-level windows to catch all of them.
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class ClaudeTaskbar {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static List<IntPtr> FindTaskbars() {
        var found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            var sb = new StringBuilder(256);
            GetClassName(hWnd, sb, sb.Capacity);
            string cls = sb.ToString();
            if (cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") {
                found.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

function Hide-Taskbar {
    foreach ($bar in [ClaudeTaskbar]::FindTaskbars()) {
        [ClaudeTaskbar]::ShowWindow($bar, 0) | Out-Null  # SW_HIDE
    }
}

function Show-Taskbar {
    foreach ($bar in [ClaudeTaskbar]::FindTaskbars()) {
        [ClaudeTaskbar]::ShowWindow($bar, 1) | Out-Null  # SW_SHOWNORMAL
    }
}

# --- Maya command port helpers -------------------------------------------
function Send-MayaCode($code) {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 7001)
    $stream = $client.GetStream()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
}

function Get-MayaPlaybackState() {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 7001)
    $stream = $client.GetStream()
    $code = "import maya.cmds as cmds`nwith open(r'$StateDir\_playback_state.txt','w') as f:`n    f.write(str(cmds.play(q=True, state=True)))`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
    Start-Sleep -Milliseconds 200
    return (Get-Content "$StateDir\_playback_state.txt" -Raw).Trim()
}

function Get-MayaFrameRange() {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 7001)
    $stream = $client.GetStream()
    $code = "import maya.cmds as cmds`nwith open(r'$StateDir\_frame_range_state.txt','w') as f:`n    f.write(str(cmds.playbackOptions(q=True, minTime=True)) + ',' + str(cmds.playbackOptions(q=True, maxTime=True)))`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
    Start-Sleep -Milliseconds 200
    $parts = (Get-Content "$StateDir\_frame_range_state.txt" -Raw).Trim().Split(",")
    return [PSCustomObject]@{ MinTime = [double]$parts[0]; MaxTime = [double]$parts[1] }
}

function Set-MayaFrameRange($minTime, $maxTime) {
    Send-MayaCode "import maya.cmds as cmds`ncmds.playbackOptions(minTime=$minTime, maxTime=$maxTime)`n"
}

# --- HUD save/mutate/restore (task17, 2026-09-30) --------------------------
# Goal: the Current Frame HUD (plus Camera Names and Frame Rate -- see
# TARGET_HUD_ITEMS below) must be visible in every ROM capture, automatically,
# and Maya's HUD must always end up exactly as the artist had it, even if
# the capture crashes or is hard-stopped. Mirrors the existing
# Get-MayaFrameRange/Set-MayaFrameRange save/mutate/finally-restore pattern
# above, but ALSO persists the saved snapshot to disk (see Get-MayaHudState)
# so Get-StopCleanupSteps's new restore step (rom_launcher_logic.ps1) can
# recover it even when Process.Kill() bypasses this script's own `finally`
# entirely -- frame range has a documented, accepted gap here; HUD does not.
#
# TARGET_HUD_ITEMS confirmed LIVE (bridge, port 7001, 2026-09-30) against a
# real Maya session, not assumed from documentation -- see the design notes
# in Get-CaptureHudState below for exactly what was verified and why these
# three specific item names.
$TargetHudItems = @('HUDCameraNames', 'HUDCurrentFrame', 'HUDFrameRate')

function Get-CapturePanelNames() {
    # Reads the exact Maya-generated modelPanel name(s) maya_camera_panels.py
    # (or _LR.py) just wrote via write_capture_panel_names() -- this
    # PowerShell process has no way to enumerate "which panels are the
    # capture panels" on its own, so it relies on that file hand-off, same
    # convention as every other _camera_*.txt file already used between
    # these two scripts. Returns an empty array (not an error) if the file
    # is missing -- e.g. this script run standalone without the panel-setup
    # step ever having run -- so HUD save/restore still degrades gracefully
    # to "no known capture panel, items only."
    $path = Join-Path $ScriptDir "..\d4_anim_sample\_capture_panels.txt"
    if (-not (Test-Path $path)) { return @() }
    $names = @(Get-Content $path | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ,$names
}

function Get-MayaHudState() {
    # Snapshots BOTH halves of what actually controls HUD text in a capture
    # panel -- confirmed live (2026-09-30) that forcing a capture panel's
    # own modelEditor headsUpDisplay flag from False to True is not enough
    # on its own: whatever OTHER HUD items already happen to be globally
    # enabled (in the verified test session: PolyCount Verts/Edges/Faces/
    # Triangles/UVs, Symmetry, CapsLock, ViewAxis) become visible in that
    # panel too, alongside the 3 wanted items -- so both the per-panel flag
    # AND every item's global visibility must be captured and restored, not
    # just the panel flag alone. Also writes the snapshot to a persistent
    # file (not just returned in-memory) so Get-StopCleanupSteps's restore
    # step can recover it after a Process.Kill(), which never lets this
    # script's own `finally` run at all.
    $panels = Get-CapturePanelNames
    $panelsPy = (($panels | ForEach-Object { "'$($_ -replace "'", "\'")'" }) -join ", ")
    $statePath = "$StateDir\_hud_state.json"
    # r'...' raw-string form, same convention as Get-MayaFrameRange/
    # Get-MayaPlaybackState above -- avoids any backslash-escaping games
    # with a plain Windows path.
    $code = @"
import maya.cmds as cmds
import json
panels = [$panelsPy]
items = cmds.headsUpDisplay(listHeadsUpDisplays=True) or []
state = {'panels': {}, 'items': {}}
for p in panels:
    if cmds.control(p, exists=True):
        state['panels'][p] = bool(cmds.modelEditor(p, query=True, headsUpDisplay=True))
for it in items:
    state['items'][it] = bool(cmds.headsUpDisplay(it, query=True, visible=True))
with open(r'$statePath', 'w') as f:
    json.dump(state, f)
"@
    if (Test-Path $statePath) { Remove-Item $statePath -Force }
    Send-MayaCode $code
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path $statePath)) {
        throw "Failed to save Maya's current HUD state before changing it -- aborting rather than risk leaving the artist's HUD altered with no saved way to restore it."
    }
    return (Get-Content $statePath -Raw | ConvertFrom-Json)
}

function Set-MayaHudState($state) {
    # Applies a full panels+items snapshot back onto Maya -- used to apply
    # BOTH the capture-time forced state (see Get-CaptureHudState) and the
    # restore-to-original state (the object Get-MayaHudState returned).
    # PowerShell True/False .ToString() output ("True"/"False") is used
    # as-is -- it matches Python's own boolean literal spelling exactly, so
    # no case conversion is needed (and lower-casing it would produce
    # invalid Python "true"/"false").
    $itemAssignments = @()
    foreach ($prop in $state.items.PSObject.Properties) {
        $itemAssignments += "cmds.headsUpDisplay('$($prop.Name)', edit=True, visible=$($prop.Value.ToString()))"
    }
    $panelAssignments = @()
    foreach ($prop in $state.panels.PSObject.Properties) {
        $panelAssignments += "if cmds.control('$($prop.Name)', exists=True): cmds.modelEditor('$($prop.Name)', edit=True, headsUpDisplay=$($prop.Value.ToString()))"
    }
    $code = "import maya.cmds as cmds`n" + ($itemAssignments -join "`n") + "`n" + ($panelAssignments -join "`n") + "`n"
    Send-MayaCode $code
}

function Get-CaptureHudState($originalState) {
    # Desired state DURING the capture: every known capture panel's own
    # flag forced True, and ONLY $TargetHudItems enabled -- everything else
    # the artist had on is suppressed for the capture's duration, then
    # restored. Built from $originalState so it covers exactly the same set
    # of panels/items that were actually snapshotted (never invents a panel
    # or item name that wasn't observed to exist).
    $captureItems = [ordered]@{}
    foreach ($prop in $originalState.items.PSObject.Properties) {
        $captureItems[$prop.Name] = [bool]($TargetHudItems -contains $prop.Name)
    }
    $capturePanels = [ordered]@{}
    foreach ($prop in $originalState.panels.PSObject.Properties) {
        $capturePanels[$prop.Name] = $true
    }
    return [PSCustomObject]@{ panels = [PSCustomObject]$capturePanels; items = [PSCustomObject]$captureItems }
}

function Clear-MayaHudStateFile() {
    $statePath = "$StateDir\_hud_state.json"
    if (Test-Path $statePath) { Remove-Item $statePath -Force }
}

function Get-MayaFps() {
    # currentTimeUnitToFPS() is the same MEL proc Maya itself uses to
    # convert the scene's time unit ('ntsc', 'film', 'pal', a custom
    # 'Xfps' string, etc.) into a plain number -- confirmed live rather
    # than assuming 30 always, since this project's ROM scenes aren't
    # guaranteed to share one time unit.
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 7001)
    $stream = $client.GetStream()
    $code = "import maya.mel as mel`nwith open(r'$StateDir\_fps_state.txt','w') as f:`n    f.write(str(mel.eval('currentTimeUnitToFPS()')))`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
    Start-Sleep -Milliseconds 200
    return [double](Get-Content "$StateDir\_fps_state.txt" -Raw).Trim()
}

function Get-PlaybackPollIntervalSeconds($frameCount) {
    # Design (2026-09-02): user reported that short sample-range captures
    # took noticeably long to trigger Stop Recording after playback had
    # actually already finished -- the fixed 5s poll below meant up to
    # ~5.5s of dead air (5s sleep + this function's own ~0.5s round trip)
    # tacked onto the end of even a 2-3 second clip, more than doubling
    # its length. Scaling the interval to the CAPTURE's own expected
    # duration fixes this without touching the fixed 5s ceiling that
    # already works fine for full-length ROM videos (a 100+ second capture
    # still polls every 5s, unchanged).
    #
    # Expected duration assumes Maya plays back at its own scene fps in
    # real time, which is the whole premise of this recording -- OBS is
    # capturing the live viewport, not a re-timed render. Falls back to
    # 30fps if the fps query fails for any reason (Maya briefly
    # unreachable, unexpected mel.eval output) -- this interval is a UX
    # nicety, not something the capture's correctness depends on, so a
    # bad/missing fps should never abort or stall the run.
    $fps = 30.0
    try {
        $queriedFps = Get-MayaFps
        if ($queriedFps -gt 0) { $fps = $queriedFps }
    } catch {
        Write-Host "Could not query Maya's frame rate for poll-interval scaling -- assuming 30fps."
    }
    $expectedDurationSec = $frameCount / $fps
    # Floor of 0.5s: Get-MayaPlaybackState's own round trip already costs
    # ~0.5s (its two fixed Start-Sleeps), so polling faster than that
    # cannot actually detect completion any sooner -- it would only add
    # command-port traffic. Ceiling of 5s: the value this always used
    # before this change, kept as-is for anything long enough to hit it.
    return [Math]::Max(0.5, [Math]::Min(5.0, $expectedDurationSec * 0.1))
}

# --- OBS WebSocket helpers -------------------------------------------------
function Send-WsMessage($ws, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
}

function Receive-WsMessage($ws) {
    # Loops until EndOfMessage instead of trusting one ReceiveAsync call to
    # return the whole thing -- a single 8192-byte read was fine for the
    # short StartRecord/StopRecord responses this originally handled, but
    # GetSourceScreenshot's base64 image payload (added 2026-08-22, see
    # Get-SourceAvgBrightness) can span more than one WebSocket frame.
    $buffer = New-Object byte[] 65536
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $all = New-Object System.IO.MemoryStream
    do {
        $result = $ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $all.Write($buffer, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    $text = [System.Text.Encoding]::UTF8.GetString($all.ToArray())
    return $text | ConvertFrom-Json
}

function Get-AuthString($password, $salt, $challenge) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $secret = [Convert]::ToBase64String($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($password + $salt)))
    return [Convert]::ToBase64String($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($secret + $challenge)))
}

function Test-ObsWebSocketReachable($obsHost, $port) {
    # A bare TCP connect can succeed before OBS's WebSocket protocol layer
    # is actually ready to handshake (especially right after launch), so
    # do a real (but throwaway) Hello exchange instead of just a socket
    # connect -- this is what actually predicts whether Invoke-ObsRecordAction
    # will succeed.
    try {
        $uri = [Uri]::new("ws://${obsHost}:${port}")
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $connectTask = $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
        if (-not $connectTask.Wait(1500)) { return $false }

        $buffer = New-Object byte[] 8192
        $segment = [System.ArraySegment[byte]]::new($buffer)
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(1500)
        $receiveTask = $ws.ReceiveAsync($segment, $cts.Token)
        $receiveTask.GetAwaiter().GetResult() | Out-Null
        try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "probe", [System.Threading.CancellationToken]::None).Wait(500) } catch {}
        return $true
    } catch {
        return $false
    }
}

function Ensure-ObsRunning() {
    $obsExe = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
    $configText = Get-Content (Join-Path $ScriptDir "obs_config.txt") -Raw
    $obsHost = ([regex]::Match($configText, 'host:\s*(\S+)')).Groups[1].Value
    $port = ([regex]::Match($configText, 'port:\s*(\S+)')).Groups[1].Value

    if (Test-ObsWebSocketReachable $obsHost $port) {
        Write-Host "OBS is already running and reachable."
        return
    }

    $running = Get-Process -Name "obs64" -ErrorAction SilentlyContinue
    if (-not $running) {
        Write-Host "OBS is not running -- launching it..."
        Start-Process -FilePath $obsExe -WorkingDirectory (Split-Path $obsExe)
    } else {
        Write-Host "OBS process found but WebSocket not reachable yet -- waiting..."
    }

    $waited = 0
    while (-not (Test-ObsWebSocketReachable $obsHost $port)) {
        Start-Sleep -Seconds 2
        $waited += 2
        if ($waited -ge 60) {
            throw "OBS did not become reachable on ${obsHost}:${port} after 60 seconds. Check that the WebSocket server is enabled (Tools > WebSocket Server Settings)."
        }
    }
    Write-Host "OBS is up and reachable (waited ${waited}s)."
}

function Connect-ObsWebSocket() {
    # Shared connect+identify dance, factored out of Invoke-ObsRecordAction
    # so Repair-MonitorCaptureSourceBinding (below) can open its own
    # separate connection the same way, instead of duplicating this block
    # a second time.
    $configText = Get-Content (Join-Path $ScriptDir "obs_config.txt") -Raw
    $obsHost = ([regex]::Match($configText, 'host:\s*(\S+)')).Groups[1].Value
    $port = ([regex]::Match($configText, 'port:\s*(\S+)')).Groups[1].Value
    $password = ([regex]::Match($configText, 'password:\s*(\S+)')).Groups[1].Value

    $uri = [Uri]::new("ws://${obsHost}:${port}")
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait()

    $hello = Receive-WsMessage $ws
    $identify = @{ op = 1; d = @{ rpcVersion = 1 } }
    if ($hello.d.authentication) {
        $identify.d.authentication = Get-AuthString -password $password -salt $hello.d.authentication.salt -challenge $hello.d.authentication.challenge
    }
    Send-WsMessage $ws $identify
    $identified = Receive-WsMessage $ws
    if ($identified.op -ne 2) { throw "Failed to identify with OBS WebSocket." }
    return $ws
}

function Invoke-ObsRequest($ws, $requestType, $requestData = @{}) {
    $requestId = [Guid]::NewGuid().ToString()
    Send-WsMessage $ws @{ op = 6; d = @{ requestType = $requestType; requestId = $requestId; requestData = $requestData } }
    for ($i = 0; $i -lt 15; $i++) {
        $msg = Receive-WsMessage $ws
        if ($msg.op -eq 7 -and $msg.d.requestId -eq $requestId) { return $msg.d }
    }
    throw "No RequestResponse received for $requestType after 15 messages."
}

function Find-ActiveMonitorCaptureSource($ws) {
    # Same "in the current program scene AND sceneItemEnabled=true" filter
    # as obs_monitor.ps1's own Find-ActiveMonitorCaptureSource -- see that
    # file's header comment for why scene membership alone isn't enough.
    $sceneResp = Invoke-ObsRequest $ws "GetCurrentProgramScene"
    $sceneName = $sceneResp.responseData.currentProgramSceneName
    $itemsResp = Invoke-ObsRequest $ws "GetSceneItemList" @{ sceneName = $sceneName }
    $candidates = $itemsResp.responseData.sceneItems | Where-Object { $_.inputKind -eq "monitor_capture" -and $_.sceneItemEnabled -eq $true }
    if (-not $candidates -or $candidates.Count -eq 0) {
        return $null
    }
    return $candidates[0].sourceName
}

function Get-SourceAvgBrightness($ws, $sourceName) {
    # Ground truth, not a proxy: GetSourceScreenshot returns the source's
    # actual rendered pixels. Replaces an earlier check (2026-08-22) that
    # compared the source's monitor_id against OBS's list of enumerable
    # monitors -- confirmed live, twice, that this reported "bound" while
    # the real recorded frame was solid black (OBS can report a valid,
    # resolvable monitor_id well before its capture backend is actually
    # delivering pixels, and in at least one case never did within the
    # observed window at all). A small 64x36 image sampled every 4th
    # pixel is plenty to tell "black" from "real image" and stays fast
    # enough to poll several times per repair attempt.
    $resp = Invoke-ObsRequest $ws "GetSourceScreenshot" @{ sourceName = $sourceName; imageFormat = "png"; imageWidth = 64; imageHeight = 36 }
    $base64 = $resp.responseData.imageData -replace '^data:image/\w+;base64,', ''
    $bytes = [Convert]::FromBase64String($base64)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    try {
        $bmp = New-Object System.Drawing.Bitmap($ms)
        try {
            $total = 0
            $count = 0
            for ($x = 0; $x -lt $bmp.Width; $x += 4) {
                for ($y = 0; $y -lt $bmp.Height; $y += 4) {
                    $px = $bmp.GetPixel($x, $y)
                    $total += ($px.R + $px.G + $px.B)
                    $count++
                }
            }
            return $total / $count
        } finally {
            $bmp.Dispose()
        }
    } finally {
        $ms.Dispose()
    }
}

function Repair-MonitorCaptureSourceBinding() {
    # Never capture an empty/disconnected display. Design agreed
    # 2026-08-22 after live testing ruled out the original approach: only
    # touch OBS at all if the real screenshot shows it's actually broken
    # (skip entirely if already fine, no unconditional side effects on a
    # working setup); if broken, only attempt repair actions confirmed
    # SAFE by live testing -- re-applying the current monitor_id and
    # toggling the scene item's enabled state. Neither is proven to
    # reliably fix a genuinely stuck WGC (Windows Graphics Capture)
    # source (both failed against one live-reproduced stuck case), but
    # both are free and carry no known risk, unlike forcing the capture
    # method to DXGI -- that looked promising in one test but coincided
    # with OBS shutting down in a way that was never confirmed safe, so
    # it is NOT attempted here unattended; it's a manual fix a user can
    # apply themselves (Properties > Capture Method) if this still fails.
    # Bounded retry budget (a handful of 500ms polls per repair action,
    # not 10+ seconds of blind waiting) so a broken run fails fast with a
    # concrete, actionable message instead of hanging or silently
    # recording a black clip.
    $ws = Connect-ObsWebSocket
    try {
        $sourceName = Find-ActiveMonitorCaptureSource $ws
        if (-not $sourceName) {
            throw "No enabled monitor_capture source found in OBS's current scene -- nothing to record into."
        }

        $brightness = Get-SourceAvgBrightness $ws $sourceName
        if ($brightness -gt 3) {
            Write-Host "Monitor capture source '$sourceName' is already showing real content (brightness=$brightness) -- no repair needed."
            return
        }
        Write-Host "Monitor capture source '$sourceName' appears black (brightness=$brightness) -- attempting safe repairs..."

        $settingsResp = Invoke-ObsRequest $ws "GetInputSettings" @{ inputName = $sourceName }
        $monitorId = $settingsResp.responseData.inputSettings.monitor_id
        Invoke-ObsRequest $ws "SetInputSettings" @{ inputName = $sourceName; inputSettings = @{ monitor_id = $monitorId }; overlay = $true } | Out-Null
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Start-Sleep -Milliseconds 500
            $brightness = Get-SourceAvgBrightness $ws $sourceName
            if ($brightness -gt 3) {
                Write-Host "Monitor capture source '$sourceName' recovered after re-applying its monitor selection (attempt $attempt, brightness=$brightness)."
                return
            }
        }

        Write-Host "Re-applying the monitor selection did not help -- trying a scene-item toggle..."
        $sceneResp = Invoke-ObsRequest $ws "GetCurrentProgramScene"
        $sceneName = $sceneResp.responseData.currentProgramSceneName
        $itemsResp = Invoke-ObsRequest $ws "GetSceneItemList" @{ sceneName = $sceneName }
        $item = $itemsResp.responseData.sceneItems | Where-Object { $_.sourceName -eq $sourceName }
        Invoke-ObsRequest $ws "SetSceneItemEnabled" @{ sceneName = $sceneName; sceneItemId = $item.sceneItemId; sceneItemEnabled = $false } | Out-Null
        Start-Sleep -Milliseconds 500
        Invoke-ObsRequest $ws "SetSceneItemEnabled" @{ sceneName = $sceneName; sceneItemId = $item.sceneItemId; sceneItemEnabled = $true } | Out-Null
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Start-Sleep -Milliseconds 500
            $brightness = Get-SourceAvgBrightness $ws $sourceName
            if ($brightness -gt 3) {
                Write-Host "Monitor capture source '$sourceName' recovered after a scene-item toggle (attempt $attempt, brightness=$brightness)."
                return
            }
        }

        throw "Monitor capture source '$sourceName' is still showing a black/empty image (brightness=$brightness) after re-applying its monitor selection and toggling it -- not starting the recording. In OBS, try right-click '$sourceName' > Properties > Capture Method, and switch it from Automatic to DXGI Desktop Duplication."
    } finally {
        try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).Wait() } catch {}
    }
}

function Invoke-ObsRecordAction($action) {
    $ws = Connect-ObsWebSocket
    $requestType = if ($action -eq "start") { "StartRecord" } else { "StopRecord" }
    $requestId = [Guid]::NewGuid().ToString()
    Send-WsMessage $ws @{ op = 6; d = @{ requestType = $requestType; requestId = $requestId } }

    $response = $null
    for ($i = 0; $i -lt 10; $i++) {
        $msg = Receive-WsMessage $ws
        if ($msg.op -eq 7 -and $msg.d.requestId -eq $requestId) { $response = $msg; break }
    }
    try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).Wait() } catch {}

    if (-not $response -or -not $response.d.requestStatus.result) {
        throw "OBS $requestType failed: $($response | ConvertTo-Json -Depth 5)"
    }
    Write-Host "OBS $requestType succeeded."
}

# --- Capture sequence ------------------------------------------------------
# Taskbar is hidden for the duration and always restored in `finally`, even
# if something throws (OBS unreachable, Maya error, etc.) -- never leave the
# user's taskbar missing after a failed run.
Hide-Taskbar
$originalRange = $null
$originalHud = $null
try {
    Ensure-ObsRunning
    Repair-MonitorCaptureSourceBinding

    $resetFrame = 0
    if ($StartFrame -ne $null) {
        Write-Host "Custom range requested ($StartFrame-$EndFrame) -- saving the current range to restore afterward..."
        $originalRange = Get-MayaFrameRange
        Write-Host "  original range: $($originalRange.MinTime)-$($originalRange.MaxTime)"
        Set-MayaFrameRange $StartFrame $EndFrame
        $resetFrame = $StartFrame
    }

    Write-Host "Resetting Maya to frame $resetFrame, forcing loop=once..."
    Send-MayaCode "import maya.cmds as cmds`ncmds.playbackOptions(loop='once')`ncmds.currentTime($resetFrame)`n"
    Start-Sleep -Milliseconds 500

    # Computed here, BEFORE Invoke-ObsRecordAction, not after -- this needs
    # 1-2 Maya round trips (frame range + fps), and doing that AFTER
    # StartRecord would push Send-MayaCode "cmds.play(forward=True)"
    # further away from it, reintroducing exactly the static lead-in this
    # code already goes out of its way to avoid (see the file header
    # comment: playback is meant to start "back-to-back with the recording
    # start").
    if ($StartFrame -ne $null) {
        $activeMin = $StartFrame
        $activeMax = $EndFrame
    } else {
        $activeRange = Get-MayaFrameRange
        $activeMin = $activeRange.MinTime
        $activeMax = $activeRange.MaxTime
    }
    $pollIntervalSec = Get-PlaybackPollIntervalSeconds ($activeMax - $activeMin)

    Write-Host "Saving current Maya HUD state..."
    $originalHud = Get-MayaHudState
    Set-MayaHudState (Get-CaptureHudState $originalHud)
    Write-Host "  HUD forced on for the capture panel(s): $($TargetHudItems -join ', ')"

    Write-Host "Starting OBS recording..."
    Invoke-ObsRecordAction "start"

    Write-Host "Starting Maya playback..."
    Send-MayaCode "import maya.cmds as cmds`ncmds.play(forward=True)`n"

    Write-Host "Waiting for playback to reach the end (polling every $([Math]::Round($pollIntervalSec, 2))s)..."
    $state = "True"
    while ($state -eq "True") {
        Start-Sleep -Seconds $pollIntervalSec
        $state = Get-MayaPlaybackState
        Write-Host "  playback state: $state"
    }

    Write-Host "Playback ended. Stopping OBS recording..."
    Invoke-ObsRecordAction "stop"

    Write-Host "Capture complete."
} finally {
    if ($originalRange -ne $null) {
        Write-Host "Restoring original frame range ($($originalRange.MinTime)-$($originalRange.MaxTime))..."
        Set-MayaFrameRange $originalRange.MinTime $originalRange.MaxTime
    }
    if ($originalHud -ne $null) {
        Write-Host "Restoring original Maya HUD state..."
        Set-MayaHudState $originalHud
        Clear-MayaHudStateFile
    }
    Show-Taskbar
}

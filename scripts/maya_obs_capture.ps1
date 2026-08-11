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
$ScriptDir = $PSScriptRoot

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
    $code = "import maya.cmds as cmds`nwith open(r'$ScriptDir\_playback_state.txt','w') as f:`n    f.write(str(cmds.play(q=True, state=True)))`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
    Start-Sleep -Milliseconds 200
    return (Get-Content "$ScriptDir\_playback_state.txt" -Raw).Trim()
}

function Get-MayaFrameRange() {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 7001)
    $stream = $client.GetStream()
    $code = "import maya.cmds as cmds`nwith open(r'$ScriptDir\_frame_range_state.txt','w') as f:`n    f.write(str(cmds.playbackOptions(q=True, minTime=True)) + ',' + str(cmds.playbackOptions(q=True, maxTime=True)))`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 300
    $stream.Close()
    $client.Close()
    Start-Sleep -Milliseconds 200
    $parts = (Get-Content "$ScriptDir\_frame_range_state.txt" -Raw).Trim().Split(",")
    return [PSCustomObject]@{ MinTime = [double]$parts[0]; MaxTime = [double]$parts[1] }
}

function Set-MayaFrameRange($minTime, $maxTime) {
    Send-MayaCode "import maya.cmds as cmds`ncmds.playbackOptions(minTime=$minTime, maxTime=$maxTime)`n"
}

# --- OBS WebSocket helpers -------------------------------------------------
function Send-WsMessage($ws, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
}

function Receive-WsMessage($ws) {
    $buffer = New-Object byte[] 8192
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $result = $ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
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

function Invoke-ObsRecordAction($action) {
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
try {
    Ensure-ObsRunning

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

    Write-Host "Starting OBS recording..."
    Invoke-ObsRecordAction "start"

    Write-Host "Starting Maya playback..."
    Send-MayaCode "import maya.cmds as cmds`ncmds.play(forward=True)`n"

    Write-Host "Waiting for playback to reach the end..."
    $state = "True"
    while ($state -eq "True") {
        Start-Sleep -Seconds 5
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
    Show-Taskbar
}

# Lists/sets which physical monitor OBS records, via its WebSocket API
# (v5 protocol) -- same connect/auth pattern as obs_control.ps1 (duplicated
# rather than shared, matching this project's established convention of
# small standalone scripts over cross-file imports).
#
# Auto-detects WHICH OBS source to target rather than requiring the user
# to name one: finds the current program scene, then the one
# monitor_capture-kind source actually present IN that scene -- not just
# any monitor_capture source in the whole OBS project. Confirmed live
# (2026-08-20) that a real OBS setup can have several monitor_capture
# sources (leftover/unused test sources included) where only one is
# actually wired into the active recording scene; picking "the first one
# found" project-wide grabbed the wrong source in that exact test.
#
# Usage:
#   powershell -File obs_monitor.ps1 -Action list
#   powershell -File obs_monitor.ps1 -Action set -MonitorId "<raw itemValue from list>"
#
# -Action list writes one line per available monitor to RESULT_PATH:
#   MONITOR_ITEM name="<display name>" value="<raw monitor_id>" current="true|false"
# (current="true" marks whichever the source is set to right now -- NOTE
# this is only "does the configured id resolve," not proof of a working
# capture; see -Action set below for that), or:
#   MONITOR_SOURCE_NOT_FOUND -- no monitor_capture source in the active scene
#   MONITOR_LIST_ERROR <message>
# -Action set applies the change, then verifies it with a real
# GetSourceScreenshot (not just id matching -- confirmed live 2026-08-22
# that a matching id can still be solid black) and writes:
#   MONITOR_SET_OK
#   MONITOR_SET_VERIFIED true|false  -- true only if a real screenshot
#     confirmed non-black content, after one safe repair attempt
#   MONITOR_SET_BRIGHTNESS <0-765 average sample>
#   MONITOR_SET_MESSAGE <human-readable result, actionable if not verified>
#   MONITOR_SET_PREVIEW <path to a saved PNG thumbnail of the current capture>
# or MONITOR_SET_ERROR <message> if the whole operation failed outright.

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("list", "set")]
    [string]$Action,
    [string]$MonitorId,
    # Opt-in only -- NOT the default for a plain -Action list, since the
    # launcher's own startup check must never surprise-launch OBS just
    # because the window opened (design 2026-08-22). Only the explicit
    # Refresh button and the "just saved the OBS password" flow pass
    # this, both deliberate user actions that justify a cold OBS launch.
    [switch]$EnsureRunning
)

if ($Action -eq "set" -and -not $MonitorId) {
    throw "-MonitorId is required with -Action set."
}

Add-Type -AssemblyName System.Drawing

$ScriptDir = $PSScriptRoot
$resultPath = Join-Path $ScriptDir "..\d4_anim_sample\_obs_monitor_result.txt"
$resultDir = Split-Path $resultPath -Parent
if (-not (Test-Path $resultDir)) {
    New-Item -ItemType Directory -Path $resultDir | Out-Null
}

function Test-ObsPortReachable($ObsHost, $Port, [int]$TimeoutMs = 500) {
    # Same bounded-TCP-probe pattern as rom_launcher.ps1's own
    # Test-MayaPortReachable, and for the same reason: a plain
    # ConnectAsync(...).Wait() against a closed port throws a nested
    # AggregateException whose top-level message PowerShell renders as
    # the unhelpful "Exception calling 'Wait' with '0' argument(s): 'One
    # or more errors occurred.'" (confirmed live, 2026-08-21, when OBS
    # simply wasn't running) -- checking reachability first, before ever
    # attempting the real WebSocket handshake, means the common "OBS
    # isn't open" case gets a clear message instead of that exception
    # text.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ObsHost, $Port, $null, $null)
        $completed = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($completed -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Send-WsMessage($ws, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
}

function Receive-WsMessage($ws) {
    # Loops until EndOfMessage instead of trusting one ReceiveAsync call to
    # return the whole thing -- fine for the short list/set responses this
    # originally handled, but GetSourceScreenshot's base64 image payload
    # (added 2026-08-22, see Get-SourceAvgBrightness) can span more than
    # one WebSocket frame.
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
    $authResponse = [Convert]::ToBase64String($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($secret + $challenge)))
    return $authResponse
}

function Invoke-ObsRequest($ws, $requestType, $requestData = @{}) {
    $requestId = [Guid]::NewGuid().ToString()
    $request = @{ op = 6; d = @{ requestType = $requestType; requestId = $requestId; requestData = $requestData } }
    Send-WsMessage $ws $request
    for ($i = 0; $i -lt 15; $i++) {
        $msg = Receive-WsMessage $ws
        if ($msg.op -eq 7 -and $msg.d.requestId -eq $requestId) { return $msg.d }
    }
    throw "No RequestResponse received for $requestType after 15 messages."
}

function Find-ActiveMonitorCaptureSource($ws) {
    # The current PROGRAM scene, not just any scene in the collection --
    # a source sitting unused in a different scene shouldn't be a
    # candidate. AND sceneItemEnabled=true (the eye-icon-on/visible state)
    # -- confirmed live (2026-08-20) that scene membership alone is NOT
    # enough to disambiguate: a real OBS setup had THREE monitor_capture
    # sources all sitting in the same active scene at once ("screen 2",
    # "Screen 1", "ROM capture"), where only "ROM capture" -- the one
    # actually recorded -- had sceneItemEnabled=true; the other two were
    # leftover/unused sources with their eye icon off. Filtering on this
    # flag is what actually identifies "the one OBS is really compositing
    # into the recording," not just "a monitor_capture source that
    # happens to exist somewhere in this scene."
    $sceneResp = Invoke-ObsRequest $ws "GetCurrentProgramScene"
    $sceneName = $sceneResp.responseData.currentProgramSceneName
    $itemsResp = Invoke-ObsRequest $ws "GetSceneItemList" @{ sceneName = $sceneName }
    $candidates = $itemsResp.responseData.sceneItems | Where-Object { $_.inputKind -eq "monitor_capture" -and $_.sceneItemEnabled -eq $true }
    if (-not $candidates -or $candidates.Count -eq 0) {
        return $null
    }
    # If more than one is BOTH in the scene AND enabled, take the first --
    # genuinely ambiguous beyond that without more information than OBS's
    # WebSocket API exposes about "which one is the real one."
    return $candidates[0].sourceName
}

function Get-SourceAvgBrightness($ws, $sourceName) {
    # Ground truth for "did this change actually work," not a proxy:
    # GetSourceScreenshot returns the source's real rendered pixels.
    # Comparing monitor_id against the list of enumerable monitors (the
    # "current" flag above) is a UI-population concern, not a verification
    # one -- confirmed live (2026-08-22) that a matching, resolvable
    # monitor_id can be reported while the actual capture is solid black.
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
            return [PSCustomObject]@{ Brightness = ($total / $count); Bytes = $bytes }
        } finally {
            $bmp.Dispose()
        }
    } finally {
        $ms.Dispose()
    }
}

try {
    $configPath = Join-Path $ScriptDir "obs_config.txt"
    $configText = Get-Content $configPath -Raw
    $host_ = ([regex]::Match($configText, 'host:\s*(\S+)')).Groups[1].Value
    $port = ([regex]::Match($configText, 'port:\s*(\S+)')).Groups[1].Value
    $password = ([regex]::Match($configText, 'password:\s*(\S+)')).Groups[1].Value

    if ($EnsureRunning -and -not (Test-ObsPortReachable -ObsHost $host_ -Port $port)) {
        # Same launch-and-wait logic as maya_obs_capture.ps1's own
        # Ensure-ObsRunning -- duplicated, not shared, matching this
        # project's established convention (see this file's own header
        # comment). Bounded at 60s, same as that copy.
        $obsExe = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
        $running = Get-Process -Name "obs64" -ErrorAction SilentlyContinue
        if (-not $running) {
            Start-Process -FilePath $obsExe -WorkingDirectory (Split-Path $obsExe)
        }
        $waited = 0
        while (-not (Test-ObsPortReachable -ObsHost $host_ -Port $port)) {
            Start-Sleep -Seconds 2
            $waited += 2
            if ($waited -ge 60) {
                break
            }
        }
    }

    if (-not (Test-ObsPortReachable -ObsHost $host_ -Port $port)) {
        throw "Could not connect to OBS at ${host_}:${port} -- is OBS Studio running, with Tools > WebSocket Server Settings > Enable WebSocket Server checked?"
    }

    $uri = [Uri]::new("ws://${host_}:${port}")
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait()

    $hello = Receive-WsMessage $ws
    $identify = @{ op = 1; d = @{ rpcVersion = 1 } }
    if ($hello.d.authentication) {
        $auth = Get-AuthString -password $password -salt $hello.d.authentication.salt -challenge $hello.d.authentication.challenge
        $identify.d.authentication = $auth
    }
    Send-WsMessage $ws $identify
    $identified = Receive-WsMessage $ws
    if ($identified.op -ne 2) {
        throw "Failed to identify with OBS WebSocket."
    }

    $sourceName = Find-ActiveMonitorCaptureSource $ws
    if (-not $sourceName) {
        Set-Content -Path $resultPath -Value "MONITOR_SOURCE_NOT_FOUND" -Encoding UTF8
        Write-Output "MONITOR_SOURCE_NOT_FOUND"
    } elseif ($Action -eq "list") {
        $settingsResp = Invoke-ObsRequest $ws "GetInputSettings" @{ inputName = $sourceName }
        $currentMonitorId = $settingsResp.responseData.inputSettings.monitor_id

        $propsResp = Invoke-ObsRequest $ws "GetInputPropertiesListPropertyItems" @{ inputName = $sourceName; propertyName = "monitor_id" }
        $lines = @()
        foreach ($item in $propsResp.responseData.propertyItems) {
            # TrimStart('\'), not a plain -eq -- confirmed live (2026-08-20)
            # that OBS itself returns the SAME monitor's id with a
            # different number of leading backslashes depending on which
            # request asked for it: GetInputSettings said
            # "\?\DISPLAY#..." (one backslash) while
            # GetInputPropertiesListPropertyItems said "\\?\DISPLAY#..."
            # (two, the standard Win32 extended-length-path prefix) for
            # the literal same physical monitor. An exact string compare
            # would mark EVERY option "not current" even when one
            # genuinely is.
            $isCurrent = if ($item.itemValue.TrimStart('\') -eq $currentMonitorId.TrimStart('\')) { "true" } else { "false" }
            $lines += 'MONITOR_ITEM name="{0}" value="{1}" current="{2}"' -f $item.itemName, $item.itemValue, $isCurrent
        }
        $lines | Set-Content -Path $resultPath -Encoding UTF8
        $lines | ForEach-Object { Write-Output $_ }
    } else {
        # overlay=true is REQUIRED here, not a default -- confirmed live
        # (2026-08-20) against a real OBS instance: omitting it made
        # SetInputSettings return requestStatus.result=true (no error at
        # all) while silently leaving monitor_id completely unchanged. A
        # subsequent GetInputSettings was the only way that was caught.
        Invoke-ObsRequest $ws "SetInputSettings" @{ inputName = $sourceName; inputSettings = @{ monitor_id = $MonitorId }; overlay = $true } | Out-Null

        # A brief settle delay before the FIRST screenshot -- confirmed
        # live (2026-08-22) via image-hash polling that GetSourceScreenshot
        # taken immediately after SetInputSettings can return a STALE
        # frame from the PREVIOUS monitor: OBS's own capture backend
        # takes a real (short but variable, observed ~10-300ms) moment to
        # actually re-bind to the new display after the setting itself
        # has already applied. Without this, the preview thumbnail shown
        # to the user could visibly show the WRONG monitor even though
        # brightness verification passes (a real, non-black image -- just
        # the old one) and OBS's own live state is already correct by the
        # time anyone checks it separately. This is exactly what was
        # reported live: "the change is reflected in OBS, but the preview
        # shows the wrong monitor."
        Start-Sleep -Milliseconds 400

        # Verify with a real screenshot instead of reporting success just
        # because the API call didn't error -- design agreed 2026-08-22:
        # a user-initiated monitor change should show a REAL verified
        # result (working preview, or a concrete warning), not a blind
        # "done" that might be lying (see Get-SourceAvgBrightness).
        $shot = Get-SourceAvgBrightness $ws $sourceName
        $verified = $shot.Brightness -gt 3
        if (-not $verified) {
            # One safe repair attempt (re-toggle the scene item) before
            # giving up and reporting the honest black result -- matches
            # maya_obs_capture.ps1's Repair-MonitorCaptureSourceBinding,
            # but shorter here since a user is actively waiting on this
            # dialog rather than an unattended capture run.
            $sceneResp = Invoke-ObsRequest $ws "GetCurrentProgramScene"
            $sceneName = $sceneResp.responseData.currentProgramSceneName
            $itemsResp = Invoke-ObsRequest $ws "GetSceneItemList" @{ sceneName = $sceneName }
            $item = $itemsResp.responseData.sceneItems | Where-Object { $_.sourceName -eq $sourceName }
            if ($item) {
                Invoke-ObsRequest $ws "SetSceneItemEnabled" @{ sceneName = $sceneName; sceneItemId = $item.sceneItemId; sceneItemEnabled = $false } | Out-Null
                Start-Sleep -Milliseconds 500
                Invoke-ObsRequest $ws "SetSceneItemEnabled" @{ sceneName = $sceneName; sceneItemId = $item.sceneItemId; sceneItemEnabled = $true } | Out-Null
                for ($attempt = 1; $attempt -le 4; $attempt++) {
                    Start-Sleep -Milliseconds 500
                    $shot = Get-SourceAvgBrightness $ws $sourceName
                    if ($shot.Brightness -gt 3) { $verified = $true; break }
                }
            }
        }

        $previewPath = Join-Path $ScriptDir "..\d4_anim_sample\_obs_monitor_preview.png"
        [System.IO.File]::WriteAllBytes($previewPath, $shot.Bytes)

        $message = if ($verified) {
            "Confirmed showing real content (brightness=$($shot.Brightness))."
        } else {
            "Still showing a black/empty image (brightness=$($shot.Brightness)) after re-applying and toggling the source. In OBS, try right-click '$sourceName' > Properties > Capture Method, and switch it from Automatic to DXGI Desktop Duplication."
        }

        $lines = @(
            "MONITOR_SET_OK",
            "MONITOR_SET_VERIFIED $(if ($verified) { 'true' } else { 'false' })",
            "MONITOR_SET_BRIGHTNESS $($shot.Brightness)",
            "MONITOR_SET_MESSAGE $message",
            "MONITOR_SET_PREVIEW $previewPath"
        )
        $lines | Set-Content -Path $resultPath -Encoding UTF8
        $lines | ForEach-Object { Write-Output $_ }
    }

    try {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).Wait()
    } catch {
        # OBS sometimes closes its end first after the response -- harmless.
    }
} catch {
    $prefix = if ($Action -eq "list") { "MONITOR_LIST_ERROR" } else { "MONITOR_SET_ERROR" }
    $line = "$prefix $($_.Exception.Message)"
    Set-Content -Path $resultPath -Value $line -Encoding UTF8
    Write-Output $line
}

# Controls OBS Studio recording via its WebSocket API (v5 protocol).
# Reads connection info from obs_config.txt (same folder).
#
# Usage:
#   powershell -File obs_control.ps1 -Action start
#   powershell -File obs_control.ps1 -Action stop

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop")]
    [string]$Action
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "obs_config.txt"
$configText = Get-Content $configPath -Raw
$host_ = ([regex]::Match($configText, 'host:\s*(\S+)')).Groups[1].Value
$port = ([regex]::Match($configText, 'port:\s*(\S+)')).Groups[1].Value
$password = ([regex]::Match($configText, 'password:\s*(\S+)')).Groups[1].Value

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
    $authResponse = [Convert]::ToBase64String($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($secret + $challenge)))
    return $authResponse
}

$uri = [Uri]::new("ws://${host_}:${port}")
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait()

# Op 0: Hello
$hello = Receive-WsMessage $ws

$identify = @{
    op = 1
    d = @{
        rpcVersion = 1
    }
}
if ($hello.d.authentication) {
    $auth = Get-AuthString -password $password -salt $hello.d.authentication.salt -challenge $hello.d.authentication.challenge
    $identify.d.authentication = $auth
}
Send-WsMessage $ws $identify

# Op 2: Identified
$identified = Receive-WsMessage $ws
if ($identified.op -ne 2) {
    Write-Error "Failed to identify with OBS WebSocket: $($identified | ConvertTo-Json -Depth 5)"
    exit 1
}

$requestType = if ($Action -eq "start") { "StartRecord" } else { "StopRecord" }
$requestId = [Guid]::NewGuid().ToString()
$request = @{
    op = 6
    d = @{
        requestType = $requestType
        requestId = $requestId
    }
}
Send-WsMessage $ws $request

# Op 7: RequestResponse -- skip over any Op 5 (Event) messages that may
# arrive interleaved (e.g. RecordStateChanged) until we get our actual reply.
$response = $null
for ($i = 0; $i -lt 10; $i++) {
    $msg = Receive-WsMessage $ws
    if ($msg.op -eq 7 -and $msg.d.requestId -eq $requestId) {
        $response = $msg
        break
    }
}
if (-not $response) {
    Write-Error "No RequestResponse received for $requestType after 10 messages."
    exit 1
}
$status = $response.d.requestStatus
if ($status.result) {
    Write-Host "OBS $requestType succeeded."
} else {
    Write-Error "OBS $requestType failed: $($status | ConvertTo-Json -Depth 5)"
}

try {
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).Wait()
} catch {
    # OBS sometimes closes its end first after the response -- harmless.
}

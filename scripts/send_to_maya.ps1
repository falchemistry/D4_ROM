# Sends Python code to a running Maya session over its command port and
# blocks until Maya actually finishes executing it, reporting back whatever
# it wrote (a return value's repr, print() output, or a traceback).
#
# -ScriptPath sends a one-line wrapper -- exec(compile(open(path).read(),
# path, 'exec'), {}) -- instead of the raw file content, so the script runs
# in its OWN fresh, isolated namespace every time. Found 2026-08-11: Maya's
# command port appears to reuse a shared/persistent namespace across many
# sends over a long session, and a script sent as raw top-level content can
# silently no-op (no exception, no print output, nothing) once that shared
# namespace accumulates enough state -- confirmed by re-running the exact
# same file wrapped in an isolated exec({}) and having it work when the
# raw send did not. See d4_rom_capture_pipeline memory for the full story.
#
# Requires Maya to have run: cmds.commandPort(name=':7001', sourceType='python')
#
# Usage:
#   powershell -File send_to_maya.ps1 -ScriptPath action.py
#   powershell -File send_to_maya.ps1 -Code "cmds.polyCube()"
#   powershell -File send_to_maya.ps1 -ScriptPath slow_script.py -TimeoutMs 1800000

param(
    [string]$ScriptPath,
    [string]$Code,
    [string]$MayaHost = "127.0.0.1",
    [int]$Port = 7001,
    # 20 minutes by default -- comfortably above maya_cache_bbox.py's
    # documented 10-16 minute worst case (see maya_key_from_cache.py,
    # which triggers it inline on a cache miss). Override for scripts
    # expected to run even longer.
    [int]$TimeoutMs = 1200000
)

if (-not $Code -and -not $ScriptPath) {
    Write-Error "Provide -ScriptPath <file.py> or -Code '<python code>'"
    exit 1
}

if ($ScriptPath) {
    $resolvedPath = (Resolve-Path $ScriptPath).Path
    $escapedPath = $resolvedPath.Replace("'", "\'")
    $source = "exec(compile(open(r'$escapedPath').read(), r'$escapedPath', 'exec'), {})"
} else {
    $source = $Code
}

$payload = $source + [Environment]::NewLine

$client = New-Object System.Net.Sockets.TcpClient($MayaHost, $Port)
$stream = $client.GetStream()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$stream.Write($bytes, 0, $bytes.Length)

# Block until Maya actually finishes executing the payload and starts
# writing back its result/traceback -- confirmed empirically (2026-08-19)
# that Maya's command port genuinely waits for execution to complete
# before replying: a deliberate 3-second time.sleep() in a test payload
# made this read take 6+ seconds, not return instantly. The PREVIOUS
# version of this script slept a fixed 300ms and closed WITHOUT reading
# anything -- meaning callers (like rom_launcher.ps1's step queue) saw
# this process exit almost immediately regardless of how long the actual
# Maya-side execution took, racing ahead into the next queued step while
# Maya was still mid-execution (e.g. a 10-16 minute cache build silently
# triggered by maya_key_from_cache.py on a cache miss).
#
# Also confirmed empirically: Maya does NOT close its side of the
# connection after replying (a follow-up read times out rather than
# hitting a clean EOF/0-byte read), so there's no "connection closed"
# signal to loop on. Instead: the FIRST read uses the long $TimeoutMs
# (that's what actually waits for Maya to finish), then any further
# buffered output is drained with a short timeout until a read goes
# quiet -- that quiet period is what marks the response as complete.
$responseBytes = New-Object System.Collections.Generic.List[byte]
$buffer = New-Object byte[] 4096
$timedOut = $false

$stream.ReadTimeout = $TimeoutMs
try {
    $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
    if ($bytesRead -gt 0) {
        # PowerShell's range-slice of a byte[] boxes the result as a plain
        # Object[], which List[byte].AddRange() (a strongly-typed generic)
        # refuses to accept -- an explicit [byte[]] cast fixes it.
        $responseBytes.AddRange([byte[]]$buffer[0..($bytesRead - 1)])
    }
} catch [System.IO.IOException] {
    $timedOut = $true
}

if (-not $timedOut) {
    $stream.ReadTimeout = 300
    while ($true) {
        try {
            $more = $stream.Read($buffer, 0, $buffer.Length)
            if ($more -eq 0) { break }
            $responseBytes.AddRange([byte[]]$buffer[0..($more - 1)])
        } catch {
            break
        }
    }
}

$stream.Close()
$client.Close()

if ($timedOut) {
    Write-Host "No response from Maya within $($TimeoutMs)ms -- it may still be running. Not treating this as a failure (Maya's command port has no way to report progress mid-script), but if this keeps happening, check the Script Editor."
} else {
    # Maya's reply ends with a trailing NUL byte (confirmed empirically --
    # a 6-byte reply for the 4-character text "None" plus a newline and
    # this byte), which .Trim() does not remove since it is not standard
    # whitespace.
    $response = ([System.Text.Encoding]::UTF8.GetString($responseBytes.ToArray()) -replace "\0", "").Trim()
    if ($response -and $response -ne "None") {
        Write-Host "Maya response: $response"
    }
}
Write-Host "Sent to Maya command port $MayaHost`:$Port"

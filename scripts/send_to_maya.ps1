# Sends Python code to a running Maya session over its command port and
# reports back any exception, since Maya's command port does not surface
# tracebacks to the Script Editor on its own.
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

param(
    [string]$ScriptPath,
    [string]$Code,
    [string]$MayaHost = "127.0.0.1",
    [int]$Port = 7001
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
Start-Sleep -Milliseconds 300
$stream.Close()
$client.Close()
Write-Host "Sent to Maya command port $MayaHost`:$Port"

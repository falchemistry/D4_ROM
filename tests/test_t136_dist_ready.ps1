# Persistent test for T136 (dist-ready quick fixes, W3 of the T135 review):
#   R8  send_to_maya.ps1: an install path with an apostrophe must reach Maya
#       as the same path (the old payload turned ' into \' inside a raw
#       string and Python kept the backslash).
#   R7  OBS exe lookup (Find-ObsExe, in maya_obs_capture.ps1 and obs_monitor.ps1,
#       duplicated on purpose like the rest of this project's standalone
#       scripts): running process, then registry, then default locations,
#       then an optional "exe:" line in obs_config.txt; a miss says
#       "OBS not found at ..." instead of "did not become reachable after 60
#       seconds". The Maya port lives in ONE setting (-MayaPort, default 7001)
#       in maya_obs_capture.ps1.
#   R14 build_dist.ps1 refuses a -DistDir that equals, contains or lies inside
#       the tool root BEFORE any Remove-Item.
#
# Safety: never starts Maya or OBS, never opens a window. R8 talks to a fake
# one-shot listener on a free 127.0.0.1 port (never 7001). Every R14 build runs
# a COPY of the tool inside a throw-away temp folder (build_dist.ps1 is run
# from that copy, so even the old, unguarded script can only delete the copy).
# The real repo and the real ..\d4_rom_dist are never given to a build.
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_t136_dist_ready.ps1 [-Root <tree>]
# -Root is optional (default: this repo); give it another tree (for example a
# copy of an older commit) to see the checks go red on it.
# Exits 0 if all checks pass, 1 otherwise. One flushed START and one result
# line per case, so a hang names the culprit.

param([string]$Root = "")

$RepoRoot = if ($Root) { [IO.Path]::GetFullPath($Root) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")) }
$SendToMaya = Join-Path $RepoRoot "scripts\maya\send_to_maya.ps1"
$CaptureScript = Join-Path $RepoRoot "scripts\capture\maya_obs_capture.ps1"
$MonitorScript = Join-Path $RepoRoot "scripts\obs\obs_monitor.ps1"
$BuildDist = Join-Path $RepoRoot "build_dist.ps1"
$TempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$failures = @()
$passed = 0

function Check($name, [scriptblock]$body) {
    Write-Output "START $name"
    [Console]::Out.Flush()
    try {
        & $body
        $script:passed++
        Write-Output "PASS  $name"
    } catch {
        $script:failures += "$name`: $($_.Exception.Message)"
        Write-Output "FAIL  $name -- $($_.Exception.Message)"
    }
    [Console]::Out.Flush()
}

function New-TempDir([string]$tag) {
    $d = Join-Path $TempRoot ("t136_" + $tag + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# Load the named functions out of a script file without running the script.
function Import-FunctionsFrom([string]$path, [string[]]$names) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$path does not parse: $($errors[0].Message)" }
    $found = @()
    foreach ($n in $names) {
        $def = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true) | Select-Object -First 1
        if (-not $def) { throw "function $n not found in $(Split-Path $path -Leaf)" }
        $found += $def.Extent.Text
    }
    return $found
}
# @() keeps a single returned string a one-element array; without it [0] would
# be the first CHARACTER of the text and every comparison below would pass.
function FunctionText([string]$path, [string]$name) { return @(Import-FunctionsFrom $path @($name))[0] }
function Test-SameText([string]$a, [string]$b) { return ($a -ceq $b) }

# ============================================================== R8
$PyEval = @'
import sys, json
payload = open(sys.argv[1], 'rb').read().decode('utf-8').rstrip('\r\n')
seen = {}
class F(object):
    def read(self): return ''
def fake_open(p, *a): seen['open'] = p; return F()
def fake_compile(src, p, mode): seen['compile'] = p; return None
def fake_exec(code, g): seen['exec'] = True
ns = {'open': fake_open, 'compile': fake_compile, 'exec': fake_exec, 'bytearray': bytearray}
exec(payload, ns)
sys.stdout.write(json.dumps(seen))
'@

# Runs send_to_maya.ps1 -ScriptPath <py> against a fake listener and returns the
# payload text Maya would have received.
function Get-SentPayload([string]$pyPath) {
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$SendToMaya`" -ScriptPath `"$pyPath`" -Port $port -TimeoutMs 20000"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $listener.Pending()) {
            if ((Get-Date) -gt $deadline) { throw "send_to_maya.ps1 never connected to the fake listener" }
            Start-Sleep -Milliseconds 50
        }
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 4096
        do {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $ms.Write($buf, 0, $n) }
        } while ($n -gt 0 -and $ms.ToArray()[$ms.Length - 1] -ne 10)
        $reply = [Text.Encoding]::UTF8.GetBytes("None`n") + [byte[]]@(0)
        $stream.Write($reply, 0, $reply.Length)
        $stream.Flush()
        if (-not $proc.WaitForExit(30000)) { throw "send_to_maya.ps1 did not exit after the fake reply" }
        $client.Close()
        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally {
        $listener.Stop()
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    }
}

$r8Base = New-TempDir "r8"
$evalPy = Join-Path $r8Base "_eval_payload.py"
[IO.File]::WriteAllText($evalPy, $PyEval, (New-Object System.Text.ASCIIEncoding))
# non-ASCII built from code points so this file stays ASCII (233 = e-acute, 8364 = euro sign)
$r8Names = @("plain", "john's tools", "o'brien's 'x' dir", "with space", "a[1] b", "a[1] b's", ("caf" + [char]233 + " d'x"), ("eur" + [char]8364 + " o'k"))
foreach ($dirName in $r8Names) {
    Check "R8 payload for path dir '$dirName' evaluates to the same path in python" {
        $dir = Join-Path $r8Base $dirName
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $py = Join-Path $dir "x.py"
        [IO.File]::WriteAllText($py, "pass`n", (New-Object System.Text.ASCIIEncoding))
        $resolved = (Resolve-Path -LiteralPath $py).Path
        $payload = Get-SentPayload $resolved
        $pf = Join-Path $r8Base "payload.txt"
        [IO.File]::WriteAllBytes($pf, [Text.Encoding]::UTF8.GetBytes($payload))
        $out = & python -I $evalPy $pf
        if ($LASTEXITCODE -ne 0) { throw "python could not evaluate the payload (exit $LASTEXITCODE): $payload" }
        $seen = $out | ConvertFrom-Json
        if ($seen.open -ne $resolved) { throw "open() got '$($seen.open)' expected '$resolved'" }
        if ($seen.compile -ne $resolved) { throw "compile() got '$($seen.compile)' expected '$resolved'" }
        if (-not $seen.exec) { throw "payload did not reach exec()" }
    }
}
Check "R8 plain path payload text is unchanged (raw string, as before)" {
    $dir = Join-Path $r8Base "plain"
    $resolved = (Resolve-Path -LiteralPath (Join-Path $dir "x.py")).Path
    $payload = (Get-SentPayload $resolved).TrimEnd("`r", "`n")
    $expect = "exec(compile(open(r'$resolved').read(), r'$resolved', 'exec'), {})"
    if ($payload -ne $expect) { throw "payload changed: $payload" }
}
Remove-Item -LiteralPath $r8Base -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================== R7 lookup
# Returns the source of the two finder functions; each case runs it through
# Invoke-Expression in its OWN scope (a function would drop them on return).
function Get-ObsFinderSource([string]$scriptPath) {
    return (Import-FunctionsFrom $scriptPath @("Find-ObsExe", "Get-ObsNotFoundMessage")) -join "`n"
}
function New-FakeExe([string]$dir, [string]$rel) {
    $p = Join-Path $dir $rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, "x", (New-Object System.Text.ASCIIEncoding))
    return $p
}

foreach ($scriptPath in @($CaptureScript, $MonitorScript)) {
    $leaf = Split-Path $scriptPath -Leaf
    Check "R7 [$leaf] Find-ObsExe: running process wins over registry, default and exe: line" {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $d = New-TempDir "r7a"
        try {
            $run = New-FakeExe $d "run\obs64.exe"
            $reg = New-FakeExe $d "reg\bin\64bit\obs64.exe"
            $def = New-FakeExe $d "def\obs64.exe"
            $cfg = New-FakeExe $d "cfg\obs64.exe"
            $r = Find-ObsExe -ConfigText "exe: $cfg" -RunningPaths @($run) -RegistryDirs @((Join-Path $d "reg")) -DefaultPaths @($def)
            if ($r.Path -ne $run) { throw "expected the running process path, got '$($r.Path)'" }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Check "R7 [$leaf] Find-ObsExe: registry install dir, then default, then exe: line (in that order)" {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $d = New-TempDir "r7b"
        try {
            $reg = New-FakeExe $d "reg\bin\64bit\obs64.exe"
            $def = New-FakeExe $d "def\obs64.exe"
            $cfg = New-FakeExe $d "cfg\obs64.exe"
            $r = Find-ObsExe -ConfigText "exe: $cfg" -RunningPaths @() -RegistryDirs @((Join-Path $d "reg")) -DefaultPaths @($def)
            if ($r.Path -ne $reg) { throw "registry: got '$($r.Path)'" }
            $r = Find-ObsExe -ConfigText "exe: $cfg" -RunningPaths @() -RegistryDirs @((Join-Path $d "nothere")) -DefaultPaths @($def)
            if ($r.Path -ne $def) { throw "default: got '$($r.Path)'" }
            $r = Find-ObsExe -ConfigText "host: 127.0.0.1`nexe: $cfg`nport: 1" -RunningPaths @() -RegistryDirs @() -DefaultPaths @((Join-Path $d "nothere.exe"))
            if ($r.Path -ne $cfg) { throw "exe: line: got '$($r.Path)'" }
            $r = Find-ObsExe -ConfigText "exe: `"$cfg`"  " -RunningPaths @() -RegistryDirs @() -DefaultPaths @()
            if ($r.Path -ne $cfg) { throw "quoted exe: line: got '$($r.Path)'" }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Check "R7 [$leaf] Find-ObsExe: nothing found returns no path, lists every location tried, message says 'OBS not found at'" {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $d = New-TempDir "r7c"
        try {
            $missDef = Join-Path $d "def\obs64.exe"
            $missCfg = Join-Path $d "cfg\obs64.exe"
            $missRun = Join-Path $d "run\obs64.exe"
            $r = Find-ObsExe -ConfigText "exe: $missCfg" -RunningPaths @($missRun) -RegistryDirs @((Join-Path $d "reg")) -DefaultPaths @($missDef)
            if ($r.Path) { throw "found '$($r.Path)' although nothing exists" }
            foreach ($want in @($missDef, $missCfg, $missRun, (Join-Path $d "reg\bin\64bit\obs64.exe"))) {
                if (@($r.Tried) -notcontains $want) { throw "Tried list lacks $want : $(@($r.Tried) -join ' | ')" }
            }
            $msg = Get-ObsNotFoundMessage $r.Tried
            if ($msg -notmatch '^OBS not found at ') { throw "message does not start with 'OBS not found at': $msg" }
            if ($msg -notlike "*$missDef*") { throw "message does not name the path tried: $msg" }
            if ($msg -match 'did not become reachable') { throw "message still blames reachability: $msg" }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Check "R7 [$leaf] Find-ObsExe: default (un-injected) call returns an object and never throws" {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $r = Find-ObsExe -ConfigText ""
        if (-not $r) { throw "no result object" }
        if (@($r.Tried).Count -lt 1) { throw "no locations tried" }
    }
}
Check "R7 Find-ObsExe: a bad candidate (stale registry value, quoted value, missing drive, illegal characters) never throws; the next location is tried" {
    foreach ($scriptPath in @($CaptureScript, $MonitorScript)) {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $leaf = Split-Path $scriptPath -Leaf
        $d = New-TempDir "r7f"
        try {
            $def = New-FakeExe $d "def\obs64.exe"
            $quotedDir = Join-Path $d "q uoted"
            $quoted = New-FakeExe $d "q uoted\bin\64bit\obs64.exe"
            $bad = @("Z:\t136_no_such_drive\obs-studio", "bad<>|chars:\x", "  ", "C:\t136\`"half quoted")
            try { $r = Find-ObsExe -ConfigText "" -RunningPaths @() -RegistryDirs $bad -DefaultPaths @($def) } catch { throw "[$leaf] threw on a bad registry value: $($_.Exception.Message)" }
            if ($r.Path -ne $def) { throw "[$leaf] did not move on to the default location, got '$($r.Path)'" }
            try { $r = Find-ObsExe -ConfigText "" -RunningPaths @() -RegistryDirs @("`"$quotedDir`"") -DefaultPaths @() } catch { throw "[$leaf] threw on a quoted registry value: $($_.Exception.Message)" }
            if ($r.Path -ne $quoted) { throw "[$leaf] quoted registry value not usable, got '$($r.Path)'" }
            try { $r = Find-ObsExe -ConfigText "exe: C:\t136?bad|path\obs64.exe" -RunningPaths @("Q:\t136_gone\obs64.exe", "bad<>|run") -RegistryDirs $bad -DefaultPaths @("<>|") } catch { throw "[$leaf] threw with only bad candidates: $($_.Exception.Message)" }
            if ($r.Path) { throw "[$leaf] found '$($r.Path)' among only bad candidates" }
            $msg = Get-ObsNotFoundMessage $r.Tried
            if ($msg -notmatch '^OBS not found at ') { throw "[$leaf] message: $msg" }
            if ($msg -match '60 seconds|did not become reachable') { throw "[$leaf] message blames reachability: $msg" }
            if (@($r.Tried).Count -lt 3) { throw "[$leaf] Tried list too short: $(@($r.Tried) -join ' | ')" }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Check "R7 Find-ObsExe: a folder (not a file) named like the exe is not accepted" {
    foreach ($scriptPath in @($CaptureScript, $MonitorScript)) {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $d = New-TempDir "r7g"
        try {
            $dirAsExe = Join-Path $d "obs64.exe"
            New-Item -ItemType Directory -Path $dirAsExe | Out-Null
            $r = Find-ObsExe -ConfigText "exe: $dirAsExe" -RunningPaths @($dirAsExe) -RegistryDirs @() -DefaultPaths @($dirAsExe)
            if ($r.Path) { throw "[$(Split-Path $scriptPath -Leaf)] accepted a directory: $($r.Path)" }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Check "R7 Find-ObsExe: reads the install folder from the registry keys it is given (temp HKCU key, removed afterwards)" {
    foreach ($scriptPath in @($CaptureScript, $MonitorScript)) {
        Invoke-Expression (Get-ObsFinderSource $scriptPath)
        $d = New-TempDir "r7h"
        $key = "HKCU:\SOFTWARE\T136_test_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        try {
            $exe = New-FakeExe $d "inst\bin\64bit\obs64.exe"
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -LiteralPath $key -Name "(default)" -Value (Join-Path $d "inst")
            $r = Find-ObsExe -ConfigText "" -RunningPaths @() -RegistryKeys @("HKCU:\SOFTWARE\T136_no_such_key", $key) -DefaultPaths @()
            if ($r.Path -ne $exe) { throw "[$(Split-Path $scriptPath -Leaf)] registry key not read: '$($r.Path)'" }
            if ($r.Source -ne "registry") { throw "source is '$($r.Source)'" }
        } finally {
            Remove-Item -LiteralPath $key -Force -ErrorAction SilentlyContinue
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
Check "R7 Find-ObsExe default registry keys and default locations are the real OBS ones" {
    foreach ($p in @($CaptureScript, $MonitorScript)) {
        $t = FunctionText $p "Find-ObsExe"
        foreach ($want in @('HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio', 'HKCU:\SOFTWARE\OBS Studio', 'C:\Program Files\obs-studio\bin\64bit\obs64.exe', 'obs-studio\bin\64bit\obs64.exe', 'bin\64bit\obs64.exe')) {
            if (-not $t.Contains($want)) { throw "$(Split-Path $p -Leaf): Find-ObsExe lacks '$want'" }
        }
    }
}
Check "R7 -MayaPort is range checked 1..65535 (checked on the parsed attribute; the script is never run)" {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($CaptureScript, [ref]$tokens, [ref]$errors)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "MayaPort" }
    if (-not $param) { throw "no -MayaPort parameter" }
    $vr = @($param.Attributes | Where-Object { $_.TypeName.Name -eq "ValidateRange" })
    if ($vr.Count -ne 1) { throw "no [ValidateRange] on -MayaPort" }
    $rangeArgs = @($vr[0].PositionalArguments | ForEach-Object { $_.Extent.Text })
    if (($rangeArgs -join ",") -notmatch '^1\s*,\s*65535$') { throw "range is '$($rangeArgs -join ',')', want 1,65535" }
}
Check "R7 Find-ObsExe and Get-ObsNotFoundMessage are the same text in both scripts (kept in sync by hand)" {
    foreach ($n in @("Find-ObsExe", "Get-ObsNotFoundMessage")) {
        $a = (FunctionText $CaptureScript $n) -replace "`r", ""
        $b = (FunctionText $MonitorScript $n) -replace "`r", ""
        if ($a.Length -lt 100) { throw "$n text is only $($a.Length) characters: the extractor returned a fragment, not the function" }
        if (-not (Test-SameText $a $b)) { throw "$n differs between maya_obs_capture.ps1 and obs_monitor.ps1" }
    }
}
Check "R7 the same-text check catches drift (mutants: one letter, one case, one added line)" {
    $a = (FunctionText $CaptureScript "Find-ObsExe") -replace "`r", ""
    if (-not (Test-SameText $a $a)) { throw "identical text reported as different" }
    foreach ($mut in @(
        @("one letter", $a.Replace('"registry"', '"registrx"')),
        @("one case", $a.Replace('"registry"', '"Registry"')),
        @("added line", ($a + "`n# drift")))) {
        if ($mut[1] -ceq $a) { throw "mutant '$($mut[0])' did not change the text (test bug)" }
        if (Test-SameText $a $mut[1]) { throw "drift '$($mut[0])' not detected" }
    }
}

# ============================================================== R7 wiring
function Strip-Comments([string]$text) { return (($text -split "`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n" }

Check "R7 capture Ensure-ObsRunning: no OBS exe found -> throws 'OBS not found at <path>', never launches, not the 60-second message" {
    $d = New-TempDir "r7d"
    try {
        [IO.File]::WriteAllText((Join-Path $d "obs_config.txt"), "host: 127.0.0.1`nport: 1`n", (New-Object System.Text.ASCIIEncoding))
        $script:ScriptDir = $d
        $script:launched = @()
        function Test-ObsWebSocketReachable { return $false }
        function Get-Process { return $null }
        function Start-Process { $script:launched += "$args"; return $null }
        function Find-ObsExe { return [PSCustomObject]@{ Path = $null; Source = ""; Tried = @("C:\fake\no_such_obs\obs64.exe") } }
        Invoke-Expression ((Import-FunctionsFrom $CaptureScript @("Get-ObsNotFoundMessage", "Ensure-ObsRunning")) -join "`n")
        $msg = $null
        try { Ensure-ObsRunning } catch { $msg = $_.Exception.Message }
        if (-not $msg) { throw "Ensure-ObsRunning did not throw" }
        if ($msg -notmatch 'OBS not found at C:\\fake\\no_such_obs\\obs64\.exe') { throw "wrong message: $msg" }
        if ($msg -match 'did not become reachable') { throw "still the 60-second message: $msg" }
        if ($script:launched.Count) { throw "tried to launch: $($script:launched -join ';')" }
    } finally {
        Remove-Item Function:\Test-ObsWebSocketReachable, Function:\Get-Process, Function:\Start-Process, Function:\Find-ObsExe -ErrorAction SilentlyContinue
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check "R7 capture Ensure-ObsRunning: found exe is the one launched" {
    $d = New-TempDir "r7e"
    try {
        $exe = New-FakeExe $d "obs\obs64.exe"
        [IO.File]::WriteAllText((Join-Path $d "obs_config.txt"), "host: 127.0.0.1`nport: 1`n", (New-Object System.Text.ASCIIEncoding))
        $script:ScriptDir = $d
        $script:launched = @()
        $script:reach = 0
        function Test-ObsWebSocketReachable { $script:reach++; return ($script:launched.Count -gt 0) }
        function Get-Process { return $null }
        function Start-Process { param($FilePath, $WorkingDirectory) $script:launched += $FilePath; return $null }
        function Start-Sleep { }
        function Find-ObsExe { return [PSCustomObject]@{ Path = "$exe"; Source = "test"; Tried = @("$exe") } }
        Invoke-Expression ((Import-FunctionsFrom $CaptureScript @("Get-ObsNotFoundMessage", "Ensure-ObsRunning")) -join "`n")
        Ensure-ObsRunning
        if (@($script:launched).Count -ne 1 -or $script:launched[0] -ne $exe) { throw "launched: $($script:launched -join ';')" }
    } finally {
        Remove-Item Function:\Test-ObsWebSocketReachable, Function:\Get-Process, Function:\Start-Process, Function:\Start-Sleep, Function:\Find-ObsExe -ErrorAction SilentlyContinue
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check "R7 neither script hard-codes the obs64.exe install path any more (outside the default-locations list)" {
    foreach ($p in @($CaptureScript, $MonitorScript)) {
        $code = Strip-Comments (Get-Content -LiteralPath $p -Raw)
        $hits = @([regex]::Matches($code, '(?m)^.*obs64\.exe.*$') | ForEach-Object { $_.Value.Trim() })
        $bad = @($hits | Where-Object { $_ -match '^\$obsExe\s*=\s*"C:\\Program Files' })
        if ($bad.Count) { throw "$(Split-Path $p -Leaf) still has: $($bad[0])" }
    }
}
Check "R7 obs_monitor -EnsureRunning uses Find-ObsExe and throws the not-found message" {
    $code = Strip-Comments (Get-Content -LiteralPath $MonitorScript -Raw)
    if ($code -notmatch 'Find-ObsExe\s+-ConfigText') { throw "block does not call Find-ObsExe" }
    if ($code -notmatch 'Get-ObsNotFoundMessage') { throw "block does not use Get-ObsNotFoundMessage" }
}
Check "R7 Maya port is ONE setting: -MayaPort (default 7001) and every TcpClient uses it" {
    $code = Strip-Comments (Get-Content -LiteralPath $CaptureScript -Raw)
    if ($code -notmatch '\[int\]\$MayaPort\s*=\s*7001') { throw "no [int]`$MayaPort = 7001 setting in the param block" }
    $literal = @([regex]::Matches($code, "TcpClient\('127\.0\.0\.1',\s*\d+\)")).Count
    if ($literal) { throw "$literal TcpClient call(s) still use a literal port" }
    $viaSetting = @([regex]::Matches($code, "TcpClient\('127\.0\.0\.1',\s*\`$MayaPort\)")).Count
    if ($viaSetting -ne 4) { throw "expected 4 TcpClient calls through `$MayaPort, found $viaSetting" }
    $sevenK = @([regex]::Matches($code, '7001')).Count
    if ($sevenK -ne 1) { throw "7001 appears $sevenK times in code (want 1: the default)" }
}
Check "R7 capture script parses and still declares its original parameters" {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($CaptureScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "parse error: $($errors[0].Message)" }
    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($want in @("StartFrame", "EndFrame", "NamePrefix", "LegAxis")) {
        if ($names -notcontains $want) { throw "parameter $want missing" }
    }
}

# ============================================================== R14
# A throw-away wrapper folder holding ONE copy of the tool (wrap\d4_rom), a
# sentinel beside it and a sentinel inside the parent, so "deleted the parent"
# and "deleted the tool root" are both visible.
function New-WrapCopy {
    $wrap = New-TempDir "wrap"
    $copy = Join-Path $wrap "d4_rom"
    New-Item -ItemType Directory -Path $copy | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $RepoRoot -Force) {
        if (@(".git", "d4_anim_sample", "user_hooks", "tests", "exe_src", "legacy") -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $copy -Recurse -Force
    }
    Remove-Item -LiteralPath (Join-Path $copy "scripts\obs_config.txt") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $copy "scripts\state") -Recurse -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText((Join-Path $wrap "sentinel_parent.txt"), "keep", (New-Object System.Text.ASCIIEncoding))
    return [PSCustomObject]@{ Wrap = $wrap; Copy = $copy }
}
function Invoke-CopyBuild([string]$copy, [string]$distArg, [string]$workDir = "") {
    # hard stop: only ever run a build script that lives in a temp copy
    $script = [IO.Path]::GetFullPath((Join-Path $copy "build_dist.ps1"))
    if (-not $script.StartsWith($TempRoot + "\t136_wrap_", [StringComparison]::OrdinalIgnoreCase)) { throw "refusing to run a build outside a t136 temp copy: $script" }
    if ($workDir -and -not ([IO.Path]::GetFullPath($workDir)).StartsWith($TempRoot + "\t136_wrap_", [StringComparison]::OrdinalIgnoreCase)) { throw "refusing a work dir outside a t136 temp copy: $workDir" }
    if ($workDir) { Push-Location -LiteralPath $workDir }
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -DistDir $distArg 2>&1
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($out) -join "`n") }
    } finally { if ($workDir) { Pop-Location } }
}
function Assert-Refused($r, $w, [string]$label) {
    if ($r.ExitCode -eq 0) { throw "$label : build exited 0 (not refused). Output: $($r.Output)" }
    if ($r.Output -notmatch 'BUILD FAILED' -or $r.Output -notmatch 'refus') { throw "$label : no clear refusal message: $($r.Output)" }
    foreach ($keep in @((Join-Path $w.Copy "build_dist.ps1"), (Join-Path $w.Copy "scripts\rom_launcher.ps1"), (Join-Path $w.Copy "ROM_Launcher.exe"), (Join-Path $w.Wrap "sentinel_parent.txt"))) {
        if (-not (Test-Path -LiteralPath $keep)) { throw "$label : $keep was deleted" }
    }
}
$cases14 = @(
    @{ Name = "DistDir equals the tool root";                   Arg = { param($w) $w.Copy } },
    @{ Name = "DistDir equals the tool root (upper case, trailing backslash)"; Arg = { param($w) $w.Copy.ToUpper() + "\" } },
    @{ Name = "DistDir is the parent of the tool root";         Arg = { param($w) $w.Wrap } },
    @{ Name = "DistDir is inside the tool root (scripts)";      Arg = { param($w) Join-Path $w.Copy "scripts" } },
    @{ Name = "DistDir is the tool root written with a ..\ segment"; Arg = { param($w) Join-Path $w.Copy "scripts\.." } }
)
foreach ($c in $cases14) {
    Check "R14 build_dist refuses: $($c.Name)" {
        $w = New-WrapCopy
        try {
            $arg = & $c.Arg $w
            $r = Invoke-CopyBuild $w.Copy $arg
            Assert-Refused $r $w $c.Name
        } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Check "R14 build_dist refuses: relative DistDir '.' run from the tool root" {
    $w = New-WrapCopy
    try {
        $r = Invoke-CopyBuild $w.Copy "." $w.Copy
        Assert-Refused $r $w "relative ."
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
# Guard function only: never runs a build against a drive or share root. The
# tool root is a made-up folder under the temp dir; a root must be refused AS a
# root (the message says so), whichever drive the temp dir is on.
$driveRootCases = @("C:\", "C:", "c:/", "C:\\", "D:\", "D:", "d:/", "D:/", "Z:\", "\\localhost\C`$\", "\\localhost\C`$", "//localhost/C`$/", "\\127.0.0.1\D`$\", "\\someserver\someshare\", "\\someserver\someshare", ([IO.Path]::GetPathRoot($TempRoot) + "t136x\.."))
foreach ($rootCase in $driveRootCases) {
    Check "R14 guard refuses a drive or share root: '$rootCase' (function only, no build)" {
        $src = (Import-FunctionsFrom $BuildDist @("Get-DistDirProblem", "ConvertTo-DistFullPath", "Get-DistToolMarker")) -join "`n"
        Invoke-Expression $src
        $problem = Get-DistDirProblem -DistDir $rootCase -ToolRoot (Join-Path $TempRoot "t136_no_such_tool\d4_rom")
        if (-not $problem) { throw "'$rootCase' was allowed" }
        if ($problem -notmatch 'drive or share root') { throw "refused for the wrong reason: $problem" }
    }
}
Check "R14 guard still allows an ordinary folder and a sub-folder of a drive (function only)" {
    $src = (Import-FunctionsFrom $BuildDist @("Get-DistDirProblem", "ConvertTo-DistFullPath", "Get-DistToolMarker")) -join "`n"
    Invoke-Expression $src
    foreach ($ok in @((Join-Path $TempRoot "t136_plain_dist"), (Join-Path $TempRoot "t136_no_such_tool\d4_rom_dist"), ($TempRoot + "\x"))) {
        $problem = Get-DistDirProblem -DistDir $ok -ToolRoot (Join-Path $TempRoot "t136_no_such_tool\d4_rom")
        if ($problem) { throw "'$ok' refused: $problem" }
    }
}
function ConvertTo-LocalAdminShareUnc([string]$path) {
    # C:\a\b -> \\localhost\C$\a\b (the QA's alias that slipped past a string compare)
    if ($path -notmatch '^([A-Za-z]):\\(.*)$') { return $null }
    return "\\localhost\" + $Matches[1] + "`$\" + $Matches[2]
}
function New-Junction([string]$link, [string]$target) {
    & cmd.exe /c mklink /J "`"$link`"" "`"$target`"" | Out-Null
    if (-not (Test-Path -LiteralPath $link)) { throw "could not create junction $link" }
}
Check "R14 build_dist refuses: UNC admin-share alias of the tool root (\\localhost\C`$\...), nothing deleted" {
    $w = New-WrapCopy
    try {
        $unc = ConvertTo-LocalAdminShareUnc $w.Copy
        if (-not $unc -or -not (Test-Path -LiteralPath $unc)) { Write-Output "      (no local admin share reachable here: case skipped)"; return }
        $r = Invoke-CopyBuild $w.Copy $unc
        Assert-Refused $r $w "UNC alias of root"
        if (-not (Test-Path -LiteralPath (Join-Path $w.Copy "scripts\maya\send_to_maya.ps1"))) { throw "tool files lost" }
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist refuses: UNC admin-share alias of a folder inside the tool root (scripts), nothing deleted" {
    $w = New-WrapCopy
    try {
        $unc = ConvertTo-LocalAdminShareUnc (Join-Path $w.Copy "scripts")
        if (-not $unc -or -not (Test-Path -LiteralPath $unc)) { Write-Output "      (no local admin share reachable here: case skipped)"; return }
        $before = @(Get-ChildItem -LiteralPath $w.Copy -Recurse -File -Force).Count
        $r = Invoke-CopyBuild $w.Copy $unc
        Assert-Refused $r $w "UNC alias of scripts"
        $after = @(Get-ChildItem -LiteralPath $w.Copy -Recurse -File -Force).Count
        if ($after -ne $before) { throw "file count changed $before -> $after" }
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist refuses: UNC admin-share alias of the PARENT of the tool root, nothing deleted" {
    $w = New-WrapCopy
    try {
        $unc = ConvertTo-LocalAdminShareUnc $w.Wrap
        if (-not $unc -or -not (Test-Path -LiteralPath $unc)) { Write-Output "      (no local admin share reachable here: case skipped)"; return }
        $r = Invoke-CopyBuild $w.Copy $unc
        Assert-Refused $r $w "UNC alias of parent"
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist refuses: a junction to the tool root, and a junction to a folder inside it (tool marker files)" {
    $w = New-WrapCopy
    try {
        $j1 = Join-Path $w.Wrap "link_root"
        New-Junction $j1 $w.Copy
        $r = Invoke-CopyBuild $w.Copy $j1
        Assert-Refused $r $w "junction to root"
        $j2 = Join-Path $w.Wrap "link_scripts"
        New-Junction $j2 (Join-Path $w.Copy "scripts")
        $r = Invoke-CopyBuild $w.Copy $j2
        Assert-Refused $r $w "junction to scripts"
        if (-not (Test-Path -LiteralPath (Join-Path $w.Copy "scripts\maya\send_to_maya.ps1"))) { throw "tool files lost through the junction" }
    } finally {
        foreach ($j in @((Join-Path $w.Wrap "link_root"), (Join-Path $w.Wrap "link_scripts"))) { if (Test-Path -LiteralPath $j) { & cmd.exe /c rmdir "`"$j`"" | Out-Null } }
        Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check "R14 build_dist refuses: forward-slash spelling of the tool root and of its parent" {
    $w = New-WrapCopy
    try {
        $r = Invoke-CopyBuild $w.Copy ($w.Copy -replace '\\', '/')
        Assert-Refused $r $w "forward slashes root"
        $r = Invoke-CopyBuild $w.Copy (($w.Wrap -replace '\\', '/') + "/")
        Assert-Refused $r $w "forward slashes parent"
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist accepts folders whose names merely START like the tool root or its parent (no prefix off-by-one), with or without a trailing backslash" {
    $w = New-WrapCopy
    try {
        $leafName = Split-Path $w.Copy -Leaf
        $targets = @(
            ($w.Copy + "2"),                                  # d4_rom2 next to d4_rom
            ($w.Copy + "_dist\"),                             # d4_rom_dist\ (trailing backslash)
            (Join-Path $w.Wrap ($leafName.Substring(0, 3))),  # d4_ : a prefix of the tool folder name
            ($w.Wrap + "_dist")                               # sibling of the wrap folder, name starts like the parent
        )
        foreach ($t in $targets) {
            $r = Invoke-CopyBuild $w.Copy $t
            if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'BUILD SUCCEEDED') { throw "'$t' wrongly refused / failed: $($r.Output)" }
            if (-not (Test-Path -LiteralPath (Join-Path $t "scripts\obs_config.txt"))) { throw "'$t' has no dist content" }
        }
    } finally {
        Remove-Item -LiteralPath ($w.Wrap + "_dist") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check "R14 build_dist rebuilds over a REAL previous dist (it holds ROM_Launcher.exe, which is shipped, so that alone must not count as the tool)" {
    $w = New-WrapCopy
    try {
        $dist = Join-Path $w.Wrap "d4_rom_dist"
        $r = Invoke-CopyBuild $w.Copy $dist
        if ($r.ExitCode -ne 0) { throw "first build failed: $($r.Output)" }
        if (-not (Test-Path -LiteralPath (Join-Path $dist "ROM_Launcher.exe"))) { throw "dist lacks ROM_Launcher.exe (test setup)" }
        $r = Invoke-CopyBuild $w.Copy $dist
        if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'BUILD SUCCEEDED') { throw "rebuild over a previous dist refused: $($r.Output)" }
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist accepts a clean sibling folder (the default d4_rom_dist shape) and builds" {
    $w = New-WrapCopy
    try {
        $dist = Join-Path $w.Wrap "d4_rom_dist"
        $r = Invoke-CopyBuild $w.Copy $dist
        if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'BUILD SUCCEEDED') { throw "clean build did not succeed: $($r.Output)" }
        if (-not (Test-Path -LiteralPath (Join-Path $dist "ROM_Launcher.exe"))) { throw "dist lacks ROM_Launcher.exe" }
        if (-not (Test-Path -LiteralPath (Join-Path $w.Copy "build_dist.ps1"))) { throw "tool copy damaged" }
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}
Check "R14 build_dist rebuilds an existing stale dist folder (still replaced, as before)" {
    $w = New-WrapCopy
    try {
        $dist = Join-Path $w.Wrap "d4_rom_dist"
        New-Item -ItemType Directory -Path $dist | Out-Null
        [IO.File]::WriteAllText((Join-Path $dist "stale.txt"), "old", (New-Object System.Text.ASCIIEncoding))
        $r = Invoke-CopyBuild $w.Copy $dist
        if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'BUILD SUCCEEDED') { throw "rebuild did not succeed: $($r.Output)" }
        if (Test-Path -LiteralPath (Join-Path $dist "stale.txt")) { throw "stale file survived the rebuild" }
    } finally { Remove-Item -LiteralPath $w.Wrap -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ""
foreach ($f in $failures) { Write-Output "FAIL: $f" }
Write-Output "$passed passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

# Persistent test suite for T87: the Prefix box and the video rename.
# Covers the prefix sanitizer (Get-SafePrefix), the leg suffix, the unique
# target path + path-length guard (Get-UniqueVideoPath), the rename itself
# on temp files (Rename-RecordedVideo: existing target, _2/_3, a locked
# file, a missing file, extension variants), the OBS StopRecord output-path
# reader (Get-ObsRecordOutputPath), the scene-name result parser
# (ConvertFrom-SceneNameOutput), the fill rule incl. the stale rule and the
# button (Get-PrefixFillDecision), the first-connect trigger, the state
# file, the step builder (-NamePrefix / -LegAxis, empty prefix = identical
# steps), the capture script and launcher parse, the Prefix XAML row, and
# scripts\maya\maya_get_scene_name.py run under plain python with a fake
# maya.cmds (NOT mayapy, NOT Maya).
#
# Dot-sources ONLY rom_launcher_logic.ps1 -- never shows a window, never
# launches Maya/OBS, never touches port 7001. Every file it writes goes
# into a temp folder.
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_prefix_naming.ps1
# Exits 0 if all checks pass, 1 otherwise.

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ScriptsRoot = Join-Path $RepoRoot "scripts"
. (Join-Path $ScriptsRoot "rom_launcher_logic.ps1")

# T87 clock seam: every rename in this file is stamped 14:32 (deterministic names
# {prefix}_{leg}_14_32<ext>); the real Get-VideoRenameTime returns Get-Date.
function Get-VideoRenameTime { return (New-Object DateTime 2026, 10, 26, 14, 32, 5) }

$failures = @()
$passed = 0

function Check($name, [scriptblock]$body) {
    try {
        & $body
        $script:passed++
    } catch {
        $script:failures += "$name`: $($_.Exception.Message)"
    }
}

function Norm([string]$p) { return [IO.Path]::GetFullPath($p).TrimEnd('\') }
function StepText($s) { return "$($s.FilePath) $(@($s.Arguments) -join ' ')" }
function StepsText($steps) {
    # run ids are random guids: normalize them so two builds compare equal
    return ((@($steps) | ForEach-Object { StepText $_ }) -join "`n") -replace '(pre|post)-(\d)-[0-9a-f]{32}', '$1-$2-GUID'
}
function ObsStepsOf($steps) { return @(@($steps) | Where-Object { (@($_.Arguments) -join ' ') -like "*maya_obs_capture.ps1*" }) }
function New-TempDir([string]$tag) {
    $d = Join-Path $env:TEMP ("t87_" + $tag + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}
function New-FakeVideo([string]$path, [int]$size = 4096) {
    $bytes = New-Object byte[] $size
    (New-Object System.Random 87).NextBytes($bytes)
    [IO.File]::WriteAllBytes($path, $bytes)
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
function U([int[]]$codes) { return -join ($codes | ForEach-Object { [char]$_ }) }

# ---------------------------------------------------------------- Get-SafePrefix
$SafeCases = @(
    @("", ""),
    @("   ", ""),
    ("`t`r`n", ""),
    @("barM_stor282_WIP_ROM", "barM_stor282_WIP_ROM"),
    @("a.v2", "a.v2"),
    @("my scene", "my_scene"),
    @("  padded name  ", "padded_name"),
    @('a\b/c:d*e?f"g<h>i|j', "a_b_c_d_e_f_g_h_i_j"),
    @('\/:*?"<>|', ""),
    @("  \ / :  ", ""),
    @(("a" + [char]1 + "b" + [char]0x7F + "c"), "a_b_c"),
    @("a`tb", "a_b"),
    @("CON", "CON_"),
    @("con", "con_"),
    @("NUL.v2", "NUL_.v2"),
    @("COM1", "COM1_"),
    @("lpt9", "lpt9_"),
    @("AUX", "AUX_"),
    @("PRN", "PRN_"),
    @(("COM" + [char]0x00B9), ("COM" + [char]0x00B9 + "_")),
    @("COM10", "COM10"),
    @("CONSOLE", "CONSOLE"),
    @("take.", "take"),
    @("take...", "take"),
    @("...", ""),
    @(". .", ""),
    @("___", "___"),
    @("-take", "_take"),
    @("a-b", "a-b"),
    @(((U @(0x30C6, 0x30B9, 0x30C8)) + "_ROM"), ((U @(0x30C6, 0x30B9, 0x30C8)) + "_ROM")),
    @(("caf" + [char]0x00E9), ("caf" + [char]0x00E9)),
    @(("take" + (U @(0xD83D, 0xDE00))), ("take" + (U @(0xD83D, 0xDE00))))
)

Check "Get-SafePrefix: $($SafeCases.Count) cases (empty, unsafe, spaces, control chars, reserved names, trailing dots, Unicode)" {
    $bad = @()
    foreach ($c in $SafeCases) {
        $got = Get-SafePrefix -Prefix $c[0]
        if ($got -cne $c[1]) { $bad += "'$($c[0])' -> '$got' (expected '$($c[1])')" }
    }
    if ($bad.Count) { throw ($bad -join "; ") }
}

Check "Get-SafePrefix: `$null is an empty prefix" {
    $got = Get-SafePrefix -Prefix $null
    if ($got -ne "") { throw "got '$got'" }
}

Check "Get-SafePrefix: idempotent (sanitizing twice changes nothing)" {
    foreach ($c in $SafeCases) {
        $once = Get-SafePrefix -Prefix $c[0]
        $twice = Get-SafePrefix -Prefix $once
        if ($once -cne $twice) { throw "'$($c[0])': '$once' -> '$twice'" }
    }
}

Check "Get-SafePrefix: no artificial length cap (300 characters stay 300)" {
    $long = "x" * 300
    $got = Get-SafePrefix -Prefix $long
    if ($got.Length -ne 300) { throw "length $($got.Length)" }
}

# ---------------------------------------------------------------- Get-LegSuffix
Check "Get-LegSuffix: FrontBack -> front_back, LeftRight -> left_right, anything else throws" {
    if ((Get-LegSuffix -LegAxis "FrontBack") -cne "front_back") { throw "FrontBack" }
    if ((Get-LegSuffix -LegAxis "LeftRight") -cne "left_right") { throw "LeftRight" }
    $threw = $false
    try { Get-LegSuffix -LegAxis "All" | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "All did not throw" }
}

# ---------------------------------------------------------------- Get-UniqueVideoPath
Check "Get-UniqueVideoPath: free name, then _2, _3 when the targets exist; extension kept" {
    $d = New-TempDir "uniq"
    try {
        $r = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "FrontBack" -Extension ".mp4"
        if ((Norm $r.Path) -ne (Norm (Join-Path $d "take_front_back.mp4"))) { throw "first: $($r.Path)" }
        if ($r.Truncated) { throw "first marked truncated" }
        [IO.File]::WriteAllText($r.Path, "1")
        $r2 = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "FrontBack" -Extension ".mp4"
        if ((Norm $r2.Path) -ne (Norm (Join-Path $d "take_front_back_2.mp4"))) { throw "second: $($r2.Path)" }
        [IO.File]::WriteAllText($r2.Path, "2")
        $r3 = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "FrontBack" -Extension ".mp4"
        if ((Norm $r3.Path) -ne (Norm (Join-Path $d "take_front_back_3.mp4"))) { throw "third: $($r3.Path)" }
        $lr = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "LeftRight" -Extension ".mkv"
        if ((Norm $lr.Path) -ne (Norm (Join-Path $d "take_left_right.mkv"))) { throw "left_right: $($lr.Path)" }
        $mov = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "FrontBack" -Extension ".mov"
        if ((Norm $mov.Path) -ne (Norm (Join-Path $d "take_front_back.mov"))) { throw "mov: $($mov.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Get-UniqueVideoPath: path-length guard truncates the prefix just enough (300-char prefix)" {
    $d = New-TempDir "len"
    try {
        $long = "p" * 300
        $r = Get-UniqueVideoPath -Directory $d -Prefix $long -LegAxis "FrontBack" -Extension ".mp4" -MaxPathLength 255
        if (-not $r.Path) { throw "no path: $($r.Error)" }
        if ($r.Path.Length -ne 255) { throw "path length $($r.Path.Length), expected exactly 255" }
        if (-not $r.Truncated) { throw "not marked truncated" }
        if ($r.Prefix -ne ("p" * $r.Prefix.Length)) { throw "prefix changed beyond truncation" }
        $short = Get-UniqueVideoPath -Directory $d -Prefix "short" -LegAxis "FrontBack" -Extension ".mp4" -MaxPathLength 255
        if ($short.Truncated) { throw "short prefix truncated" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Get-UniqueVideoPath: truncated name with an existing target still fits (_2 shortens the prefix)" {
    $d = New-TempDir "len2"
    try {
        $max = $d.Length + 1 + 30   # room for a 30-char file name
        $r = Get-UniqueVideoPath -Directory $d -Prefix ("q" * 100) -LegAxis "LeftRight" -Extension ".mp4" -MaxPathLength $max
        if ($r.Path.Length -ne $max) { throw "first length $($r.Path.Length) vs $max" }
        [IO.File]::WriteAllText($r.Path, "x")
        $r2 = Get-UniqueVideoPath -Directory $d -Prefix ("q" * 100) -LegAxis "LeftRight" -Extension ".mp4" -MaxPathLength $max
        if ($r2.Path.Length -gt $max) { throw "second too long: $($r2.Path.Length)" }
        if ($r2.Path -notmatch '_left_right_2\.mp4$') { throw "second not _2: $($r2.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Get-UniqueVideoPath: truncation never leaves a reserved name or a trailing dot" {
    $d = New-TempDir "len3"
    try {
        $fixed = $d.Length + 1 + "_front_back.mp4".Length
        $r = Get-UniqueVideoPath -Directory $d -Prefix "CONSOLE" -LegAxis "FrontBack" -Extension ".mp4" -MaxPathLength ($fixed + 3)
        if ($r.Prefix -ieq "CON") { throw "left reserved CON" }
        if ($r.Prefix.Length -gt 3) { throw "prefix too long: $($r.Prefix)" }
        $r2 = Get-UniqueVideoPath -Directory $d -Prefix "ab.cd" -LegAxis "FrontBack" -Extension ".mp4" -MaxPathLength ($fixed + 3)
        if ($r2.Prefix -ne "ab") { throw "trailing dot case: '$($r2.Prefix)'" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Get-UniqueVideoPath: folder too long for any name -> no path, Error set, never throws" {
    $d = New-TempDir "len4"
    try {
        $r = Get-UniqueVideoPath -Directory $d -Prefix "take" -LegAxis "FrontBack" -Extension ".mp4" -MaxPathLength ($d.Length + 5)
        if ($r.Path) { throw "got a path: $($r.Path)" }
        if (-not $r.Error) { throw "no Error text" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- Rename-RecordedVideo
Check "Rename-RecordedVideo: renames to {prefix}_front_back.mp4, bytes unchanged, source gone" {
    $d = New-TempDir "ren"
    try {
        $src = Join-Path $d "2026-10-26 01-00-00.mp4"
        $h = New-FakeVideo $src
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "FrontBack"
        if ($r.Status -ne "renamed") { throw "status $($r.Status): $($r.Log -join ' | ')" }
        $want = Join-Path $d "take_front_back_14_32.mp4"
        if ((Norm $r.Path) -ne (Norm $want)) { throw "path $($r.Path)" }
        if (Test-Path -LiteralPath $src) { throw "source still there" }
        if ((HashOf $want) -ne $h) { throw "bytes changed" }
        if (@($r.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "unexpected warning" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: second and third takes get _2, the first take's files stay byte-identical" {
    $d = New-TempDir "ren2"
    try {
        $a = Join-Path $d "obs_a.mp4"; $b = Join-Path $d "obs_b.mp4"; $c = Join-Path $d "obs_c.mp4"; $e = Join-Path $d "obs_e.mp4"
        $ha = New-FakeVideo $a 1000; $hb = New-FakeVideo $b 2000; $hc = New-FakeVideo $c 3000; $he = New-FakeVideo $e 4000
        $ra = Rename-RecordedVideo -SourcePath $a -Prefix "take" -LegAxis "FrontBack"
        $rb = Rename-RecordedVideo -SourcePath $b -Prefix "take" -LegAxis "LeftRight"
        $rc = Rename-RecordedVideo -SourcePath $c -Prefix "take" -LegAxis "FrontBack"
        $re = Rename-RecordedVideo -SourcePath $e -Prefix "take" -LegAxis "FrontBack"
        if ((Split-Path $ra.Path -Leaf) -ne "take_front_back_14_32.mp4") { throw "a: $($ra.Path)" }
        if ((Split-Path $rb.Path -Leaf) -ne "take_left_right_14_32.mp4") { throw "b: $($rb.Path)" }
        if ((Split-Path $rc.Path -Leaf) -ne "take_front_back_14_32_2.mp4") { throw "c: $($rc.Path)" }
        if ((Split-Path $re.Path -Leaf) -ne "take_front_back_14_32_3.mp4") { throw "e: $($re.Path)" }
        if ((HashOf $ra.Path) -ne $ha) { throw "first take front_back changed" }
        if ((HashOf $rb.Path) -ne $hb) { throw "first take left_right changed" }
        if ((HashOf $rc.Path) -ne $hc) { throw "second take bytes" }
        if ((HashOf $re.Path) -ne $he) { throw "third take bytes" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: an existing target (not from this tool) is never overwritten -> _2" {
    $d = New-TempDir "ren3"
    try {
        $existing = Join-Path $d "take_left_right_14_32.mov"
        $hx = New-FakeVideo $existing 500
        $src = Join-Path $d "obs.mov"
        $hs = New-FakeVideo $src 900
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "LeftRight"
        if ((Split-Path $r.Path -Leaf) -ne "take_left_right_14_32_2.mov") { throw "got $($r.Path)" }
        if ((HashOf $existing) -ne $hx) { throw "existing target was touched" }
        if ((HashOf $r.Path) -ne $hs) { throw "moved bytes differ" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: extension is whatever OBS wrote (mp4, mkv, mov, upper case)" {
    $d = New-TempDir "ren4"
    try {
        foreach ($ext in @(".mp4", ".mkv", ".mov", ".MP4")) {
            $src = Join-Path $d ("obs_" + [guid]::NewGuid().ToString("N").Substring(0, 6) + $ext)
            New-FakeVideo $src 100 | Out-Null
            $p = "ext" + $ext.TrimStart('.').ToLower() + $(if ($ext -ceq ".MP4") { "U" } else { "" })
            $r = Rename-RecordedVideo -SourcePath $src -Prefix $p -LegAxis "FrontBack"
            if (-not $r.Path.EndsWith("_front_back_14_32" + $ext, [StringComparison]::Ordinal)) { throw "$ext -> $($r.Path)" }
        }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: a locked file (OBS still holds it) -> retries, then WARNING and the original is kept" {
    $d = New-TempDir "ren5"
    $fs = $null
    try {
        $src = Join-Path $d "obs_locked.mp4"
        $h = New-FakeVideo $src
        $fs = [IO.File]::Open($src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "FrontBack" -RetryCount 3 -RetryDelayMs 20
        $sw.Stop()
        if ($r.Status -ne "kept") { throw "status $($r.Status)" }
        if ((Norm $r.Path) -ne (Norm $src)) { throw "path $($r.Path)" }
        if (-not @($r.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "no WARNING line" }
        if (Test-Path -LiteralPath (Join-Path $d "take_front_back_14_32.mp4")) { throw "target was created" }
        $fs.Close(); $fs = $null
        if ((HashOf $src) -ne $h) { throw "original changed" }
        if ($sw.ElapsedMilliseconds -lt 40) { throw "did not wait between retries ($($sw.ElapsedMilliseconds) ms)" }
    } finally {
        if ($fs) { $fs.Close() }
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "Rename-RecordedVideo: a file released after 2 failed tries is renamed (OnRetry seam)" {
    $d = New-TempDir "ren6"
    $script:lockStream = $null
    $script:retrySeen = 0
    try {
        $src = Join-Path $d "obs_busy.mkv"
        $h = New-FakeVideo $src
        $script:lockStream = [IO.File]::Open($src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $onRetry = { param($attempt) $script:retrySeen = $attempt; if ($attempt -ge 2 -and $script:lockStream) { $script:lockStream.Close(); $script:lockStream = $null } }
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "LeftRight" -RetryCount 20 -RetryDelayMs 5 -OnRetry $onRetry
        if ($r.Status -ne "renamed") { throw "status $($r.Status): $($r.Log -join ' | ')" }
        if ($script:retrySeen -lt 2) { throw "OnRetry saw $($script:retrySeen)" }
        if ((HashOf $r.Path) -ne $h) { throw "bytes changed" }
    } finally {
        if ($script:lockStream) { $script:lockStream.Close() }
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "Rename-RecordedVideo: missing file / no path / bad axis -> WARNING, never throws" {
    $d = New-TempDir "ren7"
    try {
        $missing = Join-Path $d "nope.mp4"
        $r = Rename-RecordedVideo -SourcePath $missing -Prefix "take" -LegAxis "FrontBack"
        if ($r.Status -ne "kept") { throw "missing: status $($r.Status)" }
        if (-not @($r.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "missing: no WARNING" }
        $r2 = Rename-RecordedVideo -SourcePath "" -Prefix "take" -LegAxis "FrontBack"
        if ($r2.Status -ne "kept" -or $r2.Path -ne "") { throw "empty path: $($r2.Status) '$($r2.Path)'" }
        if (-not @($r2.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "empty path: no WARNING" }
        $src = Join-Path $d "obs.mp4"
        New-FakeVideo $src | Out-Null
        $r3 = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "All"
        if ($r3.Status -ne "kept" -or -not (Test-Path -LiteralPath $src)) { throw "bad axis: $($r3.Status)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: empty / all-unsafe prefix -> skipped, file untouched, no warning" {
    $d = New-TempDir "ren8"
    try {
        $src = Join-Path $d "obs.mp4"
        $h = New-FakeVideo $src
        foreach ($p in @("", "   ", '<>|')) {
            $r = Rename-RecordedVideo -SourcePath $src -Prefix $p -LegAxis "FrontBack"
            if ($r.Status -ne "skipped") { throw "'$p': status $($r.Status)" }
            if ((Norm $r.Path) -ne (Norm $src)) { throw "'$p': path $($r.Path)" }
            if (@($r.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "'$p': warning" }
        }
        if ((HashOf $src) -ne $h) { throw "file changed" }
        if (@(Get-ChildItem $d).Count -ne 1) { throw "extra files" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo: the prefix is sanitized again (unsafe text never reaches the file system)" {
    $d = New-TempDir "ren9"
    try {
        $src = Join-Path $d "obs.mp4"
        New-FakeVideo $src | Out-Null
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "my take:1" -LegAxis "FrontBack"
        if ((Split-Path $r.Path -Leaf) -ne "my_take_1_front_back_14_32.mp4") { throw "got $($r.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- OBS StopRecord output path
function Msg([string]$json) { return ($json | ConvertFrom-Json) }

Check "Get-ObsRecordOutputPath: (1) the StopRecord reply's outputPath wins" {
    $m = @(
        (Msg '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputActive":false,"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPING","outputPath":null}}}'),
        (Msg '{"op":7,"d":{"requestType":"StopRecord","requestId":"r1","requestStatus":{"result":true,"code":100},"responseData":{"outputPath":"C:\\Videos\\2026-10-26 01-00-00.mp4"}}}')
    )
    $r = Get-ObsRecordOutputPath -Messages $m -RequestId "r1"
    if ($r.Path -ne "C:\Videos\2026-10-26 01-00-00.mp4") { throw "path '$($r.Path)'" }
    if ($r.Source -ne "response") { throw "source $($r.Source)" }
}

Check "Get-ObsRecordOutputPath: (2) no path in the reply -> the RecordStateChanged STOPPED event" {
    $m = @(
        (Msg '{"op":7,"d":{"requestType":"StopRecord","requestId":"r2","requestStatus":{"result":true,"code":100}}}'),
        (Msg '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputActive":false,"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":"D:\\rec\\a.mkv"}}}')
    )
    $r = Get-ObsRecordOutputPath -Messages $m -RequestId "r2"
    if ($r.Path -ne "D:\rec\a.mkv" -or $r.Source -ne "event") { throw "got '$($r.Path)' from $($r.Source)" }
}

Check "Get-ObsRecordOutputPath: (3) nothing usable -> empty, Source none (other request ids, STOPPING, empty path ignored)" {
    $m = @(
        (Msg '{"op":7,"d":{"requestType":"StopRecord","requestId":"other","requestStatus":{"result":true},"responseData":{"outputPath":"C:\\x.mp4"}}}'),
        (Msg '{"op":7,"d":{"requestType":"StopRecord","requestId":"r3","requestStatus":{"result":true},"responseData":{"outputPath":""}}}'),
        (Msg '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPING","outputPath":"C:\\y.mp4"}}}'),
        (Msg '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":""}}}'),
        (Msg '{"op":5,"d":{"eventType":"StreamStateChanged","eventData":{"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":"C:\\z.mp4"}}}')
    )
    $r = Get-ObsRecordOutputPath -Messages $m -RequestId "r3"
    if ($r.Path -ne "" -or $r.Source -ne "none") { throw "got '$($r.Path)' from $($r.Source)" }
    $r0 = Get-ObsRecordOutputPath -Messages @() -RequestId "r3"
    if ($r0.Path -ne "" -or $r0.Source -ne "none") { throw "empty list: '$($r0.Path)' $($r0.Source)" }
}

Check "Format-ObsMessageSummary: one short description per message (what the QA probe logs)" {
    $m = @(
        (Msg '{"op":7,"d":{"requestType":"StopRecord","requestId":"r1","requestStatus":{"result":true},"responseData":{"outputPath":"C:\\v.mp4"}}}'),
        (Msg '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":"C:\\v.mp4"}}}')
    )
    $s = Format-ObsMessageSummary -Messages $m
    if ($s -notlike "*StopRecord*outputPath*" -or $s -notlike "*RecordStateChanged*OBS_WEBSOCKET_OUTPUT_STOPPED*") { throw "summary '$s'" }
}

# ---------------------------------------------------------------- scene name
Check "ConvertFrom-SceneNameOutput: name / untitled / error / unknown" {
    $r = ConvertFrom-SceneNameOutput -Output "SCENE_NAME a.v2`r`n"
    if ($r.Status -ne "Named" -or $r.Name -cne "a.v2") { throw "named: $($r.Status) '$($r.Name)'" }
    $r = ConvertFrom-SceneNameOutput -Output "SCENE_NAME my scene"
    if ($r.Name -cne "my scene") { throw "raw name with a space: '$($r.Name)'" }
    $jp = (U @(0x30C6, 0x30B9, 0x30C8))
    $r = ConvertFrom-SceneNameOutput -Output ("SCENE_NAME " + $jp + "`n")
    if ($r.Name -cne $jp) { throw "unicode: '$($r.Name)'" }
    $r = ConvertFrom-SceneNameOutput -Output "SCENE_UNTITLED"
    if ($r.Status -ne "Untitled" -or $r.Name) { throw "untitled: $($r.Status)" }
    $r = ConvertFrom-SceneNameOutput -Output "SCENE_NAME    "
    if ($r.Status -ne "Untitled") { throw "blank name: $($r.Status)" }
    $r = ConvertFrom-SceneNameOutput -Output "SCENE_NAME_ERROR RuntimeError: boom"
    if ($r.Status -ne "Error" -or $r.ErrorMessage -ne "RuntimeError: boom" -or $r.Name) { throw "error: $($r.Status) '$($r.ErrorMessage)'" }
    foreach ($o in @("", "garbage", "Sent to Maya command port 127.0.0.1:7001")) {
        $r = ConvertFrom-SceneNameOutput -Output $o
        if ($r.Status -ne "Unknown" -or $r.Name) { throw "'$o': $($r.Status)" }
    }
}

# ---------------------------------------------------------------- fill rule
function Fill($cur, $last, $scene, [bool]$button = $false) {
    return Get-PrefixFillDecision -CurrentText $cur -LastAutoFill $last -SceneName $scene -FromButton $button
}

Check "Get-PrefixFillDecision: empty box is filled; typed text is never touched" {
    $r = Fill "" $null "barM_v1"
    if ($r.Text -cne "barM_v1" -or $r.LastAutoFill -cne "barM_v1" -or -not $r.Changed -or $r.Reason -ne "filled") { throw "empty: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "   " $null "barM_v1"
    if ($r.Text -cne "barM_v1" -or $r.Reason -ne "filled") { throw "whitespace-only: $($r.Text)" }
    $r = Fill "my_take" $null "barM_v1"
    if ($r.Text -cne "my_take" -or $r.Changed -or $r.Reason -ne "kept_user_text") { throw "typed: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "my_take" "barM_v1" "barM_v2"
    if ($r.Text -cne "my_take" -or $r.LastAutoFill -cne "barM_v1") { throw "typed after an auto fill: $($r | ConvertTo-Json -Compress)" }
}

Check "Get-PrefixFillDecision: STALE RULE -- an unedited auto-filled value follows the scene" {
    $r = Fill "barM_v1" "barM_v1" "barM_v2"
    if ($r.Text -cne "barM_v2" -or $r.LastAutoFill -cne "barM_v2" -or -not $r.Changed -or $r.Reason -ne "refreshed") { throw "refresh: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "barM_v1" "barM_v1" "barM_v1"
    if ($r.Changed -or $r.Text -cne "barM_v1" -or $r.Reason -ne "unchanged") { throw "same scene: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "barM_V1" "barM_v1" "barM_v2"
    if ($r.Text -cne "barM_V1" -or $r.Changed) { throw "case-edited text counts as typed: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "barM_v1x" "barM_v1" "barM_v2"
    if ($r.Text -cne "barM_v1x" -or $r.Changed) { throw "edited text: $($r | ConvertTo-Json -Compress)" }
}

Check "Get-PrefixFillDecision: the button replaces any text with the scene name" {
    $r = Fill "my_take" "barM_v1" "barM_v2" $true
    if ($r.Text -cne "barM_v2" -or $r.LastAutoFill -cne "barM_v2" -or -not $r.Changed -or $r.Reason -ne "button") { throw "button: $($r | ConvertTo-Json -Compress)" }
    $r = Fill "barM_v2" "barM_v2" "barM_v2" $true
    if ($r.Changed) { throw "button same text marked changed" }
}

Check "Get-PrefixFillDecision: untitled / no scene name -> nothing changes (button too)" {
    foreach ($scene in @($null, "", "   ")) {
        foreach ($b in @($false, $true)) {
            $r = Fill "" $null $scene $b
            if ($r.Changed -or $r.Text -ne "" -or $r.Reason -ne "no_scene") { throw "empty box, scene '$scene', button $b : $($r | ConvertTo-Json -Compress)" }
            $r = Fill "barM_v1" "barM_v1" $scene $b
            if ($r.Changed -or $r.Text -cne "barM_v1" -or $r.LastAutoFill -cne "barM_v1") { throw "auto text, scene '$scene', button $b" }
        }
    }
}

Check "Test-PrefixFillNeeded: Maya is asked only when the answer can change the box (agrees with the decision)" {
    if (-not (Test-PrefixFillNeeded -CurrentText "" -LastAutoFill "")) { throw "empty box" }
    if (-not (Test-PrefixFillNeeded -CurrentText "  " -LastAutoFill $null)) { throw "whitespace box" }
    if (-not (Test-PrefixFillNeeded -CurrentText "barM_v1" -LastAutoFill "barM_v1")) { throw "auto-filled box" }
    if (Test-PrefixFillNeeded -CurrentText "my_take" -LastAutoFill "barM_v1") { throw "typed text" }
    if (Test-PrefixFillNeeded -CurrentText "my_take" -LastAutoFill "") { throw "typed text, no auto fill yet" }
    if (-not (Test-PrefixFillNeeded -CurrentText "my_take" -LastAutoFill "x" -FromButton $true)) { throw "button" }
    foreach ($c in @(@("", ""), @("a", "a"), @("a", "b"), @("A", "a"), @("t", ""))) {
        foreach ($b in @($false, $true)) {
            $needed = Test-PrefixFillNeeded -CurrentText $c[0] -LastAutoFill $c[1] -FromButton $b
            $d = Fill $c[0] $c[1] "scene_z" $b
            if (-not $needed -and $d.Changed) { throw "'$($c[0])'/'$($c[1])' button=$b : skipped but the decision would change it" }
        }
    }
}

Check "Test-PrefixConnectFillDue: only the unreachable -> reachable transition fires" {
    if (-not (Test-PrefixConnectFillDue -WasReachable $false -IsReachable $true)) { throw "false->true" }
    if (Test-PrefixConnectFillDue -WasReachable $true -IsReachable $true) { throw "true->true" }
    if (Test-PrefixConnectFillDue -WasReachable $true -IsReachable $false) { throw "true->false" }
    if (Test-PrefixConnectFillDue -WasReachable $false -IsReachable $false) { throw "false->false" }
    if (Test-PrefixConnectFillDue -WasReachable $null -IsReachable $true) { throw "unknown->true (startup is handled separately)" }
}

# ---------------------------------------------------------------- state file
Check "resolver: _last_video.txt is a state file, maya_get_scene_name.py lives in maya\" {
    $p = Get-ToolPath -ScriptDir $ScriptsRoot -Name "_last_video.txt"
    if ((Norm $p) -ne (Norm (Join-Path $ScriptsRoot "state\_last_video.txt"))) { throw "state -> $p" }
    $s = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_get_scene_name.py"
    if ((Norm $s) -ne (Norm (Join-Path $ScriptsRoot "maya\maya_get_scene_name.py"))) { throw "scene script -> $s" }
    if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { throw "scene script missing" }
}

Check "Write-LastVideoPath: UTF-8 without BOM, overwritten per leg, empty clears it" {
    $sd = New-TempDir "state"
    try {
        $jp = "C:\" + (U @(0x30C6, 0x30B9, 0x30C8)) + "\take_front_back.mp4"
        $p = Write-LastVideoPath -ScriptDir $sd -Path $jp
        if ((Norm $p) -ne (Norm (Join-Path $sd "state\_last_video.txt"))) { throw "wrote to $p" }
        $bytes = [IO.File]::ReadAllBytes($p)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw "BOM written" }
        $back = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false))).Trim()
        if ($back -cne $jp) { throw "read back '$back'" }
        Write-LastVideoPath -ScriptDir $sd -Path "C:\v\take_left_right.mp4" | Out-Null
        $back = [IO.File]::ReadAllText($p).Trim()
        if ($back -ne "C:\v\take_left_right.mp4") { throw "not overwritten: '$back'" }
        Write-LastVideoPath -ScriptDir $sd -Path "" | Out-Null
        if ([IO.File]::ReadAllText($p).Trim() -ne "") { throw "not cleared" }
    } finally { Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- step builder
$FakePre = Join-Path $env:TEMP "t87_fake_user\d4_rom_pre_record.py"
$FakePost = Join-Path $env:TEMP "t87_fake_user\d4_rom_post_record.py"
$FakeCtx = Join-Path $env:TEMP "t87_fake_user\_hook_context.json"

Check "empty / whitespace / all-unsafe prefix leaves every step list identical (all axes, ranges, preview, hooks)" {
    foreach ($axis in @("FrontBack", "LeftRight", "All")) {
        foreach ($rec in @($true, $false)) {
            foreach ($range in @($null, @(0, 100))) {
                $sf = if ($range) { $range[0] } else { $null }
                $ef = if ($range) { $range[1] } else { $null }
                foreach ($hooks in @($false, $true)) {
                    $hp = @{}
                    if ($hooks) { $hp = @{ PreHookPath = $FakePre; PostHookPath = $FakePost; HookContextPath = $FakeCtx } }
                    $plain = StepsText (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -StartFrame $sf -EndFrame $ef @hp)
                    foreach ($p in @("", "   ", '\/:*?"<>|')) {
                        $with = StepsText (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -StartFrame $sf -EndFrame $ef -NamePrefix $p @hp)
                        if ($with -cne $plain) { throw "$axis rec=$rec range=$sf-$ef hooks=$hooks prefix='$p' differs" }
                    }
                }
            }
        }
        $pv = StepsText (Get-CaptureStepsForAxis -Axis (Get-PreviewAxis -Axis $axis) -Recording $false -ScriptDir $ScriptsRoot)
        $pv2 = StepsText (Get-CaptureStepsForAxis -Axis (Get-PreviewAxis -Axis $axis) -Recording $false -ScriptDir $ScriptsRoot -NamePrefix "")
        if ($pv -cne $pv2) { throw "preview $axis differs" }
    }
}

Check "a prefix adds -NamePrefix <safe> -LegAxis <leg> to the capture script only (All: FrontBack then LeftRight)" {
    $steps = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -StartFrame 0 -EndFrame 100 -NamePrefix "my take")
    $obs = ObsStepsOf $steps
    if ($obs.Count -ne 2) { throw "expected 2 capture steps, got $($obs.Count)" }
    $a0 = @($obs[0].Arguments); $a1 = @($obs[1].Arguments)
    $i0 = [array]::IndexOf($a0, "-NamePrefix"); $j0 = [array]::IndexOf($a0, "-LegAxis")
    if ($i0 -lt 0 -or $a0[$i0 + 1] -cne "my_take") { throw "leg 0 prefix: $($a0 -join ' ')" }
    if ($j0 -lt 0 -or $a0[$j0 + 1] -ne "FrontBack") { throw "leg 0 axis: $($a0 -join ' ')" }
    $i1 = [array]::IndexOf($a1, "-NamePrefix"); $j1 = [array]::IndexOf($a1, "-LegAxis")
    if ($i1 -lt 0 -or $a1[$i1 + 1] -cne "my_take") { throw "leg 1 prefix: $($a1 -join ' ')" }
    if ($j1 -lt 0 -or $a1[$j1 + 1] -ne "LeftRight") { throw "leg 1 axis: $($a1 -join ' ')" }
    if (([array]::IndexOf($a0, "-StartFrame")) -lt 0) { throw "range args lost" }
    # every other step is unchanged
    $plain = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -StartFrame 0 -EndFrame 100)
    if ($plain.Count -ne $steps.Count) { throw "step count changed" }
    for ($k = 0; $k -lt $steps.Count; $k++) {
        $isObs = (@($steps[$k].Arguments) -join ' ') -like "*maya_obs_capture.ps1*"
        if (-not $isObs -and (StepText $steps[$k]) -cne (StepText $plain[$k])) { throw "step $k changed" }
    }
    $lr = ObsStepsOf (Get-CaptureSteps -Axis "LeftRight" -Recording $true -ScriptDir $ScriptsRoot -NamePrefix "x")
    $alr = @($lr[0].Arguments)
    if ($alr[[array]::IndexOf($alr, "-LegAxis") + 1] -ne "LeftRight") { throw "LeftRight single leg" }
}

Check "the prefix in the capture arguments never needs quoting (no spaces, no double quotes)" {
    $obs = ObsStepsOf (Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -NamePrefix ' a "b" c ')
    $a = @($obs[0].Arguments)
    $v = $a[[array]::IndexOf($a, "-NamePrefix") + 1]
    if ($v -match '[\s"]') { throw "value '$v'" }
}

Check "Get-CaptureStepsWithHooks passes -NamePrefix through (no user scripts and with a hook error alike)" {
    $tmpRoot = New-TempDir "wh"
    try {
        $sd = Join-Path $tmpRoot "scripts"
        New-Item -ItemType Directory -Path $sd -Force | Out-Null
        $b = Get-CaptureStepsWithHooks -Axis "All" -ScriptDir $sd -ToolVersion "9.9.9" -NamePrefix "take"
        $obs = ObsStepsOf $b.Steps
        if ($obs.Count -ne 2) { throw "capture steps $($obs.Count)" }
        foreach ($o in $obs) { if ((@($o.Arguments) -join ' ') -notlike "*-NamePrefix take*") { throw "missing prefix: $(@($o.Arguments) -join ' ')" } }
        $b0 = Get-CaptureStepsWithHooks -Axis "All" -ScriptDir $sd -ToolVersion "9.9.9"
        if ((StepsText $b0.Steps) -match "NamePrefix") { throw "no prefix given but -NamePrefix present" }
    } finally { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- capture script
Check "maya_obs_capture.ps1 parses with 0 errors and declares -NamePrefix and -LegAxis" {
    $path = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_obs_capture.ps1"
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$err)
    if ($err.Count) { throw "parse errors: $($err[0].Message)" }
    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($n in @("StartFrame", "EndFrame", "NamePrefix", "LegAxis")) { if ($names -notcontains $n) { throw "param $n missing" } }
    $np = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "NamePrefix" }
    if ($np.DefaultValue.Extent.Text -notin @('""', "''")) { throw "NamePrefix default is $($np.DefaultValue.Extent.Text)" }
}

Check "maya_obs_capture.ps1 uses the StopRecord reply path, renames, writes _last_video.txt, clears it at start" {
    $text = Get-Content -LiteralPath (Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_obs_capture.ps1") -Raw
    foreach ($needle in @("Get-ObsRecordOutputPath", "Rename-RecordedVideo", "Write-LastVideoPath", "RecordStateChanged", "Format-ObsMessageSummary")) {
        if ($text -notlike "*$needle*") { throw "$needle not used" }
    }
    $clear = $text.IndexOf('Write-LastVideoPath -ScriptDir $ScriptDir -Path ""')
    $start = $text.IndexOf('Invoke-ObsRecordAction "start"')
    if ($clear -lt 0 -or $start -lt 0 -or $clear -gt $start) { throw "_last_video.txt is not cleared before recording starts" }
}

# ---------------------------------------------------------------- launcher
function Get-LauncherAst {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptsRoot "rom_launcher.ps1"), [ref]$tok, [ref]$err)
    if ($err.Count) { throw "launcher parse errors: $($err[0].Message)" }
    return $ast
}
function Get-LauncherXaml {
    $lines = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1")
    $start = ($lines | Select-String -SimpleMatch '[xml]$xaml = @"' | Select-Object -First 1).LineNumber
    $end = ($lines | Select-String -Pattern '^"@' | Where-Object { $_.LineNumber -gt $start } | Select-Object -First 1).LineNumber
    [xml]$x = ($lines[$start..($end - 2)]) -join "`n"
    return $x
}
$XNs = "http://schemas.microsoft.com/winfx/2006/xaml"
function Find-XName($x, [string]$name) {
    $nsm = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
    $nsm.AddNamespace("x", $XNs)
    return $x.SelectSingleNode("//*[@x:Name='$name']", $nsm)
}

Check "launcher parses with 0 errors and has the prefix functions + the busy-indicator seam" {
    $ast = Get-LauncherAst
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    foreach ($f in @("Get-MayaSceneName", "Update-PrefixFromScene", "Show-PrefixBusy", "Hide-PrefixBusy", "Update-PrefixHint", "Get-RecordingNamePrefix")) {
        if ($fns -notcontains $f) { throw "function $f missing" }
    }
}

Check "Prefix XAML row: label, box (32 high), placeholder, 36x32 scene button, last row of Settings" {
    $x = Get-LauncherXaml
    $label = Find-XName $x "PrefixLabel"; $box = Find-XName $x "PrefixBox"; $hint = Find-XName $x "PrefixHint"; $btn = Find-XName $x "PrefixFromSceneButton"
    if (-not $label -or $label.LocalName -ne "TextBlock" -or $label.Text -ne "ROM video prefix") { throw "PrefixLabel" }
    if (-not $box -or $box.LocalName -ne "TextBox" -or $box.Height -ne "32") { throw "PrefixBox" }
    if (-not $hint -or $hint.LocalName -ne "TextBlock" -or $hint.Text -ne "auto from the Maya scene name" -or $hint.IsHitTestVisible -ne "False") { throw "PrefixHint" }
    if (-not $btn -or $btn.LocalName -ne "Button" -or $btn.Width -ne "36" -or $btn.Height -ne "32") { throw "PrefixFromSceneButton size" }
    if ($btn.GetAttribute("AutomationProperties.Name") -ne "Use the Maya scene name") { throw "button automation name '$($btn.GetAttribute('AutomationProperties.Name'))'" }
    if (-not $btn.ToolTip) { throw "button tooltip" }
    if (-not $box.ToolTip) { throw "box tooltip" }
    $settings = Find-XName $x "SettingsPanel"
    $lastRow = @($settings.ChildNodes | Where-Object { $_.NodeType -eq "Element" })[-1]
    if (-not $lastRow.SelectSingleNode(".//*[local-name()='TextBox']")) { throw "the Prefix row is not the last Settings row" }
    if ($lastRow.SelectSingleNode(".//*[local-name()='TextBox']").GetAttribute("Name", $XNs) -ne "PrefixBox") { throw "last row box is not PrefixBox" }
}

Check "Prefix XAML loads in WPF (no window shown) and the label column is shared with the Monitor row" {
    Add-Type -AssemblyName PresentationFramework
    $x = Get-LauncherXaml
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    try {
        foreach ($n in @("PrefixLabel", "PrefixBox", "PrefixHint", "PrefixFromSceneButton")) { if (-not $w.FindName($n)) { throw "FindName $n" } }
        $settings = $w.FindName("SettingsPanel")
        if (-not [System.Windows.Controls.Grid]::GetIsSharedSizeScope($settings)) { throw "SettingsPanel is not a shared size scope" }
        $prefixGrid = $w.FindName("PrefixBox").Parent.Parent
        $monGrid = $w.FindName("MonitorComboBox").Parent
        $g1 = $prefixGrid.ColumnDefinitions[0].SharedSizeGroup; $g2 = $monGrid.ColumnDefinitions[0].SharedSizeGroup
        if (-not $g1 -or $g1 -ne $g2) { throw "label columns not shared ('$g1' / '$g2')" }
    } finally { $w.Close() }
}

Check "Prefix box and button are disabled during a run like the other inputs (Set-ButtonsEnabled)" {
    $ast = Get-LauncherAst
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Set-ButtonsEnabled" }, $true) | Select-Object -First 1
    $body = $fn.Body.Extent.Text
    if ($body -notmatch '\$prefixBox\.IsEnabled\s*=\s*\$enabled') { throw "prefixBox not gated" }
    if ($body -notmatch '\$prefixFromSceneButton') { throw "prefixFromSceneButton not gated" }
}

Check "launcher: Start Recording reads the prefix ONCE (Get-RecordingNamePrefix) and passes it to the step builder" {
    $text = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    if ($text -notmatch 'Get-CaptureStepsWithHooks[^\r\n]*-NamePrefix') { throw "Get-CaptureStepsWithHooks call has no -NamePrefix" }
    if (([regex]::Matches($text, 'Get-RecordingNamePrefix\b(?!\s*\{)')).Count -lt 1) { throw "Get-RecordingNamePrefix never called" }
}

# ---------------------------------------------------------------- maya_get_scene_name.py (plain python, fake maya.cmds)
$SceneScript = Join-Path $ScriptsRoot "maya\maya_get_scene_name.py"

Check "maya_get_scene_name.py is ASCII-only, no BOM" {
    if (-not (Test-Path -LiteralPath $SceneScript)) { throw "missing" }
    $b = [IO.File]::ReadAllBytes($SceneScript)
    if (@($b | Where-Object { $_ -gt 127 }).Count) { throw "non-ASCII bytes" }
}

Check "maya_get_scene_name.py under python + fake maya.cmds: name, a.v2.ma, untitled, error, unicode, run twice = one line" {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { throw "python not on PATH" }
    $d = New-TempDir "py"
    try {
        $fake = Join-Path $d "maya"
        New-Item -ItemType Directory -Path $fake -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $fake "__init__.py"), "")
        [IO.File]::WriteAllText((Join-Path $fake "cmds.py"), @"
import os
def file(*args, **kwargs):
    assert kwargs.get('q') or kwargs.get('query'), 'query flag'
    assert kwargs.get('sceneName') or kwargs.get('sn'), 'sceneName flag'
    v = os.environ.get('T87_FAKE_SCENE', '')
    if v == '<raise>':
        raise RuntimeError('fake failure\nsecond line')
    if v.startswith('<hex>'):
        return bytearray.fromhex(v[5:]).decode('utf-8')
    return v
"@)
        $driver = Join-Path $d "driver.py"
        [IO.File]::WriteAllText($driver, @"
import io, sys
sys.path.insert(0, sys.argv[3])
path = sys.argv[1]
out = sys.argv[2]
for _ in range(2):  # Maya's command port runs every payload twice
    exec(compile(open(path).read(), path, 'exec'), {'D4_SCENE_NAME_RESULT_PATH': out})
"@)
        $cases = @(
            @("D:/proj/scenes/barM_stor282_WIP_ROM.ma", "SCENE_NAME barM_stor282_WIP_ROM"),
            @("D:\proj\scenes\a.v2.ma", "SCENE_NAME a.v2"),
            @("D:/proj/my scene.mb", "SCENE_NAME my scene"),
            @("", "SCENE_UNTITLED"),
            @("<raise>", "SCENE_NAME_ERROR RuntimeError: fake failure second line"),
            @(("<hex>" + (-join ([Text.Encoding]::UTF8.GetBytes("D:/p/" + (U @(0x30C6, 0x30B9, 0x30C8)) + ".ma") | ForEach-Object { $_.ToString("x2") }))), ("SCENE_NAME " + (U @(0x30C6, 0x30B9, 0x30C8))))
        )
        $bad = @()
        foreach ($c in $cases) {
            $out = Join-Path $d ("res_" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".txt")
            $env:T87_FAKE_SCENE = $c[0]
            $o = & python $driver $SceneScript $out $d 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { $bad += "'$($c[0])': python exit $LASTEXITCODE $o"; continue }
            $text = [IO.File]::ReadAllText($out, (New-Object System.Text.UTF8Encoding($false)))
            $lines = @($text -split "`n" | Where-Object { $_ -ne "" })
            if ($lines.Count -ne 1) { $bad += "'$($c[0])': $($lines.Count) lines"; continue }
            if ($lines[0] -cne $c[1]) { $bad += "'$($c[0])': '$($lines[0])' (expected '$($c[1])')" }
            $parsed = ConvertFrom-SceneNameOutput -Output $text
            if ($c[1] -like "SCENE_NAME *" -and $parsed.Name -cne $c[1].Substring(11)) { $bad += "'$($c[0])': parsed '$($parsed.Name)'" }
        }
        if ($bad.Count) { throw ($bad -join "; ") }
    } finally {
        Remove-Item Env:\T87_FAKE_SCENE -ErrorAction SilentlyContinue
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "maya_get_scene_name.py: default result file is d4_anim_sample\_scene_name_result.txt (launcher reads the same)" {
    $t = Get-Content -LiteralPath $SceneScript -Raw
    if ($t -notlike "*_scene_name_result.txt*") { throw "script result name" }
    $l = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    if ($l -notlike "*d4_anim_sample\_scene_name_result.txt*") { throw "launcher result path" }
}

# ---------------------------------------------------------------- T87 phase 2: busy bar + async fill (pure parts)
Check "Get-BusyBarGeometry: 30% segment, back-and-forth travel 0..width-segment, fraction clamped" {
    $g = Get-BusyBarGeometry -BarWidth 420 -Fraction 0
    if ($g.SegmentWidth -ne 126 -or $g.Travel -ne 294 -or $g.X -ne 0) { throw "f=0: $($g | ConvertTo-Json -Compress)" }
    $g = Get-BusyBarGeometry -BarWidth 420 -Fraction 0.5
    if ($g.X -ne 147) { throw "f=0.5: X $($g.X)" }
    $g = Get-BusyBarGeometry -BarWidth 420 -Fraction 1
    if ($g.X -ne 294) { throw "f=1: X $($g.X)" }
    $g = Get-BusyBarGeometry -BarWidth 420 -Fraction 7
    if ($g.X -ne 294) { throw "clamp high: X $($g.X)" }
    $g = Get-BusyBarGeometry -BarWidth 380 -Fraction -1
    if ($g.SegmentWidth -ne 114 -or $g.X -ne 0) { throw "380 / clamp low: $($g | ConvertTo-Json -Compress)" }
    $g = Get-BusyBarGeometry -BarWidth 0 -Fraction 0.5
    if ($g.SegmentWidth -ne 0 -or $g.Travel -ne 0) { throw "zero width: $($g | ConvertTo-Json -Compress)" }
}

Check "Get-PrefixAsyncStartDecision: one fetch at a time, never during a run, never for typed text" {
    $d = Get-PrefixAsyncStartDecision -Busy $false -RunActive $false -CurrentText "" -LastAutoFill ""
    if (-not $d.Start -or $d.Reason -ne "start") { throw "empty box: $($d | ConvertTo-Json -Compress)" }
    $d = Get-PrefixAsyncStartDecision -Busy $true -RunActive $false -CurrentText "" -LastAutoFill ""
    if ($d.Start -or $d.Reason -ne "busy") { throw "second start while busy: $($d | ConvertTo-Json -Compress)" }
    $d = Get-PrefixAsyncStartDecision -Busy $false -RunActive $true -CurrentText "" -LastAutoFill ""
    if ($d.Start -or $d.Reason -ne "run_active") { throw "during a run: $($d | ConvertTo-Json -Compress)" }
    $d = Get-PrefixAsyncStartDecision -Busy $false -RunActive $false -CurrentText "my_take" -LastAutoFill "scene_a"
    if ($d.Start -or $d.Reason -ne "not_needed") { throw "typed text: $($d | ConvertTo-Json -Compress)" }
    $d = Get-PrefixAsyncStartDecision -Busy $false -RunActive $false -CurrentText "scene_a" -LastAutoFill "scene_a"
    if (-not $d.Start) { throw "auto-filled text (stale rule) must be refreshable" }
}

Check "Get-PrefixAsyncPollDecision: wait / complete / timeout / discard (a run started meanwhile)" {
    if ((Get-PrefixAsyncPollDecision -HasExited $false -ElapsedMs 100 -TimeoutMs 3000 -RunActive $false) -ne "wait") { throw "wait" }
    if ((Get-PrefixAsyncPollDecision -HasExited $true -ElapsedMs 900 -TimeoutMs 3000 -RunActive $false) -ne "complete") { throw "complete" }
    if ((Get-PrefixAsyncPollDecision -HasExited $true -ElapsedMs 5000 -TimeoutMs 3000 -RunActive $false) -ne "complete") { throw "exited late still completes" }
    if ((Get-PrefixAsyncPollDecision -HasExited $false -ElapsedMs 3000 -TimeoutMs 3000 -RunActive $false) -ne "timeout") { throw "timeout at the limit" }
    if ((Get-PrefixAsyncPollDecision -HasExited $false -ElapsedMs 100 -TimeoutMs 3000 -RunActive $true) -ne "discard") { throw "discard running" }
    if ((Get-PrefixAsyncPollDecision -HasExited $true -ElapsedMs 100 -TimeoutMs 3000 -RunActive $true) -ne "discard") { throw "discard exited" }
}

Check "Get-PrefixSceneApplyResult: the ONE decision both the sync and the async path apply (stale rule, typed text, untitled, errors)" {
    function SceneOf([string]$o) { return ConvertFrom-SceneNameOutput -Output $o }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME scene_a") -CurrentText "" -LastAutoFill "" -Trigger "Maya connected"
    if ($r.Text -cne "scene_a" -or -not $r.Changed -or $r.LastAutoFill -cne "scene_a" -or $r.LogLine -notlike "*Maya connected*scene_a*") { throw "fill: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME scene_b") -CurrentText "scene_a" -LastAutoFill "scene_a" -Trigger "t"
    if ($r.Text -cne "scene_b" -or -not $r.Changed -or $r.LogLine -notlike "*updated*scene_b*") { throw "stale refresh: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME scene_b") -CurrentText "my_take" -LastAutoFill "scene_a" -Trigger "t"
    if ($r.Text -cne "my_take" -or $r.Changed -or $r.LastAutoFill -cne "scene_a" -or $r.LogLine) { throw "typed text: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME scene_b") -CurrentText "my_take" -LastAutoFill "scene_a" -FromButton $true
    if ($r.Text -cne "scene_b" -or -not $r.Changed -or $r.LogLine -notlike "*set to the Maya scene name*") { throw "button: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_UNTITLED") -CurrentText "scene_a" -LastAutoFill "scene_a" -Trigger "t"
    if ($r.Changed -or $r.Text -cne "scene_a" -or $r.LogLine -notlike "*untitled*") { throw "untitled: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "") -CurrentText "" -LastAutoFill "" -Trigger "t"
    if ($r.Changed -or $r.LogLine -notlike "*could not read*") { throw "no reply: $($r | ConvertTo-Json -Compress)" }
    $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME_ERROR RuntimeError: x") -CurrentText "" -LastAutoFill "" -Trigger "t"
    if ($r.Changed -or $r.LogLine -notlike "*RuntimeError: x*") { throw "error: $($r | ConvertTo-Json -Compress)" }
    # agrees with Get-PrefixFillDecision for every named case
    foreach ($c in @(@("", ""), @("a", "a"), @("a", "b"), @("A", "a"), @("t", ""))) {
        foreach ($b in @($false, $true)) {
            $r = Get-PrefixSceneApplyResult -Scene (SceneOf "SCENE_NAME z") -CurrentText $c[0] -LastAutoFill $c[1] -FromButton $b
            $d = Get-PrefixFillDecision -CurrentText $c[0] -LastAutoFill $c[1] -SceneName "z" -FromButton $b
            if ($r.Text -cne $d.Text -or $r.LastAutoFill -cne $d.LastAutoFill -or $r.Changed -ne $d.Changed) { throw "disagrees with the fill decision for '$($c[0])'/'$($c[1])' button=$b" }
        }
    }
}

Check "TopBusyBar XAML: 3 px overlay at the window top, collapsed, not hit-testable, launcher ProgressBar colours" {
    $x = Get-LauncherXaml
    $bar = Find-XName $x "TopBusyBar"; $seg = Find-XName $x "TopBusyBarSegment"
    if (-not $bar -or $bar.LocalName -ne "Border") { throw "TopBusyBar missing" }
    if ($bar.Height -ne "3" -or $bar.Visibility -ne "Collapsed" -or $bar.IsHitTestVisible -ne "False" -or $bar.ClipToBounds -ne "True") { throw "bar attributes" }
    if ($bar.Background -ne "#FF1C1C1C") { throw "track colour $($bar.Background)" }
    if ($bar.VerticalAlignment -ne "Top" -or $bar.Margin -ne "-5,-5,-5,0") { throw "bar placement $($bar.VerticalAlignment) / $($bar.Margin)" }
    if (-not $seg -or $seg.LocalName -ne "Rectangle" -or $seg.Fill -ne "#FFD0D0D0") { throw "segment" }
    $root = $bar.ParentNode
    if ($root.GetAttribute("Margin") -ne "5" -or $bar.GetAttribute("Grid.RowSpan") -ne "2") { throw "bar is not an overlay of the root grid" }
}

Check "launcher: async fill on connect/launch, sync clicks without the bar, one shared apply decision" {
    $ast = Get-LauncherAst
    $fnBody = { param($n) ($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true) | Select-Object -First 1).Body.Extent.Text }
    foreach ($f in @("Start-PrefixFillAsync", "Update-PrefixFillAsync", "Stop-PrefixFillAsync", "Start-SceneNameProcess", "Get-SceneNameResultPath", "Get-PrefixAsyncElapsedMs")) {
        if (-not (& $fnBody $f)) { throw "function $f missing" }
    }
    if ((& $fnBody "Invoke-PortCheckTick") -notmatch "Start-PrefixFillAsync" -or (& $fnBody "Invoke-PortCheckTick") -match "Update-PrefixFromScene") { throw "connect fill is not async" }
    $text = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    $cr = $text.Substring($text.IndexOf('$window.Add_ContentRendered('), 400)
    if ($cr -notmatch "Start-PrefixFillAsync" -or $cr -match "Update-PrefixFromScene") { throw "launch fill is not async" }
    if ((& $fnBody "Update-PrefixFillAsync") -notmatch "Get-PrefixSceneApplyResult") { throw "async path does not use the shared decision" }
    if ((& $fnBody "Update-PrefixFromScene") -notmatch "Get-PrefixSceneApplyResult") { throw "sync path does not use the shared decision" }
    if ((& $fnBody "Update-PrefixFromScene") -match "Show-PrefixBusy") { throw "the sync path must not show the bar (it cannot draw while the UI thread is blocked)" }
    if ((& $fnBody "Show-PrefixBusy") -notmatch "TopBusyBar" -or (& $fnBody "Hide-PrefixBusy") -notmatch "TopBusyBar") { throw "busy seam not implemented" }
}

Check "the busy bar never appears in a step list" {
    foreach ($axis in @("FrontBack", "LeftRight", "All")) {
        foreach ($rec in @($true, $false)) {
            $t = StepsText (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -NamePrefix "take")
            if ($t -match "Busy|maya_get_scene_name") { throw "$axis rec=$rec mentions the busy bar / scene query" }
        }
    }
}

# ---------------------------------------------------------------- T87 QA fix round (LOW-1/2/3, MED-1 mutants M12/M16/M18)
Check "LOW-1 Get-SafePrefix strips zero-width / bidi marks; a prefix of only those = empty" {
    $zw = [string][char]0x200B; $rlo = [string][char]0x202E; $wj = [string][char]0x2060; $bom = [string][char]0xFEFF; $lrm = [string][char]0x200E
    $cases = @(
        @(("a" + $zw + "b"), "ab"),
        @(($rlo + "evil"), "evil"),
        @(("take" + $lrm + $wj), "take"),
        @(($zw + $bom), ""),
        @(($wj + " " + $zw), ""),
        @(([string][char]0x202A + [string][char]0x200F), "")
    )
    foreach ($c in $cases) {
        $got = Get-SafePrefix -Prefix $c[0]
        if ($got -cne $c[1]) { throw "case $([array]::IndexOf($cases, $c)): got '$got' expected '$($c[1])'" }
    }
    $steps = StepsText (Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -NamePrefix ($zw + $bom))
    if ($steps -match "NamePrefix") { throw "an invisible-only prefix still added -NamePrefix" }
}

Check "LOW-2 Rename-RecordedVideo: a source already named {prefix}_front_back.<ext> stays in place (no _2)" {
    $d = New-TempDir "same"
    try {
        $src = Join-Path $d "take_front_back_14_32.mp4"
        $h = New-FakeVideo $src
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "take" -LegAxis "FrontBack"
        if ((Norm $r.Path) -ne (Norm $src)) { throw "path $($r.Path)" }
        if (-not (Test-Path -LiteralPath $src) -or (HashOf $src) -ne $h) { throw "source moved/changed" }
        if (Test-Path -LiteralPath (Join-Path $d "take_front_back_14_32_2.mp4")) { throw "renamed to _2" }
        if (@($r.Log | Where-Object { $_ -like "WARNING*" }).Count) { throw "warning for an already-named file" }
        $src2 = Join-Path $d "TAKE_left_right_14_32.MKV"
        New-FakeVideo $src2 | Out-Null
        $r2 = Rename-RecordedVideo -SourcePath $src2 -Prefix "take" -LegAxis "LeftRight"
        if ((Norm $r2.Path) -ne (Norm $src2) -or @(Get-ChildItem $d).Count -ne 2) { throw "case-insensitive same name moved: $($r2.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "LOW-3 kept / OBS-reported paths are written with backslashes like renamed paths" {
    $r = Rename-RecordedVideo -SourcePath "C:/t87_no_such_dir/x.mp4" -Prefix "take" -LegAxis "FrontBack"
    if ($r.Path -ne "C:\t87_no_such_dir\x.mp4") { throw "kept path '$($r.Path)'" }
    $r = Rename-RecordedVideo -SourcePath "C:/t87_no_such_dir/x.mp4" -Prefix "" -LegAxis "FrontBack"
    if ($r.Path -ne "C:\t87_no_such_dir\x.mp4") { throw "skipped path '$($r.Path)'" }
    $sd = New-TempDir "bs"
    try {
        $p = Write-LastVideoPath -ScriptDir $sd -Path "D:/cap/x.mkv"
        $t = [IO.File]::ReadAllText($p).Trim()
        if ($t -ne "D:\cap\x.mkv") { throw "_last_video.txt '$t'" }
    } finally { Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-FunctionText([string]$Path, [string]$Name) {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "function $Name not found in $Path" }
    return $fn.Extent.Text
}

Check "M16 launcher Get-RecordingNamePrefix (executed) returns the sanitized Prefix box text" {
    $prefixBox = [PSCustomObject]@{ Text = " my take:1 " }
    Invoke-Expression (Get-FunctionText (Join-Path $ScriptsRoot "rom_launcher.ps1") "Get-RecordingNamePrefix")
    $got = Get-RecordingNamePrefix
    if ($got -cne "my_take_1") { throw "got '$got'" }
    $prefixBox = [PSCustomObject]@{ Text = "" }
    if ((Get-RecordingNamePrefix) -ne "") { throw "empty box" }
}

Check "M18 capture script finally block (executed): restores first, then Complete-RecordedVideo, only after a StopRecord" {
    $capPath = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_obs_capture.ps1"
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($capPath, [ref]$tok, [ref]$err)
    $try = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Finally })[-1]
    if (-not $try) { throw "no top-level try/finally" }
    $ft = $try.Finally.Extent.Text; $finallyText = $ft.Substring(1, $ft.Length - 2)
    $script:calls = @()
    function Set-MayaFrameRange { $script:calls += "range" }
    function Set-MayaHudState { $script:calls += "hud" }
    function Clear-MayaHudStateFile { $script:calls += "hudfile" }
    function Show-Taskbar { $script:calls += "taskbar" }
    function Complete-RecordedVideo { param($info) $script:calls += "video:$($info.OutputPath)" }
    $originalRange = [PSCustomObject]@{ MinTime = 0; MaxTime = 10 }; $originalHud = [PSCustomObject]@{}
    $stopInfo = [PSCustomObject]@{ OutputPath = "D:\cap\x.mkv"; Source = "response" }
    & ([scriptblock]::Create($finallyText)) 6>$null
    $seq = $script:calls -join ","
    if ($seq -ne "range,hud,hudfile,taskbar,video:D:\cap\x.mkv") { throw "order '$seq'" }
    $script:calls = @(); $stopInfo = $null
    & ([scriptblock]::Create($finallyText)) 6>$null
    if (($script:calls -join ",") -match "video") { throw "Complete-RecordedVideo ran without a StopRecord" }
}

Check "M18 capture Complete-RecordedVideo (executed): renames with the prefix and writes _last_video.txt" {
    $capPath = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_obs_capture.ps1"
    Invoke-Expression (Get-FunctionText $capPath "Complete-RecordedVideo")
    $d = New-TempDir "crv"
    try {
        $ScriptDir = Join-Path $d "scripts"; New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null
        $video = Join-Path $d "2026-10-26 07-00-00.mkv"; New-FakeVideo $video | Out-Null
        $SafeNamePrefix = "take"; $LegAxis = "LeftRight"
        Complete-RecordedVideo ([PSCustomObject]@{ OutputPath = $video.Replace('\', '/'); Source = "event" }) 6>$null
        $want = Join-Path $d "take_left_right_14_32.mkv"
        if (-not (Test-Path -LiteralPath $want)) { throw "not renamed" }
        $last = [IO.File]::ReadAllText((Join-Path $ScriptDir "state\_last_video.txt")).Trim()
        if ((Norm $last) -ne (Norm $want) -or $last.Contains("/")) { throw "_last_video.txt '$last'" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "M12 capture StopRecord (executed against a fake OBS WebSocket): no outputPath in the reply -> the STOPPED event's path is used" {
    $capPath = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_obs_capture.ps1"
    foreach ($fn in @("Send-WsMessage", "Receive-WsMessage", "Receive-WsMessageTimed", "Get-AuthString", "Connect-ObsWebSocket", "Invoke-ObsRecordAction")) {
        Invoke-Expression (Get-FunctionText $capPath $fn)
    }
    # the script's own wait statement, evaluated as written
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($capPath, [ref]$tok, [ref]$err)
    $waitStmt = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$waitMs' }, $true) | Select-Object -First 1
    if (-not $waitStmt) { throw "no `$waitMs statement" }
    $SafeNamePrefix = "take"
    Invoke-Expression $waitStmt.Extent.Text
    $port = 47000 + (Get-Random -Maximum 900)
    $d = New-TempDir "obs"
    $ScriptDir = $d
    [IO.File]::WriteAllText((Join-Path $d "obs_config.txt"), "host: 127.0.0.1`nport: $port`npassword: unused`n")
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $server = [PowerShell]::Create()
    [void]$server.AddScript({
        param($listener)
        function SendJ($ws, [string]$j) { $b = [Text.Encoding]::UTF8.GetBytes($j); $ws.SendAsync([ArraySegment[byte]]::new($b), 'Text', $true, [Threading.CancellationToken]::None).Wait() }
        function RecvJ($ws) { $buf = New-Object byte[] 65536; $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None).GetAwaiter().GetResult(); return ([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json) }
        $ctx = $listener.GetContextAsync().GetAwaiter().GetResult()
        $ws = $ctx.AcceptWebSocketAsync([NullString]::Value).GetAwaiter().GetResult().WebSocket
        SendJ $ws '{"op":0,"d":{"obsWebSocketVersion":"5.0.0","rpcVersion":1}}'
        RecvJ $ws | Out-Null
        SendJ $ws '{"op":2,"d":{"negotiatedRpcVersion":1}}'
        $req = RecvJ $ws
        SendJ $ws ('{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputActive":false,"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPING","outputPath":null}}}')
        SendJ $ws ('{"op":7,"d":{"requestType":"StopRecord","requestId":"' + $req.d.requestId + '","requestStatus":{"result":true,"code":100}}}')
        Start-Sleep -Milliseconds 400
        SendJ $ws '{"op":5,"d":{"eventType":"RecordStateChanged","eventData":{"outputActive":false,"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":"D:/cap/2026-10-26 07-00-00.mkv"}}}'
        Start-Sleep -Milliseconds 1500
    }).AddArgument($listener)
    $handle = $server.BeginInvoke()
    try {
        $info = Invoke-ObsRecordAction "stop" -WaitForOutputPathMs $waitMs 6>$null
        if ($info.OutputPath -ne "D:/cap/2026-10-26 07-00-00.mkv" -or $info.Source -ne "event") { throw "got '$($info.OutputPath)' from '$($info.Source)' (wait $waitMs ms)" }
        if ($waitMs -lt 5000) { throw "the event wait is only $waitMs ms" }
    } finally {
        try { $server.EndInvoke($handle) | Out-Null } catch {}
        $server.Dispose(); $listener.Stop()
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- T87 added scope (B): _HH_mm time stamp
Check "Get-VideoNameStamp: local 24 h HH_mm (09:05 -> 09_05, 23:59 -> 23_59, 00:00 -> 00_00)" {
    if ((Get-VideoNameStamp -Now (New-Object DateTime 2026, 1, 2, 9, 5, 59)) -ne "09_05") { throw "09_05" }
    if ((Get-VideoNameStamp -Now (New-Object DateTime 2026, 1, 2, 23, 59, 0)) -ne "23_59") { throw "23_59" }
    if ((Get-VideoNameStamp -Now (New-Object DateTime 2026, 1, 2, 0, 0, 0)) -ne "00_00") { throw "00_00" }
}

Check "Get-VideoRenameTime (the real clock, from the logic file) is the current local time" {
    $real = & { Invoke-Expression (Get-FunctionText (Join-Path $ScriptsRoot "rom_launcher_logic.ps1") "Get-VideoRenameTime"); Get-VideoRenameTime }
    if ([Math]::Abs(($real - (Get-Date)).TotalSeconds) -gt 5) { throw "clock returned $real" }
}

Check "Get-UniqueVideoPath -Stamp: {prefix}_{leg}_HH_mm<ext>, same minute -> _HH_mm_2, _3" {
    $d = New-TempDir "stamp"
    try {
        $r = Get-UniqueVideoPath -Directory $d -Prefix "barM_x" -LegAxis "FrontBack" -Extension ".mp4" -Stamp "14_32"
        if ((Split-Path $r.Path -Leaf) -ne "barM_x_front_back_14_32.mp4") { throw "first $($r.Path)" }
        [IO.File]::WriteAllText($r.Path, "1")
        $r2 = Get-UniqueVideoPath -Directory $d -Prefix "barM_x" -LegAxis "FrontBack" -Extension ".mp4" -Stamp "14_32"
        if ((Split-Path $r2.Path -Leaf) -ne "barM_x_front_back_14_32_2.mp4") { throw "second $($r2.Path)" }
        $r3 = Get-UniqueVideoPath -Directory $d -Prefix "barM_x" -LegAxis "LeftRight" -Extension ".mkv" -Stamp "14_33"
        if ((Split-Path $r3.Path -Leaf) -ne "barM_x_left_right_14_33.mkv") { throw "left_right $($r3.Path)" }
        $long = Get-UniqueVideoPath -Directory $d -Prefix ("p" * 300) -LegAxis "FrontBack" -Extension ".mp4" -Stamp "14_32"
        if ($long.Path.Length -ne 255 -or $long.Path -notmatch '_front_back_14_32\.mp4$') { throw "length guard with stamp: $($long.Path.Length) $($long.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Rename-RecordedVideo -Now: the stamp is taken from the clock at rename time" {
    $d = New-TempDir "now"
    try {
        $src = Join-Path $d "obs.mp4"; New-FakeVideo $src | Out-Null
        $r = Rename-RecordedVideo -SourcePath $src -Prefix "barM_x" -LegAxis "FrontBack" -Now (New-Object DateTime 2026, 10, 26, 9, 7, 0)
        if ((Split-Path $r.Path -Leaf) -ne "barM_x_front_back_09_07.mp4") { throw "got $($r.Path)" }
        $src2 = Join-Path $d "obs2.mp4"; New-FakeVideo $src2 | Out-Null
        $r2 = Rename-RecordedVideo -SourcePath $src2 -Prefix "barM_x" -LegAxis "LeftRight"
        if ((Split-Path $r2.Path -Leaf) -ne "barM_x_left_right_14_32.mp4") { throw "clock seam not used: $($r2.Path)" }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "(A) the launcher row label reads 'ROM video prefix'; the hint text is unchanged" {
    $x = Get-LauncherXaml
    if ((Find-XName $x "PrefixLabel").Text -ne "ROM video prefix") { throw "label" }
    if ((Find-XName $x "PrefixHint").Text -ne "auto from the Maya scene name") { throw "hint" }
}

Check "T87 files are ASCII-only (PowerShell 5.1 reads a BOM-less file as ANSI)" {
    $bad = @()
    foreach ($rel in @("rom_launcher.ps1", "rom_launcher_logic.ps1", "capture\maya_obs_capture.ps1", "maya\maya_get_scene_name.py", "hooks\maya_run_hook.py", "hooks\templates\d4_rom_post_record.py")) {
        $b = [IO.File]::ReadAllBytes((Join-Path $ScriptsRoot $rel))
        $n = @($b | Where-Object { $_ -gt 127 }).Count
        if ($n) { $bad += "$rel ($n bytes)" }
    }
    $self = [IO.File]::ReadAllBytes($PSCommandPath)
    if (@($self | Where-Object { $_ -gt 127 }).Count) { $bad += "test_prefix_naming.ps1" }
    if ($bad.Count) { throw "non-ASCII bytes in: $($bad -join ', ')" }
}

Check "rom_launcher_logic.ps1 stays functions-only (still safe to dot-source)" {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptsRoot "rom_launcher_logic.ps1"), [ref]$tok, [ref]$err)
    if ($err.Count) { throw "parse errors" }
    $nonFn = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
    if ($nonFn.Count) { throw "top-level statements in the logic file" }
}

Write-Output ""
foreach ($f in $failures) { Write-Output "FAIL: $f" }
Write-Output "$passed passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

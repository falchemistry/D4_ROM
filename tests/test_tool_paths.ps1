# Persistent path/layout test for the scripts\ category folders (T99).
# Proves the tool's files live where the approved layout says, that every
# script/file path the launcher, the logic file, the capture/OBS scripts,
# the Python scripts and the legacy .bat files reference resolves to a real
# file, that the state folder is created on demand, and that a dist build
# ships the category folders but never scripts\state or legacy\.
# Never launches Maya or OBS, never touches port 7001, never writes into the
# repo (the dist is built into a temp folder).
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_tool_paths.ps1
# Exits 0 if all checks pass, 1 otherwise.

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ScriptsRoot = Join-Path $RepoRoot "scripts"
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

# The approved layout (form_t99_reorg), written out independently of the
# resolver table in rom_launcher_logic.ps1 so the two cannot drift silently.
$ExpectedLayout = [ordered]@{
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
    "maya_get_time_slider.py" = "maya"
    "maya_key_from_cache.py" = "maya"
    "maya_key_from_cache_LR.py" = "maya"
    "maya_restore_hud.py" = "maya"
    "maya_stop_playback.py" = "maya"
    "send_to_maya.ps1" = "maya"
    "maya_obs_capture.ps1" = "capture"
    "taskbar_control.ps1" = "capture"
    "obs_control.ps1" = "obs"
    "obs_monitor.ps1" = "obs"
}
$StateFiles = @("_fps_state.txt", "_frame_range_state.txt", "_playback_state.txt", "_hud_state.json")
$LegacyBats = @("run_front_back.bat", "run_left_right.bat", "capture_front_back.bat", "capture_left_right.bat")

function Get-ExpectedPath([string]$root, [string]$name) {
    $sub = $ExpectedLayout[$name]
    if ($sub) { return Join-Path (Join-Path $root $sub) $name }
    return Join-Path $root $name
}

# A referenced path is fine when it is a real file, OR it is a file the tool
# writes at run time / the user creates (never in git): obs_config.txt at its
# one canonical place, or an underscore state file inside d4_anim_sample\ or
# scripts\state\ (scripts\state\ itself is created on demand, so a fresh
# clone may not have it yet).
function Test-ReferencedPath([string]$full) {
    $full = Norm $full
    if (Test-Path -LiteralPath $full -PathType Leaf) { return $true }
    if ($full -eq (Norm (Join-Path $ScriptsRoot "state"))) { return $true }   # the on-demand state folder itself
    $leaf = Split-Path $full -Leaf
    $parent = Norm (Split-Path $full -Parent)
    if ($leaf -eq "obs_config.txt") { return ($parent -eq (Norm $ScriptsRoot)) }
    if ($leaf.StartsWith("_") -or $leaf -eq "maya_debug.txt") {
        if ($parent -eq (Norm (Join-Path $RepoRoot "d4_anim_sample"))) { return $true }
        if ($parent -eq (Norm (Join-Path $ScriptsRoot "state"))) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- layout
Check "every tool file is at its approved location" {
    $missing = @()
    foreach ($name in $ExpectedLayout.Keys) {
        $p = Get-ExpectedPath $ScriptsRoot $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $p }
    }
    if ($missing.Count) { throw "missing: $($missing -join ', ')" }
}

Check "no moved file is left at its old flat scripts\ path" {
    $left = @()
    foreach ($name in $ExpectedLayout.Keys) {
        if (-not $ExpectedLayout[$name]) { continue }
        $old = Join-Path $ScriptsRoot $name
        if (Test-Path -LiteralPath $old) { $left += $old }
    }
    foreach ($name in $StateFiles) {
        $old = Join-Path $ScriptsRoot $name
        if (Test-Path -LiteralPath $old) { $left += $old }
    }
    if ($left.Count) { throw "still flat: $($left -join ', ')" }
}

Check "scripts\ root holds only the entry points, user data and the category folders" {
    $allowedFiles = @("rom_launcher.ps1", "rom_launcher_logic.ps1", "obs_config.txt")
    $allowedDirs = @("maya", "capture", "obs", "state", "guide_images", "hooks")
    $bad = @()
    foreach ($f in Get-ChildItem -LiteralPath $ScriptsRoot -Force) {
        if ($f.PSIsContainer) { if ($allowedDirs -notcontains $f.Name) { $bad += $f.Name } }
        elseif ($allowedFiles -notcontains $f.Name) { $bad += $f.Name }
    }
    if ($bad.Count) { throw "unexpected in scripts\: $($bad -join ', ')" }
}

Check "user data stays put: d4_anim_sample at repo root, guide_images and obs_config.txt in scripts\" {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "d4_anim_sample") -PathType Container)) { throw "d4_anim_sample missing at repo root" }
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptsRoot "guide_images") -PathType Container)) { throw "scripts\guide_images missing" }
    foreach ($sub in @("maya", "capture", "obs", "state")) {
        $d = Join-Path $ScriptsRoot $sub
        if (Test-Path -LiteralPath (Join-Path $d "obs_config.txt")) { throw "obs_config.txt found under scripts\$sub" }
        if (Test-Path -LiteralPath (Join-Path $d "d4_anim_sample")) { throw "d4_anim_sample found under scripts\$sub" }
        if (Test-Path -LiteralPath (Join-Path $d "guide_images")) { throw "guide_images found under scripts\$sub" }
    }
    if (Test-Path -LiteralPath (Join-Path $ScriptsRoot "d4_anim_sample")) { throw "d4_anim_sample found under scripts\" }
}

Check "the 4 old .bat files live in legacy\, not at the repo root" {
    foreach ($b in $LegacyBats) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "legacy\$b") -PathType Leaf)) { throw "legacy\$b missing" }
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $b)) { throw "$b still at the repo root" }
    }
}

Check "the entry points still point at scripts\rom_launcher.ps1" {
    $bat = Get-Content -LiteralPath (Join-Path $RepoRoot "rom_launcher.bat") -Raw
    if ($bat -notmatch [regex]::Escape('%~dp0scripts\rom_launcher.ps1')) { throw "rom_launcher.bat no longer points at scripts\rom_launcher.ps1" }
    $cs = Get-Content -LiteralPath (Join-Path $RepoRoot "exe_src\Program.cs") -Raw
    if ($cs -notmatch 'Path\.Combine\(exeDir,\s*"scripts",\s*"rom_launcher\.ps1"\)') { throw "exe_src\Program.cs no longer points at scripts\rom_launcher.ps1" }
}

# ---------------------------------------------------------------- resolver
. (Join-Path $ScriptsRoot "rom_launcher_logic.ps1")

Check "the resolver exists in rom_launcher_logic.ps1" {
    foreach ($fn in @("Get-ToolPathTable", "Get-ToolPath", "Get-ToolStateDir")) {
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "$fn not defined" }
    }
}

Check "the resolver table matches the approved layout exactly" {
    $table = Get-ToolPathTable
    foreach ($name in $ExpectedLayout.Keys) {
        if (-not $table.ContainsKey($name)) { throw "table lacks $name" }
        if ($table[$name] -ne $ExpectedLayout[$name]) { throw "$name maps to '$($table[$name])', expected '$($ExpectedLayout[$name])'" }
    }
    foreach ($name in $StateFiles) {
        if ($table[$name] -ne "state") { throw "$name should map to state, got '$($table[$name])'" }
    }
    foreach ($name in $table.Keys) {
        if (-not ($ExpectedLayout.Contains($name) -or $StateFiles -contains $name)) { throw "table has unexpected entry $name" }
    }
}

Check "Get-ToolPath resolves every tool file to an existing file" {
    foreach ($name in $ExpectedLayout.Keys) {
        $p = Get-ToolPath -ScriptDir $ScriptsRoot -Name $name
        if ((Norm $p) -ne (Norm (Get-ExpectedPath $ScriptsRoot $name))) { throw "$name -> $p" }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "$name -> $p does not exist" }
    }
}

Check "Get-ToolPath throws on an unknown name (no silent flat fallback)" {
    $threw = $false
    try { Get-ToolPath -ScriptDir $ScriptsRoot -Name "no_such_script.py" | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "expected a throw for an unknown name" }
}

Check "state folder is created on demand (fresh dist has none)" {
    $tmp = Join-Path $env:TEMP ("t99_state_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        if (Test-Path (Join-Path $tmp "state")) { throw "precondition: state already exists" }
        $p = Get-ToolPath -ScriptDir $tmp -Name "_hud_state.json"
        if ((Norm $p) -ne (Norm (Join-Path $tmp "state\_hud_state.json"))) { throw "unexpected path $p" }
        if (-not (Test-Path (Join-Path $tmp "state") -PathType Container)) { throw "Get-ToolPath did not create state\" }
        Remove-Item (Join-Path $tmp "state") -Recurse -Force
        $d = Get-ToolStateDir -ScriptDir $tmp
        if ((Norm $d) -ne (Norm (Join-Path $tmp "state"))) { throw "unexpected state dir $d" }
        if (-not (Test-Path $d -PathType Container)) { throw "Get-ToolStateDir did not create state\" }
        # a second call on an existing folder is a quiet no-op
        $d2 = Get-ToolStateDir -ScriptDir $tmp
        if ((Norm $d2) -ne (Norm $d)) { throw "second call returned $d2" }
        # non-state names never create anything
        Get-ToolPath -ScriptDir $tmp -Name "send_to_maya.ps1" | Out-Null
        if (Test-Path (Join-Path $tmp "maya")) { throw "a non-state lookup created a folder" }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- step paths
Check "every Get-*Steps path points at an existing script" {
    $steps = @()
    $steps += Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot
    $steps += Get-CaptureStepsForAxis -Axis "All" -Recording $false -ScriptDir $ScriptsRoot
    $steps += Get-CleanResetStep -ScriptDir $ScriptsRoot
    $steps += Get-StopCleanupSteps -ScriptDir $ScriptsRoot
    $n = 0
    foreach ($s in $steps) {
        foreach ($a in @($s.Arguments)) {
            if ("$a" -match '\.(ps1|py)$') {
                $n++
                if (-not (Test-Path -LiteralPath "$a" -PathType Leaf)) { throw "step argument does not exist: $a" }
            }
        }
    }
    if ($n -lt 20) { throw "expected at least 20 script arguments, found $n" }
}

# ---------------------------------------------------------------- source parsing
# For each PowerShell file, work out what its $ScriptDir means from its own
# assignment line, then resolve every literal path joined onto it.
function Get-PsBaseDir([string]$file) {
    $text = Get-Content -LiteralPath $file -Raw
    $here = Split-Path $file -Parent
    if ($text -match '(?m)^\$ScriptDir\s*=\s*Split-Path\s+\$PSScriptRoot\s+-Parent\s*$') { return (Split-Path $here -Parent) }
    if ($text -match '(?m)^\$ScriptDir\s*=\s*\$PSScriptRoot\s*$') { return $here }
    return $null
}

$PsFiles = @(
    (Join-Path $ScriptsRoot "rom_launcher.ps1"),
    (Join-Path $ScriptsRoot "rom_launcher_logic.ps1"),
    (Get-ExpectedPath $ScriptsRoot "maya_obs_capture.ps1"),
    (Get-ExpectedPath $ScriptsRoot "obs_control.ps1"),
    (Get-ExpectedPath $ScriptsRoot "obs_monitor.ps1"),
    (Get-ExpectedPath $ScriptsRoot "taskbar_control.ps1"),
    (Get-ExpectedPath $ScriptsRoot "send_to_maya.ps1")
)

Check "every literal path in the PowerShell scripts resolves" {
    $count = 0
    foreach ($f in $PsFiles) {
        if (-not (Test-Path -LiteralPath $f)) { throw "missing $f" }
        $here = Split-Path $f -Parent
        $text = Get-Content -LiteralPath $f -Raw
        # rom_launcher_logic.ps1 has no $ScriptDir of its own: callers pass
        # the scripts root, which is what every caller in this repo does.
        $base = if ((Split-Path $f -Leaf) -eq "rom_launcher_logic.ps1") { $ScriptsRoot } else { Get-PsBaseDir $f }
        foreach ($m in [regex]::Matches($text, 'Join-Path\s+\$ScriptDir\s+["'']([^"''$]+)["'']')) {
            $count++
            if (-not $base) { throw "$f joins onto `$ScriptDir but its `$ScriptDir assignment was not recognised" }
            $full = Join-Path $base $m.Groups[1].Value
            if (-not (Test-ReferencedPath $full)) { throw "$(Split-Path $f -Leaf): $($m.Groups[1].Value) -> $full does not resolve" }
        }
        foreach ($m in [regex]::Matches($text, 'Join-Path\s+\$PSScriptRoot\s+["'']([^"''$]+)["'']')) {
            $count++
            $full = Join-Path $here $m.Groups[1].Value
            if (-not (Test-ReferencedPath $full)) { throw "$(Split-Path $f -Leaf): $($m.Groups[1].Value) -> $full does not resolve" }
        }
        foreach ($m in [regex]::Matches($text, 'Join-Path\s+\(Split-Path\s+\$PSScriptRoot\s+-Parent\)\s+["'']([^"''$]+)["'']')) {
            $count++
            $full = Join-Path (Split-Path $here -Parent) $m.Groups[1].Value
            if (-not (Test-ReferencedPath $full)) { throw "$(Split-Path $f -Leaf): $($m.Groups[1].Value) -> $full does not resolve" }
        }
        # "$ScriptDir\name" string-interpolated paths
        foreach ($m in [regex]::Matches($text, '\$ScriptDir\\([A-Za-z0-9_.\\]+\.(txt|json|ps1|py))')) {
            $count++
            if (-not $base) { throw "$f uses `$ScriptDir but its assignment was not recognised" }
            $full = Join-Path $base $m.Groups[1].Value
            if (-not (Test-ReferencedPath $full)) { throw "$(Split-Path $f -Leaf): $($m.Groups[1].Value) -> $full does not resolve" }
        }
        # Get-ToolPath -Name "x" literals must be known names
        foreach ($m in [regex]::Matches($text, 'Get-ToolPath\s+-ScriptDir\s+\$ScriptDir\s+-Name\s+["'']([^"'']+)["'']')) {
            $count++
            $p = Get-ToolPath -ScriptDir $ScriptsRoot -Name $m.Groups[1].Value
            if (-not (Test-ReferencedPath $p)) { throw "$(Split-Path $f -Leaf): Get-ToolPath $($m.Groups[1].Value) -> $p does not resolve" }
        }
    }
    if ($count -lt 30) { throw "parsed only $count path literals -- the patterns no longer match the source?" }
}

Check "rom_launcher.ps1's live camera script names resolve through the resolver" {
    $text = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    $names = @([regex]::Matches($text, 'Send-CameraLiveScript\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -lt 2) { throw "expected the zoom and nudge script names" }
    foreach ($n in $names) {
        $p = Get-ToolPath -ScriptDir $ScriptsRoot -Name $n
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "$n -> $p missing" }
    }
}

Check "maya_obs_capture.ps1 writes every state file into scripts\state through the resolver" {
    $f = Get-ExpectedPath $ScriptsRoot "maya_obs_capture.ps1"
    $text = Get-Content -LiteralPath $f -Raw
    if ($text -match '\$ScriptDir\\_') { throw "a state file is still built from `$ScriptDir directly" }
    if ($text -notmatch '(?m)^\$StateDir\s*=\s*Get-ToolStateDir\s+-ScriptDir\s+\$ScriptDir\s*$') { throw "no `$StateDir = Get-ToolStateDir line" }
    if ($text -notmatch '(?m)^\.\s+\(Join-Path\s+\$ScriptDir\s+"rom_launcher_logic\.ps1"\)\s*$') { throw "does not dot-source the logic file from `$ScriptDir" }
    foreach ($n in $StateFiles) {
        if ($text -notmatch ('\$StateDir\\' + [regex]::Escape($n))) { throw "$n is not written under `$StateDir" }
    }
}

Check "rom_launcher_logic.ps1 is safe to dot-source into maya_obs_capture.ps1 (functions only, no clashes)" {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptsRoot "rom_launcher_logic.ps1"), [ref]$tok, [ref]$err)
    if ($err.Count) { throw "logic file has parse errors" }
    if ($ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock) { throw "logic file has a param/begin/process block" }
    $nonFn = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
    if ($nonFn.Count) { throw "logic file has top-level statements at lines $(($nonFn | ForEach-Object { $_.Extent.StartLineNumber }) -join ', ')" }
    $logicText = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher_logic.ps1") -Raw
    if ($logicText -match '\$(script|global):') { throw "logic file touches script/global scope variables" }
    $logicFns = @($ast.EndBlock.Statements | ForEach-Object { $_.Name })
    $oAst = [System.Management.Automation.Language.Parser]::ParseFile((Get-ExpectedPath $ScriptsRoot "maya_obs_capture.ps1"), [ref]$tok, [ref]$err)
    $oFns = @($oAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $clash = @($logicFns | Where-Object { $oFns -contains $_ })
    if ($clash.Count) { throw "function name clash: $($clash -join ', ')" }
}

Check "maya_obs_capture.ps1 resolves state, obs_config.txt and the panels file to the same places as the launcher" {
    $oBase = Get-PsBaseDir (Get-ExpectedPath $ScriptsRoot "maya_obs_capture.ps1")
    $sBase = Get-PsBaseDir (Join-Path $ScriptsRoot "rom_launcher.ps1")
    if (-not $oBase -or -not $sBase) { throw "could not read the `$ScriptDir assignments" }
    if ((Norm $oBase) -ne (Norm $sBase)) { throw "capture `$ScriptDir $oBase != launcher `$ScriptDir $sBase" }
    $oText = Get-Content -LiteralPath (Get-ExpectedPath $ScriptsRoot "maya_obs_capture.ps1") -Raw
    $sText = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    foreach ($lit in @('obs_config.txt', '..\d4_anim_sample\')) {
        $pat = 'Join-Path\s+\$ScriptDir\s+["'']' + [regex]::Escape($lit)
        if ($oText -notmatch $pat) { throw "capture script no longer joins $lit onto `$ScriptDir" }
        if ($sText -notmatch $pat) { throw "launcher no longer joins $lit onto `$ScriptDir" }
    }
    # state: both go through the same resolver on the same root
    $oState = Join-Path $oBase "state"
    if ((Norm $oState) -ne (Norm (Join-Path $ScriptsRoot "state"))) { throw "capture state dir $oState" }
}

Check "HUD state writer (capture) and reader (maya_restore_hud.py) agree on one path" {
    $writer = Norm (Join-Path (Join-Path $ScriptsRoot "state") "_hud_state.json")
    $py = Get-Content -LiteralPath (Get-ExpectedPath $ScriptsRoot "maya_restore_hud.py") -Raw
    $m = [regex]::Match($py, "STATE_PATH\s*=\s*os\.path\.join\(SCRIPT_DIR,\s*([^)]*)\)")
    if (-not $m.Success) { throw "STATE_PATH line not found" }
    $parts = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') })
    $reader = Join-Path $ScriptsRoot "maya"
    foreach ($p in $parts) { $reader = Join-Path $reader $p }
    if ((Norm $reader) -ne $writer) { throw "reader $reader != writer $writer" }
}

Check "every os.path.join(SCRIPT_DIR/SCRIPTS_DIR, ...) in the Python scripts resolves" {
    $count = 0
    foreach ($py in Get-ChildItem -LiteralPath (Join-Path $ScriptsRoot "maya") -Filter *.py -File) {
        $text = Get-Content -LiteralPath $py.FullName -Raw
        foreach ($m in [regex]::Matches($text, "os\.path\.join\((SCRIPT_DIR|SCRIPTS_DIR),\s*([^)]*)\)")) {
            $count++
            $parts = @($m.Groups[2].Value -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') })
            $full = $py.DirectoryName
            foreach ($p in $parts) { $full = Join-Path $full $p }
            $leafOk = Test-ReferencedPath $full
            $dirOk = Test-Path -LiteralPath $full -PathType Container
            if (-not ($leafOk -or $dirOk)) { throw "$($py.Name): $($m.Value) -> $full does not resolve" }
            if ($parts -contains 'd4_anim_sample' -and (Norm $full) -ne (Norm (Join-Path $RepoRoot "d4_anim_sample"))) {
                throw "$($py.Name): CACHE_DIR resolves to $full, not the repo's d4_anim_sample"
            }
        }
    }
    if ($count -lt 15) { throw "parsed only $count joins -- the pattern no longer matches?" }
}

Check "the legacy .bat files point at existing scripts" {
    foreach ($b in $LegacyBats) {
        $f = Join-Path $RepoRoot "legacy\$b"
        $text = Get-Content -LiteralPath $f -Raw
        $refs = @([regex]::Matches($text, '%~dp0([^"]+)') | ForEach-Object { $_.Groups[1].Value })
        if ($refs.Count -lt 2) { throw "${b}: no %~dp0 paths found" }
        foreach ($r in $refs) {
            $full = Join-Path (Join-Path $RepoRoot "legacy") $r
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "${b}: $r -> $full missing" }
        }
    }
}

# ---------------------------------------------------------------- dist build
Check "build_dist into a temp folder ships the category folders, never state\ or legacy\" {
    $dist = Join-Path $env:TEMP ("t99_dist_" + [guid]::NewGuid().ToString("N"))
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "build_dist.ps1") -DistDir $dist 2>&1
        if ($LASTEXITCODE -ne 0) { throw "build_dist failed: $($out -join ' | ')" }
        $ds = Join-Path $dist "scripts"
        foreach ($name in $ExpectedLayout.Keys) {
            $p = Get-ExpectedPath $ds $name
            $should = ($name -ne "maya_debug_inspect.py")
            if ($should -and -not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "dist lacks $p" }
            if ((-not $should) -and (Test-Path -LiteralPath $p)) { throw "dist ships the scratch file $name" }
        }
        if (Test-Path (Join-Path $ds "state")) { throw "dist ships scripts\state" }
        if (Test-Path (Join-Path $dist "legacy")) { throw "dist ships legacy\" }
        foreach ($b in $LegacyBats) { if (Test-Path (Join-Path $dist $b)) { throw "dist ships $b" } }
        if (-not (Test-Path (Join-Path $ds "guide_images") -PathType Container)) { throw "dist lacks guide_images" }
        $cfg = Join-Path $ds "obs_config.txt"
        if (-not (Test-Path $cfg)) { throw "dist lacks the obs_config.txt placeholder" }
        if ((Get-Content $cfg -Raw) -notmatch 'password:\s*REPLACE_ME') { throw "dist obs_config.txt is not the placeholder" }
        $underscore = @(Get-ChildItem -LiteralPath $dist -Recurse -File -Force | Where-Object { $_.Name -like "_*" })
        if ($underscore.Count) { throw "dist ships state-like files: $(($underscore | ForEach-Object Name) -join ', ')" }
        if (Test-Path (Join-Path $dist "d4_anim_sample")) { throw "dist ships d4_anim_sample" }
        if (Test-Path (Join-Path $dist "tests")) { throw "dist ships tests" }
    } finally {
        Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ""
foreach ($f in $failures) { Write-Output "FAIL: $f" }
Write-Output "$passed passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

# Persistent test suite for the pre/post recording scripts (T97): the
# step builder, the hook-state classifier, Initialize-HookFiles,
# Open-HookFolder (stubbed -- never starts Explorer), the folder button's
# missing-template path, the context-file writer and the Stop/abort flag
# logic. Dot-sources ONLY rom_launcher_logic.ps1 -- never builds a WPF
# window, never launches Maya/OBS, never touches port 7001. Every file it
# writes goes into a temp folder.
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_prepost_hooks.ps1
# Exits 0 if all checks pass, 1 otherwise.

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ScriptsRoot = Join-Path $RepoRoot "scripts"
. (Join-Path $ScriptsRoot "rom_launcher_logic.ps1")

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
function StepsJson($steps) { return (@($steps) | ForEach-Object { StepText $_ }) -join "`n" }
function IsObsStep($s) { return ((@($s.Arguments) -join ' ') -like "*maya_obs_capture.ps1*") }
function IsPingStep($s) { return ($s.FilePath -eq "ping") }
function IsTaskbarShow($s) { $a = @($s.Arguments) -join ' '; return ($a -like "*taskbar_control.ps1*" -and $a -like "*-Action show*") }
function HookKindOf($s) { if ($s.PSObject.Properties["HookKind"]) { return $s.HookKind } return $null }

# A throwaway install tree: <tmp>\scripts\hooks\templates\*.py copied from
# the real templates, so Initialize-HookFiles works on a copy, never on the
# repo's own (dev) user_hooks folder.
function New-FakeInstall {
    $root = Join-Path $env:TEMP ("t97_hooks_" + [guid]::NewGuid().ToString("N"))
    $sd = Join-Path $root "scripts"
    $tpl = Join-Path $sd "hooks\templates"
    New-Item -ItemType Directory -Path $tpl -Force | Out-Null
    foreach ($n in @("d4_rom_pre_record.py", "d4_rom_post_record.py")) {
        Copy-Item -LiteralPath (Join-Path $ScriptsRoot "hooks\templates\$n") -Destination $tpl
    }
    Copy-Item -LiteralPath (Join-Path $ScriptsRoot "hooks\maya_run_hook.py") -Destination (Join-Path $sd "hooks")
    return [PSCustomObject]@{ Root = $root; ScriptDir = $sd; Templates = $tpl; UserDir = (Join-Path $root "user_hooks") }
}

function Write-Ascii([string]$path, [string]$text) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.ASCIIEncoding))
}

$PreUser = Join-Path $env:TEMP "t97_fake_user\d4_rom_pre_record.py"
$PostUser = Join-Path $env:TEMP "t97_fake_user\d4_rom_post_record.py"
$CtxPath = Join-Path $env:TEMP "t97_fake_user\_hook_context.json"

# ---------------------------------------------------------------- baseline (GREEN today)
Check "baseline: today's recording leg is taskbar hide, panels, keys, ping, obs capture, taskbar show" {
    $s = @(Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot)
    if ($s.Count -ne 6) { throw "expected 6 steps, got $($s.Count)" }
    if (-not (IsPingStep $s[3])) { throw "step 3 is not the ping" }
    if (-not (IsObsStep $s[4])) { throw "step 4 is not maya_obs_capture.ps1" }
    if (-not (IsTaskbarShow $s[5])) { throw "step 5 is not taskbar show" }
}

Check "baseline: the runner's PRE abort text matches the launcher's CAPTURE_ABORT regex, POST's does not" {
    $preLine = "Maya response: # Error: RuntimeError: file <string> line 1: CAPTURE_ABORT: pre-record script failed -- ValueError: x (line 2)"
    $postLine = "Maya response: # Error: RuntimeError: file <string> line 1: D4_HOOK_ERROR post: KeyError: 'k' (line 1)"
    if ($preLine -notmatch "CAPTURE_ABORT:\s*(.*)") { throw "PRE line not matched" }
    if ($Matches[1] -notlike "pre-record script failed -- ValueError: x*") { throw "reason was '$($Matches[1])'" }
    if ($postLine -match "CAPTURE_ABORT:\s*(.*)") { throw "POST line must not abort" }
    $launcher = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    if ($launcher -notmatch [regex]::Escape('-match "CAPTURE_ABORT:\s*(.*)"')) { throw "launcher abort regex changed -- update this test" }
}

# ---------------------------------------------------------------- resolver (RED until Phase B)
Check "resolver knows maya_run_hook.py (hooks) and _hook_context.json (state)" {
    $r = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_run_hook.py"
    if ((Norm $r) -ne (Norm (Join-Path $ScriptsRoot "hooks\maya_run_hook.py"))) { throw "runner -> $r" }
    if (-not (Test-Path -LiteralPath $r -PathType Leaf)) { throw "runner missing at $r" }
    $c = Get-ToolPath -ScriptDir $ScriptsRoot -Name "_hook_context.json"
    if ((Norm $c) -ne (Norm (Join-Path $ScriptsRoot "state\_hook_context.json"))) { throw "context -> $c" }
}

Check "hook locations: templates in scripts\hooks\templates, user files in <install root>\user_hooks" {
    $f = New-FakeInstall
    try {
        $p = Get-HookPaths -ScriptDir $f.ScriptDir
        if ((Norm $p.UserDir) -ne (Norm $f.UserDir)) { throw "UserDir $($p.UserDir)" }
        if ((Norm $p.TemplateDir) -ne (Norm $f.Templates)) { throw "TemplateDir $($p.TemplateDir)" }
        if ((Norm $p.Pre) -ne (Norm (Join-Path $f.UserDir "d4_rom_pre_record.py"))) { throw "Pre $($p.Pre)" }
        if ((Norm $p.Post) -ne (Norm (Join-Path $f.UserDir "d4_rom_post_record.py"))) { throw "Post $($p.Post)" }
        if (Test-Path -LiteralPath $f.UserDir) { throw "Get-HookPaths must not create anything" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- classifier
Check "Get-HookState: missing / empty (blank+comment only) / code" {
    $d = Join-Path $env:TEMP ("t97_state_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $d | Out-Null
    try {
        if ((Get-HookState -Path (Join-Path $d "nope.py")) -ne "missing") { throw "missing file" }
        Write-Ascii (Join-Path $d "e1.py") ""
        if ((Get-HookState -Path (Join-Path $d "e1.py")) -ne "empty") { throw "zero-byte file" }
        Write-Ascii (Join-Path $d "e2.py") "# a`r`n   # indented comment`r`n`r`n   `t`r`n"
        if ((Get-HookState -Path (Join-Path $d "e2.py")) -ne "empty") { throw "comment-only file" }
        Write-Ascii (Join-Path $d "c1.py") "# header`nprint('x')`n"
        if ((Get-HookState -Path (Join-Path $d "c1.py")) -ne "code") { throw "code file" }
        Write-Ascii (Join-Path $d "c2.py") "    x = 1  # indented code`n"
        if ((Get-HookState -Path (Join-Path $d "c2.py")) -ne "code") { throw "indented code" }
        foreach ($n in @("d4_rom_pre_record.py", "d4_rom_post_record.py")) {
            if ((Get-HookState -Path (Join-Path $ScriptsRoot "hooks\templates\$n")) -ne "empty") { throw "shipped template $n is not 'empty'" }
        }
    } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Get-HookIndicator: gray both empty, green any code, amber any missing (missing wins)" {
    $cases = @(
        @("empty", "empty", "gray"), @("code", "empty", "green"), @("empty", "code", "green"),
        @("code", "code", "green"), @("missing", "empty", "amber"), @("code", "missing", "amber"),
        @("missing", "missing", "amber")
    )
    foreach ($c in $cases) {
        $i = Get-HookIndicator -PreState $c[0] -PostState $c[1]
        if ($i.Color -ne $c[2]) { throw "pre=$($c[0]) post=$($c[1]) -> $($i.Color), expected $($c[2])" }
        if (-not $i.Text) { throw "no tooltip text for pre=$($c[0]) post=$($c[1])" }
        if ($i.Text -notmatch '(?i)pre' -or $i.Text -notmatch '(?i)post') { throw "tooltip must name both scripts: $($i.Text)" }
    }
    $g = Get-HookIndicator -PreState "empty" -PostState "empty"
    if ($g.Text -notmatch '(?i)nothing runs') { throw "gray tooltip should say nothing runs: $($g.Text)" }
}

Check "Get-ActiveHookPaths: only files with code become hook paths; missing gives one log line each" {
    $f = New-FakeInstall
    try {
        $a = Get-ActiveHookPaths -ScriptDir $f.ScriptDir
        if ($a.Pre -or $a.Post) { throw "missing files must not become hooks" }
        if (@($a.Log).Count -ne 2) { throw "expected 2 log lines for 2 missing files, got $(@($a.Log).Count)" }
        Initialize-HookFiles -ScriptDir $f.ScriptDir | Out-Null
        $a = Get-ActiveHookPaths -ScriptDir $f.ScriptDir
        if ($a.Pre -or $a.Post) { throw "template copies (comment-only) must not become hooks" }
        if (@($a.Log).Count -ne 0) { throw "comment-only files must not log: $($a.Log -join ' | ')" }
        Write-Ascii (Join-Path $f.UserDir "d4_rom_post_record.py") "print('post')`n"
        $a = Get-ActiveHookPaths -ScriptDir $f.ScriptDir
        if ($a.Pre) { throw "pre is still comment-only" }
        if ((Norm $a.Post) -ne (Norm (Join-Path $f.UserDir "d4_rom_post_record.py"))) { throw "post path $($a.Post)" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- step builder
Check "no hooks => step lists byte-identical to today's, for every axis and mode" {
    foreach ($axis in @("FrontBack", "LeftRight", "All")) {
        foreach ($rec in @($true, $false)) {
            $today = StepsJson (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -StartFrame 10 -EndFrame 20)
            $none = StepsJson (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -StartFrame 10 -EndFrame 20 -PreHookPath $null -PostHookPath $null -HookContextPath $CtxPath)
            $blank = StepsJson (Get-CaptureStepsForAxis -Axis $axis -Recording $rec -ScriptDir $ScriptsRoot -StartFrame 10 -EndFrame 20 -PreHookPath "" -PostHookPath "" -HookContextPath $CtxPath)
            if ($none -ne $today) { throw "$axis rec=$rec differs with null hooks" }
            if ($blank -ne $today) { throw "$axis rec=$rec differs with empty hooks" }
        }
    }
}

Check "with both hooks: PRE right before the obs capture step, POST right after it, per leg; All = twice" {
    foreach ($axis in @("FrontBack", "LeftRight", "All")) {
        $s = @(Get-CaptureStepsForAxis -Axis $axis -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
        $legs = if ($axis -eq "All") { 2 } else { 1 }
        if ($s.Count -ne (8 * $legs)) { throw "$axis expected $(8 * $legs) steps, got $($s.Count)" }
        $obsIdx = @(); for ($i = 0; $i -lt $s.Count; $i++) { if (IsObsStep $s[$i]) { $obsIdx += $i } }
        if ($obsIdx.Count -ne $legs) { throw "$axis expected $legs obs steps" }
        $leg = 0
        foreach ($o in $obsIdx) {
            if ((HookKindOf $s[$o - 1]) -ne "pre") { throw "$axis leg $leg step before obs is not PRE" }
            if (-not (IsPingStep $s[$o - 2])) { throw "$axis leg $leg PRE is not right after the ping" }
            if ((HookKindOf $s[$o + 1]) -ne "post") { throw "$axis leg $leg step after obs is not POST" }
            if (-not (IsTaskbarShow $s[$o + 2])) { throw "$axis leg $leg POST is not right before taskbar show" }
            foreach ($h in @($s[$o - 1], $s[$o + 1])) {
                if ($h.LegIndex -ne $leg) { throw "$axis hook LegIndex $($h.LegIndex), expected $leg" }
            }
            $leg++
        }
        $pre = @($s | Where-Object { (HookKindOf $_) -eq "pre" })
        $post = @($s | Where-Object { (HookKindOf $_) -eq "post" })
        if ($pre.Count -ne $legs -or $post.Count -ne $legs) { throw "$axis hook count pre=$($pre.Count) post=$($post.Count)" }
    }
}

Check "hook step shape: send_to_maya -Code payload, -TimeoutMs 300000, through the resolver" {
    $s = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
    $sendToMaya = Get-ToolPath -ScriptDir $ScriptsRoot -Name "send_to_maya.ps1"
    $runner = Get-ToolPath -ScriptDir $ScriptsRoot -Name "maya_run_hook.py"
    $legAxes = @("FrontBack", "LeftRight")
    foreach ($h in @($s | Where-Object { HookKindOf $_ })) {
        $a = @($h.Arguments)
        if ($h.FilePath -ne "powershell") { throw "FilePath $($h.FilePath)" }
        if ($a[0] -ne "-ExecutionPolicy" -or $a[1] -ne "Bypass" -or $a[2] -ne "-File") { throw "args start $($a[0..2] -join ' ')" }
        if ((Norm $a[3]) -ne (Norm $sendToMaya)) { throw "not send_to_maya: $($a[3])" }
        $ci = [array]::IndexOf($a, "-Code"); if ($ci -lt 0) { throw "no -Code" }
        $ti = [array]::IndexOf($a, "-TimeoutMs"); if ($ti -lt 0 -or $a[$ti + 1] -ne "300000") { throw "no -TimeoutMs 300000" }
        $code = $a[$ci + 1]
        if ($code -match '[\r\n"]') { throw "payload must be one line with no double quotes" }
        if ($code -notlike "*$runner*") { throw "payload does not name the runner" }
        $user = if ($h.HookKind -eq "pre") { $PreUser } else { $PostUser }
        if ($code -notlike "*$user*") { throw "payload does not name the user file" }
        if ($code -notlike "*$CtxPath*") { throw "payload does not name the context file" }
        if ($code -notmatch "'D4_HOOK_KIND':\s*'$($h.HookKind)'") { throw "payload kind: $code" }
        if ($code -notmatch "'D4_HOOK_LEG_INDEX':\s*$($h.LegIndex)\b") { throw "payload leg index: $code" }
        if ($code -notmatch "'D4_HOOK_LEG_AXIS':\s*'$($legAxes[$h.LegIndex])'") { throw "payload leg axis: $code" }
    }
}

Check "once-guard: every hook step has a unique run id in its payload (per kind, per leg, per build)" {
    $a1 = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath | Where-Object { HookKindOf $_ })
    $a2 = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath | Where-Object { HookKindOf $_ })
    if ($a1.Count -ne 4) { throw "expected 4 hook steps for All, got $($a1.Count)" }
    $ids = @()
    foreach ($h in ($a1 + $a2)) {
        if (-not $h.PSObject.Properties["RunId"] -or -not $h.RunId) { throw "hook step has no RunId" }
        if ($h.RunId -notmatch '^[A-Za-z0-9_-]+$') { throw "RunId '$($h.RunId)' has characters unsafe for the payload" }
        $a = @($h.Arguments); $code = $a[[array]::IndexOf($a, "-Code") + 1]
        if ($code -notmatch ("'D4_HOOK_RUN_ID':\s*'" + [regex]::Escape($h.RunId) + "'")) { throw "payload lacks its RunId: $code" }
        $ids += $h.RunId
    }
    $unique = @($ids | Sort-Object -Unique)
    if ($unique.Count -ne $ids.Count) { throw "run ids are not unique: $($ids -join ', ')" }
}

Check "once-guard: the Stop cleanup reuses the pending POST step with its own run id" {
    $s = @(Get-CaptureStepsForAxis -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
    $post = @($s | Where-Object { (HookKindOf $_) -eq "post" })[0]
    $c = @(Get-StopCleanupSteps -ScriptDir $ScriptsRoot -PostHookStep $post)
    if ($c[-1].RunId -ne $post.RunId) { throw "cleanup POST has a different run id" }
}

Check "only PRE or only POST: the other adds no step" {
    $s = @(Get-CaptureStepsForAxis -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath "" -HookContextPath $CtxPath)
    if ($s.Count -ne 7) { throw "pre-only expected 7, got $($s.Count)" }
    if (@($s | Where-Object { (HookKindOf $_) -eq "post" }).Count) { throw "pre-only has a POST step" }
    $s = @(Get-CaptureStepsForAxis -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $null -PostHookPath $PostUser -HookContextPath $CtxPath)
    if ($s.Count -ne 7) { throw "post-only expected 7, got $($s.Count)" }
    if (-not (IsObsStep $s[4]) -or (HookKindOf $s[5]) -ne "post") { throw "post-only POST not right after obs" }
}

Check "Preview (Recording false) never runs hooks" {
    $today = StepsJson (Get-CaptureStepsForAxis -Axis "All" -Recording $false -ScriptDir $ScriptsRoot)
    $with = StepsJson (Get-CaptureStepsForAxis -Axis "All" -Recording $false -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
    if ($with -ne $today) { throw "preview steps changed with hooks set" }
}

Check "M1: an apostrophe in a hook path is escaped, not refused; a double quote / line break is still refused" {
    $s = @(Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath "C:\o'brien\'lead\d4_rom_pre_record.py" -HookContextPath $CtxPath)
    $h = @($s | Where-Object { (HookKindOf $_) -eq "pre" })[0]
    $a = @($h.Arguments); $code = $a[[array]::IndexOf($a, "-Code") + 1]
    if ($code -match '[\r\n"]') { throw "payload must stay one line with no double quotes" }
    foreach ($bad in @("C:\a`"b\x.py", "C:\a`nb\x.py")) {
        $msg = $null
        try { Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $bad -HookContextPath $CtxPath | Out-Null } catch { $msg = $_.Exception.Message }
        if (-not $msg) { throw "expected a refusal for $bad" }
    }
}

Check "M1: apostrophes in the install root and user folder: the payload really runs under python (fake maya)" {
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { throw "python not found on PATH" }
    $root = Join-Path $env:TEMP ("t97_o'brien_" + [guid]::NewGuid().ToString("N"))
    $sd = Join-Path $root "'lead's scripts"
    try {
        New-Item -ItemType Directory -Path (Join-Path $sd "hooks\templates") -Force | Out-Null
        foreach ($n in @("d4_rom_pre_record.py", "d4_rom_post_record.py")) { Copy-Item -LiteralPath (Join-Path $ScriptsRoot "hooks\templates\$n") -Destination (Join-Path $sd "hooks\templates") }
        Copy-Item -LiteralPath (Join-Path $ScriptsRoot "hooks\maya_run_hook.py") -Destination (Join-Path $sd "hooks")
        Initialize-HookFiles -ScriptDir $sd | Out-Null
        $marker = Join-Path $root "ran.txt"
        $user = Join-Path $root "user_hooks\d4_rom_pre_record.py"
        Write-Ascii $user ("open(" + "'" + $marker.Replace("\", "\\").Replace("'", "\'") + "'" + ", 'w').write(D4_CTX['kind'] + ':' + D4_CTX['scripts_dir'])`n")
        $r = Get-CaptureStepsWithHooks -Axis "FrontBack" -ScriptDir $sd -StartFrame $null -EndFrame $null -ToolVersion "9.9.9"
        if ($r.Error) { throw "build error: $($r.Error)" }
        $h = @($r.Steps | Where-Object { (HookKindOf $_) -eq "pre" })[0]
        if (-not $h) { throw "no PRE step built" }
        $a = @($h.Arguments); $code = $a[[array]::IndexOf($a, "-Code") + 1]
        if ($code -match '[\r\n"]') { throw "payload must stay one line with no double quotes" }
        $driver = Join-Path $env:TEMP ("t97_driver_" + [guid]::NewGuid().ToString("N") + ".py")
        Write-Ascii $driver ("import sys, types`nm = types.ModuleType('maya'); c = types.ModuleType('maya.cmds'); m.cmds = c`nsys.modules['maya'] = m; sys.modules['maya.cmds'] = c`n" + $code + "`n")
        $out = & $py.Source -I $driver 2>&1
        Remove-Item -LiteralPath $driver -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { throw "python failed: $($out -join ' | ')" }
        $got = Get-Content -LiteralPath $marker -Raw
        if ((Norm ($got.Substring(4))) -ne (Norm $sd) -or -not $got.StartsWith("pre:")) { throw "marker '$got'" }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "M1b: Get-CaptureStepsWithHooks falls back to NO hook steps + a log line + Error when building them fails" {
    $f = New-FakeInstall
    try {
        Initialize-HookFiles -ScriptDir $f.ScriptDir | Out-Null
        Write-Ascii (Join-Path $f.UserDir "d4_rom_pre_record.py") "print('x')`n"
        # a FOLDER where the context file goes makes Write-HookContext throw
        New-Item -ItemType Directory -Path (Join-Path $f.ScriptDir "state\_hook_context.json") -Force | Out-Null
        $r = Get-CaptureStepsWithHooks -Axis "All" -ScriptDir $f.ScriptDir -StartFrame 1 -EndFrame 5 -ToolVersion "1.1.0"
        if (-not $r.Error) { throw "no Error reported" }
        if (@($r.Steps | Where-Object { HookKindOf $_ }).Count) { throw "hook steps were still added" }
        $plain = StepsJson (Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $f.ScriptDir -StartFrame 1 -EndFrame 5)
        if ((StepsJson $r.Steps) -ne $plain) { throw "fallback steps differ from the plain recording steps" }
        if (-not (@($r.Log) | Where-Object { $_ -match '(?i)pre-post recording' -and $_ -match '(?i)not' })) { throw "no log line naming the problem: $(@($r.Log) -join ' | ')" }
        # and the happy path returns hook steps, no Error
        Remove-Item -LiteralPath (Join-Path $f.ScriptDir "state\_hook_context.json") -Recurse -Force
        $r = Get-CaptureStepsWithHooks -Axis "All" -ScriptDir $f.ScriptDir -StartFrame 1 -EndFrame 5 -ToolVersion "1.1.0"
        if ($r.Error) { throw "unexpected Error $($r.Error)" }
        if (@($r.Steps | Where-Object { (HookKindOf $_) -eq "pre" }).Count -ne 2) { throw "expected 2 PRE steps" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "M1b: the launcher uses Get-CaptureStepsWithHooks and keeps the dot amber on a build error" {
    $text = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    if ($text -notmatch 'Get-CaptureStepsWithHooks') { throw "Get-CaptureClickResult does not call Get-CaptureStepsWithHooks" }
    if ($text -notmatch '\$script:hookBuildError\s*=') { throw "no `$script:hookBuildError state" }
    $fn = [regex]::Match($text, '(?s)function Update-HookStatusIndicator \{.*?\n\}')
    if ($fn.Value -notmatch 'hookBuildError') { throw "Update-HookStatusIndicator ignores the build error" }
}

Check "M16: a bad run id is refused; INFO: a bad LegAxis is refused" {
    $ok = @{ RunnerPath = "C:\r.py"; Kind = "pre"; UserPath = "C:\u.py"; ContextPath = "C:\c.json"; LegIndex = 0; LegAxis = "FrontBack"; RunId = "pre-0-abc" }
    Get-HookStepCode @ok | Out-Null
    foreach ($bad in @("bad'id", "bad id", "", "x)y")) {
        $b = $ok.Clone(); $b.RunId = $bad; $threw = $false
        try { Get-HookStepCode @b | Out-Null } catch { $threw = $true }
        if (-not $threw) { throw "run id '$bad' accepted" }
    }
    foreach ($bad in @("Sideways", "Front'Back", "All")) {
        $b = $ok.Clone(); $b.LegAxis = $bad; $threw = $false
        try { Get-HookStepCode @b | Out-Null } catch { $threw = $true }
        if (-not $threw) { throw "LegAxis '$bad' accepted" }
    }
}

Check "L1: folder button reports Initialize-HookFiles errors as init_failed (nothing opened)" {
    $f = New-FakeInstall
    $lock = $null
    try {
        $script:openedFolders = @(); $script:openShouldFail = $false
        # an exclusively locked template makes the copy fail -> Errors
        $lock = [IO.File]::Open((Join-Path $f.Templates "d4_rom_post_record.py"), 'Open', 'Read', 'None')
        $r = Invoke-HookFolderButton -ScriptDir $f.ScriptDir
        if ($r.Status -ne "init_failed") { throw "status $($r.Status)" }
        if ($r.Message -notmatch 'd4_rom_post_record\.py') { throw "message does not name the file: $($r.Message)" }
        if ($script:openedFolders.Count -ne 0) { throw "a folder was opened" }
    } finally {
        if ($lock) { $lock.Dispose() }
        Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "L1/L4: launcher shows init_failed via the notice and disables the folder button during a run" {
    $text = Get-Content -LiteralPath (Join-Path $ScriptsRoot "rom_launcher.ps1") -Raw
    if ($text -notmatch '"init_failed"') { throw "click handler does not handle init_failed" }
    $fn = [regex]::Match($text, '(?s)function Set-ButtonsEnabled.*?\n\}')
    if (-not $fn.Success) { throw "Set-ButtonsEnabled not found" }
    if ($fn.Value -notmatch 'foreach \(\$b in @\([^)]*\$hookFolderButton') { throw "Set-ButtonsEnabled does not include the folder button" }
}

Check "the hook -Code payload survives Start-NextStep's quoting into a real powershell -File child" {
    $tmp = Join-Path $env:TEMP ("t97_quote_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $echo = Join-Path $tmp "echo.ps1"
        $outFile = Join-Path $tmp "code.txt"
        Write-Ascii $echo ("param([string]`$Code, [int]`$TimeoutMs)`r`n[IO.File]::WriteAllText('" + $outFile + "', `$Code + '|' + `$TimeoutMs, (New-Object System.Text.ASCIIEncoding))`r`n")
        $s = @(Get-CaptureSteps -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -HookContextPath $CtxPath)
        $h = @($s | Where-Object { (HookKindOf $_) -eq "pre" })[0]
        $a = @($h.Arguments); $a[3] = $echo
        $code = $a[[array]::IndexOf($a, "-Code") + 1]
        # identical to rom_launcher.ps1 Start-NextStep's argument quoting
        $quoted = $a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell"; $psi.Arguments = ($quoted -join " "); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit(20000) | Out-Null
        $got = [IO.File]::ReadAllText($outFile)
        if ($got -ne ($code + "|300000")) { throw "child got '$got'" }
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "the hook payload really runs the runner + user file under plain python with a fake maya (offline)" {
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { throw "python not found on PATH" }
    $f = New-FakeInstall
    try {
        New-Item -ItemType Directory -Path $f.UserDir -Force | Out-Null
        $marker = Join-Path $f.Root "ran.txt"
        $user = Join-Path $f.UserDir "d4_rom_pre_record.py"
        Write-Ascii $user ("from maya import cmds`nopen(r'" + $marker + "', 'w').write(D4_CTX['kind'] + ':' + str(D4_CTX['leg_index']) + ':' + D4_CTX['axis'])`n")
        $ctx = Write-HookContext -ScriptDir $f.ScriptDir -Axis "All" -StartFrame $null -EndFrame $null -ToolVersion "9.9.9"
        $s = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $f.ScriptDir -PreHookPath $user -HookContextPath $ctx)
        $h = @($s | Where-Object { (HookKindOf $_) -eq "pre" })[1]
        $a = @($h.Arguments); $code = $a[[array]::IndexOf($a, "-Code") + 1]
        $driver = Join-Path $f.Root "driver.py"
        Write-Ascii $driver ("import sys, types`nm = types.ModuleType('maya'); c = types.ModuleType('maya.cmds'); m.cmds = c`nsys.modules['maya'] = m; sys.modules['maya.cmds'] = c`n" + $code + "`n")
        $out = & $py.Source -I $driver 2>&1
        if ($LASTEXITCODE -ne 0) { throw "python failed: $($out -join ' | ')" }
        if ((Get-Content -LiteralPath $marker -Raw) -ne "pre:1:All") { throw "marker '$(Get-Content -LiteralPath $marker -Raw)'" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- PRE/POST flag + Stop cleanup
Check "Get-StopCleanupSteps default is unchanged; the POST step is appended last only when given" {
    $today = StepsJson (Get-StopCleanupSteps -ScriptDir $ScriptsRoot)
    $none = StepsJson (Get-StopCleanupSteps -ScriptDir $ScriptsRoot -PostHookStep $null)
    if ($none -ne $today) { throw "null PostHookStep changed the cleanup list" }
    $s = @(Get-CaptureStepsForAxis -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
    $post = @($s | Where-Object { (HookKindOf $_) -eq "post" })[0]
    $c = @(Get-StopCleanupSteps -ScriptDir $ScriptsRoot -PostHookStep $post)
    $base = @(Get-StopCleanupSteps -ScriptDir $ScriptsRoot)
    if ($c.Count -ne $base.Count + 1) { throw "expected $($base.Count + 1) steps, got $($c.Count)" }
    if ((HookKindOf $c[-1]) -ne "post") { throw "last cleanup step is not POST" }
    if ((StepText $c[-1]) -ne (StepText $post)) { throw "appended POST differs from the leg's POST step" }
}

Check "Update-PendingPostHook: PRE start arms its own leg's POST, POST start disarms, other steps keep it" {
    $s = @(Get-CaptureStepsForAxis -Axis "All" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath $PostUser -HookContextPath $CtxPath)
    $pending = $null
    $seen = @()
    for ($i = 0; $i -lt $s.Count; $i++) {
        $pending = Update-PendingPostHook -Steps $s -StartedIndex $i -Pending $pending
        $k = HookKindOf $s[$i]
        if ($k -eq "pre") {
            if (-not $pending -or (HookKindOf $pending) -ne "post" -or $pending.LegIndex -ne $s[$i].LegIndex) { throw "PRE at $i did not arm its own leg's POST" }
            $seen += $i
        } elseif ($k -eq "post") {
            if ($pending) { throw "POST at $i did not disarm" }
        } elseif (IsObsStep $s[$i]) {
            if (-not $pending) { throw "obs step at $i lost the pending POST (Stop during recording must run POST)" }
        }
    }
    if ($seen.Count -ne 2) { throw "expected 2 PRE starts" }
    # before any PRE ran (e.g. Stop during panels/keys) nothing is pending
    if (Update-PendingPostHook -Steps $s -StartedIndex 0 -Pending $null) { throw "pending before PRE" }
}

Check "PRE with code but POST empty: PRE start arms nothing" {
    $s = @(Get-CaptureStepsForAxis -Axis "FrontBack" -Recording $true -ScriptDir $ScriptsRoot -PreHookPath $PreUser -PostHookPath "" -HookContextPath $CtxPath)
    $i = [array]::IndexOf(@($s | ForEach-Object { HookKindOf $_ }), "pre")
    if ($i -lt 0) { throw "no PRE step" }
    if (Update-PendingPostHook -Steps $s -StartedIndex $i -Pending $null) { throw "armed a POST that does not exist" }
}

# ---------------------------------------------------------------- Initialize-HookFiles
Check "Initialize-HookFiles creates user_hooks + both files from the templates (byte-identical)" {
    $f = New-FakeInstall
    try {
        $r = Initialize-HookFiles -ScriptDir $f.ScriptDir
        if (-not (Test-Path -LiteralPath $f.UserDir -PathType Container)) { throw "user_hooks not created" }
        foreach ($n in @("d4_rom_pre_record.py", "d4_rom_post_record.py")) {
            $u = Join-Path $f.UserDir $n
            if (-not (Test-Path -LiteralPath $u)) { throw "$n not created" }
            $a = (Get-FileHash -LiteralPath $u).Hash; $b = (Get-FileHash -LiteralPath (Join-Path $f.Templates $n)).Hash
            if ($a -ne $b) { throw "$n is not a byte copy of the template" }
        }
        if (@($r.Created).Count -ne 2) { throw "Created should list 2 files, got $(@($r.Created).Count)" }
        if (@($r.MissingTemplates).Count -ne 0) { throw "MissingTemplates should be empty" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Initialize-HookFiles NEVER overwrites an existing (sentinel-edited) user file" {
    $f = New-FakeInstall
    try {
        Initialize-HookFiles -ScriptDir $f.ScriptDir | Out-Null
        $pre = Join-Path $f.UserDir "d4_rom_pre_record.py"
        Write-Ascii $pre "# T97_SENTINEL_DO_NOT_OVERWRITE`nprint('mine')`n"
        $before = (Get-FileHash -LiteralPath $pre).Hash
        $t0 = (Get-Item -LiteralPath $pre).LastWriteTimeUtc
        # a changed template (a newer tool version) must still not replace it
        Add-Content -LiteralPath (Join-Path $f.Templates "d4_rom_pre_record.py") -Value "# newer template line" -Encoding Ascii
        $r = Initialize-HookFiles -ScriptDir $f.ScriptDir
        if ((Get-FileHash -LiteralPath $pre).Hash -ne $before) { throw "user file was overwritten" }
        if ((Get-Item -LiteralPath $pre).LastWriteTimeUtc -ne $t0) { throw "user file was touched" }
        if (@($r.Created).Count -ne 0) { throw "second run created $(@($r.Created) -join ', ')" }
        # a deleted post file is recreated, the pre file still untouched
        Remove-Item -LiteralPath (Join-Path $f.UserDir "d4_rom_post_record.py")
        $r = Initialize-HookFiles -ScriptDir $f.ScriptDir
        if (@($r.Created).Count -ne 1) { throw "expected the post file recreated" }
        if ((Get-FileHash -LiteralPath $pre).Hash -ne $before) { throw "user file was overwritten on the 3rd run" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Initialize-HookFiles with a missing template: reports it, creates nothing for it, does not throw" {
    $f = New-FakeInstall
    try {
        Remove-Item -LiteralPath (Join-Path $f.Templates "d4_rom_post_record.py")
        $r = Initialize-HookFiles -ScriptDir $f.ScriptDir
        if (@($r.MissingTemplates).Count -ne 1) { throw "expected 1 missing template" }
        if ((Norm @($r.MissingTemplates)[0]) -ne (Norm (Join-Path $f.Templates "d4_rom_post_record.py"))) { throw "missing template path $(@($r.MissingTemplates)[0])" }
        if (Test-Path -LiteralPath (Join-Path $f.UserDir "d4_rom_post_record.py")) { throw "created a post file without a template" }
        if (-not (Test-Path -LiteralPath (Join-Path $f.UserDir "d4_rom_pre_record.py"))) { throw "the pre file should still be created" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- folder button (Explorer stubbed)
$script:openedFolders = @()
$script:openShouldFail = $false
function Open-HookFolder {
    # test stub replacing the logic file's real Open-HookFolder (Explorer)
    param([Parameter(Mandatory=$true)][string]$Folder)
    if ($script:openShouldFail) { throw "explorer stub failure" }
    $script:openedFolders += $Folder
}

Check "folder button: initialises and opens <install root>\user_hooks (stub, no Explorer)" {
    $f = New-FakeInstall
    try {
        $script:openedFolders = @(); $script:openShouldFail = $false
        $r = Invoke-HookFolderButton -ScriptDir $f.ScriptDir
        if ($r.Status -ne "opened") { throw "status $($r.Status)" }
        if ($script:openedFolders.Count -ne 1) { throw "expected 1 open, got $($script:openedFolders.Count)" }
        if ((Norm $script:openedFolders[0]) -ne (Norm $f.UserDir)) { throw "opened $($script:openedFolders[0])" }
        if (-not (Test-Path -LiteralPath (Join-Path $f.UserDir "d4_rom_pre_record.py"))) { throw "files not created before opening" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "folder button: a needed template missing => notice text with the exact path, nothing opened, no throw" {
    $f = New-FakeInstall
    try {
        $script:openedFolders = @(); $script:openShouldFail = $false
        $missing = Join-Path $f.Templates "d4_rom_pre_record.py"
        Remove-Item -LiteralPath $missing
        $r = Invoke-HookFolderButton -ScriptDir $f.ScriptDir
        if ($r.Status -ne "template_missing") { throw "status $($r.Status)" }
        if ($r.Message -notlike "*$missing*") { throw "notice lacks the exact path: $($r.Message)" }
        if ($script:openedFolders.Count -ne 0) { throw "a folder was opened" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "folder button: Explorer failure => status explorer_failed with a log message, no throw" {
    $f = New-FakeInstall
    try {
        $script:openedFolders = @(); $script:openShouldFail = $true
        $r = Invoke-HookFolderButton -ScriptDir $f.ScriptDir
        if ($r.Status -ne "explorer_failed") { throw "status $($r.Status)" }
        if (-not $r.Message) { throw "no log message" }
    } finally { $script:openShouldFail = $false; Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "the logic file's real Open-HookFolder starts explorer.exe with the quoted folder (source check, never run)" {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptsRoot "rom_launcher_logic.ps1"), [ref]$tok, [ref]$err)
    $fn = @($ast.EndBlock.Statements | Where-Object { $_.Name -eq "Open-HookFolder" })
    if ($fn.Count -ne 1) { throw "Open-HookFolder not defined in the logic file" }
    $body = $fn[0].Extent.Text
    if ($body -notmatch 'Start-Process\s+(-FilePath\s+)?"?explorer\.exe"?') { throw "does not Start-Process explorer.exe" }
    if ($body -notmatch '`"\$Folder`"|"`"\$Folder`""|''"''\s*\+\s*\$Folder') { throw "folder is not quoted" }
}

# ---------------------------------------------------------------- context file
Check "Write-HookContext writes state\_hook_context.json: ASCII, no BOM, the agreed keys" {
    $f = New-FakeInstall
    try {
        $p = Write-HookContext -ScriptDir $f.ScriptDir -Axis "All" -StartFrame 10 -EndFrame 120 -ToolVersion "1.1.0"
        if ((Norm $p) -ne (Norm (Join-Path $f.ScriptDir "state\_hook_context.json"))) { throw "path $p" }
        $bytes = [IO.File]::ReadAllBytes($p)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "has a BOM" }
        if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "non-ASCII byte" }
        $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
        if ($j.axis -ne "All") { throw "axis $($j.axis)" }
        if ($j.leg_count -ne 2) { throw "leg_count $($j.leg_count)" }
        if ($j.start_frame -ne 10 -or $j.end_frame -ne 120) { throw "frames $($j.start_frame)/$($j.end_frame)" }
        if ($j.tool_version -ne "1.1.0") { throw "tool_version $($j.tool_version)" }
        if ((Norm $j.scripts_dir) -ne (Norm $f.ScriptDir)) { throw "scripts_dir $($j.scripts_dir)" }
        if ((Norm $j.state_dir) -ne (Norm (Join-Path $f.ScriptDir "state"))) { throw "state_dir $($j.state_dir)" }
        $p2 = Write-HookContext -ScriptDir $f.ScriptDir -Axis "LeftRight" -StartFrame $null -EndFrame $null -ToolVersion "1.1.0"
        $j2 = [IO.File]::ReadAllText($p2) | ConvertFrom-Json
        if ($j2.leg_count -ne 1) { throw "LeftRight leg_count $($j2.leg_count)" }
        if ($null -ne $j2.start_frame -or $null -ne $j2.end_frame) { throw "All-frames must write null frames" }
        $raw = [IO.File]::ReadAllText($p2)
        if ($raw -notmatch '"start_frame"\s*:\s*null') { throw "start_frame is not JSON null: $raw" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Write-HookContext keeps a non-ASCII install path exact (escaped \uXXXX, still ASCII)" {
    $root = Join-Path $env:TEMP ("t97_ctx_" + [char]0x00E9 + [char]0x00FC + "_" + [guid]::NewGuid().ToString("N"))
    $sd = Join-Path $root "scripts"
    New-Item -ItemType Directory -Path $sd -Force | Out-Null
    try {
        $p = Write-HookContext -ScriptDir $sd -Axis "FrontBack" -StartFrame $null -EndFrame $null -ToolVersion "1.1.0"
        $bytes = [IO.File]::ReadAllBytes($p)
        if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "non-ASCII byte written" }
        $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
        if ((Norm $j.scripts_dir) -ne (Norm $sd)) { throw "scripts_dir round-trip '$($j.scripts_dir)'" }
    } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "Python reads the context file the launcher writes (same JSON both sides)" {
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { throw "python not found on PATH" }
    $f = New-FakeInstall
    try {
        $p = Write-HookContext -ScriptDir $f.ScriptDir -Axis "All" -StartFrame 5 -EndFrame 6 -ToolVersion "1.1.0"
        $out = & $py.Source -I -c "import json,sys; d=json.load(open(sys.argv[1])); print('%s|%s|%s|%s' % (d['axis'], d['leg_count'], d['start_frame'], d['end_frame']))" $p 2>&1
        if ("$out".Trim() -ne "All|2|5|6") { throw "python read '$out'" }
    } finally { Remove-Item $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- repo hygiene
Check ".gitignore ignores user_hooks/" {
    $gi = Get-Content -LiteralPath (Join-Path $RepoRoot ".gitignore")
    if (-not ($gi | Where-Object { $_.Trim() -eq "user_hooks/" })) { throw "user_hooks/ not in .gitignore" }
}

Check "rom_launcher_logic.ps1 stays functions-only (still safe to dot-source)" {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ScriptsRoot "rom_launcher_logic.ps1"), [ref]$tok, [ref]$err)
    if ($err.Count) { throw "parse errors" }
    $nonFn = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
    if ($nonFn.Count) { throw "top-level statements in the logic file" }
}

Remove-Item (Join-Path $env:TEMP "t97_fake_user") -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ""
foreach ($f in $failures) { Write-Output "FAIL: $f" }
Write-Output "$passed passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

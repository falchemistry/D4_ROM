# Persistent test for build_dist.ps1 (T97): the end-user zip ships the
# pre/post recording templates (comment-only) and the hook runner, never a
# user's own user_hooks\ folder, and the build FAILS loudly when a template
# has code in it. Also re-checks the general dist hygiene (no state files,
# no scripts\state, no legacy\, obs_config.txt is the placeholder).
#
# Every build goes into a temp folder (-DistDir), never the real
# ..\d4_rom_dist. The failure-path builds run a COPY of the repo in a temp
# folder, so the repo itself is never modified. Never launches Maya or OBS.
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_build_dist.ps1
# Exits 0 if all checks pass, 1 otherwise.

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ScriptsRoot = Join-Path $RepoRoot "scripts"
$TemplateNames = @("d4_rom_pre_record.py", "d4_rom_post_record.py")
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

function Test-CommentOnly([string]$path) {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#")) { return $false }
    }
    return $true
}

function Invoke-Build([string]$buildScript, [string]$distDir) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript -DistDir $distDir 2>&1
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = (@($out) -join "`n") }
}

# A throwaway copy of the repo (no .git, no cache data) so failure paths
# can be provoked without touching the real tree.
function New-RepoCopy {
    $dst = Join-Path $env:TEMP ("t97_repo_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dst | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $RepoRoot -Force) {
        if (@(".git", "d4_anim_sample", "user_hooks") -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force
    }
    # never keep a copy of the real OBS password or this machine's run state
    # in the temp copy (build_dist writes its own placeholder anyway)
    Remove-Item -LiteralPath (Join-Path $dst "scripts\obs_config.txt") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $dst "scripts\state") -Recurse -Force -ErrorAction SilentlyContinue
    return $dst
}

# ---------------------------------------------------------------- normal build
$Dist = Join-Path $env:TEMP ("t97_dist_" + [guid]::NewGuid().ToString("N"))
$Build = Invoke-Build (Join-Path $RepoRoot "build_dist.ps1") $Dist
$DS = Join-Path $Dist "scripts"

Check "build succeeds into a temp folder" {
    if ($Build.ExitCode -ne 0) { throw "exit $($Build.ExitCode): $($Build.Output)" }
    if ($Build.Output -notmatch "BUILD SUCCEEDED") { throw "no BUILD SUCCEEDED line" }
}

Check "dist ships both templates in scripts\hooks\templates, byte-identical, ASCII, comment-only" {
    foreach ($n in $TemplateNames) {
        $p = Join-Path $DS "hooks\templates\$n"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "dist lacks hooks\templates\$n" }
        if ((Get-FileHash -LiteralPath $p).Hash -ne (Get-FileHash -LiteralPath (Join-Path $ScriptsRoot "hooks\templates\$n")).Hash) { throw "$n differs from the repo template" }
        $bytes = [IO.File]::ReadAllBytes($p)
        if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "$n is not ASCII" }
        if (-not (Test-CommentOnly $p)) { throw "$n has a code line" }
        if ((Get-Item -LiteralPath $p).Length -lt 50) { throw "$n lost its explanatory header" }
    }
}

Check "dist ships the hook runner scripts\hooks\maya_run_hook.py" {
    $p = Join-Path $DS "hooks\maya_run_hook.py"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "dist lacks hooks\maya_run_hook.py" }
    if ((Get-FileHash -LiteralPath $p).Hash -ne (Get-FileHash -LiteralPath (Join-Path $ScriptsRoot "hooks\maya_run_hook.py")).Hash) { throw "runner differs from the repo" }
}

Check "dist has no user_hooks folder anywhere" {
    $u = @(Get-ChildItem -LiteralPath $Dist -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "user_hooks" })
    if ($u.Count) { throw "found $($u[0].FullName)" }
}

Check "dist has no _*.txt / underscore state files, no scripts\state, no legacy\, no tests\" {
    $us = @(Get-ChildItem -LiteralPath $Dist -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "_*" })
    if ($us.Count) { throw "state-like files: $(($us | ForEach-Object Name) -join ', ')" }
    if (Test-Path -LiteralPath (Join-Path $DS "state")) { throw "dist ships scripts\state" }
    if (Test-Path -LiteralPath (Join-Path $Dist "legacy")) { throw "dist ships legacy\" }
    if (Test-Path -LiteralPath (Join-Path $Dist "tests")) { throw "dist ships tests\" }
    if (Test-Path -LiteralPath (Join-Path $Dist "d4_anim_sample")) { throw "dist ships d4_anim_sample" }
}

Check "obs_config.txt in the dist is the REPLACE_ME placeholder" {
    $cfg = Join-Path $DS "obs_config.txt"
    if (-not (Test-Path -LiteralPath $cfg)) { throw "missing" }
    if ((Get-Content -LiteralPath $cfg -Raw) -notmatch 'password:\s*REPLACE_ME') { throw "not the placeholder" }
}

Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- failure paths (on a repo copy)
Check "a template with a code line FAILS the build (BUILD FAILED, exit 1, names the template)" {
    $copy = New-RepoCopy
    $dist2 = Join-Path $env:TEMP ("t97_dist_bad_" + [guid]::NewGuid().ToString("N"))
    try {
        $tpl = Join-Path $copy "scripts\hooks\templates\d4_rom_post_record.py"
        if (-not (Test-Path -LiteralPath $tpl)) { throw "precondition: the repo has no template to break" }
        Add-Content -LiteralPath $tpl -Value "print('leaked user code')" -Encoding Ascii
        $r = Invoke-Build (Join-Path $copy "build_dist.ps1") $dist2
        if ($r.ExitCode -eq 0) { throw "build passed with a code line in a template" }
        if ($r.Output -notmatch "BUILD FAILED") { throw "no BUILD FAILED line: $($r.Output)" }
        if ($r.Output -notmatch "d4_rom_post_record\.py") { throw "failure does not name the template: $($r.Output)" }
    } finally {
        Remove-Item $copy -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $dist2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "a dev user_hooks\ folder (install root or under scripts\hooks) never reaches the dist" {
    $copy = New-RepoCopy
    $dist3 = Join-Path $env:TEMP ("t97_dist_uh_" + [guid]::NewGuid().ToString("N"))
    try {
        foreach ($d in @((Join-Path $copy "user_hooks"), (Join-Path $copy "scripts\hooks\user_hooks"))) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $d "d4_rom_pre_record.py"), "print('T97_SENTINEL private')`n", (New-Object System.Text.ASCIIEncoding))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $copy "scripts\hooks\maya_run_hook.py"))) { throw "precondition: the repo has no scripts\hooks yet" }
        $r = Invoke-Build (Join-Path $copy "build_dist.ps1") $dist3
        $leak = @(Get-ChildItem -LiteralPath $dist3 -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "user_hooks" -or ($_.PSIsContainer -eq $false -and (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'T97_SENTINEL') })
        if ($r.ExitCode -eq 0) {
            if ($leak.Count) { throw "build succeeded AND shipped user_hooks: $($leak[0].FullName)" }
            if (-not (Test-Path -LiteralPath (Join-Path $dist3 "scripts\hooks\maya_run_hook.py"))) { throw "build succeeded but shipped no hooks" }
        } else {
            if ($r.Output -notmatch "BUILD FAILED" -or $r.Output -notmatch "user_hooks") { throw "failed without naming user_hooks: $($r.Output)" }
        }
    } finally {
        Remove-Item $copy -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $dist3 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "L6: an existing <DistDir>\user_hooks is never deleted: the build refuses with BUILD FAILED" {
    $dist4 = Join-Path $env:TEMP ("t97_dist_l6_" + [guid]::NewGuid().ToString("N"))
    try {
        $uh = Join-Path $dist4 "user_hooks"
        New-Item -ItemType Directory -Path $uh -Force | Out-Null
        $mine = Join-Path $uh "d4_rom_pre_record.py"
        [IO.File]::WriteAllText($mine, "print('T97_SENTINEL keep me')`n", (New-Object System.Text.ASCIIEncoding))
        $r = Invoke-Build (Join-Path $RepoRoot "build_dist.ps1") $dist4
        if ($r.ExitCode -eq 0) { throw "build ran over a dist folder holding user_hooks" }
        if ($r.Output -notmatch "BUILD FAILED" -or $r.Output -notmatch "user_hooks") { throw "no clear BUILD FAILED naming user_hooks: $($r.Output)" }
        if (-not (Test-Path -LiteralPath $mine)) { throw "the user's script was deleted" }
    } finally { Remove-Item $dist4 -Recurse -Force -ErrorAction SilentlyContinue }
}

Check "M19: the final dist guard fires when a user_hooks folder rides along in a copied folder" {
    $copy = New-RepoCopy
    $dist5 = Join-Path $env:TEMP ("t97_dist_m19_" + [guid]::NewGuid().ToString("N"))
    try {
        $leak = Join-Path $copy "scripts\guide_images\user_hooks"
        New-Item -ItemType Directory -Path $leak -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $leak "d4_rom_pre_record.py"), "print('T97_SENTINEL private')`n", (New-Object System.Text.ASCIIEncoding))
        $r = Invoke-Build (Join-Path $copy "build_dist.ps1") $dist5
        if ($r.ExitCode -eq 0) { throw "build passed although user_hooks reached the dist" }
        if ($r.Output -notmatch "BUILD FAILED" -or $r.Output -notmatch "user_hooks") { throw "failure does not name user_hooks: $($r.Output)" }
    } finally {
        Remove-Item $copy -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $dist5 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Check "build_dist.ps1 source has the user_hooks guard and the template guard on the BUILD FAILED path" {
    $src = Get-Content -LiteralPath (Join-Path $RepoRoot "build_dist.ps1") -Raw
    if ($src -notmatch 'user_hooks') { throw "no user_hooks guard in build_dist.ps1" }
    if ($src -notmatch 'hooks\\templates|hooks/templates') { throw "build_dist.ps1 does not copy scripts\hooks\templates" }
}

Write-Output ""
foreach ($f in $failures) { Write-Output "FAIL: $f" }
Write-Output "$passed passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

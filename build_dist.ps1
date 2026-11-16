# Copies the finished, end-user-facing subset of this project into a
# clean folder SEPARATE from the dev tree -- rerun any time after changes
# to refresh the distributed copy. Never touches the dev tree itself.
#
# Deliberately excluded, and why:
#   tests/, exe_src/            -- dev-only, no end user needs these
#   d4_anim_sample/             -- this machine's own cache data, not source
#   scripts/maya/maya_debug_inspect.py -- scratch file, overwritten for one-off
#                                     diagnostics, not part of the real tool
#   scripts/state/ (_frame_range_state.txt, _playback_state.txt, ...)
#                                -- transient runtime state from THIS
#                                   machine's own captures, not source
#   scripts/obs_config.txt      -- contains this machine's REAL OBS
#                                   WebSocket password. Shipping it would
#                                   leak that password to whoever gets this
#                                   folder, AND wouldn't even work for them
#                                   -- every machine's OBS has its own
#                                   independent WebSocket password. A
#                                   placeholder template is written instead
#                                   (see below), with clear instructions.
#   user_hooks/                 -- the user's OWN pre/post recording scripts
#                                   (T97); the zip ships only the comment-only
#                                   templates in scripts/hooks/templates/
#   legacy/ (the old run_*.bat/capture_*.bat files)
#                                -- superseded by rom_launcher.bat /
#                                   ROM_Launcher.exe, which replaced them
#
# Usage: powershell -ExecutionPolicy Bypass -File build_dist.ps1
#        powershell -ExecutionPolicy Bypass -File build_dist.ps1 -DistDir "D:\some\other\path"

param(
    [string]$DistDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "d4_rom_dist")
)

function Get-DistDirProblem {
    # Returns "" when $DistDir is safe to wipe and rebuild, else one sentence
    # saying why not. Refused: the tool root, a parent folder of it, anything
    # inside it, AND (T136 fix round) anything that IS a tool copy under another
    # name -- a UNC admin-share alias (\localhost\C$\...), a mapped/subst drive,
    # a junction or symlink -- found by the dev-only files a dist never holds
    # (build_dist.ps1, build_exe.ps1, the tests\ and exe_src\ folders), in the
    # folder itself, in any of its parents, or in a folder directly inside it.
    # ROM_Launcher.exe is NOT a marker: the dist ships it, and rebuilding over a
    # previous dist must keep working. Any error here stops the build (fail closed).
    param([string]$DistDir, [string]$ToolRoot)
    $cmp = [StringComparison]::OrdinalIgnoreCase
    # A drive or share root ('C:\', 'C:', 'd:/', '\\server\share\', '\\localhost\C$\')
    # is refused from the text as typed, before any path is resolved: a bare 'C:'
    # means "the current folder of drive C", so resolving first would hide it.
    $typed = (([string]$DistDir).Trim().Trim('"')) -replace '/', '\'
    if ($typed -match '^[A-Za-z]:\\*$' -or $typed -match '^\\\\[^\\]+\\[^\\]+\\*$') {
        return "it is a drive or share root ($DistDir)"
    }
    $root = ConvertTo-DistFullPath $ToolRoot
    $rootLeaf = [IO.Path]::GetFileName($root)
    $candidates = @(ConvertTo-DistFullPath $DistDir)
    # a junction/symlink: judge where it points as well as its own name
    try {
        $item = Get-Item -LiteralPath $candidates[0] -Force -ErrorAction Stop
        if ($item.LinkType -and $item.Target) { foreach ($t in @($item.Target)) { $candidates += (ConvertTo-DistFullPath $t) } }
    } catch { }
    foreach ($dist in $candidates) {
        # a root reached another way (a ..\ segment, a junction target, an admin-share alias)
        if ($dist -match '^[A-Za-z]:$' -or $dist -match '^\\\\[^\\]+\\[^\\]+$' -or $dist -eq "") { return "it is a drive or share root ($dist\)" }
        if ($dist.Equals($root, $cmp)) { return "it is the tool folder itself ($root)" }
        if ($root.StartsWith($dist + "\", $cmp)) { return "it contains the tool folder ($root), so rebuilding would delete the tool" }
        if ($dist.StartsWith($root + "\", $cmp)) { return "it is inside the tool folder ($root), so rebuilding would delete part of the tool" }
        $dir = $dist
        while ($dir) {
            $hit = Get-DistToolMarker $dir
            if ($hit) { return "it is, or sits inside, a copy of the tool folder ($hit found in $dir), so rebuilding would delete tool files" }
            $dir = [IO.Path]::GetDirectoryName($dir)
        }
        if (Test-Path -LiteralPath $dist -PathType Container) {
            foreach ($child in @(Get-ChildItem -LiteralPath $dist -Directory -Force -ErrorAction SilentlyContinue)) {
                $hit = Get-DistToolMarker $child.FullName
                if ($hit) { return "it contains a copy of the tool folder ($($child.FullName): $hit), so rebuilding would delete the tool" }
            }
        }
    }
    return ""
}

function ConvertTo-DistFullPath([string]$Path) {
    # Full path, no trailing backslash, and a local admin-share UNC alias
    # (\localhost\C$\x, \127.0.0.1\C$\x, \<this PC>\C$\x) turned back into C:\x
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $me = [regex]::Escape($env:COMPUTERNAME)
    $m = [regex]::Match($full, '^\\\\(localhost|127\.0\.0\.1|\[::1\]|' + $me + '(\.[^\\]*)?)\\([A-Za-z])\$(\\.*)?$', 'IgnoreCase')
    if ($m.Success) { $full = $m.Groups[3].Value.ToUpper() + ":" + $m.Groups[4].Value }
    return $full.TrimEnd('\')
}

function Get-DistToolMarker([string]$Dir) {
    # Name of the first dev-only item found directly in $Dir, else ""
    $base = $Dir.TrimEnd('\') + "\"
    foreach ($f in @("build_dist.ps1", "build_exe.ps1")) {
        if (Test-Path -LiteralPath ($base + $f) -PathType Leaf) { return $f }
    }
    foreach ($d in @("tests", "exe_src")) {
        if (Test-Path -LiteralPath ($base + $d) -PathType Container) { return "$d\" }
    }
    return ""
}

# $ErrorActionPreference = "Stop" + the try/catch below: a build that only
# HALF-completes (e.g. ROM_Launcher.exe skipped because a running instance
# still had it locked) previously continued past that with default
# non-terminating error handling and still printed "Distributed to: ...",
# reading as a normal success. Any real failure now stops the build and is
# reported clearly instead of hiding inside otherwise-normal-looking
# output -- build_dist.bat's `pause` still always runs either way, so the
# window never just flashes and disappears.
$ErrorActionPreference = "Stop"

try {
    # T136 (R14): the next steps run Remove-Item -Recurse -Force on whatever
    # -DistDir names. Refuse a folder that is the tool itself, one of its
    # parents (it would wipe the tool with it) or anything inside it, BEFORE
    # anything is deleted. Paths are compared as full paths, case-insensitive
    # and ignoring a trailing backslash (a relative -DistDir is resolved
    # against the current folder), local UNC admin-share aliases are mapped
    # back to the drive path, and any folder holding the tool's own dev-only
    # files is refused whatever its name (see Get-DistDirProblem).
    $distProblem = Get-DistDirProblem -DistDir $DistDir -ToolRoot $PSScriptRoot
    if ($distProblem) {
        throw "refusing to build into -DistDir '$DistDir': $distProblem. Nothing was deleted. Pick a separate, empty or previous-dist folder (the default is the sibling d4_rom_dist)."
    }
    # A user's own pre/post scripts (T97) are never deleted by a rebuild:
    # if this dist folder holds them, refuse instead of wiping it.
    if (Test-Path -LiteralPath (Join-Path $DistDir "user_hooks")) {
        throw "refusing to rebuild: $(Join-Path $DistDir 'user_hooks') exists and holds someone's own pre/post recording scripts -- move that folder out of $DistDir (or pick another -DistDir) and run again"
    }
    if (Test-Path $DistDir) {
        Remove-Item $DistDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DistDir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DistDir "scripts") | Out-Null

    $rootFiles = @("ROM_Launcher.exe", "rom_launcher.bat", "open_maya_port.py", "install_shelf_button.py", "app_icon.ico")
    foreach ($f in $rootFiles) {
        Copy-Item (Join-Path $PSScriptRoot $f) $DistDir
    }

    $excludedFromScripts = @("maya_debug_inspect.py", "_frame_range_state.txt", "_playback_state.txt", "obs_config.txt")
    Get-ChildItem (Join-Path $PSScriptRoot "scripts") -File | Where-Object {
        $excludedFromScripts -notcontains $_.Name
    } | Copy-Item -Destination (Join-Path $DistDir "scripts")

    # Category folders (T99). scripts\state\ is never shipped: it only holds
    # this machine's transient run state and the tool creates it on demand.
    foreach ($sub in @("maya", "capture", "obs")) {
        New-Item -ItemType Directory -Path (Join-Path $DistDir "scripts\$sub") | Out-Null
        Get-ChildItem (Join-Path $PSScriptRoot "scripts\$sub") -File | Where-Object {
            $excludedFromScripts -notcontains $_.Name
        } | Copy-Item -Destination (Join-Path $DistDir "scripts\$sub")
    }

    # Pre/post recording scripts (T97): ship the tool-owned runner and the
    # two comment-only templates. The user's real scripts live in
    # <install root>\user_hooks\, created on first use and never part of
    # the zip; a template that has code in it (a dev's test edit leaking
    # into every user's install) fails the build.
    $hooksSrc = Join-Path $PSScriptRoot "scripts\hooks"
    $hooksDst = Join-Path $DistDir "scripts\hooks"
    New-Item -ItemType Directory -Path (Join-Path $hooksDst "templates") -Force | Out-Null
    Copy-Item (Join-Path $hooksSrc "maya_run_hook.py") $hooksDst
    foreach ($hookName in @("d4_rom_pre_record.py", "d4_rom_post_record.py")) {
        $tpl = Join-Path $hooksSrc "templates\$hookName"
        if (-not (Test-Path -LiteralPath $tpl -PathType Leaf)) { throw "hook template missing: scripts\hooks\templates\$hookName" }
        foreach ($line in [IO.File]::ReadAllLines($tpl)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith("#")) {
                throw "hook template scripts\hooks\templates\$hookName must be comments only (found code: '$t') -- the zip must ship it empty"
            }
        }
        Copy-Item $tpl (Join-Path $hooksDst "templates")
    }

    # Real screenshots (OBS WebSocket Server Settings, this tool's own
    # Settings/Capture tabs) shown inline in the OBS password prompt and
    # the Guide window -- end users need these just as much as the
    # scripts themselves, unlike everything else excluded above.
    Copy-Item (Join-Path $PSScriptRoot "scripts\guide_images") (Join-Path $DistDir "scripts\guide_images") -Recurse

    @"
OBS WebSocket connection info for d4_rom capture automation.

host: 127.0.0.1
port: 4455
password: REPLACE_ME

Set under OBS > Tools > WebSocket Server Settings ON THIS MACHINE, then
paste that password here. Every machine's OBS has its own independent
WebSocket password -- do not reuse one copied from elsewhere.
"@ | Set-Content -Path (Join-Path $DistDir "scripts\obs_config.txt") -Encoding UTF8

    # Last line of defence (T97): a user's own pre/post scripts must never
    # reach the zip, whichever copy above might have picked them up.
    $leakedHooks = @(Get-ChildItem -LiteralPath $DistDir -Recurse -Directory -Force | Where-Object { $_.Name -eq "user_hooks" })
    if ($leakedHooks.Count) { throw "user_hooks folder found in the dist ($($leakedHooks[0].FullName)) -- user scripts must never ship" }

    Write-Output "BUILD SUCCEEDED"
    Write-Output "Distributed to: $DistDir"
    Write-Output "Remember: scripts\obs_config.txt needs a real password filled in on the target machine before Start Recording will work."
} catch {
    Write-Output "BUILD FAILED: $($_.Exception.Message)"
    # A locked ROM_Launcher.exe (a copy still running from $DistDir) is the
    # one cause seen in practice -- called out explicitly since the real
    # exception text doesn't always make that obvious at a glance.
    Write-Output "If this mentions ROM_Launcher.exe being in use, close any running copy of it (check Task Manager) and try again."
    exit 1
}

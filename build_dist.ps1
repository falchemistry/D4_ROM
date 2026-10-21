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

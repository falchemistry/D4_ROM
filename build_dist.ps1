# Copies the finished, end-user-facing subset of this project into a
# clean folder SEPARATE from the dev tree -- rerun any time after changes
# to refresh the distributed copy. Never touches the dev tree itself.
#
# Deliberately excluded, and why:
#   tests/, exe_src/            -- dev-only, no end user needs these
#   d4_anim_sample/             -- this machine's own cache data, not source
#   scripts/maya_debug_inspect.py -- scratch file, overwritten for one-off
#                                     diagnostics, not part of the real tool
#   scripts/_frame_range_state.txt, _playback_state.txt
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
#   the old run_*.bat/capture_*.bat files
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

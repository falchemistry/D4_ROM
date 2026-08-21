# Compiles exe_src/Program.cs into ROM_Launcher.exe, embedding app_icon.ico
# via csc's /win32icon flag -- this is the ONLY thing that changes what
# Explorer/the taskbar shows for the .exe file itself (rom_launcher.ps1's
# own $window.Icon line only affects the WPF window while it's actually
# open, a separate and unrelated icon assignment).
#
# No build script existed for this before (the .exe was compiled by hand
# once) -- this codifies that one-off command so re-icon'ing or any future
# Program.cs change doesn't require remembering the right csc flags again.
#
# Usage: powershell -ExecutionPolicy Bypass -File build_exe.ps1

$ErrorActionPreference = "Stop"

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    throw "csc.exe not found at $csc -- .NET Framework 4.x isn't installed where expected."
}

$srcPath = Join-Path $PSScriptRoot "exe_src\Program.cs"
$iconPath = Join-Path $PSScriptRoot "app_icon.ico"
$outPath = Join-Path $PSScriptRoot "ROM_Launcher.exe"

if (-not (Test-Path $srcPath)) { throw "Source not found: $srcPath" }
if (-not (Test-Path $iconPath)) { throw "Icon not found: $iconPath (run generate the icon first)" }

& $csc /nologo /target:winexe /out:"$outPath" /win32icon:"$iconPath" /reference:System.Windows.Forms.dll "$srcPath"
if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE"
}

Write-Output "Built: $outPath"

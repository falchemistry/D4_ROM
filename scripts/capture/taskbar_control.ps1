# Hides or shows every Windows taskbar (primary + one per extra monitor).
#
# Used by the capture bat files so the taskbar is hidden BEFORE Maya's view
# panels are created -- Windows constrains a new window to the current work
# area, so creating panels while the taskbar is visible caps them at
# (monitor height - taskbar height) and leaves a dead strip at the bottom
# once the taskbar hides.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File taskbar_control.ps1 -Action hide
#   powershell -ExecutionPolicy Bypass -File taskbar_control.ps1 -Action show

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("hide", "show")]
    [string]$Action
)

# Multi-monitor setups get a second taskbar per extra display, under class
# "Shell_SecondaryTrayWnd" (the primary is "Shell_TrayWnd") -- FindWindow
# only returns one match, so enumerate top-level windows to catch all of them.
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class ClaudeTaskbarCtl {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static List<IntPtr> FindTaskbars() {
        var found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            var sb = new StringBuilder(256);
            GetClassName(hWnd, sb, sb.Capacity);
            string cls = sb.ToString();
            if (cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") {
                found.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

$cmd = if ($Action -eq "hide") { 0 } else { 1 }  # SW_HIDE / SW_SHOWNORMAL
$bars = [ClaudeTaskbarCtl]::FindTaskbars()
foreach ($bar in $bars) {
    [ClaudeTaskbarCtl]::ShowWindow($bar, $cmd) | Out-Null
}
Write-Host "Taskbar $Action applied to $($bars.Count) taskbar window(s)."

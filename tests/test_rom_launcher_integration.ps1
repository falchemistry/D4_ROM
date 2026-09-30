# Headless integration test for rom_launcher.ps1 -- dot-sources it with
# -NoShow (builds the window/wiring but never calls ShowDialog()), then
# drives the REAL Start-Steps/Start-NextStep/DispatcherTimer queue with a
# harmless fake step sequence (ping commands, never touching Maya/OBS or
# the real d4_rom scripts). Proves the async-process + DispatcherTimer
# polling mechanism actually works end-to-end before ever showing a real
# window or running a real capture.
#
# Run via: powershell -ExecutionPolicy Bypass -File tests\test_rom_launcher_integration.ps1
# Exits 0 if all checks pass, 1 otherwise.

. (Join-Path $PSScriptRoot "..\scripts\rom_launcher.ps1") -NoShow

# Default override so every Update-MonitorList call in this file (most of
# which don't care about monitor-NAME persistence specifically) writes to
# a throwaway path instead of the real project's
# d4_anim_sample\_recording_monitor_name.txt -- same isolation convention
# already used for Get-RecordingMonitorRectPath/Get-ObsConfigFilePath.
# Individual Checks below that DO care about this file redefine the
# function again with their own path, which simply overrides this default
# from that point on.
$script:defaultRecordingMonitorNameTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_name_default.txt"
function Get-RecordingMonitorNamePath { return $script:defaultRecordingMonitorNameTestPath }

# Safety-net default (2026-09-08): Show-DarkConfirm's REAL implementation
# always calls a genuine, blocking .ShowDialog() regardless of the main
# window's -NoShow state -- confirmed the hard way: the frame-gate warning
# added to Start Recording's click handler hung an entire suite run with
# two real, unattended "Framing Warning" dialog windows sitting open,
# because $script:lastCachePath/zoom/offset state left over from an
# EARLIER, unrelated test happened to land in the zero-tolerance zone by
# the time a LATER test clicked Start Recording without expecting to hit
# any confirm dialog at all. Same override convention as
# Get-RecordingMonitorNamePath just above: any Check below that DOES want
# to test a real confirm-dialog interaction (several already do, e.g. the
# Force Rebuild tests) defines its own override, which simply takes
# priority for that scope -- this is only the fallback for everything
# else, so a leftover/unexpected reach into ANY confirm dialog (this one
# or a future one) can never again hang the whole suite unattended.
#
# Captured BEFORE the override below replaces it, so the one test that
# specifically verifies Show-DarkConfirm's OWN real click-handling
# (searchable: "Show-DarkConfirm's real Yes button") can temporarily
# restore the genuine implementation for its own scope, then hand the
# safe default back for everything after it.
$script:realShowDarkConfirm = ${function:Show-DarkConfirm}

function Show-DarkConfirm {
    param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
    return $false
}
function Set-SafeShowDarkConfirmDefault {
    ${function:Show-DarkConfirm} = {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        return $false
    }
}

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

function Wait-ForStatus([string]$expected, [int]$timeoutSeconds) {
    # Checks $script:runStatus, not $statusLabel.Text -- StatusLabel's
    # visible text is now a static "Logs" header (2026-08-20) and no
    # longer carries Idle/Running/Done at all; the run-state tracking
    # moved to this internal-only variable instead.
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($script:runStatus -ne $expected -and (Get-Date) -lt $deadline) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({ $frame.Continue = $false })
        $t.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        $t.Stop()
    }
    return $script:runStatus -eq $expected
}

Check "Capture is the default active tab at startup, Settings hidden" {
    if ($capturePanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected Capture panel visible by default" }
    if ($settingsPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected Settings panel collapsed by default" }
}

Check "Magnifier always starts at the safe 0% default, not a value restored from an earlier launch" {
    # Must run before any later Check moves $zoomSlider -- this is checking
    # the state set once at launch, right after dot-sourcing rom_launcher.ps1
    # above (design 2026-09-02: a forgotten non-zero magnifier from a past
    # session must never silently carry into this one). ZoomSlider's own
    # XAML default is already 0, so this also proves the box text got set
    # explicitly rather than left blank (a same-value 0->0 assignment would
    # never fire ValueChanged, which is what normally fills the box).
    if ($zoomSlider.Value -ne 0) { throw "expected the magnifier slider to start at 0, got $($zoomSlider.Value)" }
    if ($zoomValueBox.Text -ne "0") { throw "expected the magnifier box to read '0' at startup, got '$($zoomValueBox.Text)'" }
}

Check "Pixel offset starts at its safe/off default too, not a value restored from an earlier launch" {
    # Same reasoning and same "must run before any later Check touches
    # these controls" caveat as the Magnifier startup check above.
    if ($offsetXBox.Text -ne "0") { throw "expected the X offset box to read '0' at startup, got '$($offsetXBox.Text)'" }
    if ($offsetYBox.Text -ne "0") { throw "expected the Y offset box to read '0' at startup, got '$($offsetYBox.Text)'" }
}

Check "Recenter at start frame's state file is cleared at startup (mandatory now, no checkbox to check)" {
    # Runs against the REAL project path deliberately -- Clear-RecenterStartFrame
    # was already called at startup (dot-source time), before any test override
    # could exist, so this is the only way to observe that it actually ran.
    $realPath = Get-RecenterStartFramePath
    if (Test-Path $realPath) {
        $content = (Get-Content $realPath -Raw -ErrorAction SilentlyContinue)
        if ($content -and $content.Trim() -ne "") { throw "expected the recenter-start-frame file cleared at startup, got '$content'" }
    }
}

Check "startup writes a consolidated situation summary to the Logs box, visible regardless of active tab (design 2026-08-22)" {
    # Must run before any later Check clears $logBox (e.g. via Start-Steps)
    # -- this is checking the ORIGINAL content written once at launch,
    # right after dot-sourcing rom_launcher.ps1 above. Only asserts on
    # the stable structure/labels, not pass/fail values, since Maya/OBS
    # reachability genuinely varies by machine and shouldn't make this
    # test flaky.
    if ($logBox.Text -notmatch "=== Startup Check ===") { throw "expected a startup summary header in the log, got:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "Maya connection:") { throw "expected a Maya connection line in the startup summary, got:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "Cache: not checked yet") { throw "expected an honest 'not checked yet' cache line (no real Maya round-trip at startup), got:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "OBS WebSocket") { throw "expected the OBS password status relayed into the summary, got:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "Recording Monitor") { throw "expected the recording monitor status relayed into the summary, got:`n$($logBox.Text)" }
}

Check "clicking the Settings tab shows Settings and hides Capture; clicking Capture reverses it" {
    $settingsTabButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($settingsPanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected Settings panel visible after clicking its tab" }
    if ($capturePanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected Capture panel collapsed after switching to Settings" }
    # Monochromatic theme (2026-08-21): the active tab's background is now
    # the SAME gray as the parameter panel's own Background (#FF4D4D4D,
    # see that Border's comment) -- direct feedback asked for zero visual
    # seam between the active tab and its content, not just "some light
    # accent." Dark enough that the default light button text stays
    # readable without a contrast flip (an earlier, brighter version of
    # this color needed one; this one doesn't).
    if ($settingsTabButton.Background.Color -ne [System.Windows.Media.Color]::FromRgb(77, 77, 77)) { throw "expected the Settings tab to show the active-tab highlight color" }

    $captureTabButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($capturePanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected Capture panel visible again after switching back" }
    if ($settingsPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected Settings panel collapsed again after switching back" }
    if ($captureTabButton.Background.Color -ne [System.Windows.Media.Color]::FromRgb(77, 77, 77)) { throw "expected the Capture tab to show the active-tab highlight color" }
}

Check "status label, log box, and cache progress panel are NOT inside either tab-switched panel" {
    # These must stay visible regardless of which tab is active -- confirms
    # they live outside SettingsPanel/CapturePanel in the visual tree,
    # rather than trusting the XAML layout by eye.
    function Test-IsDescendantOf($child, $ancestor) {
        $current = $child
        while ($current -ne $null) {
            if ([object]::ReferenceEquals($current, $ancestor)) { return $true }
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        return $false
    }
    if (Test-IsDescendantOf $statusLabel $settingsPanel) { throw "StatusLabel must not live inside SettingsPanel" }
    if (Test-IsDescendantOf $statusLabel $capturePanel) { throw "StatusLabel must not live inside CapturePanel" }
    if (Test-IsDescendantOf $logBox $settingsPanel) { throw "LogBox must not live inside SettingsPanel" }
    if (Test-IsDescendantOf $logBox $capturePanel) { throw "LogBox must not live inside CapturePanel" }
    if (Test-IsDescendantOf $cacheProgressPanel $settingsPanel) { throw "CacheProgressPanel must not live inside SettingsPanel" }
    if (Test-IsDescendantOf $cacheProgressPanel $capturePanel) { throw "CacheProgressPanel must not live inside CapturePanel" }
}

Check "Show-DarkInput -Masked uses the real PasswordBox and returns its value, not the hidden TextBox's" {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $dlg = $null
            foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
                if ($src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.Title -eq "RegressionTestMaskedTitle") {
                    $dlg = $src.RootVisual
                    break
                }
            }
            if (-not $dlg) { throw "could not locate the masked input dialog window to click" }
            $pwBox = $dlg.FindName("InputPasswordBox")
            $txtBox = $dlg.FindName("InputBox")
            if ($pwBox.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the PasswordBox visible when -Masked is used" }
            if ($txtBox.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the plain TextBox collapsed when -Masked is used" }
            $pwBox.Password = "typed_masked_password"
            $dlg.FindName("SaveButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        } finally {
            if ($dlg -and $dlg.IsVisible) { $dlg.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    try {
        $result = Show-DarkInput -Title "RegressionTestMaskedTitle" -Message "test" -Masked
    } finally {
        $timer.Stop()
    }
    if ($result -ne "typed_masked_password") { throw "expected the PasswordBox's value returned, got '$result'" }
}

Check "Show-DarkGuide is non-modal (.Show(), not .ShowDialog()), displays the given message, and closing it (native title-bar close, no custom Close button) clears the tracked window" {
    # No DispatcherTimer/nested-pump trick needed here the way
    # Show-DarkConfirm/Show-DarkInput's tests still need one: those block
    # on ShowDialog()'s own nested message loop, so a timer has to fire
    # WHILE that call is blocked. Show-DarkGuide now calls .Show(), which
    # returns immediately with the window already constructed and
    # visible -- reaching the next line at all (instead of the call
    # hanging) is itself proof this is non-modal, and the window can be
    # interacted with directly and synchronously right after.
    Show-DarkGuide -Title "RegressionTestGuideTitle" -Tldr "this is test guide content"
    if ($script:openGuideWindow -eq $null) { throw "expected Show-DarkGuide to track the open window in `$script:openGuideWindow" }
    $dlg = $script:openGuideWindow
    if (-not $dlg.IsVisible) { throw "expected the guide window to actually be visible" }
    $tldrText = $dlg.FindName("TldrText")
    if ($tldrText.Text -notmatch "test guide content") { throw "expected the guide TLDR text to be set, got: $($tldrText.Text)" }
    if ($dlg.FindName("CloseButton") -ne $null) { throw "expected no custom Close button -- the native title-bar close is the only way to close this window now" }
    $dlg.Close()
    if ($script:openGuideWindow -ne $null) { throw "expected `$script:openGuideWindow to clear once the window is actually closed" }
}

Check "Show-DarkGuide reuses one instance -- calling it again while already open just activates the existing window instead of stacking a duplicate" {
    Show-DarkGuide -Title "FirstGuideCall" -Tldr "first message"
    $firstWindow = $script:openGuideWindow
    if ($firstWindow -eq $null) { throw "test setup: expected a window to be open after the first call" }

    Show-DarkGuide -Title "SecondGuideCall" -Tldr "second message"
    if ($script:openGuideWindow -ne $firstWindow) { throw "expected the SAME window instance reused, not a new one created while one is already open" }
    if ($firstWindow.Title -ne "FirstGuideCall") { throw "expected the existing window's own title/content left untouched by the second, suppressed call" }

    $firstWindow.Close()
    if ($script:openGuideWindow -ne $null) { throw "expected `$script:openGuideWindow to clear once closed" }
}

Check "clicking the Guide button opens Show-DarkGuide with real usage content, structured into sections/steps" {
    function Show-DarkGuide {
        param([string]$Title, [string]$Tldr, [array]$Sections)
        $script:guideShownTldr = $Tldr
        $script:guideShownSections = $Sections
    }
    $script:guideShownTldr = $null
    $script:guideShownSections = $null
    $guideButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:guideShownTldr -eq $null) { throw "expected clicking Guide to call Show-DarkGuide" }
    if ($script:guideShownTldr -notmatch "Usage") { throw "expected the TLDR text to include a Usage line, got: $script:guideShownTldr" }
    if (-not $script:guideShownSections -or $script:guideShownSections.Count -lt 2) { throw "expected at least a SETTINGS and a CAPTURE section, got: $($script:guideShownSections.Count)" }
    $captureSection = $script:guideShownSections | Where-Object { $_.Header -match "CAPTURE" }
    if (-not $captureSection) { throw "expected a CAPTURE section" }
    $matchesStartRecording = $captureSection.Steps | Where-Object { $_.Lead -match "Start Recording" -or $_.Text -match "Start Recording" }
    if (-not $matchesStartRecording) { throw "expected the CAPTURE section to mention Start Recording" }
    foreach ($section in $script:guideShownSections) {
        if (-not $section.ImagePath) { throw "expected every guide section to carry a real screenshot ImagePath, '$($section.Header)' had none" }
        if (-not (Test-Path $section.ImagePath)) { throw "guide section '$($section.Header)' points at a missing image file: $($section.ImagePath)" }
    }
}

Check "Show-DarkGuide opens on page 1 of N (the USAGE page), with Back disabled and Next enabled" {
    $sections = @(
        [PSCustomObject]@{ Header = "SECTION A"; Steps = @(@{ Lead = "Step:"; Text = "a" }) },
        [PSCustomObject]@{ Header = "SECTION B"; Steps = @(@{ Lead = "Step:"; Text = "b" }) }
    )
    Show-DarkGuide -Title "RegressionTestGuidePagingTitle" -Tldr "usage text" -Sections $sections
    try {
        $guideWin = $script:openGuideWindow
        if ($guideWin -eq $null) { throw "expected Show-DarkGuide to track the open window" }
        if ($guideWin.FindName("PageLabel").Text -ne "Page 1 of 3") { throw "expected 'Page 1 of 3' (USAGE + 2 sections), got '$($guideWin.FindName('PageLabel').Text)'" }
        if ($guideWin.FindName("BackButton").IsEnabled) { throw "expected Back disabled on the first page" }
        if (-not $guideWin.FindName("NextButton").IsEnabled) { throw "expected Next enabled when more pages follow" }
        if ($guideWin.FindName("TldrText").Text -ne "usage text") { throw "expected the USAGE page's own TldrText set" }
        $pageHostChildren = $guideWin.FindName("PageHost").Children
        if ($pageHostChildren.Count -ne 1) { throw "expected exactly one page's content showing at a time, got $($pageHostChildren.Count)" }
        if (-not ($pageHostChildren[0].Children -contains $guideWin.FindName("TldrText"))) { throw "expected the USAGE page (containing TldrText) to be the one currently showing" }
    } finally {
        $guideWin.Close()
    }
}

Check "Show-DarkGuide's Next/Back buttons actually flip pages, and the section's image renders on its own page" {
    $imgPath = Join-Path $ScriptDir "guide_images\guide_settings_tab.png"
    if (-not (Test-Path $imgPath)) { throw "test setup failed -- expected the real guide image to exist at $imgPath" }
    $sections = @([PSCustomObject]@{ Header = "TEST SECTION"; ImagePath = $imgPath; Steps = @(@{ Lead = "Step:"; Text = "text" }) })
    Show-DarkGuide -Title "RegressionTestGuideImageTitle" -Tldr "test" -Sections $sections
    try {
        $guideWin = $script:openGuideWindow
        if ($guideWin -eq $null) { throw "expected Show-DarkGuide to track the open window" }
        if ($guideWin.FindName("PageLabel").Text -ne "Page 1 of 2") { throw "expected 'Page 1 of 2' (USAGE + 1 section), got '$($guideWin.FindName('PageLabel').Text)'" }

        $guideWin.FindName("NextButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        if ($guideWin.FindName("PageLabel").Text -ne "Page 2 of 2") { throw "expected Next to advance to 'Page 2 of 2', got '$($guideWin.FindName('PageLabel').Text)'" }
        if (-not $guideWin.FindName("BackButton").IsEnabled) { throw "expected Back enabled once past the first page" }
        if ($guideWin.FindName("NextButton").IsEnabled) { throw "expected Next disabled on the last page" }

        $currentPagePanel = $guideWin.FindName("PageHost").Children[0]
        $imageBorder = $currentPagePanel.Children | Where-Object { $_ -is [System.Windows.Controls.Border] } | Select-Object -First 1
        if ($imageBorder -eq $null) { throw "expected an Image Border on the section's own page" }
        if ($imageBorder.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the image border visible" }
        if ($imageBorder.Child.Source -eq $null) { throw "expected the Image control to have a loaded BitmapImage source" }

        $guideWin.FindName("BackButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        if ($guideWin.FindName("PageLabel").Text -ne "Page 1 of 2") { throw "expected Back to return to 'Page 1 of 2', got '$($guideWin.FindName('PageLabel').Text)'" }
        if ($guideWin.FindName("BackButton").IsEnabled) { throw "expected Back disabled again after returning to the first page" }
    } finally {
        $guideWin.Close()
    }
}

function Set-ObsImageCheckPassed($value) {
    # Bare `$script:obsImageCheckPassed = ...` inside the Tick closure
    # below does NOT reach this file's real script scope -- same
    # .GetNewClosure() isolation gotcha rom_launcher.ps1 itself documents
    # for Set-ConfirmDialogResult/Clear-OpenGuideWindow (confirmed the
    # hard way here too: without this indirection the check silently
    # stayed $false even though the dialog was provably rendering the
    # image correctly).
    $script:obsImageCheckPassed = $value
}

Check "Show-DarkInput's real OBS password prompt image actually renders (ImagePath parameter)" {
    $imgPath = Join-Path $ScriptDir "guide_images\obs_websocket_settings.jpg"
    if (-not (Test-Path $imgPath)) { throw "test setup failed -- expected the real OBS guide image to exist at $imgPath" }
    Set-ObsImageCheckPassed $false
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $dlg = $null
            foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
                if ($src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.Title -eq "RegressionTestObsImageTitle") {
                    $dlg = $src.RootVisual
                    break
                }
            }
            if (-not $dlg) { throw "could not locate the OBS password dialog window to inspect" }
            $border = $dlg.FindName("GuideImageBorder")
            $image = $dlg.FindName("GuideImage")
            if ($border.Visibility -eq [System.Windows.Visibility]::Visible -and $image.Source -ne $null) {
                Set-ObsImageCheckPassed $true
            }
            $dlg.FindName("CancelButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        } finally {
            if ($dlg -and $dlg.IsVisible) { $dlg.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    try {
        Show-DarkInput -Title "RegressionTestObsImageTitle" -Message "test" -ImagePath $imgPath | Out-Null
    } finally {
        $timer.Stop()
    }
    if (-not $script:obsImageCheckPassed) { throw "expected the OBS guide image border/source to be visible/loaded while the dialog was open" }
}

function Set-MayaPortImageCheckPassed($value) {
    # Same GetNewClosure() isolation reasoning as Set-ObsImageCheckPassed above.
    $script:mayaPortImageCheckPassed = $value
}

Check "Show-DarkNotice's real Maya port setup image actually renders (ImagePath parameter)" {
    $imgPath = Join-Path $ScriptDir "guide_images\maya_port_setup.jpg"
    if (-not (Test-Path $imgPath)) { throw "test setup failed -- expected the real Maya port guide image to exist at $imgPath" }
    Set-MayaPortImageCheckPassed $false
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $dlg = $null
            foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
                if ($src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.Title -eq "RegressionTestMayaPortImageTitle") {
                    $dlg = $src.RootVisual
                    break
                }
            }
            if (-not $dlg) { throw "could not locate the Maya port notice window to inspect" }
            $border = $dlg.FindName("GuideImageBorder")
            $image = $dlg.FindName("GuideImage")
            if ($border.Visibility -eq [System.Windows.Visibility]::Visible -and $image.Source -ne $null) {
                Set-MayaPortImageCheckPassed $true
            }
            $dlg.FindName("OkButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        } finally {
            if ($dlg -and $dlg.IsVisible) { $dlg.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    try {
        Show-DarkNotice -Title "RegressionTestMayaPortImageTitle" -Message "test" -ImagePath $imgPath
    } finally {
        $timer.Stop()
    }
    if (-not $script:mayaPortImageCheckPassed) { throw "expected the Maya port guide image border/source to be visible/loaded while the dialog was open" }
}

Check "a two-step fake sequence runs both steps in order and reaches Done" {
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") },
        [PSCustomObject]@{ FilePath = "cmd"; Arguments = @("/c", "echo", "second_step_ran") }
    )
    Start-Steps $fakeSteps
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done (stuck at '$script:runStatus'), log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "second_step_ran") { throw "second step's output never appeared in the log:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "exited with code 0") { throw "expected at least one clean exit logged:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "All steps finished") { throw "missing completion marker:`n$($logBox.Text)" }
}

Check "a step printing CAPTURE_ABORT stops the whole run there -- later steps never execute (design 2026-08-22: never quietly stop)" {
    $script:taskbarsShownCount = 0
    function Show-AllTaskbars { $script:taskbarsShownCount++ }
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "cmd"; Arguments = @("/c", "echo", "CAPTURE_ABORT:", "no", "real", "ROM", "animation", "found") },
        [PSCustomObject]@{ FilePath = "cmd"; Arguments = @("/c", "echo", "should_never_run") }
    )
    Start-Steps $fakeSteps
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done (stuck at '$script:runStatus'), log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "Run aborted:") { throw "expected the abort to be logged loudly, got:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "no real ROM animation found") { throw "expected the actual abort reason text preserved in the log, got:`n$($logBox.Text)" }
    if ($logBox.Text -match "should_never_run") { throw "expected the second step to NEVER run once the first one aborted the whole run, but it did:`n$($logBox.Text)" }
    if ($logBox.Text -match "All steps finished") { throw "an aborted run should not also claim it finished normally:`n$($logBox.Text)" }
    if ($script:taskbarsShownCount -ne 1) { throw "expected an aborted run to restore the Windows taskbar exactly once (it may have been hidden by this run's own first step, with no later step left to un-hide it), got $script:taskbarsShownCount call(s)" }
}

Check "a normal (non-aborted) run completing does NOT call Show-AllTaskbars -- that restore is abort-specific, not unconditional" {
    $script:taskbarsShownCount = 0
    function Show-AllTaskbars { $script:taskbarsShownCount++ }
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") }
    )
    Start-Steps $fakeSteps
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    if ($script:taskbarsShownCount -ne 0) { throw "expected Show-AllTaskbars NOT to be called on a normal completion (Get-CaptureSteps's own paired 'show' step already handles that when relevant), got $script:taskbarsShownCount call(s)" }
}

Check "buttons are re-enabled after the run completes" {
    if (-not $previewButton.IsEnabled) { throw "Preview button should be re-enabled after completion" }
    if (-not $startRecordingButton.IsEnabled) { throw "Capture button should be re-enabled after completion" }
    if (-not $resetButton.IsEnabled) { throw "Reset button should be re-enabled after completion" }
}

Check "a click while a run is already in progress is ignored, not queued/duplicated" {
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "2", "127.0.0.1") }
    )
    Start-Steps $fakeSteps
    Start-Steps $fakeSteps  # should be ignored -- a run is already active
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "already running -- ignoring click") { throw "the duplicate click should have been ignored with a logged message" }
}

Check "idle buttons show their normal labels, not Stop" {
    if ($previewButton.Content -ne "Preview") { throw "Preview button should read its normal label while idle, got '$($previewButton.Content)'" }
    if ($startRecordingButton.Content -ne "Start Recording") { throw "Capture button should read its normal label while idle, got '$($startRecordingButton.Content)'" }
}

Check "Preview and Reset do NOT toggle into Stop -- only Start Recording does, matching OBS's single record toggle" {
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") }
    )
    Start-Steps $fakeSteps
    if ($previewButton.Content -ne "Preview") { throw "Preview must never relabel itself, got '$($previewButton.Content)'" }
    if ($previewButton.IsEnabled) { throw "Preview should just disable like any other inactive button, not stay active/clickable" }
    if ($startRecordingButton.IsEnabled) { throw "Capture should be disabled while an unrelated run (no owning button) is active" }
    Wait-ForStatus "Done" 15 | Out-Null

    Start-Steps $fakeSteps
    if ($resetButton.Content -ne "Reset") { throw "Reset must never relabel itself, got '$($resetButton.Content)'" }
    Wait-ForStatus "Done" 15 | Out-Null
}

Check "clicking Start Recording turns THAT button into Stop Recording and disables the other two" {
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") }
    )
    Start-Steps $fakeSteps $true $startRecordingButton "Stop Recording"
    if ($startRecordingButton.Content -ne "Stop Recording") { throw "expected the specific label 'Stop Recording' (matches OBS's own naming), got '$($startRecordingButton.Content)'" }
    if (-not $startRecordingButton.IsEnabled) { throw "the active button must stay clickable so it can be clicked again to stop" }
    if ($previewButton.IsEnabled) { throw "the other buttons should be disabled while Capture's run is active" }
    if ($resetButton.IsEnabled) { throw "the other buttons should be disabled while Capture's run is active" }
    Wait-ForStatus "Done" 15 | Out-Null
    if ($startRecordingButton.Content -ne "Start Recording") { throw "button should revert to its normal label once the run finishes, got '$($startRecordingButton.Content)'" }
    if (-not $previewButton.IsEnabled -or -not $resetButton.IsEnabled) { throw "the other buttons should re-enable once the run finishes" }
}

Check "Stop Recording kills the running process and runs cleanup, reaching Done again, then the button reverts" {
    # Override the REAL cleanup steps with a harmless fake one for just this
    # check -- Stop-CurrentRun calls Get-StopCleanupSteps by name, and a
    # later same-session redefinition takes effect for that call (ordinary
    # PowerShell late-bound function resolution), so this exercises the
    # REAL Stop-CurrentRun logic without ever touching the real
    # taskbar/OBS/Maya command port from an automated test.
    function Get-StopCleanupSteps {
        param([string]$ScriptDir)
        return @([PSCustomObject]@{ FilePath = "cmd"; Arguments = @("/c", "echo", "fake_cleanup_ran") })
    }

    $longFakeStep = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "30", "127.0.0.1") }
    )
    Start-Steps $longFakeStep $true $startRecordingButton "Stop Recording"

    # Give the process a moment to actually start before trying to stop it.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(300)
    $t.Add_Tick({ $frame.Continue = $false })
    $t.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $t.Stop()

    if ($script:currentProcess -eq $null) { throw "expected a process to be running before Stop" }
    if ($script:currentProcess.HasExited) { throw "the long ping should not have finished on its own yet -- Stop wouldn't be proving anything" }
    if ($startRecordingButton.Content -ne "Stop Recording") { throw "Capture button should read Stop Recording while its run is active" }

    Stop-CurrentRun

    if ($startRecordingButton.Content -ne "Stop Recording") { throw "button should keep reading Stop Recording through the cleanup run, not revert early" }

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done after Stop, log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "STOP requested") { throw "expected the Stop log marker" }
    if ($logBox.Text -notmatch "fake_cleanup_ran") { throw "expected the (fake) cleanup step to have actually run" }
    if ($startRecordingButton.Content -ne "Start Recording") { throw "button should revert to its normal label once cleanup finishes, got '$($startRecordingButton.Content)'" }
    if (-not $previewButton.IsEnabled) { throw "buttons should be re-enabled after Stop's cleanup finishes" }
}

Check "clicking Start Recording a SECOND time while it reads Stop Recording actually stops it (the real click handler's toggle, not just the Stop-CurrentRun function)" {
    $longFakeStep = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "30", "127.0.0.1") }
    )
    Start-Steps $longFakeStep $true $startRecordingButton "Stop Recording"
    if ($startRecordingButton.Content -ne "Stop Recording") { throw "expected Capture button to show Stop Recording after starting its own run" }

    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done after the toggle-click, log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "STOP requested") { throw "clicking the toggled button again should have triggered Stop-CurrentRun" }
}

Check "Start Recording appends a Reset step automatically once the recording finishes naturally (auto-reset, not just Stop's own cleanup)" {
    # Get-CacheStatus mocked too, not just Test-MayaPortReachable: Start
    # Recording sets $script:pendingCacheRefresh, which triggers a REAL
    # Update-CacheStatusIndicator once this run completes (see that
    # feature's own tests above) -- on THIS dev machine Maya is actually
    # reachable, so without this override the completion hook would touch
    # real Maya and leave $cacheStatusLabel/$forceRebuildMenuItem set from
    # a genuine scene check, contaminating whatever test runs next.
    function Test-MayaPortReachable { return $true }
    # Start Recording's own requirements gate (Get-StartRecordingRequirementFailures)
    # also needs these two satisfied, or this click would be blocked with a
    # Show-DarkNotice prompt before ever reaching Get-CaptureClickResult.
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/auto_reset_test.ma"; CachePath = $null; ErrorMessage = $null } }
    # Not testing the frame-gate warning here -- isolate from whatever
    # $script:lastCachePath/zoom/offset a PRIOR test left behind, same
    # reasoning as the Show-DarkConfirm safety-net default above.
    $script:lastCachePath = $null
    $allFramesRadio.IsChecked = $true
    function Get-AnimationRange { return [PSCustomObject]@{ Success = $true; Start = 0; End = 10; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Get-CleanResetStep {
        param([string]$ScriptDir)
        return ,@([PSCustomObject]@{ FilePath = "powershell"; Arguments = @("-Command", "Write-Output auto_reset_ran") })
    }
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "auto_reset_ran") { throw "expected the Reset step to run automatically after the recording finished naturally, log:`n$($logBox.Text)" }
}

Check "Start Recording is blocked with a notice when a requirement isn't met, instead of starting a doomed run" {
    function Test-MayaPortReachable { return $false }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    $script:noticeShownWith = $null
    function Show-DarkNotice { param([string]$Message, [string]$Title) $script:noticeShownWith = $Message }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        throw "Get-CaptureSteps should never be called -- the requirements gate should have stopped this click first"
    }
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:noticeShownWith -eq $null) { throw "expected Show-DarkNotice to be called with the missing-requirements message" }
    if ($script:noticeShownWith -notmatch "Maya connection") { throw "expected the Maya connection failure listed, got '$($script:noticeShownWith)'" }
    if ($script:currentProcess -ne $null) { throw "no run should have started" }
}

Check "clicking Stop with nothing running logs a no-op instead of erroring" {
    Stop-CurrentRun
    if ($logBox.Text -notmatch "nothing running") { throw "expected a 'nothing running' message, got:`n$($logBox.Text)" }
}

Check "All selected explicitly queries and passes the true animation range (regression: used to pass no range at all)" {
    # Behavior change (2026-08-20): "All" used to pass no StartFrame/
    # EndFrame at all, silently trusting whatever Maya's CURRENT
    # playbackOptions minTime/maxTime happened to be -- which could be
    # narrower than the actual animation if the Range Slider had been
    # scrubbed for something unrelated. Now it explicitly queries the true
    # outer animationStartTime/animationEndTime bounds via
    # Get-AnimationRange and passes those through, same as Time Slider
    # already did for its own range.
    function Get-AnimationRange { return [PSCustomObject]@{ Success = $true; Start = 0; End = 3240; ErrorMessage = $null } }
    $allFramesRadio.IsChecked = $true
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
    if ($result.Steps -eq $null) { throw "expected steps to be returned" }
    $obsStep = $result.Steps | Where-Object { $_.Arguments -join " " -like "*maya_obs_capture.ps1*" }
    if ($obsStep.Arguments -join " " -notmatch "-StartFrame 0 -EndFrame 3240") { throw "expected the queried animation range passed through, got: $($obsStep.Arguments -join ' ')" }
}

Check "All selected surfaces an error and does not start if the animation range query fails" {
    function Get-AnimationRange { return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Maya did not respond." } }
    $allFramesRadio.IsChecked = $true
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -eq $null) { throw "expected an error when the animation range query fails" }
    if ($result.Steps -ne $null) { throw "expected no steps when the range query fails" }
}

Check "selecting Start/End enables the frame boxes even if they were left disabled by an earlier run (regression: used to stay stuck disabled)" {
    # Real bug (2026-08-20): IsEnabled on these boxes was previously only
    # ever touched inside Set-ButtonsEnabled, which only runs when a run
    # starts/finishes -- selecting Start/End on its own never re-enabled
    # them. If the LAST time Set-ButtonsEnabled ran was while some OTHER
    # Time Range option was selected, the boxes could stay stuck disabled
    # indefinitely even after switching to Start/End.
    $allFramesRadio.IsChecked = $true
    Set-ButtonsEnabled $true
    if ($startFrameBox.IsEnabled) { throw "test setup: expected the boxes disabled while All is selected, to prove the fix below isn't a no-op" }

    $startEndRadio.IsChecked = $true
    if (-not $startFrameBox.IsEnabled) { throw "expected StartFrameBox to enable immediately on selecting Start/End" }
    if (-not $endFrameBox.IsEnabled) { throw "expected EndFrameBox to enable immediately on selecting Start/End" }
}

Check "Start/End selected with valid numbers passes them through to the OBS step" {
    $startEndRadio.IsChecked = $true
    $startFrameBox.Text = "10"
    $endFrameBox.Text = "50"
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
    $obsStep = $result.Steps | Where-Object { $_.Arguments -join " " -like "*maya_obs_capture.ps1*" }
    $joined = $obsStep.Arguments -join " "
    if ($joined -notmatch "-StartFrame 10") { throw "expected -StartFrame 10 in: $joined" }
    if ($joined -notmatch "-EndFrame 50") { throw "expected -EndFrame 50 in: $joined" }
}

Check "Axis: All shares the Axis radio group, is off by default, and checking it unchecks Front/Back and Left/Right" {
    # Item 4 (All radiobutton). rom_launcher.ps1 never bound LeftRightRadio
    # to a variable (Front/Back vs Left/Right was a binary ternary), so the
    # test looks it up by name.
    if ($window -eq $null) { throw "test setup: expected the dot-sourced launcher's `$window in scope" }
    $leftRightRadio = $window.FindName("LeftRightRadio")
    if ($allAxisRadio -eq $null) { throw "AllAxisRadio was not found in the XAML (FindName returned null)" }
    if ($leftRightRadio -eq $null) { throw "LeftRightRadio was not found in the XAML" }
    if ($allAxisRadio.GroupName -ne "Axis") { throw "expected GroupName 'Axis', got '$($allAxisRadio.GroupName)'" }
    if ($allAxisRadio.Content -ne "All") { throw "expected the label 'All', got '$($allAxisRadio.Content)'" }
    if (-not $frontBackRadio.IsChecked) { throw "Front/Back must stay the default axis" }
    if ($allAxisRadio.IsChecked) { throw "All must not be checked by default" }
    try {
        $allAxisRadio.IsChecked = $true
        if ($frontBackRadio.IsChecked -or $leftRightRadio.IsChecked) { throw "checking All must uncheck the other axis radios (same GroupName)" }
    } finally {
        $frontBackRadio.IsChecked = $true
    }
    if ($allAxisRadio.IsChecked) { throw "re-checking Front/Back must uncheck All" }
}

Check "Axis: All queues both legs (Front/Back then Left/Right) with the same Start/End range on each OBS step; single axes still queue one leg" {
    # Item 4 success criterion: with All checked the click queue equals
    # Front/Back steps + Left/Right steps concatenated -- two independent
    # OBS capture steps = two videos. Uses Start/End (typed numbers, no
    # Maya round trip), same technique as the Start/End test above.
    $leftRightRadio = $window.FindName("LeftRightRadio")
    $startEndRadio.IsChecked = $true
    $startFrameBox.Text = "10"
    $endFrameBox.Text = "50"
    try {
        $allAxisRadio.IsChecked = $true
        $result = Get-CaptureClickResult
        if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
        if (@($result.Steps).Count -ne 12) { throw "expected 12 steps (6 Front/Back + 6 Left/Right), got $(@($result.Steps).Count)" }
        $joinedSteps = @($result.Steps | ForEach-Object { $_.Arguments -join " " })
        if (($joinedSteps[1] -notlike "*maya_camera_panels.py*") -or ($joinedSteps[1] -like "*maya_camera_panels_LR.py*")) { throw "step 1 should be the Front/Back panels script, got: $($joinedSteps[1])" }
        if ($joinedSteps[7] -notlike "*maya_camera_panels_LR.py*") { throw "step 7 should be the Left/Right panels script, got: $($joinedSteps[7])" }
        $obsSteps = @($joinedSteps | Where-Object { $_ -like "*maya_obs_capture.ps1*" })
        if ($obsSteps.Count -ne 2) { throw "expected exactly 2 OBS capture steps (one per leg = two videos), got $($obsSteps.Count)" }
        foreach ($o in $obsSteps) {
            if ($o -notmatch "-StartFrame 10 -EndFrame 50") { throw "each leg's OBS step must carry the same range, got: $o" }
        }

        $frontBackRadio.IsChecked = $true
        $result = Get-CaptureClickResult
        if (@($result.Steps).Count -ne 6) { throw "Front/Back alone must still queue exactly one leg (6 steps), got $(@($result.Steps).Count)" }

        $leftRightRadio.IsChecked = $true
        $result = Get-CaptureClickResult
        if (@($result.Steps).Count -ne 6) { throw "Left/Right alone must still queue exactly one leg (6 steps), got $(@($result.Steps).Count)" }
        if ((@($result.Steps)[1].Arguments -join " ") -notlike "*maya_camera_panels_LR.py*") { throw "Left/Right alone must use the LR panels script" }
    } finally {
        $frontBackRadio.IsChecked = $true
        $allFramesRadio.IsChecked = $true
    }
}

Check "Axis: Preview with All runs ONLY the first leg (Front/Back); single axes unchanged; the cache build still runs both legs" {
    # Item 4 follow-up (user decision 2026-09-24, option b). Each panel
    # script closes all four claude_view_* windows on startup, so an All
    # preview could only ever leave the LAST leg on screen; Preview now runs
    # the first leg only. Hermetic on purpose: Get-CaptureSteps is a
    # recorder returning one harmless ping step, Get-CleanResetStep is a
    # ping too (the real one sends maya_clean_reset.py to whatever Maya is
    # live), Test-MayaPortReachable is $false so the post-run cache refresh
    # takes its early return, and the recenter file/range resolution are
    # redirected -- nothing here touches Maya, OBS or the real state files.
    $leftRightRadio = $window.FindName("LeftRightRadio")
    $script:previewAxesSeen = @()
    $script:recenterFrameTestPath = Join-Path $env:TEMP "rom_launcher_test_preview_axis.txt"
    function Get-RecenterStartFramePath { return $script:recenterFrameTestPath }
    function Get-ResolvedTimeRange { return [PSCustomObject]@{ Success = $true; Start = 0; End = 100; ErrorMessage = $null } }
    function Test-MayaPortReachable { return $false }
    function Show-DarkConfirm { return $true }
    function Get-CleanResetStep { param([string]$ScriptDir) return ,@([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") }) }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        $script:previewAxesSeen += $Axis
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
    try {
        # All -> Preview asks for the FrontBack leg only, and says so in the log.
        $allAxisRadio.IsChecked = $true
        $script:previewAxesSeen = @()
        $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        if (-not (Wait-ForStatus "Done" 15)) { throw "Preview (All) never reached Done, log:`n$($logBox.Text)" }
        if ((@($script:previewAxesSeen) -join ",") -ne "FrontBack") { throw "Preview with All must request ONLY the FrontBack leg, got: '$(@($script:previewAxesSeen) -join ',')'" }
        if ($logBox.Text -notmatch "first leg \(Front/Back\) only") { throw "expected the log to say Preview shows the first leg only, got:`n$($logBox.Text)" }

        # Front/Back alone -> FrontBack, no note.
        $frontBackRadio.IsChecked = $true
        $script:previewAxesSeen = @()
        $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        if (-not (Wait-ForStatus "Done" 15)) { throw "Preview (Front/Back) never reached Done" }
        if ((@($script:previewAxesSeen) -join ",") -ne "FrontBack") { throw "Preview with Front/Back must request FrontBack, got: '$(@($script:previewAxesSeen) -join ',')'" }
        if ($logBox.Text -match "first leg") { throw "the first-leg note must only appear for All, got:`n$($logBox.Text)" }

        # Left/Right alone -> LeftRight, unchanged.
        $leftRightRadio.IsChecked = $true
        $script:previewAxesSeen = @()
        $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        if (-not (Wait-ForStatus "Done" 15)) { throw "Preview (Left/Right) never reached Done" }
        if ((@($script:previewAxesSeen) -join ",") -ne "LeftRight") { throw "Preview with Left/Right must request LeftRight, got: '$(@($script:previewAxesSeen) -join ',')'" }

        # Regression: the cache build with All is UNCHANGED (still both legs).
        $allAxisRadio.IsChecked = $true
        $script:previewAxesSeen = @()
        Confirm-AndBuildCache -DeleteExisting $false
        if (-not (Wait-ForStatus "Done" 15)) { throw "cache build (All) never reached Done, log:`n$($logBox.Text)" }
        if ((@($script:previewAxesSeen) -join ",") -ne "FrontBack,LeftRight") { throw "the cache build with All must still request both legs in order, got: '$(@($script:previewAxesSeen) -join ',')'" }
    } finally {
        $frontBackRadio.IsChecked = $true
        $allFramesRadio.IsChecked = $true
        Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
    }
}

Check "Start/End selected with non-numeric input produces an error, no steps" {
    $startEndRadio.IsChecked = $true
    $startFrameBox.Text = "abc"
    $endFrameBox.Text = "50"
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when input is invalid" }
    if ($result.ErrorMessage -eq $null) { throw "expected an error message for non-numeric input" }
}

Check "Start/End selected with Start greater than End produces an error, no steps" {
    $startEndRadio.IsChecked = $true
    $startFrameBox.Text = "80"
    $endFrameBox.Text = "20"
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when Start > End" }
    if ($result.ErrorMessage -eq $null) { throw "expected an error message for Start > End" }
}

Check "selecting Start/End reveals its Start/End panel; All and Time Slider collapse it" {
    $startEndRadio.IsChecked = $true
    if ($startEndPanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the Start/End panel visible once that radio is selected" }
    $allFramesRadio.IsChecked = $true
    if ($startEndPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the panel collapsed once All is selected instead" }
    $startEndRadio.IsChecked = $true
    if ($startEndPanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the panel visible again once Start/End is re-selected" }
    $timeSliderRadio.IsChecked = $true
    if ($startEndPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the panel collapsed once Time Slider is selected instead" }
    $allFramesRadio.IsChecked = $true
}

Check "Time Slider selected fetches Maya's live range and passes it through to the OBS step" {
    # Overriding Get-TimeSliderRange (same technique already proven for
    # Get-StopCleanupSteps/Get-CaptureSteps) so this exercises the real
    # Get-CaptureClickResult branch without a real Maya round trip.
    function Get-TimeSliderRange { return [PSCustomObject]@{ Success = $true; Start = 25; End = 175; ErrorMessage = $null } }
    $timeSliderRadio.IsChecked = $true
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
    $obsStep = $result.Steps | Where-Object { $_.Arguments -join " " -like "*maya_obs_capture.ps1*" }
    $joined = $obsStep.Arguments -join " "
    if ($joined -notmatch "-StartFrame 25") { throw "expected -StartFrame 25 (from the live query) in: $joined" }
    if ($joined -notmatch "-EndFrame 175") { throw "expected -EndFrame 175 (from the live query) in: $joined" }
    $allFramesRadio.IsChecked = $true
}

Check "Time Slider selected reports an error and produces no steps when Maya doesn't respond" {
    function Get-TimeSliderRange { return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "No response from Maya." } }
    $timeSliderRadio.IsChecked = $true
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when the live query fails" }
    if ($result.ErrorMessage -notmatch "No response from Maya") { throw "expected the underlying error surfaced, got: $($result.ErrorMessage)" }
    $allFramesRadio.IsChecked = $true
}

Check "Time Slider selected reports an error when Maya's own range is invalid (Start > End)" {
    function Get-TimeSliderRange { return [PSCustomObject]@{ Success = $true; Start = 200; End = 50; ErrorMessage = $null } }
    $timeSliderRadio.IsChecked = $true
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when the fetched range is invalid" }
    if ($result.ErrorMessage -eq $null) { throw "expected an error message for an invalid fetched range" }
    $allFramesRadio.IsChecked = $true
}

Check "the cache progress panel is collapsed when no progress file exists" {
    Remove-Item $script:cacheProgressPath -ErrorAction SilentlyContinue
    Update-CacheProgress
    if ($cacheProgressPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the panel collapsed with no progress file present" }
}

Check "Update-CacheProgress shows and populates the panel from a real-format progress file" {
    $lines = @(
        "animation_reference=D:/fake/barM_rom_anim.ma",
        "frames_done=1200",
        "frames_total=3241",
        "percent=37.0"
    )
    Set-Content -Path $script:cacheProgressPath -Value $lines -Encoding UTF8
    Update-CacheProgress
    if ($cacheProgressPanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the panel visible once a progress file exists" }
    if ([Math]::Abs($cacheProgressBar.Value - 37.0) -gt 0.01) { throw "expected ProgressBar.Value 37.0, got $($cacheProgressBar.Value)" }
    if ($cacheProgressLabel.Text -notmatch "1200") { throw "expected frames_done (1200) in the label text, got: $($cacheProgressLabel.Text)" }
    if ($cacheProgressLabel.Text -notmatch "3241") { throw "expected frames_total (3241) in the label text, got: $($cacheProgressLabel.Text)" }
    Remove-Item $script:cacheProgressPath -ErrorAction SilentlyContinue
}

Check "Start-Steps deletes any stale progress file and collapses the panel before a run begins" {
    # Mid-build (done < total), not done=total -- a completed progress file
    # is now collapsed immediately by Update-CacheProgress itself (see
    # ConvertFrom-CacheProgressOutput's IsComplete), so this fixture
    # represents a stale run that was still in flight (e.g. the app was
    # closed mid-build) to actually exercise Start-Steps's own cleanup.
    Set-Content -Path $script:cacheProgressPath -Value @("frames_done=500", "frames_total=999", "percent=50.0") -Encoding UTF8
    Update-CacheProgress
    if ($cacheProgressPanel.Visibility -ne [System.Windows.Visibility]::Visible) { throw "test setup failed -- expected the panel visible before starting a new run" }

    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") }
    )
    Start-Steps $fakeSteps
    if (Test-Path $script:cacheProgressPath) { throw "Start-Steps should delete a stale progress file from a previous run" }
    if ($cacheProgressPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "the panel should collapse immediately at the start of a new run, not carry over the previous run's 100%" }
    Wait-ForStatus "Done" 15 | Out-Null
}

Check "Test-MayaPortReachable returns false quickly for a definitely-closed port" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Test-MayaPortReachable -MayaHost "127.0.0.1" -Port 1 -TimeoutMs 300
    $sw.Stop()
    if ($result -ne $false) { throw "port 1 on localhost should not have anything listening" }
    if ($sw.ElapsedMilliseconds -gt 2000) { throw "took $($sw.ElapsedMilliseconds)ms -- should be bounded well under the OS default timeout" }
}

Check "Test-MayaPortReachable returns true for a port with a real listener" {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $freePort = $listener.LocalEndpoint.Port
    try {
        $result = Test-MayaPortReachable -MayaHost "127.0.0.1" -Port $freePort -TimeoutMs 300
        if ($result -ne $true) { throw "expected true for a port with an active listener" }
    } finally {
        $listener.Stop()
    }
}

Check "Cache action button and status indicator exist with correct idle defaults" {
    # Reset explicitly rather than relying on this being the very first
    # test to ever touch cache state -- several earlier tests in this
    # suite legitimately trigger a real cache-status refresh as a side
    # effect (e.g. Start Recording's completion hook), same reasoning as
    # the Update-PortStatusIndicator test's own $script:lastSceneHasReference
    # reset above. This test verifies the row's genuine idle/unknown
    # resting appearance, not "nothing has ever run since launch."
    $cacheStatusLabel.Text = "Cache: not checked"
    $cacheActionButton.IsEnabled = $true
    $cacheCheckIcon.Visibility = [System.Windows.Visibility]::Visible
    $cacheRefreshIcon.Visibility = [System.Windows.Visibility]::Collapsed

    if ($cacheStatusLabel.Text -notmatch "not checked") { throw "expected the idle 'not checked' label, got '$($cacheStatusLabel.Text)'" }
    if (-not $cacheActionButton.IsEnabled) { throw "Cache action button should be enabled while idle" }
    if ($cacheCheckIcon.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the magnifier glyph visible while idle/unknown" }
    if ($cacheRefreshIcon.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the refresh glyph collapsed while idle/unknown" }
}

Check "Update-CacheStatusIndicator reports Maya-not-reachable without attempting a real cache check" {
    Update-CacheStatusIndicator -Port 1
    if ($cacheStatusLabel.Text -notmatch "not reachable") { throw "expected a 'not reachable' message when Maya's port is closed, got '$($cacheStatusLabel.Text)'" }
    if ($cacheStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Gray) { throw "expected the Cache status dot gray for the not-reachable state, got '$($cacheStatusDot.Fill.Color)'" }
    if (-not $cacheActionButton.IsEnabled) { throw "button should still be enabled/clickable after a not-reachable result, not stuck disabled" }
    if ($forceRebuildMenuItem.IsEnabled) { throw "Force Rebuild should not be enabled when the reachability check itself failed" }
}

Check "Force Rebuild enables (not disables) when the cache check comes back Missing, and the icon swaps to refresh" {
    # Behavior change (2026-08-20): Missing used to leave the rebuild path
    # disabled entirely, on the theory that Preview/Start Recording would
    # silently auto-build it later. Now Missing is actionable too -- the
    # merged Cache button can build a fresh cache (no delete step, see
    # Confirm-AndBuildCache's $DeleteExisting branch) instead of requiring
    # a trip to the Capture tab.
    function Test-MayaPortReachable { return $true }
    function Show-DarkConfirm { return $false }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/anim.ma"; CachePath = $null; ErrorMessage = $null } }
    Update-CacheStatusIndicator
    if (-not $forceRebuildMenuItem.IsEnabled) { throw "Force Rebuild should enable on Missing -- there is a build action available even with nothing to delete" }
    if ($script:lastCachePath -ne $null) { throw "expected no cache path remembered on Missing, got '$($script:lastCachePath)'" }
    if ($script:lastAnimRef -ne "D:/fake/anim.ma") { throw "expected the animation reference remembered even on Missing, got '$($script:lastAnimRef)'" }
    if ($cacheCheckIcon.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "expected the magnifier glyph to hide once a status is actionable" }
    if ($cacheRefreshIcon.Visibility -ne [System.Windows.Visibility]::Visible) { throw "expected the refresh glyph to show once a status is actionable" }
}

Check "Cache button coming back Missing immediately offers to build it (the 'ask permission' behavior)" {
    $script:confirmAndBuildCacheCallArgs = $null
    function Test-MayaPortReachable { return $true }
    function Show-DarkConfirm {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        $script:confirmAndBuildCacheCallArgs = $Message
        return $false
    }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/anim_prompt_test.ma"; CachePath = $null; ErrorMessage = $null } }
    $cacheActionButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:confirmAndBuildCacheCallArgs -eq $null) { throw "expected the Cache button finding Missing to trigger a confirm prompt automatically, but Show-DarkConfirm was never called" }
    if ($script:confirmAndBuildCacheCallArgs -notmatch "anim_prompt_test") { throw "expected the confirm message to name the missing animation reference, got '$($script:confirmAndBuildCacheCallArgs)'" }
    if ($logBox.Text -notmatch "cancelled") { throw "expected a 'cancelled' log message when the auto-offered prompt is declined" }
}

Check "Cache button coming back Exists does NOT auto-prompt (only Missing does)" {
    $script:confirmCalledForExistsTest = $false
    function Test-MayaPortReachable { return $true }
    function Show-DarkConfirm { $script:confirmCalledForExistsTest = $true; return $false }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/anim.ma"; CachePath = "D:/fake/cache.json"; ErrorMessage = $null } }
    $cacheActionButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:confirmCalledForExistsTest) { throw "Exists should not trigger an unsolicited confirm prompt -- only Missing does (use Force Rebuild for that)" }
}

Check "confirming the auto-offered build (from the Cache button finding Missing) starts a build run with no delete step" {
    function Test-MayaPortReachable { return $true }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Show-DarkConfirm { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/anim_build_test.ma"; CachePath = $null; ErrorMessage = $null } }

    $cacheActionButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($logBox.Text -notmatch "Building cache for the first time") { throw "expected a log message confirming a first-time build started, got:`n$($logBox.Text)" }
    if ($logBox.Text -match "Deleted the existing cache") { throw "there was nothing to delete on a Missing result -- the delete-path log message should not appear" }

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
}

Check "Force Rebuild re-checks fresh before acting: a stale Missing state that has since become Exists still builds correctly" {
    # Force Rebuild must never trust $script:lastCachePath/$script:lastAnimRef
    # left over from a PREVIOUS check (e.g. the scene changed in Maya since
    # then) -- it always calls Update-CacheStatusIndicator first. Seeding
    # stale Missing state here and having the (overridden) Get-CacheStatus
    # report Exists on the fresh call proves the fresh result wins, not the
    # seeded one.
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Test-MayaPortReachable { return $true }
    function Show-DarkConfirm { return $true }
    $fakeForceRebuildCachePath = Join-Path $env:TEMP "rom_launcher_test_force_rebuild_stale.json"
    Set-Content -Path $fakeForceRebuildCachePath -Value "fake cache content" -Encoding UTF8
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/anim_direct_rebuild_test.ma"; CachePath = $script:fakeForceRebuildCachePathForTest; ErrorMessage = $null } }
    $script:fakeForceRebuildCachePathForTest = $fakeForceRebuildCachePath

    # Seeded stale state: a PRIOR check found Missing (no path at all).
    $script:lastCachePath = $null
    $script:lastAnimRef = "D:/fake/anim_direct_rebuild_test.ma"
    $script:cacheActionable = $true
    $forceRebuildMenuItem.IsEnabled = $true

    $forceRebuildMenuItem.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    if ($logBox.Text -notmatch "Deleted the existing cache") { throw "expected the FRESH Exists result to drive a delete-and-rebuild, not the stale seeded Missing state, got:`n$($logBox.Text)" }

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    if (Test-Path $fakeForceRebuildCachePath) { throw "confirming should have deleted the fresh cache path" }
}

Check "Force Rebuild enables once the cache check confirms Exists, and remembers the path/reference" {
    function Test-MayaPortReachable { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/barM_rom_anim.ma"; CachePath = "D:/fake/cache/barM__abc123.json"; ErrorMessage = $null } }
    Update-CacheStatusIndicator
    if (-not $forceRebuildMenuItem.IsEnabled) { throw "Force Rebuild should enable once a cache is confirmed to exist" }
    if ($script:lastCachePath -ne "D:/fake/cache/barM__abc123.json") { throw "expected the cache path remembered for the rebuild click handler, got '$($script:lastCachePath)'" }
    if ($script:lastAnimRef -ne "D:/fake/barM_rom_anim.ma") { throw "expected the animation reference remembered too, got '$($script:lastAnimRef)'" }
}

Check "Show-DarkConfirm's real Yes button actually returns true (regression test: GetNewClosure isolates script-scope writes)" {
    # Must run before any later test overrides Show-DarkConfirm -- those
    # overrides are correct for isolating the CALLER's logic but mean none
    # of them ever exercise Show-DarkConfirm's own internal click handling,
    # exactly how a real bug there (found 2026-08-20: the Yes/No handlers
    # wrote `$script:confirmDialogResult` directly inside a
    # .GetNewClosure()'d scriptblock, which silently never reached the
    # real script scope, so the dialog ALWAYS resolved as declined
    # regardless of which button was actually clicked) shipped past 53
    # passing tests. This test calls the REAL Show-DarkConfirm and clicks
    # its REAL Yes button via a DispatcherTimer that fires while
    # ShowDialog()'s nested message loop is pumping -- PresentationSource
    # .CurrentSources (not Application.Current.Windows, which is $null
    # here since this codebase never constructs a System.Windows.
    # Application object) is what finds the shown-but-untracked window.
    #
    # Restores the GENUINE implementation for this scope only -- the suite
    # otherwise runs under a safe stub (see Set-SafeShowDarkConfirmDefault)
    # so a leftover state from an unrelated test can never again pop a
    # real, unattended modal. Handed back in the existing finally below,
    # which runs regardless of outcome, so a failure here can't leave the
    # real (blocking) implementation active for every test after this one.
    ${function:Show-DarkConfirm} = $script:realShowDarkConfirm
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $dlg = $null
            foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
                if ($src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.Title -eq "RegressionTestDialogTitle") {
                    $dlg = $src.RootVisual
                    break
                }
            }
            if (-not $dlg) { throw "could not locate the confirm dialog window to click" }
            $dlg.FindName("YesButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        } finally {
            # Guarantees ShowDialog() below returns even if something
            # above throws, instead of hanging the whole test suite.
            if ($dlg -and $dlg.IsVisible) { $dlg.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    try {
        $result = Show-DarkConfirm -Title "RegressionTestDialogTitle" -Message "test message" -ConfirmLabel "Yes"
    } finally {
        # If Show-DarkConfirm throws before ever reaching ShowDialog(), the
        # tick above never fires and never stops the timer itself -- an
        # orphaned DispatcherTimer keeps ticking on the one shared
        # Dispatcher and can misfire into a LATER, unrelated test's own
        # dispatcher pump. Guaranteeing it stops here, regardless of
        # outcome, is what actually happened and caused exactly that
        # symptom before this try/finally was added.
        $timer.Stop()
        Set-SafeShowDarkConfirmDefault
    }
    if ($result -ne $true) { throw "expected the real Yes button click to resolve the dialog true, got '$result'" }
}

Check "clicking Force Rebuild and declining the confirmation does nothing" {
    function Test-MayaPortReachable { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/barM_rom_anim.ma"; CachePath = $script:fakeCachePathForDeclineTest; ErrorMessage = $null } }
    function Show-DarkConfirm { return $false }

    $script:fakeCachePathForDeclineTest = Join-Path $env:TEMP "rom_launcher_test_decline_cache.json"
    Set-Content -Path $script:fakeCachePathForDeclineTest -Value "fake cache content" -Encoding UTF8
    Update-CacheStatusIndicator

    $forceRebuildMenuItem.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    if (-not (Test-Path $script:fakeCachePathForDeclineTest)) { throw "declining the confirmation must NOT delete the existing cache file" }
    if ($logBox.Text -notmatch "cancelled") { throw "expected a 'cancelled' log message when the confirmation is declined" }
    Remove-Item $script:fakeCachePathForDeclineTest -ErrorAction SilentlyContinue
}

Check "clicking Force Rebuild and confirming deletes the cache file and starts a rebuild run" {
    # Overriding Get-CaptureSteps (same technique already proven for
    # Get-StopCleanupSteps) so the real click handler's call to it returns
    # a harmless fake step instead of ever launching a real
    # send_to_maya.ps1 process against live Maya.
    function Test-MayaPortReachable { return $true }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Show-DarkConfirm { return $true }

    $fakeCachePath = Join-Path $env:TEMP "rom_launcher_test_confirm_cache.json"
    Set-Content -Path $fakeCachePath -Value "fake cache content" -Encoding UTF8
    # Force Rebuild's click handler re-checks fresh before acting (see the
    # staleness test above), so Get-CacheStatus -- not a manually primed
    # $script:lastCachePath/$script:lastAnimRef -- is what actually drives
    # this run.
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/barM_rom_anim.ma"; CachePath = $script:fakeCachePathForConfirmTest; ErrorMessage = $null } }
    $script:fakeCachePathForConfirmTest = $fakeCachePath
    $script:cacheActionable = $true
    $forceRebuildMenuItem.IsEnabled = $true

    $forceRebuildMenuItem.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    # The Cache button's Content is a Grid of icon Canvases, not text --
    # the running-state signal for icon buttons is the Background color
    # swap (see Set-ButtonRunningVisual), not a text swap the way
    # Start Recording still works.
    if ($cacheActionButton.Content -isnot [System.Windows.Controls.Grid]) { throw "expected the icon Grid to still be the button's Content while active, not replaced by text" }
    if ($cacheActionButton.Background.Color -ne [System.Windows.Media.Color]::FromRgb(224, 120, 110)) { throw "expected the Background to swap to the stop-red while the forced rebuild is active, got '$($cacheActionButton.Background)'" }

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    if (Test-Path $fakeCachePath) { throw "confirming the rebuild must delete the existing cache file" }
    if ($logBox.Text -notmatch "Deleted the existing cache") { throw "expected a log message confirming the delete" }
    if ($cacheActionButton.Content -isnot [System.Windows.Controls.Grid]) { throw "expected the icon Grid to still be the button's Content once the rebuild run finishes" }
}

Check "Check Cache finding no scene reference upgrades the Maya connection dot to a warning, not green/red" {
    function Test-MayaPortReachable { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "NoReference"; AnimationReference = $null; CachePath = $null; ErrorMessage = "No file references found in this scene." } }

    Update-CacheStatusIndicator
    if ($script:lastSceneHasReference -ne $false) { throw "expected lastSceneHasReference false after a NoReference result, got '$($script:lastSceneHasReference)'" }
    if ($portStatusDot.Fill.Color -ne [System.Windows.Media.Color]::FromRgb(239, 192, 84)) { throw "expected the Maya connection dot to turn warning-amber on NoReference, got '$($portStatusDot.Fill.Color)'" }
    if ($portStatusLabel.Text -notmatch "wrong scene") { throw "expected the Maya connection label to call out the wrong-scene state, got '$($portStatusLabel.Text)'" }
    if ($cacheStatusLabel.Text -notmatch "no scene reference") { throw "expected the Cache row to admit it has nothing to report, got '$($cacheStatusLabel.Text)'" }

    # The warning must survive the next automatic (cheap, reachability-only)
    # poll tick -- this is the actual point of folding it into the Maya
    # connection row instead of a separate one-shot indicator.
    Update-PortStatusIndicator | Out-Null
    if ($portStatusDot.Fill.Color -ne [System.Windows.Media.Color]::FromRgb(239, 192, 84)) { throw "expected the warning to survive a plain reachability poll, got '$($portStatusDot.Fill.Color)'" }
}

Check "Check Cache finding a scene reference upgrades the Maya connection label to confirm the right scene is loaded" {
    function Test-MayaPortReachable { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/anim_scene_ok_test.ma"; CachePath = $null; ErrorMessage = $null } }

    Update-CacheStatusIndicator
    if ($script:lastSceneHasReference -ne $true) { throw "expected lastSceneHasReference true after a Missing (but resolved) result, got '$($script:lastSceneHasReference)'" }
    if ($portStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected the Maya connection dot to be LimeGreen once a reference is confirmed, got '$($portStatusDot.Fill.Color)'" }
    if ($portStatusLabel.Text -notmatch "ROM scene ready") { throw "expected the Maya connection label to confirm the scene is ready, got '$($portStatusLabel.Text)'" }
    if ($portStatusDot.ToolTip -notmatch "anim_scene_ok_test") { throw "expected the tooltip to name the resolved reference, got '$($portStatusDot.ToolTip)'" }
}

Check "Cache status indicator refreshes automatically once a build triggered via Force Rebuild finishes (regression: used to stay stale)" {
    # Real bug (2026-08-20): a run that built/changed the cache never
    # re-triggered Update-CacheStatusIndicator on its own, so the dot/label
    # kept showing whatever they said BEFORE the run started, even once a
    # fresh cache genuinely existed on disk. See $script:pendingCacheRefresh.
    function Test-MayaPortReachable { return $true }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Show-DarkConfirm { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/anim_refresh_test.ma"; CachePath = "D:/fake/anim_refresh_test_cache.json"; ErrorMessage = $null } }
    $script:cacheActionable = $true
    $forceRebuildMenuItem.IsEnabled = $true
    # Seed an intentionally WRONG "before" label/dot -- distinct from
    # anything Get-CacheStatus above would itself set -- so a passing
    # assertion below can only mean the post-run refresh genuinely ran,
    # not that the check already happened to say the right thing.
    $cacheStatusLabel.Text = "Cache: not built yet"
    $cacheStatusDot.Fill = $script:cacheWarningBrush

    $forceRebuildMenuItem.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }

    if ($cacheStatusLabel.Text -ne "Cache: ready") { throw "expected the Cache status label to auto-refresh to 'Cache: ready' once the build finished, but it stayed '$($cacheStatusLabel.Text)' -- this is the exact bug being fixed" }
    if ($cacheStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected the Cache status dot to auto-refresh to LimeGreen, got '$($cacheStatusDot.Fill.Color)'" }
}

Check "Cache status indicator refreshes after Preview too, not just Rebuild Cache" {
    # Preview/Start Recording can ALSO silently trigger a first-time build
    # (see the guide text) -- the fix needs to cover those paths too, not
    # just the explicit Rebuild Cache button.
    function Test-MayaPortReachable { return $true }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/anim_preview_refresh_test.ma"; CachePath = "D:/fake/anim_preview_refresh_test_cache.json"; ErrorMessage = $null } }
    $cacheStatusLabel.Text = "Cache: not built yet"
    $cacheStatusDot.Fill = $script:cacheWarningBrush

    $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }

    if ($cacheStatusLabel.Text -ne "Cache: ready") { throw "expected Preview finishing to also auto-refresh the Cache status label, but it stayed '$($cacheStatusLabel.Text)'" }
}

Check "Update-PortStatusIndicator sets the dot to a valid color and a matching tooltip" {
    # Reset explicitly -- earlier tests in this suite call
    # Update-CacheStatusIndicator with various Exists/Missing/NoReference
    # results, each of which sets $script:lastSceneHasReference as a side
    # effect (see Update-PortStatusIndicator's own comment on why that
    # state persists across polls by design). This test wants the plain
    # "never checked the scene yet" baseline tooltip, not whatever an
    # earlier test happened to leave behind.
    $script:lastSceneHasReference = $null
    $reachable = Update-PortStatusIndicator
    $fillColor = $portStatusDot.Fill.Color
    if ($reachable) {
        if ($fillColor -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected LimeGreen fill when reachable, got '$fillColor'" }
        if ($portStatusDot.ToolTip -notmatch "will work") { throw "expected a reassuring tooltip when reachable" }
    } else {
        if ($fillColor -ne [System.Windows.Media.Colors]::Red) { throw "expected Red fill when unreachable, got '$fillColor'" }
        if ($portStatusDot.ToolTip -notmatch "open_maya_port.py") { throw "expected the tooltip to point at the fix when unreachable" }
    }
}

Check "clicking Copy port-open snippet puts the real file content on the clipboard and shows a setup guide" {
    $script:mayaPortNoticeShown = $null
    function Show-DarkNotice {
        param([string]$Message, [string]$Title, [string]$ImagePath)
        $script:mayaPortNoticeShown = [PSCustomObject]@{ Title = $Title; Message = $Message; ImagePath = $ImagePath }
    }
    $copySnippetButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $clipboardText = [System.Windows.Clipboard]::GetText()
    if ($clipboardText -notmatch "commandPort") { throw "clipboard should contain the port-open snippet, got: $clipboardText" }
    if ($logBox.Text -notmatch "Copied the port-open snippet") { throw "expected a confirmation message logged after copying" }
    if ($script:mayaPortNoticeShown -eq $null) { throw "expected Show-DarkNotice to be called with Maya port setup steps" }
    if ($script:mayaPortNoticeShown.Message -notmatch "Script Editor") { throw "expected the steps to mention the Script Editor, got: $($script:mayaPortNoticeShown.Message)" }
    if (-not (Test-Path $script:mayaPortNoticeShown.ImagePath)) { throw "expected a real image file at $($script:mayaPortNoticeShown.ImagePath)" }
}

Check "Update-ObsPasswordStatusIndicator reflects a temp config file's real content, never touching the real project file" {
    # Get-ObsConfigFilePath overridden here (same technique proven for
    # Get-CaptureSteps etc.) so this and every following OBS-password test
    # reads/writes a throwaway temp file, never the real
    # d4_rom\scripts\obs_config.txt -- that file holds this machine's REAL
    # OBS WebSocket password, which a test must never overwrite.
    $script:obsConfigTestPath = Join-Path $env:TEMP "rom_launcher_test_obs_config.txt"
    function Get-ObsConfigFilePath { return $script:obsConfigTestPath }

    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue
    Update-ObsPasswordStatusIndicator
    if ($obsPasswordStatusLabel.Text -notmatch "not configured") { throw "expected 'not configured' when no config file exists, got '$($obsPasswordStatusLabel.Text)'" }
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Gray) { throw "expected the OBS status dot gray/dim when not configured, got '$($obsPasswordStatusDot.Fill.Color)'" }

    Set-Content -Path $script:obsConfigTestPath -Value "host: 127.0.0.1`nport: 4455`npassword: a_real_test_password`n" -Encoding UTF8
    Update-ObsPasswordStatusIndicator
    # User report: this dot used to go straight to green the instant SOME
    # password string existed, even a wrong one -- "the auto finding...
    # need to check whether the tools can really access the obs before
    # updating the green signal." A configured-but-unverified password
    # must land on the SAME amber used for "no cache yet" elsewhere
    # ($script:cacheWarningBrush), never green -- green is now earned
    # only by Update-ObsPasswordVerificationIndicator, from a REAL
    # connect+identify handshake result (see the checks below).
    if ($obsPasswordStatusLabel.Text -notmatch "not yet verified") { throw "expected 'not yet verified' once a password is in the file but never checked, got '$($obsPasswordStatusLabel.Text)'" }
    if ($obsPasswordStatusDot.Fill.Color -ne $script:cacheWarningBrush.Color) { throw "expected the OBS status dot amber (unverified), not green, got '$($obsPasswordStatusDot.Fill.Color)'" }
}

Check "Update-ObsPasswordVerificationIndicator turns the dot green only on a REAL successful handshake, red on a confirmed wrong password, and amber (not red) when OBS just isn't reachable to check at all" {
    $script:obsConfigTestPath = Join-Path $env:TEMP "rom_launcher_test_obs_config_verify.txt"
    function Get-ObsConfigFilePath { return $script:obsConfigTestPath }
    Set-Content -Path $script:obsConfigTestPath -Value "host: 127.0.0.1`nport: 4455`npassword: a_real_test_password`n" -Encoding UTF8

    Update-ObsPasswordVerificationIndicator ([PSCustomObject]@{ Success = $true; AuthFailed = $false })
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected green on a real successful handshake, got '$($obsPasswordStatusDot.Fill.Color)'" }
    if ($obsPasswordStatusLabel.Text -notmatch "verified") { throw "expected the label to say 'verified', got '$($obsPasswordStatusLabel.Text)'" }

    Update-ObsPasswordVerificationIndicator ([PSCustomObject]@{ Success = $false; AuthFailed = $true })
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Red) { throw "expected red when OBS was reachable but authentication failed, got '$($obsPasswordStatusDot.Fill.Color)'" }
    if ($obsPasswordStatusLabel.Text -notmatch "incorrect") { throw "expected the label to say the password looks incorrect, got '$($obsPasswordStatusLabel.Text)'" }

    Update-ObsPasswordVerificationIndicator ([PSCustomObject]@{ Success = $false; AuthFailed = $false })
    if ($obsPasswordStatusDot.Fill.Color -ne $script:cacheWarningBrush.Color) { throw "expected amber (not red) when OBS itself isn't reachable -- that's 'can't tell', not 'confirmed wrong', got '$($obsPasswordStatusDot.Fill.Color)'" }
    if ($obsPasswordStatusLabel.Text -notmatch "can't verify") { throw "expected the label to say it can't verify, got '$($obsPasswordStatusLabel.Text)'" }

    # No password configured at all -- must NOT let a stale/incoming
    # check result override Update-ObsPasswordStatusIndicator's own gray.
    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue
    Update-ObsPasswordStatusIndicator
    Update-ObsPasswordVerificationIndicator ([PSCustomObject]@{ Success = $true; AuthFailed = $false })
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Gray) { throw "expected gray to survive when no password is configured at all, got '$($obsPasswordStatusDot.Fill.Color)'" }
}

Check "Update-MonitorList's own real handshake result also drives the OBS password dot, not just the Monitor dropdown" {
    $script:obsConfigTestPath = Join-Path $env:TEMP "rom_launcher_test_obs_config_combined.txt"
    function Get-ObsConfigFilePath { return $script:obsConfigTestPath }
    Set-Content -Path $script:obsConfigTestPath -Value "host: 127.0.0.1`nport: 4455`npassword: a_real_test_password`n" -Encoding UTF8

    function Get-ObsMonitorList {
        return [PSCustomObject]@{ Success = $false; ErrorMessage = "the OBS WebSocket password is incorrect."; Monitors = @(); AuthFailed = $true }
    }
    $script:recordingMonitorNameTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_name_authfail.txt"
    function Get-RecordingMonitorNamePath { return $script:recordingMonitorNameTestPath }
    Remove-Item $script:recordingMonitorNameTestPath -ErrorAction SilentlyContinue

    Update-MonitorList
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Red) { throw "expected Update-MonitorList's own auth-failed result to turn the password dot red, got '$($obsPasswordStatusDot.Fill.Color)'" }
}

Check "Update-MonitorList populates the ComboBox and pre-selects whichever monitor OBS reports as current" {
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true
            ErrorMessage = $null
            Monitors = @(
                [PSCustomObject]@{ Name = "Artist22R Pro (Primary)"; Value = "monitor-a-id"; IsCurrent = $false }
                [PSCustomObject]@{ Name = "LG FHD"; Value = "monitor-b-id"; IsCurrent = $true }
            )
        }
    }
    Update-MonitorList
    if ($monitorComboBox.Items.Count -ne 2) { throw "expected 2 items in the ComboBox, got $($monitorComboBox.Items.Count)" }
    if ($monitorComboBox.SelectedIndex -ne 1) { throw "expected the current monitor (index 1) pre-selected, got index $($monitorComboBox.SelectedIndex)" }
    if ($monitorStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected the Monitor status dot green on success, got '$($monitorStatusDot.Fill.Color)'" }
}

Check "Update-MonitorList shows a clear error, empty/disabled list, when it fails with no last-known monitor on record" {
    $script:recordingMonitorNameTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_name_none.txt"
    function Get-RecordingMonitorNamePath { return $script:recordingMonitorNameTestPath }
    Remove-Item $script:recordingMonitorNameTestPath -ErrorAction SilentlyContinue
    function Get-ObsMonitorList { return [PSCustomObject]@{ Success = $false; ErrorMessage = "No enabled monitor-capture source found in OBS's active scene."; Monitors = @() } }
    Update-MonitorList
    if ($monitorComboBox.Items.Count -ne 0) { throw "expected an empty ComboBox on failure with nothing on record, got $($monitorComboBox.Items.Count) items" }
    if ($monitorComboBox.IsEnabled -ne $false) { throw "expected the ComboBox disabled on failure" }
    if ($monitorStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::Red) { throw "expected the Monitor status dot red on failure, got '$($monitorStatusDot.Fill.Color)'" }
    if ($monitorStatusLabel.Text -notmatch "No enabled monitor-capture source") { throw "expected the error message surfaced in the label, got '$($monitorStatusLabel.Text)'" }
}

Check "Update-MonitorList falls back to the last known monitor, disabled, when OBS can't be reached (design 2026-08-22: detect at launch even without OBS)" {
    $script:recordingMonitorNameTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_name_fallback.txt"
    function Get-RecordingMonitorNamePath { return $script:recordingMonitorNameTestPath }
    Set-Content -Path $script:recordingMonitorNameTestPath -Value "LG FHD: 1920x1080 @ 1920,0" -Encoding UTF8
    function Get-ObsMonitorList { return [PSCustomObject]@{ Success = $false; ErrorMessage = "Could not connect to OBS."; Monitors = @() } }
    Update-MonitorList
    if ($monitorComboBox.Items.Count -ne 1) { throw "expected exactly the last-known monitor shown, got $($monitorComboBox.Items.Count) items" }
    if ($monitorComboBox.Items[0] -notmatch "LG FHD") { throw "expected the last-known monitor name shown, got '$($monitorComboBox.Items[0])'" }
    if ($monitorComboBox.IsEnabled -ne $false) { throw "expected the ComboBox to stay DISABLED until OBS actually confirms -- the user must never pick blind" }
    if ($monitorStatusLabel.Text -notmatch "OBS not running") { throw "expected a clear 'OBS not running' status, got '$($monitorStatusLabel.Text)'" }
    Remove-Item $script:recordingMonitorNameTestPath -ErrorAction SilentlyContinue
}

Check "Update-MonitorList re-enables the ComboBox once OBS answers for real" {
    # Regression guard: a previous failed check must not leave IsEnabled
    # stuck false forever once OBS actually becomes reachable.
    $monitorComboBox.IsEnabled = $false
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @([PSCustomObject]@{ Name = "Only Monitor"; Value = "monitor-only-id"; IsCurrent = $true })
        }
    }
    Update-MonitorList
    if ($monitorComboBox.IsEnabled -ne $true) { throw "expected the ComboBox re-enabled once OBS answered successfully" }
}

Check "populating the ComboBox does NOT itself re-apply to OBS (SelectionChanged suppressed during Update-MonitorList)" {
    # If this guard didn't work, populating the list (which sets
    # SelectedIndex programmatically) would fire SelectionChanged and
    # call Set-ObsMonitorSelection right back at OBS for no reason, on
    # every single startup/refresh.
    $script:setObsMonitorSelectionCallCount = 0
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @([PSCustomObject]@{ Name = "Only Monitor"; Value = "monitor-only-id"; IsCurrent = $true })
        }
    }
    function Set-ObsMonitorSelection { param([string]$MonitorId) $script:setObsMonitorSelectionCallCount++; return "MONITOR_SET_OK" }
    Update-MonitorList
    if ($script:setObsMonitorSelectionCallCount -ne 0) { throw "expected Set-ObsMonitorSelection NOT called while Update-MonitorList itself is populating the list, got $($script:setObsMonitorSelectionCallCount) call(s)" }
}

Check "Write-RecordingMonitorRect writes the parsed rect to disk" {
    # Real bug fixed (2026-08-21): the tracked camera panels used to spawn
    # at a hardcoded monitor rect completely independent of this dropdown
    # -- picking a different monitor moved what OBS recorded but not
    # where the panels actually appeared. This is the write side of the
    # fix; maya_camera_panels.py/_LR.py's own get_secondary_monitor_rect()
    # reads the same file.
    $script:recordingMonitorRectTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_rect.txt"
    function Get-RecordingMonitorRectPath { return $script:recordingMonitorRectTestPath }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue

    Write-RecordingMonitorRect -MonitorName "LG FHD: 1920x1080 @ 1920,0"
    if (-not (Test-Path $script:recordingMonitorRectTestPath)) { throw "expected the rect file to be created" }
    $written = (Get-Content $script:recordingMonitorRectTestPath -Raw).Trim()
    if ($written -ne "1920,0,3840,1080") { throw "expected '1920,0,3840,1080', got '$written'" }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
}

Check "Write-RecordingMonitorRect writes NO byte-order mark (regression: BOM silently broke the Python reader)" {
    # Real bug fixed (2026-08-21): -Encoding UTF8 in Windows PowerShell
    # 5.1 always emits a BOM. maya_camera_panels.py's plain open().read()
    # + int() choked on it (ValueError on the first number), and the
    # try/except around it silently fell back to the OLD hardcoded rect
    # -- so switching monitors in the dropdown APPEARED to do nothing,
    # even though the file itself was being written with the right
    # content the whole time. Only a raw-byte check catches this; a
    # normal Get-Content-based text comparison does not, since PowerShell
    # transparently strips the BOM back out when reading the file as text
    # (which is exactly why this shipped unnoticed the first time).
    $script:recordingMonitorRectTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_rect_bom.txt"
    function Get-RecordingMonitorRectPath { return $script:recordingMonitorRectTestPath }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue

    Write-RecordingMonitorRect -MonitorName "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"
    $bytes = [System.IO.File]::ReadAllBytes($script:recordingMonitorRectTestPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "expected no UTF-8 byte-order-mark at the start of the file, found EF BB BF"
    }
    # First byte should be '0' (0x30), the first digit of "0,0,1920,1080" --
    # proves the content starts immediately, not after a BOM or any other
    # unexpected prefix.
    if ($bytes[0] -ne 0x30) { throw "expected the file to start with ASCII '0' (0x30), got 0x$($bytes[0].ToString('X2'))" }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
}

Check "Write-RecordingMonitorRect logs a warning and does not throw for an unparseable monitor name" {
    $script:recordingMonitorRectTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_rect_unparseable.txt"
    function Get-RecordingMonitorRectPath { return $script:recordingMonitorRectTestPath }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue

    Write-RecordingMonitorRect -MonitorName "Some Unusual Monitor Name"
    if (Test-Path $script:recordingMonitorRectTestPath) { throw "expected no rect file written for an unparseable name" }
    if ($logBox.Text -notmatch "Could not parse a screen rect") { throw "expected a warning logged instead of silently doing nothing" }
}

Check "Update-MonitorList writes the rect for whichever monitor OBS reports as current" {
    $script:recordingMonitorRectTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_rect_initial.txt"
    function Get-RecordingMonitorRectPath { return $script:recordingMonitorRectTestPath }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @(
                [PSCustomObject]@{ Name = "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"; Value = "monitor-a-id"; IsCurrent = $false }
                [PSCustomObject]@{ Name = "LG FHD: 1920x1080 @ 1920,0"; Value = "monitor-b-id"; IsCurrent = $true }
            )
        }
    }
    Update-MonitorList
    $written = (Get-Content $script:recordingMonitorRectTestPath -Raw).Trim()
    if ($written -ne "1920,0,3840,1080") { throw "expected the CURRENT monitor's rect (LG FHD), got '$written'" }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
}

Check "selecting a different monitor in the ComboBox writes ITS rect, following the user's pick" {
    $script:recordingMonitorRectTestPath = Join-Path $env:TEMP "rom_launcher_test_monitor_rect_selection.txt"
    function Get-RecordingMonitorRectPath { return $script:recordingMonitorRectTestPath }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @(
                [PSCustomObject]@{ Name = "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"; Value = "monitor-a-id"; IsCurrent = $true }
                [PSCustomObject]@{ Name = "LG FHD: 1920x1080 @ 1920,0"; Value = "monitor-b-id"; IsCurrent = $false }
            )
        }
    }
    # Confirm dialog answered Yes, verified result shown -- both would
    # otherwise pop a real window and block on Show-DarkConfirm's
    # .ShowDialog() (2026-08-22: user-initiated monitor changes now
    # require confirmation and show a real verified result, see
    # Show-DarkMonitorResult).
    function Show-DarkConfirm { param([string]$Message, [string]$Title, [string]$ConfirmLabel) return $true }
    function Show-DarkMonitorResult { param([string]$Title, [string]$Message, [string]$PreviewPath) }
    function Set-ObsMonitorSelection { param([string]$MonitorId) return [PSCustomObject]@{ Success = $true; Verified = $true; Brightness = 100; Message = "Confirmed showing real content."; PreviewPath = $null } }
    Update-MonitorList
    # Sanity check the initial write (Artist22R Pro, the current one) before switching.
    $writtenBefore = (Get-Content $script:recordingMonitorRectTestPath -Raw).Trim()
    if ($writtenBefore -ne "0,0,1920,1080") { throw "test setup: expected the initial rect for Artist22R Pro, got '$writtenBefore'" }

    # User picks the second monitor (LG FHD) in the dropdown.
    $monitorComboBox.SelectedIndex = 1
    $writtenAfter = (Get-Content $script:recordingMonitorRectTestPath -Raw).Trim()
    if ($writtenAfter -ne "1920,0,3840,1080") { throw "expected the rect to follow the user's new selection (LG FHD), got '$writtenAfter'" }
    Remove-Item $script:recordingMonitorRectTestPath -ErrorAction SilentlyContinue
}

Check "cancelling the change-monitor confirmation reverts the ComboBox and never touches OBS (design 2026-08-22)" {
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @(
                [PSCustomObject]@{ Name = "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"; Value = "monitor-a-id"; IsCurrent = $true }
                [PSCustomObject]@{ Name = "LG FHD: 1920x1080 @ 1920,0"; Value = "monitor-b-id"; IsCurrent = $false }
            )
        }
    }
    Update-MonitorList
    if ($monitorComboBox.SelectedIndex -ne 0) { throw "test setup: expected Artist22R Pro (index 0) pre-selected" }

    $script:setObsMonitorSelectionCallCount = 0
    function Show-DarkConfirm { param([string]$Message, [string]$Title, [string]$ConfirmLabel) return $false }
    function Set-ObsMonitorSelection { param([string]$MonitorId) $script:setObsMonitorSelectionCallCount++; return [PSCustomObject]@{ Success = $true; Verified = $true; Brightness = 100; Message = "should never be called"; PreviewPath = $null } }

    $monitorComboBox.SelectedIndex = 1
    if ($script:setObsMonitorSelectionCallCount -ne 0) { throw "expected Set-ObsMonitorSelection NOT called when the user cancels the confirmation" }
    if ($monitorComboBox.SelectedIndex -ne 0) { throw "expected the ComboBox reverted back to Artist22R Pro (index 0) after Cancel, got index $($monitorComboBox.SelectedIndex)" }
}

Check "confirming a change that OBS applies but can't verify (still black) shows the real, actionable result -- not a blind success" {
    function Get-ObsMonitorList {
        return [PSCustomObject]@{
            Success = $true; ErrorMessage = $null
            Monitors = @(
                [PSCustomObject]@{ Name = "Artist22R Pro: 1920x1080 @ 0,0 (Primary Monitor)"; Value = "monitor-a-id"; IsCurrent = $true }
                [PSCustomObject]@{ Name = "LG FHD: 1920x1080 @ 1920,0"; Value = "monitor-b-id"; IsCurrent = $false }
            )
        }
    }
    Update-MonitorList

    function Show-DarkConfirm { param([string]$Message, [string]$Title, [string]$ConfirmLabel) return $true }
    $script:monitorResultShownWith = $null
    function Show-DarkMonitorResult { param([string]$Title, [string]$Message, [string]$PreviewPath) $script:monitorResultShownWith = $Message }
    function Set-ObsMonitorSelection {
        param([string]$MonitorId)
        return [PSCustomObject]@{ Success = $true; Verified = $false; Brightness = 0; Message = "Still showing a black/empty image (brightness=0). Try DXGI Desktop Duplication."; PreviewPath = "C:\fake\preview.png" }
    }

    $monitorComboBox.SelectedIndex = 1
    if ($monitorComboBox.SelectedIndex -ne 1) { throw "expected the selection to stay on the user's pick even though verification failed -- the OBS-side apply DID happen" }
    if ($script:monitorResultShownWith -eq $null) { throw "expected Show-DarkMonitorResult to be called with the real result" }
    if ($script:monitorResultShownWith -notmatch "DXGI Desktop Duplication") { throw "expected the actionable fix text surfaced to the user, got: $script:monitorResultShownWith" }
}

Check "clicking the Recording Monitor refresh button calls Update-MonitorList with -EnsureRunning, and re-enables the buttons afterward (design 2026-08-22)" {
    $script:refreshCalledWithEnsureRunning = $null
    function Update-MonitorList { param([switch]$EnsureRunning) $script:refreshCalledWithEnsureRunning = [bool]$EnsureRunning }

    $monitorRefreshButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))

    if ($script:refreshCalledWithEnsureRunning -ne $true) { throw "expected the Refresh button to call Update-MonitorList -EnsureRunning" }
    if (-not $previewButton.IsEnabled) { throw "expected other buttons re-enabled once the refresh finished" }
    if (-not $monitorRefreshButton.IsEnabled) { throw "expected the Refresh button itself re-enabled once its own refresh finished" }
}

Check "Write-CameraZoomPct writes the value to disk, no byte-order mark" {
    # Read by get_zoom_pct() in maya_camera_panels.py/_LR.py -- same BOM
    # risk class already fixed for Write-RecordingMonitorRect (a BOM makes
    # Python's float() raise, silently falling back to the 0% default).
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    Write-CameraZoomPct -Value 25
    $bytes = [System.IO.File]::ReadAllBytes($script:cameraZoomPctTestPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "expected no UTF-8 byte-order-mark at the start of the file, found EF BB BF"
    }
    $written = (Get-Content $script:cameraZoomPctTestPath -Raw).Trim()
    if ($written -ne "25") { throw "expected '25', got '$written'" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}


Check "moving the Magnifier slider writes the value and updates the typed-entry box to match" {
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct_slider.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    $zoomSlider.Value = 20
    $written = (Get-Content $script:cameraZoomPctTestPath -Raw).Trim()
    if ($written -ne "20") { throw "expected '20' written for a +20 slider move, got '$written'" }
    if ($zoomValueBox.Text -ne "+20") { throw "expected box '+20', got '$($zoomValueBox.Text)'" }

    $zoomSlider.Value = -15
    $written = (Get-Content $script:cameraZoomPctTestPath -Raw).Trim()
    if ($written -ne "-15") { throw "expected '-15' written for a -15 slider move, got '$written'" }
    if ($zoomValueBox.Text -ne "-15") { throw "expected box '-15', got '$($zoomValueBox.Text)'" }

    $zoomSlider.Value = 0
    if ($zoomValueBox.Text -ne "0") { throw "expected box '0' at the safe default, got '$($zoomValueBox.Text)'" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}

Check "typing a value into the Magnifier box commits it: moves the slider, writes the file, normalizes the display" {
    # This drives Commit-ZoomValueBox directly, the same function BOTH
    # LostFocus and the Enter-key handler call -- a real KeyDown routed
    # event needs a live PresentationSource (only exists once a window has
    # actually been Show()n), which this suite's -NoShow window never has;
    # confirmed live, constructing one throws "Value cannot be null.
    # Parameter name: inputSource". The Enter-key handler itself is just a
    # one-line `if ($e.Key -eq Return) { Commit-ZoomValueBox }` on top of
    # this already-tested function, not independently risky logic.
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct_typed_enter.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    $zoomValueBox.Text = "35"
    Commit-ZoomValueBox

    if ($zoomSlider.Value -ne 35) { throw "expected the typed value to move the slider to 35, got $($zoomSlider.Value)" }
    $written = (Get-Content $script:cameraZoomPctTestPath -Raw).Trim()
    if ($written -ne "35") { throw "expected '35' written after committing the typed box value, got '$written'" }
    if ($zoomValueBox.Text -ne "+35") { throw "expected the box normalized to '+35' after commit, got '$($zoomValueBox.Text)'" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}

Check "typing a value into the Magnifier box and losing focus (Commit-ZoomValueBox) applies it the same way" {
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct_typed_lostfocus.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    # Drives Commit-ZoomValueBox directly rather than raising a real
    # LostFocus event -- WPF only fires LostFocus with real keyboard focus
    # in play, which a headless -NoShow window never has, so this is the
    # same technique already used for other logic-only event handlers in
    # this suite. The KeyDown/Return check above already proves the wiring
    # from a real routed event; this proves the handler's own parsing.
    $zoomValueBox.Text = "-40"
    Commit-ZoomValueBox
    if ($zoomSlider.Value -ne -40) { throw "expected the slider to move to -40, got $($zoomSlider.Value)" }
    $written = (Get-Content $script:cameraZoomPctTestPath -Raw).Trim()
    if ($written -ne "-40") { throw "expected '-40' written, got '$written'" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}

Check "typing an out-of-range value clamps to +/-50, typing garbage reverts to the last valid value" {
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct_typed_invalid.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    $zoomValueBox.Text = "500"
    Commit-ZoomValueBox
    if ($zoomSlider.Value -ne 50) { throw "expected an out-of-range typed value clamped to 50, got $($zoomSlider.Value)" }

    $zoomValueBox.Text = "abc"
    Commit-ZoomValueBox
    if ($zoomSlider.Value -ne 50) { throw "expected garbage input to leave the slider unchanged at 50, got $($zoomSlider.Value)" }
    if ($zoomValueBox.Text -ne "+50") { throw "expected the box reverted to the last valid '+50', got '$($zoomValueBox.Text)'" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}

Check "typing a value with a trailing percent sign is accepted" {
    $script:cameraZoomPctTestPath = Join-Path $env:TEMP "rom_launcher_test_zoom_pct_typed_percent.txt"
    function Get-CameraZoomPctPath { return $script:cameraZoomPctTestPath }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue

    $zoomValueBox.Text = "10%"
    Commit-ZoomValueBox
    if ($zoomSlider.Value -ne 10) { throw "expected '10%' to parse as 10, got $($zoomSlider.Value)" }
    Remove-Item $script:cameraZoomPctTestPath -ErrorAction SilentlyContinue
}

Check "Write-CameraOffsetPx writes 'X,Y' to disk, no byte-order mark" {
    $script:cameraOffsetTestPath = Join-Path $env:TEMP "rom_launcher_test_offset_px.txt"
    function Get-CameraOffsetPxPath { return $script:cameraOffsetTestPath }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue

    Write-CameraOffsetPx -X 25 -Y -10
    $bytes = [System.IO.File]::ReadAllBytes($script:cameraOffsetTestPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "expected no UTF-8 byte-order-mark at the start of the file, found EF BB BF"
    }
    $written = (Get-Content $script:cameraOffsetTestPath -Raw).Trim()
    if ($written -ne "25,-10") { throw "expected '25,-10', got '$written'" }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue
}

Check "committing the X offset box also writes the Y box's current value (shared 'X,Y' file, not a half-updated pair)" {
    $script:cameraOffsetTestPath = Join-Path $env:TEMP "rom_launcher_test_offset_px_combined.txt"
    function Get-CameraOffsetPxPath { return $script:cameraOffsetTestPath }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue
    $offsetXBox.Text = "0"; $offsetYBox.Text = "0"
    $script:lastValidOffsetX = 0; $script:lastValidOffsetY = 0

    $offsetYBox.Text = "40"
    Commit-OffsetBoxes
    $written = (Get-Content $script:cameraOffsetTestPath -Raw).Trim()
    if ($written -ne "0,40") { throw "expected '0,40' after committing just the Y box, got '$written'" }

    $offsetXBox.Text = "-30"
    Commit-OffsetBoxes
    $written = (Get-Content $script:cameraOffsetTestPath -Raw).Trim()
    if ($written -ne "-30,40") { throw "expected '-30,40' (X changed, Y still carried through), got '$written'" }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue
}

Check "invalid input in one offset box reverts just that box, without disturbing the other's valid value" {
    $script:cameraOffsetTestPath = Join-Path $env:TEMP "rom_launcher_test_offset_px_invalid.txt"
    function Get-CameraOffsetPxPath { return $script:cameraOffsetTestPath }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue
    $offsetXBox.Text = "0"; $offsetYBox.Text = "0"
    $script:lastValidOffsetX = 0; $script:lastValidOffsetY = 0

    $offsetXBox.Text = "15"
    Commit-OffsetBoxes
    $offsetXBox.Text = "not a number"
    Commit-OffsetBoxes
    if ($offsetXBox.Text -ne "15") { throw "expected X to revert to its last valid '15', got '$($offsetXBox.Text)'" }
    $written = (Get-Content $script:cameraOffsetTestPath -Raw).Trim()
    if ($written -ne "15,0") { throw "expected '15,0' after reverting garbage input, got '$written'" }
    Remove-Item $script:cameraOffsetTestPath -ErrorAction SilentlyContinue
}

Check "Write-RecenterStartFrame writes the frame number; Clear-RecenterStartFrame writes an empty file (the 'disabled' state)" {
    $script:recenterFrameTestPath = Join-Path $env:TEMP "rom_launcher_test_recenter_frame.txt"
    function Get-RecenterStartFramePath { return $script:recenterFrameTestPath }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue

    Write-RecenterStartFrame -Frame 1500
    $written = (Get-Content $script:recenterFrameTestPath -Raw).Trim()
    if ($written -ne "1500") { throw "expected '1500', got '$written'" }

    Clear-RecenterStartFrame
    $written = (Get-Content $script:recenterFrameTestPath -Raw)
    if ($written.Trim() -ne "") { throw "expected an empty file after Clear-RecenterStartFrame, got '$written'" }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
}

Check "Preview always writes the resolved Start frame (mandatory now, no checkbox)" {
    # Get-CaptureSteps overridden to a harmless ping step, same reasoning
    # as the Start Recording tests -- the REAL one would have Start-Steps
    # (called right after the code under test here) launch a real
    # send_to_maya.ps1 process against whatever Maya session is actually
    # live right now.
    $script:recenterFrameTestPath = Join-Path $env:TEMP "rom_launcher_test_recenter_preview.txt"
    function Get-RecenterStartFramePath { return $script:recenterFrameTestPath }
    function Get-ResolvedTimeRange { return [PSCustomObject]@{ Success = $true; Start = 250; End = 400; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue

    $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    # The recenter file write happens synchronously in the click handler,
    # before Start-Steps -- but still wait for the run to finish so it
    # can't bleed a lingering async process into the next Check.
    Wait-ForStatus "Done" 15 | Out-Null
    $written = (Get-Content $script:recenterFrameTestPath -Raw).Trim()
    if ($written -ne "250") { throw "expected the resolved Start (250) written, got '$written'" }
    # Real bug fixed (2026-09-02): this confirmation used to be logged
    # BEFORE Start-Steps, which clears the log box as one of its own first
    # actions -- the message was silently wiped every time, so nothing
    # ever confirmed a resolved Start frame even on runs where recentering
    # DID apply. User-reported as "the tool didn't calculate my start
    # frame" when the file write (proven above) shows it actually did.
    if ($logBox.Text -notmatch "Recenter at start frame: resolved Start=250") { throw "expected a visible confirmation of the resolved Start frame in the log, got:`n$($logBox.Text)" }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
}

Check "Preview logs a warning and proceeds without recentering when the Time Range can't be resolved (not a hard block)" {
    $script:recenterFrameTestPath = Join-Path $env:TEMP "rom_launcher_test_recenter_preview_fail.txt"
    function Get-RecenterStartFramePath { return $script:recenterFrameTestPath }
    function Get-ResolvedTimeRange { return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "No response from Maya." } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue

    $previewButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Wait-ForStatus "Done" 15 | Out-Null
    if ($logBox.Text -notmatch "previewing without recentering") { throw "expected a warning logged instead of blocking Preview, got:`n$($logBox.Text)" }
    $written = (Get-Content $script:recenterFrameTestPath -Raw)
    if ($written.Trim() -ne "") { throw "expected no recenter frame written when resolution fails, got '$written'" }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
}

Check "Start Recording writes the SAME resolved Start frame Get-CaptureClickResult already found, no second Maya round trip" {
    # Get-CaptureSteps overridden to a single harmless ping step -- same
    # technique as the other Start Recording click tests in this suite
    # (see "Start Recording is blocked..." above) -- the REAL Get-CaptureSteps
    # would build args pointing at send_to_maya.ps1/maya_obs_capture.ps1,
    # which Start-Steps would then actually launch as real processes.
    $script:recenterFrameTestPath = Join-Path $env:TEMP "rom_launcher_test_recenter_start.txt"
    function Get-RecenterStartFramePath { return $script:recenterFrameTestPath }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
    $script:resolveCallCount = 0
    function Get-ResolvedTimeRange {
        $script:resolveCallCount++
        return [PSCustomObject]@{ Success = $true; Start = 700; End = 900; ErrorMessage = $null }
    }
    function Update-PortStatusIndicator { return $true }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    # Not testing the frame-gate warning here -- same isolation as the
    # other Start Recording tests above.
    $script:lastCachePath = $null

    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:resolveCallCount -ne 1) { throw "expected exactly 1 range resolution (shared with Get-CaptureClickResult), got $($script:resolveCallCount)" }
    $written = (Get-Content $script:recenterFrameTestPath -Raw).Trim()
    if ($written -ne "700") { throw "expected the resolved Start (700) written, got '$written'" }

    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done, log so far:`n$($logBox.Text)" }
    # Same bug/fix as Preview's own confirmation message -- see that Check's
    # comment for the full story.
    if ($logBox.Text -notmatch "Recenter at start frame: resolved Start=700") { throw "expected a visible confirmation of the resolved Start frame in the log, got:`n$($logBox.Text)" }
    Remove-Item $script:recenterFrameTestPath -ErrorAction SilentlyContinue
}

Check "Show-DarkInput's real Save button actually returns the typed text (same GetNewClosure class of risk as Show-DarkConfirm)" {
    # This click handler used Set-InputDialogResult (the safe pattern)
    # from the start, unlike Show-DarkConfirm's first version -- but only
    # a real click-through test proves that, the same way only a real
    # click-through test caught Show-DarkConfirm's actual bug. Overriding
    # this function entirely (as later tests do, for speed/isolation)
    # would never exercise this code path at all.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $dlg = $null
            foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
                if ($src.RootVisual -is [System.Windows.Window] -and $src.RootVisual.Title -eq "RegressionTestInputTitle") {
                    $dlg = $src.RootVisual
                    break
                }
            }
            if (-not $dlg) { throw "could not locate the input dialog window to click" }
            $inputBox = $dlg.FindName("InputBox")
            $inputBox.Text = "typed_via_test"
            $dlg.FindName("SaveButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        } finally {
            if ($dlg -and $dlg.IsVisible) { $dlg.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    try {
        $result = Show-DarkInput -Title "RegressionTestInputTitle" -Message "test message" -InitialValue "initial"
    } finally {
        $timer.Stop()
    }
    if ($result -ne "typed_via_test") { throw "expected the real Save button to return the typed text, got '$result'" }
}

Check "clicking the OBS password button, entering a password, and saving writes it to the (temp) config file" {
    # CRITICAL: Get-ObsConfigFilePath must be overridden HERE, in THIS
    # block, not just once in an earlier one -- confirmed empirically
    # (2026-08-20) that a bare `function Name {...}` defined inside one
    # Check block's scriptblock does NOT persist into a later, separate
    # Check block invocation (each is its own child scope). Only
    # $script:-scoped VARIABLES persist that way; function overrides do
    # not. Getting this wrong here once already caused a REAL write to
    # the actual project's real obs_config.txt, silently replacing this
    # machine's real OBS password with a test string -- caught and fixed
    # immediately, but the fix belongs here, permanently, not just in the
    # incident.
    function Get-ObsConfigFilePath { return $script:obsConfigTestPath }
    function Show-DarkInput { return "clicked_and_saved_password" }
    # Saving the password now also triggers Update-MonitorList -EnsureRunning
    # (2026-08-22 design: launch OBS right after setup) -- without this
    # mock the click handler would make a REAL obs_monitor.ps1 subprocess
    # call against whatever OBS state actually exists on this machine,
    # up to a real ~60s wait, corrupting this and any later test in the
    # same run (confirmed the hard way: this exact omission cascaded into
    # a wall of unrelated failures elsewhere in this file).
    $script:updateMonitorListCalledWithEnsureRunning = $null
    function Update-MonitorList { param([switch]$EnsureRunning) $script:updateMonitorListCalledWithEnsureRunning = [bool]$EnsureRunning }
    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue

    $obsPasswordButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))

    if ($script:updateMonitorListCalledWithEnsureRunning -ne $true) { throw "expected saving the password to trigger Update-MonitorList -EnsureRunning" }
    if (-not (Test-Path $script:obsConfigTestPath)) { throw "expected the temp config file to be created" }
    $written = Get-Content $script:obsConfigTestPath -Raw
    if ($written -notmatch "password:\s*clicked_and_saved_password") { throw "expected the new password written to the file, got: $written" }
    if ($logBox.Text -notmatch "OBS WebSocket password updated") { throw "expected a confirmation log message" }
    if ($obsPasswordStatusLabel.Text -notmatch "password set") { throw "expected the status label to refresh to 'password set' immediately after saving" }
    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue
}

Check "cancelling the OBS password dialog leaves the (temp) config file untouched" {
    # Same reminder as above: the override must be redefined in this
    # block too, not inherited from an earlier one.
    function Get-ObsConfigFilePath { return $script:obsConfigTestPath }
    function Show-DarkInput { return $null }
    # Defensive, matching the save-password test's own mock -- Cancel
    # returns before reaching Update-MonitorList today, but this keeps
    # the test from silently starting to make real OBS calls if that
    # ever changes.
    function Update-MonitorList { param([switch]$EnsureRunning) }
    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue

    $obsPasswordButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))

    if (Test-Path $script:obsConfigTestPath) { throw "cancelling must not create/write the config file" }
    if ($logBox.Text -notmatch "OBS password edit cancelled") { throw "expected a cancellation log message" }
    Remove-Item $script:obsConfigTestPath -ErrorAction SilentlyContinue
}

Check "Invoke-ResetOnClose fires the Reset step when idle, but not while a run is still active" {
    # Pulled out of Window.Add_Closing into its own function specifically
    # so this is testable at all -- WPF's Closing event does not reliably
    # fire for a Window that was never actually Shown, which is exactly
    # this -NoShow test harness's own setup.
    $script:resetOnCloseStartProcessCalls = @()
    function Get-CleanResetStep {
        param([string]$ScriptDir)
        return ,@([PSCustomObject]@{ FilePath = "fake_reset.exe"; Arguments = @("-arg1") })
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle)
        $script:resetOnCloseStartProcessCalls += $FilePath
    }

    $script:currentProcess = $null
    Invoke-ResetOnClose
    if ($script:resetOnCloseStartProcessCalls.Count -ne 1) { throw "expected Reset to fire once while idle, got $($script:resetOnCloseStartProcessCalls.Count) call(s)" }
    if ($script:resetOnCloseStartProcessCalls[0] -ne "fake_reset.exe") { throw "expected the Reset step's own FilePath used, got '$($script:resetOnCloseStartProcessCalls[0])'" }

    $script:resetOnCloseStartProcessCalls = @()
    $script:currentProcess = New-Object System.Diagnostics.Process
    try {
        Invoke-ResetOnClose
        if ($script:resetOnCloseStartProcessCalls.Count -ne 0) { throw "expected Reset to be skipped while a run is still active, got $($script:resetOnCloseStartProcessCalls.Count) call(s)" }
    } finally {
        $script:currentProcess = $null
    }
}

# --- Live-tune controls (2026-09-08 revision) -------------------------
# Per-box drag (X/Y), hover-gated arrow-key nudge, deferred zoom-slider
# push, and Reset -- all funnel into $script:pendingNudgeDeltaX/Y /
# $pendingZoomPush, flushed by Invoke-LiveApplyTick. Isolated to a
# throwaway offset file, same convention as every other Write-Camera*
# function above.
$script:liveTuneOffsetPath = Join-Path $env:TEMP "rom_launcher_test_livetune_offset.txt"
function Get-CameraOffsetPxPath { return $script:liveTuneOffsetPath }
function Reset-LiveTuneTestState {
    $script:lastValidOffsetX = 0
    $script:lastValidOffsetY = 0
    $script:dragBoxAxis = $null
    $script:dragCurrentValue = 0.0
    $script:arrowNudgeActive = $false
    $script:zoomSliderDragging = $false
    $script:pendingNudgeDeltaX = 0.0
    $script:pendingNudgeDeltaY = 0.0
    $script:pendingZoomPush = $false
    $script:liveApplyProcess = $null
    $offsetXBox.Text = "0"
    $offsetYBox.Text = "0"
    $zoomSlider.Value = 0
    # The assignment above can itself trigger ValueChanged (a real change
    # from whatever the previous test left it at) and set pendingZoomPush
    # -- clear it again AFTER, not just before, so this reset is truly clean.
    $script:pendingZoomPush = $false
    Remove-Item $script:liveTuneOffsetPath -ErrorAction SilentlyContinue
}

Check "Commit-OffsetBoxes pushes a live nudge delta matching the change; invalid input pushes nothing" {
    Reset-LiveTuneTestState
    $offsetXBox.Text = "42"
    $offsetYBox.Text = "-15"
    Commit-OffsetBoxes
    if ($script:pendingNudgeDeltaX -ne 42) { throw "expected pending X delta 42, got $($script:pendingNudgeDeltaX)" }
    if ($script:pendingNudgeDeltaY -ne -15) { throw "expected pending Y delta -15, got $($script:pendingNudgeDeltaY)" }

    $script:pendingNudgeDeltaX = 0.0
    $script:pendingNudgeDeltaY = 0.0
    $offsetXBox.Text = "not a number"
    Commit-OffsetBoxes
    if ($script:pendingNudgeDeltaX -ne 0) { throw "invalid input must push a zero delta (revert, not a change), got $($script:pendingNudgeDeltaX)" }
}

Check "a single zoom slider VALUE CHANGE (not a drag) applies immediately" {
    Reset-LiveTuneTestState
    $zoomSlider.Value = 15
    if (-not $script:pendingZoomPush) { throw "expected an immediate pendingZoomPush for a non-drag value change" }
}

Check "zoom slider drag is deferred: no push while dragging, exactly one push on DragCompleted" {
    Reset-LiveTuneTestState
    $script:zoomSliderDragging = $true
    $zoomSlider.Value = 20   # simulates a ValueChanged tick mid-drag
    if ($script:pendingZoomPush) { throw "expected the push suppressed while a drag is in progress" }
    $dragCompletedArgs = New-Object System.Windows.Controls.Primitives.DragCompletedEventArgs(0, 0, $false)
    $dragCompletedArgs.RoutedEvent = [System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent
    $zoomSlider.RaiseEvent($dragCompletedArgs)
    if ($script:zoomSliderDragging) { throw "expected dragging flag cleared after DragCompleted" }
    if (-not $script:pendingZoomPush) { throw "expected exactly one push once the drag completes" }
}

Check "Update/Stop-OffsetWheelNudge on X: no live push mid-scroll, one push with the TOTAL delta once settled" {
    Reset-LiveTuneTestState
    # Ten scroll-up notches (positive Delta): no push until Stop (matching
    # the settle-timer firing after 400ms of no further scrolling).
    for ($i = 1; $i -le 10; $i++) { Update-OffsetWheelNudge -Axis "X" -Delta 120 -ShiftHeld $false }
    if ($script:pendingNudgeDeltaX -ne 0) { throw "expected NO live push while still mid-scroll, got $($script:pendingNudgeDeltaX)" }
    if ($offsetXBox.Text -ne "100") { throw "expected OffsetXBox to display '100' live during the scroll, got '$($offsetXBox.Text)'" }
    Stop-OffsetWheelNudge
    if ($script:pendingNudgeDeltaX -ne 100) { throw "expected exactly one pending delta of 100 once settled, got $($script:pendingNudgeDeltaX)" }
    if ($script:lastValidOffsetX -ne 100) { throw "expected committed offset X = 100, got $($script:lastValidOffsetX)" }
    $written = (Get-Content $script:liveTuneOffsetPath -Raw).Trim()
    if ($written -ne "100,0") { throw "expected the offset file to hold '100,0' once settled, got '$written'" }
}

Check "scrolling down is negative, Shift = 100px per notch, Y-axis scroll never touches X" {
    Reset-LiveTuneTestState
    Update-OffsetWheelNudge -Axis "X" -Delta -120 -ShiftHeld $false
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne -10) { throw "expected -10 from a single scroll-down notch, got $($script:lastValidOffsetX)" }

    Reset-LiveTuneTestState
    Update-OffsetWheelNudge -Axis "Y" -Delta 120 -ShiftHeld $true
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne 100) { throw "expected +100 from a single Shift+scroll-up notch, got $($script:lastValidOffsetY)" }
    if ($script:lastValidOffsetX -ne 0) { throw "a Y-axis scroll must never touch X, got $($script:lastValidOffsetX)" }
}

Check "Stop-OffsetWheelNudge is a no-op when no scroll session is active" {
    Reset-LiveTuneTestState
    Stop-OffsetWheelNudge
    if ($script:pendingNudgeDeltaX -ne 0 -or $script:pendingNudgeDeltaY -ne 0) { throw "expected no pending delta without an active scroll session" }
}

Check "switching axis mid-scroll flushes the prior axis's session first, not mixing them" {
    Reset-LiveTuneTestState
    Update-OffsetWheelNudge -Axis "X" -Delta 120 -ShiftHeld $false
    Update-OffsetWheelNudge -Axis "X" -Delta 120 -ShiftHeld $false
    Update-OffsetWheelNudge -Axis "Y" -Delta 120 -ShiftHeld $false   # switches axis -- must flush X's 2-notch session
    if ($script:lastValidOffsetX -ne 20) { throw "expected X's session flushed at 20 before Y started, got $($script:lastValidOffsetX)" }
    if ($script:pendingNudgeDeltaX -ne 20) { throw "expected X's flushed delta to already be pending, got $($script:pendingNudgeDeltaX)" }
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne 10) { throw "expected Y's own session to commit separately, got $($script:lastValidOffsetY)" }
}

Check "arrow nudge: plain arrow = 10px, Shift+arrow = 100px, unrelated key is a no-op, deferred until Stop-ArrowNudge" {
    Reset-LiveTuneTestState
    Start-ArrowNudge
    if (-not (Update-ArrowNudge -Key ([System.Windows.Input.Key]::Right) -ShiftHeld $false)) { throw "expected Right arrow to be handled" }
    if ($script:lastValidOffsetX -ne 10) { throw "expected +10 from a plain Right arrow, got $($script:lastValidOffsetX)" }
    if ($script:pendingNudgeDeltaX -ne 0) { throw "expected NO live push while the key is still held (before Stop-ArrowNudge), got $($script:pendingNudgeDeltaX)" }

    if (-not (Update-ArrowNudge -Key ([System.Windows.Input.Key]::Up) -ShiftHeld $true)) { throw "expected Shift+Up to be handled" }
    if ($script:lastValidOffsetY -ne 100) { throw "expected +100 from Shift+Up, got $($script:lastValidOffsetY)" }

    if (Update-ArrowNudge -Key ([System.Windows.Input.Key]::A) -ShiftHeld $false) { throw "expected an unrelated key to be a no-op (return false)" }
    if ($script:lastValidOffsetX -ne 10 -or $script:lastValidOffsetY -ne 100) { throw "an unrelated key must not change the offset" }

    Stop-ArrowNudge
    if ($script:pendingNudgeDeltaX -ne 10 -or $script:pendingNudgeDeltaY -ne 100) { throw "expected the whole held-key session's total (10, 100) pushed exactly once on release, got ($($script:pendingNudgeDeltaX), $($script:pendingNudgeDeltaY))" }
}

Check "Test-ArrowNudgeKey identifies exactly the 4 arrow keys" {
    foreach ($k in @([System.Windows.Input.Key]::Left, [System.Windows.Input.Key]::Right, [System.Windows.Input.Key]::Up, [System.Windows.Input.Key]::Down)) {
        if (-not (Test-ArrowNudgeKey $k)) { throw "expected $k to be recognized as an arrow-nudge key" }
    }
    if (Test-ArrowNudgeKey ([System.Windows.Input.Key]::Space)) { throw "expected an unrelated key to NOT be recognized" }
}

Check "Reset button zeroes Zoom/X/Y and applies immediately" {
    Reset-LiveTuneTestState
    $zoomSlider.Value = 30
    $offsetXBox.Text = "25"; $offsetYBox.Text = "-8"
    Commit-OffsetBoxes
    $script:pendingNudgeDeltaX = 0.0; $script:pendingNudgeDeltaY = 0.0; $script:pendingZoomPush = $false

    $resetFrameOffsetsButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))

    if ($zoomSlider.Value -ne 0) { throw "expected zoom reset to 0, got $($zoomSlider.Value)" }
    if ($offsetXBox.Text -ne "0" -or $offsetYBox.Text -ne "0") { throw "expected X/Y boxes reset to 0, got X='$($offsetXBox.Text)' Y='$($offsetYBox.Text)'" }
    if (-not $script:pendingZoomPush) { throw "expected the reset to apply live immediately (zoom)" }
    if ($script:pendingNudgeDeltaX -ne -25 -or $script:pendingNudgeDeltaY -ne 8) { throw "expected the reset to apply live immediately (offset delta back to 0), got ($($script:pendingNudgeDeltaX), $($script:pendingNudgeDeltaY))" }
}

Check "Invoke-LiveApplyTick coalesces pending state into exactly one send per tick, zoom before nudge" {
    Reset-LiveTuneTestState
    $script:liveApplySendCalls = @()
    function Send-CameraLiveScript { param([string]$ScriptName); $script:liveApplySendCalls += $ScriptName }
    $nudgeDeltaPath = Join-Path $ScriptDir "..\d4_anim_sample\_camera_nudge_delta.txt"
    Remove-Item $nudgeDeltaPath -ErrorAction SilentlyContinue

    # Several raw updates land between ticks -- must coalesce to ONE send,
    # using the LATEST accumulated total, not one send per update.
    $script:pendingNudgeDeltaX = 3.0
    $script:pendingNudgeDeltaX += 4.0
    $script:pendingNudgeDeltaY = 1.0
    Invoke-LiveApplyTick
    if ($script:liveApplySendCalls.Count -ne 1) { throw "expected exactly 1 send for coalesced nudge deltas, got $($script:liveApplySendCalls.Count)" }
    if ($script:liveApplySendCalls[0] -ne "maya_camera_live_nudge.py") { throw "expected the nudge script to be sent" }
    if ($script:pendingNudgeDeltaX -ne 0 -or $script:pendingNudgeDeltaY -ne 0) { throw "expected pending deltas cleared after the send" }
    $writtenDelta = (Get-Content $nudgeDeltaPath -Raw).Trim()
    if ($writtenDelta -ne "7,1") { throw "expected the coalesced delta '7,1' written before the send, got '$writtenDelta'" }
    Remove-Item $nudgeDeltaPath -ErrorAction SilentlyContinue

    # Zoom beats nudge when both are pending at once.
    $script:liveApplySendCalls = @()
    $script:pendingNudgeDeltaX = 5.0
    $script:pendingZoomPush = $true
    Invoke-LiveApplyTick
    if ($script:liveApplySendCalls.Count -ne 1) { throw "expected exactly 1 send even with 2 things pending, got $($script:liveApplySendCalls.Count)" }
    if ($script:liveApplySendCalls[0] -ne "maya_camera_live_zoom.py") { throw "expected zoom to take priority, got $($script:liveApplySendCalls[0])" }
    if ($script:pendingNudgeDeltaX -ne 5.0) { throw "nudge delta should still be pending -- only one thing is sent per tick" }

    # A send genuinely still "in flight" (a real, not-yet-exited process)
    # must block the tick entirely -- nothing sent, nothing cleared. Set a
    # FRESH pending push here rather than relying on the previous section's
    # (which Invoke-LiveApplyTick already consumed/cleared on its own send).
    $script:liveApplySendCalls = @()
    $script:pendingZoomPush = $true
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ping"
    $psi.Arguments = "-n 30 127.0.0.1"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:liveApplyProcess = [System.Diagnostics.Process]::Start($psi)
    try {
        Invoke-LiveApplyTick
        if ($script:liveApplySendCalls.Count -ne 0) { throw "expected no send while a previous one is still in flight, got $($script:liveApplySendCalls.Count)" }
        if (-not $script:pendingZoomPush) { throw "pending zoom push must remain pending while blocked" }
    } finally {
        $script:liveApplyProcess.Kill()
        $script:liveApplyProcess.WaitForExit(2000) | Out-Null
        $script:liveApplyProcess = $null
    }
}

Reset-LiveTuneTestState

# --- Frame-gate warning (2026-09-08) ----------------------------------
# Get-FrameGateEffectiveOverflowPct mirrors maya_camera_panels.py's
# compute_effective_overflow_pct entirely locally -- verify it against a
# synthetic cache file with a KNOWN x_width, not the real project cache,
# so the expected value can be hand-derived exactly (no MARGIN_PX_MIN-style
# clamp involved in this particular formula, unlike compute_margin_px's
# vertical margin -- confirmed by re-reading the Python source before
# trusting this).
$script:frameGateTestCachePath = Join-Path $env:TEMP "rom_launcher_test_frame_gate_cache.json"
$script:frameGateTestRectPath = Join-Path $env:TEMP "rom_launcher_test_frame_gate_rect.txt"
function Get-RecordingMonitorRectPath { return $script:frameGateTestRectPath }

function Reset-FrameGateTestState {
    # max_w=200, panel width=1000 (rect 0..1000,0..1080 -> colWidth=500 for
    # 2 views -- use a rect that yields a round colWidth for easy hand math).
    # frames/x_center/z_center/z_width added (2026-09-28) for the Frame gate
    # OFF clipping-estimate tests below -- x_width kept EXACTLY as before so
    # the pre-existing ON-mode (Get-FrameGateEffectiveOverflowPct) tests
    # above stay byte-identical (Q-ON). x_center=[0,0,0,100] with
    # x_width=[150,180,200,120]: at zoom0/offset0 (neededOrtho=212.5,
    # halfOrtho=106.25) frames 0-2 all fit (widest pose, by design, always
    # fits at zero drift/zero offset); frame 3's pose has drifted to
    # center=100 with half-width=60, edges [40,160] vs allowed [-106.25,
    # 106.25] -> overflow=53.75 -> P=25% (1 of 4 frames), W=53.75/212.5*100
    # = 25.294...% ~ 25.3%. z_width kept tiny (10 throughout) so Left/Right
    # never clips in this shared fixture -- isolates the Front/Back-only
    # math cleanly; a dedicated small-array test below exercises Get-
    # ClippingEstimateCore directly (no files at all) for the "All picks
    # the worse axis" case, since mixing that into this shared per-file
    # fixture would need a second cache entirely.
    Set-Content -Path $script:frameGateTestRectPath -Value "0,0,1000,1080" -Encoding ASCII
    @{ frames = @(0,1,2,3); x_width = @(150, 180, 200, 120); x_center = @(0,0,0,100); z_width = @(10,10,10,10); z_center = @(0,0,0,0) } | ConvertTo-Json | Set-Content -Path $script:frameGateTestCachePath -Encoding UTF8
    $script:lastCachePath = $script:frameGateTestCachePath
    $script:cachedFrameArrays = $null   # invalidate the memoized parse -- a PRIOR test may have cached a DIFFERENT path/array under the same variable
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 0
    $previewButton.Effect = $null
    # Isolation (2026-09-28): a PRIOR test could leave this unchecked --
    # every existing Check in this section assumes gate ON (it tests the
    # ON-mode path exclusively), and the new OFF-mode Checks below always
    # set it explicitly themselves, so this default matters only as a
    # defensive reset, same philosophy as zeroing zoom/offset above.
    $frameGateCheckBox.IsChecked = $true
}

Check "Get-FrameGateEffectiveOverflowPct returns null when no cache path is known" {
    $script:lastCachePath = $null
    if ((Get-FrameGateEffectiveOverflowPct) -ne $null) { throw "expected null with no cache path" }
    $script:lastCachePath = Join-Path $env:TEMP "rom_launcher_test_frame_gate_nonexistent.json"
    if ((Get-FrameGateEffectiveOverflowPct) -ne $null) { throw "expected null when the cache path doesn't actually exist" }
}

Check "Get-FrameGateEffectiveOverflowPct matches a hand-derived value at zero offset/zoom" {
    Reset-FrameGateTestState
    # neededOrtho = (200 / (1 - 2*0.02)) * 1.02 = (200/0.96)*1.02 = 212.5
    # finalOrtho (zoom=0) = 212.5
    # effective = (1 - (200*1.02/212.5))/2 = (1 - 0.96)/2 = 0.02 (= base, as expected at zero offset)
    $result = Get-FrameGateEffectiveOverflowPct
    if ([Math]::Abs($result - 0.02) -gt 1e-6) { throw "expected 0.02 at zero offset/zoom, got $result" }
}

Check "Get-FrameGateEffectiveOverflowPct reduces correctly with a nonzero offset" {
    Reset-FrameGateTestState
    $script:lastValidOffsetX = 40
    # worldPerPx = finalOrtho / colWidth = 212.5 / 500 = 0.425
    # offsetWorld = 40 * 0.425 = 17
    # expected = 0.02 - 17/212.5 = 0.02 - 0.08 = -0.06 -> clamped to 0
    $result = Get-FrameGateEffectiveOverflowPct
    if ([Math]::Abs($result - 0.0) -gt 1e-6) { throw "expected 0 (clamped) with a 40px offset on this synthetic frame, got $result" }
}

Check "Get-FrameGateEffectiveOverflowPct: small offset reduces proportionally, not clamped" {
    Reset-FrameGateTestState
    $script:lastValidOffsetX = 5
    # offsetWorld = 5 * 0.425 = 2.125; expected = 0.02 - 2.125/212.5 = 0.02 - 0.01 = 0.01
    $result = Get-FrameGateEffectiveOverflowPct
    if ([Math]::Abs($result - 0.01) -gt 1e-6) { throw "expected 0.01, got $result" }
}

Check "Update-FrameGateGlow: no effect when healthy, amber when tight, red at zero" {
    Reset-FrameGateTestState
    Update-FrameGateGlow
    if ($previewButton.Effect -ne $null) { throw "expected no glow at the healthy default (0px offset)" }

    # 5px lands exactly on the half-of-base boundary (0.01); use 6px to be
    # unambiguously inside the amber zone rather than testing an edge case.
    $script:lastValidOffsetX = 6
    Update-FrameGateGlow
    if ($previewButton.Effect -eq $null) { throw "expected an amber glow when tolerance drops below half the base" }
    if ($previewButton.Effect.Color.R -ne 239) { throw "expected the amber color (R=239), got R=$($previewButton.Effect.Color.R)" }

    $script:lastValidOffsetX = 40   # clamped to 0 per the earlier test
    Update-FrameGateGlow
    if ($previewButton.Effect -eq $null) { throw "expected a red glow at the zero floor" }
    if ($previewButton.Effect.Color.R -ne 224) { throw "expected the red color (R=224), got R=$($previewButton.Effect.Color.R)" }
}

Check "Start Recording's frame-gate check only prompts at the zero-tolerance floor, and respects Cancel" {
    Reset-FrameGateTestState
    function Test-MayaPortReachable { return $true }
    function Update-PortStatusIndicator { return $true }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    # Get-CacheStatus mocked too, not just Test-MayaPortReachable -- SAME
    # underlying bug as the auto-reset test far above this one (search "Get-
    # CacheStatus mocked too"): Start Recording sets $script:pendingCache
    # Refresh, whose completion hook calls a REAL Update-CacheStatusIndicator
    # once the healthy-state run below finishes. THAT function unconditionally
    # resets $script:lastCachePath to $null before even looking at the
    # result (see its own source, ~line 1108), then only its "Exists" branch
    # repopulates it from $result.CachePath -- so unlike the auto-reset
    # test's own "Missing" mock (which doesn't care about lastCachePath),
    # THIS test needs "Exists" with CachePath pointed at the SAME synthetic
    # cache Reset-FrameGateTestState already wrote, so the reset-then-
    # repopulate round-trips back to the same value instead of leaving it
    # null. Confirmed live (2026-09-28, with a real Maya reachable on port
    # 7001): without any override here, the unmocked REAL Get-CacheStatus
    # returns the REAL project cache, silently replacing $script:lastCachePath
    # mid-test -- the zero-tolerance assertion below then flaked to "got 0
    # confirm calls" because Get-FrameGateEffectiveOverflowPct read the wrong
    # cache's max_w. This was the pre-existing non-hermetic test the task
    # called out by name.
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/frame_gate_test.ma"; CachePath = $script:frameGateTestCachePath; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    $script:frameGateConfirmCalls = 0
    function Show-DarkConfirm {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        $script:frameGateConfirmCalls++
        return $false   # Cancel
    }

    # Healthy state: no prompt at all, run proceeds.
    $script:lastValidOffsetX = 0
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 10
    if (-not $reachedDone) { throw "expected the healthy-state run to complete without any prompt, log:`n$($logBox.Text)" }
    if ($script:frameGateConfirmCalls -ne 0) { throw "expected zero confirm calls in the healthy state, got $($script:frameGateConfirmCalls)" }

    # Zero-tolerance state + Cancel: prompted, and the run must NOT start.
    $script:lastValidOffsetX = 40
    $script:currentProcess = $null
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:frameGateConfirmCalls -ne 1) { throw "expected exactly 1 confirm call at the zero-tolerance floor, got $($script:frameGateConfirmCalls)" }
    if ($script:currentProcess -ne $null) { throw "Cancel must abort before Start-Steps ever runs" }
}

Check "Start Recording's frame-gate check proceeds when the user clicks Continue Anyway" {
    Reset-FrameGateTestState
    function Test-MayaPortReachable { return $true }
    function Update-PortStatusIndicator { return $true }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    # See the previous Check's own comment ("Get-CacheStatus mocked too")
    # for the full explanation -- same hermetic fix needed here.
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/frame_gate_test.ma"; CachePath = $script:frameGateTestCachePath; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Show-DarkConfirm {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        return $true   # Continue Anyway
    }
    $script:lastValidOffsetX = 40

    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 10
    if (-not $reachedDone) { throw "expected the run to proceed after Continue Anyway, log:`n$($logBox.Text)" }
}

# --- Frame gate OFF: clipping estimator (2026-09-28) -------------------
# Get-ClippingEstimateCore is pure math (no files, no WPF) -- tested
# directly on hand-derived arrays first; Get-ClippingEstimate (the file-
# reading wrapper) is then tested through the SAME Reset-FrameGateTestState
# fixture the ON-mode tests above already use, hand-derived independently
# below rather than trusting the source's own formula (see that function's
# comment for the numbers: neededOrtho=(200/0.96)*1.02=212.5, halfOrtho=
# 106.25 at zoom0).

Check "Get-ClippingEstimateCore: no overflow anywhere -> 0%/0%" {
    $result = Get-ClippingEstimateCore -CenterX @(0.0, 0.0, 0.0) -WidthX @(10.0, 10.0, 10.0) -CamPosX 0.0 -HalfOrtho 100.0 -StartIndex 0 -EndIndex 2
    if ([Math]::Abs($result.PercentClipped - 0.0) -gt 1e-6) { throw "expected 0% clipped, got $($result.PercentClipped)" }
    if ([Math]::Abs($result.WorstOverflowPct - 0.0) -gt 1e-6) { throw "expected 0% worst overflow, got $($result.WorstOverflowPct)" }
}

Check "Get-ClippingEstimateCore: one frame drifts past the fixed frame edge -> hand-derived P/W" {
    # frame width = 2*50 = 100. Frames 0-2 sit at center=0 (half-width 5,
    # inside +/-50 -- never clips). Frame 3 drifts to center=100, half=5 ->
    # edges [95,105] vs allowed [-50,50] -> right overflow = 105-50 = 55.
    # P = 1/4 = 25%. W = 55/100*100 = 55% exactly -- clean round numbers,
    # deliberately chosen so there is no rounding ambiguity to hide a bug.
    $result = Get-ClippingEstimateCore -CenterX @(0.0, 0.0, 0.0, 100.0) -WidthX @(10.0, 10.0, 10.0, 10.0) -CamPosX 0.0 -HalfOrtho 50.0 -StartIndex 0 -EndIndex 3
    if ([Math]::Abs($result.PercentClipped - 25.0) -gt 1e-6) { throw "expected 25% clipped, got $($result.PercentClipped)" }
    if ([Math]::Abs($result.WorstOverflowPct - 55.0) -gt 1e-6) { throw "expected 55% worst overflow, got $($result.WorstOverflowPct)" }
}

Check "Get-ClippingEstimate: FrontBack/LeftRight/All wired to the right cache arrays (hand-derived)" {
    Reset-FrameGateTestState
    # Front/Back (x): frame 3 (center=100, half-width=60) vs allowed
    # [-106.25, 106.25] -> overflow 53.75 -> P=25%, W=53.75/212.5*100 =
    # 25.294...%. Left/Right (z): all centers 0, half-width 5, never
    # clips -> P=0%, W=0%. All picks the pair with the larger W, i.e.
    # Front/Back here (25.3 > 0).
    $fb = Get-ClippingEstimate -Axis FrontBack -ZoomPct 0 -OffsetXPx 0
    if ([Math]::Abs($fb.PercentClipped - 25.0) -gt 0.1) { throw "FrontBack: expected P=25, got $($fb.PercentClipped)" }
    if ([Math]::Abs($fb.WorstOverflowPct - 25.2941) -gt 0.1) { throw "FrontBack: expected W~25.29, got $($fb.WorstOverflowPct)" }

    $lr = Get-ClippingEstimate -Axis LeftRight -ZoomPct 0 -OffsetXPx 0
    if ([Math]::Abs($lr.PercentClipped - 0.0) -gt 1e-6) { throw "LeftRight: expected P=0, got $($lr.PercentClipped)" }
    if ([Math]::Abs($lr.WorstOverflowPct - 0.0) -gt 1e-6) { throw "LeftRight: expected W=0, got $($lr.WorstOverflowPct)" }

    $all = Get-ClippingEstimate -Axis All -ZoomPct 0 -OffsetXPx 0
    if ([Math]::Abs($all.PercentClipped - $fb.PercentClipped) -gt 1e-6 -or [Math]::Abs($all.WorstOverflowPct - $fb.WorstOverflowPct) -gt 1e-6) {
        throw "All: expected to match FrontBack (the worse axis pair) exactly, got P=$($all.PercentClipped) W=$($all.WorstOverflowPct)"
    }
}

Check "Get-ClippingEstimate: a resolved range narrows the window AND moves the reference frame" {
    Reset-FrameGateTestState
    # Range [1,2]: excludes frame 3 (the only clipping frame) entirely, and
    # re-anchors camPosX on frame 1's own center (still 0 here) -- expect a
    # clean healthy 0%/0% result even though the UNBOUNDED whole-take call
    # above found 25% clipped.
    $ranged = Get-ClippingEstimate -Axis FrontBack -ZoomPct 0 -OffsetXPx 0 -RangeStart 1 -RangeEnd 2
    if ([Math]::Abs($ranged.PercentClipped - 0.0) -gt 1e-6) { throw "expected 0% clipped when the clipping frame is outside the range, got $($ranged.PercentClipped)" }
}

# --- Frame gate OFF: glow (none/amber/red) ------------------------------
$script:frameGateGlowTestCachePath = Join-Path $env:TEMP "rom_launcher_test_frame_gate_glow_cache.json"
function Set-FrameGateGlowTestCache([double]$Frame1CenterX) {
    # max_w=10 -> neededOrtho=(10/0.96)*1.02=10.625, halfOrtho=5.3125,
    # frameWidth=10.625. Frame 0 always sits at center=0 (half=5, inside
    # +/-5.3125 -- never clips, a safety margin so shifting frame 1 alone
    # cleanly isolates each case). z arrays kept flat/tiny (never clips) --
    # this test only exercises the Front/Back axis.
    @{ frames = @(0,1); x_width = @(10.0, 10.0); x_center = @(0.0, $Frame1CenterX); z_width = @(10.0, 10.0); z_center = @(0.0, 0.0) } |
        ConvertTo-Json | Set-Content -Path $script:frameGateGlowTestCachePath -Encoding UTF8
    $script:lastCachePath = $script:frameGateGlowTestCachePath
    $script:cachedFrameArrays = $null   # invalidate the memo -- see Get-CachedFrameArrays
}

Check "Update-FrameGateGlow (gate OFF): no glow when healthy, amber when tight, red past 2% worst overflow" {
    Reset-FrameGateTestState
    $frameGateCheckBox.IsChecked = $false
    $frontBackRadio.IsChecked = $true
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 0

    # Healthy: frame 1 at center=0, same as frame 0 -- never clips.
    Set-FrameGateGlowTestCache -Frame1CenterX 0.0
    Update-FrameGateGlow
    if ($previewButton.Effect -ne $null) { throw "expected no glow when healthy (gate OFF, no clipping), got a glow" }
    if ($previewButton.ToolTip -match "Frame gate OFF") { throw "expected the normal Preview tooltip when there is nothing to warn about, got '$($previewButton.ToolTip)'" }

    # Amber: frame 1 at center=0.5 -> overflow 0.1875 -> W=1.7647...% (0-2%).
    Set-FrameGateGlowTestCache -Frame1CenterX 0.5
    Update-FrameGateGlow
    if ($previewButton.Effect -eq $null) { throw "expected an amber glow at ~1.76% worst overflow" }
    if ($previewButton.Effect.Color.R -ne 239) { throw "expected the amber color (R=239), got R=$($previewButton.Effect.Color.R)" }
    if ($previewButton.ToolTip -notmatch "Frame gate OFF -- estimated clipping: 50% of frames, worst 1\.8% of frame width\.") { throw "unexpected tooltip wording: '$($previewButton.ToolTip)'" }

    # Red: frame 1 at center=2 -> overflow 1.6875 -> W=15.88...% (>2%).
    Set-FrameGateGlowTestCache -Frame1CenterX 2.0
    Update-FrameGateGlow
    if ($previewButton.Effect -eq $null) { throw "expected a red glow past 2% worst overflow" }
    if ($previewButton.Effect.Color.R -ne 224) { throw "expected the red color (R=224), got R=$($previewButton.Effect.Color.R)" }
    if ($previewButton.ToolTip -notmatch "Frame gate OFF -- estimated clipping: 50% of frames, worst 15\.9% of frame width\.") { throw "unexpected tooltip wording: '$($previewButton.ToolTip)'" }

    Remove-Item $script:frameGateGlowTestCachePath -ErrorAction SilentlyContinue
}

Check "Frame gate checkbox writes _camera_frame_gate.txt on toggle (Success Criterion 1)" {
    $testGatePath = Join-Path $env:TEMP "rom_launcher_test_frame_gate_state.txt"
    function Get-FrameGatePath { return $testGatePath }
    Remove-Item $testGatePath -ErrorAction SilentlyContinue

    $frameGateCheckBox.IsChecked = $true
    if ((Get-Content $testGatePath -Raw).Trim() -ne "1") { throw "expected '1' after checking, got '$((Get-Content $testGatePath -Raw))'" }
    $frameGateCheckBox.IsChecked = $false
    if ((Get-Content $testGatePath -Raw).Trim() -ne "0") { throw "expected '0' after unchecking, got '$((Get-Content $testGatePath -Raw))'" }
    $frameGateCheckBox.IsChecked = $true
    if ((Get-Content $testGatePath -Raw).Trim() -ne "1") { throw "expected '1' after re-checking, got '$((Get-Content $testGatePath -Raw))'" }
    Remove-Item $testGatePath -ErrorAction SilentlyContinue
}

Check "Update-FrameGateGlow: ON path is untouched by the OFF branch (Q-ON regression)" {
    # Guards against a future edit accidentally routing the ON path through
    # the new OFF estimator -- re-runs the ORIGINAL ON-mode assertions
    # (same numbers as the pre-existing "Update-FrameGateGlow: no effect
    # when healthy..." Check above) with the gate explicitly ON.
    Reset-FrameGateTestState
    $frameGateCheckBox.IsChecked = $true
    Update-FrameGateGlow
    if ($previewButton.Effect -ne $null) { throw "ON path: expected no glow at the healthy default" }
    $script:lastValidOffsetX = 40
    Update-FrameGateGlow
    if ($previewButton.Effect -eq $null -or $previewButton.Effect.Color.R -ne 224) { throw "ON path: expected the red zero-floor glow, got $($previewButton.Effect)" }
    if ($previewButton.ToolTip -match "Frame gate OFF") { throw "ON path: tooltip must not show the OFF wording, got '$($previewButton.ToolTip)'" }
}

# --- Frame gate OFF: Start Recording's clipping prompt ------------------
Check "Start Recording (gate OFF): only prompts past 2% worst overflow, and respects Cancel" {
    Reset-FrameGateTestState
    $frameGateCheckBox.IsChecked = $false
    $frontBackRadio.IsChecked = $true
    $allFramesRadio.IsChecked = $true
    function Get-AnimationRange { return [PSCustomObject]@{ Success = $true; Start = 0; End = 3; ErrorMessage = $null } }
    function Test-MayaPortReachable { return $true }
    function Update-PortStatusIndicator { return $true }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/frame_gate_test.ma"; CachePath = $script:frameGateTestCachePath; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    $script:offClipConfirmCalls = 0
    function Show-DarkConfirm {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        $script:offClipConfirmCalls++
        return $false   # Cancel
    }

    # Healthy axis (Left/Right on this fixture never clips): no prompt.
    (Get-Variable -Name window -Scope Script -ValueOnly).FindName("LeftRightRadio").IsChecked = $true
    $script:currentProcess = $null
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 10
    if (-not $reachedDone) { throw "expected the healthy-axis (Left/Right) run to complete without any prompt, log:`n$($logBox.Text)" }
    if ($script:offClipConfirmCalls -ne 0) { throw "expected zero confirm calls on the non-clipping axis, got $($script:offClipConfirmCalls)" }

    # Clipping axis (Front/Back, W~25.3% > 2%): prompted, run must NOT start.
    $frontBackRadio.IsChecked = $true
    $script:currentProcess = $null
    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:offClipConfirmCalls -ne 1) { throw "expected exactly 1 confirm call on the clipping axis, got $($script:offClipConfirmCalls)" }
    if ($script:currentProcess -ne $null) { throw "Cancel must abort before Start-Steps ever runs" }
}

Check "Start Recording (gate OFF): proceeds and logs the estimate when the user clicks Continue Anyway" {
    Reset-FrameGateTestState
    $frameGateCheckBox.IsChecked = $false
    $frontBackRadio.IsChecked = $true
    $allFramesRadio.IsChecked = $true
    function Get-AnimationRange { return [PSCustomObject]@{ Success = $true; Start = 0; End = 3; ErrorMessage = $null } }
    function Test-MayaPortReachable { return $true }
    function Update-PortStatusIndicator { return $true }
    function Get-ObsPasswordStatus { return [PSCustomObject]@{ Configured = $true } }
    function Test-RecordingMonitorSelected { return $true }
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Exists"; AnimationReference = "D:/fake/frame_gate_test.ma"; CachePath = $script:frameGateTestCachePath; ErrorMessage = $null } }
    function Get-CaptureSteps {
        param([string]$Axis, [bool]$Recording, [string]$ScriptDir, $StartFrame, $EndFrame)
        return @([PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") })
    }
    function Show-DarkConfirm {
        param([string]$Message, [string]$Title, [string]$ConfirmLabel = "Confirm")
        return $true   # Continue Anyway
    }

    $startRecordingButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $reachedDone = Wait-ForStatus "Done" 10
    if (-not $reachedDone) { throw "expected the run to proceed after Continue Anyway, log:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "Frame gate OFF: fixed camera, estimated clipping 25% of frames \(worst 25\.3% of frame width\)\.") { throw "expected the estimate log line, got:`n$($logBox.Text)" }
}

# --- Tolerance box (2026-09-29, Part 3 -- override plumbing step) -------

Check "Tolerance box starts at Auto; Commit-ToleranceValueBox writes/clamps/reverts/clears correctly" {
    $testTolPath = Join-Path $env:TEMP "rom_launcher_test_tolerance_state.txt"
    function Get-CameraTolerancePctPath { return $testTolPath }
    Remove-Item $testTolPath -ErrorAction SilentlyContinue

    # Default state (matches the startup-reset block): Auto, no file written yet.
    $toleranceValueBox.Text = "Auto"
    $script:lastValidTolerancePct = $null

    # Typing a valid in-range number writes it and normalizes the display text.
    $toleranceValueBox.Text = "5.5"
    Commit-ToleranceValueBox
    if ((Get-Content $testTolPath -Raw).Trim() -ne "5.5") { throw "expected '5.5' written, got '$((Get-Content $testTolPath -Raw))'" }
    if ($toleranceValueBox.Text -ne "5.5") { throw "expected display text '5.5', got '$($toleranceValueBox.Text)'" }

    # Out-of-range clamps (both directions).
    $toleranceValueBox.Text = "27"
    Commit-ToleranceValueBox
    if ((Get-Content $testTolPath -Raw).Trim() -ne "20") { throw "expected clamp to 20, got '$((Get-Content $testTolPath -Raw))'" }
    $toleranceValueBox.Text = "-4"
    Commit-ToleranceValueBox
    if ((Get-Content $testTolPath -Raw).Trim() -ne "0") { throw "expected clamp to 0, got '$((Get-Content $testTolPath -Raw))'" }

    # Unparseable garbage reverts to the last valid value, does not touch the file.
    $beforeGarbage = (Get-Content $testTolPath -Raw).Trim()
    $toleranceValueBox.Text = "not a number"
    Commit-ToleranceValueBox
    if ($toleranceValueBox.Text -ne $beforeGarbage) { throw "expected revert to '$beforeGarbage', got '$($toleranceValueBox.Text)'" }
    if ((Get-Content $testTolPath -Raw).Trim() -ne $beforeGarbage) { throw "garbage input must not touch the file" }

    # "Auto"/blank clears -- writes an EMPTY file, not the text "Auto".
    $toleranceValueBox.Text = "Auto"
    Commit-ToleranceValueBox
    if ((Get-Content $testTolPath -Raw).Trim() -ne "") { throw "expected an empty file for Auto, got '$((Get-Content $testTolPath -Raw))'" }
    $toleranceValueBox.Text = "3"
    Commit-ToleranceValueBox
    $toleranceValueBox.Text = ""
    Commit-ToleranceValueBox
    if ((Get-Content $testTolPath -Raw).Trim() -ne "") { throw "expected blank input to also clear to an empty file, got '$((Get-Content $testTolPath -Raw))'" }
    if ($toleranceValueBox.Text -ne "Auto") { throw "expected display text to normalize blank back to 'Auto', got '$($toleranceValueBox.Text)'" }

    Remove-Item $testTolPath -ErrorAction SilentlyContinue
    $toleranceValueBox.Text = "Auto"
    $script:lastValidTolerancePct = $null
}

Check "Get-ClippingWarningThresholdPct: Auto is 2.0, a manual Tolerance value overrides it (Q4: reuse)" {
    $testTolPath = Join-Path $env:TEMP "rom_launcher_test_tolerance_threshold.txt"
    function Get-CameraTolerancePctPath { return $testTolPath }
    Remove-Item $testTolPath -ErrorAction SilentlyContinue

    if ((Get-ClippingWarningThresholdPct) -ne 2.0) { throw "expected Auto (no file) to give the default 2.0 threshold" }
    Set-Content -Path $testTolPath -Value "8" -Encoding ASCII
    if ((Get-ClippingWarningThresholdPct) -ne 8.0) { throw "expected a manual value to override the default threshold" }

    Remove-Item $testTolPath -ErrorAction SilentlyContinue
}

Check "Get-FrameGateEffectiveOverflowPct: a manual Tolerance value bypasses the zoom/offset formula entirely" {
    Reset-FrameGateTestState
    $testTolPath = Join-Path $env:TEMP "rom_launcher_test_tolerance_bypass.txt"
    function Get-CameraTolerancePctPath { return $testTolPath }
    Remove-Item $testTolPath -ErrorAction SilentlyContinue

    # Auto first -- confirms this test's Reset-FrameGateTestState fixture still
    # gives the SAME pre-existing ON-mode number as the ORIGINAL (Q-ON) test
    # above, i.e. this new function's Auto path is unaffected by its own edit.
    $zoomSlider.Value = 0
    $autoResult = Get-FrameGateEffectiveOverflowPct

    # A manual value must return EXACTLY manual/100, regardless of zoom --
    # tries a zoom level far enough to change the Auto answer, to prove this
    # is a real bypass and not a coincidence.
    Set-Content -Path $testTolPath -Value "6.5" -Encoding ASCII
    $zoomSlider.Value = 30
    $manualResult = Get-FrameGateEffectiveOverflowPct
    if ([Math]::Abs($manualResult - 0.065) -gt 1e-9) { throw "expected exactly 0.065 with manual=6.5, got $manualResult" }
    if ($manualResult -eq $autoResult) { throw "test setup should have made Auto and manual disagree -- got the same value" }

    Remove-Item $testTolPath -ErrorAction SilentlyContinue
    $zoomSlider.Value = 0
}

# --- Tolerance readout (2026-09-29, Part 3 step 3) -----------------------
# Validated against the REAL barM cache and the approved proposal's own
# replica tables (d4_rom_final_proposals.md sec.3 evidence table + sec.4
# trade-off table) -- these numbers were independently derived BEFORE this
# readout was ever built (the proposal predates it), and the G+B algorithm
# itself is already live-Maya-verified (gap 2, this same session). The
# readout's own design deliberately never touches Maya (same "no round
# trip needed" principle as the pre-existing glow) -- so matching these
# real-cache, previously-live-verified numbers through Get-Tolerance
# ReadoutEstimate's pure-PowerShell path is the correct-scoped verification
# for THIS specific new code, not a live Maya run that has nothing to
# exercise.
$script:realBarmCachePath = Join-Path $ScriptDir "..\d4_anim_sample\barM_rom_anim__c1af6ac5752e.json"

function Set-RealBarmCacheState {
    Set-Content -Path $script:frameGateTestRectPath -Value "1920,0,3840,1080" -Encoding ASCII
    $script:lastCachePath = $script:realBarmCachePath
    $script:cachedFrameArrays = $null
}

Check "Get-ToleranceReadoutEstimate reproduces the approved proposal's zoom20/offset20 replica table (T=0/2/5/10/15) on the real barM cache" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 20
    $script:lastValidOffsetX = 20
    # replica: keys / frames-over-T / worst-overflow, from d4_rom_final_proposals.md sec.4
    $expected = @{
        0  = @{ Keys = 480; OverT = 44.6; Worst = 20.7 }
        2  = @{ Keys = 395; OverT = 35.7; Worst = 17.9 }
        5  = @{ Keys = 298; OverT = 16.5; Worst = 15.7 }
        10 = @{ Keys = 111; OverT = 11.4; Worst = 12.1 }
        15 = @{ Keys = 70;  OverT = 10.4; Worst = 17.1 }
    }
    foreach ($t in $expected.Keys) {
        $result = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct ([double]$t)
        $exp = $expected[$t]
        if ($result.Keys -ne $exp.Keys) { throw "T=$t%: expected $($exp.Keys) keys, got $($result.Keys)" }
        if ([Math]::Abs($result.PercentOverTolerance - $exp.OverT) -gt 0.1) { throw "T=$t%: expected $($exp.OverT)% over tolerance, got $($result.PercentOverTolerance)" }
        if ([Math]::Abs($result.WorstOverflowPct - $exp.Worst) -gt 0.1) { throw "T=$t%: expected $($exp.Worst)% worst overflow, got $($result.WorstOverflowPct)" }
    }
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 0
}

Check "Get-ToleranceReadoutEstimate reproduces the approved proposal's zoom0/offset20 replica row (T=0/2/5/10/15) on the real barM cache" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 20
    # replica: d4_rom_final_proposals.md sec.4 trade-off table, second row
    $expected = @{
        0  = @{ Keys = 97; OverT = 11.8; Worst = 2.1 }
        2  = @{ Keys = 70; OverT = 11.1; Worst = 4.1 }
        5  = @{ Keys = 30; OverT = 7.0;  Worst = 7.1 }
        10 = @{ Keys = 14; OverT = 2.5;  Worst = 12.1 }
        15 = @{ Keys = 8;  OverT = 2.3;  Worst = 17.1 }
    }
    foreach ($t in $expected.Keys) {
        $result = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct ([double]$t)
        $exp = $expected[$t]
        if ($result.Keys -ne $exp.Keys) { throw "zoom0 T=$t%: expected $($exp.Keys) keys, got $($result.Keys)" }
        if ([Math]::Abs($result.PercentOverTolerance - $exp.OverT) -gt 0.1) { throw "zoom0 T=$t%: expected $($exp.OverT)% over tolerance, got $($result.PercentOverTolerance)" }
        if ([Math]::Abs($result.WorstOverflowPct - $exp.Worst) -gt 0.1) { throw "zoom0 T=$t%: expected $($exp.Worst)% worst overflow, got $($result.WorstOverflowPct)" }
    }
    $script:lastValidOffsetX = 0
}

Check "Get-ToleranceReadoutEstimate Auto matches Get-FrameGateEffectiveOverflowPct's own zoom-only formula (regression: readout's Auto path is not a second, diverging formula)" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 20
    $script:lastValidOffsetX = 0
    $autoResult = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct $null
    if ($autoResult.Keys -ne 480) { throw "Auto at zoom20/offset0 should match the T=0 replica exactly (Auto's own formula clamps to 0 here), got $($autoResult.Keys) keys" }
    $zoomSlider.Value = 0
}

Check "Get-ToleranceReadoutEstimate: All axis picks the worse-worst-overflow pair with its OWN P (not a per-frame mix), on a small hand-derived fixture" {
    Reset-FrameGateTestState
    # Reuses the shared fixture: x half-widths up to 100 vs halfOrtho 106.25
    # (frame 3 clips per Reset-FrameGateTestState's own comment); z_width is
    # tiny (10) throughout, so Left/Right never clips here -- "All" must
    # therefore report exactly the FrontBack numbers, not some blend.
    $fb = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct 0 -OffsetXPx 0 -ManualTolerancePct 0.0
    $all = Get-ToleranceReadoutEstimate -Axis "All" -ZoomPct 0 -OffsetXPx 0 -ManualTolerancePct 0.0
    if ($all.Keys -ne $fb.Keys -or [Math]::Abs($all.WorstOverflowPct - $fb.WorstOverflowPct) -gt 1e-9) {
        throw "expected All to exactly match FrontBack when LeftRight never clips, got Keys=$($all.Keys)/W=$($all.WorstOverflowPct) vs FB Keys=$($fb.Keys)/W=$($fb.WorstOverflowPct)"
    }
}

Remove-Item $script:frameGateTestCachePath -ErrorAction SilentlyContinue
Remove-Item $script:frameGateTestRectPath -ErrorAction SilentlyContinue
Remove-Item $script:frameGateGlowTestCachePath -ErrorAction SilentlyContinue
$script:lastCachePath = $null
$script:cachedFrameArrays = $null
$frameGateCheckBox.IsChecked = $true
Write-FrameGateEnabled -Enabled $true

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

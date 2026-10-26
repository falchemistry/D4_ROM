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

function Wait-ForCondition([scriptblock]$condition, [int]$timeoutSeconds, [int]$pollMs = 50) {
    # General bounded-poll helper (task17, 2026-09-30): checks a condition
    # tightly and returns as soon as it's true, pumping the WPF dispatcher
    # between checks (same DispatcherFrame/DispatcherTimer idiom as
    # Wait-ForStatus above) so any pending UI/process-exit callback this
    # process needs to observe actually gets a chance to run -- a plain
    # Start-Sleep loop would starve the dispatcher and could never see the
    # condition flip. Used to replace a fixed blind sleep with "poll
    # tightly for results, cap the wait" (this workspace's own testing
    # policy, TOOL_DEVELOPMENT_WORKFLOW.md section 4.3) wherever a test was
    # previously waiting out a fixed guess at how long some async state
    # takes to settle, rather than actually checking for it.
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while (-not (& $condition) -and (Get-Date) -lt $deadline) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($pollMs)
        $t.Add_Tick({ $frame.Continue = $false })
        $t.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        $t.Stop()
    }
    return [bool](& $condition)
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

    # Poll for the process actually being up, instead of blindly waiting a
    # fixed 300ms and hoping that was enough (task17, 2026-09-30) --
    # confirmed intermittently flaky: process creation (a real Win32
    # CreateProcess call under Start-Steps) is not guaranteed to land
    # inside any fixed short window on a loaded machine, so a wait tuned
    # to the common case could still occasionally fire before
    # $script:currentProcess was even assigned. Bounded to 10s -- a `ping`
    # child process starting should never take remotely that long; if it
    # does, something is actually wrong and the test should fail loudly
    # rather than silently proceed into a false pass/fail below.
    $started = Wait-ForCondition { $script:currentProcess -ne $null -and -not $script:currentProcess.HasExited } 10
    if (-not $started) { throw "expected a process to be running before Stop -- never observed one within 10s" }
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
    # Hermetic against this machine's REAL user_hooks\ (T97 test hygiene,
    # done in T87): Get-CaptureClickResult adds a pre/post step per leg for
    # any user script with code, so on a machine whose own
    # d4_rom_pre_record.py / d4_rom_post_record.py hold code this counted 16
    # steps instead of 12. This case counts the PLAIN legs, so the user
    # scripts are stubbed away here (the hook steps have their own suite:
    # tests\test_prepost_hooks.ps1). The real files are never read or touched.
    function Get-ActiveHookPaths { param([string]$ScriptDir) return [PSCustomObject]@{ Pre = $null; Post = $null; Log = @() } }
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
    # Was a single Test-MayaPortReachable call with a tight 300ms
    # TimeoutMs -- confirmed intermittently flaky (task17, 2026-09-30):
    # a real listener should answer near-instantly, but an occasional
    # scheduling/GC pause on a loaded machine could push one single
    # BeginConnect/WaitOne attempt past 300ms even though the listener was
    # never actually unreachable. Per this workspace's testing policy
    # (poll tightly for results rather than a blind fixed wait), this now
    # retries the SAME real check in a bounded loop instead of either
    # widening the timeout (a band-aid that just moves the flake threshold)
    # or trusting a single attempt -- any successful attempt within the
    # bound proves the listener is genuinely reachable, and the loop only
    # fails the test if every attempt in the whole window comes back false.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $freePort = $listener.LocalEndpoint.Port
    try {
        $reachable = $false
        $attempts = 0
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $reachable -and (Get-Date) -lt $deadline) {
            $attempts++
            $reachable = Test-MayaPortReachable -MayaHost "127.0.0.1" -Port $freePort -TimeoutMs 300
            if (-not $reachable) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $reachable) { throw "expected true for a port with an active listener -- still false after $attempts attempts over 5s" }
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

Check "Get-ToleranceReadoutEstimate zoom20/offset20 table (T=0/2/5/10/15) on the real barM cache -- the gate follows the visible frame (T72 item 6)" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 20
    $script:lastValidOffsetX = 20
    # keys / frames-over-T / worst-overflow. T72 item 6 (2026-10-20) replaced the approved proposal's replica numbers for
    # a non-zero Offset (d4_rom_final_proposals.md sec.4: 480/395/298/111/70 keys): that table came from the old walk whose
    # gate sat one Offset away from the visible frame. These values come from the independent visible-space walk
    # (tests/test_edge_guard_curve_logic.py, _visible_oracle). The Offset-0 replica (480/395/298/111/70 keys) is asserted in the
    # check right after the zoom0/offset20 row below ("zoom20/offset0 replica"); Offset 0 is the old walk, so those key counts are unchanged.
    $expected = @{
        0  = @{ Keys = 482; OverT = 23.1; Worst = 18.6 }
        2  = @{ Keys = 426; OverT = 14.0; Worst = 15.8 }
        5  = @{ Keys = 308; OverT = 3.0;  Worst = 13.6 }
        10 = @{ Keys = 114; OverT = 0.0;  Worst = 10.0 }
        15 = @{ Keys = 84;  OverT = 0.0;  Worst = 15.0 }
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

Check "Get-ToleranceReadoutEstimate zoom0/offset20 row (T=0/2/5/10/15) on the real barM cache -- the gate follows the visible frame (T72 item 6)" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 20
    # T72 item 6: replaces the old replica row (97/70/30/14/8 keys, worst 2.1/4.1/7.1/12.1/17.1 from the
    # proposal's trade-off table): with the gate in the visible frame the worst overflow is exactly the tolerance.
    $expected = @{
        0  = @{ Keys = 103; OverT = 0.0; Worst = 0.0 }
        2  = @{ Keys = 86;  OverT = 0.0; Worst = 2.0 }
        5  = @{ Keys = 50;  OverT = 0.0; Worst = 5.0 }
        10 = @{ Keys = 16;  OverT = 0.0; Worst = 10.0 }
        15 = @{ Keys = 11;  OverT = 0.0; Worst = 15.0 }
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

Check "Get-ToleranceReadoutEstimate zoom20/offset0 replica (T=0/2/5/10/15) on the real barM cache -- keys 480/395/298/111/70 are the approved proposal's numbers, unchanged by T72 item 6" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 20
    $script:lastValidOffsetX = 0
    # Offset 0 == the old walk exactly (offset_shift 0.0 is byte-for-byte the old curve), so the approved proposal's KEY counts
    # (d4_rom_final_proposals.md sec.4: 480/395/298/111/70) still hold. Its over-tolerance / worst-overflow columns
    # (44.6/35.7/16.5/11.4/10.4 and 20.7/17.9/15.7/12.1/17.1) belong to zoom 20 / OFFSET 20 px (the old test's configuration), not
    # to Offset 0: the pre-T72 (git HEAD) function returns exactly those columns at Offset 20 and 23.1/14.0/3.0/0.0/0.0 and
    # 18.6/15.8/13.6/10.0/15.0 at Offset 0, the same as the current function (checked 2026-10-21 by running both).
    $expected = @{
        0  = @{ Keys = 480; OverT = 23.1; Worst = 18.6 }
        2  = @{ Keys = 395; OverT = 14.0; Worst = 15.8 }
        5  = @{ Keys = 298; OverT = 3.0;  Worst = 13.6 }
        10 = @{ Keys = 111; OverT = 0.0;  Worst = 10.0 }
        15 = @{ Keys = 70;  OverT = 0.0;  Worst = 15.0 }
    }
    foreach ($t in $expected.Keys) {
        $result = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct ([double]$t)
        $exp = $expected[$t]
        if ($result.Keys -ne $exp.Keys) { throw "zoom20/offset0 T=$t%: expected $($exp.Keys) keys, got $($result.Keys)" }
        if ([Math]::Abs($result.PercentOverTolerance - $exp.OverT) -gt 0.1) { throw "zoom20/offset0 T=$t%: expected $($exp.OverT)% over tolerance, got $($result.PercentOverTolerance)" }
        if ([Math]::Abs($result.WorstOverflowPct - $exp.Worst) -gt 0.1) { throw "zoom20/offset0 T=$t%: expected $($exp.Worst)% worst overflow, got $($result.WorstOverflowPct)" }
    }
    $zoomSlider.Value = 0
}

Check "Get-ToleranceReadoutEstimate Auto matches Get-FrameGateEffectiveOverflowPct's own zoom-only formula (regression: readout's Auto path is not a second, diverging formula)" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 20
    $script:lastValidOffsetX = 0
    $autoResult = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct $null
    if ($autoResult.Keys -ne 480) { throw "Auto at zoom20/offset0 should match the T=0 replica exactly (Auto's own formula clamps to 0 here), got $($autoResult.Keys) keys" }
    $zoomSlider.Value = 0
}

Check "T72 Option B: Get-ToleranceReadoutEstimate seeds the guard walk at the measured range's Start (real barM cache, zoom 0, offset 0, Auto): FB 70/90/32/30/25/17 keys, none over, worst 2.0 at Start 0/150/300/600/1000/2000" {
    Set-RealBarmCacheState
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 0
    # keys expected from an independent Python walk seeded at the cached centre of the Start frame (frames are 0..3240, index = frame)
    foreach ($e in @(@(0, 70), @(150, 90), @(300, 32), @(600, 30), @(1000, 25), @(2000, 17))) {
        $r = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct 0 -OffsetXPx 0 -ManualTolerancePct $null -MeasureStartIndex ([int]$e[0]) -MeasureEndIndex 3240
        if ($r.Keys -ne $e[1]) { throw "Start $($e[0]): expected $($e[1]) keys, got $($r.Keys)" }
        if ($r.PercentOverTolerance -gt 0.05) { throw "Start $($e[0]): expected none over tolerance, got $($r.PercentOverTolerance)%" }
        if ([Math]::Abs($r.WorstOverflowPct - 2.0) -gt 0.05) { throw "Start $($e[0]): expected worst 2.0%, got $($r.WorstOverflowPct)" }
    }
    $whole = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct 0 -OffsetXPx 0 -ManualTolerancePct $null
    if ($whole.Keys -ne 70) { throw "no range = the whole take, seeded at 0: expected 70 keys, got $($whole.Keys)" }
    # Left/Right (z, frame sized from the x widths like the keyer's panels): 4 keys whole take, 2 (seed + end) from every later Start
    foreach ($e in @(@(0, 4), @(150, 2), @(300, 2), @(600, 2), @(1000, 2), @(2000, 2))) {
        $r = Get-ToleranceReadoutEstimate -Axis "LeftRight" -ZoomPct 0 -OffsetXPx 0 -ManualTolerancePct $null -MeasureStartIndex ([int]$e[0]) -MeasureEndIndex 3240
        if ($r.Keys -ne $e[1]) { throw "LR Start $($e[0]): expected $($e[1]) keys, got $($r.Keys)" }
        if ($r.PercentOverTolerance -gt 0.05) { throw "LR Start $($e[0]): expected none over tolerance, got $($r.PercentOverTolerance)%" }
    }
    $off = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct 0 -OffsetXPx 50 -ManualTolerancePct $null -MeasureStartIndex 300 -MeasureEndIndex 3240
    # T72 item 6: the gate follows the visible frame, so a +50 px Offset no longer pushes the worst overflow to 7.21% (it stays the 2.0% tolerance)
    if ($off.Keys -ne 50 -or [Math]::Abs($off.WorstOverflowPct - 2.0) -gt 0.05 -or $off.PercentOverTolerance -gt 0.05) { throw "Start 300 with a +50 px offset: expected 50 keys, worst 2.0%, none over, got $($off.Keys) / $($off.WorstOverflowPct) / $($off.PercentOverTolerance)" }
}

Check "T72 item 6: the guard gate follows the VISIBLE frame -- Get-ToleranceReadoutEstimate equals the shared parity table with the Python walk (real barM cache, FB and LR, zoom 0 / 7, Offset +-10/+-50/+-100, Start none/300/1000)" {
    Set-RealBarmCacheState
    $script:lastValidOffsetX = 0
    # Axis, zoom %, typed Tolerance % (null = Auto), Offset px, measured Start (null = whole take), keys, % over tolerance, worst % of the frame width.
    # The same rows are asserted against the shipped Python walk in tests/test_edge_guard_curve_logic.py (ESTIMATE_PARITY_TABLE),
    # generated there from an independent visible-space oracle.
    $rows = @(
        @('FrontBack', 0, $null, 0, $null, 70, 0.0000, 2.0000),
        @('FrontBack', 0, $null, 0, 300, 32, 0.0000, 2.0000),
        @('FrontBack', 0, $null, 50, 300, 50, 0.0000, 2.0000),
        @('FrontBack', 0, $null, -50, 300, 51, 0.0000, 2.0000),
        @('FrontBack', 0, $null, 100, 1000, 49, 0.0000, 2.0000),
        @('FrontBack', 0, $null, -100, 1000, 75, 0.0000, 2.0000),
        @('FrontBack', 0, $null, 10, 0, 81, 0.0000, 2.0000),
        @('FrontBack', 7, 1.0, 50, 300, 105, 0.0000, 1.0000),
        @('FrontBack', 7, 1.0, -50, 300, 147, 0.0000, 1.0000),
        @('FrontBack', 7, 1.0, 100, 1000, 75, 0.0446, 4.7401),
        @('FrontBack', 7, 1.0, -100, 300, 173, 0.0000, 1.0000),
        @('FrontBack', 7, 1.0, -10, 300, 111, 0.0000, 1.0000),
        @('FrontBack', 7, $null, -50, 300, 190, 0.7140, 1.7061),
        @('LeftRight', 0, $null, 50, 300, 2, 0.0000, 1.4858),
        @('LeftRight', 0, $null, -100, 1000, 2, 0.0000, 0.0000),
        @('LeftRight', 7, 1.0, 50, 300, 6, 0.0000, 1.0000),
        @('LeftRight', 7, 1.0, -100, 1000, 2, 0.0000, 0.9123)
    )
    foreach ($r in $rows) {
        $ms = $r[4]
        $res = Get-ToleranceReadoutEstimate -Axis $r[0] -ZoomPct ([double]$r[1]) -OffsetXPx ([double]$r[3]) -ManualTolerancePct $r[2] -MeasureStartIndex $ms -MeasureEndIndex $null
        $tag = "$($r[0]) zoom $($r[1]) tol $($r[2]) offset $($r[3]) start $($r[4])"
        if ($res.Keys -ne $r[5]) { throw "${tag}: expected $($r[5]) keys, got $($res.Keys)" }
        if ([Math]::Abs($res.PercentOverTolerance - $r[6]) -gt 0.002) { throw "${tag}: expected $($r[6])% over tolerance, got $($res.PercentOverTolerance)" }
        if ([Math]::Abs($res.WorstOverflowPct - $r[7]) -gt 0.002) { throw "${tag}: expected worst $($r[7])%, got $($res.WorstOverflowPct)" }
    }
}

Check "T72 item 6: Get-EdgeGuardCurveEstimateCore hand-checked -- the walk starts at the visible camera (centre minus Offset) and no post-shift is applied, both signs" {
    $c = [double[]]@(0, 0, 0, 8, 8, -8, -8)
    $w = [double[]]@(10, 10, 10, 10, 10, 10, 10)
    # half ortho 10, overflow 1 (gate half-width 11), pose half-width 5. +4: camera starts at -4, gate [-15, 7]: index 3 right edge 13 -> cam 2,
    # index 5 left edge -13 < -9 -> cam -2; keys 0,3,5 + end(6) = 4, every nudge parks the edge at the limit: worst = 1 / 20 = 5.0%, none over.
    $p = Get-EdgeGuardCurveEstimateCore -CenterX $c -WidthX $w -HalfOrtho 10 -Overflow 1 -OffsetShift 4 -StartIndex 0 -EndIndex 6
    if ($p.Keys -ne 4 -or [Math]::Abs($p.WorstOverflowPct - 5.0) -gt 1e-9 -or $p.PercentOverTolerance -ne 0) { throw "+4: expected 4 keys / 0% / worst 5.0, got $($p.Keys) / $($p.PercentOverTolerance) / $($p.WorstOverflowPct)" }
    # -4: camera starts at +4, gate [-7, 15]: index 3 (13) fits, no nudge; index 5 left edge -13 < -7 -> cam -2; keys 0,5 + end = 3.
    $n = Get-EdgeGuardCurveEstimateCore -CenterX $c -WidthX $w -HalfOrtho 10 -Overflow 1 -OffsetShift -4 -StartIndex 0 -EndIndex 6
    if ($n.Keys -ne 3 -or [Math]::Abs($n.WorstOverflowPct - 5.0) -gt 1e-9 -or $n.PercentOverTolerance -ne 0) { throw "-4: expected 3 keys / 0% / worst 5.0, got $($n.Keys) / $($n.PercentOverTolerance) / $($n.WorstOverflowPct)" }
    # Offset 0 is the old walk: seed 0, gate [-11, 11]: index 3 right edge 13 -> cam 2, index 5 -> cam -2: 4 keys.
    $z = Get-EdgeGuardCurveEstimateCore -CenterX $c -WidthX $w -HalfOrtho 10 -Overflow 1 -OffsetShift 0 -StartIndex 0 -EndIndex 6
    if ($z.Keys -ne 4) { throw "0: expected 4 keys, got $($z.Keys)" }
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

# --- Arrow / wheel stepping on every numeric box (task48, 2026-10-07) -----
# Real handler paths: a synthetic KeyEventArgs / MouseWheelEventArgs is raised
# on each REAL box with RaiseEvent, so the actual Add_PreviewKeyDown /
# Add_PreviewMouseWheel handler, the Step-* function and the field's real write
# path all run. The invisible HwndSource below only gives the synthetic key
# event a PresentationSource; nothing is shown and no focus is taken.
# Synthetic events cannot carry Shift/Ctrl (the launcher reads the physical
# keyboard), so modifier routing is covered by the pure Get-SteppedNumber
# checks in test_rom_launcher_logic.ps1 plus direct Step-*/Invoke-NumericStep
# calls with explicit flags below -- never by pressing real keys.
$script:t48Zoom = Join-Path $env:TEMP "rom_launcher_test_t48_zoom.txt"
$script:t48Tol = Join-Path $env:TEMP "rom_launcher_test_t48_tol.txt"
$script:t48RealZoomPathFn = ${function:Get-CameraZoomPctPath}
$script:t48RealTolPathFn = ${function:Get-CameraTolerancePctPath}
function Get-CameraZoomPctPath { return $script:t48Zoom }
function Get-CameraTolerancePctPath { return $script:t48Tol }
$script:t48SourceParams = New-Object System.Windows.Interop.HwndSourceParameters("t48_test_source")
$script:t48Source = New-Object System.Windows.Interop.HwndSource($script:t48SourceParams)

function Send-T48Key($target, $key, [bool]$preview = $true) {
    $ev = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $script:t48Source, 0, $key)
    $ev.RoutedEvent = if ($preview) { [System.Windows.Input.Keyboard]::PreviewKeyDownEvent } else { [System.Windows.Input.Keyboard]::KeyDownEvent }
    $target.RaiseEvent($ev)
    return $ev
}
function Send-T48Wheel($target, [int]$delta, [bool]$preview = $true) {
    $ev = New-Object System.Windows.Input.MouseWheelEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, [Environment]::TickCount, $delta)
    $ev.RoutedEvent = if ($preview) { [System.Windows.Input.Mouse]::PreviewMouseWheelEvent } else { [System.Windows.Input.Mouse]::MouseWheelEvent }
    $target.RaiseEvent($ev)
    return $ev
}
function Reset-T48State {
    # task48 rebuild: the modifier seam defaults to 'nothing held', so a Shift/Ctrl the
    # user happens to hold on the real keyboard during a run cannot leak into a check.
    $script:modifierKeysOverride = [System.Windows.Input.ModifierKeys]::None
    $script:wheelSettleTimer.Stop()
    $script:wheelNudgeAxis = $null
    if ($script:zoomStepSettleTimer) { $script:zoomStepSettleTimer.Stop() }
    $script:zoomStepActive = $false
    $script:zoomSliderDragging = $false
    $script:zoomThumbDragging = $false     # a check that throws mid-drag must not leak its drag into the next one
    Reset-LiveTuneTestState
    $script:lastValidTolerancePct = $null
    $toleranceValueBox.Text = "Auto"
    $startFrameBox.Text = "0"
    $endFrameBox.Text = "100"
    $script:lastCachePath = $null
    $script:cachedFrameArrays = $null
    Remove-Item $script:t48Zoom -ErrorAction SilentlyContinue
    Remove-Item $script:t48Tol -ErrorAction SilentlyContinue
}
function Get-T48FileText($path) { return ([IO.File]::ReadAllText($path)).Trim() }
function Get-T48FileBytes($path) { return ([IO.File]::ReadAllBytes($path) -join ",") }

Check "Zoom box: real Up/Down PreviewKeyDown steps by 10, clamps at +/-50, file bytes equal the plain writer's, Maya push held until settle" {
    Reset-T48State
    $ev = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled) { throw "Up must be marked handled" }
    if ($zoomSlider.Value -ne 10) { throw "expected slider 10 after Up, got $($zoomSlider.Value)" }
    if ($zoomValueBox.Text -ne "+10") { throw "expected box '+10', got '$($zoomValueBox.Text)'" }
    if ((Get-T48FileText $script:t48Zoom) -ne "10") { throw "expected zoom file '10', got '$(Get-T48FileText $script:t48Zoom)'" }
    $stepBytes = Get-T48FileBytes $script:t48Zoom
    Write-CameraZoomPct -Value 10
    if ($stepBytes -ne (Get-T48FileBytes $script:t48Zoom)) { throw "file bytes after a key step ($stepBytes) differ from the plain writer's ($(Get-T48FileBytes $script:t48Zoom))" }
    if ($script:pendingZoomPush) { throw "push must be held while the key burst is still going" }
    if (-not $script:zoomStepActive -or -not $script:zoomSliderDragging) { throw "step session should hold the push flag" }

    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Down)
    if ($zoomSlider.Value -ne 10) { throw "Up,Up,Down should net +10, got $($zoomSlider.Value)" }
    if ($script:pendingZoomPush) { throw "still no push mid-burst" }
    Stop-ZoomStep
    if (-not $script:pendingZoomPush) { throw "expected exactly one push once the burst settles" }
    if ($script:zoomSliderDragging -or $script:zoomStepActive) { throw "settle must release the hold" }

    # Ends where it began: no push at all.
    Reset-T48State
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Down)
    Stop-ZoomStep
    if ($script:pendingZoomPush) { throw "a burst that ends where it began must not push" }

    # Range ends.
    Reset-T48State
    $zoomSlider.Value = 45
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    if ($zoomSlider.Value -ne 50) { throw "45 + 10 must clamp to 50, got $($zoomSlider.Value)" }
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    if ($zoomSlider.Value -ne 50 -or $zoomValueBox.Text -ne "+50") { throw "must stay at +50, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    $zoomSlider.Value = -45
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Down)
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Down)
    if ($zoomSlider.Value -ne -50 -or $zoomValueBox.Text -ne "-50") { throw "must stop at -50, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    Stop-ZoomStep
}

Check "Zoom box: typed-but-uncommitted text is committed first then stepped; garbage reverts first then steps" {
    Reset-T48State
    $zoomValueBox.Text = "25"
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    if ($zoomSlider.Value -ne 35) { throw "typed 25 then Up must give 35, got $($zoomSlider.Value)" }
    $zoomValueBox.Text = "zzz"
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Down)
    if ($zoomSlider.Value -ne 25) { throw "garbage reverts to 35 then Down gives 25, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    Stop-ZoomStep
}

Check "Zoom steps from the Step-/Invoke- functions honour Shift (100 -> clamps) and Ctrl (1), Ctrl wins" {
    Reset-T48State
    Invoke-NumericStep "Zoom" 1 $false $true
    if ($zoomSlider.Value -ne 1) { throw "Ctrl+Up should be +1, got $($zoomSlider.Value)" }
    Invoke-NumericStep "Zoom" 1 $true $true
    if ($zoomSlider.Value -ne 2) { throw "Shift+Ctrl+Up: Ctrl wins, +1, got $($zoomSlider.Value)" }
    Invoke-NumericStep "Zoom" 1 $true $false
    if ($zoomSlider.Value -ne 50) { throw "Shift+Up (100) must clamp to 50, got $($zoomSlider.Value)" }
    Invoke-NumericStep "Zoom" -1 $true $false
    if ($zoomSlider.Value -ne -50) { throw "Shift+Down must clamp to -50, got $($zoomSlider.Value)" }
    Stop-ZoomStep
}

Check "Offset X/Y boxes: real Up/Down step 10 through the wheel session (one push after settle); file is 'X,Y'; typed text commits first" {
    Reset-T48State
    $ev = Send-T48Key $offsetXBox ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled) { throw "Up must be handled on X" }
    if ($offsetXBox.Text -ne "10") { throw "expected X box '10' live, got '$($offsetXBox.Text)'" }
    $null = Send-T48Key $offsetXBox ([System.Windows.Input.Key]::Up)
    $null = Send-T48Key $offsetXBox ([System.Windows.Input.Key]::Down)
    if ($script:pendingNudgeDeltaX -ne 0) { throw "no live push mid-burst, got $($script:pendingNudgeDeltaX)" }
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 10 -or $script:pendingNudgeDeltaX -ne 10) { throw "expected X=10 and one pending delta of 10, got X=$($script:lastValidOffsetX) delta=$($script:pendingNudgeDeltaX)" }
    if ((Get-T48FileText $script:liveTuneOffsetPath) -ne "10,0") { throw "expected file '10,0', got '$(Get-T48FileText $script:liveTuneOffsetPath)'" }

    $ev = Send-T48Key $offsetYBox ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled) { throw "Up must be handled on Y" }
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne 10 -or $script:lastValidOffsetX -ne 10) { throw "Y Up must change only Y (+10, subject up); got X=$($script:lastValidOffsetX) Y=$($script:lastValidOffsetY)" }
    $null = Send-T48Key $offsetYBox ([System.Windows.Input.Key]::Down)
    $null = Send-T48Key $offsetYBox ([System.Windows.Input.Key]::Down)
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne -10) { throw "Y Down,Down from 10 must give -10, got $($script:lastValidOffsetY)" }
    if ((Get-T48FileText $script:liveTuneOffsetPath) -ne "10,-10") { throw "expected file '10,-10', got '$(Get-T48FileText $script:liveTuneOffsetPath)'" }

    # Typed but not committed: committed first, then stepped (25 -> 35, not 10).
    Reset-T48State
    $offsetXBox.Text = "25"
    $null = Send-T48Key $offsetXBox ([System.Windows.Input.Key]::Up)
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 35) { throw "typed 25 then Up must give 35, got $($script:lastValidOffsetX)" }
    if ($script:pendingNudgeDeltaX -ne 35) { throw "the Maya delta must be the whole 0->35 move exactly once, got $($script:pendingNudgeDeltaX)" }
    $offsetYBox.Text = "abc"
    $null = Send-T48Key $offsetYBox ([System.Windows.Input.Key]::Up)
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne 10) { throw "garbage reverts to 0 then Up gives 10, got $($script:lastValidOffsetY)" }
}

Check "Offset X/Y step sizes via explicit flags: plain 10, Shift 100, Ctrl 1, Ctrl wins; wheel session accepts -CtrlHeld" {
    Reset-T48State
    Invoke-NumericStep "OffsetX" 1 $true $false;  Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 100) { throw "Shift+Up should be +100, got $($script:lastValidOffsetX)" }
    Invoke-NumericStep "OffsetX" -1 $false $true; Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 99) { throw "Ctrl+Down should be -1, got $($script:lastValidOffsetX)" }
    Invoke-NumericStep "OffsetY" 1 $true $true;   Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne 1) { throw "Shift+Ctrl+Up: Ctrl wins, +1, got $($script:lastValidOffsetY)" }
    Update-OffsetWheelNudge -Axis "X" -Delta -120 -ShiftHeld $false -CtrlHeld $true
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 98) { throw "wheel with -CtrlHeld should be -1, got $($script:lastValidOffsetX)" }
}

Check "Tolerance box: Auto + Up/Down starts from Auto's zoom value (2.0 at zoom 0, no cache needed), Down at 0 stays 0, clamps at 20, file is a plain number" {
    Reset-T48State
    $ev = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled) { throw "Up must be handled on Tolerance" }
    if ($toleranceValueBox.Text -ne "3" -or $script:lastValidTolerancePct -ne 3) { throw "Auto at zoom 0 (2.0, no cache) then Up = 3, got '$($toleranceValueBox.Text)' / $($script:lastValidTolerancePct)" }
    if ((Get-T48FileText $script:t48Tol) -ne "3") { throw "expected tolerance file '3', got '$(Get-T48FileText $script:t48Tol)'" }
    $stepBytes = Get-T48FileBytes $script:t48Tol
    Write-CameraTolerancePct -Value 3.0
    if ($stepBytes -ne (Get-T48FileBytes $script:t48Tol)) { throw "tolerance file bytes after a step differ from the plain writer's" }

    Reset-T48State
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($toleranceValueBox.Text -ne "1" -or $script:lastValidTolerancePct -ne 1) { throw "Auto at zoom 0 (2.0) then Down = 1, got '$($toleranceValueBox.Text)'" }
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($toleranceValueBox.Text -ne "0" -or $script:lastValidTolerancePct -ne 0) { throw "1 then Down = 0, got '$($toleranceValueBox.Text)'" }
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($toleranceValueBox.Text -ne "0" -or $null -eq $script:lastValidTolerancePct) { throw "Down at 0 must stay 0 (not wrap to Auto), got '$($toleranceValueBox.Text)'" }
    if ((Get-T48FileText $script:t48Tol) -ne "0") { throw "file must hold 0 (a real zero, not Auto), got '$(Get-T48FileText $script:t48Tol)'" }

    Reset-T48State
    $script:lastValidTolerancePct = 19.5; $toleranceValueBox.Text = "19.5"
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($toleranceValueBox.Text -ne "20" -or $script:lastValidTolerancePct -ne 20) { throw "must clamp at 20, got '$($toleranceValueBox.Text)'" }

    # Ctrl-fine steps land exactly (no float drift in the box).
    Reset-T48State
    $script:lastValidTolerancePct = 0.2; $toleranceValueBox.Text = "0.2"
    Invoke-NumericStep "Tolerance" 1 $false $true
    if ($toleranceValueBox.Text -ne "0.3") { throw "0.2 + 0.1 must display exactly '0.3', got '$($toleranceValueBox.Text)'" }
    Invoke-NumericStep "Tolerance" 1 $true $false
    if ($toleranceValueBox.Text -ne "10.3") { throw "Shift step is 10: expected '10.3', got '$($toleranceValueBox.Text)'" }
    Invoke-NumericStep "Tolerance" 1 $true $false
    if ($toleranceValueBox.Text -ne "20") { throw "10.3 + 10 clamps to 20, got '$($toleranceValueBox.Text)'" }
}

Check "Tolerance box: typed text commits first then steps; clearing returns to Auto (Enter); a manual value always wins over Auto's" {
    Reset-T48State
    $toleranceValueBox.Text = "7"
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($script:lastValidTolerancePct -ne 8) { throw "typed 7 then Up must give 8, got $($script:lastValidTolerancePct)" }
    $toleranceValueBox.Text = "nope"
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($script:lastValidTolerancePct -ne 7) { throw "garbage reverts to 8 then Down gives 7, got $($script:lastValidTolerancePct)" }
    $toleranceValueBox.Text = ""
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Left)
    $enter = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Return) $false
    if ($null -ne $script:lastValidTolerancePct -or $toleranceValueBox.Text -ne "Auto") { throw "clearing + Enter must return to Auto, got '$($toleranceValueBox.Text)'" }
    if ((Get-T48FileText $script:t48Tol) -ne "") { throw "Auto must write an empty file, got '$(Get-T48FileText $script:t48Tol)'" }
}

Check "Tolerance box: from Auto with a KNOWN effective value, Up/Down seed from it (percent, 1 decimal) then step" {
    Reset-T48State
    Reset-FrameGateTestState        # max_w 200, panel 1000 wide: Auto at zoom 0 / offset 0 is exactly 2.0%
    $script:lastValidTolerancePct = $null
    $toleranceValueBox.Text = "Auto"
    Remove-Item $script:t48Tol -ErrorAction SilentlyContinue
    $auto = Get-AutoEffectiveTolerancePct
    if ($null -eq $auto -or [Math]::Abs($auto - 2.0) -gt 1e-6) { throw "fixture should give Auto = 2.0%, got '$auto'" }
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($script:lastValidTolerancePct -ne 3) { throw "Auto 2.0% then Up must give 3, got $($script:lastValidTolerancePct)" }

    $script:lastValidTolerancePct = $null
    $toleranceValueBox.Text = "Auto"
    Remove-Item $script:t48Tol -ErrorAction SilentlyContinue
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($script:lastValidTolerancePct -ne 1) { throw "Auto 2.0% then Down must give 1, got $($script:lastValidTolerancePct)" }
    $script:lastCachePath = $null
    $script:cachedFrameArrays = $null
}

Check "Start/End boxes: real Up/Down step by 1 (Shift 10), no lower limit; non-numeric text -> Up/Down do nothing (still handled)" {
    Reset-T48State
    $startFrameBox.Text = "5"
    $ev = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled -or $startFrameBox.Text -ne "6") { throw "Start 5 + Up should be '6' and handled, got '$($startFrameBox.Text)'" }
    $null = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Down)
    $null = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Down)
    if ($startFrameBox.Text -ne "4") { throw "Start Down,Down from 6 should give 4, got '$($startFrameBox.Text)'" }
    $startFrameBox.Text = "0"
    $null = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Down)
    if ($startFrameBox.Text -ne "-1") { throw "no lower limit: 0 Down must give -1, got '$($startFrameBox.Text)'" }
    Invoke-NumericStep "StartFrame" 1 $true $false
    if ($startFrameBox.Text -ne "9") { throw "Shift+Up from -1 should give 9, got '$($startFrameBox.Text)'" }
    Invoke-NumericStep "StartFrame" 1 $true $true
    if ($startFrameBox.Text -ne "10") { throw "Shift+Ctrl+Up: Ctrl wins (+1), got '$($startFrameBox.Text)'" }

    $endFrameBox.Text = "100"
    $null = Send-T48Key $endFrameBox ([System.Windows.Input.Key]::Up)
    if ($endFrameBox.Text -ne "101") { throw "End 100 + Up should be '101', got '$($endFrameBox.Text)'" }
    foreach ($bad in @("abc", "", "5.5", "12x")) {
        $startFrameBox.Text = $bad
        $ev = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Up)
        $ev2 = Send-T48Key $startFrameBox ([System.Windows.Input.Key]::Down)
        if ($startFrameBox.Text -ne $bad) { throw "non-numeric '$bad' must be left alone by Up/Down, got '$($startFrameBox.Text)'" }
        if (-not $ev.Handled -or -not $ev2.Handled) { throw "Up/Down on '$bad' must still be swallowed so the caret does not jump" }
    }
}

Check "keys other than Up/Down are never claimed or acted on, on every numeric box and the slider (typing/caret/Tab/Enter untouched)" {
    Reset-T48State
    $targets = @($zoomValueBox, $zoomSlider, $offsetXBox, $offsetYBox, $toleranceValueBox, $startFrameBox, $endFrameBox)
    $keys = @([System.Windows.Input.Key]::Left, [System.Windows.Input.Key]::Right, [System.Windows.Input.Key]::Home, [System.Windows.Input.Key]::End,
              [System.Windows.Input.Key]::Back, [System.Windows.Input.Key]::Tab, [System.Windows.Input.Key]::Return, [System.Windows.Input.Key]::D5,
              [System.Windows.Input.Key]::A, [System.Windows.Input.Key]::OemMinus, [System.Windows.Input.Key]::PageUp, [System.Windows.Input.Key]::PageDown)
    foreach ($t in $targets) {
        foreach ($k in $keys) {
            $ev = Send-T48Key $t $k
            if ($ev.Handled) { throw "$($t.Name): key $k must not be handled by the stepping handler" }
        }
    }
    if ($zoomSlider.Value -ne 0 -or $zoomValueBox.Text -ne "0") { throw "no zoom change expected, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    if ($script:lastValidOffsetX -ne 0 -or $script:lastValidOffsetY -ne 0 -or $offsetXBox.Text -ne "0" -or $offsetYBox.Text -ne "0") { throw "no offset change expected" }
    if ($null -ne $script:lastValidTolerancePct -or $toleranceValueBox.Text -ne "Auto") { throw "no tolerance change expected" }
    if ($startFrameBox.Text -ne "0" -or $endFrameBox.Text -ne "100") { throw "no Start/End change expected" }
    if (Test-Path $script:t48Tol) { throw "no tolerance file write expected from non-step keys" }
}

Check "Zoom slider: SmallChange 1 / LargeChange 10; its own Right/Left keys step whole percent visibly; Up/Down route through the zoom step" {
    Reset-T48State
    if ($zoomSlider.SmallChange -ne 1 -or $zoomSlider.LargeChange -ne 10) { throw "expected SmallChange 1 / LargeChange 10, got $($zoomSlider.SmallChange) / $($zoomSlider.LargeChange)" }
    $null = Send-T48Key $zoomSlider ([System.Windows.Input.Key]::Right) $false
    if ($zoomSlider.Value -ne 1 -or $zoomValueBox.Text -ne "+1") { throw "slider native Right key must move +1 whole percent visibly, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    $null = Send-T48Key $zoomSlider ([System.Windows.Input.Key]::Left) $false
    if ($zoomSlider.Value -ne 0) { throw "slider native Left key must move -1, got $($zoomSlider.Value)" }
    $ev = Send-T48Key $zoomSlider ([System.Windows.Input.Key]::Up)
    if (-not $ev.Handled -or $zoomSlider.Value -ne 10) { throw "slider Up must step +10 like the box, got $($zoomSlider.Value)" }
    Stop-ZoomStep
}

Check "mouse wheel (real PreviewMouseWheel path): Zoom box, slider, Tolerance, Start/End step like the arrows; X/Y wheel still works; Delta 0 is ignored" {
    Reset-T48State
    $ev = Send-T48Wheel $zoomValueBox 120
    if (-not $ev.Handled -or $zoomSlider.Value -ne 10) { throw "Zoom box wheel up should be +10 and handled, got $($zoomSlider.Value)" }
    $null = Send-T48Wheel $zoomSlider -120
    $null = Send-T48Wheel $zoomSlider -120
    if ($zoomSlider.Value -ne -10) { throw "slider wheel down x2 from 10 should be -10, got $($zoomSlider.Value)" }
    Stop-ZoomStep
    $null = Send-T48Wheel $toleranceValueBox 120
    if ($script:lastValidTolerancePct -ne 7.4) { throw "Tolerance wheel up from Auto at zoom -10 (6.36 -> 6.4) should be 7.4 (and step once, not twice), got $($script:lastValidTolerancePct)" }
    $null = Send-T48Wheel $startFrameBox 120
    $null = Send-T48Wheel $endFrameBox -120
    if ($startFrameBox.Text -ne "1" -or $endFrameBox.Text -ne "99") { throw "Start/End wheel should give '1' / '99', got '$($startFrameBox.Text)' / '$($endFrameBox.Text)'" }
    # X/Y keep their existing bubbling MouseWheel handler (raised as the real wheel does after Preview).
    $ev = Send-T48Wheel $offsetXBox 120 $false
    if (-not $ev.Handled) { throw "X wheel must still be handled" }
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 10) { throw "X wheel up should still be +10, got $($script:lastValidOffsetX)" }
    $ev = Send-T48Wheel $zoomValueBox 0
    if ($ev.Handled) { throw "a zero-delta wheel event must be ignored" }
}

Check "Shift/Ctrl routing through the REAL key and wheel handlers via the virtual modifier seam (physical keyboard never touched); Ctrl wins when both are held" {
    Reset-T48State
    $MK = [System.Windows.Input.ModifierKeys]
    $Both = [System.Windows.Input.ModifierKeys]([int]$MK::Shift -bor [int]$MK::Control)
    $Up = [System.Windows.Input.Key]::Up
    $Down = [System.Windows.Input.Key]::Down
    try {
        # Zoom (keys): Ctrl = 1, Shift = 100 (clamps to the limit), both = Ctrl.
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Key $zoomValueBox $Up
        if ($zoomSlider.Value -ne 1) { throw "Ctrl+Up on Zoom should be +1, got $($zoomSlider.Value)" }
        $script:modifierKeysOverride = $Both
        $null = Send-T48Key $zoomValueBox $Up
        if ($zoomSlider.Value -ne 2) { throw "Shift+Ctrl+Up on Zoom should be +1 (Ctrl wins), got $($zoomSlider.Value)" }
        $script:modifierKeysOverride = $MK::Shift
        $null = Send-T48Key $zoomValueBox $Up
        if ($zoomSlider.Value -ne 50) { throw "Shift+Up on Zoom (100) should clamp to 50, got $($zoomSlider.Value)" }
        $null = Send-T48Key $zoomValueBox $Down
        $null = Send-T48Key $zoomValueBox $Down
        if ($zoomSlider.Value -ne -50) { throw "Shift+Down x2 on Zoom should clamp to -50, got $($zoomSlider.Value)" }
        Stop-ZoomStep

        # Offset X/Y (keys and the existing wheel): Ctrl = 1, Shift = 100, both = Ctrl.
        $script:modifierKeysOverride = $MK::Shift
        $null = Send-T48Key $offsetXBox $Up
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetX -ne 100) { throw "Shift+Up on X should be +100, got $($script:lastValidOffsetX)" }
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Key $offsetXBox $Up
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetX -ne 101) { throw "Ctrl+Up on X should be +1, got $($script:lastValidOffsetX)" }
        $script:modifierKeysOverride = $Both
        $null = Send-T48Key $offsetYBox $Down
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetY -ne -1) { throw "Shift+Ctrl+Down on Y should be -1 (Ctrl wins), got $($script:lastValidOffsetY)" }
        # X/Y wheel (bubbling MouseWheel, the existing handlers): this is the path that
        # used to read a property MouseWheelEventArgs does not have.
        $script:modifierKeysOverride = $MK::Shift
        $null = Send-T48Wheel $offsetXBox 120 $false
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetX -ne 201) { throw "Shift+wheel on X should now be +100 (was dead before), got $($script:lastValidOffsetX)" }
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Wheel $offsetXBox -120 $false
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetX -ne 200) { throw "Ctrl+wheel down on X should be -1, got $($script:lastValidOffsetX)" }
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Wheel $offsetYBox 120 $false
        Stop-OffsetWheelNudge
        if ($script:lastValidOffsetY -ne 0) { throw "Ctrl+wheel up on Y from -1 should be 0, got $($script:lastValidOffsetY)" }

        # Tolerance: Ctrl = 0.1, Shift = 10, both = Ctrl; wheel too.
        $script:lastValidTolerancePct = 5.0; $toleranceValueBox.Text = "5"
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Key $toleranceValueBox $Up
        if ($toleranceValueBox.Text -ne "5.1") { throw "Ctrl+Up on Tolerance should give 5.1, got '$($toleranceValueBox.Text)'" }
        $script:modifierKeysOverride = $MK::Shift
        $null = Send-T48Key $toleranceValueBox $Up
        if ($toleranceValueBox.Text -ne "15.1") { throw "Shift+Up on Tolerance should give 15.1, got '$($toleranceValueBox.Text)'" }
        $script:modifierKeysOverride = $Both
        $null = Send-T48Wheel $toleranceValueBox -120
        if ($toleranceValueBox.Text -ne "15") { throw "Shift+Ctrl+wheel down on Tolerance should be -0.1 -> 15, got '$($toleranceValueBox.Text)'" }

        # Start/End: Shift = 10, Ctrl = 1; wheel too.
        $startFrameBox.Text = "0"
        $script:modifierKeysOverride = $MK::Shift
        $null = Send-T48Key $startFrameBox $Up
        if ($startFrameBox.Text -ne "10") { throw "Shift+Up on Start should be 10, got '$($startFrameBox.Text)'" }
        $null = Send-T48Wheel $endFrameBox -120
        if ($endFrameBox.Text -ne "90") { throw "Shift+wheel down on End (100) should be 90, got '$($endFrameBox.Text)'" }
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Key $startFrameBox $Up
        if ($startFrameBox.Text -ne "11") { throw "Ctrl+Up on Start should be 11, got '$($startFrameBox.Text)'" }

        # Zoom wheel and slider wheel carry modifiers too.
        $zoomSlider.Value = 0
        $script:modifierKeysOverride = $MK::Control
        $null = Send-T48Wheel $zoomSlider 120
        if ($zoomSlider.Value -ne 1) { throw "Ctrl+wheel on the slider should be +1, got $($zoomSlider.Value)" }
        Stop-ZoomStep
    } finally {
        $script:modifierKeysOverride = $null
    }
    # With no override the real keyboard is read: nothing is held, so plain steps apply.
    Reset-T48State
    $script:modifierKeysOverride = $null
    $null = Send-T48Key $zoomValueBox $Up
    if ($zoomSlider.Value -ne 10) { throw "with the seam cleared a plain Up should be +10, got $($zoomSlider.Value)" }
    Stop-ZoomStep
}

Check "Reset button and the step functions coexist: Reset after a zoom step still zeroes Zoom/X/Y (single write path intact)" {
    Reset-T48State
    Invoke-NumericStep "Zoom" 1 $false $false
    Invoke-NumericStep "OffsetX" 1 $false $false
    Stop-ZoomStep; Stop-OffsetWheelNudge
    $resetFrameOffsetsButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($zoomSlider.Value -ne 0 -or $offsetXBox.Text -ne "0") { throw "Reset should zero zoom/X, got $($zoomSlider.Value) / '$($offsetXBox.Text)'" }
    if ((Get-T48FileText $script:t48Zoom) -ne "0") { throw "zoom file should read 0 after Reset, got '$(Get-T48FileText $script:t48Zoom)'" }
}

# --- Adjust section rebuild (task48, 2026-10-12): layout 3a, Tolerance bar, time range, F1-F6 ---
# Headless geometry: Measure/Arrange/UpdateLayout on the never-shown window's
# content tree (window size minus a typical 8px side / 39px caption+bottom
# frame), measured positions via TransformToAncestor. No window is shown, no
# focus is taken, the real pointer and keyboard are never used. The Tolerance
# bar's shapes carry Tags (frame, used-L/R, slack-L/R, over-L/R, auto-L/R,
# auto-A, cap-L/R, bang-over, bang-off) so their pixel geometry is measured
# directly. Real Segoe UI pixels and "does it look right" stay with the
# headless PNG renders plus a hands-on look.
function Get-T48Geo($name, $root) {
    $e = $window.FindName($name)
    if ($null -eq $e) { throw "element '$name' not found" }
    $p = $e.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
    return [PSCustomObject]@{ X = $p.X; Y = $p.Y; W = $e.ActualWidth; H = $e.ActualHeight; Element = $e }
}
function Invoke-T48Layout([double]$clientW, [double]$clientH) {
    $root = $window.Content
    $root.Measure((New-Object System.Windows.Size($clientW, $clientH)))
    $root.Arrange((New-Object System.Windows.Rect(0, 0, $clientW, $clientH)))
    $root.UpdateLayout()
    return $root
}
function Get-T48Shapes([string]$tag) {
    return @($tolVisualHost.Child.Children | Where-Object { $_.Tag -eq $tag })
}
function Get-T48ShapeLeft([string]$tag) { return [System.Windows.Controls.Canvas]::GetLeft((Get-T48Shapes $tag)[0]) }
function Get-T48Hex($brush) { return $brush.Color.ToString() }
function Get-T48Readout {
    if ($toleranceReadoutText.Text -notmatch "^Estimated: (\d+) keys, [\d.]+% of frames over tolerance, worst ([\d.]+)% of frame width\.$") { return "text:" + $toleranceReadoutText.Text }
    return "$($Matches[1]) keys, worst $($Matches[2])"
}
function Reset-T48RangeState {
    $allFramesRadio.IsChecked = $true
    $frontBackRadio.IsChecked = $true
    $script:lastTimeSliderRangeStart = $null
    $script:lastTimeSliderRangeEnd = $null
    $script:lastEstimateWorstPct = $null
    $script:lastEstimateRange = $null
    $script:tolVisualKey = $null
    $frameGateCheckBox.IsChecked = $true
}
# Set the Tolerance bar's inputs directly (no cache) and redraw.
function Set-T48Bar($tolPct, $worstPct, [bool]$gateOn = $true, [double]$zoom = 0) {
    $frameGateCheckBox.IsChecked = $gateOn
    $zoomSlider.Value = $zoom
    $script:lastValidTolerancePct = $tolPct
    $toleranceValueBox.Text = $(if ($null -eq $tolPct) { "Auto" } else { "$tolPct" })
    $script:lastEstimateWorstPct = $worstPct
    $script:tolVisualKey = $null
    Update-ToleranceVisual
}

# Range fixture: 6 frames, every pose 200 wide (max_w 200 -> frame 212.5,
# halfOrtho 106.25, with the 0..1000 rect from Reset-FrameGateTestState).
# Centres [0,0,0,30,30,30]. Gate ON, T = 2 % (cushion 4.25): All / 0-5 -> the
# guard keys at 0 (anchor), 3 (cam -> 19.5) and 5 (end); frames 3-5 then sit
# exactly 4.25 past the frame edge = worst 2.0 %, frames 0-2 never pass it.
# T72 Option B (2026-10-14): the keyer SEEDS its walk at the capture's Start
# frame, so a range starting at 3 restarts the guard there (cam 30, centred):
# 3-5 -> keys 3 (seed) and 5 (end), nothing passes the edge = worst 0. (Before
# T72 the walk was always seeded at frame 0 and 3-5 read worst 2.0.)
# Gate OFF (camera parked at the range's Start):
# All / 0-5 -> parked at 0, frames 3-5 are 23.75 past = 11.18 %; 3-5 -> parked
# at 30, nothing clips.
$script:t48RangeCachePath = Join-Path $env:TEMP "rom_launcher_test_t48_range_cache.json"
function Set-T48RangeCache {
    Set-Content -Path $script:frameGateTestRectPath -Value "0,0,1000,1080" -Encoding ASCII
    @{ frames = @(0,1,2,3,4,5); x_width = @(200,200,200,200,200,200); x_center = @(0,0,0,30,30,30); z_width = @(10,10,10,10,10,10); z_center = @(0,0,0,0,0,0) } |
        ConvertTo-Json | Set-Content -Path $script:t48RangeCachePath -Encoding UTF8
    $script:lastCachePath = $script:t48RangeCachePath
    $script:cachedFrameArrays = $null
    $zoomSlider.Value = 0
    $script:lastValidOffsetX = 0
}

Check "layout 3a: Adjust header with Reset at its right end, Zoom row, X/Y row with the pad, then toggle + 284 px Tolerance cell (226 diagram + 58 cap) with the readout under it; window 600 / MinHeight 522" {
    Reset-T48State; Reset-T48RangeState
    if ($window.Height -ne 600 -or $window.MinHeight -ne 549) { throw "window should be 600 high with MinHeight 549, got $($window.Height) / $($window.MinHeight)" }
    $root = Invoke-T48Layout ($window.Width - 16) ($window.Height - 39)
    $top = $window.FindName("AdjustTopGrid")
    $hdr = @($top.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq "Adjust" -and $_.FontWeight -eq [System.Windows.FontWeights]::Bold })
    if ($hdr.Count -ne 1 -or [System.Windows.Controls.Grid]::GetRow($hdr[0]) -ne 0) { throw "expected one bold 'Adjust' header in row 0" }
    if (@($top.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and @("Frame Offsets", "Frame Gate", "Tolerance") -contains $_.Text }).Count -ne 0) { throw "old section titles / the 'Tolerance' label must be gone" }
    if (@($window.FindName("AdjustGateGrid").Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq "Tolerance" }).Count -ne 0) { throw "no 'Tolerance' text label (user decision)" }
    $block = Get-T48Geo "FrameOffsetsGrid" $root
    $reset = Get-T48Geo "ResetFrameOffsetsButton" $root; $zoom = Get-T48Geo "ZoomValueBox" $root
    if ([Math]::Abs(($reset.X + $reset.W) - ($block.X + $block.W)) -gt 0.5) { throw "Reset must sit at the right end of the header (reset right $($reset.X + $reset.W), block right $($block.X + $block.W))" }
    if ($reset.Y + $reset.H -gt $zoom.Y + 0.5) { throw "Reset must be in the header, above the Zoom row" }
    $x = Get-T48Geo "OffsetXBox" $root; $y = Get-T48Geo "OffsetYBox" $root; $pad = Get-T48Geo "ArrowNudgePad" $root
    if (-not ($zoom.Y -lt $x.Y -and [Math]::Abs($x.Y - $y.Y) -lt 0.5)) { throw "X and Y share the row under Zoom" }
    if ($pad.X -lt $y.X + $y.W -or [Math]::Abs($pad.W - 24) -gt 0.5) { throw "24 px pad right of Y" }
    foreach ($b in @($zoom, $x, $y)) { if ([Math]::Abs($b.H - 24) -gt 0.5 -or $b.W -lt 44 - 0.5) { throw "boxes are 24 high, at least 44 wide" } }
    $gate = Get-T48Geo "FrameGateCheckBox" $root; $cell = Get-T48Geo "ToleranceCell" $root
    $vis = Get-T48Geo "TolVisualHost" $root; $cap = Get-T48Geo "TolNumberCap" $root; $ro = Get-T48Geo "ToleranceReadoutText" $root
    if ([Math]::Abs($cell.W - 284) -gt 0.5 -or [Math]::Abs($vis.W - 226) -gt 0.5 -or [Math]::Abs($cap.W - 58) -gt 0.5) { throw "cell 284 = 226 + 58, got $($cell.W) / $($vis.W) / $($cap.W)" }
    if ([Math]::Abs($vis.X - $cell.X) -gt 0.5 -or [Math]::Abs(($cap.X + $cap.W) - ($cell.X + $cell.W)) -gt 0.5) { throw "diagram at the left, cap at the right end" }
    if ($gate.X + $gate.W -gt $cell.X + 0.5 -or $gate.Y -lt $y.Y + 24) { throw "toggle left of the cell, under the X/Y row" }
    if ([Math]::Abs($ro.X - $cell.X) -gt 0.5 -or $ro.Y -lt $cell.Y + 24 - 0.5) { throw "readout starts under the cell" }
    $tb = Get-T48Geo "ToleranceValueBox" $root
    if ($tb.X -lt $cap.X -or $tb.X + $tb.W -gt $cap.X + $cap.W) { throw "the number box sits inside the cap" }
    if ($toleranceValueBox.BorderThickness.Left -ne 0 -or $toleranceValueBox.Background.Color.A -ne 0) { throw "the number box is transparent and borderless inside the cap" }
}

Check "layout 3a: nothing clipped at the default, 520 and MINIMUM widths, with the All AND the Start/End radio (its boxes shown) and a two-line readout; the log keeps its 80 px INSIDE its container; block 138.6 px with an empty readout" {
    Reset-T48State; Reset-T48RangeState
    $sizes = @(@(($window.Width - 16), ($window.Height - 39)), @(520, ($window.Height - 39)), @(($window.MinWidth - 16), ($window.MinHeight - 39)))
    $logParent = [System.Windows.Media.VisualTreeHelper]::GetParent($window.FindName("LogBox"))
    foreach ($mode in @("All", "StartEnd")) {
    if ($mode -eq "StartEnd") { $startEndRadio.IsChecked = $true } else { $allFramesRadio.IsChecked = $true }
    foreach ($sz in $sizes) {
        $toleranceReadoutText.Text = "Estimated: 480 keys, 44.6% of frames over tolerance, worst 20.7% of frame width."
        $root = Invoke-T48Layout $sz[0] $sz[1]
        $block = Get-T48Geo "FrameOffsetsGrid" $root
        foreach ($n in @("ZoomValueBox", "ZoomSlider", "OffsetXBox", "OffsetYBox", "ArrowNudgePad", "ResetFrameOffsetsButton", "FrameGateCheckBox", "ToleranceCell", "TolNumberCap", "ToleranceReadoutText")) {
            $g = Get-T48Geo $n $root
            if ($g.X + $g.W -gt $block.X + $block.W + 0.5) { throw "$n overflows the right edge at $($sz[0]) px (right $($g.X + $g.W) > $($block.X + $block.W))" }
            if ($g.W -le 0 -or $g.H -le 0) { throw "$n collapsed at $($sz[0]) px" }
        }
        if ($sz[0] -eq $window.MinWidth - 16 -and $toleranceReadoutText.ActualHeight -lt 25) { throw "the readout should wrap to two lines here ($mode, $($sz[0]) px), got height $($toleranceReadoutText.ActualHeight)" }
        $log = Get-T48Geo "LogBox" $root
        $lp = $logParent.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
        if ($log.H -lt 80 - 0.5) { throw "log squeezed below 80 at $($sz[0])x$($sz[1]) ($mode): $($log.H)" }
        if ($log.Y + $log.H -gt $lp.Y + $logParent.ActualHeight + 0.5) { throw "log clipped by its container at $($sz[0])x$($sz[1]) ($mode): log bottom $($log.Y + $log.H) > container bottom $($lp.Y + $logParent.ActualHeight)" }
    }
    }
    $allFramesRadio.IsChecked = $true
    $frameGateCheckBox.IsChecked = $false     # gate OFF clears the readout
    $root = Invoke-T48Layout ($window.Width - 16) ($window.Height - 39)
    $block = Get-T48Geo "FrameOffsetsGrid" $root
    if ($toleranceReadoutText.Text -ne "" -or [Math]::Abs($block.H - 138.6) -gt 1.0) { throw "block with an empty readout should be about 138.6 px, got $($block.H) ('$($toleranceReadoutText.Text)')" }
    $frameGateCheckBox.IsChecked = $true
}

Check "Tab order: Zoom box, slider, X, Y, Reset, Frame gate, Tolerance -- and no new Tab stop (diagram, cap, cell are not focusable)" {
    $order = @()
    $stack = New-Object System.Collections.Stack
    $stack.Push($window.FindName("FrameOffsetsGrid"))
    $visit = New-Object System.Collections.Generic.List[object]
    function Walk-T48($node) {
        if ($node -is [System.Windows.Controls.Control] -and $node.Focusable -and $node.IsTabStop) { $visit.Add($node.Name) }
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($node)) { if ($c -is [System.Windows.DependencyObject]) { Walk-T48 $c } }
    }
    Walk-T48 $window.FindName("FrameOffsetsGrid")
    $want = @("ZoomValueBox", "ZoomSlider", "OffsetXBox", "OffsetYBox", "ResetFrameOffsetsButton", "FrameGateCheckBox", "ToleranceValueBox")
    if (($visit -join ",") -ne ($want -join ",")) { throw "Tab stops in order: expected $($want -join ', '), got $($visit -join ', ')" }
    foreach ($n in @("ToleranceCell", "TolVisualHost", "TolNumberCap", "ArrowNudgePad")) {
        if ($window.FindName($n).Focusable) { throw "$n must not be focusable" }
    }
    foreach ($e in @($frameGateCheckBox, $toleranceValueBox, $resetFrameOffsetsButton)) { if ([System.Windows.Input.KeyboardNavigation]::GetTabIndex($e) -ne [int]::MaxValue) { throw "$($e.Name): no explicit TabIndex (document order rules)" } }
}

Check "Frame gate toggle (7a / ON-2): icon only; ON = dark pill + thin blue ring, blue fill, light brackets, no slash; OFF = grey fill, struck through; state tooltip" {
    Reset-T48State; Reset-T48RangeState
    $null = Invoke-T48Layout ($window.Width - 16) ($window.Height - 39)
    if ("$($frameGateCheckBox.Content)" -ne "" -or [System.Windows.Automation.AutomationProperties]::GetName($frameGateCheckBox) -ne "Frame gate") { throw "icon-only, but named 'Frame gate' for accessibility" }
    $t = $frameGateCheckBox.Template
    $pill = $t.FindName("Pill", $frameGateCheckBox); $fill = $t.FindName("GateFill", $frameGateCheckBox); $brk = $t.FindName("GateBrackets", $frameGateCheckBox); $slash = $t.FindName("GateSlash", $frameGateCheckBox)
    if ($null -eq $pill -or $null -eq $fill) { throw "template parts missing" }
    if ((Get-T48Hex $pill.Background) -ne "#FF1F1F1F" -or (Get-T48Hex $pill.BorderBrush) -ne "#FF2F8CFF" -or (Get-T48Hex $fill.Fill) -ne "#FF2F8CFF" -or (Get-T48Hex $brk.Stroke) -ne "#FFE6E6E6" -or $slash.Visibility -ne "Collapsed") {
        throw "ON look wrong: bg $(Get-T48Hex $pill.Background) ring $(Get-T48Hex $pill.BorderBrush) fill $(Get-T48Hex $fill.Fill) brackets $(Get-T48Hex $brk.Stroke) slash $($slash.Visibility)"
    }
    if ("$($frameGateCheckBox.ToolTip)" -notmatch "^Frame gate is ON") { throw "ON tooltip" }
    $frameGateCheckBox.IsChecked = $false
    $null = Invoke-T48Layout ($window.Width - 16) ($window.Height - 39)
    if ((Get-T48Hex $pill.Background) -ne "#FF1F1F1F" -or (Get-T48Hex $pill.BorderBrush) -ne "#FF5A5A5A" -or (Get-T48Hex $fill.Fill) -ne "#FF5A5A5A" -or $slash.Visibility -ne "Visible") { throw "OFF look wrong" }
    if ("$($frameGateCheckBox.ToolTip)" -notmatch "^Frame gate is OFF") { throw "OFF tooltip" }
    $frameGateCheckBox.IsChecked = $true
}

Check "Reset = the whole Adjust section: Zoom/X/Y 0, Frame gate back ON, Tolerance back to Auto (files written by the plain writers); a settling session is flushed first" {
    $testGatePath = Join-Path $env:TEMP "rom_launcher_test_t48_reset_gate.txt"
    function Get-FrameGatePath { return $testGatePath }
    Reset-T48State; Reset-T48RangeState
    $zoomSlider.Value = 10
    $offsetXBox.Text = "40"; Commit-OffsetBoxes
    $script:lastValidTolerancePct = 7.0; $toleranceValueBox.Text = "7"; Commit-ToleranceValueBox
    $frameGateCheckBox.IsChecked = $false
    Invoke-NumericStep "OffsetY" 1 $false $false      # a Y wheel session still settling
    $resetFrameOffsetsButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Stop-OffsetWheelNudge                             # a late settle must not resurrect Y = 10
    if ($zoomSlider.Value -ne 0 -or $script:lastValidOffsetX -ne 0 -or $script:lastValidOffsetY -ne 0) { throw "Zoom/X/Y must be 0, got $($zoomSlider.Value) / $($script:lastValidOffsetX) / $($script:lastValidOffsetY)" }
    if (-not $frameGateCheckBox.IsChecked) { throw "Frame gate must be back ON" }
    if ($null -ne $script:lastValidTolerancePct -or $toleranceValueBox.Text -ne "Auto") { throw "Tolerance must be back to Auto, got '$($toleranceValueBox.Text)'" }
    if ((Get-T48FileText $script:t48Zoom) -ne "0" -or (Get-T48FileText $script:liveTuneOffsetPath) -ne "0,0" -or (Get-T48FileText $script:t48Tol) -ne "" -or (Get-T48FileText $testGatePath) -ne "1") {
        throw "state files after Reset: zoom '$(Get-T48FileText $script:t48Zoom)' offset '$(Get-T48FileText $script:liveTuneOffsetPath)' tol '$(Get-T48FileText $script:t48Tol)' gate '$(Get-T48FileText $testGatePath)'"
    }
    $tolBytes = Get-T48FileBytes $script:t48Tol; Write-CameraTolerancePct -Value $null
    if ($tolBytes -ne (Get-T48FileBytes $script:t48Tol)) { throw "Reset's Auto tolerance bytes differ from the plain writer's" }
    $gateBytes = Get-T48FileBytes $testGatePath; Write-FrameGateEnabled -Enabled $true
    if ($gateBytes -ne (Get-T48FileBytes $testGatePath)) { throw "Reset's gate bytes differ from the plain writer's" }
    Remove-Item $testGatePath -ErrorAction SilentlyContinue
}

Check "Tolerance bar: LINEAR 10x mapping (0.5 / 2 / 10 / 20 % = 2.24 / 8.96 / 44.8 / 89.6 px per side), frame a fifth and centred, symmetric; % shown for a number, hidden for Auto" {
    Reset-T48State; Reset-T48RangeState
    foreach ($c in @(@(0.5, 2.24), @(2.0, 8.96), @(10.0, 44.8), @(20.0, 89.6))) {
        Set-T48Bar $c[0] $null
        $r = (Get-T48Shapes "used-R")[0]; $l = (Get-T48Shapes "used-L")[0]
        if ([Math]::Abs($r.Width - $c[1]) -gt 1e-6 -or [Math]::Abs($l.Width - $c[1]) -gt 1e-6) { throw "$($c[0])%: expected $($c[1]) px per side, got L $($l.Width) / R $($r.Width)" }
        if ([Math]::Abs((Get-T48ShapeLeft "used-R") - 134.4) -gt 1e-6 -or [Math]::Abs((Get-T48ShapeLeft "used-L") - (89.6 - $c[1])) -gt 1e-6) { throw "$($c[0])%: bands must start at the frame edges 89.6 / 134.4" }
        if ((Get-T48Shapes "slack-R").Count -ne 0 -or (Get-T48Shapes "over-R").Count -ne 0 -or (Get-T48Shapes "auto-R").Count -ne 0) { throw "$($c[0])% with no estimate: solid only" }
        if ($tolPctSuffix.Visibility -ne "Visible") { throw "'%' must show for a number" }
    }
    $f = (Get-T48Shapes "frame")[0]
    if ([Math]::Abs($f.Width - 44.8) -gt 1e-6 -or [Math]::Abs((Get-T48ShapeLeft "frame") - 89.6) -gt 1e-6) { throw "grey frame must be 44.8 px at 89.6" }
    if ((Get-T48Shapes "label-100").Count -ne 1 -or (Get-T48Shapes "label-x10").Count -ne 1 -or (Get-T48Shapes "tick-label").Count -ne 3) { throw "100% label, x10 mark and the 5/10/20 labels expected" }
    if ((@($tolVisualHost.Child.Children | Where-Object { $_.Tag -eq "tick-label" } | ForEach-Object { $_.Text }) -join ",") -ne "5,10,20") { throw "tick labels 5,10,20" }
    if ($tolVisualHost.Focusable -or $tolVisualHost.Child.Focusable) { throw "display-only" }
}

Check "Tolerance bar: Auto = zoom-derived value with a dashed outline + 'A' (2.0 at zoom 0, 0 at +20); gate OFF = fixed 2.0, '!' at the left and dashed caps; '%' hidden for Auto" {
    Reset-T48State; Reset-T48RangeState
    Set-T48Bar $null $null $true 0
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 8.96) -gt 1e-6 -or [Math]::Abs((Get-T48Shapes "auto-R")[0].Width - 8.96) -gt 1e-6) { throw "Auto at zoom 0 = 2.0 % = 8.96 px, dashed" }
    if ((Get-T48Shapes "auto-R")[0].StrokeDashArray.Count -eq 0 -or (Get-T48Shapes "auto-A").Count -ne 1 -or (Get-T48Shapes "used-R")[0].Opacity -ge 1) { throw "Auto must be dashed, paler, with an 'A'" }
    if ($tolPctSuffix.Visibility -ne "Collapsed") { throw "'%' hidden for Auto" }
    if ((Get-T48Shapes "cap-R")[0] -isnot [System.Windows.Shapes.Rectangle] -or (Get-T48Shapes "bang-off").Count -ne 0) { throw "gate ON: solid caps, no '!'" }
    Set-T48Bar $null $null $true 20
    if ((Get-T48Shapes "used-R").Count -ne 0 -or (Get-T48Shapes "auto-A").Count -ne 1) { throw "Auto at zoom +20 = 0: no band, still the 'A'" }
    Set-T48Bar $null $null $true -50
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 18.0 * 4.48) -gt 1e-6) { throw "Auto at zoom -50 = 18 %" }
    Set-T48Bar $null $null $false 20
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 8.96) -gt 1e-6) { throw "gate OFF Auto = fixed 2.0 % whatever the zoom" }
    if ((Get-T48Shapes "bang-off").Count -ne 1 -or (Get-T48Shapes "cap-L")[0] -isnot [System.Windows.Shapes.Line] -or (Get-T48Shapes "cap-L")[0].StrokeDashArray.Count -eq 0) { throw "gate OFF: '!' + dashed caps" }
    Set-T48Bar 5.0 $null $false 0
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 22.4) -gt 1e-6 -or (Get-T48Shapes "auto-A").Count -ne 0) { throw "gate OFF manual 5 % (threshold) = 22.4 px, no 'A'" }
    if ($toleranceValueBox.IsEnabled -eq $false) { throw "Tolerance stays editable with the gate OFF" }
    $frameGateCheckBox.IsChecked = $true; $zoomSlider.Value = 0
}

Check "Tolerance bar W5 split from the stored worst NUMBER: lt = solid used + pale dashed slack; eq = all solid; gt = red outlined over + '!'; no estimate = no marker" {
    Reset-T48State; Reset-T48RangeState
    Set-T48Bar 10.0 6.3
    $script:lastEstimateWorstPct = 2.0; Update-ToleranceVisual       # ONLY the worst changes: the bar must redraw
    if ([Math]::Abs((Get-T48Shapes "slack-R")[0].Width - 8.0 * 4.48) -gt 1e-6) { throw "a new worst value alone must redraw the bar (slack 8 %), got $((Get-T48Shapes 'slack-R')[0].Width)" }
    $script:lastEstimateWorstPct = 6.3; Update-ToleranceVisual
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 6.3 * 4.48) -gt 1e-6 -or [Math]::Abs((Get-T48Shapes "slack-R")[0].Width - 3.7 * 4.48) -gt 1e-6) { throw "lt: used 6.3 % + slack 3.7 %" }
    if ([Math]::Abs((Get-T48ShapeLeft "slack-R") - (134.4 + 6.3 * 4.48)) -gt 1e-6 -or (Get-T48Shapes "slack-R")[0].StrokeDashArray.Count -eq 0) { throw "slack sits after the used part, dashed" }
    if ((Get-T48Shapes "over-R").Count -ne 0 -or (Get-T48Shapes "bang-over").Count -ne 0) { throw "lt: no over" }
    if ("$($tolVisualHost.ToolTip)".IndexOf("worst 6.3%") -lt 0) { throw "tooltip carries the worst value" }
    Set-T48Bar 2.0 2.0
    if ([Math]::Abs((Get-T48Shapes "used-R")[0].Width - 8.96) -gt 1e-6 -or (Get-T48Shapes "slack-R").Count -ne 0 -or (Get-T48Shapes "over-R").Count -ne 0) { throw "eq: all solid" }
    Set-T48Bar 2.0 12.0
    $over = (Get-T48Shapes "over-R")[0]
    if ($null -eq $over -or [Math]::Abs($over.Width - 10 * 4.48) -gt 1e-6 -or [Math]::Abs((Get-T48ShapeLeft "over-R") - (134.4 + 8.96)) -gt 1e-6) { throw "gt: red over 10 % after the 2 % margin" }
    if ((Get-T48Hex $over.Stroke) -ne "#FFE0786E" -or (Get-T48Shapes "bang-over").Count -ne 1 -or (Get-T48Shapes "over-L").Count -ne 1) { throw "gt: red outline + '!' (colour AND mark), both sides" }
    Set-T48Bar 2.0 $null
    if ((Get-T48Shapes "slack-R").Count + (Get-T48Shapes "over-R").Count + (Get-T48Shapes "bang-over").Count -ne 0) { throw "no estimate: no marker" }
    $script:lastValidTolerancePct = $null; $toleranceValueBox.Text = "Auto"
}

Check "Tolerance cell: the wheel over the diagram / the cap steps the number like the box (once; from Auto at Auto's value); the cap click focuses the box; clicks on the box are left alone" {
    Reset-T48State; Reset-T48RangeState
    $script:t48FocusCalls = 0
    function Set-ToleranceBoxFocus { $script:t48FocusCalls++ }
    $ev = Send-T48Wheel $tolVisualHost 120
    if (-not $ev.Handled -or $script:lastValidTolerancePct -ne 3) { throw "wheel over the diagram from Auto (zoom 0) should give 3, got $($script:lastValidTolerancePct)" }
    $null = Send-T48Wheel $tolNumberCap -120
    if ($script:lastValidTolerancePct -ne 2) { throw "wheel over the cap should step down to 2, got $($script:lastValidTolerancePct)" }
    $null = Send-T48Wheel $toleranceValueBox 120
    if ($script:lastValidTolerancePct -ne 3) { throw "wheel over the box steps ONCE (3), got $($script:lastValidTolerancePct)" }
    $script:modifierKeysOverride = [System.Windows.Input.ModifierKeys]::Control
    try { $null = Send-T48Wheel $tolVisualHost 120 } finally { $script:modifierKeysOverride = $null }
    if ($toleranceValueBox.Text -ne "3.1") { throw "Ctrl+wheel over the diagram = 0.1, got '$($toleranceValueBox.Text)'" }
    $md = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $md.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
    $tolNumberCap.Child.RaiseEvent($md)              # the cap's padding (the "%" is not hit-testable)
    if ($script:t48FocusCalls -ne 1 -or -not $md.Handled) { throw "a click on the cap ('%') must focus the box, calls=$($script:t48FocusCalls)" }
    $md2 = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $md2.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
    $toleranceValueBox.RaiseEvent($md2)
    if ($script:t48FocusCalls -ne 1) { throw "a click on the box itself is the box's own (caret/selection)" }
}

Check "time range (gate ON): Estimated / worst / bar are measured over the chosen range on a guard walk SEEDED at the range Start (T72 Option B); recomputed on radio and Start/End changes" {
    Reset-T48State; Reset-T48RangeState; Set-T48RangeCache
    $script:lastValidTolerancePct = 2.0; $toleranceValueBox.Text = "2"; Commit-ToleranceValueBox
    Update-ToleranceReadout
    if ((Get-T48Readout) -ne "3 keys, worst 2") { throw "All: '$($toleranceReadoutText.Text)'" }
    if ([Math]::Abs($script:lastEstimateWorstPct - 2.0) -gt 1e-9) { throw "All: worst stored as the number 2.0, got $($script:lastEstimateWorstPct)" }
    $startFrameBox.Text = "0"; $endFrameBox.Text = "2"
    $startEndRadio.IsChecked = $true                  # recompute on the radio, no explicit call
    if ((Get-T48Readout) -ne "1 keys, worst 0" -or $script:lastEstimateWorstPct -ne 0) { throw "0-2: '$($toleranceReadoutText.Text)' worst $($script:lastEstimateWorstPct)" }
    $startFrameBox.Text = "3"; $endFrameBox.Text = "5"   # recompute on TextChanged
    if ((Get-T48Readout) -ne "2 keys, worst 0") { throw "3-5: the walk is seeded at Start (T72), keys 3 + 5, worst 0 (not the frame-0-seeded 2.0): '$($toleranceReadoutText.Text)'" }
    $endFrameBox.Text = "1"
    if ($toleranceReadoutText.Text -ne "Estimated: -- (Start is after End)" -or $null -ne $script:lastEstimateWorstPct) { throw "reversed: '$($toleranceReadoutText.Text)'" }
    if ((Get-T48Shapes "slack-R").Count + (Get-T48Shapes "over-R").Count -ne 0) { throw "unknown range: no worst marker on the bar" }
    $endFrameBox.Text = "3"                           # 3-3: the Start frame alone is the seed (centred), so 0
    if ((Get-T48Readout) -ne "1 keys, worst 0") { throw "3-3: the recording's Start frame is the walk's seed key, got '$($toleranceReadoutText.Text)'" }
    $endFrameBox.Text = "5"; $startFrameBox.Text = "4"
    if ((Get-T48Readout) -ne "2 keys, worst 0") { throw "4-5: seed 4 + end 5, nothing passes the edge: '$($toleranceReadoutText.Text)'" }
    if ("$($tolVisualHost.ToolTip)".IndexOf("over frames 4-5") -lt 0) { throw "tooltip names the measured frames" }
    $allFramesRadio.IsChecked = $true
    if ((Get-T48Readout) -ne "3 keys, worst 2") { throw "back to All: '$($toleranceReadoutText.Text)'" }
}

Check "time range: Time Slider = the last range a Preview / Start Recording click resolved from Maya; none yet -> 'range unknown', never a guess" {
    Reset-T48State; Reset-T48RangeState; Set-T48RangeCache
    $script:lastValidTolerancePct = 2.0; $toleranceValueBox.Text = "2"; Commit-ToleranceValueBox
    $timeSliderRadio.IsChecked = $true
    if ($toleranceReadoutText.Text -ne "Estimated: -- (Time Slider range unknown until Preview reads it from Maya)" -or $null -ne $script:lastEstimateWorstPct) { throw "unknown: '$($toleranceReadoutText.Text)'" }
    function Get-TimeSliderRange { return [PSCustomObject]@{ Success = $true; Start = 3; End = 5; ErrorMessage = $null } }
    $resolved = Get-ResolvedTimeRange
    if (-not $resolved.Success) { throw "resolution should succeed" }
    Update-ToleranceReadout
    if ((Get-T48Readout) -ne "2 keys, worst 0") { throw "Time Slider 3-5: '$($toleranceReadoutText.Text)'" }
    function Get-TimeSliderRange { return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "No response from Maya." } }
    $null = Get-ResolvedTimeRange
    Update-ToleranceReadout
    if ((Get-T48Readout) -ne "2 keys, worst 0") { throw "a failed later read keeps the last known range" }
    $allFramesRadio.IsChecked = $true
}

Check "time range (gate OFF): the bar's worst and the Preview glow use the fixed-camera estimate over the chosen range (camera parked at its Start)" {
    Reset-T48State; Reset-T48RangeState; Set-T48RangeCache
    $frameGateCheckBox.IsChecked = $false
    Update-ToleranceReadout; Update-FrameGateGlow
    if ($toleranceReadoutText.Text -ne "" -or [Math]::Abs($script:lastEstimateWorstPct - (100 * 23.75 / 212.5)) -gt 1e-9) { throw "All: worst should be 11.18 %, got $($script:lastEstimateWorstPct)" }
    if ($null -eq $previewButton.Effect) { throw "All: red glow expected" }
    if ((Get-T48Shapes "over-R").Count -ne 1 -or (Get-T48Shapes "bang-over").Count -ne 1) { throw "All: red over on the bar" }
    $startFrameBox.Text = "3"; $endFrameBox.Text = "5"; $startEndRadio.IsChecked = $true
    Update-FrameGateGlow
    if ($script:lastEstimateWorstPct -ne 0 -or $null -ne $previewButton.Effect) { throw "3-5 (parked at 30): nothing clips, got worst $($script:lastEstimateWorstPct)" }
    $startFrameBox.Text = "0"
    Update-FrameGateGlow
    if ([Math]::Abs($script:lastEstimateWorstPct - (100 * 23.75 / 212.5)) -gt 1e-9 -or $null -eq $previewButton.Effect) { throw "0-5: parked at 0, 11.18 % again" }
    $frameGateCheckBox.IsChecked = $true; $allFramesRadio.IsChecked = $true; $previewButton.Effect = $null
}

Check "no estimate: no cache -> 'Estimated: -- (open Preview once to see keys and worst overshoot)', worst `$null, no marker" {
    Reset-T48State; Reset-T48RangeState
    $script:lastCachePath = $null; $script:cachedFrameArrays = $null
    Update-ToleranceReadout
    if ($toleranceReadoutText.Text -ne "Estimated: -- (open Preview once to see keys and worst overshoot)" -or $null -ne $script:lastEstimateWorstPct) { throw "got '$($toleranceReadoutText.Text)'" }
    if ((Get-T48Shapes "slack-R").Count + (Get-T48Shapes "over-R").Count + (Get-T48Shapes "bang-over").Count -ne 0) { throw "no marker without an estimate" }
}

Check "F1: Tolerance Up/Down from Auto seed from Auto's ZOOM value (gate ON) or the fixed 2.0 (gate OFF), no cache needed" {
    Reset-T48State; Reset-T48RangeState
    $zoomSlider.Value = 20
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($script:lastValidTolerancePct -ne 1) { throw "gate ON zoom +20: Auto 0 then Up = 1, got $($script:lastValidTolerancePct)" }
    $script:lastValidTolerancePct = $null; $toleranceValueBox.Text = "Auto"
    $frameGateCheckBox.IsChecked = $false
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($script:lastValidTolerancePct -ne 3) { throw "gate OFF: Auto = 2.0 threshold then Up = 3, got $($script:lastValidTolerancePct)" }
    $script:lastValidTolerancePct = $null; $toleranceValueBox.Text = "Auto"
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Down)
    if ($script:lastValidTolerancePct -ne 1) { throw "gate OFF: 2.0 then Down = 1, got $($script:lastValidTolerancePct)" }
    $frameGateCheckBox.IsChecked = $true
    $script:lastValidTolerancePct = $null; $toleranceValueBox.Text = "Auto"; $zoomSlider.Value = -50
    $null = Send-T48Key $toleranceValueBox ([System.Windows.Input.Key]::Up)
    if ($script:lastValidTolerancePct -ne 19) { throw "zoom -50: Auto 18 then Up = 19, got $($script:lastValidTolerancePct)" }
}

Check "F2: the X/Y WHEEL commits typed-but-uncommitted text first (like Up/Down), then steps" {
    Reset-T48State; Reset-T48RangeState
    $offsetXBox.Text = "25"
    $null = Send-T48Wheel $offsetXBox 120 $false
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetX -ne 35 -or $script:pendingNudgeDeltaX -ne 35) { throw "typed 25 then wheel up = 35 (one delta of 35), got $($script:lastValidOffsetX) / $($script:pendingNudgeDeltaX)" }
    $offsetYBox.Text = "-5"
    $null = Send-T48Wheel $offsetYBox -120 $false
    Stop-OffsetWheelNudge
    if ($script:lastValidOffsetY -ne -15) { throw "typed -5 then wheel down = -15, got $($script:lastValidOffsetY)" }
    if ((Get-T48FileText $script:liveTuneOffsetPath) -ne "35,-15") { throw "file '35,-15' expected, got '$(Get-T48FileText $script:liveTuneOffsetPath)'" }
}

Check "F3: a real thumb drag that starts while a key/wheel step is settling keeps its push-hold until the drag completes" {
    Reset-T48State; Reset-T48RangeState
    Invoke-NumericStep "Zoom" 1 $false $false
    $ds = New-Object System.Windows.Controls.Primitives.DragStartedEventArgs(0.0, 0.0)
    $zoomSlider.RaiseEvent($ds)
    Stop-ZoomStep                                       # the 400 ms settle fires mid-drag
    if (-not $script:zoomSliderDragging) { throw "the settle must not release the hold during a real drag" }
    if ($script:pendingZoomPush) { throw "no Maya push from the settle while the thumb is held (the drag's completion pushes once)" }
    $zoomSlider.Value = 25                              # the drag moves on: no live push yet
    if ($script:pendingZoomPush) { throw "no push while the thumb is still held" }
    $dc = New-Object System.Windows.Controls.Primitives.DragCompletedEventArgs(0.0, 0.0, $false)
    $zoomSlider.RaiseEvent($dc)
    if ($script:zoomSliderDragging -or $script:zoomThumbDragging -or -not $script:pendingZoomPush) { throw "drag completion releases the hold and pushes once" }
}

Check "F4: 'NaN' / 'Infinity' typed in Zoom, Tolerance or X/Y revert like garbage; Zoom Up after NaN steps from the last value and the push-hold always has its settle" {
    Reset-T48State; Reset-T48RangeState
    $zoomValueBox.Text = "NaN"
    $null = Send-T48Key $zoomValueBox ([System.Windows.Input.Key]::Up)
    if ($zoomSlider.Value -ne 10 -or $zoomValueBox.Text -ne "+10") { throw "NaN reverts to 0 then Up = +10, got $($zoomSlider.Value) / '$($zoomValueBox.Text)'" }
    if (-not $script:zoomStepActive -or -not $script:zoomStepSettleTimer.IsEnabled) { throw "the hold must come with a running settle timer" }
    Stop-ZoomStep
    if ($script:zoomSliderDragging -or -not $script:pendingZoomPush) { throw "settle releases and pushes" }
    $zoomValueBox.Text = "-Infinity"; Commit-ZoomValueBox
    if ($zoomSlider.Value -ne 10 -or $zoomValueBox.Text -ne "+10") { throw "-Infinity reverts" }
    $script:lastValidTolerancePct = 4.0; $toleranceValueBox.Text = "NaN"; Commit-ToleranceValueBox
    if ($script:lastValidTolerancePct -ne 4 -or $toleranceValueBox.Text -ne "4" -or (Get-T48FileText $script:t48Tol) -ne "4") { throw "NaN tolerance reverts to 4, got '$($toleranceValueBox.Text)'" }
    $offsetXBox.Text = "Infinity"; $offsetYBox.Text = "NaN"; Commit-OffsetBoxes
    if ($script:lastValidOffsetX -ne 0 -or $script:lastValidOffsetY -ne 0 -or $offsetXBox.Text -ne "0" -or (Get-T48FileText $script:liveTuneOffsetPath) -ne "0,0") { throw "non-finite X/Y revert" }
}

Check "F6: the slider's own Right/Left/PageUp/PageDown/Home/End keys still move it, but push to Maya once after the settle, not per press" {
    # The real tunnelling key event goes through the launcher's handler; the slider's
    # OWN move is then driven by its routed command (what its key gesture invokes).
    # WPF matches those gestures against the PHYSICAL keyboard's modifiers, which no
    # test seam can override, so raising the native key here would make this check
    # depend on what the user happens to hold during the run.
    Reset-T48State; Reset-T48RangeState
    $S = [System.Windows.Controls.Slider]
    foreach ($kc in @(@([System.Windows.Input.Key]::Right, $S::IncreaseSmall), @([System.Windows.Input.Key]::Right, $S::IncreaseSmall), @([System.Windows.Input.Key]::PageUp, $S::IncreaseLarge))) {
        $pre = Send-T48Key $zoomSlider $kc[0]                # tunnelling: joins the hold, not claimed
        if ($pre.Handled) { throw "$($kc[0]) must not be claimed by the stepping handler" }
        $kc[1].Execute($null, $zoomSlider)                   # the slider moves itself
    }
    if ($zoomSlider.Value -ne 12) { throw "Right, Right, PageUp = +12, got $($zoomSlider.Value)" }
    if ($script:pendingZoomPush) { throw "no push per press" }
    Stop-ZoomStep
    if (-not $script:pendingZoomPush -or $script:zoomSliderDragging) { throw "one push after the settle" }
    $script:pendingZoomPush = $false
    $null = Send-T48Key $zoomSlider ([System.Windows.Input.Key]::Home)
    $S::MinimizeValue.Execute($null, $zoomSlider)
    if ($zoomSlider.Value -ne -50 -or $script:pendingZoomPush) { throw "Home -> -50, held" }
    Stop-ZoomStep
    if (-not $script:pendingZoomPush) { throw "Home pushes once after the settle" }
    foreach ($k in @([System.Windows.Input.Key]::Left, [System.Windows.Input.Key]::PageDown, [System.Windows.Input.Key]::End)) {
        Reset-T48State
        $null = Send-T48Key $zoomSlider $k
        if (-not $script:zoomStepActive) { throw "$k must join the push-hold" }
    }
    Reset-T48State
    $null = Send-T48Key $zoomSlider ([System.Windows.Input.Key]::A)
    if ($script:zoomStepActive) { throw "other keys must not start a hold" }
}
Check "settle delays: the zoom key/wheel step and the X/Y wheel/arrow sessions push to Maya 400 ms after the last input" {
    if ($script:zoomStepSettleTimer.Interval.TotalMilliseconds -ne 400) { throw "zoom step settle should be 400 ms, got $($script:zoomStepSettleTimer.Interval.TotalMilliseconds)" }
    if ($script:wheelSettleTimer.Interval.TotalMilliseconds -ne 400) { throw "X/Y wheel settle should be 400 ms, got $($script:wheelSettleTimer.Interval.TotalMilliseconds)" }
}

Check "over-tolerance counts ignore floating-point noise at the limit (1e-9 x frame width); keys and worst unchanged (real barM, offset 0)" {
    Set-RealBarmCacheState
    $script:lastValidOffsetX = 0
    $cases = @(@(0, $null, 70, 2.0, 0.0), @(0, 2.0, 70, 2.0, 0.0), @(20, 2.0, 395, 15.82, 14.01))
    foreach ($c in $cases) {
        $r = Get-ToleranceReadoutEstimate -Axis "FrontBack" -ZoomPct $c[0] -OffsetXPx 0 -ManualTolerancePct $c[1]
        if ($r.Keys -ne $c[2] -or [Math]::Abs($r.WorstOverflowPct - $c[3]) -gt 0.01) { throw "zoom $($c[0]) T $($c[1]): keys/worst must stay $($c[2]) / $($c[3]), got $($r.Keys) / $($r.WorstOverflowPct)" }
        if ([Math]::Abs($r.PercentOverTolerance - $c[4]) -gt 0.01) { throw "zoom $($c[0]) T $($c[1]): frames parked AT the limit are not over: expected $($c[4])%, got $($r.PercentOverTolerance)" }
    }
    # gate OFF core: a pose whose edge sits on the frame edge up to float noise (0.1 + 0.2 vs 0.3) is not clipped
    $off = Get-ClippingEstimateCore -CenterX @(0.1 + 0.2) -WidthX @(0.0) -CamPosX 0.0 -HalfOrtho 0.3 -StartIndex 0 -EndIndex 0
    if ($off.PercentClipped -ne 0) { throw "float noise at the edge must not count as clipped, got $($off.PercentClipped)%" }
    $off2 = Get-ClippingEstimateCore -CenterX @(0.31) -WidthX @(0.0) -CamPosX 0.0 -HalfOrtho 0.3 -StartIndex 0 -EndIndex 0
    if ($off2.PercentClipped -ne 100) { throw "a real overshoot still counts, got $($off2.PercentClipped)%" }
    $script:lastCachePath = $null; $script:cachedFrameArrays = $null; $zoomSlider.Value = 0
}

Check "per-tick memo: the Estimated line and the gate-OFF worst recompute when ANY input changes (zoom, X, tolerance, cache, monitor rect), and a repeat tick with nothing changed returns the same numbers" {
    Reset-T48State; Reset-T48RangeState; Set-T48RangeCache
    $script:lastValidTolerancePct = 2.0; $toleranceValueBox.Text = "2"; Commit-ToleranceValueBox
    Update-ToleranceReadout; $base = $toleranceReadoutText.Text; $baseW = $script:lastEstimateWorstPct
    Update-ToleranceReadout
    if ($toleranceReadoutText.Text -ne $base -or $script:lastEstimateWorstPct -ne $baseW) { throw "an idle repeat must give the same numbers" }
    $zoomSlider.Value = 20; Update-ToleranceReadout
    if ($script:lastEstimateWorstPct -le 20) { throw "zoom +20 must recompute (poses wider than the frame), worst $($script:lastEstimateWorstPct)" }
    $zoomSlider.Value = 0; Update-ToleranceReadout
    if ($script:lastEstimateWorstPct -ne $baseW) { throw "back to zoom 0 must give the zoom-0 worst again" }
    $script:lastValidOffsetX = 50; Update-ToleranceReadout
    $w50 = $script:lastEstimateWorstPct
    if ($w50 -eq $baseW) { throw "X offset 50 must recompute" }
    Set-Content -Path $script:frameGateTestRectPath -Value "0,0,2000,1080" -Encoding ASCII; Update-ToleranceReadout
    if ($script:lastEstimateWorstPct -eq $w50) { throw "a different monitor rect (px -> world) must recompute" }
    Set-Content -Path $script:frameGateTestRectPath -Value "0,0,1000,1080" -Encoding ASCII
    $script:lastValidOffsetX = 0
    $script:lastValidTolerancePct = 10.0; $toleranceValueBox.Text = "10"; Commit-ToleranceValueBox; Update-ToleranceReadout
    if ($toleranceReadoutText.Text -eq $base) { throw "a new tolerance must recompute" }
    $script:lastValidTolerancePct = 2.0; $toleranceValueBox.Text = "2"; Commit-ToleranceValueBox
    @{ frames = @(0,1,2,3,4,5); x_width = @(200,200,200,200,200,200); x_center = @(0,0,0,0,0,0); z_width = @(10,10,10,10,10,10); z_center = @(0,0,0,0,0,0) } |
        ConvertTo-Json | Set-Content -Path $script:t48RangeCachePath -Encoding UTF8
    $script:cachedFrameArrays = $null; Update-ToleranceReadout
    if ($script:lastEstimateWorstPct -ne 0) { throw "a re-parsed cache must recompute (static poses: worst 0), got $($script:lastEstimateWorstPct)" }
    Set-T48RangeCache
    $frameGateCheckBox.IsChecked = $false
    $offBase = $script:lastEstimateWorstPct
    $script:lastValidOffsetX = 40; Update-ToleranceReadout
    if ($script:lastEstimateWorstPct -eq $offBase) { throw "gate OFF: X offset must recompute the fixed-camera worst" }
    $zoomSlider.Value = 10; Update-ToleranceReadout
    $offZ = $script:lastEstimateWorstPct
    $zoomSlider.Value = 0; Update-ToleranceReadout
    if ($offZ -eq $script:lastEstimateWorstPct) { throw "gate OFF: zoom must recompute" }
    $script:lastValidOffsetX = 0; $frameGateCheckBox.IsChecked = $true
}
Check "the Estimated line goes through the ONE formatter (Format-EstimateReadoutText, the bar's rounding rule)" {
    Reset-T48State; Reset-T48RangeState; Set-T48RangeCache
    function Format-EstimateReadoutText { param($Keys, $OverPct, $WorstPct) return "FORMATTER:$Keys" }
    Update-ToleranceReadout
    if ($toleranceReadoutText.Text -ne "FORMATTER:3") { throw "readout must come from Format-EstimateReadoutText, got '$($toleranceReadoutText.Text)'" }
}

Check "Maya-bound state bytes: zoom / offset / tolerance / gate files written by the rebuilt paths equal the plain writers' for the same values" {
    $testGatePath = Join-Path $env:TEMP "rom_launcher_test_t48_bytes_gate.txt"
    function Get-FrameGatePath { return $testGatePath }
    Reset-T48State; Reset-T48RangeState
    $cases = @(
        @{ Do = { $zoomValueBox.Text = "17"; Commit-ZoomValueBox }; File = { $script:t48Zoom }; Plain = { Write-CameraZoomPct -Value 17 } },
        @{ Do = { $offsetXBox.Text = "-33"; $offsetYBox.Text = "8"; Commit-OffsetBoxes }; File = { $script:liveTuneOffsetPath }; Plain = { Write-CameraOffsetPx -X -33 -Y 8 } },
        @{ Do = { $toleranceValueBox.Text = "3.5"; Commit-ToleranceValueBox }; File = { $script:t48Tol }; Plain = { Write-CameraTolerancePct -Value 3.5 } },
        @{ Do = { $toleranceValueBox.Text = ""; Commit-ToleranceValueBox }; File = { $script:t48Tol }; Plain = { Write-CameraTolerancePct -Value $null } },
        @{ Do = { $frameGateCheckBox.IsChecked = $false }; File = { $testGatePath }; Plain = { Write-FrameGateEnabled -Enabled $false } }
    )
    foreach ($c in $cases) {
        & $c.Do
        $a = Get-T48FileBytes (& $c.File)
        & $c.Plain
        if ($a -ne (Get-T48FileBytes (& $c.File))) { throw "bytes differ for $($c.Do)" }
    }
    $frameGateCheckBox.IsChecked = $true
    Remove-Item $testGatePath -ErrorAction SilentlyContinue
}

Reset-T48RangeState
Remove-Item $script:t48RangeCachePath -ErrorAction SilentlyContinue

Reset-T48State
$zoomSlider.Value = 0
$script:pendingZoomPush = $false
${function:Get-CameraZoomPctPath} = $script:t48RealZoomPathFn
${function:Get-CameraTolerancePctPath} = $script:t48RealTolPathFn
Remove-Item $script:t48Zoom -ErrorAction SilentlyContinue
Remove-Item $script:t48Tol -ErrorAction SilentlyContinue
try { $script:t48Source.Dispose() } catch { }

Remove-Item $script:frameGateTestCachePath -ErrorAction SilentlyContinue
Remove-Item $script:frameGateTestRectPath -ErrorAction SilentlyContinue
Remove-Item $script:frameGateGlowTestCachePath -ErrorAction SilentlyContinue
$script:lastCachePath = $null
$script:cachedFrameArrays = $null
$frameGateCheckBox.IsChecked = $true
Write-FrameGateEnabled -Enabled $true

# ---------------------------------------------------------------- T87 phase 2: top busy bar + async scene-name fill
# Hermetic: Start-SceneNameProcess is replaced by a fake process object (no
# powershell / send_to_maya / Maya), Get-SceneNameResultPath points at a temp
# file the test writes, Get-PrefixAsyncElapsedMs returns a test clock, and
# Update-PrefixFillAsync (the timer's tick) is called directly.
$script:t87ResultPath = Join-Path $env:TEMP ("t87_scene_result_" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
function New-T87FakeProcess {
    $p = [PSCustomObject]@{ HasExited = $false; Killed = $false; Disposed = $false }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.Killed = $true; $this.HasExited = $true }
    $p | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
    return $p
}
function Reset-T87Async {
    if ($script:prefixAsync) { Stop-PrefixFillAsync -Silent }
    $prefixBox.Text = ""
    $script:prefixLastAutoFill = ""
    $logBox.Clear()
    Remove-Item $script:t87ResultPath -ErrorAction SilentlyContinue
}

Check "T87: Show-PrefixBusy / Hide-PrefixBusy show and hide the top bar (never left visible)" {
    $bar = $window.FindName("TopBusyBar")
    if ($bar.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "bar not collapsed at start" }
    Show-PrefixBusy
    if ($bar.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Show-PrefixBusy did not show it" }
    Hide-PrefixBusy
    if ($bar.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "Hide-PrefixBusy did not hide it" }
    Hide-PrefixBusy
    if ($bar.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "a second hide changed it" }
}

Check "T87: async fill -- one process, bar while waiting, completion fills the box, bar hidden, one log line" {
    Reset-T87Async
    $script:t87Starts = 0
    function Get-SceneNameResultPath { return $script:t87ResultPath }
    function Start-SceneNameProcess { param([int]$TimeoutMs) $script:t87Starts++; $script:t87Proc = New-T87FakeProcess; return $script:t87Proc }
    function Get-PrefixAsyncElapsedMs { return 200 }
    try {
        if (-not (Start-PrefixFillAsync -Trigger "Maya connected")) { throw "did not start" }
        if ($window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Visible) { throw "bar not shown while waiting" }
        if (Start-PrefixFillAsync -Trigger "Maya connected") { throw "a second fill started while one runs" }
        if ($script:t87Starts -ne 1) { throw "$($script:t87Starts) processes started" }
        Update-PrefixFillAsync
        if (-not $script:prefixAsync) { throw "finished before the process exited" }
        [IO.File]::WriteAllText($script:t87ResultPath, "SCENE_NAME scene_a`n")
        $script:t87Proc.HasExited = $true
        Update-PrefixFillAsync
        if ($prefixBox.Text -cne "scene_a") { throw "box '$($prefixBox.Text)'" }
        if ($script:prefixLastAutoFill -cne "scene_a") { throw "last auto fill '$($script:prefixLastAutoFill)'" }
        if ($script:prefixAsync) { throw "state not cleared" }
        if ($window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "bar still visible" }
        if ($prefixHint.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "hint still visible over the text" }
        $lines = @($logBox.Text -split "`n" | Where-Object { $_ -like "Prefix*" })
        if ($lines.Count -ne 1 -or $lines[0] -notlike "*scene_a*") { throw "log: $($logBox.Text)" }
        if (-not $script:t87Proc.Disposed) { throw "process not disposed" }
    } finally { Reset-T87Async }
}

Check "T87: async fill time-out -> process killed, bar hidden, box unchanged, ONE log line" {
    Reset-T87Async
    function Get-SceneNameResultPath { return $script:t87ResultPath }
    function Start-SceneNameProcess { param([int]$TimeoutMs) $script:t87Proc = New-T87FakeProcess; return $script:t87Proc }
    $script:t87Clock = 100
    function Get-PrefixAsyncElapsedMs { return $script:t87Clock }
    try {
        Start-PrefixFillAsync -Trigger "Maya already open" | Out-Null
        Update-PrefixFillAsync
        $script:t87Clock = 60000
        Update-PrefixFillAsync
        if (-not $script:t87Proc.Killed) { throw "process not killed" }
        if ($script:prefixAsync) { throw "state not cleared" }
        if ($window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "bar stuck visible" }
        if ($prefixBox.Text -ne "") { throw "box changed to '$($prefixBox.Text)'" }
        $lines = @($logBox.Text -split "`n" | Where-Object { $_ -like "Prefix*" })
        if ($lines.Count -ne 1 -or $lines[0] -notlike "*did not answer*") { throw "log: $($logBox.Text)" }
        Update-PrefixFillAsync
        if (@($logBox.Text -split "`n" | Where-Object { $_ -like "Prefix*" }).Count -ne 1) { throw "a later tick logged again" }
    } finally { Reset-T87Async }
}

Check "T87: async completion never touches text typed while it was running; stale value is refreshed" {
    Reset-T87Async
    function Get-SceneNameResultPath { return $script:t87ResultPath }
    function Start-SceneNameProcess { param([int]$TimeoutMs) $script:t87Proc = New-T87FakeProcess; return $script:t87Proc }
    function Get-PrefixAsyncElapsedMs { return 300 }
    try {
        Start-PrefixFillAsync -Trigger "Maya connected" | Out-Null
        $prefixBox.Text = "my_take"
        [IO.File]::WriteAllText($script:t87ResultPath, "SCENE_NAME scene_a`n")
        $script:t87Proc.HasExited = $true
        Update-PrefixFillAsync
        if ($prefixBox.Text -cne "my_take") { throw "typed text replaced by '$($prefixBox.Text)'" }
        if ($window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "bar stuck" }
        # stale rule: an unedited auto-filled value follows the next scene
        $prefixBox.Text = "scene_a"; $script:prefixLastAutoFill = "scene_a"
        Start-PrefixFillAsync -Trigger "Maya connected" | Out-Null
        [IO.File]::WriteAllText($script:t87ResultPath, "SCENE_NAME scene_b`n")
        $script:t87Proc.HasExited = $true
        Update-PrefixFillAsync
        if ($prefixBox.Text -cne "scene_b") { throw "stale value not refreshed: '$($prefixBox.Text)'" }
    } finally { Reset-T87Async }
}

Check "T87: async fill is skipped during a run and discarded if a run starts meanwhile (bar hidden)" {
    Reset-T87Async
    function Get-SceneNameResultPath { return $script:t87ResultPath }
    $script:t87Starts = 0
    function Start-SceneNameProcess { param([int]$TimeoutMs) $script:t87Starts++; $script:t87Proc = New-T87FakeProcess; return $script:t87Proc }
    function Get-PrefixAsyncElapsedMs { return 300 }
    $saved = $script:currentProcess
    try {
        $script:currentProcess = [PSCustomObject]@{ HasExited = $false }
        if (Start-PrefixFillAsync -Trigger "Maya connected") { throw "started during a run" }
        if ($script:t87Starts -ne 0) { throw "a process was started during a run" }
        $script:currentProcess = $null
        Start-PrefixFillAsync -Trigger "Maya connected" | Out-Null
        $script:currentProcess = [PSCustomObject]@{ HasExited = $false }
        [IO.File]::WriteAllText($script:t87ResultPath, "SCENE_NAME scene_a`n")
        $script:t87Proc.HasExited = $true
        Update-PrefixFillAsync
        if ($prefixBox.Text -ne "") { throw "applied during a run: '$($prefixBox.Text)'" }
        if ($script:prefixAsync -or $window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "not cleaned up" }
    } finally {
        $script:currentProcess = $saved
        Reset-T87Async
    }
}

Check "T87: a sync click fill cancels an in-flight async fill first (no two processes writing one result file)" {
    Reset-T87Async
    function Get-SceneNameResultPath { return $script:t87ResultPath }
    function Start-SceneNameProcess { param([int]$TimeoutMs) $script:t87Proc = New-T87FakeProcess; return $script:t87Proc }
    function Get-PrefixAsyncElapsedMs { return 300 }
    function Get-MayaSceneName { param([int]$TimeoutMs) return [PSCustomObject]@{ Status = "Named"; Name = "scene_sync"; ErrorMessage = $null } }
    try {
        Start-PrefixFillAsync -Trigger "Maya connected" | Out-Null
        $first = $script:t87Proc
        $line = Update-PrefixFromScene -Trigger "Start Recording"
        if (-not $first.Killed) { throw "in-flight async fill not cancelled" }
        if ($script:prefixAsync) { throw "async state left" }
        if ($prefixBox.Text -cne "scene_sync") { throw "sync fill result '$($prefixBox.Text)'" }
        if ($window.FindName("TopBusyBar").Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "bar stuck" }
    } finally { Reset-T87Async }
}
Remove-Item $script:t87ResultPath -ErrorAction SilentlyContinue

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

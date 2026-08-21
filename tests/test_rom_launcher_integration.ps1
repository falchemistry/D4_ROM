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

Check "Show-DarkGuide is non-modal (.Show(), not .ShowDialog()), displays the given message, and its real Close button actually closes it" {
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
    $dlg.FindName("CloseButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    if ($script:openGuideWindow -ne $null) { throw "expected `$script:openGuideWindow to clear once the window is actually closed" }
}

Check "Show-DarkGuide reuses one instance -- calling it again while already open just activates the existing window instead of stacking a duplicate" {
    Show-DarkGuide -Title "FirstGuideCall" -Tldr "first message"
    $firstWindow = $script:openGuideWindow
    if ($firstWindow -eq $null) { throw "test setup: expected a window to be open after the first call" }

    Show-DarkGuide -Title "SecondGuideCall" -Tldr "second message"
    if ($script:openGuideWindow -ne $firstWindow) { throw "expected the SAME window instance reused, not a new one created while one is already open" }
    if ($firstWindow.Title -ne "FirstGuideCall") { throw "expected the existing window's own title/content left untouched by the second, suppressed call" }

    $firstWindow.FindName("CloseButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
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
    function Get-CacheStatus { return [PSCustomObject]@{ Status = "Missing"; AnimationReference = "D:/fake/auto_reset_test.ma"; CachePath = $null; ErrorMessage = $null } }
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
    Set-Content -Path $script:cacheProgressPath -Value @("frames_done=999", "frames_total=999", "percent=100.0") -Encoding UTF8
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

Check "clicking Copy port-open snippet puts the real file content on the clipboard" {
    $copySnippetButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $clipboardText = [System.Windows.Clipboard]::GetText()
    if ($clipboardText -notmatch "commandPort") { throw "clipboard should contain the port-open snippet, got: $clipboardText" }
    if ($logBox.Text -notmatch "Copied the port-open snippet") { throw "expected a confirmation message logged after copying" }
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
    if ($obsPasswordStatusLabel.Text -notmatch "password set") { throw "expected 'password set' once a real password is in the file, got '$($obsPasswordStatusLabel.Text)'" }
    if ($obsPasswordStatusDot.Fill.Color -ne [System.Windows.Media.Colors]::LimeGreen) { throw "expected the OBS status dot green once configured, got '$($obsPasswordStatusDot.Fill.Color)'" }
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

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

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
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($statusLabel.Text -ne $expected -and (Get-Date) -lt $deadline) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({ $frame.Continue = $false })
        $t.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        $t.Stop()
    }
    return $statusLabel.Text -eq $expected
}

Check "a two-step fake sequence runs both steps in order and reaches Done" {
    $fakeSteps = @(
        [PSCustomObject]@{ FilePath = "ping"; Arguments = @("-n", "1", "127.0.0.1") },
        [PSCustomObject]@{ FilePath = "cmd"; Arguments = @("/c", "echo", "second_step_ran") }
    )
    Start-Steps $fakeSteps
    $reachedDone = Wait-ForStatus "Done" 15
    if (-not $reachedDone) { throw "status never reached Done (stuck at '$($statusLabel.Text)'), log so far:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "second_step_ran") { throw "second step's output never appeared in the log:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "exited with code 0") { throw "expected at least one clean exit logged:`n$($logBox.Text)" }
    if ($logBox.Text -notmatch "All steps finished") { throw "missing completion marker:`n$($logBox.Text)" }
}

Check "buttons are re-enabled after the run completes" {
    if (-not $runOnlyButton.IsEnabled) { throw "Run Only button should be re-enabled after completion" }
    if (-not $captureButton.IsEnabled) { throw "Capture button should be re-enabled after completion" }
    if (-not $cleanResetButton.IsEnabled) { throw "Clean Reset button should be re-enabled after completion" }
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

Check "unchecked sample range produces a full-range step list with no error" {
    $sampleRangeCheck.IsChecked = $false
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
    if ($result.Steps -eq $null) { throw "expected steps to be returned" }
    $obsStep = $result.Steps | Where-Object { $_.Arguments -join " " -like "*maya_obs_capture.ps1*" }
    if ($obsStep.Arguments -join " " -match "-StartFrame") { throw "unchecked range should not add -StartFrame" }
}

Check "checked sample range with valid numbers passes them through to the OBS step" {
    $sampleRangeCheck.IsChecked = $true
    $startFrameBox.Text = "10"
    $endFrameBox.Text = "50"
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) { throw "expected no error, got: $($result.ErrorMessage)" }
    $obsStep = $result.Steps | Where-Object { $_.Arguments -join " " -like "*maya_obs_capture.ps1*" }
    $joined = $obsStep.Arguments -join " "
    if ($joined -notmatch "-StartFrame 10") { throw "expected -StartFrame 10 in: $joined" }
    if ($joined -notmatch "-EndFrame 50") { throw "expected -EndFrame 50 in: $joined" }
}

Check "checked sample range with non-numeric input produces an error, no steps" {
    $sampleRangeCheck.IsChecked = $true
    $startFrameBox.Text = "abc"
    $endFrameBox.Text = "50"
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when input is invalid" }
    if ($result.ErrorMessage -eq $null) { throw "expected an error message for non-numeric input" }
}

Check "checked sample range with Start greater than End produces an error, no steps" {
    $sampleRangeCheck.IsChecked = $true
    $startFrameBox.Text = "80"
    $endFrameBox.Text = "20"
    $result = Get-CaptureClickResult
    if ($result.Steps -ne $null) { throw "expected no steps when Start > End" }
    if ($result.ErrorMessage -eq $null) { throw "expected an error message for Start > End" }
}

Check "checking the Sample range box enables the Start/End boxes, unchecking disables them" {
    $sampleRangeCheck.IsChecked = $false
    if ($startFrameBox.IsEnabled -or $endFrameBox.IsEnabled) { throw "Start/End should be disabled while unchecked" }
    $sampleRangeCheck.IsChecked = $true
    if (-not $startFrameBox.IsEnabled -or -not $endFrameBox.IsEnabled) { throw "Start/End should be enabled once checked" }
    $sampleRangeCheck.IsChecked = $false
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

Check "Update-PortStatusIndicator sets the dot to a valid color and a matching tooltip" {
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

Write-Output "$passed passed, $($failures.Count) failed"
foreach ($f in $failures) { Write-Output "FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 } else { exit 0 }

# WPF launcher for the d4 ROM capture pipeline -- replaces double-clicking
# run_front_back.bat / run_left_right.bat / capture_front_back.bat /
# capture_left_right.bat with a single window (axis choice + Run Only /
# Capture + Record buttons), plus a Clean Reset button
# (maya_clean_reset.py). Step sequences live in rom_launcher_logic.ps1 and
# are unit-tested in tests/test_rom_launcher_logic.ps1 -- this file is only
# the window/process-running plumbing.
#
# Usage: powershell -ExecutionPolicy Bypass -File rom_launcher.ps1
# (or via the rom_launcher.bat wrapper, matching the other .bat entry points)
#
# -NoShow: builds the window and wires everything but never calls
# ShowDialog() -- lets tests dot-source this file and exercise the real
# Start-Steps/Start-NextStep/DispatcherTimer queue end-to-end (with a
# harmless fake step sequence) without ever putting a window on screen.
# Same "prove it headless before showing anything real" tier used
# throughout this session for the Qt tools.
param([switch]$NoShow)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "rom_launcher_logic.ps1")

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="d4 ROM Capture" Width="420" SizeToContent="Height"
        ResizeMode="CanMinimize">
    <StackPanel Margin="12">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,0,0,8">
            <Ellipse x:Name="PortStatusDot" Width="12" Height="12" Fill="Gray" Margin="0,0,6,0"
                     ToolTip="Checking Maya command port..."/>
            <TextBlock Text="Maya connection" FontSize="10" Foreground="Gray" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <Button x:Name="CopySnippetButton" Content="Copy port-open snippet" FontSize="10" Padding="4,1"
                    ToolTip="Copies the code that opens Maya's command port -- paste it into Maya's Script Editor (Python tab) and run it."/>
        </StackPanel>

        <TextBlock Text="Axis" FontWeight="Bold" Margin="0,0,0,4"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <RadioButton x:Name="FrontBackRadio" Content="Front / Back" IsChecked="True" Margin="0,0,16,0" GroupName="Axis"/>
            <RadioButton x:Name="LeftRightRadio" Content="Left / Right" GroupName="Axis"/>
        </StackPanel>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
            <CheckBox x:Name="SampleRangeCheck" Content="Sample range" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Text="Start" VerticalAlignment="Center" Margin="0,0,4,0"/>
            <TextBox x:Name="StartFrameBox" Width="50" Text="0" IsEnabled="False" Margin="0,0,10,0"/>
            <TextBlock Text="End" VerticalAlignment="Center" Margin="0,0,4,0"/>
            <TextBox x:Name="EndFrameBox" Width="50" Text="100" IsEnabled="False"/>
        </StackPanel>
        <TextBlock Text="Unchecked = full ROM video, same as before. Only applies to Capture + Record -- Run Only never records."
                   TextWrapping="Wrap" FontSize="10" Foreground="Gray" Margin="0,2,0,10"/>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="RunOnlyButton" Content="Run Only" Width="130" Height="32" Margin="0,0,8,0"/>
            <Button x:Name="CaptureButton" Content="Capture + Record" Width="140" Height="32" Margin="0,0,8,0"/>
            <Button x:Name="CleanResetButton" Content="Clean Reset" Width="100" Height="32"/>
        </StackPanel>

        <TextBlock x:Name="StatusLabel" Text="Idle" FontWeight="Bold" Margin="0,0,0,4"/>
        <TextBox x:Name="LogBox" Height="220" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="11"/>
    </StackPanel>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$portStatusDot = $window.FindName("PortStatusDot")
$copySnippetButton = $window.FindName("CopySnippetButton")
$frontBackRadio = $window.FindName("FrontBackRadio")
$sampleRangeCheck = $window.FindName("SampleRangeCheck")
$startFrameBox = $window.FindName("StartFrameBox")
$endFrameBox = $window.FindName("EndFrameBox")
$runOnlyButton = $window.FindName("RunOnlyButton")
$captureButton = $window.FindName("CaptureButton")
$cleanResetButton = $window.FindName("CleanResetButton")
$statusLabel = $window.FindName("StatusLabel")
$logBox = $window.FindName("LogBox")
$dispatcher = $window.Dispatcher

$script:currentSteps = @()
$script:currentStepIndex = 0
$script:currentProcess = $null
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)

# Bounded (300ms) TCP probe -- localhost connection-refused is normally
# near-instant, but BeginConnect+WaitOne caps the worst case instead of
# trusting the OS default connect timeout (which can be many seconds for a
# genuinely unreachable host), so this never has a chance to freeze the UI
# thread even in a pathological case.
function Test-MayaPortReachable {
    param([string]$MayaHost = "127.0.0.1", [int]$Port = 7001, [int]$TimeoutMs = 300)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($MayaHost, $Port, $null, $null)
        $completed = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($completed -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Update-PortStatusIndicator {
    $reachable = Test-MayaPortReachable
    if ($reachable) {
        $portStatusDot.Fill = "LimeGreen"
        $portStatusDot.ToolTip = "Maya command port (127.0.0.1:7001) is open -- ROM tools will work."
    } else {
        $portStatusDot.Fill = "Red"
        $portStatusDot.ToolTip = "Maya command port (127.0.0.1:7001) is NOT reachable -- buttons below will silently do nothing. Paste open_maya_port.py into Maya's Script Editor (Python tab) and run it, then this dot will turn green."
    }
    return $reachable
}

$script:portCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:portCheckTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:portCheckTimer.Add_Tick({ Update-PortStatusIndicator | Out-Null })

function Write-Log([string]$text) {
    # Called both directly from the UI thread (button click handlers,
    # DispatcherTimer ticks) and from Register-ObjectEvent's isolated
    # action scriptblocks (background thread) -- Dispatcher.Invoke makes
    # this safe from either. Proven via wpf_async_probe.ps1: a
    # Register-ObjectEvent action CAN correctly call an outer-defined
    # function that closes over script-scope variables like $dispatcher/
    # $logBox (PowerShell functions resolve via their scope of definition,
    # not their caller's scope) -- it's only setting a bare $script:
    # variable directly INSIDE the action block itself that fails to
    # propagate back to the caller, which this design avoids entirely.
    $dispatcher.Invoke([action]{
        $logBox.AppendText("$text`r`n")
        $logBox.ScrollToEnd()
    }.GetNewClosure())
}

function Set-ButtonsEnabled([bool]$enabled) {
    $runOnlyButton.IsEnabled = $enabled
    $captureButton.IsEnabled = $enabled
    $cleanResetButton.IsEnabled = $enabled
    $sampleRangeCheck.IsEnabled = $enabled
    $startFrameBox.IsEnabled = $enabled -and $sampleRangeCheck.IsChecked
    $endFrameBox.IsEnabled = $enabled -and $sampleRangeCheck.IsChecked
}

function Start-NextStep {
    if ($script:currentStepIndex -ge $script:currentSteps.Count) {
        $script:pollTimer.Stop()
        $statusLabel.Text = "Done"
        Set-ButtonsEnabled $true
        Write-Log "=== All steps finished ==="
        return
    }

    $step = $script:currentSteps[$script:currentStepIndex]
    Write-Log ">>> $($step.FilePath) $($step.Arguments -join ' ')"

    # ProcessStartInfo.ArgumentList exists on paper but comes back null on
    # this machine's PowerShell 5.1 (confirmed empirically -- calling
    # .Add() on it throws InvokeMethodOnNull) -- build the classic
    # space-joined .Arguments string instead, quoting any argument that
    # contains a space (script/argument values here are always full
    # Windows paths, e.g. "D:\__backup\claude\d4_rom\scripts\...", never
    # containing an embedded double-quote themselves).
    $quotedArgs = $step.Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $step.FilePath
    $psi.Arguments = $quotedArgs -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
        if ($EventArgs.Data) { Write-Log $EventArgs.Data }
    } | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { Write-Log "[stderr] $($EventArgs.Data)" }
    } | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:currentProcess = $proc
}

$script:pollTimer.Add_Tick({
    if ($script:currentProcess -eq $null) { return }
    if ($script:currentProcess.HasExited) {
        Write-Log "--- exited with code $($script:currentProcess.ExitCode) ---"
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:currentProcess } | Unregister-Event
        $script:currentProcess = $null
        $script:currentStepIndex++
        Start-NextStep
    }
})

function Start-Steps([array]$steps) {
    if ($script:currentProcess -ne $null) {
        Write-Log "(already running -- ignoring click)"
        return
    }
    $script:currentSteps = $steps
    $script:currentStepIndex = 0
    Set-ButtonsEnabled $false
    $statusLabel.Text = "Running..."
    $logBox.Clear()
    $script:pollTimer.Start()
    Start-NextStep
}

$sampleRangeCheck.Add_Checked({
    $startFrameBox.IsEnabled = $true
    $endFrameBox.IsEnabled = $true
})
$sampleRangeCheck.Add_Unchecked({
    $startFrameBox.IsEnabled = $false
    $endFrameBox.IsEnabled = $false
})

# Pure-ish: reads the real WPF controls' current values but returns a
# result object instead of starting anything -- lets tests verify the
# checkbox/textbox validation without ever calling Start-Steps (which
# would launch real send_to_maya.ps1/maya_obs_capture.ps1 processes
# against whatever's live in Maya right now).
function Get-CaptureClickResult {
    $axis = if ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }

    if (-not $sampleRangeCheck.IsChecked) {
        $steps = Get-CaptureSteps -Axis $axis -Recording $true -ScriptDir $ScriptDir
        return [PSCustomObject]@{ Steps = $steps; ErrorMessage = $null }
    }

    $parsedStart = 0
    $parsedEnd = 0
    $startOk = [int]::TryParse($startFrameBox.Text, [ref]$parsedStart)
    $endOk = [int]::TryParse($endFrameBox.Text, [ref]$parsedEnd)
    if (-not $startOk -or -not $endOk) {
        return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Start/End must be whole numbers (got '$($startFrameBox.Text)' / '$($endFrameBox.Text)') -- not starting." }
    }
    if ($parsedStart -gt $parsedEnd) {
        return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Start ($parsedStart) must not be greater than End ($parsedEnd) -- not starting." }
    }
    $steps = Get-CaptureSteps -Axis $axis -Recording $true -ScriptDir $ScriptDir -StartFrame $parsedStart -EndFrame $parsedEnd
    return [PSCustomObject]@{ Steps = $steps; ErrorMessage = $null }
}

$runOnlyButton.Add_Click({
    $axis = if ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $steps = Get-CaptureSteps -Axis $axis -Recording $false -ScriptDir $ScriptDir
    Start-Steps $steps
})

$captureButton.Add_Click({
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) {
        Write-Log $result.ErrorMessage
        return
    }
    Start-Steps $result.Steps
})

$cleanResetButton.Add_Click({
    $steps = Get-CleanResetStep -ScriptDir $ScriptDir
    Start-Steps $steps
})

$copySnippetButton.Add_Click({
    $content = Get-PortSnippetContent -ScriptDir $ScriptDir
    if ($content -eq $null) {
        Write-Log "Could not find open_maya_port.py to copy."
        return
    }
    [System.Windows.Clipboard]::SetText($content)
    Write-Log "Copied the port-open snippet to your clipboard -- paste it into Maya's Script Editor (Python tab) and run it."
})

Update-PortStatusIndicator | Out-Null
$script:portCheckTimer.Start()

if (-not $NoShow) {
    $window.ShowDialog() | Out-Null
}

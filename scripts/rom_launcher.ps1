# WPF launcher for the D4 ROM capture pipeline -- replaces double-clicking
# run_front_back.bat / run_left_right.bat / capture_front_back.bat /
# capture_left_right.bat with a single window (axis choice + Preview /
# Start Recording buttons), plus a Reset button
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

# Bumped by hand on a meaningful change (semver-ish, not tied to git commit
# count) -- shown in the window title so a user/screenshot/bug report can
# say which build they're on, and so a stale d4_rom_dist copy is
# distinguishable from the current source at a glance.
$script:ToolVersion = "1.0.0"

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="D4 ROM Capture" Width="420" Height="600" MinWidth="380" MinHeight="450"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <Window.Resources>
        <!-- Same dark palette as MayaSkinningCheck/MayaShelves' shared
             akStyle.py build_style() (rgb values transcribed to hex, not
             re-guessed), so this WPF tool matches the Qt tools instead of
             standing out as the one plain white window. -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#FF1F1F1F"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="9,2"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF2D2D2D"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="#FF161616"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#FF1A1A1A"/>
                    <Setter Property="Foreground" Value="#FF808080"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FF1C1C1C"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF4C4C4C"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="3"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#FFE6E6E6"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#FFE4E4E4"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="#FFE4E4E4"/>
        </Style>
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#FF303030"/>
            <Setter Property="Foreground" Value="#FFE1E1E1"/>
            <Setter Property="BorderBrush" Value="#FF484848"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="#FF1C1C1C"/>
            <!-- Monochromatic theme (2026-08-21): was the same blue as the
                 active-tab/primary-button accent everywhere else in this
                 window. Replaced project-wide with a light neutral gray,
                 so nothing in this UI relies on color to read as
                 "selected/primary," just brightness contrast against the
                 dark chrome. -->
            <Setter Property="Foreground" Value="#FFD0D0D0"/>
            <Setter Property="BorderBrush" Value="#FF4C4C4C"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Height" Value="16"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                            <Grid x:Name="PART_Track" ClipToBounds="True">
                                <Rectangle x:Name="PART_Indicator" Fill="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Dark-themed so the Cache button's right-click menu (Force
             Rebuild) doesn't pop up as a jarring default white Windows
             menu against the rest of this dark window. -->
        <!-- Full custom template, not just property Setters. Confirmed
             live (2026-08-21) that a plain Setter-only Style here still
             left a white box next to "Force Rebuild": that gutter belongs
             to ContextMenu's OWN default chrome (a shared icon column
             running down the whole popup), not to MenuItem, which
             already has its own full template below. Simple setters
             never override it; only a full template removes it. -->
        <Style TargetType="ContextMenu">
            <Setter Property="Background" Value="#FF2A2A2A"/>
            <Setter Property="Foreground" Value="#FFE6E6E6"/>
            <Setter Property="BorderBrush" Value="#FF4C4C4C"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ContextMenu">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                            <StackPanel IsItemsHost="True"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Full custom template, not just property Setters: the default
             MenuItem chrome reserves an icon/checkbox gutter column that
             paints with its own hardcoded system brush regardless of
             Background, leaving a jarring unstyled white box next to the
             text (confirmed visually), the same class of problem Button
             and ProgressBar above already needed a full template to avoid.
             This app has no icons/checkable menu items, so the template
             is just a Border + text, no gutter at all. -->
        <Style TargetType="MenuItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FFE6E6E6"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border x:Name="MenuItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="MenuItemBorder" Property="Background" Value="#FF3C3C3C"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#FF6E6E6E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Full custom templates, same reasoning as MenuItem above: the
             default ComboBox chrome's dropdown popup paints with its own
             system brushes regardless of simple Background/Foreground
             Setters, so a plain Style here would leave a white dropdown
             against this dark window. -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#FF2A2A2A"/>
            <Setter Property="Foreground" Value="#FFE6E6E6"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="#FF3C3C3C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#FF1C1C1C"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF4C4C4C"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleBtn" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" Focusable="False" ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="20"/>
                                                </Grid.ColumnDefinitions>
                                                <Path Grid.Column="1" Data="M0,0 L4,4 L8,0 Z" Fill="#FFE6E6E6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Grid>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                            <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
                                <Border Background="#FF2A2A2A" BorderBrush="#FF4C4C4C" BorderThickness="1" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                    <ScrollViewer>
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="5">
        <!-- Root is a Grid (not a StackPanel) with an explicit row layout
             so the window can actually be resized: every row above the log
             is Auto-height (unchanged behavior), and the log row alone is
             "*" so it is the one thing that grows/shrinks when the user
             drags the window taller or shorter, instead of the whole
             window fighting a StackPanel that always sizes to content. -->
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Tab bar: two plain Buttons toggling which panel below is
             Visible, rather than a native TabControl. This reuses the
             already dark-styled Button (and the same Visibility-toggle
             technique already proven for StartEndPanel/CacheProgressPanel)
             instead of taking on TabControl's own separate default-chrome
             styling risk. Set-ActiveTab (code-behind) drives which button
             looks "pressed" via Background, matching the same pattern
             already used for the Stop-state toggle on the buttons below.
             Guide button rides along in its own Auto column so it stays
             compact instead of stretching to tab width. -->
        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <UniformGrid Grid.Column="0" Columns="2">
                <Button x:Name="SettingsTabButton" Content="Settings" Height="32" Margin="0,0,4,0"/>
                <Button x:Name="CaptureTabButton" Content="Capture" Height="32" Margin="4,0,0,0"/>
            </UniformGrid>
            <!-- Plain "?" text content, not a hand-drawn glyph like the
                 Settings-row icons. A literal question mark is instantly
                 recognizable with zero drawing risk, and Preview/Start
                 Recording/Reset already establish that text-content
                 buttons are normal in this window, not just icon-only
                 ones. -->
            <Button Grid.Column="1" x:Name="GuideButton" Content="?" Width="36" Height="32" Padding="0" FontWeight="Bold" Margin="6,0,0,0" AutomationProperties.Name="Guide"
                    ToolTip="How to use this tool"/>
        </Grid>

        <!-- Wraps both tab panels in one container, directly beneath the
             tab row with no gap (matches the reference: Maya's own Tool
             Settings content sits flush against its tab). Solid fill,
             not a colored accent border: a lighter gray than the window
             background (2026-08-21: corrected from an earlier, WRONG
             choice that went darker instead of lighter, and read as
             "still black" rather than "highlighted") reads as a raised,
             solid panel on its own, no color needed to carry that.
             Deliberately NOT as light as the active tab's own accent
             gray (#FFD0D0D0): this window's TextBlocks/RadioButtons/etc
             all default to light-colored text for a dark background, and
             matching the tab's brightness exactly would need every one of
             those recolored dark for contrast too, not just this one
             Background value. Border is a plain neutral gray, same
             family as every other subtle border in this window
             (TextBox/ComboBox), purely to define the edge.

             Extended (2026-08-21) to wrap the run's progress/status/log
             area too, not just the tab-switched panels: these used to
             sit outside the border, back on the plain window background,
             which left a visible seam/gap between the boxed parameter
             area and everything below it. One Border, one Grid with its
             OWN row definitions inside, so the same Padding governs every
             row's left/right inset consistently instead of needing each
             row's own margin hand-matched to line up. -->
        <!-- BorderBrush matches Background exactly, not a distinct
             outline shade: a visibly different border stroke color
             reads as its own thin "gap" ring around the panel, which is
             exactly what this is meant to eliminate, not reintroduce. -->
        <Border Grid.Row="1" Background="#FF4D4D4D" BorderThickness="1" BorderBrush="#FF4D4D4D" Padding="8,10,8,10">
        <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
        <!-- Flat vertical list: Maya connection, Cache, OBS password.
             Each is a one-time-per-machine or rarely-touched setup
             concern, so they're grouped under their own tab rather than
             sharing space with the per-run Capture controls. -->
        <StackPanel x:Name="SettingsPanel" Visibility="Collapsed">
            <!-- Every row is the same Grid shape: a status dot (uniform
                 size/position across all three rows, so they visually line
                 up in a clean column) plus label on the left in a
                 stretching column, action button(s) pinned to the right in
                 an Auto column. Icon buttons are pure actions now (plain
                 Foreground-bound glyphs, no code-driven status color).
                 The dot is the one consistent status indicator per row,
                 not split between a dot on some rows and a tinted icon on
                 others. -->
            <Grid Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="PortStatusDot" Width="10" Height="10" Fill="Gray" Margin="0,0,6,0" VerticalAlignment="Center"
                             ToolTip="Checking Maya command port..."/>
                    <TextBlock x:Name="PortStatusLabel" Text="Maya connection" Foreground="#FFA0A0A0" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
                <!-- Icon buttons, all Height 32 to match Preview, Start
                     Recording, and Reset. Content is a small hand-drawn
                     glyph (Canvas of primitive shapes, same low-risk
                     technique used throughout this window) instead of
                     text, so these secondary actions stay compact.
                     Foreground bound via RelativeSource so the glyph
                     automatically grays out when the button disables, for
                     free, off the same Button style trigger every other
                     button uses. -->
                <Button Grid.Column="1" x:Name="CopySnippetButton" Width="36" Height="32" Padding="0" AutomationProperties.Name="Copy port-open snippet"
                        ToolTip="Copies the code that opens Maya's command port -- paste it into Maya's Script Editor (Python tab) and run it.">
                    <Canvas Width="14" Height="14">
                        <Rectangle Canvas.Left="2" Canvas.Top="2.5" Width="10" Height="10.5" RadiusX="1.3" RadiusY="1.3" Fill="Transparent"
                                   Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.2"/>
                        <Rectangle Canvas.Left="4.7" Canvas.Top="0.8" Width="4.6" Height="2.6" RadiusX="0.8" RadiusY="0.8"
                                   Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        <Line X1="4" Y1="6.3" X2="10" Y2="6.3" StrokeThickness="1"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        <Line X1="4" Y1="8.8" X2="10" Y2="8.8" StrokeThickness="1"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                    </Canvas>
                </Button>
            </Grid>

            <Grid Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="CacheStatusDot" Width="10" Height="10" Fill="Gray" Margin="0,0,6,0" VerticalAlignment="Center"
                             ToolTip="Not checked yet."/>
                    <TextBlock x:Name="CacheStatusLabel" Text="Cache: not checked" Foreground="#FFA0A0A0" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
                <!-- One merged button, not two: a plain click always
                     checks first (never acts on a stale scene/reference
                     left over from the last check), then only offers to
                     build if that fresh check comes back Missing. The
                     same status dot above already shows whether a cache
                     currently exists, so a separate always-visible "Check"
                     button next to a separate "Rebuild" button was
                     redundant surface area. The icon itself swaps
                     (magnifier to refresh) once a status is known, same
                     "one control, state-dependent glyph/action" pattern
                     already used for Start/Stop Recording elsewhere in
                     this window. Right-click (Force Rebuild) is the one
                     capability a plain click deliberately does NOT cover:
                     the cache path is keyed off the animation reference's
                     FILE PATH only (see maya_check_cache.py's
                     cache_path_for), not its content, so an artist can
                     edit the referenced animation without renaming it and
                     Check will keep reporting "Exists" even though the
                     cache is now stale. Force Rebuild is the deliberate
                     override for exactly that case. -->
                <Button Grid.Column="1" x:Name="CacheActionButton" Width="36" Height="32" Padding="0" Margin="6,0,0,0" AutomationProperties.Name="Check or Rebuild Cache"
                        ToolTip="Click: checks the cache (and builds it if missing). Right-click: force a rebuild even if a cache already exists -- for when the animation changed without renaming its file.">
                    <Button.ContextMenu>
                        <ContextMenu>
                            <MenuItem x:Name="ForceRebuildMenuItem" Header="Force Rebuild (even if cache exists)" IsEnabled="False"/>
                        </ContextMenu>
                    </Button.ContextMenu>
                    <Grid>
                        <Canvas x:Name="CacheCheckIcon" Width="14" Height="14">
                            <Ellipse Canvas.Left="1.5" Canvas.Top="1.5" Width="7" Height="7" Fill="Transparent"
                                     Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.5"/>
                            <Line X1="7.5" Y1="7.5" X2="12" Y2="12" StrokeThickness="1.8"
                                  Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        </Canvas>
                        <!-- Standard refresh glyph (circular arrow): one
                             open arc (Path) plus a Polygon arrowhead
                             capping its leading end, same primitive-shape
                             technique as every other icon here. -->
                        <Canvas x:Name="CacheRefreshIcon" Width="14" Height="14" Visibility="Collapsed">
                            <Path Data="M 9.50,2.67 A 5,5 0 1 1 3.79,3.17"
                                  Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3" Fill="Transparent"/>
                            <Polygon Points="7.60,1.57 10.15,1.54 8.85,3.80"
                                     Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        </Canvas>
                    </Grid>
                </Button>
            </Grid>

            <Grid Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="ObsPasswordStatusDot" Width="10" Height="10" Fill="Gray" Margin="0,0,6,0" VerticalAlignment="Center"
                             ToolTip="Not configured yet."/>
                    <TextBlock x:Name="ObsPasswordStatusLabel" Text="OBS WebSocket: not configured" Foreground="#FFA0A0A0" VerticalAlignment="Center"/>
                </StackPanel>
                <Button Grid.Column="1" x:Name="ObsPasswordButton" Width="36" Height="32" Padding="0" AutomationProperties.Name="OBS WebSocket Password"
                        ToolTip="Set this machine's OBS WebSocket password (OBS > Tools > WebSocket Server Settings). Every machine's OBS has its own independent password -- this is a one-time setup step per machine.">
                    <Canvas Width="14" Height="14">
                        <Ellipse Canvas.Left="1" Canvas.Top="4" Width="6" Height="6" Fill="Transparent"
                                 Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3"/>
                        <Line X1="6.5" Y1="7" X2="13" Y2="7" StrokeThickness="1.4"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        <Line X1="10" Y1="7" X2="10" Y2="10" StrokeThickness="1.2"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                        <Line X1="12.5" Y1="7" X2="12.5" Y2="9.5" StrokeThickness="1.2"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                    </Canvas>
                </Button>
            </Grid>

            <!-- Same single-row shape as the other three settings rows,
                 but with the columns reversed: label is Auto (just wide
                 enough for its own text) and the ComboBox is "*" so IT
                 stretches to fill the remaining row width, instead of the
                 label stretching and the action being a fixed-width Auto
                 column. Monitor display names are long ("Artist22R Pro:
                 1920x1080 @ 0,0 (Primary Monitor)") and need the room. -->
            <Grid Margin="0,0,0,10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0">
                    <Ellipse x:Name="MonitorStatusDot" Width="10" Height="10" Fill="Gray" Margin="0,0,6,0" VerticalAlignment="Center"
                             ToolTip="Not checked yet."/>
                    <!-- MaxWidth, not just TextWrapping="Wrap" alone: this
                         column is "Auto" (unlike the other status rows'
                         "*" label column) so the ComboBox/Refresh button
                         next to it can take most of the row width in the
                         normal case, but "Auto" is unbounded, so
                         TextWrapping does nothing without a cap, and a
                         long status message (e.g. the "Could not connect
                         to OBS..." error) was pushing the ComboBox and
                         Refresh button off the visible window entirely
                         instead of wrapping (confirmed live, 2026-08-22). -->
                    <TextBlock x:Name="MonitorStatusLabel" Text="Recording Monitor" Foreground="#FFA0A0A0" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="150"/>
                </StackPanel>
                <!-- Populated from OBS once at startup, not polled
                     continuously: monitor lists don't change often enough
                     to justify a live query loop the way Maya port
                     reachability does. -->
                <ComboBox Grid.Column="1" x:Name="MonitorComboBox" Height="32" HorizontalAlignment="Stretch" VerticalContentAlignment="Center"
                          ToolTip="Which physical monitor OBS records. Auto-detected from the one enabled monitor-capture source in OBS's active scene."/>
                <!-- Design agreed 2026-08-22: nothing auto-launches OBS
                     just because this window opened (see Update-MonitorList's
                     own comment), so this is the explicit, user-initiated
                     way to launch OBS and re-detect the monitor: most
                     useful right after a cold launch, when the dropdown
                     is locked showing only the last-known selection.
                     Same refresh glyph already used for Force Rebuild. -->
                <Button Grid.Column="2" x:Name="MonitorRefreshButton" Width="36" Height="32" Padding="0" Margin="6,0,0,0" AutomationProperties.Name="Refresh Recording Monitor"
                        ToolTip="Launch OBS (if it isn't already running) and re-check which monitor it's set to record.">
                    <Canvas Width="14" Height="14">
                        <Path Data="M 9.50,2.67 A 5,5 0 1 1 3.79,3.17"
                              Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3" Fill="Transparent"/>
                        <Polygon Points="7.60,1.57 10.15,1.54 8.85,3.80"
                                 Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
                    </Canvas>
                </Button>
            </Grid>
        </StackPanel>

        <StackPanel x:Name="CapturePanel">
            <TextBlock Text="Axis" FontWeight="Bold" Margin="0,0,0,4"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                <RadioButton x:Name="FrontBackRadio" Content="Front / Back" IsChecked="True" Margin="0,0,16,0" GroupName="Axis"/>
                <RadioButton x:Name="LeftRightRadio" Content="Left / Right" GroupName="Axis"/>
            </StackPanel>

            <TextBlock Text="Time Range" FontWeight="Bold" Margin="0,0,0,4"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                <RadioButton x:Name="TimeSliderRadio" Content="Time Slider" Margin="0,0,14,0" GroupName="TimeRange"
                             ToolTip="Reads Maya's current Range Slider (minTime/maxTime) at the moment you click Start Recording -- whatever the artist's active working range is right then, not a fixed snapshot taken now."/>
                <RadioButton x:Name="AllFramesRadio" Content="All" IsChecked="True" Margin="0,0,14,0" GroupName="TimeRange"
                             ToolTip="Full ROM video, same as always -- no range passed."/>
                <RadioButton x:Name="StartEndRadio" Content="Start/End" GroupName="TimeRange"
                             ToolTip="Manually typed frame numbers."/>
            </StackPanel>
            <StackPanel x:Name="StartEndPanel" Orientation="Horizontal" Margin="0,0,0,4" Visibility="Collapsed">
                <TextBlock Text="Start" VerticalAlignment="Center" Margin="0,0,4,0"/>
                <TextBox x:Name="StartFrameBox" Width="50" Text="0" Margin="0,0,10,0"/>
                <TextBlock Text="End" VerticalAlignment="Center" Margin="0,0,4,0"/>
                <TextBox x:Name="EndFrameBox" Width="50" Text="100"/>
            </StackPanel>
            <TextBlock Text="Only applies to Start Recording -- Preview never records."
                       TextWrapping="Wrap" FontSize="10" Foreground="#FFA0A0A0" Margin="0,2,0,10"/>

            <!-- Only Start Recording toggles into Stop Recording, matching
                 that this is the one action that mirrors OBS's own
                 Start/Stop Recording button: a long-running recording a
                 user would actually want to interrupt. Preview and Reset
                 are fast, one-shot steps, same as before this feature
                 existed; they just disable like any other inactive button
                 while something else runs. They were never individually
                 stoppable even before Stop existed, so this is not a new
                 gap. -->
            <UniformGrid Columns="3" Margin="0,0,0,10">
                <Button x:Name="PreviewButton" Content="Preview" Height="32" Margin="0,4,4,0"
                        ToolTip="Opens the tracked camera panels and keys them from cache, in the Maya viewport only -- no OBS recording."/>
                <Button x:Name="StartRecordingButton" Content="Start Recording" Tag="Start Recording" Height="32" Margin="4,4,4,0"
                        ToolTip="Same as Preview, plus records via OBS. While recording, click again (now labeled Stop Recording) to interrupt it -- also stops Maya playback, restores the taskbar, and stops the OBS recording."/>
                <Button x:Name="ResetButton" Content="Reset" Height="32" Margin="4,4,0,0"
                        ToolTip="Deletes the tracked cameras and panels, resets the timeline to frame 0."/>
            </UniformGrid>
        </StackPanel>
        </Grid>

        <!-- Outside both tab panels (but still inside the shared bordered
             Grid above, since 2026-08-21, see that Border's own
             comment), always visible regardless of which tab is active: a
             run's progress/status/log must stay visible even if the user
             switches to Settings while something is running, not get
             hidden along with the Capture controls. -->

        <!-- Only relevant on a cache miss (see maya_cache_bbox.py),
             collapsed the rest of the time so it doesn't sit around empty
             for the common case where the cache already exists. -->
        <StackPanel x:Name="CacheProgressPanel" Grid.Row="1" Visibility="Collapsed" Margin="0,0,0,10">
            <TextBlock x:Name="CacheProgressLabel" Text="Building animation cache..." FontSize="10" Foreground="#FFA0A0A0" Margin="0,0,0,3" TextWrapping="Wrap"/>
            <ProgressBar x:Name="CacheProgressBar" Minimum="0" Maximum="100" Value="0"/>
        </StackPanel>

        <!-- Static header now, matching the "Axis"/"Time Range" style.
             The run status this used to show (Idle/Running/Done) moved to
             $script:runStatus (internal only), since the button toggling
             into "Stop Recording" already signals "something is running"
             visually, and the log content itself narrates progress. -->
        <TextBlock x:Name="StatusLabel" Grid.Row="2" Text="Logs" FontWeight="Bold" Margin="0,0,0,4"/>
        <!-- The one "*" row: MinHeight keeps a few lines visible even if
             the user shrinks the window toward MinHeight, instead of the
             log getting squeezed to nothing while the Auto rows above it
             keep their full size. -->
        <TextBox x:Name="LogBox" Grid.Row="3" MinHeight="80" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="11"/>
        </Grid>
        </Border>
    </Grid>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = "$($window.Title) v$script:ToolVersion"

# app_icon.ico lives at the project root (one level up from scripts/, same
# folder as ROM_Launcher.exe) -- this only sets the WPF window's own
# title-bar/taskbar-while-running icon; it is a SEPARATE assignment from
# build_exe.ps1's /win32icon flag, which is what Explorer shows for the
# .exe file itself before it's even launched. Wrapped in try/catch so a
# missing icon file degrades to WPF's default rather than crashing the
# whole launcher over a cosmetic detail.
try {
    $iconPath = Join-Path (Split-Path $ScriptDir -Parent) "app_icon.ico"
    if (Test-Path $iconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]"file:///$($iconPath -replace '\\','/')")
    }
} catch {
    Write-Warning "Could not load app_icon.ico: $($_.Exception.Message)"
}

$settingsTabButton = $window.FindName("SettingsTabButton")
$captureTabButton = $window.FindName("CaptureTabButton")
$guideButton = $window.FindName("GuideButton")
$settingsPanel = $window.FindName("SettingsPanel")
$capturePanel = $window.FindName("CapturePanel")
$portStatusDot = $window.FindName("PortStatusDot")
$portStatusLabel = $window.FindName("PortStatusLabel")
$copySnippetButton = $window.FindName("CopySnippetButton")
$cacheStatusDot = $window.FindName("CacheStatusDot")
$cacheStatusLabel = $window.FindName("CacheStatusLabel")
$cacheActionButton = $window.FindName("CacheActionButton")
$cacheCheckIcon = $window.FindName("CacheCheckIcon")
$cacheRefreshIcon = $window.FindName("CacheRefreshIcon")
$forceRebuildMenuItem = $window.FindName("ForceRebuildMenuItem")
$obsPasswordStatusDot = $window.FindName("ObsPasswordStatusDot")
$obsPasswordButton = $window.FindName("ObsPasswordButton")
$obsPasswordStatusLabel = $window.FindName("ObsPasswordStatusLabel")
$monitorStatusDot = $window.FindName("MonitorStatusDot")
$monitorStatusLabel = $window.FindName("MonitorStatusLabel")
$monitorComboBox = $window.FindName("MonitorComboBox")
$monitorRefreshButton = $window.FindName("MonitorRefreshButton")
$frontBackRadio = $window.FindName("FrontBackRadio")
$timeSliderRadio = $window.FindName("TimeSliderRadio")
$allFramesRadio = $window.FindName("AllFramesRadio")
$startEndRadio = $window.FindName("StartEndRadio")
$startEndPanel = $window.FindName("StartEndPanel")
$startFrameBox = $window.FindName("StartFrameBox")
$endFrameBox = $window.FindName("EndFrameBox")
$previewButton = $window.FindName("PreviewButton")
$startRecordingButton = $window.FindName("StartRecordingButton")
$resetButton = $window.FindName("ResetButton")
$cacheProgressPanel = $window.FindName("CacheProgressPanel")
$cacheProgressLabel = $window.FindName("CacheProgressLabel")
$cacheProgressBar = $window.FindName("CacheProgressBar")
$statusLabel = $window.FindName("StatusLabel")
$logBox = $window.FindName("LogBox")
$dispatcher = $window.Dispatcher

# Monochromatic theme (2026-08-21): was a distinctly brighter blue, then
# a bright neutral gray -- now unified with the parameter panel's own
# Background (#FF4D4D4D, see that Border) so the active tab and its
# content read as one continuous surface with zero seam between them,
# per direct feedback ("make the border share similar color too...no
# gap"). Dark enough that the existing light-colored button text (the
# Button style's own default Foreground) stays readable without needing
# a contrast flip the way the earlier, brighter gray did -- one less
# thing to keep in sync.
$script:activeTabBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(77, 77, 77))

function Set-ActiveTab([string]$Tab) {
    if ($Tab -eq "Settings") {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Visible
        $capturePanel.Visibility = [System.Windows.Visibility]::Collapsed
        $settingsTabButton.Background = $script:activeTabBrush
        $captureTabButton.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
    } else {
        $settingsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $capturePanel.Visibility = [System.Windows.Visibility]::Visible
        $captureTabButton.Background = $script:activeTabBrush
        $settingsTabButton.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
    }
}

# Internal-only run-state tracker, decoupled from StatusLabel now that its
# visible Text is a static "Logs" header -- exists so tests (and any other
# future internal consumer) can still know when an async run is genuinely
# done, without needing a user-visible label to change for it.
$script:runStatus = "Idle"

# maya_cache_bbox.py (triggered inline by maya_key_from_cache.py on a
# cache miss) writes its progress here every 100 frames -- see that
# file's _write_progress(). Deleted at the start of every run so stale
# data from a past build can never be mistaken for a currently-active one.
$script:cacheProgressPath = Join-Path $ScriptDir "..\d4_anim_sample\_cache_build_progress.txt"

$script:currentSteps = @()
$script:currentStepIndex = 0
$script:currentProcess = $null
# Whichever button started the run currently in flight (or $null for
# nothing running / an internally-triggered run with no owning button).
# That button visually becomes "Stop" for the duration -- see
# Set-ButtonRunningVisual -- instead of a separate always-present Stop
# button that's meaningless while idle.
$script:activeButton = $null
# Tracked separately from any single button's IsEnabled -- Rebuild Cache's
# enabled state depends on BOTH "nothing else is running" AND "Check
# Cache last confirmed one exists," so Set-ButtonsEnabled needs this as
# an independent signal, not something it can derive from $enabled alone.
$script:cacheKnownToExist = $false
# True for Exists OR Missing -- both give Rebuild Cache something to do
# (see Confirm-AndBuildCache); only Error/Unknown leave it disabled.
$script:cacheActionable = $false
$script:lastCachePath = $null
$script:lastAnimRef = $null
$script:lastCacheStatus = $null
# $null = never checked, $true/$false = the last real Check Cache
# round-trip's answer to "did this scene have any file reference at all."
# Folded into the Maya-connection dot/label by Update-PortStatusIndicator
# instead of driving a separate row -- see that function's own comment.
$script:lastSceneHasReference = $null
# Set right before Start-Steps by any run that can create/change a cache
# (Preview, Start Recording, Confirm-AndBuildCache) -- NOT Reset, which
# never touches the cache. Consumed by Start-NextStep's completion branch:
# the fix for a real bug (2026-08-20) where the Cache status dot/label
# kept showing stale "not built yet" after a run actually finished
# building one, since nothing ever re-ran the check automatically.
$script:pendingCacheRefresh = $false
# Tracks the one live Guide window instance (see Show-DarkGuide) -- $null
# when none is open.
$script:openGuideWindow = $null
# Populated by Update-MonitorList, read by MonitorComboBox's
# SelectionChanged handler to map the selected display name back to its
# raw OBS monitor_id.
$script:obsMonitorOptions = @()
# Guards MonitorComboBox.SelectionChanged from re-applying to OBS while
# Update-MonitorList itself is the one setting SelectedIndex
# programmatically (populating the list), not the user picking something.
$script:suppressMonitorSelectionChanged = $false
# The last SelectedIndex actually confirmed (by Update-MonitorList's own
# auto-select, or by the user answering Yes) -- what SelectionChanged
# reverts the ComboBox back to if the user answers No to the change
# confirmation, so a cancelled change doesn't leave the visual selection
# out of sync with OBS's real, unchanged configuration.
$script:lastConfirmedMonitorIndex = -1
# Set by Set-CaptureAbortReason when a step prints CAPTURE_ABORT (see
# Start-NextStep's OutputDataReceived handler) -- non-$null tells the
# pollTimer tick handler below to stop the whole run right there instead
# of advancing to the next step. Reset at the start of every Start-Steps
# call so a PRIOR run's abort can't bleed into a later, unrelated one.
$script:captureAbortReason = $null
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
# Same destructive-action red as MayaSkinningCheck's delete icon
# (akStyle.make_delete_icon's rgb(224, 120, 110)), not an arbitrary pick.
$script:stopBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(224, 120, 110))

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
    # Reachability itself is still the cheap TCP-only probe polled every
    # 5 seconds (see $script:portCheckTimer) -- deliberately NOT re-running
    # a real Maya round-trip that often, which would mean spawning a
    # send_to_maya.ps1 process every 5 seconds forever. $script:lastSceneHasReference
    # is the one piece of richer "is the RIGHT scene loaded" information,
    # and it only ever gets set by an actual Check Cache round-trip (see
    # Update-CacheStatusIndicator) -- this function just folds whatever it
    # last learned into the same dot/label instead of erasing it every
    # time the cheap poll runs.
    $reachable = Test-MayaPortReachable
    if (-not $reachable) {
        $portStatusDot.Fill = "Red"
        $portStatusLabel.Text = "Maya connection"
        $portStatusDot.ToolTip = "Maya command port (127.0.0.1:7001) is NOT reachable -- buttons below will silently do nothing. Paste open_maya_port.py into Maya's Script Editor (Python tab) and run it, then this dot will turn green."
    } elseif ($script:lastSceneHasReference -eq $false) {
        $portStatusDot.Fill = $script:cacheWarningBrush
        $portStatusLabel.Text = "Maya connection: wrong scene"
        $portStatusDot.ToolTip = "Connected, but this scene has no file references -- open the ROM scene, then click the Cache button again."
    } elseif ($script:lastSceneHasReference -eq $true) {
        $portStatusDot.Fill = "LimeGreen"
        $portStatusLabel.Text = "Maya connection: ROM scene ready"
        $portStatusDot.ToolTip = "Maya command port (127.0.0.1:7001) is open, and a ROM reference was found in the scene ($script:lastAnimRef)."
    } else {
        $portStatusDot.Fill = "LimeGreen"
        $portStatusLabel.Text = "Maya connection"
        $portStatusDot.ToolTip = "Maya command port (127.0.0.1:7001) is open -- ROM tools will work. Click the Cache button to also confirm the right scene is loaded."
    }
    return $reachable
}

$script:portCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:portCheckTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:portCheckTimer.Add_Tick({ Update-PortStatusIndicator | Out-Null })

# Same warning amber as MayaSkinningCheck's SEVERITY_COLORS["warning"]
# (akStyle.py, rgb(239, 192, 84)) -- "no cache yet" is informational (the
# next run will just take longer), not an error, so it gets the warning
# color rather than the destructive red used for Stop Recording.
$script:cacheWarningBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(239, 192, 84))

function Get-CacheStatus {
    # Deliberately synchronous, unlike every Maya-touching action button
    # (Preview/Start Recording/Reset all go through the async
    # Start-Steps/DispatcherTimer queue instead of blocking the UI thread).
    # This is a one-off, user-initiated, single fast file-existence check
    # -- never a cache BUILD -- so a short bounded wait here is an
    # acceptable, simpler trade-off than retrofitting the shared queue.
    #
    # The result comes from a FILE maya_check_cache.py writes, not from
    # capturing this process's stdout -- confirmed empirically that Maya's
    # command port does not relay print() output back over the socket on
    # a successful run (only the exec() call's own return value, always
    # None, or an exception's text). send_to_maya.ps1's blocking read is
    # still what we rely on here: it guarantees this process does not
    # exit until Maya has actually finished writing that file.
    $checkScript = Join-Path $ScriptDir "maya_check_cache.py"
    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $resultPath = Join-Path $ScriptDir "..\d4_anim_sample\_cache_check_result.txt"
    Remove-Item $resultPath -ErrorAction SilentlyContinue

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$sendToMaya`" -ScriptPath `"$checkScript`" -TimeoutMs 3000"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $proc.StandardOutput.ReadToEnd() | Out-Null
    $proc.WaitForExit(6000) | Out-Null

    if (-not (Test-Path $resultPath)) {
        return ConvertFrom-CacheCheckOutput -Output ""
    }
    return ConvertFrom-CacheCheckOutput -Output (Get-Content $resultPath -Raw)
}

function Get-TimeSliderRange {
    # Same synchronous, bounded, file-based-result pattern as
    # Get-CacheStatus, and for the same reason: a single fast query, never
    # a long operation, and print() output is not reliably relayed back
    # through the command port on success. Queried fresh every time this
    # is called (not cached) -- deliberately, so a Range Slider the artist
    # adjusts between selecting "Time Slider" and clicking Start Recording
    # is picked up correctly rather than using a stale snapshot.
    $queryScript = Join-Path $ScriptDir "maya_get_time_slider.py"
    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $resultPath = Join-Path $ScriptDir "..\d4_anim_sample\_time_slider_result.txt"
    Remove-Item $resultPath -ErrorAction SilentlyContinue

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$sendToMaya`" -ScriptPath `"$queryScript`" -TimeoutMs 3000"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $proc.StandardOutput.ReadToEnd() | Out-Null
    $proc.WaitForExit(6000) | Out-Null

    if (-not (Test-Path $resultPath)) {
        return ConvertFrom-TimeSliderOutput -Output ""
    }
    return ConvertFrom-TimeSliderOutput -Output (Get-Content $resultPath -Raw)
}

function Get-AnimationRange {
    # Same synchronous, bounded, file-based-result pattern as
    # Get-TimeSliderRange, querying maya_get_animation_range.py instead --
    # the outer animationStartTime/animationEndTime bounds, not the Range
    # Slider's current minTime/maxTime. Used by the "All" Time Range option
    # so it captures the true full animation regardless of whatever the
    # Range Slider happens to be scrubbed to right now.
    $queryScript = Join-Path $ScriptDir "maya_get_animation_range.py"
    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $resultPath = Join-Path $ScriptDir "..\d4_anim_sample\_animation_range_result.txt"
    Remove-Item $resultPath -ErrorAction SilentlyContinue

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$sendToMaya`" -ScriptPath `"$queryScript`" -TimeoutMs 3000"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $proc.StandardOutput.ReadToEnd() | Out-Null
    $proc.WaitForExit(6000) | Out-Null

    if (-not (Test-Path $resultPath)) {
        return ConvertFrom-AnimationRangeOutput -Output ""
    }
    return ConvertFrom-AnimationRangeOutput -Output (Get-Content $resultPath -Raw)
}

function Update-CacheStatusIndicator {
    # MayaHost/Port only override the reachability pre-check (so tests can
    # exercise the "Maya not reachable" branch against a definitely-closed
    # port without depending on live Maya state) -- the actual cache check
    # in Get-CacheStatus always talks to send_to_maya.ps1's own real
    # configured target, same as every other Maya-touching action.
    param([string]$MayaHost = "127.0.0.1", [int]$Port = 7001)
    if (-not (Test-MayaPortReachable -MayaHost $MayaHost -Port $Port)) {
        $cacheStatusDot.Fill = "Gray"
        $cacheStatusLabel.Text = "Cache: not reachable"
        $cacheStatusDot.ToolTip = "Open the Maya command port first (see the dot above), then check again."
        # Nothing is known here -- Force Rebuild/the refresh icon should
        # reflect that, not whatever a PREVIOUS successful check happened
        # to leave behind (a real gap: this early-return path never used
        # to touch either at all).
        $script:cacheActionable = $false
        $forceRebuildMenuItem.IsEnabled = $false
        $cacheCheckIcon.Visibility = [System.Windows.Visibility]::Visible
        $cacheRefreshIcon.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    $cacheStatusDot.Fill = "Gray"
    $cacheStatusLabel.Text = "Cache: checking..."
    $cacheActionButton.IsEnabled = $false

    $result = Get-CacheStatus
    # Reset every call rather than leaving a stale value from a PREVIOUS
    # check -- Error/Unknown below intentionally leave these $null since
    # there is nothing actionable to build/rebuild from either result.
    $script:lastCachePath = $null
    $script:lastAnimRef = $null
    $script:lastCacheStatus = $result.Status

    # Exists AND Missing both give Rebuild Cache something to do (delete
    # and rebuild vs. build for the first time -- see Confirm-AndBuildCache)
    # -- only Error/Unknown leave nothing actionable to click into.
    $script:cacheKnownToExist = $false
    $script:cacheActionable = $false

    if ($result.Status -eq "Exists") {
        $cacheStatusDot.Fill = "LimeGreen"
        $cacheStatusLabel.Text = "Cache: ready"
        $cacheStatusDot.ToolTip = "Cache found: $($result.CachePath) -- Preview/Start Recording will be fast."
        $script:lastCachePath = $result.CachePath
        $script:lastAnimRef = $result.AnimationReference
        $script:cacheKnownToExist = $true
        $script:cacheActionable = $true
        $script:lastSceneHasReference = $true
    } elseif ($result.Status -eq "Missing") {
        $cacheStatusDot.Fill = $script:cacheWarningBrush
        $cacheStatusLabel.Text = "Cache: not built yet"
        $cacheStatusDot.ToolTip = "No cache yet for: $($result.AnimationReference) -- click the Cache button to build it now, or Preview/Start Recording will trigger the same 10-16 minute build automatically."
        $script:lastAnimRef = $result.AnimationReference
        $script:cacheActionable = $true
        $script:lastSceneHasReference = $true
    } elseif ($result.Status -eq "NoReference") {
        # Distinct from Error below: not a failure, the expected result of
        # the wrong scene being loaded (or nothing referenced in yet). The
        # real signal this carries (is the RIGHT scene loaded) belongs on
        # the Maya-connection row per Update-PortStatusIndicator, not here
        # -- this row just admits it has nothing to report cache-wise.
        $cacheStatusDot.Fill = "Gray"
        $cacheStatusLabel.Text = "Cache: unknown (no scene reference)"
        $cacheStatusDot.ToolTip = "See the Maya connection dot above -- this scene has no file references to key a cache off of."
        $script:lastSceneHasReference = $false
    } elseif ($result.Status -eq "Error") {
        $cacheStatusDot.Fill = "Red"
        $cacheStatusLabel.Text = "Cache: check failed"
        $cacheStatusDot.ToolTip = $result.ErrorMessage
    } else {
        $cacheStatusDot.Fill = "Gray"
        $cacheStatusLabel.Text = "Cache: no response"
        $cacheStatusDot.ToolTip = "Maya did not respond to the cache check -- try again, or check the Script Editor."
    }

    $cacheActionButton.IsEnabled = $true
    $forceRebuildMenuItem.IsEnabled = $script:cacheActionable
    # Icon swap: magnifier while there's nothing actionable yet, refresh
    # glyph once a plain click would offer to build/rebuild something --
    # same "one control, state-dependent glyph" pattern as Start/Stop
    # Recording elsewhere in this window.
    if ($script:cacheActionable) {
        $cacheCheckIcon.Visibility = [System.Windows.Visibility]::Collapsed
        $cacheRefreshIcon.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $cacheCheckIcon.Visibility = [System.Windows.Visibility]::Visible
        $cacheRefreshIcon.Visibility = [System.Windows.Visibility]::Collapsed
    }
    # Refresh the Maya-connection dot/label right away with whatever this
    # check just learned, instead of waiting up to 5 seconds for the next
    # automatic reachability-only poll to happen to run.
    Update-PortStatusIndicator | Out-Null
}

function Confirm-AndBuildCache {
    # Shared by the Cache button's plain click (auto-offered the moment a
    # check comes back Missing -- this is the actual "ask permission"
    # behavior) and its Force Rebuild context-menu item (offered on-demand
    # any time after a check confirms Exists or Missing) -- same
    # confirm-then-build flow either way, just different confirm wording
    # depending on whether an existing cache is being replaced or built
    # for the first time.
    param([bool]$DeleteExisting)

    if ($DeleteExisting) {
        $confirmed = Show-DarkConfirm -Title "Rebuild Cache?" -ConfirmLabel "Rebuild" -Message "This deletes the existing cache for `"$script:lastAnimRef`" and rebuilds it from scratch, which takes 10-16 minutes. Continue?"
        if (-not $confirmed) {
            Write-Log "Rebuild cache cancelled."
            return
        }
        # $logBox.Clear() intentionally skipped here (ClearLog=$false below) --
        # otherwise Start-Steps would immediately wipe the "Deleted the
        # existing cache" line the moment the run starts. Same bug, same fix,
        # already found once for Stop-CurrentRun's own log message earlier.
        $logBox.Clear()
        Remove-Item $script:lastCachePath -ErrorAction SilentlyContinue
        Write-Log "Deleted the existing cache -- rebuilding from scratch..."
    } else {
        $confirmed = Show-DarkConfirm -Title "Build Cache?" -ConfirmLabel "Build" -Message "No cache exists yet for `"$script:lastAnimRef`". Build it now? This is a one-time step that takes 10-16 minutes."
        if (-not $confirmed) {
            Write-Log "Cache build cancelled."
            return
        }
        $logBox.Clear()
        Write-Log "Building cache for the first time..."
    }
    $axis = if ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $steps = Get-CaptureSteps -Axis $axis -Recording $false -ScriptDir $ScriptDir
    $script:pendingCacheRefresh = $true
    Start-Steps $steps $false $cacheActionButton "Stop Rebuilding"
}

function Set-ConfirmDialogResult([bool]$value) {
    # .GetNewClosure() (used below so the Yes/No click handlers can close
    # their own dialog window) gives the closure its OWN isolated session
    # state -- a bare `$script:confirmDialogResult = $value` written
    # directly inside one of those closures never reaches this file's real
    # script scope at all (confirmed empirically: it silently no-ops,
    # deterministically, not a race). This is the exact same class of bug
    # already documented for Register-ObjectEvent action blocks elsewhere
    # in this file, just via a different isolation mechanism. The fix is
    # the same established pattern: a real top-level FUNCTION resolves
    # variables via its own definition scope regardless of how or from
    # where it gets called, so routing the write through here (instead of
    # inline in the closure) makes it actually land.
    $script:confirmDialogResult = $value
}

function Show-DarkConfirm {
    # A custom dark-styled Yes/No dialog instead of the native
    # System.Windows.MessageBox -- that box cannot be restyled at all (it
    # is sealed OS chrome in WPF/.NET Framework) and would reintroduce the
    # exact "why is this white" complaint already raised and fixed
    # elsewhere in this window. Kept as its own overridable top-level
    # function (not inlined into the click handler) specifically so tests
    # can redefine it to return a fixed answer instead of ever blocking on
    # a real modal .ShowDialog() call -- same technique already proven for
    # Get-StopCleanupSteps in the integration tests.
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$ConfirmLabel = "Confirm"
    )
    [xml]$confirmXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" MinWidth="360" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <StackPanel Margin="16">
        <TextBlock x:Name="MessageText" TextWrapping="Wrap" Foreground="#FFE6E6E6" Margin="0,0,0,16"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="NoButton" Content="Cancel" Width="80" Height="28" Margin="0,0,8,0"
                    Background="#FF1F1F1F" Foreground="White" BorderThickness="0"/>
            <Button x:Name="YesButton" Width="100" Height="28"
                    Background="#FFE07868" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $confirmReader = New-Object System.Xml.XmlNodeReader $confirmXaml
    $confirmWindow = [Windows.Markup.XamlReader]::Load($confirmReader)
    $confirmWindow.Title = $Title
    # WPF throws if Owner is set to a Window that has never been shown --
    # true of the real $window only in the -NoShow test harness (in normal
    # use $window.ShowDialog() has already been running for as long as the
    # app has been open, long before a user could click Rebuild Cache).
    # Skipping Owner there just means the test dialog isn't centered over
    # a parent that was never on screen anyway -- harmless.
    if ($window.IsVisible) {
        $confirmWindow.Owner = $window
    }
    $confirmWindow.FindName("MessageText").Text = $Message
    $confirmWindow.FindName("YesButton").Content = $ConfirmLabel

    $script:confirmDialogResult = $false
    $confirmWindow.FindName("NoButton").Add_Click({ Set-ConfirmDialogResult $false; $confirmWindow.Close() }.GetNewClosure())
    $confirmWindow.FindName("YesButton").Add_Click({ Set-ConfirmDialogResult $true; $confirmWindow.Close() }.GetNewClosure())
    $confirmWindow.ShowDialog() | Out-Null
    return $script:confirmDialogResult
}

function Show-DarkMonitorResult {
    # Shows the REAL, verified outcome of a recording-monitor change --
    # design agreed 2026-08-22: a confirmation should never just claim
    # success, since a matching monitor_id can still mean a black
    # capture (confirmed live, twice). $PreviewPath is a real
    # GetSourceScreenshot thumbnail (see obs_monitor.ps1's -Action set),
    # shown directly so the user can SEE what OBS is actually capturing
    # right now, not just read a status line. No color-coding for
    # verified/not-verified -- this window's whole theme deliberately
    # dropped color-as-signal in favor of the monochromatic redesign
    # earlier this session, so the text itself has to carry the
    # distinction, not a red/green border.
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$PreviewPath
    )
    [xml]$resultXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" MinWidth="360" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <StackPanel Margin="16">
        <Border x:Name="PreviewBorder" BorderBrush="#FF4C4C4C" BorderThickness="1" Margin="0,0,0,12" Visibility="Collapsed">
            <Image x:Name="PreviewImage" Height="160" Stretch="Uniform"/>
        </Border>
        <TextBlock x:Name="MessageText" TextWrapping="Wrap" Foreground="#FFE6E6E6" Margin="0,0,0,16"/>
        <Button x:Name="CloseButton" Content="Close" Width="90" Height="28" HorizontalAlignment="Right"
                Background="#FF1F1F1F" Foreground="White" BorderThickness="0"/>
    </StackPanel>
</Window>
"@
    $resultReader = New-Object System.Xml.XmlNodeReader $resultXaml
    $resultWindow = [Windows.Markup.XamlReader]::Load($resultReader)
    $resultWindow.Title = $Title
    if ($window.IsVisible) {
        $resultWindow.Owner = $window
    }
    $resultWindow.FindName("MessageText").Text = $Message

    if ($PreviewPath -and (Test-Path $PreviewPath)) {
        # CacheOption OnLoad reads the file into memory immediately and
        # releases the handle -- without it BitmapImage keeps the PNG
        # file locked open for as long as this Image control exists,
        # which would block obs_monitor.ps1 from overwriting the same
        # preview path on the NEXT monitor change.
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = New-Object System.Uri($PreviewPath)
        $bitmap.EndInit()
        $resultWindow.FindName("PreviewImage").Source = $bitmap
        $resultWindow.FindName("PreviewBorder").Visibility = [System.Windows.Visibility]::Visible
    }

    $resultWindow.FindName("CloseButton").Add_Click({ $resultWindow.Close() }.GetNewClosure())
    $resultWindow.Show()
}

function Set-InputDialogResult($value) {
    # Same reasoning as Set-ConfirmDialogResult -- routes the write
    # through a real top-level function instead of inline inside a
    # .GetNewClosure()'d click handler, which is what actually reaches
    # this file's real script scope.
    $script:inputDialogResult = $value
}

function Show-DarkInput {
    # Text-entry sibling of Show-DarkConfirm, same dark styling and the
    # same GetNewClosure()-safe result pattern. Returns the entered text,
    # or $null specifically for Cancel -- an empty string is a valid
    # "save an empty value" answer, distinct from "cancelled", so callers
    # must check for $null, not falsiness.
    #
    # -Masked swaps in a real PasswordBox instead of a plain TextBox --
    # both exist in the XAML at all times and only one is ever Visible; a
    # Collapsed element takes no layout space in a StackPanel, so this
    # does not leave a gap. PasswordBox.Password is set/read directly from
    # code (not bound in XAML, which WPF deliberately restricts for
    # security) -- that is normal, fully supported usage, not a workaround.
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$InitialValue = "",
        [string]$ConfirmLabel = "Save",
        [switch]$Masked
    )
    [xml]$inputXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" MinWidth="360" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <StackPanel Margin="16">
        <TextBlock x:Name="MessageText" TextWrapping="Wrap" Foreground="#FFE6E6E6" Margin="0,0,0,10"/>
        <TextBox x:Name="InputBox" Padding="4" Margin="0,0,0,16"/>
        <PasswordBox x:Name="InputPasswordBox" Padding="4" Margin="0,0,0,16" Background="#FF1C1C1C" Foreground="White" BorderBrush="#FF4C4C4C" BorderThickness="1"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelButton" Content="Cancel" Width="80" Height="28" Margin="0,0,8,0"
                    Background="#FF1F1F1F" Foreground="White" BorderThickness="0"/>
            <!-- Monochromatic theme (2026-08-21): was blue, matching the
                 old active-tab/progress-bar accent. Same light neutral
                 gray now, with dark text for contrast (light bg, same
                 reasoning as Set-ActiveTab's own text-color flip). -->
            <Button x:Name="SaveButton" Width="100" Height="28"
                    Background="#FFD0D0D0" Foreground="#FF1F1F1F" FontWeight="Bold" BorderThickness="0"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $inputReader = New-Object System.Xml.XmlNodeReader $inputXaml
    $inputWindow = [Windows.Markup.XamlReader]::Load($inputReader)
    $inputWindow.Title = $Title
    if ($window.IsVisible) {
        $inputWindow.Owner = $window
    }
    $inputWindow.FindName("MessageText").Text = $Message
    $inputBoxRef = $inputWindow.FindName("InputBox")
    $passwordBoxRef = $inputWindow.FindName("InputPasswordBox")
    $inputWindow.FindName("SaveButton").Content = $ConfirmLabel

    if ($Masked) {
        $inputBoxRef.Visibility = [System.Windows.Visibility]::Collapsed
        $passwordBoxRef.Password = $InitialValue
        $passwordBoxRef.Focus() | Out-Null
    } else {
        $passwordBoxRef.Visibility = [System.Windows.Visibility]::Collapsed
        $inputBoxRef.Text = $InitialValue
    }

    $script:inputDialogResult = $null
    $inputWindow.FindName("CancelButton").Add_Click({ Set-InputDialogResult $null; $inputWindow.Close() }.GetNewClosure())
    $inputWindow.FindName("SaveButton").Add_Click({
        $value = if ($Masked) { $passwordBoxRef.Password } else { $inputBoxRef.Text }
        Set-InputDialogResult $value
        $inputWindow.Close()
    }.GetNewClosure())
    $inputWindow.ShowDialog() | Out-Null
    return $script:inputDialogResult
}

function Get-ObsConfigFilePath {
    Join-Path $ScriptDir "obs_config.txt"
}

function Get-ObsPasswordStatus {
    $path = Get-ObsConfigFilePath
    if (-not (Test-Path $path)) {
        return ConvertFrom-ObsConfigContent -Content ""
    }
    return ConvertFrom-ObsConfigContent -Content (Get-Content $path -Raw)
}

function Update-ObsPasswordStatusIndicator {
    # Genuinely binary (configured or not -- there is no live "checking"
    # state the way Maya/Cache have), so this dot only ever needs
    # green/dim, unlike the richer gray/green/amber/red range the other
    # two rows use.
    $status = Get-ObsPasswordStatus
    if ($status.Configured) {
        $obsPasswordStatusDot.Fill = "LimeGreen"
        $obsPasswordStatusLabel.Text = "OBS WebSocket: password set"
    } else {
        $obsPasswordStatusDot.Fill = "Gray"
        $obsPasswordStatusLabel.Text = "OBS WebSocket: not configured"
    }
}

function Get-ObsMonitorList([switch]$EnsureRunning) {
    # Synchronous, like Get-CacheStatus/Get-TimeSliderRange -- a single
    # fast WebSocket round-trip to OBS, never a long operation UNLESS
    # -EnsureRunning is passed (design 2026-08-22: the Refresh button and
    # "just saved the OBS password" flow can ask this to cold-launch OBS
    # first, which can take up to obs_monitor.ps1's own 60s bound -- the
    # 8s timeout below is only right for the normal, no-launch case).
    # Unlike the Maya command-port scripts, obs_monitor.ps1's own stdout
    # DOES relay directly (it's a normal process invocation, not exec()
    # over a socket), but it still also writes a result file for
    # consistency with the rest of this codebase's established pattern --
    # read from stdout here since there's no send_to_maya.ps1-style relay
    # problem to work around.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $ensureArg = if ($EnsureRunning) { " -EnsureRunning" } else { "" }
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'obs_monitor.ps1')`" -Action list$ensureArg"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $output = $proc.StandardOutput.ReadToEnd()
    $waitMs = if ($EnsureRunning) { 65000 } else { 8000 }
    $proc.WaitForExit($waitMs) | Out-Null

    return ConvertFrom-ObsMonitorListOutput -Output $output
}

function Set-ObsMonitorSelection([string]$MonitorId) {
    # Returns ConvertFrom-ObsMonitorSetOutput's structured result, not the
    # raw trimmed string -- obs_monitor.ps1's -Action set now applies AND
    # verifies with a real screenshot (2026-08-22), so callers need
    # .Verified/.Message/.PreviewPath, not just "did the process not
    # error." 15s timeout, up from 8s: the new flow can include one safe
    # repair attempt (a scene-item toggle + a few 500ms re-checks) when
    # the first verification comes back black.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'obs_monitor.ps1')`" -Action set -MonitorId `"$MonitorId`""
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $output = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit(15000) | Out-Null
    return ConvertFrom-ObsMonitorSetOutput -Output $output
}

function Get-RecordingMonitorRectPath {
    # Own function, not inlined into Write-RecordingMonitorRect, same
    # reasoning as Get-ObsConfigFilePath above: lets tests override just
    # the path (to a throwaway temp file) without ever touching this
    # project's real d4_anim_sample state.
    Join-Path $ScriptDir "..\d4_anim_sample\_recording_monitor_rect.txt"
}

function Write-RecordingMonitorRect([string]$MonitorName) {
    # Closes a real gap (2026-08-21): maya_camera_panels.py/_LR.py used to
    # spawn the tracked camera panels at a hardcoded SECONDARY_MONITOR_RECT
    # completely independent of this Recording Monitor setting -- changing
    # the dropdown moved what OBS records but not where the panels
    # actually appear, so picking anything other than whichever monitor
    # happened to match the old hardcoded default would silently record
    # the wrong screen (no panels visible in the capture at all). Writing
    # the selected monitor's rect here, parsed straight out of OBS's own
    # display name (see ConvertFrom-ObsMonitorName), and having both
    # Python scripts read it instead of their hardcoded constant is what
    # actually closes that gap.
    $parsed = ConvertFrom-ObsMonitorName -Name $MonitorName
    if (-not $parsed.Success) {
        Write-Log "Could not parse a screen rect out of monitor name '$MonitorName' -- camera panels will keep using their last known/default monitor."
        return
    }
    $rectPath = Get-RecordingMonitorRectPath
    $rectDir = Split-Path $rectPath -Parent
    if (-not (Test-Path $rectDir)) {
        New-Item -ItemType Directory -Path $rectDir | Out-Null
    }
    # -Encoding ASCII, not UTF8: confirmed the hard way (2026-08-21) that
    # Windows PowerShell 5.1's "UTF8" always writes a byte-order mark, and
    # Python's plain open().read() on the other end does NOT strip it --
    # the BOM bytes land on the front of the first number, int() throws
    # ValueError, and get_secondary_monitor_rect()'s try/except silently
    # swallows that and falls back to the OLD hardcoded rect. This is
    # exactly why switching monitors in the dropdown appeared to do
    # nothing: the file was being written correctly, just never
    # successfully READ. Content here is plain ASCII digits/commas/minus
    # signs only, so ASCII encoding is sufficient and has no BOM concept
    # to trip over in the first place.
    Set-Content -Path $rectPath -Value "$($parsed.Left),$($parsed.Top),$($parsed.Right),$($parsed.Bottom)" -Encoding ASCII
}

function Get-RecordingMonitorNamePath {
    # Own function, same reasoning as Get-RecordingMonitorRectPath --
    # lets tests override the path without touching real project state.
    Join-Path $ScriptDir "..\d4_anim_sample\_recording_monitor_name.txt"
}

function Write-RecordingMonitorName([string]$MonitorName) {
    # Persists the selected monitor's own display Name (not just its
    # parsed rect) so the launcher can show something meaningful in the
    # ComboBox on a LATER launch where OBS isn't running yet -- design
    # agreed 2026-08-22: detect the recording monitor at launch even when
    # the tool can't ask OBS directly, by falling back to whatever was
    # last confirmed, rather than showing a blank/error control.
    $namePath = Get-RecordingMonitorNamePath
    $nameDir = Split-Path $namePath -Parent
    if (-not (Test-Path $nameDir)) {
        New-Item -ItemType Directory -Path $nameDir | Out-Null
    }
    Set-Content -Path $namePath -Value $MonitorName -Encoding UTF8
}

function Read-RecordingMonitorName {
    $namePath = Get-RecordingMonitorNamePath
    if (-not (Test-Path $namePath)) {
        return $null
    }
    $name = (Get-Content -Path $namePath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }
    return $name.Trim()
}

function Update-MonitorList([switch]$EnsureRunning) {
    # Populates the ComboBox fresh from OBS -- not polled continuously
    # (see the XAML comment on MonitorComboBox), called once at startup
    # and available to re-run manually later if monitors change.
    # $script:suppressMonitorSelectionChanged guards the SelectionChanged
    # handler below from firing (and re-applying to OBS) while this
    # function is the one setting SelectedIndex programmatically, not the
    # user picking something.
    #
    # Design agreed 2026-08-22: the dropdown must never let the user pick
    # a monitor blind, before OBS has actually confirmed what's live --
    # it stays DISABLED, showing only the last known selection, until a
    # real response comes back from OBS. This also means detection works
    # even on a launch where OBS isn't running yet, instead of just
    # showing an error with an empty control.
    $monitorStatusDot.Fill = "Gray"
    $monitorStatusLabel.Text = if ($EnsureRunning) { "Recording Monitor: launching OBS, please wait..." } else { "Recording Monitor: checking..." }
    # A property change alone only QUEUES a repaint on this same
    # dispatcher thread -- it does not force one. Get-ObsMonitorList
    # below blocks this thread synchronously, so without flushing here
    # first, the status text above would never actually become visible
    # until AFTER the call returns, and -EnsureRunning's call can run up
    # to ~60s (cold OBS launch): the whole window would just look frozen
    # for a minute with no visible explanation, not "launching OBS."
    $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [Action]{})
    $result = Get-ObsMonitorList -EnsureRunning:$EnsureRunning
    $script:suppressMonitorSelectionChanged = $true
    try {
        $monitorComboBox.Items.Clear()
        if (-not $result.Success) {
            $monitorComboBox.IsEnabled = $false
            $lastKnown = Read-RecordingMonitorName
            if ($lastKnown) {
                $monitorComboBox.Items.Add($lastKnown) | Out-Null
                $monitorComboBox.SelectedIndex = 0
                $monitorStatusDot.Fill = "Gray"
                $monitorStatusLabel.Text = "Recording Monitor: OBS not running -- showing last used"
            } else {
                $monitorStatusDot.Fill = "Red"
                $monitorStatusLabel.Text = "Recording Monitor: $($result.ErrorMessage)"
            }
            return
        }
        $selectedIndex = -1
        for ($i = 0; $i -lt $result.Monitors.Count; $i++) {
            $m = $result.Monitors[$i]
            $monitorComboBox.Items.Add($m.Name) | Out-Null
            if ($m.IsCurrent) { $selectedIndex = $i }
        }
        $script:obsMonitorOptions = $result.Monitors
        $monitorComboBox.IsEnabled = $true
        if ($selectedIndex -ge 0) {
            $monitorComboBox.SelectedIndex = $selectedIndex
            $script:lastConfirmedMonitorIndex = $selectedIndex
            Write-RecordingMonitorRect -MonitorName $result.Monitors[$selectedIndex].Name
            Write-RecordingMonitorName -MonitorName $result.Monitors[$selectedIndex].Name
        }
        $monitorStatusDot.Fill = "LimeGreen"
        $monitorStatusLabel.Text = "Recording Monitor"
    } finally {
        $script:suppressMonitorSelectionChanged = $false
    }
}

function New-GuideStepRow([string]$Number, [string]$Lead, [string]$Text) {
    # One numbered step, laid out as a 2-column Grid (fixed-width number
    # column + wrapping text column) instead of plain "1. Lead: text"
    # inline in a paragraph -- a wrapped second line then aligns under the
    # step's own text, not back at the left margin under the number,
    # which is what made the old flat TextBlock version read as a run-on
    # paragraph rather than a scannable list (2026-08-22 readability
    # pass). $Lead renders bold so the word someone's actually scanning
    # for ("Cache button:", "OBS WebSocket password:") stands out from
    # its own explanation.
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = "0,0,0,8"
    $numCol = New-Object System.Windows.Controls.ColumnDefinition
    $numCol.Width = [System.Windows.GridLength]::new(20)
    $textCol = New-Object System.Windows.Controls.ColumnDefinition
    $textCol.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $grid.ColumnDefinitions.Add($numCol)
    $grid.ColumnDefinitions.Add($textCol)

    $numText = New-Object System.Windows.Controls.TextBlock
    $numText.Text = "$Number."
    $numText.Foreground = "#FFE6E6E6"
    $numText.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    [System.Windows.Controls.Grid]::SetColumn($numText, 0)
    $grid.Children.Add($numText) | Out-Null

    $bodyText = New-Object System.Windows.Controls.TextBlock
    $bodyText.TextWrapping = "Wrap"
    $bodyText.Foreground = "#FFE6E6E6"
    [System.Windows.Controls.Grid]::SetColumn($bodyText, 1)
    if ($Lead) {
        $boldRun = New-Object System.Windows.Documents.Bold
        $boldRun.Inlines.Add((New-Object System.Windows.Documents.Run("$Lead "))) | Out-Null
        $bodyText.Inlines.Add($boldRun) | Out-Null
    }
    $bodyText.Inlines.Add((New-Object System.Windows.Documents.Run($Text))) | Out-Null
    $grid.Children.Add($bodyText) | Out-Null

    return $grid
}

function Get-GuideStepPlainText($stepRow) {
    # Flattens a New-GuideStepRow grid's Lead+Text back into one plain
    # string -- lets tests substring-match rendered content the same way
    # they matched the old flat $Message string, without needing to know
    # this is now a Grid of Inlines under the hood.
    $bodyText = $stepRow.Children[1]
    $sb = New-Object System.Text.StringBuilder
    foreach ($inline in $bodyText.Inlines) {
        if ($inline -is [System.Windows.Documents.Bold]) {
            foreach ($run in $inline.Inlines) { $sb.Append($run.Text) | Out-Null }
        } else {
            $sb.Append($inline.Text) | Out-Null
        }
    }
    return $sb.ToString()
}

function Show-DarkGuide {
    # Read-only info dialog: no Confirm/Input semantics, just a scrollable
    # message and a single Close button, same dark styling as
    # Show-DarkConfirm/Show-DarkInput. Wider (360) and allows a tall
    # ScrollViewer since guide content is expected to run long (TLDR +
    # numbered steps), unlike the short one-liners those two dialogs show.
    #
    # Non-modal (.Show(), not .ShowDialog()) so the main window stays
    # interactive while the guide is open -- a reference doc, not a
    # blocking prompt, so there is no reason it should freeze the rest of
    # the app. Reuses one instance ($script:openGuideWindow): clicking
    # Guide again while it's already open just brings the existing window
    # forward instead of stacking duplicates.
    #
    # $Sections is an array of @{ Header = "..."; Steps = @(@{ Lead =
    # "..."; Text = "..." }, ...) } -- structured data instead of one
    # flat pre-formatted string (2026-08-22 readability pass), so bold
    # section headers and hanging-indent numbered steps can actually be
    # built as real WPF elements (TextBlock.Text can't carry partial
    # bold/alignment on its own).
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Tldr,
        [array]$Sections = @()
    )
    if ($script:openGuideWindow -ne $null -and $script:openGuideWindow.IsVisible) {
        $script:openGuideWindow.Activate() | Out-Null
        return
    }
    # NOTE: any code that needs to write $script:openGuideWindow from
    # inside a .GetNewClosure()'d scriptblock below must route through
    # Clear-OpenGuideWindow (a real top-level function), never a bare
    # `$script:openGuideWindow = ...` written directly inside the
    # closure -- confirmed empirically (2026-08-20, Show-DarkConfirm's own
    # Yes/No handlers) that .GetNewClosure() isolates the closure's own
    # session state, so such a write silently never reaches this file's
    # real script scope at all.
    [xml]$guideXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="380" Height="480" MinWidth="320" MinHeight="260" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <Grid Margin="16">
        <!-- Grid instead of the old StackPanel + fixed MaxHeight="420":
             now that the window itself resizes, the ScrollViewer's row is
             "*" so dragging the dialog taller actually reveals more text
             at once instead of just growing empty space around a
             capped-height scroll box. -->
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Margin="0,0,0,16">
            <StackPanel x:Name="ContentPanel"/>
        </ScrollViewer>
        <Button Grid.Row="1" x:Name="CloseButton" Content="Close" Width="90" Height="28" HorizontalAlignment="Right"
                Background="#FF1F1F1F" Foreground="White" BorderThickness="0"/>
    </Grid>
</Window>
"@
    $guideReader = New-Object System.Xml.XmlNodeReader $guideXaml
    $guideWindow = [Windows.Markup.XamlReader]::Load($guideReader)
    $guideWindow.Title = $Title
    if ($window.IsVisible) {
        $guideWindow.Owner = $window
    }

    $contentPanel = $guideWindow.FindName("ContentPanel")

    $tldrText = New-Object System.Windows.Controls.TextBlock
    $tldrText.Name = "TldrText"
    $tldrText.Text = $Tldr
    $tldrText.TextWrapping = "Wrap"
    $tldrText.FontWeight = "Bold"
    $tldrText.FontSize = 14
    $tldrText.Foreground = "#FFE6E6E6"
    $tldrText.Margin = "0,0,0,14"
    $contentPanel.RegisterName($tldrText.Name, $tldrText)
    $contentPanel.Children.Add($tldrText) | Out-Null

    foreach ($section in $Sections) {
        $headerText = New-Object System.Windows.Controls.TextBlock
        $headerText.Text = $section.Header
        $headerText.TextWrapping = "Wrap"
        $headerText.FontWeight = "Bold"
        $headerText.FontSize = 13
        $headerText.Foreground = "#FFE6E6E6"
        $headerText.Margin = "0,0,0,8"
        $contentPanel.Children.Add($headerText) | Out-Null

        $stepNumber = 1
        foreach ($step in $section.Steps) {
            $stepRow = New-GuideStepRow -Number $stepNumber -Lead $step.Lead -Text $step.Text
            $contentPanel.Children.Add($stepRow) | Out-Null
            $stepNumber++
        }
    }

    $guideWindow.FindName("CloseButton").Add_Click({ $guideWindow.Close() }.GetNewClosure())
    # Clears the tracked reference once actually closed, so a LATER click
    # creates a fresh window rather than trying to Activate() a disposed
    # one -- Closed (not Closing) since this only needs to run once the
    # window is genuinely gone. Routed through Clear-OpenGuideWindow, not
    # a bare $script: write inline -- see the NOTE above.
    $guideWindow.Add_Closed({ Clear-OpenGuideWindow }.GetNewClosure())
    $script:openGuideWindow = $guideWindow
    $guideWindow.Show()
}

function Clear-OpenGuideWindow {
    $script:openGuideWindow = $null
}

function Set-CaptureAbortReason($reason) {
    # Same GetNewClosure()-adjacent scoping reasoning as
    # Clear-OpenGuideWindow/Set-ConfirmDialogResult -- see this write's
    # one call site (inside Start-NextStep's OutputDataReceived action)
    # for why it must go through a real top-level function.
    $script:captureAbortReason = $reason
}

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

function Set-ButtonsEnabled([bool]$enabled, $activeButton = $null) {
    # copySnippetButton/obsPasswordButton added here alongside
    # cacheActionButton (2026-08-20): editing the OBS password or copying
    # the port snippet while a capture is actively running is a race
    # waiting to happen -- they were previously left clickable through any
    # run, unlike every other secondary action, which was an
    # inconsistency, not a deliberate choice. monitorRefreshButton added
    # 2026-08-22 for the same reason, plus its own: it blocks the UI
    # thread synchronously for up to ~60s (launching OBS), which would
    # also stall $script:pollTimer -- the DispatcherTimer driving an
    # ALREADY-active run's own step transitions -- if clicked mid-capture.
    foreach ($b in @($previewButton, $startRecordingButton, $resetButton, $cacheActionButton, $copySnippetButton, $obsPasswordButton, $monitorRefreshButton)) {
        if (-not $enabled -and $b -eq $activeButton) {
            # The button that started the current run stays clickable --
            # it's the one now showing "Stop" (see Set-ButtonRunningVisual)
            # -- including through the cleanup sequence Stop itself kicks
            # off, in case a cleanup step needs to be force-killed too.
            $b.IsEnabled = $true
        } else {
            $b.IsEnabled = $enabled
        }
    }
    # Force Rebuild (the cache button's right-click menu item) has an
    # extra gating condition beyond "is anything else currently running":
    # it only ever makes sense once a check has confirmed a status it can
    # act on -- Exists (delete + rebuild) or Missing (build for the first
    # time); see $script:cacheActionable, set by
    # Update-CacheStatusIndicator. Unlike the old separate Rebuild Cache
    # button, this is a MenuItem, not the button clicked to start/stop a
    # run, so it has no "stays enabled if it's the active button" carve-out
    # to make -- cacheActionButton itself (above) already covers that.
    $forceRebuildMenuItem.IsEnabled = $enabled -and $script:cacheActionable
    $timeSliderRadio.IsEnabled = $enabled
    $allFramesRadio.IsEnabled = $enabled
    $startEndRadio.IsEnabled = $enabled
    $startFrameBox.IsEnabled = $enabled -and $startEndRadio.IsChecked
    $endFrameBox.IsEnabled = $enabled -and $startEndRadio.IsChecked
    $monitorComboBox.IsEnabled = $enabled
}

function Set-ButtonRunningVisual($button, [bool]$running, [string]$runningLabel = "Stop") {
    if ($button -eq $null) { return }
    # Icon buttons (the Cache button) have a UIElement (a Grid of Canvas
    # glyphs) as their Content, not a string -- swapping .Content the way text
    # buttons do would silently replace the icon with plain text and lose
    # it for good (Tag never held the icon to restore). Icon buttons rely
    # on the Background color change alone to signal "active, click to
    # stop" -- text buttons still get the specific running-label swap
    # (matches OBS's own "Stop Recording", not a generic "Stop").
    $isTextButton = $button.Content -is [string]
    if ($running) {
        if ($isTextButton) {
            $button.Content = $runningLabel
            $button.FontWeight = "Bold"
        }
        $button.Background = $script:stopBrush
    } else {
        if ($isTextButton) {
            $button.Content = $button.Tag
            $button.ClearValue([System.Windows.Controls.Control]::FontWeightProperty)
        }
        $button.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
    }
}

function Complete-Run([string]$FinalMessage = "=== All steps finished ===") {
    # Factored out of Start-NextStep's own "ran out of steps" branch so
    # the pollTimer's abort path (see Set-CaptureAbortReason) can share
    # the exact same cleanup instead of a second, easy-to-drift copy.
    $script:pollTimer.Stop()
    $script:runStatus = "Done"
    Set-ButtonRunningVisual $script:activeButton $false
    Set-ButtonsEnabled $true
    $script:activeButton = $null
    Write-Log $FinalMessage
    if ($script:pendingCacheRefresh) {
        $script:pendingCacheRefresh = $false
        Update-CacheStatusIndicator
    }
}

function Start-NextStep {
    if ($script:currentStepIndex -ge $script:currentSteps.Count) {
        Complete-Run
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
        if ($EventArgs.Data) {
            Write-Log $EventArgs.Data
            # CAPTURE_ABORT is a marker the Python capture scripts print
            # (see maya_key_from_cache.py/_LR.py) when a step hits a
            # condition that makes the rest of the run pointless -- e.g.
            # no cache could be built because the scene has no real ROM
            # animation. Design (2026-08-22, "never quietly stop"): the
            # step queue normally does NOT gate on a step's exit code
            # (Get-StopCleanupSteps relies on that independence, and
            # changing it globally would be a much bigger, riskier
            # change than this needs), so this marker is how ONE
            # specific step can opt the WHOLE run into stopping here
            # instead of silently continuing into camera panels and a
            # broken OBS recording. Routed through the real top-level
            # Set-CaptureAbortReason function, not a bare `$script:`
            # write directly inside this scriptblock -- confirmed
            # empirically (2026-08-22) that a bare `$script:` assignment
            # inside a Register-ObjectEvent -Action block does NOT reach
            # this file's real script scope (same class of isolation
            # already documented elsewhere in this file for
            # .GetNewClosure()'d scriptblocks), while the exact same
            # write routed through a top-level function does.
            if ($EventArgs.Data -match "CAPTURE_ABORT:\s*(.*)") {
                Set-CaptureAbortReason $Matches[1]
            }
        }
    } | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { Write-Log "[stderr] $($EventArgs.Data)" }
    } | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $script:currentProcess = $proc
}

# Cheap (single small text file, a handful of key=value lines) to poll
# every 200ms alongside the existing process-exit check below. Deleted at
# the start of every run (see Start-Steps) so this can trust "file exists"
# to mean "this run's own cache build wrote it," not a stale leftover from
# a previous run.
function Update-CacheProgress {
    if (-not (Test-Path $script:cacheProgressPath)) {
        if ($cacheProgressPanel.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed
        }
        return
    }
    $lines = Get-Content $script:cacheProgressPath -ErrorAction SilentlyContinue
    if (-not $lines) { return }
    $data = @{}
    foreach ($line in $lines) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $data[$parts[0]] = $parts[1] }
    }
    $done = 0
    $total = 1
    $percent = 0.0
    [void][int]::TryParse($data['frames_done'], [ref]$done)
    [void][int]::TryParse($data['frames_total'], [ref]$total)
    [void][double]::TryParse($data['percent'], [ref]$percent)
    $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Visible
    $cacheProgressBar.Value = $percent
    $cacheProgressLabel.Text = "Building animation cache: $done / $total frames ($($percent.ToString('0.0'))%) -- one time only, future runs reuse this"
}

$script:pollTimer.Add_Tick({
    Update-CacheProgress
    if ($script:currentProcess -eq $null) { return }
    if ($script:currentProcess.HasExited) {
        Write-Log "--- exited with code $($script:currentProcess.ExitCode) ---"
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:currentProcess } | Unregister-Event
        $script:currentProcess = $null
        if ($script:captureAbortReason) {
            # See Set-CaptureAbortReason -- a step asked for the WHOLE
            # run to stop here, not just itself, so this skips straight
            # to Complete-Run instead of advancing $script:currentStepIndex
            # into the remaining steps (camera panels, OBS recording).
            Complete-Run "=== Run aborted: $($script:captureAbortReason) ==="
            return
        }
        $script:currentStepIndex++
        Start-NextStep
    }
})

function Start-Steps([array]$steps, [bool]$ClearLog = $true, $Button = $null, [string]$RunningLabel = "Stop") {
    if ($script:currentProcess -ne $null) {
        Write-Log "(already running -- ignoring click)"
        return
    }
    $script:currentSteps = $steps
    $script:currentStepIndex = 0
    $script:activeButton = $Button
    $script:captureAbortReason = $null
    # Stashed so Stop-CurrentRun's own Start-Steps call (for the cleanup
    # sequence) can keep showing the same label instead of resetting to
    # the generic default partway through.
    $script:activeRunningLabel = $RunningLabel
    Set-ButtonsEnabled $false $Button
    Set-ButtonRunningVisual $Button $true $RunningLabel
    $script:runStatus = "Running..."
    # Stop-CurrentRun passes $false here so the "STOP requested" line (and
    # any output from the step that got killed) survives into the cleanup
    # run's log instead of vanishing the instant cleanup starts.
    if ($ClearLog) { $logBox.Clear() }
    # Removed (not just left stale) so Update-CacheProgress can trust that
    # a freshly-appearing file belongs to THIS run's own cache build, not
    # a leftover percentage from whatever the last build happened to reach.
    Remove-Item $script:cacheProgressPath -ErrorAction SilentlyContinue
    $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $script:pollTimer.Start()
    Start-NextStep
}

function Stop-CurrentRun {
    if ($script:currentProcess -eq $null) {
        Write-Log "(nothing running -- Stop has nothing to do)"
        return
    }

    Write-Log "=== STOP requested -- killing current step and cleaning up ==="
    try {
        if (-not $script:currentProcess.HasExited) {
            $script:currentProcess.Kill()
        }
    } catch {
        Write-Log "(process was already exiting: $($_.Exception.Message))"
    }
    Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:currentProcess } | Unregister-Event
    $script:currentProcess = $null
    $script:pollTimer.Stop()

    # Process.Kill() bypasses maya_obs_capture.ps1's own `finally` cleanup
    # entirely (see Get-StopCleanupSteps) -- run the same cleanup ourselves,
    # reusing the same standalone utility scripts, as its own step sequence
    # through the normal queue so status/logging/button-state stay
    # consistent with every other run. Keep showing the same running label
    # on the same button through the cleanup run by passing both through
    # unchanged.
    Start-Steps (Get-StopCleanupSteps -ScriptDir $ScriptDir) $false $script:activeButton $script:activeRunningLabel
}

$startEndRadio.Add_Checked({
    $startEndPanel.Visibility = [System.Windows.Visibility]::Visible
    # Real bug fixed (2026-08-20): IsEnabled on these boxes was previously
    # only ever touched inside Set-ButtonsEnabled, which only runs when a
    # run starts/finishes -- selecting this radio on its own never
    # re-enabled them, so if the LAST time Set-ButtonsEnabled ran was
    # while some other Time Range option was selected, the boxes could
    # stay stuck disabled indefinitely even after switching to Start/End.
    # Only enable if nothing is currently running, matching every other
    # control's own run-state gating.
    $isIdle = ($script:currentProcess -eq $null)
    $startFrameBox.IsEnabled = $isIdle
    $endFrameBox.IsEnabled = $isIdle
})
$timeSliderRadio.Add_Checked({ $startEndPanel.Visibility = [System.Windows.Visibility]::Collapsed })
$allFramesRadio.Add_Checked({ $startEndPanel.Visibility = [System.Windows.Visibility]::Collapsed })

# Reads the real WPF controls' current values (and, for Time Slider, makes
# a real bounded round-trip to Maya) but returns a result object instead
# of starting anything -- lets tests verify the Time Range validation
# without ever calling Start-Steps (which would launch real
# send_to_maya.ps1/maya_obs_capture.ps1 processes against whatever's live
# in Maya right now).
function Get-CaptureClickResult {
    $axis = if ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }

    if ($allFramesRadio.IsChecked) {
        # Explicitly queries the true animation range (not just whatever
        # the Range Slider happens to show) so "All" always means the full
        # ROM -- a real bug fixed (2026-08-20): passing no range at all
        # here left maya_obs_capture.ps1 trusting Maya's current
        # playbackOptions minTime/maxTime implicitly, which could be
        # narrower than the actual animation if the Range Slider had been
        # scrubbed for something unrelated since the scene was opened.
        $range = Get-AnimationRange
        if (-not $range.Success) {
            return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Could not read Maya's animation range: $($range.ErrorMessage) -- not starting." }
        }
        if ($range.Start -gt $range.End) {
            return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Maya's animation range is invalid (Start $($range.Start) > End $($range.End)) -- not starting." }
        }
        $steps = Get-CaptureSteps -Axis $axis -Recording $true -ScriptDir $ScriptDir -StartFrame $range.Start -EndFrame $range.End
        return [PSCustomObject]@{ Steps = $steps; ErrorMessage = $null }
    }

    if ($timeSliderRadio.IsChecked) {
        $range = Get-TimeSliderRange
        if (-not $range.Success) {
            return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Could not read Maya's Time Slider range: $($range.ErrorMessage) -- not starting." }
        }
        if ($range.Start -gt $range.End) {
            return [PSCustomObject]@{ Steps = $null; ErrorMessage = "Maya's Time Slider range is invalid (Start $($range.Start) > End $($range.End)) -- not starting." }
        }
        $steps = Get-CaptureSteps -Axis $axis -Recording $true -ScriptDir $ScriptDir -StartFrame $range.Start -EndFrame $range.End
        return [PSCustomObject]@{ Steps = $steps; ErrorMessage = $null }
    }

    # Start/End (manual entry)
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

$previewButton.Add_Click({
    # No toggle here -- Preview is a fast, one-shot action (matches
    # pre-Stop-feature behavior). It just disables like any other inactive
    # button while something runs; only Start Recording's own run makes
    # PreviewButton clickable-but-inert-while-disabled the normal way.
    $axis = if ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $steps = Get-CaptureSteps -Axis $axis -Recording $false -ScriptDir $ScriptDir
    # Preview silently triggers a cache build itself when one doesn't
    # exist yet (see the guide text) -- flagging this so the Cache status
    # dot/label refresh once that finishes, instead of staying stuck on
    # whatever it showed (or never showed) before this click.
    $script:pendingCacheRefresh = $true
    Start-Steps $steps
})

$startRecordingButton.Add_Click({
    # This is the one button that toggles into Stop -- matches OBS's own
    # Start/Stop Recording button, since this is the one long-running
    # recording action a user would actually want to interrupt mid-flight.
    if ($script:currentProcess -ne $null -and $script:activeButton -eq $startRecordingButton) {
        Stop-CurrentRun
        return
    }
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) {
        Write-Log $result.ErrorMessage
        return
    }
    # Same reasoning as Preview above -- Start Recording can also trigger
    # a silent first-time cache build.
    $script:pendingCacheRefresh = $true
    # Reset appended as the run's own final step, not a separate
    # completion-triggered callback: a completed recording should always
    # end with a clean scene (tracked cameras/panels removed, timeline
    # back to frame 0), and folding it into the same step list means Stop
    # Recording still shows the SAME "Stop Recording" label/Stop-toggle
    # behavior through it, and Stop-CurrentRun's own separate cleanup path
    # (for a MANUALLY interrupted recording) is untouched -- only a
    # NATURALLY finished recording auto-resets.
    # @(...) wrapping $result.Steps is required, not decorative: PowerShell
    # unwraps a single-element array back to a scalar across a function
    # return (same footgun Get-CleanResetStep's own header comment already
    # documents), and `+` between a scalar PSCustomObject and an array
    # throws ("does not contain a method named 'op_Addition'") instead of
    # concatenating -- confirmed the hard way via a test whose mocked
    # Get-CaptureSteps happened to return exactly one step. Real usage
    # normally returns several steps for Recording=$true so this never
    # actually got hit in practice, but that made it a latent bug, not a
    # nonexistent one.
    $steps = @($result.Steps) + (Get-CleanResetStep -ScriptDir $ScriptDir)
    Start-Steps $steps $true $startRecordingButton "Stop Recording"
})

$resetButton.Add_Click({
    # No toggle -- same reasoning as Preview, a fast one-shot step.
    $steps = Get-CleanResetStep -ScriptDir $ScriptDir
    Start-Steps $steps
})

$settingsTabButton.Add_Click({ Set-ActiveTab "Settings" })
$captureTabButton.Add_Click({ Set-ActiveTab "Capture" })

$guideButton.Add_Click({
    $guideTldr = "Usage: Tracks a character across Front/Back or Left/Right camera panels in Maya and records the result via OBS -- a few clicks instead of manual setup each time."
    $guideSections = @(
        [PSCustomObject]@{
            Header = "SETTINGS (one-time or rarely-touched setup, its own tab)"
            Steps = @(
                @{ Lead = "Maya connection:"; Text = "green means ready. If red/gray, click the clipboard icon to copy the setup snippet, paste it into Maya's Script Editor (Python tab), and run it." },
                @{ Lead = "Cache button:"; Text = "click checks whether a cache already exists. If not, it asks permission to build one right there (10-16 minutes, one-time). Right-click for `"Force Rebuild`" if the character or animation changed without renaming its file, since a plain check can't tell that apart from an up-to-date cache." },
                @{ Lead = "OBS WebSocket password:"; Text = "in OBS Studio, go to Tools > WebSocket Server Settings, check `"Enable WebSocket Server`" if it isn't already, then click Show Connect Info to reveal the password. Click the key icon here and paste it in -- a one-time setup per machine." },
                @{ Lead = "Recording Monitor:"; Text = "which physical monitor OBS records, auto-detected from OBS's active scene. Only needs changing if you plug in a different monitor setup or switch machines." }
            )
        },
        [PSCustomObject]@{
            Header = "CAPTURE (what you use every run, its own tab)"
            Steps = @(
                @{ Lead = "Pick an Axis:"; Text = "Front/Back or Left/Right." },
                @{ Lead = "Pick a Time Range:"; Text = "All (full ROM video), Time Slider (Maya's current Range Slider), or Start/End (type exact frame numbers)." },
                @{ Lead = "Click Preview"; Text = "to check framing in Maya only, no recording." },
                @{ Lead = "Click Start Recording"; Text = "to also capture via OBS. While recording, click the same button again (it now reads Stop Recording) to interrupt it early." },
                @{ Lead = "Click Reset"; Text = "any time the tracked cameras or scene state look wrong, to clear everything and start fresh." }
            )
        }
    )
    Show-DarkGuide -Title "How to Use D4 ROM Capture" -Tldr $guideTldr -Sections $guideSections
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

$obsPasswordButton.Add_Click({
    $current = (Get-ObsPasswordStatus).CurrentPassword
    if ($current -eq "REPLACE_ME") { $current = "" }
    $obsPasswordSteps = "1. Open OBS Studio`n2. Tools > WebSocket Server Settings`n3. Check `"Enable WebSocket Server`" if it isn't already`n4. Click `"Show Connect Info`" to reveal the password (or set one if empty)`n5. Copy it and paste below`n`nEvery machine's OBS has its own independent password."
    $newPassword = Show-DarkInput -Title "OBS WebSocket Password" -ConfirmLabel "Save" -InitialValue $current -Message $obsPasswordSteps -Masked
    if ($newPassword -eq $null) {
        Write-Log "OBS password edit cancelled."
        return
    }
    $path = Get-ObsConfigFilePath
    $existing = if (Test-Path $path) { Get-Content $path -Raw } else { "" }
    Set-Content -Path $path -Value (Set-ObsConfigPassword -ExistingContent $existing -NewPassword $newPassword) -Encoding UTF8
    Update-ObsPasswordStatusIndicator
    Write-Log "OBS WebSocket password updated."
    # Design agreed 2026-08-22: saving the password is a deliberate "set
    # up OBS integration" moment -- launching OBS right here to detect
    # the real recording monitor is a natural continuation of what the
    # user is already doing, not a surprising side effect of an unrelated
    # action.
    Write-Log "Launching OBS to detect the recording monitor..."
    Update-MonitorList -EnsureRunning
})

$monitorRefreshButton.Add_Click({
    Set-ButtonsEnabled $false $null
    try {
        Write-Log "Launching OBS (if needed) to refresh the recording monitor..."
        Update-MonitorList -EnsureRunning
    } finally {
        Set-ButtonsEnabled $true
    }
})

$monitorComboBox.Add_SelectionChanged({
    if ($script:suppressMonitorSelectionChanged) { return }
    $index = $monitorComboBox.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:obsMonitorOptions.Count) { return }
    $selected = $script:obsMonitorOptions[$index]

    # Design agreed 2026-08-22: a user-initiated monitor change is a
    # deliberate action, not a side effect of scrolling the dropdown --
    # confirm before touching OBS's actual configuration at all. Reverts
    # the visual selection back to whatever was confirmed last on
    # Cancel, via the same suppress flag Update-MonitorList uses so this
    # revert doesn't re-trigger itself.
    $confirmed = Show-DarkConfirm -Title "Change Recording Monitor" -ConfirmLabel "Change" -Message "Change the recording monitor to `"$($selected.Name)`"?"
    if (-not $confirmed) {
        $script:suppressMonitorSelectionChanged = $true
        try {
            $monitorComboBox.SelectedIndex = $script:lastConfirmedMonitorIndex
        } finally {
            $script:suppressMonitorSelectionChanged = $false
        }
        return
    }

    # Written unconditionally, not just once verified below -- the camera
    # panels' own spawn location should follow what the user just
    # confirmed regardless of whether the separate OBS-side apply turns
    # out to actually produce a working image, since a mismatch there is
    # a different problem (surfaced in the result dialog) than "which
    # screen do the panels open on."
    Write-RecordingMonitorRect -MonitorName $selected.Name
    Write-RecordingMonitorName -MonitorName $selected.Name
    $result = Set-ObsMonitorSelection -MonitorId $selected.Value
    $script:lastConfirmedMonitorIndex = $index

    if (-not $result.Success) {
        Write-Log "Failed to set recording monitor: $($result.Message)"
        Show-DarkMonitorResult -Title "Recording Monitor" -Message "Could not change the recording monitor: $($result.Message)"
        return
    }
    # Real verified result, not a blind "done" -- see Show-DarkMonitorResult.
    Write-Log "Recording monitor set to: $($selected.Name) -- $($result.Message)"
    Show-DarkMonitorResult -Title "Recording Monitor" -Message "$($selected.Name): $($result.Message)" -PreviewPath $result.PreviewPath
})

$cacheActionButton.Add_Click({
    # Toggles into Stop while a build it started (via either path below)
    # is running -- same convention as Start Recording elsewhere in this
    # window, and the reason both the plain-click-found-Missing build and
    # the Force Rebuild menu item both pass $cacheActionButton itself as
    # Start-Steps' owning button, not some other control.
    if ($script:currentProcess -ne $null -and $script:activeButton -eq $cacheActionButton) {
        Stop-CurrentRun
        return
    }
    Update-CacheStatusIndicator
    # The "ask permission to build" behavior: a Missing result is offered
    # immediately, right here, instead of silently deferring to whatever
    # Preview/Start Recording would auto-build later on the Capture tab.
    # Exists deliberately stays silent -- see the Force Rebuild menu item
    # below for the explicit override.
    if ($script:lastCacheStatus -eq "Missing") {
        Confirm-AndBuildCache -DeleteExisting $false
    }
})

$forceRebuildMenuItem.Add_Click({
    if ($script:currentProcess -ne $null -and $script:activeButton -eq $cacheActionButton) {
        Stop-CurrentRun
        return
    }
    # Re-checks fresh first, same as a plain click -- never acts on
    # $script:lastCachePath/$script:lastAnimRef left over from whatever
    # the PREVIOUS check happened to find (e.g. a scene switched in Maya
    # since then). This is also what makes Force Rebuild meaningful on an
    # Exists result in the first place: the cache path is keyed off the
    # animation reference's file PATH only (see maya_check_cache.py's
    # cache_path_for), not its content, so a fresh Exists here can still
    # be genuinely stale if the artist edited the referenced file without
    # renaming it -- this is the deliberate override for exactly that.
    Update-CacheStatusIndicator
    if (-not $script:lastAnimRef) {
        Write-Log "No cache status known yet -- nothing to force-rebuild."
        return
    }
    Confirm-AndBuildCache -DeleteExisting ([bool]$script:lastCachePath)
})

function Invoke-ResetOnClose {
    # Cleans up tracked cameras/panels and resets the timeline so closing
    # the window doesn't leave Maya's scene in whatever half-set-up state
    # this session left it in. Fire-and-forget (Start-Process directly,
    # not through Start-Steps/the DispatcherTimer queue): the window is
    # about to close, so there is no UI left to show progress in, and no
    # reason to keep it open and waiting for Reset to finish first.
    #
    # Skipped entirely if something is still actively running -- e.g.
    # Start Recording mid-flight -- so this never races a live capture;
    # only a normal idle close triggers it.
    #
    # Pulled out into its own named function (rather than inline in
    # Add_Closing below) so it's unit-testable directly -- WPF's Closing
    # event does not reliably fire for a Window that was never actually
    # Shown, which is exactly the -NoShow test harness's own setup.
    if ($script:currentProcess -ne $null) {
        return
    }
    try {
        $resetSteps = Get-CleanResetStep -ScriptDir $ScriptDir
        foreach ($step in $resetSteps) {
            Start-Process -FilePath $step.FilePath -ArgumentList $step.Arguments -WindowStyle Hidden
        }
    } catch {
        # Best-effort cleanup -- never block the window from actually
        # closing over this.
    }
}

$window.Add_Closing({ Invoke-ResetOnClose })

function Write-StartupSummary([bool]$MayaReachable) {
    # Consolidates what the individual Settings-tab status checks already
    # found into the Logs box -- design agreed 2026-08-22: the user
    # shouldn't have to click into Settings (not even the default active
    # tab) just to learn what the tool needs before a capture will
    # actually work. The Logs box is visible under BOTH tabs (it's
    # outside the tab-switched content, see the shared Border wrapping
    # both), unlike the individual status rows themselves.
    #
    # Deliberately does NOT run a real cache check here -- that needs a
    # live Maya round-trip (a real send_to_maya.ps1 subprocess), and
    # Preview/Start Recording already auto-check/build it on demand; a
    # blocking cache probe on every single launch would slow startup for
    # information the user may not need yet. "Not checked yet" is an
    # honest reflection of the real state, not a placeholder.
    Write-Log "=== Startup Check ==="
    if ($MayaReachable) {
        Write-Log "Maya connection: OK (127.0.0.1:7001 reachable)"
    } else {
        Write-Log "Maya connection: NOT reachable -- paste open_maya_port.py into Maya's Script Editor (Python tab) and run it."
    }
    Write-Log "Cache: not checked yet -- click Cache (Settings tab), or it auto-checks on Preview/Start Recording."
    Write-Log $obsPasswordStatusLabel.Text
    Write-Log $monitorStatusLabel.Text
    Write-Log "======================"
}

$script:mayaReachableAtStartup = Update-PortStatusIndicator
$script:portCheckTimer.Start()
Update-ObsPasswordStatusIndicator
Update-MonitorList
Write-StartupSummary -MayaReachable $script:mayaReachableAtStartup
Set-ActiveTab "Capture"

if (-not $NoShow) {
    $window.ShowDialog() | Out-Null
}

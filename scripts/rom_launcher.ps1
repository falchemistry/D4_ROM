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
$script:ToolVersion = "1.0.1"

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="D4 ROM Capture" Width="420" Height="600" MinWidth="380" MinHeight="549"
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
        <!-- No x:Key, same as every other Style here: applies to every
             ScrollBar in the window implicitly, including the ones
             LogBox's own default TextBox template draws internally for
             VerticalScrollBarVisibility/HorizontalScrollBarVisibility
             (and Show-DarkGuide's ScrollViewer), without needing to
             separately restyle TextBox/ScrollViewer's own chrome. Thin,
             flat, no arrow buttons: matches the monochromatic redesign
             (no default Windows light-gray scrollbar chrome standing out
             against this window's dark background). -->
        <Style x:Key="RomScrollBarThumbStyle" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="ThumbBorder" Background="#FF5A5A5A" CornerRadius="3" Margin="1"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#FF6E6E6E"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#FF464646"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="MinWidth" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="{TemplateBinding Background}">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <!-- Opacity 0, not removed: still needs to exist and
                                         stay clickable so paging (clicking the track above/
                                         below the thumb) keeps working, it just shouldn't
                                         render as a visible arrow button. -->
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource RomScrollBarThumbStyle}"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="10"/>
                    <Setter Property="MinHeight" Value="10"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Grid Background="{TemplateBinding Background}">
                                    <Track x:Name="PART_Track" IsDirectionReversed="False">
                                        <Track.DecreaseRepeatButton>
                                            <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>
                                        </Track.DecreaseRepeatButton>
                                        <Track.IncreaseRepeatButton>
                                            <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>
                                        </Track.IncreaseRepeatButton>
                                        <Track.Thumb>
                                            <Thumb Style="{StaticResource RomScrollBarThumbStyle}"/>
                                        </Track.Thumb>
                                    </Track>
                                </Grid>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
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
                <RadioButton x:Name="LeftRightRadio" Content="Left / Right" Margin="0,0,16,0" GroupName="Axis"/>
                <RadioButton x:Name="AllAxisRadio" Content="All" GroupName="Axis"
                             ToolTip="Start Recording runs Front/Back, then Left/Right, back to back -- two separate video outputs from one click. Preview with All shows Front/Back only."/>
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
                <TextBox x:Name="StartFrameBox" Width="50" Text="0" Margin="0,0,10,0"
                         ToolTip="First frame to record. Up/Down arrows or the mouse wheel step by 1 (Shift = 10)."/>
                <TextBlock Text="End" VerticalAlignment="Center" Margin="0,0,4,0"/>
                <TextBox x:Name="EndFrameBox" Width="50" Text="100"
                         ToolTip="Last frame to record. Up/Down arrows or the mouse wheel step by 1 (Shift = 10)."/>
            </StackPanel>
            <TextBlock Text="Only applies to Start Recording -- Preview never records."
                       TextWrapping="Wrap" FontSize="10" Foreground="#FFA0A0A0" Margin="0,2,0,10"/>

            <!-- Frame Offsets (2026-09-02, renamed from "Frame Settings"):
                 groups every manual override on top of the automatic "safe"
                 framing (sized to always fit the animation's widest pose)
                 into one place: zoom and a pixel nudge for off-center
                 short-range captures. "Recenter at start frame" (the third
                 control that used to live here) is no longer a checkbox:
                 it's mandatory now, always applied by Preview/Start
                 Recording, since it just fixes a real mismatch (Maya's
                 current-time cursor vs. the capture range's actual Start)
                 rather than being an optional creative choice. -->
            <!-- Adjust section (task48 rebuild, 2026-10-12; user-approved mock 3a):
                 one "Adjust" header with the Reset icon at its right end, then
                 hairline-separated rows: Zoom / X, Y + arrow pad / Frame gate
                 toggle + Tolerance diagram with its number cap, and the
                 Estimated readout under it. Reset is DECLARED after Y although it
                 sits in the header, so Tab still goes Zoom box, slider, X, Y,
                 Reset, Frame gate, Tolerance; the diagram and the cap are plain
                 Borders, never Tab stops. Reset covers the whole section (Zoom/X/Y
                 0, Frame gate ON, Tolerance Auto). Live updates stay DEFERRED to
                 release / key-settle (2026-09-08, user feedback after trying
                 continuous live update: "it feels jumpy"): box and slider text
                 update instantly, the Maya push fires once input settles, via
                 $script:zoomSliderDragging / Stop-ZoomStep / Stop-OffsetWheelNudge
                 / the arrow pad's KeyUp. A single click or a typed commit is a
                 one-shot and applies at once. The Zoom box is editable, not just
                 the slider: typing an exact value goes through the SAME
                 Write-CameraZoomPct path as the slider (Commit-ZoomValueBox moves
                 the slider), so there is only one place that writes the file. -->
            <StackPanel x:Name="FrameOffsetsGrid" Grid.IsSharedSizeScope="True" Margin="0,0,0,10">
                <Grid x:Name="AdjustTopGrid">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto" SharedSizeGroup="AdjLabel"/>
                        <ColumnDefinition Width="*" MinWidth="44"/>
                        <ColumnDefinition Width="Auto" SharedSizeGroup="AdjUnit"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*" MinWidth="44"/>
                        <ColumnDefinition Width="Auto" SharedSizeGroup="AdjUnit"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="7" Text="Adjust" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,0,4"/>

                    <!-- Zoom -->
                    <TextBlock Grid.Row="1" Grid.Column="0" Text="Zoom" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBox Grid.Row="1" Grid.Column="1" x:Name="ZoomValueBox" Height="24" VerticalContentAlignment="Center" TextAlignment="Right"
                             ToolTip="Type an exact magnifier value from -50 to 50, then press Enter or click away to apply. 0 is the safe default sized to fit the widest pose. Up/Down arrows or the mouse wheel step by 10 (Shift = 100, Ctrl = 1); Maya follows once you stop."/>
                    <TextBlock Grid.Row="1" Grid.Column="2" Text="%" VerticalAlignment="Center" Margin="4,0,0,0"/>
                    <!-- SmallChange/LargeChange (task48): WPF's defaults (0.1 / 1)
                         are rounded away by the ValueChanged handler, so the
                         focused slider's own arrow / PageUp / PageDown keys
                         looked dead. 1 / 10 move whole percent, visibly. -->
                    <Slider Grid.Row="1" Grid.Column="3" Grid.ColumnSpan="5" x:Name="ZoomSlider" Minimum="-50" Maximum="50" Value="0" SmallChange="1" LargeChange="10"
                            TickFrequency="10" IsSnapToTickEnabled="False" VerticalAlignment="Center" Margin="12,0,0,0"
                            ToolTip="Adjusts the camera framing +/-50% around the safe default (0%), which is sized to always fit the animation's widest pose. Positive zooms in, negative zooms out for more headroom. Applies once you release the drag; type an exact value instead if you prefer instant apply. Up/Down arrows or the mouse wheel: 10 per step (Shift = 100, Ctrl = 1); Left/Right: 1."/>

                    <Border Grid.Row="2" Grid.ColumnSpan="8" Height="1" Background="#FF686868" Margin="0,5,0,5"/>

                    <!-- Offset X / Y, with the hover-gated arrow-nudge pad beside them
                         (24x24, same height as the boxes). Hovering the pad activates
                         all 4 arrow keys to nudge offset, X/Y boxes updating live,
                         without clicking into anything. -->
                    <TextBlock Grid.Row="3" Grid.Column="0" Text="X" FontWeight="Bold" Foreground="Red" VerticalAlignment="Center" Margin="0,0,6,0"
                               ToolTip="Horizontal pixel offset, +/- (positive moves the subject right on screen)."/>
                    <TextBox Grid.Row="3" Grid.Column="1" x:Name="OffsetXBox" Text="0" Height="24" TextAlignment="Right" VerticalContentAlignment="Center"
                             ToolTip="Type a horizontal pixel offset (Enter or click away to apply), or use the Up/Down arrows or the mouse wheel here: 10px per step, Shift = 100px, Ctrl = 1px -- applies once you stop."/>
                    <TextBlock Grid.Row="3" Grid.Column="2" Text="px" VerticalAlignment="Center" Margin="4,0,0,0"/>
                    <TextBlock Grid.Row="3" Grid.Column="3" Text="Y" FontWeight="Bold" Foreground="LimeGreen" VerticalAlignment="Center" Margin="12,0,6,0"
                               ToolTip="Vertical pixel offset, +/- (positive moves the subject up on screen)."/>
                    <TextBox Grid.Row="3" Grid.Column="4" x:Name="OffsetYBox" Text="0" Height="24" TextAlignment="Right" VerticalContentAlignment="Center"
                             ToolTip="Type a vertical pixel offset (Enter or click away to apply), or use the Up/Down arrows or the mouse wheel here: 10px per step, Shift = 100px, Ctrl = 1px -- applies once you stop."/>
                    <TextBlock Grid.Row="3" Grid.Column="5" Text="px" VerticalAlignment="Center" Margin="4,0,0,0"/>
                    <Border Grid.Row="3" Grid.Column="6" x:Name="ArrowNudgePad" Width="24" Height="24" Background="#FF3A3A3A" BorderBrush="#FF707070" BorderThickness="1" Margin="12,0,0,0"
                            ToolTip="Hover here, then use the arrow keys to nudge offset 10px at a time (Shift = 100px) -- X/Y update as you go, applied once you release the key. Type an exact value in the box for finer precision.">
                        <Path Data="M3,11 L19,11 M11,3 L11,19" Stroke="#FFA0A0A0" StrokeThickness="1"/>
                    </Border>

                    <!-- Reset (whole Adjust section) sits in the header, declared after Y for the Tab order. -->
                    <Button Grid.Row="0" Grid.Column="7" x:Name="ResetFrameOffsetsButton" Width="24" Height="24" Padding="0" Margin="8,0,0,4" HorizontalAlignment="Right" VerticalAlignment="Center"
                            AutomationProperties.Name="Reset Adjust section"
                            ToolTip="Reset the Adjust section: Zoom 0, X 0, Y 0, Frame gate back ON, Tolerance back to Auto. Applies immediately.">
                        <TextBlock Text="&#x21BA;" FontSize="14"/>
                    </Button>
                </Grid>

                <Border Height="1" Background="#FF686868" Margin="0,5,0,5"/>

                <Grid x:Name="AdjustGateGrid">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <!-- Frame gate: the same CheckBox, drawn as an icon-only toggle
                         (user decision 7a / ON-2): viewfinder brackets with a blue
                         box filling their interior; ON = dark pill, thin blue ring,
                         light brackets; OFF = dark pill, grey box, struck through.
                         Unchecked turns off only the automatic drift TRACKING
                         (frame-WIDTH sizing always stays), leaving the camera fixed
                         at the current framing. Default checked and reset to checked
                         every launch (the startup reset block near the end of this
                         file). Focusable, Space toggles, white ring on keyboard focus. -->
                    <CheckBox Grid.Row="0" Grid.Column="0" x:Name="FrameGateCheckBox" Content="" IsChecked="True" Height="24" VerticalAlignment="Center" HorizontalAlignment="Left"
                              FocusVisualStyle="{x:Null}" AutomationProperties.Name="Frame gate">
                        <CheckBox.Style>
                            <Style TargetType="CheckBox">
                                <Setter Property="ToolTip" Value="Frame gate is ON: the camera tracks the subject and nudges back small drift. Click (or press Space) to turn it OFF and keep the camera fixed at the current framing."/>
                                <Style.Triggers>
                                    <Trigger Property="IsChecked" Value="False">
                                        <Setter Property="ToolTip" Value="Frame gate is OFF: the camera stays fixed for the whole take at the current framing; watch the Preview glow and the Tolerance bar for clipping. Click (or press Space) to turn it ON."/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </CheckBox.Style>
                        <CheckBox.Template>
                            <ControlTemplate TargetType="CheckBox">
                                <Border x:Name="Pill" CornerRadius="3" Background="#FF1F1F1F" BorderBrush="#FF5A5A5A" BorderThickness="1" Padding="6,0,6,0" Height="24">
                                    <Canvas Width="16" Height="16" VerticalAlignment="Center">
                                        <Rectangle x:Name="GateFill" Canvas.Left="1" Canvas.Top="1" Width="14" Height="14" Fill="#FF5A5A5A"/>
                                        <Path x:Name="GateBrackets" Data="M1,5 L1,1 L5,1 M11,1 L15,1 L15,5 M15,11 L15,15 L11,15 M5,15 L1,15 L1,11" Stroke="#FFB4B4B4" StrokeThickness="1.7"
                                              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                                        <Path x:Name="GateSlash" Data="M3,13 L13,3" Stroke="#FFD0D0D0" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                    </Canvas>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsChecked" Value="True">
                                        <Setter TargetName="Pill" Property="BorderBrush" Value="#FF2F8CFF"/>
                                        <Setter TargetName="GateBrackets" Property="Stroke" Value="#FFE6E6E6"/>
                                        <Setter TargetName="GateFill" Property="Fill" Value="#FF2F8CFF"/>
                                        <Setter TargetName="GateSlash" Property="Visibility" Value="Collapsed"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="Pill" Property="BorderBrush" Value="#FFC8C8C8"/>
                                    </Trigger>
                                    <Trigger Property="IsKeyboardFocused" Value="True">
                                        <Setter TargetName="Pill" Property="BorderBrush" Value="#FFFFFFFF"/>
                                        <Setter TargetName="Pill" Property="BorderThickness" Value="2"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </CheckBox.Template>
                    </CheckBox>
                    <!-- Tolerance (user decisions 8a / 10b / W5): a display-only
                         diagram (TolVisualHost, drawn by Update-ToleranceVisual) and the
                         editable number in a cap at its right end. The number is the
                         same ToleranceValueBox as always (transparent, borderless inside
                         the bordered cap; "Auto" hides the %), so Up/Down, wheel, Enter,
                         LostFocus and typing are unchanged; clicking anywhere on the cap
                         focuses it. The wheel anywhere over this cell steps the number.
                         Blank/"Auto" (the default, reset every launch) keeps the
                         zoom-derived formula; a typed 0.0-20.0 fixes the slack. With the
                         gate OFF the SAME number is the clipping-warning threshold (Q4:
                         reuse), so it is deliberately NOT greyed out. -->
                    <Grid Grid.Row="0" Grid.Column="1" x:Name="ToleranceCell" Margin="10,0,0,0" HorizontalAlignment="Left" Width="284" Height="24">
                        <Border x:Name="TolVisualHost" HorizontalAlignment="Left" Width="226" Height="24" Background="#FF1C1C1C" BorderBrush="#FF4C4C4C" BorderThickness="1"/>
                        <Border x:Name="TolNumberCap" HorizontalAlignment="Right" Width="58" Height="24" Cursor="IBeam">
                            <Border.Style>
                                <Style TargetType="Border">
                                    <Setter Property="Background" Value="#FF1C1C1C"/>
                                    <Setter Property="BorderBrush" Value="#FF4C4C4C"/>
                                    <Setter Property="BorderThickness" Value="1"/>
                                    <Style.Triggers>
                                        <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                            <Setter Property="BorderBrush" Value="#FFFFFFFF"/>
                                            <Setter Property="BorderThickness" Value="2"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </Border.Style>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,6,0">
                                <TextBox x:Name="ToleranceValueBox" Width="32" Height="20" Background="Transparent" BorderThickness="0" Padding="0" TextAlignment="Right" VerticalContentAlignment="Center" Text="Auto"
                                         ToolTip="Tolerance, 0-20 percent of the frame width per side, or Auto (the zoom-derived value). Type a number and press Enter, clear the box to go back to Auto. Up/Down arrows or the mouse wheel step by 1 (Shift = 10, Ctrl = 0.1); from Auto they start at Auto's current value. With Frame gate OFF this same number is the clipping-warning threshold instead."/>
                                <TextBlock x:Name="TolPctSuffix" Text="%" Margin="2,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                    <!-- Estimated readout (2026-09-29, Q6; task48 rebuild): read-only,
                         gate ON only, for whichever tolerance is in effect, measured
                         over the frames the chosen Time Range would record
                         (Update-ToleranceReadout); a dash placeholder plus the reason
                         when there is nothing to measure yet. -->
                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="ToleranceReadoutText" Text="" FontSize="11" Foreground="Gray" TextWrapping="Wrap" Margin="10,2,0,0"
                               ToolTip="What the automatic guard is predicted to do at the current Zoom/Offset/Tolerance over the frames the chosen Time Range records -- keys written, percent of frames still over tolerance, and the worst single frame's overflow as a percent of the frame width."/>
                </Grid>
            </StackPanel>

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
                 HorizontalScrollBarVisibility="Disabled" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11"/>
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
$allAxisRadio = $window.FindName("AllAxisRadio")
$timeSliderRadio = $window.FindName("TimeSliderRadio")
$allFramesRadio = $window.FindName("AllFramesRadio")
$startEndRadio = $window.FindName("StartEndRadio")
$startEndPanel = $window.FindName("StartEndPanel")
$startFrameBox = $window.FindName("StartFrameBox")
$endFrameBox = $window.FindName("EndFrameBox")
$zoomSlider = $window.FindName("ZoomSlider")
$zoomValueBox = $window.FindName("ZoomValueBox")
$offsetXBox = $window.FindName("OffsetXBox")
$offsetYBox = $window.FindName("OffsetYBox")
$arrowNudgePad = $window.FindName("ArrowNudgePad")
$resetFrameOffsetsButton = $window.FindName("ResetFrameOffsetsButton")
$frameGateCheckBox = $window.FindName("FrameGateCheckBox")
$toleranceValueBox = $window.FindName("ToleranceValueBox")
$toleranceReadoutText = $window.FindName("ToleranceReadoutText")
$toleranceCell = $window.FindName("ToleranceCell")
$tolVisualHost = $window.FindName("TolVisualHost")
$tolNumberCap = $window.FindName("TolNumberCap")
$tolPctSuffix = $window.FindName("TolPctSuffix")
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
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit(6000) | Out-Null
    Write-NoteworthyMayaOutput "Cache check" $stdout

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
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit(6000) | Out-Null
    Write-NoteworthyMayaOutput "Time Slider range check" $stdout

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
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit(6000) | Out-Null
    Write-NoteworthyMayaOutput "Animation range check" $stdout

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
    $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    # Cache's step list is the same open-panels-and-key-cameras sequence
    # Preview uses -- appending the clean-reset step here mirrors what
    # Start Recording already does for itself (see its own handler:
    # "a completed recording should always end with a clean scene"). Cache
    # previously had no equivalent, so a cache build left Maya sitting in
    # "preview" state (floating tracked-camera panels, keyed cameras)
    # afterward, with nothing to clear it.
    $steps = @(Get-CaptureStepsForAxis -Axis $axis -Recording $false -ScriptDir $ScriptDir) + (Get-CleanResetStep -ScriptDir $ScriptDir)
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

function Show-DarkNotice {
    # Single-button ("OK") sibling of Show-DarkConfirm -- for messages that
    # only need acknowledgment, not a yes/no decision (e.g. the Start
    # Recording requirements gate: there's nothing to confirm, the run
    # just isn't starting until the listed items are fixed). Same dark
    # styling and overridable-top-level-function pattern so tests can stub
    # this instead of blocking on a real modal .ShowDialog() call.
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$ImagePath
    )
    [xml]$noticeXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" MinWidth="360" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <StackPanel Margin="16">
        <TextBlock x:Name="MessageText" TextWrapping="Wrap" Foreground="#FFE6E6E6" Margin="0,0,0,16"/>
        <Border x:Name="GuideImageBorder" BorderBrush="#FF4C4C4C" BorderThickness="1" Margin="0,0,0,12" Visibility="Collapsed">
            <Image x:Name="GuideImage" Stretch="Uniform" MaxHeight="260"/>
        </Border>
        <Button x:Name="OkButton" Content="OK" Width="90" Height="28" HorizontalAlignment="Right"
                Background="#FFE07868" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
    </StackPanel>
</Window>
"@
    $noticeReader = New-Object System.Xml.XmlNodeReader $noticeXaml
    $noticeWindow = [Windows.Markup.XamlReader]::Load($noticeReader)
    $noticeWindow.Title = $Title
    if ($window.IsVisible) {
        $noticeWindow.Owner = $window
    }
    $noticeWindow.FindName("MessageText").Text = $Message

    if ($ImagePath -and (Test-Path $ImagePath)) {
        # Same OnLoad-cached BitmapImage loading as Show-DarkInput/
        # Show-DarkMonitorResult's own guide images.
        $guideBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $guideBitmap.BeginInit()
        $guideBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $guideBitmap.UriSource = New-Object System.Uri($ImagePath)
        $guideBitmap.EndInit()
        $noticeWindow.FindName("GuideImage").Source = $guideBitmap
        $noticeWindow.FindName("GuideImageBorder").Visibility = [System.Windows.Visibility]::Visible
    }
    $noticeWindow.FindName("OkButton").Add_Click({ $noticeWindow.Close() }.GetNewClosure())
    $noticeWindow.ShowDialog() | Out-Null
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
        [switch]$Masked,
        [string]$ImagePath
    )
    [xml]$inputXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" MinWidth="360" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" Background="#FF3C3C3C">
    <StackPanel Margin="16">
        <TextBlock x:Name="MessageText" TextWrapping="Wrap" Foreground="#FFE6E6E6" Margin="0,0,0,10"/>
        <Border x:Name="GuideImageBorder" BorderBrush="#FF4C4C4C" BorderThickness="1" Margin="0,0,0,12" Visibility="Collapsed">
            <Image x:Name="GuideImage" Stretch="Uniform" MaxHeight="260"/>
        </Border>
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

    if ($ImagePath -and (Test-Path $ImagePath)) {
        # Same CacheOption OnLoad reasoning as Show-DarkMonitorResult's own
        # image loading -- reads the file into memory immediately and
        # releases the handle, so this dialog never holds the guide image
        # file locked open.
        $guideBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $guideBitmap.BeginInit()
        $guideBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $guideBitmap.UriSource = New-Object System.Uri($ImagePath)
        $guideBitmap.EndInit()
        $inputWindow.FindName("GuideImage").Source = $guideBitmap
        $inputWindow.FindName("GuideImageBorder").Visibility = [System.Windows.Visibility]::Visible
    }

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
    # Only ever shows what's knowable WITHOUT a network round-trip: gray
    # if no password is set at all. A configured password can no longer
    # promise green here by itself -- a typo'd password looks byte-for-
    # byte identical to a correct one until OBS actually authenticates
    # it, which is exactly what used to make this dot go green on a
    # WRONG password (user report: "it gives green indicator even though
    # we entered the wrong password... need to check whether the tools
    # can really access the obs before updating the green signal"). A
    # configured-but-unverified password gets the same amber used
    # elsewhere for "known but not yet confirmed working" (see
    # $script:cacheWarningBrush), not green. Real verification comes from
    # Update-ObsPasswordVerificationIndicator, called with the result of
    # an ACTUAL connect+identify handshake (Get-ObsMonitorList, already
    # run by Update-MonitorList -- no separate check invented here).
    $status = Get-ObsPasswordStatus
    if ($status.Configured) {
        $obsPasswordStatusDot.Fill = $script:cacheWarningBrush
        $obsPasswordStatusLabel.Text = "OBS WebSocket: password set, not yet verified"
    } else {
        $obsPasswordStatusDot.Fill = "Gray"
        $obsPasswordStatusLabel.Text = "OBS WebSocket: not configured"
    }
}

function Update-ObsPasswordVerificationIndicator($result) {
    # $result is a Get-ObsMonitorList return value -- this function adds
    # NO network call of its own, it just reinterprets a real
    # connect+identify handshake Update-MonitorList already ran for the
    # Recording Monitor dropdown's own sake. Skips updating anything if
    # no password is configured at all, so a stale check result from
    # before the password was ever set can't paint over
    # Update-ObsPasswordStatusIndicator's own "not configured" gray.
    if (-not (Get-ObsPasswordStatus).Configured) {
        return
    }
    if ($result.Success) {
        $obsPasswordStatusDot.Fill = "LimeGreen"
        $obsPasswordStatusLabel.Text = "OBS WebSocket: password verified"
    } elseif ($result.AuthFailed) {
        # Reachable, but authentication itself failed -- this IS a wrong
        # password, not ambiguous the way "OBS isn't running" is.
        $obsPasswordStatusDot.Fill = "Red"
        $obsPasswordStatusLabel.Text = "OBS WebSocket: password appears incorrect"
    } else {
        # Every other failure (OBS not running, no capture source, bad
        # host/port, etc) means the password genuinely CAN'T be verified
        # right now either way -- not the same claim as "confirmed wrong."
        $obsPasswordStatusDot.Fill = $script:cacheWarningBrush
        $obsPasswordStatusLabel.Text = "OBS WebSocket: can't verify (OBS not running)"
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

function Get-CameraZoomPctPath {
    # Own function, same reasoning as Get-RecordingMonitorRectPath -- lets
    # tests override just the path without touching real project state.
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_zoom_pct.txt"
}

function Write-CameraZoomPct([double]$Value) {
    # Read by get_zoom_pct() in maya_camera_panels.py/_LR.py -- see those
    # for the full explanation. Same plain-ASCII, no-BOM reasoning as
    # Write-RecordingMonitorRect above (a BOM makes Python's float() raise,
    # silently falling back to the 0% default with no visible error).
    $zoomPath = Get-CameraZoomPctPath
    $zoomDir = Split-Path $zoomPath -Parent
    if (-not (Test-Path $zoomDir)) {
        New-Item -ItemType Directory -Path $zoomDir | Out-Null
    }
    Set-Content -Path $zoomPath -Value "$Value" -Encoding ASCII
}

function Get-CameraOffsetPxPath {
    # Own function, same reasoning as Get-CameraZoomPctPath.
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_offset_px.txt"
}

function Write-CameraOffsetPx([double]$X, [double]$Y) {
    # Read by get_pixel_offset() in maya_camera_panels.py/_LR.py as a single
    # "X,Y" line -- same plain-ASCII, no-BOM reasoning as Write-CameraZoomPct.
    $offsetPath = Get-CameraOffsetPxPath
    $offsetDir = Split-Path $offsetPath -Parent
    if (-not (Test-Path $offsetDir)) {
        New-Item -ItemType Directory -Path $offsetDir | Out-Null
    }
    Set-Content -Path $offsetPath -Value "$X,$Y" -Encoding ASCII
}

function Get-FrameGatePath {
    # Own function, same reasoning as Get-CameraZoomPctPath -- lets tests
    # override just the path without touching real project state.
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_frame_gate.txt"
}

function Write-FrameGateEnabled([bool]$Enabled) {
    # Read by get_frame_gate_enabled() in maya_key_from_cache.py/_LR.py --
    # "1" (checked/ON) or "0" (unchecked/OFF). Same plain-ASCII, no-BOM
    # reasoning as Write-CameraZoomPct.
    $gatePath = Get-FrameGatePath
    $gateDir = Split-Path $gatePath -Parent
    if (-not (Test-Path $gateDir)) {
        New-Item -ItemType Directory -Path $gateDir | Out-Null
    }
    Set-Content -Path $gatePath -Value $(if ($Enabled) { "1" } else { "0" }) -Encoding ASCII
}

function Get-CameraTolerancePctPath {
    # Own function, same reasoning as Get-FrameGatePath -- lets tests
    # override just the path without touching real project state.
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_tolerance_pct.txt"
}

function Write-CameraTolerancePct {
    # Read by get_manual_tolerance_pct() in maya_camera_panels.py/_LR.py --
    # a plain number in percent, or an EMPTY file for Auto (today's zoom-
    # derived formula, unchanged). $null here means Auto; anything else is
    # written as a plain number, same plain-ASCII, no-BOM reasoning as
    # every other state file in this project. Not "Auto" as literal text --
    # empty is simpler for the Python side to treat as falsy with no string
    # comparison needed, same convention as _camera_recenter_start_frame.txt.
    param([Nullable[double]]$Value)
    $tolPath = Get-CameraTolerancePctPath
    $tolDir = Split-Path $tolPath -Parent
    if (-not (Test-Path $tolDir)) {
        New-Item -ItemType Directory -Path $tolDir | Out-Null
    }
    Set-Content -Path $tolPath -Value $(if ($null -eq $Value) { "" } else { [string]$Value }) -Encoding ASCII
}

function Read-CameraTolerancePct {
    # Mirror of get_manual_tolerance_pct() -- same "unknown/malformed
    # defaults to Auto ($null), never a guessed number" convention. Used by
    # Get-FrameGateEffectiveOverflowPct (the launcher's own independent
    # glow/prompt mirror) and by the Tolerance box's own startup restore.
    $tolPath = Get-CameraTolerancePctPath
    if (-not (Test-Path $tolPath)) { return $null }
    $content = Get-Content $tolPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $null }
    $content = $content.Trim()
    if ($content -eq '') { return $null }
    $value = 0.0
    if ([double]::TryParse($content, [ref]$value)) {
        return $value
    }
    return $null
}

# --- Live-apply plumbing (2026-09-08) --------------------------------
# The goal: touching ANY Frame Offsets control (drag, arrow-key, typed
# box, zoom slider) updates the live Maya camera immediately, with no
# Preview click and no panel reopen. Raw input events below only ever
# update the $script:pending* state -- they never call send_to_maya.ps1
# directly. $script:liveApplyTimer's tick is the ONLY place a bridge send
# actually fires, coalescing however many raw events happened since the
# last tick into at most one send -- without this, a fast drag would
# queue far more sends than a fresh-process-per-send bridge can keep up
# with, and they'd back up behind each other rather than reflecting the
# mouse in real time.
function Get-CameraNudgeDeltaPath {
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_nudge_delta.txt"
}
function Write-CameraNudgeDelta([double]$X, [double]$Y) {
    # Read by maya_camera_live_nudge.py as a single "dx,dy" line -- this is
    # a DELTA, not the running total (see that script's own docstring for
    # why: it lets every input method -- drag, arrow-key, typed commit --
    # share one Maya-side code path without that script needing to track
    # any state of its own).
    $path = Get-CameraNudgeDeltaPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -Path $path -Value "$X,$Y" -Encoding ASCII
}

$script:pendingNudgeDeltaX = 0.0
$script:pendingNudgeDeltaY = 0.0
$script:pendingZoomPush = $false
$script:liveApplyProcess = $null

function Send-CameraLiveScript([string]$ScriptName) {
    $sendToMaya = Join-Path $ScriptDir "send_to_maya.ps1"
    $target = Join-Path $ScriptDir $ScriptName
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$sendToMaya`" -ScriptPath `"$target`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:liveApplyProcess = [System.Diagnostics.Process]::Start($psi)
}

# Pulled out into its own named function (not left as an anonymous
# Add_Tick scriptblock) specifically so this is directly testable, same
# reasoning as Invoke-ResetOnClose being factored out of Window.Add_Closing.
function Invoke-LiveApplyTick {
    if ($script:liveApplyProcess -ne $null -and -not $script:liveApplyProcess.HasExited) {
        # A send is still in flight -- never overlap sends (Maya's command
        # port has no queueing of its own); whatever is pending now will
        # still be pending, and get picked up, on the next tick.
        return
    }
    if ($script:pendingZoomPush) {
        $script:pendingZoomPush = $false
        Send-CameraLiveScript "maya_camera_live_zoom.py"
        return
    }
    if ($script:pendingNudgeDeltaX -ne 0 -or $script:pendingNudgeDeltaY -ne 0) {
        Write-CameraNudgeDelta -X $script:pendingNudgeDeltaX -Y $script:pendingNudgeDeltaY
        $script:pendingNudgeDeltaX = 0.0
        $script:pendingNudgeDeltaY = 0.0
        Send-CameraLiveScript "maya_camera_live_nudge.py"
    }
}

# --- Frame-gate glow (2026-09-08) -------------------------------------
# Mirrors maya_camera_panels.py's compute_effective_overflow_pct entirely
# LOCALLY -- no Maya round-trip needed, since everything it depends on is
# already known here: max_w comes straight from the already-built cache
# JSON (same file $script:lastCachePath already points at), zoom/offset
# are the launcher's own live state, and panel width comes from the
# recording monitor rect already written to disk. EDGE_OVERFLOW_PCT/
# MARGIN_SAFETY are mirrored constants -- if the Python module constants
# ever change, these drift out of sync (same accepted risk this project
# already lives with for AUTO_MARGIN_AXIS/EDGE_OVERFLOW_PCT being
# duplicated across the Python files themselves).
$script:frameGateEdgeOverflowPct = 0.02
$script:frameGateMarginSafety = 1.02

function Get-FrameGateEffectiveOverflowPct {
    # Manual tolerance override (2026-09-29): a typed value in the
    # Tolerance box bypasses everything below, cache/rect lookups
    # included -- with a manual value the answer doesn't depend on any of
    # that. Mirrors compute_effective_overflow_pct's own bypass on the
    # Python side exactly: the override is an absolute number, so it stops
    # being offset-aware too once set, not a second, different rule from
    # the one the keyer itself now uses.
    $manualPct = Read-CameraTolerancePct
    if ($null -ne $manualPct) {
        return $manualPct / 100.0
    }

    # Returns $null when unknown (no cache yet) rather than a guessed
    # number -- callers must treat $null as "can't tell," not "safe."
    if (-not $script:lastCachePath -or -not (Test-Path $script:lastCachePath)) {
        return $null
    }
    try {
        $cacheJson = Get-Content $script:lastCachePath -Raw | ConvertFrom-Json
        $maxW = ($cacheJson.x_width | Measure-Object -Maximum).Maximum
    } catch {
        return $null
    }
    if (-not $maxW) { return $null }

    $rectPath = Get-RecordingMonitorRectPath
    if (-not (Test-Path $rectPath)) { return $null }
    $parts = (Get-Content $rectPath -Raw).Trim() -split ','
    if ($parts.Count -ne 4) { return $null }
    $monWidth = [double]$parts[2] - [double]$parts[0]
    $colWidth = [Math]::Floor($monWidth / 2.0)
    if ($colWidth -le 0) { return $null }

    $zoomPct = $zoomSlider.Value
    $offsetXPx = $script:lastValidOffsetX

    $neededOrtho = ($maxW / (1.0 - 2.0 * $script:frameGateEdgeOverflowPct)) * $script:frameGateMarginSafety
    $finalOrtho = $neededOrtho * (1.0 - $zoomPct / 100.0)
    if ($finalOrtho -le 0) { return 0.0 }
    $effective = (1.0 - ($maxW * $script:frameGateMarginSafety / $finalOrtho)) / 2.0
    $worldPerPx = $finalOrtho / $colWidth
    $offsetWorld = [Math]::Abs($offsetXPx) * $worldPerPx
    $effective -= $offsetWorld / $finalOrtho
    return [Math]::Max(0.0, $effective)
}

function New-FrameGateGlow([byte]$R, [byte]$G, [byte]$B) {
    $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $glow.Color = [System.Windows.Media.Color]::FromRgb($R, $G, $B)
    $glow.ShadowDepth = 0
    $glow.BlurRadius = 16
    $glow.Opacity = 0.9
    return $glow
}

# --- Frame-gate OFF clipping estimate (2026-09-28) --------------------
# When the checkbox is unchecked, edge_guard never runs at all -- there is
# no "effective overflow tolerance" to report the way Get-
# FrameGateEffectiveOverflowPct does for the ON path. Instead this answers
# a different question entirely: with the camera held perfectly still at
# its current framing, how much of the ALREADY-CACHED animation would
# clip? P = percent of (in-range) frames whose bbox exceeds the fixed
# frame on either edge; W = the worst single overflow, as a percent of
# the frame width. Deliberately its OWN function, not a branch bolted onto
# Get-FrameGateEffectiveOverflowPct -- that function's own hermetic tests
# hand-derive exact ON-path numbers and must stay byte-identical (Q-ON).
$script:cachedFrameArrays = $null   # memoized by path+mtime, see Get-CachedFrameArrays

function Get-CachedFrameArrays {
    # Parses the cache JSON's frames/x_center/x_width/z_center/z_width
    # arrays once and remembers them keyed on (path, LastWriteTimeUtc) --
    # Get-FrameGateEffectiveOverflowPct re-parses the whole cache on every
    # 60ms tick already (accepted, existing cost); this avoids ADDING a
    # second full re-parse of the same file for the new estimator on top
    # of that, per the tolerance-box proposal's own "cache the parsed
    # arrays by path + mtime first" guidance (applies equally here).
    #
    # IMPORTANT (found via live prototyping against the real barM cache
    # before writing this): Windows PowerShell 5.1's ConvertFrom-Json
    # deserializes JSON numbers as [System.Decimal], not [double].
    # [Array]::IndexOf(a Decimal array, [double]3079) silently returns -1
    # even when 3079.0 IS present, because boxed Decimal.Equals(boxed
    # Double) is false across the mismatched types -- confirmed live, this
    # is not a hypothetical. Casting to [double[]] immediately below is
    # what makes frame-index lookups (and all downstream arithmetic) work
    # correctly, matching the Python side's plain floats.
    if (-not $script:lastCachePath -or -not (Test-Path $script:lastCachePath)) { return $null }
    $mtime = (Get-Item $script:lastCachePath).LastWriteTimeUtc
    if ($script:cachedFrameArrays -ne $null -and $script:cachedFrameArrays.Path -eq $script:lastCachePath -and $script:cachedFrameArrays.MTime -eq $mtime) {
        return $script:cachedFrameArrays
    }
    try {
        $cacheJson = Get-Content $script:lastCachePath -Raw | ConvertFrom-Json
        [double[]]$frames = @($cacheJson.frames)
        [double[]]$xCenter = @($cacheJson.x_center)
        [double[]]$xWidth = @($cacheJson.x_width)
        [double[]]$zCenter = @($cacheJson.z_center)
        [double[]]$zWidth = @($cacheJson.z_width)
    } catch {
        return $null
    }
    if ($frames.Count -eq 0) { return $null }
    $script:cachedFrameArrays = [PSCustomObject]@{
        Path = $script:lastCachePath; MTime = $mtime
        Frames = $frames; XCenter = $xCenter; XWidth = $xWidth; ZCenter = $zCenter; ZWidth = $zWidth
    }
    return $script:cachedFrameArrays
}

function Get-NearestFrameIndex([double[]]$Frames, [double]$TargetFrame) {
    # Nearest match, not an exact-or-fail lookup -- a typed Start/End (or a
    # resolved Time-Slider/All range) need not land exactly on a cached
    # sample. Linear scan: cache arrays are a few thousand elements, called
    # at most twice per estimate (Start and End), nowhere near the 60ms
    # budget's actual cost driver (the JSON parse, already memoized above).
    $bestIdx = 0
    $bestDiff = [double]::MaxValue
    for ($i = 0; $i -lt $Frames.Count; $i++) {
        $diff = [Math]::Abs($Frames[$i] - $TargetFrame)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $bestIdx = $i }
    }
    return $bestIdx
}

function Get-ClippingEstimateCore {
    # Pure math, no file I/O, no WPF -- directly hand-verifiable and unit
    # testable on synthetic arrays. Mirrors key_edge_guard's own
    # allowed_left/allowed_right math in maya_key_from_cache.py MINUS any
    # overflow cushion: gate OFF means the camera never reacts at all, so
    # the tolerance is exactly zero by construction, not just a small one.
    # Single-axis only (X slot) -- the caller runs this ONCE PER AXIS PAIR
    # (Front/Back, then Left/Right) and picks whichever pair is worse; see
    # Get-ClippingEstimate's own comment for why "All" is resolved that way
    # rather than folding both axes into one per-frame pass (which would
    # mix a P from one camera with a W from the other on frames where
    # neither single camera actually clips that badly).
    param(
        [Parameter(Mandatory=$true)][double[]]$CenterX,
        [Parameter(Mandatory=$true)][double[]]$WidthX,
        [Parameter(Mandatory=$true)][double]$CamPosX,
        [Parameter(Mandatory=$true)][double]$HalfOrtho,
        [Parameter(Mandatory=$true)][int]$StartIndex,
        [Parameter(Mandatory=$true)][int]$EndIndex
    )
    $total = $EndIndex - $StartIndex + 1
    if ($total -le 0) { return [PSCustomObject]@{ PercentClipped = 0.0; WorstOverflowPct = 0.0 } }
    $clipped = 0
    $worst = 0.0
    # task48 fix round: a frame only counts as clipped past a tiny relative
    # epsilon (1e-9 x the frame width), so floating-point noise at exactly
    # the frame edge is not counted; the worst value is tracked as before.
    $noise = 1e-9 * 2.0 * $HalfOrtho
    for ($i = $StartIndex; $i -le $EndIndex; $i++) {
        $halfX = $WidthX[$i] / 2.0
        $ov = [Math]::Max(($CamPosX - $HalfOrtho) - ($CenterX[$i] - $halfX), ($CenterX[$i] + $halfX) - ($CamPosX + $HalfOrtho))
        if ($ov -gt 0 -and $ov -gt $worst) { $worst = $ov }
        if ($ov -gt $noise) { $clipped++ }
    }
    $frameWidth = 2.0 * $HalfOrtho
    return [PSCustomObject]@{
        PercentClipped = (100.0 * $clipped / $total)
        WorstOverflowPct = (100.0 * $worst / $frameWidth)
    }
}

function Get-ClippingEstimate {
    # Returns $null when unknown (no cache yet), same "don't guess"
    # convention as Get-FrameGateEffectiveOverflowPct. $RangeStart/$RangeEnd
    # $null (both) means the whole cached take, reference frame = the
    # cache's own first frame -- used by the live glow tick (Q-rng: no Maya
    # round trip on every 60ms tick). Non-null means a RESOLVED capture
    # range (Start Recording's click-time prompt), reference frame = that
    # range's own Start -- matches where maya_camera_panels.py's
    # frame_camera() actually parks the camera when Recenter-at-start-frame
    # is mandatory (it always is now).
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")]
        [string]$Axis,
        [Parameter(Mandatory=$true)][double]$ZoomPct,
        [Parameter(Mandatory=$true)][double]$OffsetXPx,
        [Nullable[int]]$RangeStart = $null,
        [Nullable[int]]$RangeEnd = $null
    )
    $arrays = Get-CachedFrameArrays
    if ($arrays -eq $null) { return $null }
    $maxW = ($arrays.XWidth | Measure-Object -Maximum).Maximum
    if (-not $maxW) { return $null }

    $rectPath = Get-RecordingMonitorRectPath
    if (-not (Test-Path $rectPath)) { return $null }
    $parts = (Get-Content $rectPath -Raw).Trim() -split ','
    if ($parts.Count -ne 4) { return $null }
    $monWidth = [double]$parts[2] - [double]$parts[0]
    $colWidth = [Math]::Floor($monWidth / 2.0)
    if ($colWidth -le 0) { return $null }

    $neededOrtho = ($maxW / (1.0 - 2.0 * $script:frameGateEdgeOverflowPct)) * $script:frameGateMarginSafety
    $finalOrtho = $neededOrtho * (1.0 - $ZoomPct / 100.0)
    if ($finalOrtho -le 0) {
        # Same "no tolerance value can fix this" floor as Get-FrameGate
        # EffectiveOverflowPct -- past a large enough zoom-in the frame
        # itself has collapsed, so every in-range frame clips completely.
        return [PSCustomObject]@{ PercentClipped = 100.0; WorstOverflowPct = 100.0 }
    }
    $halfOrtho = $finalOrtho / 2.0
    $worldPerPx = $finalOrtho / $colWidth
    $offsetWorld = $OffsetXPx * $worldPerPx

    $frames = $arrays.Frames
    $startIdx = 0
    $endIdx = $frames.Count - 1
    if ($RangeStart -ne $null) { $startIdx = Get-NearestFrameIndex -Frames $frames -TargetFrame ([double]$RangeStart) }
    if ($RangeEnd -ne $null) { $endIdx = Get-NearestFrameIndex -Frames $frames -TargetFrame ([double]$RangeEnd) }
    if ($endIdx -lt $startIdx) { return $null }
    $refIdx = $startIdx

    $camPosX = $arrays.XCenter[$refIdx] - $offsetWorld
    $camPosZ = $arrays.ZCenter[$refIdx] - $offsetWorld

    if ($Axis -eq "LeftRight") {
        # Z-only pass -- reuse the same core with the Z arrays fed into the
        # X slot (the math is axis-symmetric: center/half-width in,
        # overflow out) rather than adding a third code path.
        return Get-ClippingEstimateCore -CenterX $arrays.ZCenter -WidthX $arrays.ZWidth `
            -CamPosX $camPosZ -HalfOrtho $halfOrtho -StartIndex $startIdx -EndIndex $endIdx
    }
    if ($Axis -eq "FrontBack") {
        return Get-ClippingEstimateCore -CenterX $arrays.XCenter -WidthX $arrays.XWidth `
            -CamPosX $camPosX -HalfOrtho $halfOrtho -StartIndex $startIdx -EndIndex $endIdx
    }

    # "All": run Front/Back and Left/Right independently, then report the
    # ONE axis pair with the larger worst-overflow (W) together with ITS
    # OWN P -- NOT a per-frame max/OR across both axes, which would mix a P
    # from one camera with a W from the other on frames where neither
    # single camera actually clips that badly (e.g. P=50%/W=20% when no
    # real camera ever hits both at once). This matches this project's own
    # rule that worst-overflow alone drives severity (Q-thr: "worst
    # overflow alone decides") and was verified live to reproduce the
    # proposal's Front/Back-vs-Left/Right addendum table exactly.
    $fb = Get-ClippingEstimateCore -CenterX $arrays.XCenter -WidthX $arrays.XWidth `
        -CamPosX $camPosX -HalfOrtho $halfOrtho -StartIndex $startIdx -EndIndex $endIdx
    $lr = Get-ClippingEstimateCore -CenterX $arrays.ZCenter -WidthX $arrays.ZWidth `
        -CamPosX $camPosZ -HalfOrtho $halfOrtho -StartIndex $startIdx -EndIndex $endIdx
    if ($lr.WorstOverflowPct -gt $fb.WorstOverflowPct) { return $lr }
    return $fb
}

function Get-EdgeGuardCurveEstimateCore {
    # Pure math, no file I/O, no WPF -- PowerShell port of compute_edge_
    # guard_curve (maya_key_from_cache.py/_LR.py), the G+B tracking
    # algorithm, for the ON-mode live readout (2026-09-29, Part 3 step 3).
    # T72 item 6 (2026-10-20): the gate follows the frame the artist SEES.
    # The walk is seeded at the cached centre minus OffsetShift and every
    # decision compares the pose with THAT visible camera -- exactly like
    # compute_edge_guard_curve(..., offset_shift) in maya_key_from_cache.py
    # /_LR.py, whose values the keyer writes as they are. Nothing is
    # subtracted afterwards any more (the old [G] form built the walk
    # offset-free and post-shifted it, so the real gate sat one Offset
    # away from the visible frame). OffsetShift 0 is the old walk.
    # [B] hold instead of correct when a pose cannot fit within Overflow
    # regardless of camera position. The tolerance itself stays zoom-only.
    # Single pass: tracks cam_pos exactly like the real loop, storing it at
    # every frame (piecewise-constant between corrections, same semantics
    # as key_edge_guard's own loop) so the frames-over-tolerance/worst-
    # overflow measurement below reads the ACTUAL held position at every
    # frame, not just at correction points -- equivalent to the persisted
    # Python tests' separate reconstruction pass, done inline in one pass.
    param(
        [Parameter(Mandatory=$true)][double[]]$CenterX,
        [Parameter(Mandatory=$true)][double[]]$WidthX,
        [Parameter(Mandatory=$true)][double]$HalfOrtho,
        [Parameter(Mandatory=$true)][double]$Overflow,
        [Parameter(Mandatory=$true)][double]$OffsetShift,
        [Parameter(Mandatory=$true)][int]$StartIndex,
        [Parameter(Mandatory=$true)][int]$EndIndex,
        # task48 rebuild (time range), T72 Option B (2026-10-14): keys / frames
        # over tolerance / worst are MEASURED over MeasureStart..MeasureEnd --
        # the frames the chosen Time Range records. The walk is SEEDED at the
        # first measured frame (the recording's Start) at the cached centre
        # there and simulated from it to EndIndex, exactly like the keyer
        # (maya_key_from_cache.py key_edge_guard: seed_series_at_start, the
        # walk starts at the capture's start frame from the live centre; the
        # old apply_recenter_override notch is gone). Frames before the seed
        # are not simulated. Omitted = the whole span seeded at StartIndex
        # (the pre-rebuild behaviour, byte-identical). Keys = the guard keys
        # (the seed included) whose frame lies in the measured span.
        [Nullable[int]]$MeasureStartIndex = $null,
        [Nullable[int]]$MeasureEndIndex = $null
    )
    $total = $EndIndex - $StartIndex + 1
    if ($total -le 0) { return [PSCustomObject]@{ Keys = 0; PercentOverTolerance = 0.0; WorstOverflowPct = 0.0 } }
    $measureStart = if ($null -ne $MeasureStartIndex) { [Math]::Max($StartIndex, [int]$MeasureStartIndex) } else { $StartIndex }
    $measureEnd = if ($null -ne $MeasureEndIndex) { [Math]::Min($EndIndex, [int]$MeasureEndIndex) } else { $EndIndex }
    if ($measureEnd -lt $measureStart) { return [PSCustomObject]@{ Keys = 0; PercentOverTolerance = 0.0; WorstOverflowPct = 0.0 } }

    $seedIndex = $measureStart
    $camPos = $CenterX[$seedIndex] - $OffsetShift
    $keys = 1
    $lastKeyedIndex = $seedIndex
    $keyedIndices = New-Object 'System.Collections.Generic.List[int]'
    $keyedIndices.Add($seedIndex)
    [double[]]$camPosAt = New-Object 'double[]' ($EndIndex - $seedIndex + 1)
    $camPosAt[0] = $camPos

    for ($i = $seedIndex + 1; $i -le $EndIndex; $i++) {
        $halfW = $WidthX[$i] / 2.0
        if ($halfW -le ($HalfOrtho + $Overflow)) {
            $leftEdge = $CenterX[$i] - $halfW
            $rightEdge = $CenterX[$i] + $halfW
            $allowedLeft = $camPos - $HalfOrtho - $Overflow
            $allowedRight = $camPos + $HalfOrtho + $Overflow
            if ($leftEdge -lt $allowedLeft) {
                $camPos = $leftEdge + $HalfOrtho + $Overflow
                $keys++
                $lastKeyedIndex = $i
                $keyedIndices.Add($i)
            } elseif ($rightEdge -gt $allowedRight) {
                $camPos = $rightEdge - $HalfOrtho - $Overflow
                $keys++
                $lastKeyedIndex = $i
                $keyedIndices.Add($i)
            }
            # else: within tolerance already, cam_pos unchanged, no new key.
        }
        # else: [B] hold -- pose cannot fit even at full tolerance.
        $camPosAt[$i - $seedIndex] = $camPos
    }
    if ($lastKeyedIndex -ne $EndIndex) { $keys++; $keyedIndices.Add($EndIndex) }
    if ($measureEnd -ne $EndIndex) {
        $keys = 0
        foreach ($k in $keyedIndices) { if ($k -ge $measureStart -and $k -le $measureEnd) { $keys++ } }
    }

    $overCount = 0
    $worst = 0.0
    $frameWidth = 2.0 * $HalfOrtho
    $total = $measureEnd - $measureStart + 1
    for ($i = $measureStart; $i -le $measureEnd; $i++) {
        $halfW2 = $WidthX[$i] / 2.0
        $heldCamPos = $camPosAt[$i - $seedIndex]
        # the walk already runs in the visible frame (T72 item 6): no post-shift
        $ov = [Math]::Max(($heldCamPos - $HalfOrtho) - ($CenterX[$i] - $halfW2), ($CenterX[$i] + $halfW2) - ($heldCamPos + $HalfOrtho))
        # "Over tolerance" means the raw overflow (beyond the plain HalfOrtho
        # edge) EXCEEDS the tolerance cushion itself (Overflow, already in
        # the SAME raw world units as $ov) -- NOT "any overflow at all".
        # Bug caught live (2026-09-29): comparing against a hardcoded 0
        # instead of $Overflow is only correct when Overflow==0 (T=0), which
        # is exactly why it silently passed there and only surfaced as a
        # wrong number once a nonzero T (5%) was checked against the real
        # replica table. "Worst" is still tracked unconditionally (any
        # positive ov can be the worst, whether or not it individually
        # exceeds the cushion) -- only the COUNT needed the T-relative check.
        if ($ov -gt 0 -and $ov -gt $worst) { $worst = $ov }
        # task48 fix round: the guard parks an edge EXACTLY at the limit, so
        # "over" needs a tiny relative epsilon (1e-9 x the frame width) or
        # floating-point noise at the limit counts as over (zoom 0 Auto read
        # 2.1% over while nothing actually passed it).
        if ($ov -gt $Overflow + 1e-9 * $frameWidth) {
            $overCount++
        }
    }

    return [PSCustomObject]@{
        Keys = $keys
        PercentOverTolerance = (100.0 * $overCount / $total)
        WorstOverflowPct = (100.0 * $worst / $frameWidth)
    }
}

function Get-ToleranceReadoutEstimate {
    # Live "Estimated: N keys, X% of frames over tolerance, worst Y% of
    # frame width" readout (2026-09-29, Part 3 step 3, Q6: recommended and
    # included). ON-mode only -- this simulates the G+B guard itself, which
    # only runs while Frame gate is ON; callers branch on the checkbox the
    # same way Update-FrameGateGlow already does. The guard is simulated
    # from the capture's start frame to the end of the cached take (T72
    # Option B: the keyer seeds its walk at the start frame, see
    # Get-EdgeGuardCurveEstimateCore); task48 rebuild: the numbers are
    # MEASURED over -MeasureStartIndex..-MeasureEndIndex, the cached frames
    # the chosen Time Range records (Get-EstimateRange). Omitted = the whole
    # take, as before.
    param(
        [Parameter(Mandatory=$true)][ValidateSet("FrontBack", "LeftRight", "All")]
        [string]$Axis,
        [Parameter(Mandatory=$true)][double]$ZoomPct,
        [Parameter(Mandatory=$true)][double]$OffsetXPx,
        [Nullable[double]]$ManualTolerancePct = $null,
        [Nullable[int]]$MeasureStartIndex = $null,
        [Nullable[int]]$MeasureEndIndex = $null
    )
    $arrays = Get-CachedFrameArrays
    if ($arrays -eq $null) { return $null }
    $maxW = ($arrays.XWidth | Measure-Object -Maximum).Maximum
    if (-not $maxW) { return $null }

    $rectPath = Get-RecordingMonitorRectPath
    if (-not (Test-Path $rectPath)) { return $null }
    $parts = (Get-Content $rectPath -Raw).Trim() -split ','
    if ($parts.Count -ne 4) { return $null }
    $monWidth = [double]$parts[2] - [double]$parts[0]
    $colWidth = [Math]::Floor($monWidth / 2.0)
    if ($colWidth -le 0) { return $null }

    $neededOrtho = ($maxW / (1.0 - 2.0 * $script:frameGateEdgeOverflowPct)) * $script:frameGateMarginSafety
    $finalOrtho = $neededOrtho * (1.0 - $ZoomPct / 100.0)
    if ($finalOrtho -le 0) {
        return [PSCustomObject]@{ Keys = 0; PercentOverTolerance = 100.0; WorstOverflowPct = 100.0 }
    }
    $halfOrtho = $finalOrtho / 2.0
    $worldPerPx = $finalOrtho / $colWidth
    $offsetShift = $OffsetXPx * $worldPerPx

    if ($null -ne $ManualTolerancePct) {
        # M1 override: bypasses the zoom-derived formula and its zero floor
        # entirely -- mirrors compute_effective_overflow_pct's own manual_pct
        # branch exactly (Python side).
        $overflowPct = $ManualTolerancePct / 100.0
    } else {
        # Auto: zoom-only (no offset term) -- matches the REAL value the
        # keyer actually reads today (offset_x_px=0.0 always passed at the
        # real write site, part of G), not the launcher's OWN separately-
        # offset-aware glow mirror (Get-FrameGateEffectiveOverflowPct,
        # deliberately different, Q-ON).
        $overflowPct = (1.0 - ($maxW * $script:frameGateMarginSafety / $finalOrtho)) / 2.0
        $overflowPct = [Math]::Max(0.0, $overflowPct)
    }
    $overflow = $overflowPct * $finalOrtho

    $frames = $arrays.Frames
    $startIdx = 0
    $endIdx = $frames.Count - 1

    $mStart = $MeasureStartIndex
    $mEnd = $MeasureEndIndex

    if ($Axis -eq "LeftRight") {
        return Get-EdgeGuardCurveEstimateCore -CenterX $arrays.ZCenter -WidthX $arrays.ZWidth `
            -HalfOrtho $halfOrtho -Overflow $overflow -OffsetShift $offsetShift -StartIndex $startIdx -EndIndex $endIdx -MeasureStartIndex $mStart -MeasureEndIndex $mEnd
    }
    if ($Axis -eq "FrontBack") {
        return Get-EdgeGuardCurveEstimateCore -CenterX $arrays.XCenter -WidthX $arrays.XWidth `
            -HalfOrtho $halfOrtho -Overflow $overflow -OffsetShift $offsetShift -StartIndex $startIdx -EndIndex $endIdx -MeasureStartIndex $mStart -MeasureEndIndex $mEnd
    }
    # "All": same "independent per axis, report the worse W with its own P"
    # rule as Get-ClippingEstimate, for the same reason (never mix a P from
    # one camera with a W from the other).
    $fb = Get-EdgeGuardCurveEstimateCore -CenterX $arrays.XCenter -WidthX $arrays.XWidth `
        -HalfOrtho $halfOrtho -Overflow $overflow -OffsetShift $offsetShift -StartIndex $startIdx -EndIndex $endIdx -MeasureStartIndex $mStart -MeasureEndIndex $mEnd
    $lr = Get-EdgeGuardCurveEstimateCore -CenterX $arrays.ZCenter -WidthX $arrays.ZWidth `
        -HalfOrtho $halfOrtho -Overflow $overflow -OffsetShift $offsetShift -StartIndex $startIdx -EndIndex $endIdx -MeasureStartIndex $mStart -MeasureEndIndex $mEnd
    if ($lr.WorstOverflowPct -gt $fb.WorstOverflowPct) { return $lr }
    return $fb
}

function Get-ClippingWarningThresholdPct {
    # Gate-OFF clipping-warning threshold (2026-09-29, Part 3, Q4:
    # RECOMMENDED answer was "reuse"). With the gate OFF, the Tolerance box
    # has nothing to override (there is no automatic guard running at all --
    # see key_edge_guard's own OFF branch), so the SAME number instead
    # becomes "how much overflow I accept before the warning escalates from
    # amber to red" -- one number, two meanings depending on the checkbox,
    # exactly as the approved design describes it. Auto (Tolerance box
    # empty) keeps the pre-existing hardcoded 2% default, unchanged.
    $manualPct = Read-CameraTolerancePct
    if ($null -ne $manualPct) { return $manualPct }
    return 2.0
}

function Update-FrameGateGlow {
    # Cheap enough to call unconditionally every tick (see
    # Invoke-LiveApplyTick) -- pure local math + two small file reads, no
    # Maya round-trip, so the glow tracks zoom/offset live as they change.
    if ($frameGateCheckBox.IsChecked) {
        $effective = Get-FrameGateEffectiveOverflowPct
        if ($effective -eq $null) {
            $previewButton.Effect = $null
        } elseif ($effective -le 1e-6) {
            $previewButton.Effect = New-FrameGateGlow -R 224 -G 120 -B 110   # same red as Stop Recording
        } elseif ($effective -lt ($script:frameGateEdgeOverflowPct * 0.5)) {
            $previewButton.Effect = New-FrameGateGlow -R 239 -G 192 -B 84    # same amber as the cache warning dot
        } else {
            $previewButton.Effect = $null
        }
        $previewButton.ToolTip = "Opens the tracked camera panels and keys them from cache, in the Maya viewport only -- no OBS recording."
        return
    }

    # Gate OFF: glow/tooltip switch from the zero-margin test to the
    # clipping estimate (Q-thr, approved as proposed): 0% -> no glow;
    # 0% < W <= threshold -> amber; W > threshold -> red. Threshold is 2%
    # by default, or the manual Tolerance value if one is set (Q4: reuse,
    # see Get-ClippingWarningThresholdPct). P never gates the glow color,
    # only feeds the wording -- same "worst overflow alone decides" rule
    # Get-ClippingEstimate's own "All" resolution follows.
    # task48 rebuild: over the frames the chosen Time Range records (same
    # range as the Tolerance bar); a range the launcher cannot know yet falls
    # back to the whole cached take, as before, so the warning is never lost.
    $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $estimateRange = Get-CurrentEstimateRange
    if ($estimateRange.Known) {
        $estimate = Get-GateOffRangeEstimate $estimateRange
    } else {
        $estimate = Get-ClippingEstimate -Axis $axis -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX
    }
    $threshold = Get-ClippingWarningThresholdPct
    if ($estimate -eq $null) {
        $previewButton.Effect = $null
        $previewButton.ToolTip = "Opens the tracked camera panels and keys them from cache, in the Maya viewport only -- no OBS recording."
    } elseif ($estimate.WorstOverflowPct -le 1e-6) {
        $previewButton.Effect = $null
        $previewButton.ToolTip = "Opens the tracked camera panels and keys them from cache, in the Maya viewport only -- no OBS recording."
    } else {
        $pRounded = [Math]::Round($estimate.PercentClipped, 1)
        $wRounded = [Math]::Round($estimate.WorstOverflowPct, 1)
        if ($estimate.WorstOverflowPct -le $threshold) {
            $previewButton.Effect = New-FrameGateGlow -R 239 -G 192 -B 84    # amber
        } else {
            $previewButton.Effect = New-FrameGateGlow -R 224 -G 120 -B 110  # red
        }
        $previewButton.ToolTip = "Frame gate OFF -- estimated clipping: $pRounded% of frames, worst $wRounded% of frame width."
    }
}

function Update-ToleranceReadout {
    # Live "Estimated: N keys, X% of frames over tolerance, worst Y% of
    # frame width" (2026-09-29, Part 3 step 3, Q6). ON-mode only -- this
    # simulates the G+B guard itself, which only runs while Frame gate is
    # ON; the text is cleared while OFF, same "never leave a forgotten value
    # visible" discipline as every other Adjust control.
    # task48 rebuild: measured over the frames the chosen Time Range records
    # (Get-CurrentEstimateRange); nothing to measure -> "Estimated: --" with
    # the reason. The worst value is also kept as a NUMBER
    # ($script:lastEstimateWorstPct, $null when unknown) for the Tolerance
    # bar; with the gate OFF it is the fixed-camera clipping estimate over the
    # same range instead (the bar's red "over" part = the glow's red).
    $range = Get-CurrentEstimateRange
    $script:lastEstimateRange = $range
    if (-not $frameGateCheckBox.IsChecked) {
        $toleranceReadoutText.Text = ""
        $offEstimate = if ($range.Known) { Get-GateOffRangeEstimate $range } else { $null }
        $script:lastEstimateWorstPct = if ($null -ne $offEstimate) { [double]$offEstimate.WorstOverflowPct } else { $null }
        Update-ToleranceVisual
        return
    }
    $estimate = $null
    if ($range.Known) {
        $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
        $manualPct = Read-CameraTolerancePct
        $estimate = Invoke-EstimateMemo "readout" "$axis|$($zoomSlider.Value)|$($script:lastValidOffsetX)|$manualPct|$($range.StartIndex)|$($range.EndIndex)" {
            Get-ToleranceReadoutEstimate -Axis $axis -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -ManualTolerancePct $manualPct `
                -MeasureStartIndex $range.StartIndex -MeasureEndIndex $range.EndIndex
        }
    }
    if ($estimate -eq $null) {
        $script:lastEstimateWorstPct = $null
        $toleranceReadoutText.Text = Get-EstimatePendingText -Reason $range.Reason
    } else {
        $script:lastEstimateWorstPct = [double]$estimate.WorstOverflowPct
        # One rounding rule with the bar (Format-EstimateReadoutText, the
        # split's half-away-from-zero), same text format as before.
        $toleranceReadoutText.Text = Format-EstimateReadoutText -Keys $estimate.Keys -OverPct $estimate.PercentOverTolerance -WorstPct $estimate.WorstOverflowPct
    }
    Update-ToleranceVisual
}

# --- Estimate range + Tolerance bar (task48 rebuild, 2026-10-12) -----------
# Which frames the estimate measures: the chosen Time Range (see
# Get-EstimateRange in rom_launcher_logic.ps1). "Time Slider" can only be
# known from the last Preview / Start Recording click that resolved it from
# Maya (Get-ResolvedTimeRange stores it below) -- never queried on the tick.
$script:lastTimeSliderRangeStart = $null
$script:lastTimeSliderRangeEnd = $null
$script:lastEstimateRange = $null
$script:lastEstimateWorstPct = $null

function Get-SelectedTimeRangeMode {
    if ($timeSliderRadio.IsChecked) { return "TimeSlider" }
    if ($startEndRadio.IsChecked) { return "StartEnd" }
    return "All"
}

# Per-tick cost (task48 fix round): the range and both estimates are pure
# functions of their inputs, so each is memoized on ALL of them -- its own
# arguments plus the parsed cache (by object identity: Get-CachedFrameArrays
# re-parses on a new path / mtime and returns a NEW object) and the monitor
# rect text (frame width per pixel). The glow and the readout then share one
# computation per tick, and an idle tick recomputes nothing. Numbers are
# unchanged: a hit returns exactly what the same call computed before.
$script:estimateMemo = @{}
function Invoke-EstimateMemo([string]$Name, [string]$ArgsKey, [scriptblock]$Compute) {
    $arrays = Get-CachedFrameArrays
    $rectPath = Get-RecordingMonitorRectPath
    $rectText = if (Test-Path $rectPath) { [IO.File]::ReadAllText($rectPath) } else { "" }
    $key = "$ArgsKey|$rectText"
    $memo = $script:estimateMemo[$Name]
    if ($null -ne $memo -and $memo.Key -eq $key -and [object]::ReferenceEquals($memo.Arrays, $arrays)) { return $memo.Result }
    $result = & $Compute
    $script:estimateMemo[$Name] = [PSCustomObject]@{ Key = $key; Arrays = $arrays; Result = $result }
    return $result
}

$script:estimateRangeMemo = $null
function Get-CurrentEstimateRange {
    # Memoized on the radio, the box texts, the remembered Time Slider range
    # and the cache identity; the cached frame array is passed by reference
    # (an if-expression around it would unroll and re-allocate it per call).
    $arrays = Get-CachedFrameArrays
    $mode = Get-SelectedTimeRangeMode
    $key = "$mode|$($startFrameBox.Text)|$($endFrameBox.Text)|$($script:lastTimeSliderRangeStart)|$($script:lastTimeSliderRangeEnd)"
    $memo = $script:estimateRangeMemo
    if ($null -ne $memo -and $memo.Key -eq $key -and [object]::ReferenceEquals($memo.Arrays, $arrays)) { return $memo.Range }
    $frames = [double[]]@()
    if ($null -ne $arrays) { $frames = $arrays.Frames }
    $range = Get-EstimateRange -Mode $mode -Frames $frames -StartText $startFrameBox.Text -EndText $endFrameBox.Text `
        -LastTimeSliderStart $script:lastTimeSliderRangeStart -LastTimeSliderEnd $script:lastTimeSliderRangeEnd
    $script:estimateRangeMemo = [PSCustomObject]@{ Key = $key; Arrays = $arrays; Range = $range }
    return $range
}

# Gate OFF fixed-camera estimate over a KNOWN range: the same
# Get-ClippingEstimate Start Recording's click-time prompt uses, given the
# range's first/last cached frame (reference frame = Start, where
# frame_camera() parks the camera). Memoized (Invoke-EstimateMemo), so the
# glow and the readout share it.
function Get-GateOffRangeEstimate($Range) {
    $arrays = Get-CachedFrameArrays
    if ($null -eq $arrays -or -not $Range.Known) { return $null }
    $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $rs = [int][Math]::Round($arrays.Frames[$Range.StartIndex])
    $re = [int][Math]::Round($arrays.Frames[$Range.EndIndex])
    return Invoke-EstimateMemo "gateoff" "$axis|$($zoomSlider.Value)|$($script:lastValidOffsetX)|$rs|$re" {
        Get-ClippingEstimate -Axis $axis -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -RangeStart $rs -RangeEnd $re
    }
}

# The bar's inputs, from the live controls: tolerance in effect (Auto = the
# zoom-derived value, or the fixed 2.0 threshold with the gate OFF) and the
# last worst overshoot.
function Get-ToleranceVisualState {
    $gateOn = [bool]$frameGateCheckBox.IsChecked
    $auto = ($null -eq $script:lastValidTolerancePct)
    $tol = if ($auto) { Get-AutoTolFromZoom -ZoomPct ([Math]::Round($zoomSlider.Value)) -GateOn $gateOn } else { [double]$script:lastValidTolerancePct }
    if ($null -eq $tol) { $tol = 0.0 }
    return [PSCustomObject]@{ GateOn = $gateOn; Auto = $auto; TolPct = [double]$tol; WorstPct = $script:lastEstimateWorstPct }
}

$script:tolBlue = "#FF2F8CFF"
$script:tolRed = "#FFE0786E"
function New-TolBrush([string]$Hex) {
    return [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}
function Add-TolShape($Canvas, $Element, [double]$X, [double]$Y, [string]$Tag) {
    [System.Windows.Controls.Canvas]::SetLeft($Element, $X)
    [System.Windows.Controls.Canvas]::SetTop($Element, $Y)
    $Element.Tag = $Tag
    [void]$Canvas.Children.Add($Element)
}
function New-TolRect([double]$W, [double]$H, [string]$Fill, [string]$Stroke = "", [double]$Thickness = 0, [string]$Dash = "") {
    $r = New-Object System.Windows.Shapes.Rectangle
    $r.Width = [Math]::Max(0.0, $W); $r.Height = $H
    if ($Fill) { $r.Fill = New-TolBrush $Fill }
    if ($Stroke) {
        $r.Stroke = New-TolBrush $Stroke; $r.StrokeThickness = $Thickness
        if ($Dash) { $r.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse($Dash) }
    }
    return $r
}
function New-TolText([string]$Text, [double]$Size, [string]$Color, [bool]$Bold = $false) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = New-TolBrush $Color
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::Bold }
    $t.Measure((New-Object System.Windows.Size(300, 30)))
    return $t
}

# Draws the display-only diagram (user decisions 10b + W5, approved mocks
# task48_mock10/11/12): grey frame = 100 % of the frame width (a fifth of the
# bar, faint "100%" inside), the allowed margin on BOTH sides on the linear
# 10x scale, split into solid blue (used, up to the worst overshoot), pale
# dashed blue (unused slack) and a red outlined extension + "!" (overshoot
# beyond the margin). Auto = dashed outline + "A"; gate OFF = "!" at the left
# and dashed frame caps. Every shape carries a Tag so tests can measure it.
function New-ToleranceDiagram($State, [double]$CanvasWidth = 224.0, [double]$CanvasHeight = 22.0) {
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $CanvasWidth; $cv.Height = $CanvasHeight; $cv.ClipToBounds = $true
    $geo = Get-ToleranceVisualGeometry -CanvasWidth $CanvasWidth
    $cx = $geo.CenterX; $fw = $geo.FrameWidth; $k = $geo.PxPerPct
    $by = 11.0; $bh = 10.0
    $lab = "#FFB0B0B0"; $cap = "#FFC8C8C8"; $hair = "#FFD0D0D0"
    $left0 = $cx - $fw / 2.0; $right0 = $cx + $fw / 2.0
    $split = Get-ToleranceBandSplit -TolerancePct $State.TolPct -WorstPct $State.WorstPct
    $tw = Get-ToleranceMarginPx -Pct $State.TolPct -PxPerPct $k
    $uw = Get-ToleranceMarginPx -Pct $split.UsedPct -PxPerPct $k
    $sw = [Math]::Max(0.0, $tw - $uw)
    $ow = if ($split.IsOver) { (Get-ToleranceMarginPx -Pct ($split.UsedPct + $split.OverPct) -PxPerPct $k) - $tw } else { 0.0 }

    Add-TolShape $cv (New-TolRect $fw $bh "#FF707070") $left0 $by "frame"
    Add-TolShape $cv (New-TolText "100%" 6.5 "#FF2A2A2A") ($cx - 11) ($by - 0.5) "label-100"
    foreach ($side in @("L", "R")) {
        $sign = if ($side -eq "R") { 1 } else { -1 }
        $edge = if ($side -eq "R") { $right0 } else { $left0 }
        if ($uw -gt 0.01) {
            $used = New-TolRect $uw $bh $script:tolBlue
            if ($State.Auto) { $used.Opacity = 0.65 }
            Add-TolShape $cv $used $(if ($sign -gt 0) { $edge } else { $edge - $uw }) $by "used-$side"
        }
        if ($sw -gt 0.3) {
            Add-TolShape $cv (New-TolRect $sw $bh "#552F8CFF" $script:tolBlue 1 "2,2") $(if ($sign -gt 0) { $edge + $uw } else { $edge - $uw - $sw }) $by "slack-$side"
        }
        if ($ow -gt 0.01) {
            Add-TolShape $cv (New-TolRect $ow $bh "#66E0786E" $script:tolRed 1.2) $(if ($sign -gt 0) { $edge + $tw } else { $edge - $tw - $ow }) $by "over-$side"
        }
        if ($State.Auto -and $tw -gt 0.01) {
            Add-TolShape $cv (New-TolRect $tw ($bh + 4) "" $hair 1 "2,2") $(if ($sign -gt 0) { $edge } else { $edge - $tw }) ($by - 2) "auto-$side"
        }
        # frame-edge caps: solid with the gate ON, dashed with it OFF (camera fixed)
        if ($State.GateOn) {
            Add-TolShape $cv (New-TolRect 2 ($bh + 4) $cap) ($edge - 1) ($by - 2) "cap-$side"
        } else {
            $ln = New-Object System.Windows.Shapes.Line
            $ln.X1 = 0; $ln.X2 = 0; $ln.Y1 = 0; $ln.Y2 = ($bh + 4)
            $ln.Stroke = New-TolBrush $cap; $ln.StrokeThickness = 2
            $ln.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse("2,1.5")
            Add-TolShape $cv $ln $edge ($by - 2) "cap-$side"
        }
    }
    # scale: ticks at 5 / 10 / 20 % on both sides; numbers and "x10" on the
    # LEFT so the right-hand label row stays free for "!" / "A"
    foreach ($tp in @(5.0, 10.0, 20.0)) {
        foreach ($tx in @(($left0 - $tp * $k), ($right0 + $tp * $k))) {
            Add-TolShape $cv (New-TolRect 1 3 $lab) ([Math]::Min([Math]::Max($tx, 0.0), $CanvasWidth - 1.0)) ($by - 3) "tick"
        }
        $t = New-TolText ("{0:0}" -f $tp) 7 $lab
        Add-TolShape $cv $t ([Math]::Max(1.0, ($left0 - $tp * $k) - $t.DesiredSize.Width / 2.0)) -1 "tick-label"
    }
    Add-TolShape $cv (New-TolText "x10" 7 $lab) 73 -1 "label-x10"
    if ($split.IsOver) {
        $bang = New-TolText "!" 11 $script:tolRed $true
        Add-TolShape $cv $bang ([Math]::Min($right0 + $tw + $ow + 2, $CanvasWidth - $bang.DesiredSize.Width)) -2 "bang-over"
    }
    if ($State.Auto) {
        $a = New-TolText "A" 7 $hair
        $ax = $right0 + $tw + 2
        if ($split.IsOver -or $ax + $a.DesiredSize.Width -gt $CanvasWidth - 1) { $ax = $right0 + $tw - 2 - $a.DesiredSize.Width }
        Add-TolShape $cv $a $ax -1 "auto-A"
    }
    if (-not $State.GateOn) { Add-TolShape $cv (New-TolText "!" 12 "#FFFFFFFF" $true) 3 8 "bang-off" }
    return $cv
}

# Rebuilds the bar only when one of its inputs changed (it is also called on
# every 60 ms tick through Update-ToleranceReadout), then refreshes the
# tooltip and hides the "%" after "Auto".
$script:tolVisualKey = $null
function Update-ToleranceVisual {
    if ($null -eq $tolVisualHost) { return }
    $state = Get-ToleranceVisualState
    $range = $script:lastEstimateRange
    $rangeText = ""
    if ($null -ne $range -and $range.Known) { $rangeText = "frames $($range.StartFrame)-$($range.EndFrame)" }
    $reason = if ($null -ne $range) { $range.Reason } else { $null }
    $key = "$($state.GateOn)|$($state.Auto)|$($state.TolPct)|$($state.WorstPct)|$rangeText|$reason"
    $tolPctSuffix.Visibility = if ($state.Auto) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    if ($key -eq $script:tolVisualKey -and $null -ne $tolVisualHost.Child) { return }
    $script:tolVisualKey = $key
    $tolVisualHost.Child = New-ToleranceDiagram $state
    $tolVisualHost.ToolTip = Get-ToleranceTooltipText -GateOn $state.GateOn -Auto $state.Auto -TolPct $state.TolPct -WorstPct $state.WorstPct -RangeText $rangeText -PendingReason $reason
}

$script:liveApplyTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:liveApplyTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$script:liveApplyTimer.Add_Tick({
    Update-FrameGateGlow
    Update-ToleranceReadout
    Invoke-LiveApplyTick
})
$script:liveApplyTimer.Start()

function Get-RecenterStartFramePath {
    # Own function, same reasoning as Get-CameraZoomPctPath.
    Join-Path $ScriptDir "..\d4_anim_sample\_camera_recenter_start_frame.txt"
}

function Write-RecenterStartFrame([double]$Frame) {
    # Read by get_recenter_start_frame() in maya_camera_panels.py/_LR.py.
    $framePath = Get-RecenterStartFramePath
    $frameDir = Split-Path $framePath -Parent
    if (-not (Test-Path $frameDir)) {
        New-Item -ItemType Directory -Path $frameDir | Out-Null
    }
    Set-Content -Path $framePath -Value "$Frame" -Encoding ASCII
}

function Clear-RecenterStartFrame {
    # Writes an EMPTY file, not just skipping the write -- get_recenter_
    # start_frame() reads an empty file as "disabled" (returns None). A
    # stale non-empty value from a PREVIOUS run must never keep silently
    # applying after the checkbox is unchecked (same "explicitly reset,
    # don't rely on stale state" lesson as the magnifier's 0%-at-startup
    # fix, 2026-09-02) -- this is called every Preview/Start Recording
    # click when the checkbox is unchecked, not just once at startup.
    $framePath = Get-RecenterStartFramePath
    $frameDir = Split-Path $framePath -Parent
    if (-not (Test-Path $frameDir)) {
        New-Item -ItemType Directory -Path $frameDir | Out-Null
    }
    Set-Content -Path $framePath -Value "" -Encoding ASCII
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
    # Same connect+identify handshake this call just performed for the
    # Recording Monitor dropdown's own sake also proves (or disproves)
    # the configured password -- feed it into that dot too instead of
    # letting it sit on whatever Update-ObsPasswordStatusIndicator's own
    # network-free guess last showed.
    Update-ObsPasswordVerificationIndicator $result
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

function Test-RecordingMonitorSelected {
    # Own overridable function (same pattern as Test-MayaPortReachable /
    # Get-ObsPasswordStatus), used by the Start Recording requirements
    # gate. IsEnabled only ever becomes true inside Update-MonitorList's
    # confirmed-response-from-OBS branch -- the Gray/disabled states (OBS
    # not running, showing a stale last-used entry) do NOT count as
    # satisfied here, since starting a recording against one of those
    # would not actually work.
    return $monitorComboBox.IsEnabled -and $monitorComboBox.SelectedIndex -ge 0
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
    <Window.Resources>
        <!-- This is a SEPARATE XamlReader.Load() document from the main
             window, so it does not inherit that window's ScrollBar style:
             duplicated here rather than shared, same convention this
             project already uses for standalone script logic (see e.g.
             obs_monitor.ps1's own header comment). Kept in sync by hand
             with the main window's copy. -->
        <Style x:Key="RomScrollBarThumbStyle" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="ThumbBorder" Background="#FF5A5A5A" CornerRadius="3" Margin="1"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#FF6E6E6E"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#FF464646"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="MinWidth" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="{TemplateBinding Background}">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource RomScrollBarThumbStyle}"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Same implicit Button style as the main window's own copy,
             needed because this is a separate XamlReader.Load() document
             that does not inherit that one. Without this, Back/Next fell
             back to WPF's default Button chrome, which (unlike this
             template) renders a disabled button as plain white; confirmed
             live: Back looked "totally white" on page 1, where it is
             disabled by design. -->
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
    </Window.Resources>
    <Grid Margin="16">
        <!-- Book-style pagination (design 2026-08-22, requested to cut
             down on scrolling through unrelated sections just to reach
             one): one page visible at a time in PageHost, flipped via
             Back/Next instead of everything stacked in one long scroll. -->
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Margin="0,0,0,10">
            <StackPanel x:Name="PageHost"/>
        </ScrollViewer>
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Grid.Column="0" x:Name="BackButton" Content="Back" Width="80" Height="26"/>
            <TextBlock Grid.Column="1" x:Name="PageLabel" Foreground="#FFA0A0A0" FontSize="11"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Button Grid.Column="2" x:Name="NextButton" Content="Next" Width="80" Height="26"/>
        </Grid>
    </Grid>
</Window>
"@
    $guideReader = New-Object System.Xml.XmlNodeReader $guideXaml
    $guideWindow = [Windows.Markup.XamlReader]::Load($guideReader)
    $guideWindow.Title = $Title
    if ($window.IsVisible) {
        $guideWindow.Owner = $window
    }

    $pageHost = $guideWindow.FindName("PageHost")

    # Page 0 = a short "USAGE" intro (the old always-on TLDR line, now its
    # own page instead of pinned above everything else) -- Page 1..N = one
    # page per $Sections entry. RegisterName on TldrText specifically:
    # Show-DarkGuide's own regression tests FindName() it directly, and
    # XamlReader's auto-generated NameScope only covers elements that were
    # part of the original static markup, not ones added via code later.
    $usagePage = New-Object System.Windows.Controls.StackPanel
    $tldrText = New-Object System.Windows.Controls.TextBlock
    $tldrText.Name = "TldrText"
    $tldrText.Text = $Tldr
    $tldrText.TextWrapping = "Wrap"
    $tldrText.FontWeight = "Bold"
    $tldrText.FontSize = 14
    $tldrText.Foreground = "#FFE6E6E6"
    $pageHost.RegisterName($tldrText.Name, $tldrText)
    $usagePage.Children.Add($tldrText) | Out-Null
    $pages = @($usagePage)

    foreach ($section in $Sections) {
        $sectionPage = New-Object System.Windows.Controls.StackPanel

        $headerText = New-Object System.Windows.Controls.TextBlock
        $headerText.Text = $section.Header
        $headerText.TextWrapping = "Wrap"
        $headerText.FontWeight = "Bold"
        $headerText.FontSize = 13
        $headerText.Foreground = "#FFE6E6E6"
        $headerText.Margin = "0,0,0,8"
        $sectionPage.Children.Add($headerText) | Out-Null

        if ($section.ImagePath -and (Test-Path $section.ImagePath)) {
            # Real screenshot of this section's own tab, shown once above
            # its numbered steps -- "here's what it actually looks like,"
            # not a per-step diagram (the bold Lead text in each step
            # already does the pointing-at-a-specific-control job in
            # prose). Same OnLoad-cached BitmapImage loading as
            # Show-DarkMonitorResult/Show-DarkInput's own guide image.
            $sectionBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $sectionBitmap.BeginInit()
            $sectionBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $sectionBitmap.UriSource = New-Object System.Uri($section.ImagePath)
            $sectionBitmap.EndInit()
            $sectionImage = New-Object System.Windows.Controls.Image
            $sectionImage.Source = $sectionBitmap
            $sectionImage.Stretch = "Uniform"
            $sectionImage.MaxHeight = 280
            $sectionImage.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
            $sectionBorder = New-Object System.Windows.Controls.Border
            $sectionBorder.BorderBrush = "#FF4C4C4C"
            $sectionBorder.BorderThickness = 1
            $sectionBorder.Margin = "0,0,0,10"
            $sectionBorder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
            $sectionBorder.Child = $sectionImage
            $sectionPage.Children.Add($sectionBorder) | Out-Null
        }

        $stepNumber = 1
        foreach ($step in $section.Steps) {
            $stepRow = New-GuideStepRow -Number $stepNumber -Lead $step.Lead -Text $step.Text
            $sectionPage.Children.Add($stepRow) | Out-Null
            $stepNumber++
        }

        $pages += $sectionPage
    }

    # No custom Close button (removed 2026-08-22, redundant with the
    # window's own native title-bar close) -- Closed still covers however
    # the user actually closes it (native X, Alt+F4, etc).
    # Clears the tracked reference once actually closed, so a LATER click
    # creates a fresh window rather than trying to Activate() a disposed
    # one -- Closed (not Closing) since this only needs to run once the
    # window is genuinely gone. Routed through Clear-OpenGuideWindow, not
    # a bare $script: write inline -- see the NOTE above.
    $guideWindow.Add_Closed({ Clear-OpenGuideWindow }.GetNewClosure())
    # Back/Next are each their own separate .GetNewClosure() scriptblock,
    # so (same isolation reasoning as Clear-OpenGuideWindow) they cannot
    # reliably share a plain local page-index variable with each other --
    # both routed through Get-/Set-GuideCurrentPage instead.
    $guideWindow.FindName("BackButton").Add_Click({ Set-GuideCurrentPage ((Get-GuideCurrentPage) - 1) }.GetNewClosure())
    $guideWindow.FindName("NextButton").Add_Click({ Set-GuideCurrentPage ((Get-GuideCurrentPage) + 1) }.GetNewClosure())

    $script:guidePages = $pages
    $script:openGuideWindow = $guideWindow
    Set-GuideCurrentPage 0
    $guideWindow.Show()
}

function Get-GuideCurrentPage {
    return $script:guideCurrentPageIndex
}

function Set-GuideCurrentPage([int]$Index) {
    # Real top-level function, not inline logic in a closure -- see the
    # NOTE on Clear-OpenGuideWindow above; this is the same fix applied to
    # Back/Next page navigation.
    if ($script:guidePages -eq $null -or $script:guidePages.Count -eq 0) { return }
    $Index = [Math]::Max(0, [Math]::Min($Index, $script:guidePages.Count - 1))
    $script:guideCurrentPageIndex = $Index

    $guideWin = $script:openGuideWindow
    $pageHost = $guideWin.FindName("PageHost")
    $pageHost.Children.Clear()
    $pageHost.Children.Add($script:guidePages[$Index]) | Out-Null
    $guideWin.FindName("BackButton").IsEnabled = ($Index -gt 0)
    $guideWin.FindName("NextButton").IsEnabled = ($Index -lt ($script:guidePages.Count - 1))
    $guideWin.FindName("PageLabel").Text = "Page $($Index + 1) of $($script:guidePages.Count)"
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

function Write-NoteworthyMayaOutput([string]$Label, [string]$Stdout) {
    # Shared by the synchronous "quick check" round-trips (Get-CacheStatus,
    # Get-TimeSliderRange, Get-AnimationRange), which previously discarded
    # their subprocess's stdout entirely via `| Out-Null` -- meaning a
    # genuine failure during one of these checks (Maya raising an
    # exception, or a timeout) produced no log entry at all, success or
    # failure. The actual filtering logic lives in Get-NoteworthyMayaOutput
    # (rom_launcher_logic.ps1) -- kept pure/unit-testable, same split as
    # every other Convert-From-*/Get-* function there; this is just the
    # thin WPF-side wrapper that performs the Write-Log side effect.
    $noteworthy = Get-NoteworthyMayaOutput -Stdout $Stdout
    if ($noteworthy) {
        Write-Log "[$Label] $noteworthy"
    }
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

function Show-AllTaskbars {
    # Restores every Windows taskbar via the same standalone utility
    # Get-CaptureSteps's own "hide" step (Recording only) uses. Own
    # overridable top-level function (same pattern as
    # Test-MayaPortReachable/Get-ObsPasswordStatus) so tests can stub this
    # instead of actually hiding/showing the real desktop taskbar during a
    # headless run. Safe to call unconditionally even when this run never
    # hid the taskbar in the first place (Preview, or a Recording run that
    # aborted before its own hide step) -- showing an already-visible
    # taskbar is a no-op.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'taskbar_control.ps1')`" -Action show"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $proc.WaitForExit(5000) | Out-Null
}

function Complete-Run([string]$FinalMessage = "=== All steps finished ===", [bool]$Aborted = $false) {
    # Factored out of Start-NextStep's own "ran out of steps" branch so
    # the pollTimer's abort path (see Set-CaptureAbortReason) can share
    # the exact same cleanup instead of a second, easy-to-drift copy.
    $script:pollTimer.Stop()
    $script:runStatus = "Done"
    Set-ButtonRunningVisual $script:activeButton $false
    Set-ButtonsEnabled $true
    $script:activeButton = $null
    Write-Log $FinalMessage
    if ($Aborted) {
        # An aborted run (CAPTURE_ABORT -- e.g. the scene has no animation
        # to key off of) can happen AFTER Get-CaptureSteps's own taskbar-hide
        # step (its very first step, Recording only) but BEFORE the paired
        # "show" step later in that same queue -- confirmed live: this left
        # the Windows taskbar missing indefinitely, with nothing left in
        # the queue to ever restore it (Get-CleanResetStep only reaches
        # Maya over the command port, which cannot touch the Windows
        # taskbar at all).
        Show-AllTaskbars
    }
    # Stopping pollTimer above also stops Update-CacheProgress from ever
    # running again -- previously the ONLY thing that hid CacheProgressPanel
    # was Start-Steps deleting the progress file at the START of the NEXT
    # run, so a cache build left the bar frozen at ~100% until the user
    # began something else. Hide it here, as part of THIS run actually
    # finishing, not as an accidental side effect of starting a new one.
    Remove-Item $script:cacheProgressPath -ErrorAction SilentlyContinue
    $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed
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
    $info = ConvertFrom-CacheProgressOutput $lines
    if ($info.IsComplete) {
        # Sampling itself is done -- hide right here instead of waiting for
        # Complete-Run, which only fires once the whole run (including any
        # steps queued after the cache build, e.g. the post-cache clean
        # reset) finishes. See ConvertFrom-CacheProgressOutput.
        $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $cacheProgressPanel.Visibility = [System.Windows.Visibility]::Visible
    $cacheProgressBar.Value = $info.Percent
    $cacheProgressLabel.Text = $info.Label
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
            Complete-Run "=== Run aborted: $($script:captureAbortReason) ===" -Aborted $true
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
    Update-ToleranceReadout
})
# task48 rebuild: the Estimated line and the Tolerance bar measure the chosen
# Time Range, so they recompute at once when it changes (the 60 ms tick would
# catch up anyway; this makes it immediate and testable).
$timeSliderRadio.Add_Checked({ $startEndPanel.Visibility = [System.Windows.Visibility]::Collapsed; Update-ToleranceReadout })
$allFramesRadio.Add_Checked({ $startEndPanel.Visibility = [System.Windows.Visibility]::Collapsed; Update-ToleranceReadout })
$startFrameBox.Add_TextChanged({ if ($startEndRadio.IsChecked) { Update-ToleranceReadout } })
$endFrameBox.Add_TextChanged({ if ($startEndRadio.IsChecked) { Update-ToleranceReadout } })

# Deferred-to-release (2026-09-08, user feedback: continuous live update
# "feels jumpy"): the slider's OWN value/text update instantly and always
# (that's free -- no Maya round trip), but the Maya push is suppressed
# while $script:zoomSliderDragging is true, and fires exactly once when
# the thumb drag completes. A single click on the track (not a drag)
# never sets that flag at all, so it still applies immediately -- only a
# genuine held-drag gets deferred.
$script:zoomSliderDragging = $false
# task48 F3: a REAL thumb drag is tracked on its own flag, so a key/wheel step
# session settling mid-drag (Stop-ZoomStep) can no longer clear the push hold
# under the user's mouse; the drag's own completion releases it.
$script:zoomThumbDragging = $false
$zoomSlider.AddHandler(
    [System.Windows.Controls.Primitives.Thumb]::DragStartedEvent,
    [System.Windows.RoutedEventHandler]{ $script:zoomThumbDragging = $true; $script:zoomSliderDragging = $true })
$zoomSlider.AddHandler(
    [System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent,
    [System.Windows.RoutedEventHandler]{
        $script:zoomThumbDragging = $false
        $script:zoomSliderDragging = $false
        $script:pendingZoomPush = $true
    })
$zoomSlider.Add_ValueChanged({
    # Snap to whole percent -- the underlying framing math has no use for
    # fractional percent, and a whole number is simpler to type back in.
    # "+0;-0;0" is a 3-section custom numeric format (positive;negative;
    # zero) -- the only place this is worth relying on .NET's own sign
    # handling rather than an if/else, since it needs to run every time
    # the slider moves (dragging fires this continuously).
    $pct = [Math]::Round($zoomSlider.Value)
    $zoomValueBox.Text = "{0:+0;-0;0}" -f $pct
    Write-CameraZoomPct -Value $pct
    if (-not $script:zoomSliderDragging) {
        $script:pendingZoomPush = $true
    }
    # Auto's dashed mark follows Zoom at once (task48 rebuild); the estimate
    # itself catches up on the next 60 ms tick.
    Update-ToleranceVisual
})

# --- Offset wheel-nudge on the X/Y boxes (2026-09-08: replaces drag) --
# Middle-click-drag didn't work reliably in real use -- replaced with
# mouse-wheel scroll directly on each box: wheel up/down on OffsetXBox
# nudges X only, same on OffsetYBox for Y. 10px per notch, Shift = 100px, same
# convention as the arrow-key nudge. Deferred-to-settle, same "avoid
# jumpy" principle as the drag had: box text updates on every notch, but
# the Maya push only fires once scrolling actually stops (400ms of no
# further wheel input), using the whole session's total -- a fast spin
# doesn't flood Maya with one send per notch.
#
# Core logic lives in named functions taking an EXPLICIT direction/shift
# flag, not hidden behind e.Delta -- same reasoning as the other nudge
# paths above.
# Modifier state for the numeric-box key/wheel handlers (task48). Reads the real
# keyboard via the static Keyboard.Modifiers -- NOT $e.KeyboardDevice, which
# MouseWheelEventArgs does not have (the old X/Y wheel handlers read that and
# always got $null, so Shift never registered on the wheel). Tests set
# $script:modifierKeysOverride to a [ModifierKeys] value to drive Shift/Ctrl
# through the real handlers without touching the physical keyboard.
$script:modifierKeysOverride = $null
function Get-CurrentModifierKeys {
    if ($null -ne $script:modifierKeysOverride) { return $script:modifierKeysOverride }
    return [System.Windows.Input.Keyboard]::Modifiers
}

$script:wheelNudgeAxis = $null   # $null, "X", or "Y"
$script:wheelNudgeStartValue = 0
$script:wheelNudgeCurrentValue = 0.0

$script:wheelSettleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:wheelSettleTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:wheelSettleTimer.Add_Tick({ Stop-OffsetWheelNudge })

function Update-OffsetWheelNudge([string]$Axis, [int]$Delta, [bool]$ShiftHeld, [bool]$CtrlHeld = $false) {
    if ($script:wheelNudgeAxis -ne $null -and $script:wheelNudgeAxis -ne $Axis) {
        # Switching axis mid-stream (rare, but possible if the mouse moves
        # to the other box while still settling) -- flush the prior one
        # first rather than mixing sessions.
        Stop-OffsetWheelNudge
    }
    if ($script:wheelNudgeAxis -eq $null) {
        $script:wheelNudgeAxis = $Axis
        $script:wheelNudgeStartValue = if ($Axis -eq "X") { $script:lastValidOffsetX } else { $script:lastValidOffsetY }
        $script:wheelNudgeCurrentValue = $script:wheelNudgeStartValue
    }
    # 10px default / 100px with Shift (2026-09-08): coarse-only via wheel/
    # arrow-key -- exact values go through the typed box directly (edit
    # the last digit, e.g. 95/96/103/3), which these nudge controls were
    # never meant to replace.
    # task48: the step now comes from the shared step table (plain 10 /
    # Shift 100 / Ctrl 1, Ctrl wins) so wheel, arrows and tests cannot
    # drift apart. Plain and Shift are unchanged from before.
    $step = Get-NumericStepSize -Field $(if ($Axis -eq "X") { "OffsetX" } else { "OffsetY" }) -Shift $ShiftHeld -Ctrl $CtrlHeld
    $direction = if ($Delta -gt 0) { 1 } else { -1 }
    $script:wheelNudgeCurrentValue += $direction * $step
    $box = if ($Axis -eq "X") { $offsetXBox } else { $offsetYBox }
    $box.Text = "$([Math]::Round($script:wheelNudgeCurrentValue))"
    $script:wheelSettleTimer.Stop()
    $script:wheelSettleTimer.Start()
}
function Stop-OffsetWheelNudge {
    $script:wheelSettleTimer.Stop()
    if ($script:wheelNudgeAxis -eq $null) { return }
    $axis = $script:wheelNudgeAxis
    $finalValue = [Math]::Round($script:wheelNudgeCurrentValue)
    $delta = $finalValue - $script:wheelNudgeStartValue
    if ($axis -eq "X") { $script:lastValidOffsetX = $finalValue } else { $script:lastValidOffsetY = $finalValue }
    $box = if ($axis -eq "X") { $offsetXBox } else { $offsetYBox }
    $box.Text = "$finalValue"
    if ($delta -ne 0) {
        if ($axis -eq "X") { $script:pendingNudgeDeltaX += $delta } else { $script:pendingNudgeDeltaY += $delta }
        Write-CameraOffsetPx -X $script:lastValidOffsetX -Y $script:lastValidOffsetY
    }
    $script:wheelNudgeAxis = $null
}

$offsetXBox.Add_MouseWheel({
    param($eventSender, $e)
    # task48: MouseWheelEventArgs has NO KeyboardDevice property (checked by
    # reflection), so the old $e.KeyboardDevice.Modifiers read was always $null
    # and Shift never registered on the wheel. The static Keyboard.Modifiers
    # is the real modifier state.
    # task48 F2: through Step-OffsetBox (same as Up/Down), so text typed but
    # not yet committed is committed first instead of being lost.
    if ($e.Delta -eq 0) { return }
    $mods = Get-CurrentModifierKeys
    $shiftHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ctrlHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    Step-OffsetBox "X" $(if ($e.Delta -gt 0) { 1 } else { -1 }) $shiftHeld $ctrlHeld
    $e.Handled = $true
})
$offsetYBox.Add_MouseWheel({
    param($eventSender, $e)
    # task48: MouseWheelEventArgs has NO KeyboardDevice property (checked by
    # reflection), so the old $e.KeyboardDevice.Modifiers read was always $null
    # and Shift never registered on the wheel. The static Keyboard.Modifiers
    # is the real modifier state.
    # task48 F2: see the X handler above.
    if ($e.Delta -eq 0) { return }
    $mods = Get-CurrentModifierKeys
    $shiftHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ctrlHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    Step-OffsetBox "Y" $(if ($e.Delta -gt 0) { 1 } else { -1 }) $shiftHeld $ctrlHeld
    $e.Handled = $true
})

# --- Hover-gated arrow-key nudge on the repositioned pad --------------
# No click/focus needed -- as long as the mouse is hovering ArrowNudgePad,
# arrow keys nudge offset, regardless of which control technically has
# keyboard focus. Bound at the WINDOW level (Preview, tunnels from the
# window down to whatever has focus) rather than on the pad itself, since
# the pad never actually receives focus in this design. Deferred-to-
# release, same as the drag above: held/auto-repeat keys update the boxes
# live but only push to Maya once the key is released.
$script:arrowNudgeActive = $false
$script:arrowNudgeStartX = 0
$script:arrowNudgeStartY = 0

function Start-ArrowNudge {
    $script:arrowNudgeActive = $true
    $script:arrowNudgeStartX = $script:lastValidOffsetX
    $script:arrowNudgeStartY = $script:lastValidOffsetY
}
function Update-ArrowNudge([System.Windows.Input.Key]$Key, [bool]$ShiftHeld) {
    # Same 10px/100px convention as the wheel nudge above.
    $step = if ($ShiftHeld) { 100 } else { 10 }
    $dx = 0; $dy = 0
    if ($Key -eq [System.Windows.Input.Key]::Left) { $dx = -$step }
    elseif ($Key -eq [System.Windows.Input.Key]::Right) { $dx = $step }
    elseif ($Key -eq [System.Windows.Input.Key]::Up) { $dy = $step }
    elseif ($Key -eq [System.Windows.Input.Key]::Down) { $dy = -$step }
    else { return $false }

    $script:lastValidOffsetX += $dx
    $script:lastValidOffsetY += $dy
    $offsetXBox.Text = "$($script:lastValidOffsetX)"
    $offsetYBox.Text = "$($script:lastValidOffsetY)"
    return $true
}
function Stop-ArrowNudge {
    if (-not $script:arrowNudgeActive) { return }
    $script:arrowNudgeActive = $false
    $deltaX = $script:lastValidOffsetX - $script:arrowNudgeStartX
    $deltaY = $script:lastValidOffsetY - $script:arrowNudgeStartY
    if ($deltaX -ne 0 -or $deltaY -ne 0) {
        $script:pendingNudgeDeltaX += $deltaX
        $script:pendingNudgeDeltaY += $deltaY
        Write-CameraOffsetPx -X $script:lastValidOffsetX -Y $script:lastValidOffsetY
    }
}
function Test-ArrowNudgeKey([System.Windows.Input.Key]$Key) {
    return $Key -eq [System.Windows.Input.Key]::Left -or $Key -eq [System.Windows.Input.Key]::Right -or
           $Key -eq [System.Windows.Input.Key]::Up -or $Key -eq [System.Windows.Input.Key]::Down
}

$window.Add_PreviewKeyDown({
    param($eventSender, $e)
    if (-not $arrowNudgePad.IsMouseOver) { return }
    if (-not (Test-ArrowNudgeKey $e.Key)) { return }
    if (-not $script:arrowNudgeActive) { Start-ArrowNudge }
    $shiftHeld = ($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    Update-ArrowNudge -Key $e.Key -ShiftHeld $shiftHeld | Out-Null
    $e.Handled = $true
})
$window.Add_PreviewKeyUp({
    param($eventSender, $e)
    if (Test-ArrowNudgeKey $e.Key) { Stop-ArrowNudge }
})

# --- Reset button ------------------------------------------------------
# A discrete, one-shot action (not something "in progress"), so it
# applies immediately -- same reasoning as a typed box commit.
$resetFrameOffsetsButton.Add_Click({
    # The whole Adjust section (task48 rebuild, user decision; was Zoom/X/Y
    # only): Zoom 0, X 0, Y 0, Frame gate back ON, Tolerance back to Auto.
    # Any key/wheel session still settling is flushed FIRST, so its late
    # settle can never write its old value over the reset.
    Stop-ZoomStep
    Stop-OffsetWheelNudge
    $zoomSlider.Value = 0
    $offsetXBox.Text = "0"
    $offsetYBox.Text = "0"
    Commit-OffsetBoxes
    $frameGateCheckBox.IsChecked = $true
    $toleranceValueBox.Text = 'Auto'
    Commit-ToleranceValueBox
})

# --- Frame gate checkbox ------------------------------------------------
# Writes immediately on toggle (Checked/Unchecked fire synchronously on the
# state change itself, not on the 60ms timer) -- Success Criterion 1 asks
# for "within one tick," this is actually immediate.
$frameGateCheckBox.Add_Checked({ Write-FrameGateEnabled -Enabled $true; Update-ToleranceReadout })
$frameGateCheckBox.Add_Unchecked({ Write-FrameGateEnabled -Enabled $false; Update-ToleranceReadout })

$script:lastValidTolerancePct = $null  # $null = Auto, the default

function Commit-ToleranceValueBox {
    # Auto/blank means "use today's zoom-and-offset-derived formula" -- a
    # DIFFERENT state from typing "0", which is a real, valid (if
    # aggressive) manual choice: zero slack, react instantly. Mirrors
    # Commit-ZoomValueBox/Commit-OffsetBoxes' revert-on-invalid discipline,
    # but has a third valid state (Auto) neither of those needed. Writes
    # DIRECTLY (unlike Commit-ZoomValueBox, which routes through a slider
    # that does the writing) since there is no companion slider here, same
    # direct-write shape as Commit-OffsetBoxes.
    $text = $toleranceValueBox.Text.Trim()
    if ($text -eq '' -or $text -ieq 'auto') {
        $script:lastValidTolerancePct = $null
        $toleranceValueBox.Text = 'Auto'
    } else {
        # task48 F4: "NaN"/"Infinity" parse as doubles but are garbage here.
        $value = ConvertFrom-FiniteNumberText -Text $text.TrimEnd('%')
        if ($null -ne $value) {
            $script:lastValidTolerancePct = [Math]::Max(0.0, [Math]::Min(20.0, $value))
            $toleranceValueBox.Text = "$($script:lastValidTolerancePct)"
        } else {
            # Unparseable garbage -- revert instead of leaving stale/invalid
            # text on screen or writing it to disk, same discipline as every
            # other box on this row.
            $toleranceValueBox.Text = if ($null -eq $script:lastValidTolerancePct) { 'Auto' } else { "$($script:lastValidTolerancePct)" }
        }
    }
    Write-CameraTolerancePct -Value $script:lastValidTolerancePct
    Update-ToleranceVisual
}
$toleranceValueBox.Add_LostFocus({ Commit-ToleranceValueBox })
$toleranceValueBox.Add_KeyDown({
    param($eventSender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        Commit-ToleranceValueBox
        [System.Windows.Input.Keyboard]::ClearFocus()
    }
})

function Commit-ZoomValueBox {
    # Typed entry, alongside the slider (2026-09-02, user asked for exact
    # values, not just dragging). Routes through the slider rather than
    # calling Write-CameraZoomPct directly, so there is still only one
    # place that writes the file and only one place that formats the
    # display text -- this just decides what value to hand it.
    $text = $zoomValueBox.Text.Trim().TrimEnd('%')
    # task48 F4: "NaN"/"Infinity" revert like any other garbage (a NaN
    # reaching the slider threw mid-step and could leave live zoom stuck).
    $value = ConvertFrom-FiniteNumberText -Text $text
    if ($null -ne $value) {
        $zoomSlider.Value = [Math]::Max(-50, [Math]::Min(50, [Math]::Round($value)))
    } else {
        # Empty or unparseable -- revert to the last valid value instead of
        # leaving stale/garbage text on screen or writing it to disk.
        $zoomValueBox.Text = "{0:+0;-0;0}" -f ([Math]::Round($zoomSlider.Value))
    }
}
$zoomValueBox.Add_LostFocus({ Commit-ZoomValueBox })
$zoomValueBox.Add_KeyDown({
    param($eventSender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        Commit-ZoomValueBox
        # Moves focus off the box so the commit visibly "lands" (matches
        # LostFocus's own behavior) instead of leaving the caret sitting in
        # a box that already applied -- Enter is the one path that commits
        # without the user's next action doing that for free.
        [System.Windows.Input.Keyboard]::ClearFocus()
    }
})

$script:lastValidOffsetX = 0
$script:lastValidOffsetY = 0

function Commit-OffsetBoxes {
    # X and Y share one file as a single "X,Y" line (see
    # Write-CameraOffsetPx), so committing EITHER box re-reads BOTH current
    # values and writes them together -- keeps the file always in sync with
    # what's on screen, rather than one box's commit silently overwriting
    # the other's not-yet-committed value with a stale one. Invalid/empty
    # input in either box reverts JUST that box to its own last valid
    # value, same discipline as the magnifier's Commit-ZoomValueBox.
    $priorX = $script:lastValidOffsetX
    $priorY = $script:lastValidOffsetY

    # task48 F4: non-finite text ("NaN", "Infinity") reverts too.
    $x = ConvertFrom-FiniteNumberText -Text $offsetXBox.Text.Trim()
    if ($null -ne $x) {
        $script:lastValidOffsetX = [Math]::Round($x)
    }
    $offsetXBox.Text = "$($script:lastValidOffsetX)"

    $y = ConvertFrom-FiniteNumberText -Text $offsetYBox.Text.Trim()
    if ($null -ne $y) {
        $script:lastValidOffsetY = [Math]::Round($y)
    }
    $offsetYBox.Text = "$($script:lastValidOffsetY)"

    Write-CameraOffsetPx -X $script:lastValidOffsetX -Y $script:lastValidOffsetY

    # Live-push (2026-09-08): apply the CHANGE immediately -- same
    # throttled path the drag pad and arrow keys use -- instead of only
    # taking effect on the next Preview click. Invalid input reverted the
    # box above without changing lastValidOffset*, so priorX/Y correctly
    # nets to a zero delta in that case -- no live push happens, matching
    # "invalid input never pushes garbage to the live camera."
    $script:pendingNudgeDeltaX += ($script:lastValidOffsetX - $priorX)
    $script:pendingNudgeDeltaY += ($script:lastValidOffsetY - $priorY)
}
$offsetXBox.Add_LostFocus({ Commit-OffsetBoxes })
$offsetYBox.Add_LostFocus({ Commit-OffsetBoxes })
$offsetXBox.Add_KeyDown({
    param($eventSender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        Commit-OffsetBoxes
        [System.Windows.Input.Keyboard]::ClearFocus()
    }
})
$offsetYBox.Add_KeyDown({
    param($eventSender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        Commit-OffsetBoxes
        [System.Windows.Input.Keyboard]::ClearFocus()
    }
})

# --- Arrow-key / wheel stepping on every numeric box (task48, 2026-10-07) ---
# Up/Down arrows and the mouse wheel step Zoom, Offset X/Y, Tolerance and
# Start/End (and the zoom slider) by the user-approved table in
# rom_launcher_logic.ps1 (Get-NumericFieldSpec): plain / Shift / Ctrl, Ctrl
# wins when both are held. The step MATH is the pure Get-Stepped* functions
# there; everything below is thin wiring that reads the key/modifier state
# and calls the field's explicit-argument Step-* function (same shape as
# Update-OffsetWheelNudge, so tests call them directly with a direction and
# modifier flags, the same way they already test the wheel).
#
# "Commit then step": if the box holds typed-but-uncommitted text, the
# field's own existing commit runs first (garbage reverts, as always), and
# the step starts from that committed value. Only Up/Down (and the wheel)
# are intercepted -- digits, Left/Right, Home/End, Backspace, Tab and Enter
# are untouched, so typing, caret movement and the Enter/LostFocus commits
# behave exactly as before.
#
# Every write goes through the field's EXISTING write path (slider
# ValueChanged for Zoom, the wheel session for X/Y, Write-CameraTolerancePct
# for Tolerance), so the state files keep today's exact formats.

# Zoom: steps the slider's Value, so the one ValueChanged handler above still
# formats the box and writes the file. While keys/wheel keep arriving the Maya
# push is held back (same flag a thumb drag uses) and fires ONCE, 400 ms after
# the last step (like the wheel on X/Y) -- a timer, not KeyUp, so a missed
# KeyUp (Alt-Tab mid-hold) can never leave live zoom stuck off.
$script:zoomStepActive = $false
$script:zoomStepStartPct = 0.0
$script:zoomStepSettleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:zoomStepSettleTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:zoomStepSettleTimer.Add_Tick({ Stop-ZoomStep })

function Start-ZoomStepHold {
    # Own the push-hold until the settle timer fires, unless a real thumb drag
    # already holds it; (re)starts the settle either way while a session runs.
    if (-not $script:zoomStepActive -and -not $script:zoomSliderDragging) {
        $script:zoomStepActive = $true
        $script:zoomStepStartPct = [Math]::Round($zoomSlider.Value)
        $script:zoomSliderDragging = $true
    }
    if ($script:zoomStepActive) {
        $script:zoomStepSettleTimer.Stop()
        $script:zoomStepSettleTimer.Start()
    }
}
function Step-ZoomValue([int]$Direction, [bool]$ShiftHeld, [bool]$CtrlHeld) {
    # task48 F4: the push-hold is taken through Start-ZoomStepHold, which
    # starts the settle timer at the same moment, so nothing after it (the
    # commit below included) can leave the hold set with no settle pending.
    # The commit stays inside the held burst: one Maya push for the whole burst.
    Start-ZoomStepHold
    Commit-ZoomValueBox
    $current = [Math]::Round($zoomSlider.Value)
    $zoomSlider.Value = Get-SteppedNumber -Current $current -Direction $Direction -Field "Zoom" -Shift $ShiftHeld -Ctrl $CtrlHeld
    if ($script:zoomStepActive) {
        $script:zoomStepSettleTimer.Stop()
        $script:zoomStepSettleTimer.Start()
    }
}
function Stop-ZoomStep {
    $script:zoomStepSettleTimer.Stop()
    if (-not $script:zoomStepActive) { return }
    $script:zoomStepActive = $false
    # task48 F3: a thumb drag that started during the settle keeps its hold,
    # and its own completion does the one push -- none from here mid-drag.
    if ($script:zoomThumbDragging) { return }
    $script:zoomSliderDragging = $false
    # One push for the whole burst, and none at all if it ended where it began.
    if ([Math]::Round($zoomSlider.Value) -ne $script:zoomStepStartPct) {
        $script:pendingZoomPush = $true
    }
}

# Offset X/Y: reuses the existing wheel session (live box text, ONE push after
# the 400 ms settle, axis-switch flush) with Up = +1 notch, Down = -1 notch.
function Step-OffsetBox([string]$Axis, [int]$Direction, [bool]$ShiftHeld, [bool]$CtrlHeld) {
    $box = if ($Axis -eq "X") { $offsetXBox } else { $offsetYBox }
    if ($script:wheelNudgeAxis -ne $null -and $script:wheelNudgeAxis -ne $Axis) {
        Stop-OffsetWheelNudge
    }
    # Typed text is only committed when no session is running on this axis:
    # mid-session the box shows the session's live value, which is not typed
    # input (committing it would double-count the delta).
    if ($script:wheelNudgeAxis -eq $null) {
        $committed = if ($Axis -eq "X") { $script:lastValidOffsetX } else { $script:lastValidOffsetY }
        if ($box.Text.Trim() -ne "$committed") { Commit-OffsetBoxes }
    }
    Update-OffsetWheelNudge -Axis $Axis -Delta ($Direction * 120) -ShiftHeld $ShiftHeld -CtrlHeld $CtrlHeld
}

# Tolerance: from Auto, start from Auto's current value (percent, from Zoom;
# 2.0 with the gate OFF) and step; Down at 0 stays 0 (no wrap to Auto --
# clearing the box returns to Auto). No Maya push: the keyer and the
# glow/readout read the file.
function Get-AutoEffectiveTolerancePct {
    # task48 F1: Auto's value is the keyer's own zoom-only formula with the
    # gate ON, and the fixed 2.0 warning threshold with the gate OFF
    # (Get-AutoTolFromZoom) -- no cache needed, and no longer the glow's
    # offset-aware mirror, which is not what the keyer uses.
    return (Get-AutoTolFromZoom -ZoomPct ([Math]::Round($zoomSlider.Value)) -GateOn ([bool]$frameGateCheckBox.IsChecked))
}
function Step-ToleranceBox([int]$Direction, [bool]$ShiftHeld, [bool]$CtrlHeld) {
    $displayed = if ($null -eq $script:lastValidTolerancePct) { 'Auto' } else { "$($script:lastValidTolerancePct)" }
    if ($toleranceValueBox.Text.Trim() -ne $displayed) { Commit-ToleranceValueBox }
    $current = $script:lastValidTolerancePct
    $autoPct = if ($null -eq $current) { Get-AutoEffectiveTolerancePct } else { $null }
    $new = Get-SteppedTolerance -CurrentPct $current -AutoEffectivePct $autoPct -Direction $Direction -Shift $ShiftHeld -Ctrl $CtrlHeld
    $script:lastValidTolerancePct = $new
    $toleranceValueBox.Text = "$new"
    Write-CameraTolerancePct -Value $new
    Update-ToleranceVisual
}

# Start/End: steps the whole number in the box. Non-numeric text: does nothing
# (returns $false) -- Start Recording's own check still complains about it.
function Step-FrameBox([string]$Which, [int]$Direction, [bool]$ShiftHeld, [bool]$CtrlHeld) {
    $box = if ($Which -eq "Start") { $startFrameBox } else { $endFrameBox }
    $field = if ($Which -eq "Start") { "StartFrame" } else { "EndFrame" }
    $newText = Get-SteppedFrameText -Text $box.Text -Direction $Direction -Field $field -Shift $ShiftHeld -Ctrl $CtrlHeld
    if ($null -eq $newText) { return $false }
    $box.Text = $newText
    return $true
}

# One entry point per field name: Zoom, OffsetX, OffsetY, Tolerance, StartFrame,
# EndFrame. After a step the box text is selected (when the box has keyboard
# focus) so the caret does not jump to the start and typing replaces the value.
function Invoke-NumericStep([string]$Field, [int]$Direction, [bool]$ShiftHeld, [bool]$CtrlHeld) {
    switch ($Field) {
        "Zoom"       { Step-ZoomValue $Direction $ShiftHeld $CtrlHeld; $box = $zoomValueBox }
        "OffsetX"    { Step-OffsetBox "X" $Direction $ShiftHeld $CtrlHeld; $box = $offsetXBox }
        "OffsetY"    { Step-OffsetBox "Y" $Direction $ShiftHeld $CtrlHeld; $box = $offsetYBox }
        "Tolerance"  { Step-ToleranceBox $Direction $ShiftHeld $CtrlHeld; $box = $toleranceValueBox }
        "StartFrame" { Step-FrameBox "Start" $Direction $ShiftHeld $CtrlHeld | Out-Null; $box = $startFrameBox }
        "EndFrame"   { Step-FrameBox "End" $Direction $ShiftHeld $CtrlHeld | Out-Null; $box = $endFrameBox }
        default      { throw "Unknown numeric field '$Field'" }
    }
    if ($box.IsKeyboardFocusWithin) { $box.SelectAll() }
}

# Event glue. Preview (tunnelling) so Up/Down are claimed before the TextBox
# or Slider can do anything of their own with them; anything else returns
# $false untouched.
function Invoke-NumericStepKey([string]$Field, $e) {
    if ($e.Key -ne [System.Windows.Input.Key]::Up -and $e.Key -ne [System.Windows.Input.Key]::Down) { return $false }
    $mods = Get-CurrentModifierKeys
    $shiftHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ctrlHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $direction = if ($e.Key -eq [System.Windows.Input.Key]::Up) { 1 } else { -1 }
    Invoke-NumericStep $Field $direction $shiftHeld $ctrlHeld
    $e.Handled = $true
    return $true
}
function Invoke-NumericStepWheel([string]$Field, $e) {
    if ($e.Delta -eq 0) { return $false }
    $mods = Get-CurrentModifierKeys
    $shiftHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ctrlHeld = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $direction = if ($e.Delta -gt 0) { 1 } else { -1 }
    Invoke-NumericStep $Field $direction $shiftHeld $ctrlHeld
    $e.Handled = $true
    return $true
}

$zoomValueBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "Zoom" $e | Out-Null })
# task48 F6: the slider's OWN Left/Right/PageUp/PageDown/Home/End keys (not
# claimed here -- the slider still moves itself) now join the same push-hold
# and 400 ms settle as Up/Down, so a held key pushes to Maya once, not per press.
function Test-ZoomSliderNativeKey([System.Windows.Input.Key]$Key) {
    return @([System.Windows.Input.Key]::Left, [System.Windows.Input.Key]::Right, [System.Windows.Input.Key]::PageUp,
             [System.Windows.Input.Key]::PageDown, [System.Windows.Input.Key]::Home, [System.Windows.Input.Key]::End) -contains $Key
}
$zoomSlider.Add_PreviewKeyDown({
    param($eventSender, $e)
    if (Invoke-NumericStepKey "Zoom" $e) { return }
    if (Test-ZoomSliderNativeKey $e.Key) { Start-ZoomStepHold }
})
$offsetXBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "OffsetX" $e | Out-Null })
$offsetYBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "OffsetY" $e | Out-Null })
$toleranceValueBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "Tolerance" $e | Out-Null })
$startFrameBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "StartFrame" $e | Out-Null })
$endFrameBox.Add_PreviewKeyDown({ param($eventSender, $e); Invoke-NumericStepKey "EndFrame" $e | Out-Null })

# The wheel: X/Y already have theirs (above, now with Ctrl-fine); the rest get
# the same steps and modifiers as the arrows.
$zoomValueBox.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "Zoom" $e | Out-Null })
$zoomSlider.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "Zoom" $e | Out-Null })
$toleranceValueBox.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "Tolerance" $e | Out-Null })
# Tolerance cell (task48 rebuild): the wheel anywhere over the diagram or the
# cap steps the number exactly like over the box (it tunnels through here
# first, so a wheel over the box itself still steps once, not twice). The
# diagram is display-only: no focus, no click action, no Tab stop.
$toleranceCell.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "Tolerance" $e | Out-Null })
# Clicking anywhere on the cap (its padding, the "%") focuses the number box;
# clicks on the box itself are left to the box (caret, selection).
function Set-ToleranceBoxFocus { [void]$toleranceValueBox.Focus() }
# PreviewMouseDown (a true tunnelling event), not PreviewMouseLeftButtonDown,
# which WPF re-raises per element as a Direct event.
$tolNumberCap.Add_PreviewMouseDown({
    param($eventSender, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    $src = $e.OriginalSource
    if ($src -eq $toleranceValueBox -or ($src -is [System.Windows.Media.Visual] -and $toleranceValueBox.IsAncestorOf($src))) { return }
    Set-ToleranceBoxFocus
    $e.Handled = $true
})
$startFrameBox.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "StartFrame" $e | Out-Null })
$endFrameBox.Add_PreviewMouseWheel({ param($eventSender, $e); Invoke-NumericStepWheel "EndFrame" $e | Out-Null })

# Resolves whichever Time Range mode is currently selected (All / Time
# Slider / Start-End) into concrete Start/End frame numbers, WITHOUT
# building a step list. Factored out of Get-CaptureClickResult (2026-09-02)
# so Preview's own click handler can resolve just the Start frame for
# "Recenter at start frame" without duplicating this per-mode logic, and so
# Start Recording's recentering reuses the SAME resolution
# Get-CaptureClickResult already makes for real, rather than paying for a
# second Maya round trip.
function Get-ResolvedTimeRange {
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
            return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Could not read Maya's animation range: $($range.ErrorMessage)" }
        }
        if ($range.Start -gt $range.End) {
            return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Maya's animation range is invalid (Start $($range.Start) > End $($range.End))" }
        }
        return [PSCustomObject]@{ Success = $true; Start = $range.Start; End = $range.End; ErrorMessage = $null }
    }

    if ($timeSliderRadio.IsChecked) {
        $range = Get-TimeSliderRange
        if (-not $range.Success) {
            return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Could not read Maya's Time Slider range: $($range.ErrorMessage)" }
        }
        if ($range.Start -gt $range.End) {
            return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Maya's Time Slider range is invalid (Start $($range.Start) > End $($range.End))" }
        }
        # task48 rebuild: remembered for the Estimated line / Tolerance bar,
        # which can never query Maya on their 60 ms tick (Get-EstimateRange).
        $script:lastTimeSliderRangeStart = $range.Start
        $script:lastTimeSliderRangeEnd = $range.End
        return [PSCustomObject]@{ Success = $true; Start = $range.Start; End = $range.End; ErrorMessage = $null }
    }

    # Start/End (manual entry)
    $parsedStart = 0
    $parsedEnd = 0
    $startOk = [int]::TryParse($startFrameBox.Text, [ref]$parsedStart)
    $endOk = [int]::TryParse($endFrameBox.Text, [ref]$parsedEnd)
    if (-not $startOk -or -not $endOk) {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Start/End must be whole numbers (got '$($startFrameBox.Text)' / '$($endFrameBox.Text)')" }
    }
    if ($parsedStart -gt $parsedEnd) {
        return [PSCustomObject]@{ Success = $false; Start = $null; End = $null; ErrorMessage = "Start ($parsedStart) must not be greater than End ($parsedEnd)" }
    }
    return [PSCustomObject]@{ Success = $true; Start = $parsedStart; End = $parsedEnd; ErrorMessage = $null }
}

# Reads the real WPF controls' current values (and, for Time Slider/All,
# makes a real bounded round-trip to Maya) but returns a result object
# instead of starting anything -- lets tests verify the Time Range
# validation without ever calling Start-Steps (which would launch real
# send_to_maya.ps1/maya_obs_capture.ps1 processes against whatever's live
# in Maya right now).
function Get-CaptureClickResult {
    $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    $range = Get-ResolvedTimeRange
    if (-not $range.Success) {
        return [PSCustomObject]@{ Steps = $null; ErrorMessage = "$($range.ErrorMessage) -- not starting."; ResolvedStart = $null; ResolvedEnd = $null }
    }
    $steps = Get-CaptureStepsForAxis -Axis $axis -Recording $true -ScriptDir $ScriptDir -StartFrame $range.Start -EndFrame $range.End
    # ResolvedStart: so a caller wanting "Recenter at start frame" can reuse
    # THIS resolution (a real Maya round trip for Time Slider/All) instead
    # of paying for a second one just to find the same number again.
    # ResolvedEnd (2026-09-28): same reasoning, added for the Frame gate
    # OFF clipping estimate -- its click-time prompt needs the exact
    # resolved range, not just the Start, and must not pay for a second
    # Get-ResolvedTimeRange round trip to get it.
    return [PSCustomObject]@{ Steps = $steps; ErrorMessage = $null; ResolvedStart = $range.Start; ResolvedEnd = $range.End }
}

$previewButton.Add_Click({
    # No toggle here -- Preview is a fast, one-shot action (matches
    # pre-Stop-feature behavior). It just disables like any other inactive
    # button while something runs; only Start Recording's own run makes
    # PreviewButton clickable-but-inert-while-disabled the normal way.
    $axis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
    # With All selected Preview shows the FIRST leg (Front/Back) only (user
    # decision 2026-09-24, option b) -- the two panel sets cannot coexist
    # (each panel script closes all four claude_view_* windows), so a
    # two-leg preview would only ever leave Left/Right on screen. Start
    # Recording and the cache build are untouched (they still run both
    # legs). The explanatory log line is queued and written AFTER Start-Steps
    # below, same reason as $recenterLogMessage (Start-Steps clears the log).
    $steps = Get-CaptureStepsForAxis -Axis (Get-PreviewAxis -Axis $axis) -Recording $false -ScriptDir $ScriptDir
    $previewAxisNote = if ($axis -eq "All") { "Preview with All shows the first leg (Front/Back) only -- Start Recording captures both legs." } else { $null }
    # Recenter at start frame (2026-09-02, now mandatory -- no checkbox):
    # Preview normally never resolves a Time Range at all (Start/End only
    # ever applied to Start Recording, unchanged) -- this is the one case
    # Preview pays for a real Maya round trip, unconditionally now. A
    # failed resolution is a WARNING, not a hard block (Preview has no
    # other blocking gate either): log it and preview without recentering
    # rather than refusing to preview at all. Either message is queued
    # into $recenterLogMessage and logged AFTER Start-Steps below, not
    # here -- Start-Steps clears the log box as one of its own first
    # actions (confirmed live: logging here got silently wiped the instant
    # Start-Steps ran, so the user would never actually have seen it --
    # this was a real bug, not just missing feedback: nothing ever
    # confirmed the resolved Start frame, which read as "not calculated"
    # even on runs where it was).
    $recenterLogMessage = $null
    $range = Get-ResolvedTimeRange
    if ($range.Success) {
        Write-RecenterStartFrame -Frame $range.Start
        $recenterLogMessage = "Recenter at start frame: resolved Start=$($range.Start) -- framing measured there."
    } else {
        $recenterLogMessage = "Recenter at start frame: could not resolve the current Time Range ($($range.ErrorMessage)) -- previewing without recentering."
        Clear-RecenterStartFrame
    }
    # Preview silently triggers a cache build itself when one doesn't
    # exist yet (see the guide text) -- flagging this so the Cache status
    # dot/label refresh once that finishes, instead of staying stuck on
    # whatever it showed (or never showed) before this click.
    $script:pendingCacheRefresh = $true
    Start-Steps $steps
    if ($recenterLogMessage) { Write-Log $recenterLogMessage }
    if ($previewAxisNote) { Write-Log $previewAxisNote }
})

$startRecordingButton.Add_Click({
    # This is the one button that toggles into Stop -- matches OBS's own
    # Start/Stop Recording button, since this is the one long-running
    # recording action a user would actually want to interrupt mid-flight.
    if ($script:currentProcess -ne $null -and $script:activeButton -eq $startRecordingButton) {
        Stop-CurrentRun
        return
    }
    # Hard-block gate (design confirmed 2026-08-22): none of these three
    # are things a recording could succeed without, so failing any of them
    # stops the click here with an actionable prompt instead of starting a
    # run that's doomed to fail partway through. Update-PortStatusIndicator
    # is called fresh, not read from the last poll, since a recording is
    # long enough to be worth a genuinely current answer; the other two are
    # already cheap/local.
    $mayaReachable = Update-PortStatusIndicator
    $obsConfigured = (Get-ObsPasswordStatus).Configured
    $monitorSelected = Test-RecordingMonitorSelected
    $requirementFailures = Get-StartRecordingRequirementFailures -MayaReachable $mayaReachable -ObsPasswordConfigured $obsConfigured -MonitorSelected $monitorSelected
    if ($requirementFailures.Count -gt 0) {
        Write-Log "Start Recording blocked: $($requirementFailures.Count) requirement(s) not met."
        Show-DarkNotice -Title "Cannot Start Recording" -Message ("Fix the following before starting a recording:`n`n" + ($requirementFailures -join "`n`n"))
        return
    }
    # Frame-gate warning (2026-09-08): a SOFT gate, unlike the hard-block
    # checks above -- amber alone never blocks (matches Preview's glow-only
    # treatment), only the zero-tolerance floor does, and only with an
    # explicit override, not a silent refusal. Gate ON: unchanged (Q-ON) --
    # this exact check, untouched. Gate OFF: this zero-margin test has no
    # meaning at all (edge_guard never runs), so it's skipped entirely and
    # replaced by the clipping-estimate check below, AFTER the resolved
    # range is known.
    $frameGateLogMessage = $null
    if ($frameGateCheckBox.IsChecked) {
        $frameGateEffective = Get-FrameGateEffectiveOverflowPct
        if ($frameGateEffective -ne $null -and $frameGateEffective -le 1e-6) {
            $proceedAnyway = Show-DarkConfirm -Title "Framing Warning" -ConfirmLabel "Continue Anyway" -Message "Your current Zoom/Offset leaves zero safe tracking margin -- the widest pose may clip, or the camera may move erratically to compensate.`n`nContinue anyway?"
            if (-not $proceedAnyway) {
                Write-Log "Start Recording cancelled: framing warning not confirmed."
                return
            }
        }
    }
    $result = Get-CaptureClickResult
    if ($result.ErrorMessage -ne $null) {
        Write-Log $result.ErrorMessage
        return
    }
    # Gate OFF clipping check (2026-09-28): needs the RESOLVED range (Q-rng:
    # "the click-time prompt uses the resolved range"), so this runs here,
    # after Get-CaptureClickResult, not alongside the ON-mode check above.
    # Soft gate too, same as ON: only prompts past the worst-overflow
    # threshold (Success Criterion 5: "prompt only when W > 2%" by default,
    # or the manual Tolerance value if set -- Q4: reuse), P never gates it.
    # Message queued into $frameGateLogMessage and written AFTER
    # Start-Steps below, same reason as $recenterLogMessage (Start-Steps
    # clears the log box).
    if (-not $frameGateCheckBox.IsChecked) {
        $offAxis = if ($allAxisRadio.IsChecked) { "All" } elseif ($frontBackRadio.IsChecked) { "FrontBack" } else { "LeftRight" }
        $offEstimate = Get-ClippingEstimate -Axis $offAxis -ZoomPct $zoomSlider.Value -OffsetXPx $script:lastValidOffsetX -RangeStart $result.ResolvedStart -RangeEnd $result.ResolvedEnd
        $offThreshold = Get-ClippingWarningThresholdPct
        if ($offEstimate -ne $null) {
            $offP = [Math]::Round($offEstimate.PercentClipped, 1)
            $offW = [Math]::Round($offEstimate.WorstOverflowPct, 1)
            if ($offEstimate.WorstOverflowPct -gt $offThreshold) {
                $proceedAnyway = Show-DarkConfirm -Title "Clipping Warning" -ConfirmLabel "Continue Anyway" -Message "Frame gate is OFF, so the camera stays fixed for the whole take.`n`nAt your current Zoom/Offset the character leaves the frame on about $offP% of frames, by up to $offW% of the frame width -- those parts will be cut off in the recording.`n`nLower the Zoom or turn Frame gate back on to reduce this.`n`nContinue anyway?"
                if (-not $proceedAnyway) {
                    Write-Log "Start Recording cancelled: clipping warning not confirmed."
                    return
                }
            }
            $frameGateLogMessage = "Frame gate OFF: fixed camera, estimated clipping $offP% of frames (worst $offW% of frame width)."
        }
    }
    # Recenter at start frame (2026-09-02, now mandatory -- no checkbox):
    # reuses Get-CaptureClickResult's OWN range resolution (ResolvedStart)
    # rather than a second Maya round trip -- that resolution already
    # succeeded or this would have returned above, so there is no failure
    # path to handle here (unlike Preview, which has no other gate).
    # Logged AFTER Start-Steps below (same reasoning as Preview's own
    # click handler) since Start-Steps clears the log box as one of its
    # own first actions.
    Write-RecenterStartFrame -Frame $result.ResolvedStart
    $recenterLogMessage = "Recenter at start frame: resolved Start=$($result.ResolvedStart) -- framing measured there."
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
    if ($recenterLogMessage) { Write-Log $recenterLogMessage }
    if ($frameGateLogMessage) { Write-Log $frameGateLogMessage }
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
            ImagePath = Join-Path $ScriptDir "guide_images\guide_settings_tab.png"
            Steps = @(
                @{ Lead = "Maya connection:"; Text = "green means ready. If red/gray, click the clipboard icon to copy the setup snippet, paste it into Maya's Script Editor (Python tab), and run it." },
                @{ Lead = "Cache button:"; Text = "click checks whether a cache already exists. If not, it asks permission to build one right there (10-16 minutes, one-time). Right-click for `"Force Rebuild`" if the character or animation changed without renaming its file, since a plain check can't tell that apart from an up-to-date cache." },
                @{ Lead = "OBS WebSocket password:"; Text = "in OBS Studio, go to Tools > WebSocket Server Settings, check `"Enable WebSocket Server`" if it isn't already, then click Show Connect Info to reveal the password. Click the key icon here and paste it in -- a one-time setup per machine." },
                @{ Lead = "Recording Monitor:"; Text = "which physical monitor OBS records, auto-detected from OBS's active scene. Only needs changing if you plug in a different monitor setup or switch machines." }
            )
        },
        [PSCustomObject]@{
            Header = "CAPTURE (what you use every run, its own tab)"
            ImagePath = Join-Path $ScriptDir "guide_images\guide_capture_tab.png"
            Steps = @(
                @{ Lead = "Pick an Axis:"; Text = "Front/Back, Left/Right, or All (Front/Back then Left/Right, recorded as two separate videos -- Preview with All shows Front/Back only)." },
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
    $mayaPortSteps = "1. In Maya, open the Script Editor (the icon at the bottom-right of the status line, or Windows > General Editors > Script Editor)`n2. Click the Python tab`n3. Paste the snippet -- already copied to your clipboard`n4. Click Execute All (or press Ctrl+Enter) to run it`n`nMust be re-run every time Maya is restarted -- the port does not persist across sessions."
    $mayaPortImage = Join-Path $ScriptDir "guide_images\maya_port_setup.jpg"
    Show-DarkNotice -Title "Open Maya's Command Port" -Message $mayaPortSteps -ImagePath $mayaPortImage
})

$obsPasswordButton.Add_Click({
    $current = (Get-ObsPasswordStatus).CurrentPassword
    if ($current -eq "REPLACE_ME") { $current = "" }
    $obsPasswordSteps = "1. Open OBS Studio`n2. Tools > WebSocket Server Settings`n3. Check `"Enable WebSocket Server`" if it isn't already`n4. Click `"Show Connect Info`" to reveal the password (or set one if empty)`n5. Copy it and paste below`n`nEvery machine's OBS has its own independent password."
    $obsPasswordImage = Join-Path $ScriptDir "guide_images\obs_websocket_settings.jpg"
    $newPassword = Show-DarkInput -Title "OBS WebSocket Password" -ConfirmLabel "Save" -InitialValue $current -Message $obsPasswordSteps -Masked -ImagePath $obsPasswordImage
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
# Design (2026-09-02): the magnifier always starts at the safe 0% default,
# never restoring a value left over from an earlier launch -- a forgotten
# non-zero magnifier should never silently carry into a future session and
# risk clipping. Sets the box text and writes the file explicitly rather
# than assigning $zoomSlider.Value = 0 -- the slider's XAML default is
# already 0, so that assignment would be a same-value no-op and its own
# ValueChanged handler (the thing that normally updates the box text and
# writes the file) would never fire, leaving the box blank and any stale
# non-zero file from a past session in place.
$zoomValueBox.Text = "0"
Write-CameraZoomPct -Value 0
# Same reasoning as the magnifier just above: pixel offset always starts
# at 0,0 too, never restoring a forgotten value from an earlier launch.
$offsetXBox.Text = "0"
$offsetYBox.Text = "0"
$script:lastValidOffsetX = 0
$script:lastValidOffsetY = 0
$script:dragOffsetX = 0
$script:dragOffsetY = 0
Write-CameraOffsetPx -X 0 -Y 0
# Recenter at start frame is mandatory now (no checkbox) -- Preview/Start
# Recording always resolve and write a fresh value at click time, but
# clear it here too so nothing stale from a past session could apply if a
# scene were somehow opened and captured through some OTHER path first.
Clear-RecenterStartFrame
# Frame gate always starts checked (2026-09-28) -- same "never silently
# restore a forgotten value" rule as Zoom/Offset/Recenter above. Written
# explicitly, not just via IsChecked = $true: the XAML default is ALREADY
# True, so that assignment alone would be a same-value no-op and its own
# Add_Checked handler (the thing that normally writes the file) would
# never fire -- identical gotcha to the magnifier's own startup reset just
# above (see its comment), which is why that one calls Write-CameraZoomPct
# directly instead of trusting the ValueChanged side effect.
$frameGateCheckBox.IsChecked = $true
Write-FrameGateEnabled -Enabled $true
# Tolerance box always starts at Auto (2026-09-29) -- same rule, same
# "assignment alone is a same-value no-op" gotcha: Text is already "Auto"
# in the XAML, so this also writes the file explicitly rather than relying
# on a LostFocus/KeyDown event that never fires from a same-value assign.
$toleranceValueBox.Text = 'Auto'
$script:lastValidTolerancePct = $null
Write-CameraTolerancePct -Value $null
# First draw of the Tolerance bar and the Estimated line (task48 rebuild), so
# neither waits for the first 60 ms tick.
Update-ToleranceReadout
Update-MonitorList
Write-StartupSummary -MayaReachable $script:mayaReachableAtStartup
Set-ActiveTab "Capture"

if (-not $NoShow) {
    $window.ShowDialog() | Out-Null
}

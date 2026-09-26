# Generate-Screenshots.ps1
# Generates high-resolution screenshots of the Agent Collab Controller and Review Diff modal.
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass .\scripts\generate-screenshots.ps1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$outputDir = Join-Path $PSScriptRoot "..\docs\images"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

function Save-VisualToPng {
    param(
        [System.Windows.FrameworkElement]$element,
        [string]$filePath,
        [int]$width = 1080,
        [int]$height = 860
    )
    $element.Measure([System.Windows.Size]::new($width, $height))
    $element.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
    $element.UpdateLayout()

    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $rtb.Render($element)

    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $stream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Create)
    $encoder.Save($stream)
    $stream.Close()
    Write-Host "Exported: $filePath ($((Get-Item $filePath).Length) bytes)"
}

# --- 1. Main Controller Window ---
$mainXaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#181825" CornerRadius="8" BorderBrush="#313244" BorderThickness="1"
        Width="1080" Height="860" TextElement.FontFamily="Segoe UI">
    <Border.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#CDD6F4"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1E1E2E"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#E6E9EF"/>
            <Setter Property="Foreground" Value="#11111B"/>
            <Setter Property="BorderBrush" Value="#89B4FA"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#F2F4F8"/>
            <Setter Property="Foreground" Value="#11111B"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,4"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="Margin" Value="0,0,12,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="Margin" Value="0,0,12,0"/>
        </Style>
    </Border.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Title Bar -->
            <RowDefinition Height="*"/>    <!-- Main Body -->
        </Grid.RowDefinitions>

        <!-- Title Bar Simulation -->
        <Border Grid.Row="0" Background="#11111B" CornerRadius="8,8,0,0" Padding="12,8" BorderBrush="#313244" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🎮" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Agent Collab Controller - v1.2.2" FontWeight="SemiBold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="11" Height="11" CornerRadius="6" Background="#A6E3A1" Margin="0,0,6,0" ToolTip="Minimize"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F9E2AF" Margin="0,0,6,0" ToolTip="Maximize"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F38BA8" ToolTip="Close"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Main Body -->
        <Grid Grid.Row="1" Margin="12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/> <!-- 0: Header & Presets -->
                <RowDefinition Height="Auto"/> <!-- 1: Stoplight & Phase -->
                <RowDefinition Height="Auto"/> <!-- 2: Roles & Issue Tracker -->
                <RowDefinition Height="130"/>  <!-- 3: Objective, Alignment & Human Steering Notes -->
                <RowDefinition Height="185"/>  <!-- 4: Cursor | Gemini last-response panes -->
                <RowDefinition Height="Auto"/> <!-- 5: Agent Kickoff & Re-prompting -->
                <RowDefinition Height="Auto"/> <!-- 6: Actions -->
                <RowDefinition Height="Auto"/> <!-- 7: Status -->
            </Grid.RowDefinitions>

            <!-- 0: Header Bar & Quick Workflow Presets -->
            <Grid Grid.Row="0" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡ Presets:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <Border Background="#313244" CornerRadius="4" Padding="8,4" Margin="0,0,4,0">
                        <TextBlock Text="🛠️ Implement" FontWeight="SemiBold" FontSize="11" Foreground="#CDD6F4"/>
                    </Border>
                    <Button Content="⚡ Apply" Margin="0,0,6,0" Background="#45475A" Foreground="#89B4FA" FontWeight="SemiBold" Padding="8,3"/>
                    <Button Content="🚀 Promote Align" Background="#313244" Foreground="#A6E3A1" Padding="8,3"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <CheckBox Content="💡 Tooltips" IsChecked="True" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <Button Content="🔄 Update App" Background="#313244" Foreground="#89B4FA" Margin="0,0,4,0" Padding="8,3" FontWeight="SemiBold"/>
                    <Button Content="⏭️ Relaunch" Background="#313244" Foreground="#BAC2DE" Margin="0,0,8,0" Padding="8,3"/>
                    <Border Background="#45475A" CornerRadius="12" Padding="10,3">
                        <TextBlock Text="Human (Lead)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1"/>
                    </Border>
                </StackPanel>
            </Grid>

            <!-- 1: Stoplight Flow Control & Phase Selector -->
            <Border Grid.Row="1" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🚦 Flow Control:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,12,0"/>
                        <RadioButton Content="🟢 GO" IsChecked="True" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                        <RadioButton Content="🟡 PAUSE" Foreground="#F9E2AF" VerticalAlignment="Center"/>
                        <RadioButton Content="🔴 ALL STOP" Foreground="#F38BA8" VerticalAlignment="Center"/>
                    </StackPanel>

                    <Border Grid.Column="1" Background="#11111B" CornerRadius="4" Padding="8,3" Margin="8,0,8,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Center" HorizontalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="📋 Board: " FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
                            <TextBlock Text="C:\Users\dev\my-project\.ai\blackboard.md" FontSize="10" Foreground="#89B4FA" FontFamily="Consolas, monospace" VerticalAlignment="Center"/>
                            <Button Content="📂 Switch" FontSize="10" Padding="6,1" Margin="8,0,0,0" Background="#313244" Foreground="#BAC2DE"/>
                        </StackPanel>
                    </Border>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="📍 Project Phase:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <Border Background="#313244" CornerRadius="4" Padding="10,4">
                            <TextBlock Text="implement (Active Coding)" FontWeight="SemiBold" FontSize="11" Foreground="#A6E3A1"/>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 2: Agent Roles, Sign-off, & Issue Tracker Card -->
            <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="1.1*"/>
                        <ColumnDefinition Width="1.1*"/>
                    </Grid.ColumnDefinitions>

                    <!-- AI 1 Role -->
                    <StackPanel Grid.Column="0" Margin="0,0,6,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="AI 1 Role" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" VerticalAlignment="Center"/>
                            <Border Grid.Column="1" Background="#313244" CornerRadius="3" Padding="6,1">
                                <TextBlock Text="Cursor" FontSize="10" Foreground="#89B4FA" FontWeight="Bold"/>
                            </Border>
                        </Grid>
                        <Border Background="#313244" CornerRadius="4" Padding="8,5">
                            <TextBlock Text="implement" FontWeight="Bold" Foreground="#A6E3A1" FontSize="12"/>
                        </Border>
                    </StackPanel>

                    <!-- AI 2 Role -->
                    <StackPanel Grid.Column="1" Margin="6,0,6,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="AI 2 Role" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                            <Border Grid.Column="1" Background="#313244" CornerRadius="3" Padding="6,1">
                                <TextBlock Text="Antigravity" FontSize="10" Foreground="#A6E3A1" FontWeight="Bold"/>
                            </Border>
                        </Grid>
                        <Border Background="#313244" CornerRadius="4" Padding="8,5">
                            <TextBlock Text="review" FontWeight="Bold" Foreground="#89B4FA" FontSize="12"/>
                        </Border>
                    </StackPanel>

                    <!-- Completion Sign-offs -->
                    <StackPanel Grid.Column="2" Margin="6,0,6,0">
                        <TextBlock Text="Project Sign-off" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                            <CheckBox Content="Human" Margin="0,0,8,0" Foreground="#BAC2DE"/>
                            <CheckBox Content="AI 1" Margin="0,0,8,0" Foreground="#BAC2DE"/>
                            <CheckBox Content="AI 2" Foreground="#BAC2DE"/>
                        </StackPanel>
                    </StackPanel>

                    <!-- GitHub Issue Tracker -->
                    <StackPanel Grid.Column="3" Margin="6,0,0,0">
                        <TextBlock Text="GitHub Issue #" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" Margin="0,0,0,4"/>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox Text="#42" VerticalContentAlignment="Center" FontWeight="Bold" Foreground="#89B4FA"/>
                            <Button Grid.Column="1" Content="🔍" Margin="4,0,0,0" Padding="5,2"/>
                            <Button Grid.Column="2" Content="➕" Margin="2,0,0,0" Padding="5,2"/>
                        </Grid>
                        <TextBlock Text="Add token-bucket rate limiting middleware" FontSize="10" Foreground="#A6ADC8" Margin="0,2,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 3: Objective, Alignment & Human Steering Notes -->
            <Grid Grid.Row="3" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Objective & Prompt -->
                <Border Grid.Column="0" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="📝 CURRENT OBJECTIVE &amp; PROMPT" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,4"/>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="Implement token-bucket rate limiting middleware on public API routes (/api/v1/auth, /api/v1/query). Support configurable burst capacity and refill rate per client IP."/>
                    </Grid>
                </Border>

                <!-- Alignment & Constraints -->
                <Border Grid.Column="1" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="🤝 ALIGNMENT &amp; DECISIONS" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,4"/>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="- Concurrency safety: thread-safe token bucket using ConcurrentDictionary.&#x0a;- Max 1 implement agent: Cursor owns middleware &amp; test code.&#x0a;- Reviewer: Antigravity verifies edge cases &amp; test matrix."/>
                    </Grid>
                </Border>

                <!-- Human Steering Notes -->
                <Border Grid.Column="2" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="👑 HUMAN STEERING NOTES" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center"/>
                            <Button Grid.Column="1" Content="📝 Promote to Prompt" Background="#313244" Foreground="#F9E2AF" Padding="5,1" FontSize="9"/>
                        </Grid>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="- Priority: protect /api/v1/auth from brute-force attempts.&#x0a;- Default limit: 60 req/min with burst allowance of 10.&#x0a;- Include unit tests before 3-way sign-off."/>
                    </Grid>
                </Border>
            </Grid>

            <!-- 4: AI 1 | AI 2 Response Panes -->
            <Grid Grid.Row="4" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Background="#181825" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="💠 AI 1 LAST RESPONSE (Cursor)" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,6"/>
                        <Border Grid.Row="1" Background="#11111B" CornerRadius="6" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="- implement (rate limiter): Sign-off: [ ]" FontWeight="Bold" Foreground="#89B4FA" Margin="0,0,0,4" FontFamily="Consolas" FontSize="12"/>
                                <TextBlock Text="  • Created TokenBucketRateLimiter.cs with sliding-window refill logic." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Added unit test suite RateLimiterTests.cs with 14 passing test assertions." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Benchmarked throughput: ~4.2M acquires/sec under concurrent stress." Foreground="#A6E3A1" FontFamily="Segoe UI" FontSize="12"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <Border Grid.Column="1" Background="#181825" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="🪐 AI 2 LAST RESPONSE (Antigravity)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,6"/>
                        <Border Grid.Row="1" Background="#11111B" CornerRadius="6" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="- review (code audit): Sign-off: [ ]" FontWeight="Bold" Foreground="#A6E3A1" Margin="0,0,0,4" FontFamily="Consolas" FontSize="12"/>
                                <TextBlock Text="  • Audited TokenBucketRateLimiter.cs: thread-safety locks confirmed safe." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Verified burst exhaustion properly returns HTTP 429 Too Many Requests." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Git diff verified cleanly. Ready for Human testing &amp; final sign-off." Foreground="#F9E2AF" FontFamily="Segoe UI" FontSize="12"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>
            </Grid>

            <!-- 5: Agent Kickoff & Prompt Automation Card -->
            <Border Grid.Row="5" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🚀 Kickoff:" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <Button Content="📋 Copy AI 1" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send AI 1" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,3"/>
                        <Button Content="📋 Copy AI 2" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send AI 2" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,3"/>
                        <Button Content="📋 Copy Both" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send Both" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,4,0" Padding="8,3"/>
                        <CheckBox Content="New Chat" VerticalAlignment="Center" Margin="6,0,4,0" Foreground="#A6E3A1"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="⚡ Re-prompt Sync:" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <Button Content="AI 1" Margin="0,0,4,0" Padding="7,3"/>
                        <Button Content="AI 2" Margin="0,0,4,0" Padding="7,3"/>
                        <Button Content="⚡ Both" Background="#45475A" Foreground="#F9E2AF" Padding="8,3"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 6: Action Controls -->
            <Grid Grid.Row="6" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal">
                    <Button Content="💾 Apply Blackboard" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="12,5"/>
                    <Button Content="🏁 Close Project" Background="#313244" Foreground="#A6E3A1" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5"/>
                    <Button Content="🧹 Reset (No Save)" Background="#45475A" Foreground="#CDD6F4" Margin="0,0,6,0" Padding="10,5"/>
                    <Button Content="🔄 Reset (Auto-Save)" Background="#F38BA8" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5"/>
                    <Button Content="📦 Save Snapshot" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="📂 Load State" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="📄 Blackboard Output" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="🔍 Review Diff" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,5"/>
                </StackPanel>

                <Button Grid.Column="1" Content="🕒 Open .ai/history" Background="#313244" Padding="8,5"/>
            </Grid>

            <!-- 7: Status Bar -->
            <Border Grid.Row="7" Background="#11111B" CornerRadius="4" Padding="8,4">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Ready. Working tree changes detected (2 modified, 1 untracked)." FontSize="11" Foreground="#A6ADC8"/>
                    <TextBlock Grid.Column="1" Text="Last write: 2026-09-25 23:14:13" FontSize="11" Foreground="#6C7086"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Border>
"@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($mainXaml))
$mainElement = [System.Windows.Markup.XamlReader]::Load($reader)
Save-VisualToPng -element $mainElement -filePath (Join-Path $outputDir "controller-main-window.png") -width 1080 -height 860


# --- 2. Git Review Diff Modal Window ---
$diffXaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#181825" CornerRadius="8" BorderBrush="#313244" BorderThickness="1"
        Width="920" Height="680" TextElement.FontFamily="Segoe UI">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Title Bar -->
        <Border Grid.Row="0" Background="#11111B" CornerRadius="8,8,0,0" Padding="12,8" BorderBrush="#313244" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🔍" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Git Review Diff - Working Tree vs HEAD" FontWeight="SemiBold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="11" Height="11" CornerRadius="6" Background="#A6E3A1" Margin="0,0,6,0"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F9E2AF" Margin="0,0,6,0"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F38BA8"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Diff Viewer Body -->
        <Grid Grid.Row="1" Margin="12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <Border Grid.Row="0" Background="#1E1E2E" CornerRadius="6" Padding="10,6" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🔍 REVIEW GIT DIFF (Working Tree vs HEAD)" FontWeight="Bold" FontSize="12" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                        <Border Background="#313244" CornerRadius="3" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center">
                            <TextBlock Text="🔒 Read-Only" FontSize="10" Foreground="#BAC2DE"/>
                        </Border>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                        <Border Background="#313244" CornerRadius="4" Padding="10,3" Margin="0,0,6,0">
                            <TextBlock Text="📋 Copy Diff" Foreground="#CDD6F4" FontWeight="SemiBold" FontSize="11"/>
                        </Border>
                        <Border Background="#313244" CornerRadius="4" Padding="10,3">
                            <TextBlock Text="🔄 Refresh" Foreground="#A6E3A1" FontWeight="SemiBold" FontSize="11"/>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Diff Content View -->
            <Border Grid.Row="1" Background="#11111B" CornerRadius="6" BorderBrush="#313244" BorderThickness="1" Padding="12,10">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                    <StackPanel TextElement.FontFamily="Consolas, monospace" TextElement.FontSize="12">
                        <TextBlock Text="=== GIT STATUS (Changed &amp; Untracked Files) ===" FontWeight="Bold" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                        <TextBlock Text=" M src/Middleware/RateLimiter.cs" Foreground="#89B4FA" Margin="0,0,0,2"/>
                        <TextBlock Text="?? tests/RateLimiterTests.cs" Foreground="#A6E3A1" Margin="0,0,0,8"/>

                        <TextBlock Text="=== GIT DIFF (HEAD) ===" FontWeight="Bold" Foreground="#89B4FA" Margin="0,4,0,4"/>
                        <TextBlock Text="--- a/src/Middleware/RateLimiter.cs" Foreground="#CDD6F4"/>
                        <TextBlock Text="+++ b/src/Middleware/RateLimiter.cs" Foreground="#CDD6F4"/>
                        <TextBlock Text="@@ -14,6 +14,24 @@ namespace MyApp.Middleware" Foreground="#CBA6F7" Margin="0,2,0,2"/>
                        <TextBlock Text="+ public class TokenBucketRateLimiter" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ {" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     private readonly ConcurrentDictionary&lt;string, TokenBucket&gt; _buckets = new();" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     private readonly int _capacity;" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     private readonly double _refillRatePerSecond;" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ " Foreground="#A6E3A1"/>
                        <TextBlock Text="+     public bool TryAcquire(string clientIp, int tokens = 1)" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     {" Foreground="#A6E3A1"/>
                        <TextBlock Text="+         var bucket = _buckets.GetOrAdd(clientIp, _ =&gt; new TokenBucket(_capacity));" Foreground="#A6E3A1"/>
                        <TextBlock Text="+         return bucket.Consume(tokens, _refillRatePerSecond);" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     }" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ }" Foreground="#A6E3A1"/>

                        <TextBlock Text="=== UNTRACKED FILES CONTENT ===" FontWeight="Bold" Foreground="#FAB387" Margin="0,10,0,4"/>
                        <TextBlock Text="--- /dev/null" Foreground="#CBA6F7"/>
                        <TextBlock Text="+++ b/tests/RateLimiterTests.cs" Foreground="#CBA6F7"/>
                        <TextBlock Text="+ [Fact]" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ public void BurstCapacity_Exceeded_RejectsFurtherRequests()" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ {" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     var limiter = new TokenBucketRateLimiter(capacity: 5, refillRatePerSecond: 1);" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     for (int i = 0; i &lt; 5; i++) Assert.True(limiter.TryAcquire(&quot;127.0.0.1&quot;));" Foreground="#A6E3A1"/>
                        <TextBlock Text="+     Assert.False(limiter.TryAcquire(&quot;127.0.0.1&quot;));" Foreground="#A6E3A1"/>
                        <TextBlock Text="+ }" Foreground="#A6E3A1"/>
                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- Footer -->
            <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="4" Padding="8,4" Margin="0,6,0,0" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="git diff HEAD: 1 file changed, 24 insertions(+). Untracked: 1 file." FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="git diff HEAD" FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Border>
"@

$diffReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($diffXaml))
$diffElement = [System.Windows.Markup.XamlReader]::Load($diffReader)
Save-VisualToPng -element $diffElement -filePath (Join-Path $outputDir "controller-diff-viewer.png") -width 920 -height 680


# --- 3. Project Sign-Off & Close Window ---
$closeXaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#181825" CornerRadius="8" BorderBrush="#313244" BorderThickness="1"
        Width="1080" Height="860" TextElement.FontFamily="Segoe UI">
    <Border.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#CDD6F4"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1E1E2E"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,4"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="Margin" Value="0,0,12,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="Margin" Value="0,0,12,0"/>
        </Style>
    </Border.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Title Bar -->
            <RowDefinition Height="*"/>    <!-- Main Body -->
        </Grid.RowDefinitions>

        <!-- Title Bar Simulation -->
        <Border Grid.Row="0" Background="#11111B" CornerRadius="8,8,0,0" Padding="12,8" BorderBrush="#313244" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🎮" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Agent Collab Controller - v1.2.2 [Session Verified - 3/3 Sign-offs Complete]" FontWeight="SemiBold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="11" Height="11" CornerRadius="6" Background="#A6E3A1" Margin="0,0,6,0"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F9E2AF" Margin="0,0,6,0"/>
                    <Border Width="11" Height="11" CornerRadius="6" Background="#F38BA8"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Main Body -->
        <Grid Grid.Row="1" Margin="12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/> <!-- 0: Header & Presets -->
                <RowDefinition Height="Auto"/> <!-- 1: Stoplight & Phase -->
                <RowDefinition Height="Auto"/> <!-- 2: Roles & Issue Tracker -->
                <RowDefinition Height="130"/>  <!-- 3: Objective, Alignment & Human Steering Notes -->
                <RowDefinition Height="185"/>  <!-- 4: Cursor | Gemini last-response panes -->
                <RowDefinition Height="Auto"/> <!-- 5: Agent Kickoff & Re-prompting -->
                <RowDefinition Height="Auto"/> <!-- 6: Actions -->
                <RowDefinition Height="Auto"/> <!-- 7: Status -->
            </Grid.RowDefinitions>

            <!-- 0: Header Bar & Quick Workflow Presets -->
            <Grid Grid.Row="0" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡ Presets:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <Border Background="#313244" CornerRadius="4" Padding="8,4" Margin="0,0,4,0">
                        <TextBlock Text="🏁 Closeout" FontWeight="SemiBold" FontSize="11" Foreground="#A6E3A1"/>
                    </Border>
                    <Button Content="⚡ Apply" Margin="0,0,6,0" Background="#45475A" Foreground="#89B4FA" FontWeight="SemiBold" Padding="8,3"/>
                    <Button Content="🚀 Promote Align" Background="#313244" Foreground="#BAC2DE" Padding="8,3"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <CheckBox Content="💡 Tooltips" IsChecked="True" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <Button Content="🔄 Update App" Background="#313244" Foreground="#89B4FA" Margin="0,0,4,0" Padding="8,3" FontWeight="SemiBold"/>
                    <Button Content="⏭️ Relaunch" Background="#313244" Foreground="#BAC2DE" Margin="0,0,8,0" Padding="8,3"/>
                    <Border Background="#45475A" CornerRadius="12" Padding="10,3">
                        <TextBlock Text="Human (Lead)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1"/>
                    </Border>
                </StackPanel>
            </Grid>

            <!-- 1: Stoplight Flow Control & Phase Selector -->
            <Border Grid.Row="1" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🚦 Flow Control:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,12,0"/>
                        <RadioButton Content="🟢 GO" IsChecked="True" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                        <RadioButton Content="🟡 PAUSE" Foreground="#F9E2AF" VerticalAlignment="Center"/>
                        <RadioButton Content="🔴 ALL STOP" Foreground="#F38BA8" VerticalAlignment="Center"/>
                    </StackPanel>

                    <Border Grid.Column="1" Background="#11111B" CornerRadius="4" Padding="8,3" Margin="8,0,8,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Center" HorizontalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="📋 Board: " FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
                            <TextBlock Text="C:\Users\dev\my-project\.ai\blackboard.md" FontSize="10" Foreground="#89B4FA" FontFamily="Consolas, monospace" VerticalAlignment="Center"/>
                            <Button Content="📂 Switch" FontSize="10" Padding="6,1" Margin="8,0,0,0" Background="#313244" Foreground="#BAC2DE"/>
                        </StackPanel>
                    </Border>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="📍 Project Phase:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <Border Background="#313244" CornerRadius="4" Padding="10,4" BorderBrush="#A6E3A1" BorderThickness="1">
                            <TextBlock Text="test (3/3 Verified - Ready to Close)" FontWeight="SemiBold" FontSize="11" Foreground="#A6E3A1"/>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 2: Agent Roles, Sign-off, & Issue Tracker Card -->
            <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="1.1*"/>
                        <ColumnDefinition Width="1.1*"/>
                    </Grid.ColumnDefinitions>

                    <!-- AI 1 Role -->
                    <StackPanel Grid.Column="0" Margin="0,0,6,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="AI 1 Role" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" VerticalAlignment="Center"/>
                            <Border Grid.Column="1" Background="#313244" CornerRadius="3" Padding="6,1">
                                <TextBlock Text="Cursor" FontSize="10" Foreground="#89B4FA" FontWeight="Bold"/>
                            </Border>
                        </Grid>
                        <Border Background="#313244" CornerRadius="4" Padding="8,5">
                            <TextBlock Text="review" FontWeight="Bold" Foreground="#89B4FA" FontSize="12"/>
                        </Border>
                    </StackPanel>

                    <!-- AI 2 Role -->
                    <StackPanel Grid.Column="1" Margin="6,0,6,0">
                        <Grid Margin="0,0,0,4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Text="AI 2 Role" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                            <Border Grid.Column="1" Background="#313244" CornerRadius="3" Padding="6,1">
                                <TextBlock Text="Antigravity" FontSize="10" Foreground="#A6E3A1" FontWeight="Bold"/>
                            </Border>
                        </Grid>
                        <Border Background="#313244" CornerRadius="4" Padding="8,5">
                            <TextBlock Text="review" FontWeight="Bold" Foreground="#A6E3A1" FontSize="12"/>
                        </Border>
                    </StackPanel>

                    <!-- Completion Sign-offs (All Checked!) -->
                    <StackPanel Grid.Column="2" Margin="6,0,6,0">
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                            <TextBlock Text="Project Sign-off" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1"/>
                            <Border Background="#A6E3A1" CornerRadius="3" Padding="4,1" Margin="6,0,0,0">
                                <TextBlock Text="3/3 Complete" FontSize="9" FontWeight="Bold" Foreground="#11111B"/>
                            </Border>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                            <CheckBox Content="Human" IsChecked="True" Margin="0,0,8,0" Foreground="#A6E3A1" FontWeight="Bold"/>
                            <CheckBox Content="AI 1" IsChecked="True" Margin="0,0,8,0" Foreground="#A6E3A1" FontWeight="Bold"/>
                            <CheckBox Content="AI 2" IsChecked="True" Foreground="#A6E3A1" FontWeight="Bold"/>
                        </StackPanel>
                    </StackPanel>

                    <!-- GitHub Issue Tracker -->
                    <StackPanel Grid.Column="3" Margin="6,0,0,0">
                        <TextBlock Text="GitHub Issue #" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" Margin="0,0,0,4"/>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox Text="#42" VerticalContentAlignment="Center" FontWeight="Bold" Foreground="#89B4FA"/>
                            <Border Grid.Column="1" Background="#313244" CornerRadius="3" Padding="6,2" Margin="4,0,0,0" VerticalAlignment="Center">
                                <TextBlock Text="✅ Auto-Close" FontSize="10" Foreground="#A6E3A1" FontWeight="SemiBold"/>
                            </Border>
                        </Grid>
                        <TextBlock Text="Closes automatically via gh CLI on project close" FontSize="9" Foreground="#6C7086" Margin="0,2,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 3: Objective, Alignment & Human Steering Notes -->
            <Grid Grid.Row="3" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Objective & Prompt -->
                <Border Grid.Column="0" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="📝 CURRENT OBJECTIVE &amp; PROMPT" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,4"/>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="Implement token-bucket rate limiting middleware on public API routes (/api/v1/auth, /api/v1/query). Support configurable burst capacity and refill rate per client IP."/>
                    </Grid>
                </Border>

                <!-- Alignment & Constraints -->
                <Border Grid.Column="1" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="🤝 ALIGNMENT &amp; DECISIONS" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,4"/>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="- Concurrency safety: thread-safe token bucket using ConcurrentDictionary.&#x0a;- All tests passing (14 unit tests, 100% route coverage).&#x0a;- All 3 sign-offs complete. Ready to archive tape &amp; close."/>
                    </Grid>
                </Border>

                <!-- Human Steering Notes -->
                <Border Grid.Column="2" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="👑 HUMAN STEERING NOTES" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                        <TextBox Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                                 Text="- Priority test cases validated: brute-force protection works.&#x0a;- Rate limiter benchmarks confirmed under concurrent load.&#x0a;- Verified diff is clean. Approved to close project session."/>
                    </Grid>
                </Border>
            </Grid>

            <!-- 4: AI 1 | AI 2 Response Panes -->
            <Grid Grid.Row="4" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Background="#181825" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="💠 AI 1 LAST RESPONSE (Cursor)" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,6"/>
                        <Border Grid.Row="1" Background="#11111B" CornerRadius="6" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="- test (verification suite): Sign-off: [x]" FontWeight="Bold" Foreground="#A6E3A1" Margin="0,0,0,4" FontFamily="Consolas" FontSize="12"/>
                                <TextBlock Text="  • Ran 14 integration test assertions against TokenBucketRateLimiter." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Verified HTTP 429 status code and Retry-After header semantics." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Review diff clean. Working tree matches expectations. PASS." Foreground="#A6E3A1" FontFamily="Segoe UI" FontSize="12"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <Border Grid.Column="1" Background="#181825" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="🪐 AI 2 LAST RESPONSE (Antigravity)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,6"/>
                        <Border Grid.Row="1" Background="#11111B" CornerRadius="6" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="- test (concurrency &amp; audit): Sign-off: [x]" FontWeight="Bold" Foreground="#A6E3A1" Margin="0,0,0,4" FontFamily="Consolas" FontSize="12"/>
                                <TextBlock Text="  • Audited memory allocation and thread safety under concurrent load." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Verified untracked test files compiled without warnings." Foreground="#CDD6F4" Margin="0,0,0,2" FontFamily="Segoe UI" FontSize="12"/>
                                <TextBlock Text="  • Verification matrix passed. Signed off for project completion." Foreground="#A6E3A1" FontFamily="Segoe UI" FontSize="12"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>
            </Grid>

            <!-- 5: Agent Kickoff & Prompt Automation Card -->
            <Border Grid.Row="5" Background="#1E1E2E" CornerRadius="8" Padding="10,7" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🚀 Kickoff:" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <Button Content="📋 Copy AI 1" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send AI 1" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,3"/>
                        <Button Content="📋 Copy AI 2" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send AI 2" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,3"/>
                        <Button Content="📋 Copy Both" Margin="0,0,4,0" Padding="8,3"/>
                        <Button Content="🚀 Send Both" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,4,0" Padding="8,3"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="⚡ Re-prompt Sync:" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <Button Content="AI 1" Margin="0,0,4,0" Padding="7,3"/>
                        <Button Content="AI 2" Margin="0,0,4,0" Padding="7,3"/>
                        <Button Content="⚡ Both" Background="#45475A" Foreground="#F9E2AF" Padding="8,3"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 6: Action Controls with Highlighted Close Project -->
            <Grid Grid.Row="6" Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal">
                    <Button Content="💾 Apply Blackboard" Background="#45475A" Foreground="#BAC2DE" Margin="0,0,6,0" Padding="12,5"/>
                    <Border Background="#A6E3A1" CornerRadius="4" Margin="0,0,6,0">
                        <Button Content="🏁 Close Project (Ready)" Background="#A6E3A1" Foreground="#11111B" FontWeight="Bold" BorderBrush="#A6E3A1" Padding="14,5"/>
                    </Border>
                    <Button Content="🧹 Reset (No Save)" Background="#313244" Foreground="#CDD6F4" Margin="0,0,6,0" Padding="10,5"/>
                    <Button Content="🔄 Reset (Auto-Save)" Background="#313244" Foreground="#CDD6F4" Margin="0,0,6,0" Padding="10,5"/>
                    <Button Content="📦 Save Snapshot" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="📂 Load State" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="📄 Blackboard Output" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,5"/>
                    <Button Content="🔍 Review Diff" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,5"/>
                </StackPanel>

                <Button Grid.Column="1" Content="🕒 Open .ai/history" Background="#313244" Padding="8,5"/>
            </Grid>

            <!-- 7: Status Bar -->
            <Border Grid.Row="7" Background="#11111B" CornerRadius="4" Padding="8,4">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="✅ All 3 sign-offs complete (Human, AI 1, AI 2). Ready to archive session into .ai/history/ and close project." FontSize="11" Foreground="#A6E3A1" FontWeight="SemiBold"/>
                    <TextBlock Grid.Column="1" Text="Last write: 2026-09-25 23:28:45" FontSize="11" Foreground="#6C7086"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Border>
"@

$closeReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($closeXaml))
$closeElement = [System.Windows.Markup.XamlReader]::Load($closeReader)
Save-VisualToPng -element $closeElement -filePath (Join-Path $outputDir "controller-signoff-close.png") -width 1080 -height 860

Write-Host "Screenshots generated successfully in $outputDir!"

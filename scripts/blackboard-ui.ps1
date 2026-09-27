# AI Collab Controller (WPF UI)
# Version 1.2.36
# Standalone dual-session controller for multi-agent collaboration with human-in-the-loop steering.

$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null

$script:AppVersion = "v1.2.36"
$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:ProjectName = (Split-Path $script:RepoRoot -Leaf)
$script:ScriptFilePath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot "blackboard-ui.ps1" }
$script:LoadedScriptWriteTime = if (Test-Path $script:ScriptFilePath) { (Get-Item $script:ScriptFilePath).LastWriteTime } else { [DateTime]::MinValue }
$script:DiskScriptIsNewer = $false
$script:GitHubRepo = $null
function Get-TargetGitHubRepo {
    if ($script:GitHubRepo) { return $script:GitHubRepo }
    try {
        $origin = (git -C $script:RepoRoot config --get remote.origin.url 2>$null)
        if ($origin -match 'github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?$') {
            $script:GitHubRepo = $Matches[1]
            return $script:GitHubRepo
        }
    } catch {}
    try {
        $r = & gh repo view --json nameWithOwner -q .nameWithOwner 2>$null
        if ($LASTEXITCODE -eq 0 -and $r) {
            $script:GitHubRepo = $r.Trim()
            return $script:GitHubRepo
        }
    } catch {}
    return $null
}
$script:ControllerRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:ControllerAiDir = Join-Path $script:ControllerRoot ".ai"
$script:ClientsConfigPath = Join-Path $script:ControllerAiDir "clients.json"
$script:SignoffBaselinePath = Join-Path $script:ControllerAiDir "signoff-baseline.json"
$script:ClientsExamplePath = Join-Path $script:ControllerAiDir "clients.example.json"

$script:AiDir = Join-Path $script:RepoRoot ".ai"
$script:HistoryDir = Join-Path $script:AiDir "history"
$script:SavedDir = Join-Path $script:AiDir "saved"
$script:BlackboardPath = Join-Path $script:AiDir "blackboard.md"
$script:ExamplePath = Join-Path $script:AiDir "blackboard.example.md"

foreach ($dir in @($script:ControllerAiDir, $script:AiDir, $script:HistoryDir, $script:SavedDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

$win32Type = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text;

public class WinHelper {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;

    public static IntPtr LastHwnd = IntPtr.Zero;

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const byte VK_MENU = 0x12;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    public static bool ClickLowerComposer(IntPtr hWnd) {
        return ClickLowerComposer(hWnd, 72, 35);
    }

    public static bool ClickLowerComposer(IntPtr hWnd, int yFromBottom, int widthPercent) {
        if (hWnd == IntPtr.Zero) return false;
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return false;
        int width = r.Right - r.Left;
        int height = r.Bottom - r.Top;
        if (width < 80 || height < 80) return false;
        if (widthPercent < 5) widthPercent = 5;
        if (widthPercent > 95) widthPercent = 95;
        if (yFromBottom < 24) yFromBottom = 24;
        int x = r.Left + (width * widthPercent / 100);
        int y = r.Bottom - yFromBottom;
        SetCursorPos(x, y);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        return true;
    }

    public static bool ForceForeground(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return false;
        LastHwnd = hWnd;
        if (IsIconic(hWnd)) {
            ShowWindow(hWnd, SW_RESTORE);
        } else {
            ShowWindow(hWnd, SW_SHOW);
        }
        IntPtr fgWnd = GetForegroundWindow();
        uint pid = 0;
        uint fgThread = GetWindowThreadProcessId(fgWnd, out pid);
        uint curThread = GetCurrentThreadId();
        if (fgThread != curThread && fgThread != 0) {
            AttachThreadInput(curThread, fgThread, true);
        }
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        bool res = SetForegroundWindow(hWnd);
        if (fgThread != curThread && fgThread != 0) {
            AttachThreadInput(curThread, fgThread, false);
        }
        return res;
    }

    public static bool FocusProcess(string nameOrTitlePattern) {
        Process[] processes = Process.GetProcesses();
        for (int i = 0; i < processes.Length; i++) {
            Process p = processes[i];
            try {
                if (p.ProcessName.IndexOf(nameOrTitlePattern, StringComparison.OrdinalIgnoreCase) >= 0) {
                    if (p.MainWindowHandle != IntPtr.Zero) {
                        return ForceForeground(p.MainWindowHandle);
                    }
                }
            } catch {}
        }
        IntPtr foundWnd = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            string title = sb.ToString();
            if (!string.IsNullOrEmpty(title) && title.IndexOf(nameOrTitlePattern, StringComparison.OrdinalIgnoreCase) >= 0) {
                foundWnd = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        if (foundWnd != IntPtr.Zero) {
            return ForceForeground(foundWnd);
        }
        return false;
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]"WinHelper").Type) {
    Add-Type -TypeDefinition $win32Type
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dual-Session Blackboard Controller"
        Height="850" Width="1040"
        MinHeight="750" MinWidth="960"
        WindowStartupLocation="CenterScreen"
        Background="#181825" Foreground="#CDD6F4"
        FontFamily="Segoe UI">
    <Window.Resources>
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
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#BAC2DE"/>
                    <Setter Property="Foreground" Value="#0F172A"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#A6E3A1"/>
                    <Setter Property="Foreground" Value="#11111B"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,4"/>
            <Setter Property="Cursor" Value="Hand"/>
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
    </Window.Resources>
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- 0: Header & Presets -->
            <RowDefinition Height="Auto"/> <!-- 1: Stoplight & Phase -->
            <RowDefinition Height="Auto"/> <!-- 2: Roles & Issue Tracker -->
            <RowDefinition Height="*" MinHeight="120"/> <!-- 3: Objective, Alignment & Human Steering Notes -->
            <RowDefinition Height="*" MinHeight="240"/> <!-- 4: Cursor | Gemini last-response panes -->
            <RowDefinition Height="Auto"/> <!-- 5: Agent Kickoff & Re-prompting -->
            <RowDefinition Height="Auto"/> <!-- 6: Actions -->
            <RowDefinition Height="Auto"/> <!-- 7: Status -->
        </Grid.RowDefinitions>

        <!-- 0: Header Bar & Synced Phase Controls Pair -->
        <Grid Grid.Row="0" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Phase Control Pair: Phase Presets & Current Phase -->
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="⚡ Phase Presets:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox Name="cbPresets" Width="135" SelectedIndex="0" Margin="0,0,10,0" ToolTip="Select workflow preset (auto-applies roles and sets phase)">
                    <ComboBoxItem Content="💡 Pitch" Tag="Pitch"/>
                    <ComboBoxItem Content="💬 Discuss" Tag="Discuss"/>
                    <ComboBoxItem Content="📋 Plan" Tag="Plan"/>
                    <ComboBoxItem Content="🛠️ Implement" Tag="Implement"/>
                    <ComboBoxItem Content="🔍 Review" Tag="Review"/>
                    <ComboBoxItem Content="🧪 Test" Tag="Test"/>
                    <ComboBoxItem Content="📦 Inventory" Tag="Inventory"/>
                </ComboBox>
                <TextBlock Text="📍 Current Phase:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox Name="cbPhase" Width="175" SelectedIndex="0" ToolTip="Current project workflow phase step">
                    <ComboBoxItem Content="pitch (Proposals &amp; Ideas)"/>
                    <ComboBoxItem Content="discuss (Discussion &amp; Debate)"/>
                    <ComboBoxItem Content="plan (Architecture &amp; Design)"/>
                    <ComboBoxItem Content="implement (Active Coding)"/>
                    <ComboBoxItem Content="review (Audit &amp; Verification)"/>
                    <ComboBoxItem Content="test (Verify scripts/UI)"/>
                    <ComboBoxItem Content="closing (Final sign-off)"/>
                    <ComboBoxItem Content="closed (Completed &amp; Closed)"/>
                </ComboBox>
            </StackPanel>

            <!-- Active Turn Badge, Relaunch, Update Buttons & Tooltip/Audio Toggles -->
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <CheckBox Name="chkEnableTooltips" Content="💡 Tooltips" IsChecked="True" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <CheckBox Name="chkAudioCue" Content="🔔 Sound" IsChecked="False" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="Play subtle audio chime when an agent responds or changes turn (default off)"/>
                <Button Name="btnUpdateController" Content="🔄 Update App" Background="#313244" Foreground="#89B4FA" Margin="0,0,4,0" Padding="8,3" FontWeight="SemiBold"/>
                <Button Name="btnRelaunch" Content="⏭️ Relaunch" Background="#313244" Foreground="#BAC2DE" Margin="0,0,8,0" Padding="8,3"/>
                <Border Name="badgeTurn" Background="#45475A" CornerRadius="12" Padding="10,3">
                    <TextBlock Name="txtActiveTurn" Text="Human (Lead)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1"/>
                </Border>
            </StackPanel>
        </Grid>

        <!-- 1: Stoplight Flow Control & Active Board Path -->
        <Border Grid.Row="1" Background="#1E1E2E" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Stoplight -->
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🚦 Flow Control:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <RadioButton Name="rbGo" Content="🟢 GO" IsChecked="True" Foreground="#A6E3A1" VerticalAlignment="Center" ToolTip="Normal execution"/>
                    <RadioButton Name="rbPause" Content="🟡 PAUSE" Foreground="#F9E2AF" VerticalAlignment="Center" ToolTip="Wait for human input/review"/>
                    <RadioButton Name="rbStop" Content="🔴 ALL STOP" Foreground="#F38BA8" VerticalAlignment="Center" ToolTip="Emergency freeze"/>
                </StackPanel>

                <!-- Board Path Info Box -->
                <Border Grid.Column="1" Background="#11111B" CornerRadius="4" Padding="6,2" Margin="10,0,0,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Center" HorizontalAlignment="Right">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="📋 Board: " FontSize="11" FontWeight="SemiBold" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,4,0"/>
                        <ComboBox Name="cbRecentBoards" Width="145" Margin="0,0,6,0" ToolTip="Recent project boards (Select to switch)"/>
                        <TextBlock Name="txtBoardPath" Text="" FontSize="10" Foreground="#89B4FA" FontFamily="Consolas, monospace" VerticalAlignment="Center" ToolTip="Active Blackboard.md path (Click to copy)" Cursor="Hand" Margin="0,0,6,0"/>
                        <Button Name="btnNewBoard" Content="➕ New" FontSize="10" Padding="5,1" Margin="0,0,3,0" Background="#313244" Foreground="#A6E3A1" FontWeight="SemiBold" ToolTip="Start a new board in a project folder"/>
                        <Button Name="btnSwitchBoard" Content="📂 Browse" FontSize="10" Padding="5,1" Margin="0,0,3,0" Background="#313244" Foreground="#BAC2DE" ToolTip="Browse to select an existing blackboard.md file"/>
                        <Button Name="btnReloadBoard" Content="🔄 Reload" FontSize="10" Padding="5,1" Margin="0,0,0,0" Background="#313244" Foreground="#89B4FA" FontWeight="SemiBold" ToolTip="Force reload active blackboard from disk"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <!-- 2: Agent Roles, Sign-off, & Issue Tracker Card -->
        <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="1.1*"/>
                    <ColumnDefinition Width="1.1*"/>
                </Grid.ColumnDefinitions>

                <!-- AI 1 Role -->
                <StackPanel Grid.Column="0" Margin="0,0,6,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Name="lblSeat1Role" Text="AI 1 Role" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <StackPanel Grid.Column="1">
                            <ComboBox Name="cbSeat1Client" Width="110" Margin="0,0,0,3" Padding="4,2" FontSize="11" FontWeight="SemiBold" ToolTip="Select AI Client / IDE profile for Seat 1"/>
                            <ComboBox Name="cbCursorRole" Width="110" SelectedIndex="5">
                                <ComboBoxItem Content="implement"/>
                                <ComboBoxItem Content="review"/>
                                <ComboBoxItem Content="advise"/>
                                <ComboBoxItem Content="inventory"/>
                                <ComboBoxItem Content="plan"/>
                                <ComboBoxItem Content="idle"/>
                            </ComboBox>
                        </StackPanel>
                    </Grid>
                </StackPanel>

                <!-- AI 2 Role -->
                <StackPanel Grid.Column="1" Margin="6,0,6,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Name="lblSeat2Role" Text="AI 2 Role" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <StackPanel Grid.Column="1">
                            <ComboBox Name="cbSeat2Client" Width="110" Margin="0,0,0,3" Padding="4,2" FontSize="11" FontWeight="SemiBold" ToolTip="Select AI Client / IDE profile for Seat 2"/>
                            <ComboBox Name="cbGeminiRole" Width="110" SelectedIndex="5">
                                <ComboBoxItem Content="review"/>
                                <ComboBoxItem Content="implement"/>
                                <ComboBoxItem Content="advise"/>
                                <ComboBoxItem Content="inventory"/>
                                <ComboBoxItem Content="plan"/>
                                <ComboBoxItem Content="idle"/>
                            </ComboBox>
                        </StackPanel>
                    </Grid>
                </StackPanel>

                <!-- Completion Sign-offs -->
                <StackPanel Grid.Column="2" Margin="6,0,6,0">
                    <TextBlock Text="Project Sign-off" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <CheckBox Name="chkSignHuman" Content="Human" Margin="0,0,6,0"/>
                        <CheckBox Name="chkSignCursor" Content="AI 1" Margin="0,0,6,0"/>
                        <CheckBox Name="chkSignGemini" Content="AI 2" Margin="0,0,10,0"/>
                        <CheckBox Name="chkAutoStep" Content="⚡ Auto Step" IsChecked="True" ToolTip="On: all three sign-offs advance one phase. Off: the phase stays."/>
                    </StackPanel>
                    <TextBlock Name="txtGitStatusSummary" Text="Git: clean" FontSize="10" Foreground="#A6ADC8" Margin="0,3,0,0" ToolTip="Read-only git status for active repository"/>
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
                        <TextBox Name="txtIssueNum" Text="" VerticalContentAlignment="Center"/>
                        <Button Name="btnFetchIssue" Grid.Column="1" Content="🔍" Margin="4,0,0,0" Padding="5,2" ToolTip="Fetch Issue info via gh CLI"/>
                        <Button Name="btnNewIssue" Grid.Column="2" Content="➕" Margin="2,0,0,0" Padding="5,2" ToolTip="Create new issue on GitHub"/>
                    </Grid>
                    <TextBlock Name="txtIssueTitle" Text="" FontSize="10" Foreground="#A6ADC8" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 3: Objective, Alignment & Human Steering Notes -->
        <Grid Grid.Row="3" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Objective & Prompt -->
            <Border Grid.Column="0" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="📝 CURRENT OBJECTIVE &amp; PROMPT" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,6"/>
                    <TextBox Name="txtPrompt" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                             MinHeight="64" VerticalAlignment="Stretch"
                             Text="Implement proposed quality-of-life and automation enhancements to the Dual-Session Blackboard Controller."/>
                </Grid>
            </Border>

            <!-- Alignment & Constraints -->
            <Border Grid.Column="1" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,4,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="🤝 ALIGNMENT &amp; DECISIONS" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,6"/>
                    <TextBox Name="txtAlignment" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                             MinHeight="64" VerticalAlignment="Stretch"
                             Text="- Follow Windows WPF / PowerShell standards.&#x0a;- Maintain safety guard: max 1 implement agent.&#x0a;- Ephemeral snapshots in .ai/history/."/>
                </Grid>
            </Border>

            <!-- Human (Lead) Steering Notes -->
            <Border Grid.Column="2" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="👑 HUMAN STEERING NOTES" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center"/>
                        <Button Grid.Column="1" Name="btnPromoteNotes" Content="📝 Promote to Prompt" Background="#313244" Foreground="#F9E2AF" Padding="6,2" FontSize="10" ToolTip="Draft a Prompt from these steering notes (requires confirmation before replacing Current Objective)"/>
                    </Grid>
                    <TextBox Name="txtHumanNotes" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                             MinHeight="64" VerticalAlignment="Stretch"
                             Text="- Active steering notes."/>
                </Grid>
            </Border>
        </Grid>

        <!-- 4: AI 1 | AI 2 last-response panes (#23) -->
        <Grid Grid.Row="4" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#181825" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Name="lblSeat1Pane" Grid.Column="0" Text="💠 AI 1 LAST RESPONSE" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" VerticalAlignment="Center"/>
                        <Button Grid.Column="1" Name="btnPromoteSeat1" Content="🤝 Promote to Alignment" Background="#313244" Foreground="#A6E3A1" Padding="6,2" FontSize="10" FontWeight="SemiBold" ToolTip="Promote selected text or latest proposal bullet from Seat 1 into Alignment"/>
                    </Grid>
                    <RichTextBox Name="rtbCursorLast" Grid.Row="1" IsReadOnly="True" IsTabStop="False" IsUndoEnabled="False"
                             MinHeight="120" VerticalAlignment="Stretch"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                             Background="#11111B" Foreground="#CDD6F4" BorderThickness="0" Padding="8,6"
                             FontFamily="Segoe UI" FontSize="13"/>
                </Grid>
            </Border>
            <Border Grid.Column="1" Background="#181825" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Name="lblSeat2Pane" Grid.Column="0" Text="🪐 AI 2 LAST RESPONSE" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                        <Button Grid.Column="1" Name="btnPromoteSeat2" Content="🤝 Promote to Alignment" Background="#313244" Foreground="#A6E3A1" Padding="6,2" FontSize="10" FontWeight="SemiBold" ToolTip="Promote selected text or latest proposal bullet from Seat 2 into Alignment"/>
                    </Grid>
                    <RichTextBox Name="rtbGeminiLast" Grid.Row="1" IsReadOnly="True" IsTabStop="False" IsUndoEnabled="False"
                             MinHeight="120" VerticalAlignment="Stretch"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                             Background="#11111B" Foreground="#CDD6F4" BorderThickness="0" Padding="8,6"
                             FontFamily="Segoe UI" FontSize="13"/>
                </Grid>
            </Border>
        </Grid>

        <!-- 5: Agent Kickoff & Prompt Automation Card -->
        <Border Grid.Row="5" Background="#1E1E2E" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Row 0 Left: Kickoff Controls -->
                <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🚀 Kickoff:" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ComboBox Name="cbKickoffTarget" Width="105" SelectedIndex="2" Margin="0,0,6,0" ToolTip="Select kickoff recipient target (Seat 1, Seat 2, or Both)">
                        <ComboBoxItem Name="cbiKickoffSeat1" Content="AI 1" Tag="Seat1"/>
                        <ComboBoxItem Name="cbiKickoffSeat2" Content="AI 2" Tag="Seat2"/>
                        <ComboBoxItem Name="cbiKickoffBoth" Content="Both" Tag="Both"/>
                    </ComboBox>
                    <Button Name="btnCopyKickoffPrompt" Content="📋 Copy Prompt" Background="#313244" Margin="0,0,4,0" ToolTip="Copy tailored full Kickoff Prompt for selected target to Clipboard"/>
                    <Button Name="btnSendKickoffPrompt" Content="🚀 Send Prompt" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" ToolTip="Sequence and send full Kickoff Prompt to selected target agent(s)"/>
                    <CheckBox Name="chkNewChatKickoff" Content="New Chat" IsChecked="False" VerticalAlignment="Center" Margin="4,0,4,0" Foreground="#A6E3A1" ToolTip="Optional one-shot on Kickoff. Codex New Chat is manual: the kickoff is copied, not sent; open and verify a new Codex chat, then paste and submit. The one-shot stays armed. Cursor uses Chat: New Chat; Antigravity uses Ctrl+Shift+I then Ctrl+Shift+L. Re-prompt never opens a new chat."/>
                    <CheckBox Name="chkDryRunKickoff" Content="Dry run" IsChecked="False" VerticalAlignment="Center" Margin="4,0,4,0" Foreground="#89B4FA" ToolTip="Record the selected kickoff target, New Chat state, and status. Do not copy or send the prompt."/>
                </StackPanel>

                <!-- Center Safety Warning -->
                <TextBlock Name="txtSafetyWarning" Grid.Row="0" Grid.Column="1" Text="" Foreground="#FAB387" FontWeight="Bold" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Center" TextAlignment="Center"/>

                <!-- Row 0 Right: Re-prompt Buttons -->
                <StackPanel Grid.Row="0" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡ Re-prompt Sync:" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <Button Name="btnRepromptCursor" Content="AI 1" Background="#313244" Margin="0,0,4,0" ToolTip="Focus AI 1 &amp; re-prompt"/>
                    <Button Name="btnRepromptGemini" Content="AI 2" Background="#313244" Margin="0,0,4,0" ToolTip="Focus AI 2 &amp; re-prompt"/>
                    <Button Name="btnRepromptBoth" Content="⚡ Both" Background="#45475A" Foreground="#F9E2AF" Margin="0,0,6,0" ToolTip="Re-prompt both agents"/>
                    <Button Name="btnCompareNotes" Content="⚖️ Compare Notes" Background="#313244" Foreground="#89B4FA" FontWeight="SemiBold" ToolTip="Send a compare-notes re-prompt to both agents without replacing Objective or Alignment"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 6: Action Controls -->
        <Grid Grid.Row="6" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Left Controls: Apply, Close Project, Reset, Text Output -->
            <StackPanel Orientation="Horizontal">
                <Button Name="btnApply" Content="💾 Apply Blackboard" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="12,5"/>
                <Button Name="btnCloseProject" Content="🏁 Close Project" Background="#313244" Foreground="#A6E3A1" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5" ToolTip="Audit git, optionally commit allowlisted files and ff-only push, then archive and idle"/>
                <Button Name="btnReset" Content="🔄 Reset (Auto-Save)" Background="#F38BA8" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5" ToolTip="Archive the current board to .ai/history, then clear the form for the next task on this same file"/>
                <Button Name="btnViewText" Content="📄 Blackboard Output" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,5" ToolTip="Open separate window showing live blackboard markdown text"/>
                <Button Name="btnViewDiff" Content="🔍 Review Diff" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,5" ToolTip="Open window showing git diff of uncommitted changes"/>
                <Button Name="btnViewCompare" Content="⚖️ Compare Turns" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,5" ToolTip="Open side-by-side window comparing AI 1 and AI 2 scratchpads"/>
            </StackPanel>

            <!-- Right Controls: History Folder -->
            <Button Name="btnOpenHistory" Grid.Column="1" Content="🕒 Open .ai/history" Background="#313244" Padding="8,5" ToolTip="Open history snapshots directory in Explorer"/>
        </Grid>

        <!-- 7: Status Bar -->
        <Border Grid.Row="7" Background="#11111B" CornerRadius="4" Padding="8,4" Margin="0,2,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="txtStatus" Text="Ready. Blackboard initialized." FontSize="11" Foreground="#A6ADC8"/>
                <TextBlock Grid.Column="1" Name="txtLastSaved" Text="Last write: -" FontSize="11" Foreground="#6C7086"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$window.Title = "AI Collab Controller - " + $script:AppVersion

$txtBoardPath          = $window.FindName("txtBoardPath")
if ($txtBoardPath) {
    $txtBoardPath.Text = $script:BlackboardPath
    $txtBoardPath.Cursor = [System.Windows.Input.Cursors]::Hand
    $txtBoardPath.ToolTip = "Active Blackboard.md path (Click to copy):`n$script:BlackboardPath"
    $txtBoardPath.add_MouseDown({
        try {
            [System.Windows.Clipboard]::SetText($script:BlackboardPath)
            $txtStatus.Text = "Copied blackboard path to clipboard: $script:BlackboardPath"
        } catch {
            $txtStatus.Text = "Failed to copy path: $($_.Exception.Message)"
        }
    })
}

$cbRecentBoards        = $window.FindName("cbRecentBoards")
if ($cbRecentBoards) {
    $cbRecentBoards.add_SelectionChanged({
        if ($script:SuppressBoardSwitch) { return }
        $selectedItem = $cbRecentBoards.SelectedItem
        if ($selectedItem -and $selectedItem.Tag) {
            $target = [string]$selectedItem.Tag
            $isSame = ($script:BlackboardPath -and ((Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path -eq (Resolve-Path $target -ErrorAction SilentlyContinue).Path))
            if ($isSame) {
                Reload-ActiveBlackboard
                return
            }
            if (-not (Confirm-DiscardUnsavedEdits -actionName "switching boards")) {
                Populate-RecentBoardsDropdown
                return
            }
            Set-ActiveBlackboardPath -targetPath $target
        }
    })
}

$btnNewBoard           = $window.FindName("btnNewBoard")
if ($btnNewBoard) {
    $btnNewBoard.add_Click({
        try {
            if (-not (Confirm-DiscardUnsavedEdits -actionName "creating a new board")) { return }
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Select Project / Repository Folder for New Blackboard"
            $fbd.SelectedPath = if (Test-Path $script:RepoRoot) { $script:RepoRoot } else { [Environment]::GetFolderPath("UserProfile") }
            $fbd.ShowNewFolderButton = $true
            if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $chosenFolder = $fbd.SelectedPath
                if ([string]::IsNullOrWhiteSpace($chosenFolder) -or -not (Test-Path $chosenFolder)) { return }
                
                $targetAiDir = Join-Path $chosenFolder ".ai"
                $targetBlackboard = Join-Path $targetAiDir "blackboard.md"
                
                if (-not (Test-Path $targetAiDir)) {
                    New-Item -ItemType Directory -Force -Path $targetAiDir | Out-Null
                }
                foreach ($sub in @("history", "saved")) {
                    $subPath = Join-Path $targetAiDir $sub
                    if (-not (Test-Path $subPath)) {
                        New-Item -ItemType Directory -Force -Path $subPath | Out-Null
                    }
                }
                $targetGitignore = Join-Path $chosenFolder ".gitignore"
                if (Test-Path $targetGitignore) {
                    try {
                        $giContent = [System.IO.File]::ReadAllText($targetGitignore, [System.Text.Encoding]::UTF8)
                        if ($giContent -notmatch '\.ai/blackboard\.md') {
                            $appendGi = "`n# Dual-Session Agent Blackboard (gitignored live session)`n.ai/blackboard.md`n.ai/blackboard.md.bak`n"
                            [System.IO.File]::AppendAllText($targetGitignore, $appendGi, [System.Text.Encoding]::UTF8)
                        }
                    } catch {}
                }

                if (-not (Test-Path $targetBlackboard)) {
                    $templateSource = if (Test-Path $script:ExamplePath) {
                        $script:ExamplePath
                    } elseif (Test-Path (Join-Path $script:ControllerAiDir "blackboard.example.md")) {
                        Join-Path $script:ControllerAiDir "blackboard.example.md"
                    } else {
                        $null
                    }
                    
                    if ($templateSource) {
                        Copy-Item -Path $templateSource -Destination $targetBlackboard -Force
                    } else {
                        $initContent = @"
# Dual-Session Agent Blackboard

> **Flow Control**: `🟢 GO`
> **Project Phase**: `advise`
> **Active Turn**: Human (Lead)
> **GitHub Issue**: none
> **Last Updated**: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))

---

## Agent Roles & Safety

| Participant | Active Role | Status | Sign-off (Complete) |
|-------------|-------------|--------|---------------------|
| **Human (Lead)** | `lead` | Active | [ ] |
| **Cursor** | `advise` | Active | [ ] |
| **Antigravity** | `advise` | Active | [ ] |

> [!NOTE]
> **Safety Guard**: Only ONE agent may hold the `implement` role at any time. When one implements, the other must be `review`, `advise`, or `idle`.

---

## Current Objective & Prompt

New board initialized.

---

## Alignment & Agreed Decisions



---

## Working Notes & Scratchpads

### Human (Lead)
- Active steering notes.

### Cursor Scratchpad
- (Cursor updates here)

### Antigravity Scratchpad
- (Antigravity updates here)
"@
                        [System.IO.File]::WriteAllText($targetBlackboard, $initContent, [System.Text.Encoding]::UTF8)
                    }
                }
                
                Set-ActiveBlackboardPath -targetPath $targetBlackboard
                $txtStatus.Text = "Initialized active board at: $targetBlackboard"
            }
        } catch {
            $txtStatus.Text = "Error creating new board: $_"
        }
    })
}

$btnSwitchBoard        = $window.FindName("btnSwitchBoard")
if ($btnSwitchBoard) {
    $btnSwitchBoard.add_Click({
        try {
            if (-not (Confirm-DiscardUnsavedEdits -actionName "switching boards")) { return }
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = "Select Target Blackboard Markdown File"
            $dlg.InitialDirectory = if (Test-Path $script:AiDir) { $script:AiDir } else { $script:RepoRoot }
            $dlg.Filter = "Blackboard File (*blackboard*.md)|*blackboard*.md|Markdown files (*.md)|*.md|All files (*.*)|*.*"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-ActiveBlackboardPath -targetPath $dlg.FileName
            }
        } catch {
            $txtStatus.Text = "Error selecting board: $_"
        }
    })
}

$btnReloadBoard        = $window.FindName("btnReloadBoard")
if ($btnReloadBoard) {
    $btnReloadBoard.add_Click({
        Reload-ActiveBlackboard
    })
}

$btnUpdateController   = $window.FindName("btnUpdateController")
$btnRelaunch           = $window.FindName("btnRelaunch")
$badgeTurn             = $window.FindName("badgeTurn")
$txtActiveTurn         = $window.FindName("txtActiveTurn")
$rbGo                  = $window.FindName("rbGo")
$rbPause               = $window.FindName("rbPause")
$rbStop                = $window.FindName("rbStop")
$cbPhase               = $window.FindName("cbPhase")
$cbCursorRole          = $window.FindName("cbCursorRole")
$cbGeminiRole          = $window.FindName("cbGeminiRole")
$chkSignHuman          = $window.FindName("chkSignHuman")
$chkSignCursor         = $window.FindName("chkSignCursor")
$chkSignGemini         = $window.FindName("chkSignGemini")
$chkAutoStep           = $window.FindName("chkAutoStep")
$txtIssueNum           = $window.FindName("txtIssueNum")
$txtIssueTitle         = $window.FindName("txtIssueTitle")
$btnFetchIssue         = $window.FindName("btnFetchIssue")
$btnNewIssue           = $window.FindName("btnNewIssue")
$txtPrompt             = $window.FindName("txtPrompt")
$txtAlignment          = $window.FindName("txtAlignment")
$txtHumanNotes         = $window.FindName("txtHumanNotes")
$chkEnableTooltips     = $window.FindName("chkEnableTooltips")
$chkAudioCue           = $window.FindName("chkAudioCue")
$badgeTurn             = $window.FindName("badgeTurn")
$rtbCursorLast         = $window.FindName("rtbCursorLast")
$rtbGeminiLast         = $window.FindName("rtbGeminiLast")
$cbPresets             = $window.FindName("cbPresets")
$btnApplyPreset        = $window.FindName("btnApplyPreset")
$txtGitStatusSummary   = $window.FindName("txtGitStatusSummary")
$cbKickoffTarget       = $window.FindName("cbKickoffTarget")
$cbiKickoffSeat1       = $window.FindName("cbiKickoffSeat1")
$cbiKickoffSeat2       = $window.FindName("cbiKickoffSeat2")
$cbiKickoffBoth        = $window.FindName("cbiKickoffBoth")
$btnCopyKickoffPrompt  = $window.FindName("btnCopyKickoffPrompt")
$btnSendKickoffPrompt  = $window.FindName("btnSendKickoffPrompt")
$chkNewChatKickoff     = $window.FindName("chkNewChatKickoff")
$chkDryRunKickoff      = $window.FindName("chkDryRunKickoff")
$btnRepromptCursor     = $window.FindName("btnRepromptCursor")
$btnRepromptGemini     = $window.FindName("btnRepromptGemini")
$btnRepromptBoth       = $window.FindName("btnRepromptBoth")
$btnCompareNotes       = $window.FindName("btnCompareNotes")
$btnApply              = $window.FindName("btnApply")
$btnCloseProject        = $window.FindName("btnCloseProject")
$btnReset              = $window.FindName("btnReset")
$btnViewText           = $window.FindName("btnViewText")
$btnViewDiff           = $window.FindName("btnViewDiff")
$btnViewCompare        = $window.FindName("btnViewCompare")
$btnPromoteNotes       = $window.FindName("btnPromoteNotes")
$btnOpenHistory        = $window.FindName("btnOpenHistory")
$txtSafetyWarning      = $window.FindName("txtSafetyWarning")
$txtStatus             = $window.FindName("txtStatus")
$txtLastSaved          = $window.FindName("txtLastSaved")
$cbSeat1Client         = $window.FindName("cbSeat1Client")
$cbSeat2Client         = $window.FindName("cbSeat2Client")
$lblSeat1Role          = $window.FindName("lblSeat1Role")
$lblSeat2Role          = $window.FindName("lblSeat2Role")
$lblSeat1Pane          = $window.FindName("lblSeat1Pane")
$lblSeat2Pane          = $window.FindName("lblSeat2Pane")
$btnPromoteSeat1       = $window.FindName("btnPromoteSeat1")
$btnPromoteSeat2       = $window.FindName("btnPromoteSeat2")

function Get-ClientConfiguration {
    $defaultConfig = [PSCustomObject]@{
        seat1 = "AI 1"
        seat2 = "AI 2"
        boardPath = ""
        recentBoards = @()
        boardSeats = [PSCustomObject]@{}
        tooltips = $true
        audioCue = $false
        autoStep = $true
        profiles = [PSCustomObject]@{
            "AI 1" = [PSCustomObject]@{ process = ""; description = "Generic Seat 1 (Manual Clipboard Copy)" }
            "AI 2" = [PSCustomObject]@{ process = ""; description = "Generic Seat 2 (Manual Clipboard Copy)" }
            "Cursor" = [PSCustomObject]@{ process = "Cursor"; description = "Cursor AI IDE" }
            "Antigravity" = [PSCustomObject]@{ process = "Antigravity"; description = "Google Antigravity IDE" }
            "Windsurf" = [PSCustomObject]@{ process = "Windsurf"; description = "Codeium Windsurf IDE" }
            "VS Code" = [PSCustomObject]@{ process = "Code"; description = "VS Code / GitHub Copilot" }
            "Terminal" = [PSCustomObject]@{ process = "WindowsTerminal"; description = "Windows Terminal (Claude Code, Aider, CLI)" }
            "Codex" = [PSCustomObject]@{ process = "ChatGPT"; description = "OpenAI Codex in the ChatGPT desktop app" }
        }
    }

    $ensureConfig = {
        param($obj)
        if ($obj) {
            if (-not $obj.PSObject.Properties['recentBoards']) { $obj | Add-Member -NotePropertyName "recentBoards" -NotePropertyValue @() -Force }
            if (-not $obj.PSObject.Properties['boardSeats']) { $obj | Add-Member -NotePropertyName "boardSeats" -NotePropertyValue ([PSCustomObject]@{}) -Force }
            if (-not $obj.PSObject.Properties['tooltips']) { $obj | Add-Member -NotePropertyName "tooltips" -NotePropertyValue $true -Force }
            if (-not $obj.PSObject.Properties['audioCue']) { $obj | Add-Member -NotePropertyName "audioCue" -NotePropertyValue $false -Force }
            if (-not $obj.PSObject.Properties['autoStep']) { $obj | Add-Member -NotePropertyName "autoStep" -NotePropertyValue $true -Force }
            if ($obj.profiles) {
                if (-not $obj.profiles.PSObject.Properties['Codex']) {
                    $obj.profiles | Add-Member -NotePropertyName "Codex" -NotePropertyValue ([PSCustomObject]@{ process = "ChatGPT"; description = "OpenAI Codex in the ChatGPT desktop app" }) -Force
                }
                if ($obj.profiles.PSObject.Properties['ChatGPT']) {
                    $obj.profiles.PSObject.Properties.Remove('ChatGPT')
                }
            }
            if ($obj.seat1 -eq "ChatGPT") { $obj.seat1 = "Codex" }
            if ($obj.seat2 -eq "ChatGPT") { $obj.seat2 = "Codex" }
        }
    }

    if (Test-Path $script:ClientsConfigPath) {
        try {
            $json = Get-Content $script:ClientsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json -and $json.profiles) {
                & $ensureConfig $json
                return $json
            }
        } catch {}
    }

    if (Test-Path $script:ClientsExamplePath) {
        try {
            $json = Get-Content $script:ClientsExamplePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json -and $json.profiles) {
                & $ensureConfig $json
                return $json
            }
        } catch {}
    }

    return $defaultConfig
}

$script:MasterTooltips = @{
    # Presets & Top Toolbar
    "cbPresets"            = "Select a dual-agent workflow preset (auto-applies roles and phase on change)"
    "chkEnableTooltips"    = "Toggle hover tooltips on/off across all controller controls"
    "chkAudioCue"          = "Toggle audio chime on agent response / turn completion (default off)"
    "btnUpdateController"  = "Check GitHub for newer controller version, pull, and relaunch"
    "btnRelaunch"          = "Relaunch controller script immediately (reloads local code changes). A newer script also relaunches on its own after a short settle when the form is clean."
    "badgeTurn"            = "Current active turn indicator"
    "txtActiveTurn"        = "Current active participant who has the turn"

    # Flow Control, Board Path & Phase
    "rbGo"                 = "Normal execution — agents proceed with tasks in assigned roles"
    "rbPause"              = "Pause execution — agents wait for Human Lead input or review"
    "rbStop"               = "Emergency freeze — all agents cease work immediately"
    "cbRecentBoards"       = "Select a recent project board to switch active context"
    "txtBoardPath"         = "Active blackboard file path (Click to copy to clipboard)"
    "btnNewBoard"          = "Initialize a new blackboard in a project folder"
    "btnSwitchBoard"       = "Browse to select an existing blackboard.md file"
    "btnReloadBoard"       = "Force reload active blackboard from disk"
    "cbPhase"              = "Select current project workflow phase (pitch, discuss, plan, implement, review, test, closing, closed)"

    # Seat Profiles, Roles, Sign-offs & Issues
    "cbSeat1Client"        = "Select AI client / IDE profile for Seat 1"
    "cbSeat2Client"        = "Select AI client / IDE profile for Seat 2"
    "cbCursorRole"         = "Select active role permissions for Seat 1"
    "cbGeminiRole"         = "Select active role permissions for Seat 2"
    "chkSignHuman"         = "Phase sign-off approval from Human Lead (all 3 advance phase / close project)"
    "chkSignCursor"        = "Phase sign-off approval from Seat 1 (all 3 advance phase / close project)"
    "chkSignGemini"        = "Phase sign-off approval from Seat 2 (all 3 advance phase / close project)"
    "chkAutoStep"          = "Auto step. On advances one phase when all three sign-offs are checked. Off leaves the phase where it is."
    "txtGitStatusSummary"  = "Read-only summary of active git branch and uncommitted changes"
    "txtIssueNum"          = "Associated GitHub issue number (e.g. 24 or none)"
    "txtIssueTitle"        = "Fetched title of the linked GitHub issue"
    "btnFetchIssue"        = "Fetch issue title and metadata via gh CLI"
    "btnNewIssue"          = "Create a new issue on GitHub via gh CLI"

    # Prompt, Alignment & Steering Notes
    "txtPrompt"            = "Enter primary task objective, requirements, and acceptance criteria"
    "txtAlignment"         = "Key design rules, architectural constraints, and agreed decisions"
    "txtHumanNotes"        = "Active steering notes and directives from the Human Lead"
    "btnPromoteNotes"      = "Draft a Prompt from these steering notes (replaces Current Objective)"

    # Response Panes
    "rtbCursorLast"        = "Formatted view of Seat 1's latest scratchpad response"
    "rtbGeminiLast"        = "Formatted view of Seat 2's latest scratchpad response"
    "btnPromoteSeat1"      = "Promote selected text or latest proposal bullet from Seat 1 into Alignment"
    "btnPromoteSeat2"      = "Promote selected text or latest proposal bullet from Seat 2 into Alignment"

    # Kickoff & Reprompt Dispatch
    "cbKickoffTarget"      = "Select kickoff recipient target (Seat 1, Seat 2, or Both)"
    "btnCopyKickoffPrompt" = "Copy tailored Kickoff Prompt for selected target to Clipboard"
    "btnSendKickoffPrompt" = "Focus target window and paste tailored Kickoff Prompt"
    "chkNewChatKickoff"    = "Optional one-shot on Kickoff. Codex New Chat is manual: the kickoff is copied, not sent; open and verify a new Codex chat, then paste and submit. The one-shot stays armed. Cursor uses Chat: New Chat; Antigravity uses Ctrl+Shift+I then Ctrl+Shift+L. Re-prompt never opens a new chat."
    "chkDryRunKickoff"     = "Record the selected kickoff target, New Chat state, and status. Do not copy or send the prompt."
    "btnRepromptCursor"    = "Focus Seat 1 window and trigger follow-up prompt"
    "btnRepromptGemini"    = "Focus Seat 2 window and trigger follow-up prompt"
    "btnRepromptBoth"      = "Re-prompt both agents"
    "btnCompareNotes"      = "Send a compare-notes re-prompt to both agents without replacing Objective or Alignment"

    # Bottom Toolbar Actions
    "btnApply"             = "Write current form configuration to active blackboard.md on disk"
    "btnCloseProject"      = "Audit git, archive session to .ai/history, and reset board to idle"
    "btnReset"             = "Archive the current board to .ai/history and clear the form for the next task on this same file"
    "btnViewText"          = "Open live blackboard markdown text viewer window"
    "btnViewDiff"          = "Open Review Diff viewer showing uncommitted working tree changes"
    "btnViewCompare"       = "Open side-by-side pop-out window comparing AI 1 and AI 2 scratchpads"
    "btnOpenHistory"       = "Open .ai/history directory in File Explorer"
    "txtStatus"            = "Controller status and activity log"
    "txtLastSaved"         = "Timestamp of last save to disk"
    "txtSafetyWarning"     = "Safety and mutual exclusion status indicator"
}

function Set-ControllerTooltips {
    param([bool]$enabled)
    foreach ($entry in $script:MasterTooltips.GetEnumerator()) {
        $ctrl = $window.FindName($entry.Key)
        if ($ctrl -and ($ctrl -is [System.Windows.FrameworkElement])) {
            $ctrl.ToolTip = if ($enabled) { $entry.Value } else { $null }
        }
    }
}

function Save-ClientConfiguration {
    try {
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $cfg = $script:ClientConfig
        if (-not $cfg) { $cfg = Get-ClientConfiguration }

        $propsToEnsure = @{
            "seat1"        = $s1
            "seat2"        = $s2
            "boardPath"    = $script:BlackboardPath
            "tooltips"     = $true
            "audioCue"     = $false
            "autoStep"     = $true
            "recentBoards" = @()
            "boardSeats"   = [PSCustomObject]@{}
        }
        foreach ($propName in $propsToEnsure.Keys) {
            if (-not $cfg.PSObject.Properties[$propName]) {
                $cfg | Add-Member -NotePropertyName $propName -NotePropertyValue $propsToEnsure[$propName] -Force
            }
        }

        $cfg.seat1 = $s1
        $cfg.seat2 = $s2
        $cfg.boardPath = $script:BlackboardPath
        $tooltipsVal = if ($chkEnableTooltips) { [bool]$chkEnableTooltips.IsChecked } elseif ($null -ne $cfg.tooltips) { [bool]$cfg.tooltips } else { $true }
        $cfg.tooltips = $tooltipsVal
        $audioCueVal = if ($chkAudioCue) { [bool]$chkAudioCue.IsChecked } elseif ($null -ne $cfg.audioCue) { [bool]$cfg.audioCue } else { $false }
        $cfg.audioCue = $audioCueVal
        $autoStepVal = if ($chkAutoStep) { [bool]$chkAutoStep.IsChecked } elseif ($null -ne $cfg.autoStep) { [bool]$cfg.autoStep } else { $true }
        $cfg.autoStep = $autoStepVal

        if ($script:BlackboardPath) {
            $resolvedPath = (Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path
            if ($resolvedPath) {
                $boardSeatObj = [PSCustomObject]@{
                    seat1 = $s1
                    seat2 = $s2
                }
                $cfg.boardSeats | Add-Member -NotePropertyName $resolvedPath -NotePropertyValue $boardSeatObj -Force
            }
        }

        $recent = @()
        if ($cfg.recentBoards) {
            $recent = @($cfg.recentBoards | Where-Object { $_ -and (Test-Path $_) })
        }
        if ($script:BlackboardPath -and (Test-Path $script:BlackboardPath)) {
            $resolvedActive = (Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path
            if ($resolvedActive) {
                $recent = @($resolvedActive) + @($recent | Where-Object {
                    $r = (Resolve-Path $_ -ErrorAction SilentlyContinue).Path
                    $r -and ($r -ne $resolvedActive)
                })
                if ($recent.Count -gt 8) { $recent = $recent[0..7] }
            }
        }
        $cfg.recentBoards = $recent
        $script:ClientConfig = $cfg
        $exportObj = [PSCustomObject]@{
            '$schema' = "https://json-schema.org/draft/2020-12/schema"
            seat1 = $s1
            seat2 = $s2
            boardPath = $script:BlackboardPath
            recentBoards = $recent
            boardSeats = $cfg.boardSeats
            tooltips = $tooltipsVal
            audioCue = $audioCueVal
            autoStep = $autoStepVal
            profiles = $cfg.profiles
        }
        $dir = Split-Path $script:ClientsConfigPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $jsonStr = $exportObj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($script:ClientsConfigPath, $jsonStr, [System.Text.Encoding]::UTF8)
    } catch {
        if ($txtStatus) { $txtStatus.Text = "Config save error: $($_.Exception.Message)" }
        Write-Warning "Save-ClientConfiguration failed: $_"
    }
}

function Get-Seat1Client {
    if ($cbSeat1Client -and $cbSeat1Client.SelectedItem) {
        return [string]$cbSeat1Client.SelectedItem
    }
    if ($script:ClientConfig -and $script:ClientConfig.seat1) {
        $val = [string]$script:ClientConfig.seat1
        if ($val -eq "Agent 1") { return "AI 1" }
        return $val
    }
    return "AI 1"
}

function Get-Seat2Client {
    if ($cbSeat2Client -and $cbSeat2Client.SelectedItem) {
        return [string]$cbSeat2Client.SelectedItem
    }
    if ($script:ClientConfig -and $script:ClientConfig.seat2) {
        $val = [string]$script:ClientConfig.seat2
        if ($val -eq "Agent 2") { return "AI 2" }
        return $val
    }
    return "AI 2"
}

function Update-KickoffButtonTooltips {
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $targetName = "Both ($s1 & $s2)"
    if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) {
        $tag = [string]$cbKickoffTarget.SelectedItem.Tag
        if ($tag -eq "Seat1") { $targetName = $s1 }
        elseif ($tag -eq "Seat2") { $targetName = $s2 }
    }
    if ($btnCopyKickoffPrompt) {
        $btnCopyKickoffPrompt.ToolTip = "Copy tailored full Kickoff Prompt for $targetName to Clipboard"
    }
    if ($btnSendKickoffPrompt) {
        $btnSendKickoffPrompt.ToolTip = "Focus $targetName window and paste tailored full Kickoff Prompt"
    }
}

function Update-SeatClientLabels {
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    
    if ($lblSeat1Role) { $lblSeat1Role.Text = "$s1 Role" }
    if ($lblSeat2Role) { $lblSeat2Role.Text = "$s2 Role" }
    
    if ($chkSignCursor) { $chkSignCursor.Content = $s1 }
    if ($chkSignGemini) { $chkSignGemini.Content = $s2 }
    
    if ($cbiKickoffSeat1) { $cbiKickoffSeat1.Content = $s1 }
    if ($cbiKickoffSeat2) { $cbiKickoffSeat2.Content = $s2 }
    Update-KickoffButtonTooltips
    
    if ($btnRepromptCursor) { $btnRepromptCursor.Content = $s1 }
    if ($btnRepromptGemini) { $btnRepromptGemini.Content = $s2 }
    
    if ($lblSeat1Pane) { $lblSeat1Pane.Text = "💠 " + $s1.ToUpper() + " LAST RESPONSE" }
    if ($lblSeat2Pane) { $lblSeat2Pane.Text = "🪐 " + $s2.ToUpper() + " LAST RESPONSE" }
    
    if (Get-Command Update-UiActiveTurn -ErrorAction SilentlyContinue) {
        Update-UiActiveTurn -keepOverride
    }
}

function Populate-SeatClientDropdowns {
    param([switch]$forceFromBoard)
    $script:ClientConfig = Get-ClientConfiguration
    $profileNames = @($script:ClientConfig.profiles.PSObject.Properties | ForEach-Object { $_.Name })
    if ($profileNames.Count -eq 0) {
        $profileNames = @("AI 1", "AI 2", "Cursor", "Antigravity", "Windsurf", "VS Code", "Terminal", "Codex")
    }

    $boardSeat1 = $null
    $boardSeat2 = $null
    if ($script:BlackboardPath) {
        $resolvedActive = (Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path
        if ($resolvedActive -and $script:ClientConfig.boardSeats -and $script:ClientConfig.boardSeats.$resolvedActive) {
            $boardSeat1 = [string]$script:ClientConfig.boardSeats.$resolvedActive.seat1
            $boardSeat2 = [string]$script:ClientConfig.boardSeats.$resolvedActive.seat2
        }
    }

    if ($cbSeat1Client) {
        $current1 = [string]$cbSeat1Client.SelectedItem
        $cbSeat1Client.Items.Clear()
        foreach ($p in $profileNames) {
            [void]$cbSeat1Client.Items.Add($p)
        }
        $target1 = if (-not $forceFromBoard -and $current1 -and $cbSeat1Client.Items.Contains($current1)) {
            $current1
        } elseif ($boardSeat1 -and $cbSeat1Client.Items.Contains($boardSeat1)) {
            $boardSeat1
        } elseif ($script:ClientConfig.seat1 -and $script:ClientConfig.seat1 -ne "Agent 1") {
            [string]$script:ClientConfig.seat1
        } else {
            "AI 1"
        }
        $idx1 = $cbSeat1Client.Items.IndexOf($target1)
        if ($idx1 -ge 0) { $cbSeat1Client.SelectedIndex = $idx1 } else { $cbSeat1Client.SelectedIndex = 0 }
    }

    if ($cbSeat2Client) {
        $current2 = [string]$cbSeat2Client.SelectedItem
        $cbSeat2Client.Items.Clear()
        foreach ($p in $profileNames) {
            [void]$cbSeat2Client.Items.Add($p)
        }
        $target2 = if (-not $forceFromBoard -and $current2 -and $cbSeat2Client.Items.Contains($current2)) {
            $current2
        } elseif ($boardSeat2 -and $cbSeat2Client.Items.Contains($boardSeat2)) {
            $boardSeat2
        } elseif ($script:ClientConfig.seat2 -and $script:ClientConfig.seat2 -ne "Agent 2") {
            [string]$script:ClientConfig.seat2
        } else {
            "AI 2"
        }
        $idx2 = $cbSeat2Client.Items.IndexOf($target2)
        if ($idx2 -ge 0) { $cbSeat2Client.SelectedIndex = $idx2 } else { $cbSeat2Client.SelectedIndex = 1 }
    }

    Update-SeatClientLabels
}

function Confirm-DiscardUnsavedEdits {
    param([string]$actionName = "switching boards")
    if ($script:FormDirty) {
        $res = [System.Windows.MessageBox]::Show(
            "You have unsaved changes in the Blackboard UI.`n`nDo you want to save before $actionName?`n`nYes = Save & Continue`nNo = Discard & Continue`nCancel = Stay here",
            "Unsaved Changes",
            [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($res -eq [System.Windows.MessageBoxResult]::Cancel) { return $false }
        if ($res -eq [System.Windows.MessageBoxResult]::Yes) {
            Save-BlackboardContent
        }
    }
    return $true
}

$script:SuppressBoardSwitch = $false

function Populate-RecentBoardsDropdown {
    if (-not $cbRecentBoards) { return }
    $script:SuppressBoardSwitch = $true
    try {
        $cbRecentBoards.Items.Clear()
        $cfg = $script:ClientConfig
        if (-not $cfg) { $cfg = Get-ClientConfiguration }
        $recent = @()
        if ($cfg.recentBoards) {
            $recent = @($cfg.recentBoards | Where-Object { $_ -and (Test-Path $_) })
        }
        if ($script:BlackboardPath -and (Test-Path $script:BlackboardPath)) {
            $activeResolved = (Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path
            if ($activeResolved -and -not ($recent | Where-Object { (Resolve-Path $_ -ErrorAction SilentlyContinue).Path -eq $activeResolved })) {
                $recent = @($activeResolved) + $recent
            }
        }

        $selectedIdx = -1
        $currentIdx = 0
        foreach ($bPath in $recent) {
            $rPath = (Resolve-Path $bPath -ErrorAction SilentlyContinue).Path
            if (-not $rPath) { continue }
            $pDir = Split-Path $rPath -Parent
            $isAi = ((Split-Path $pDir -Leaf) -eq ".ai")
            $projName = if ($isAi) { Split-Path (Split-Path $pDir -Parent) -Leaf } else { Split-Path $pDir -Leaf }
            $fileName = Split-Path $rPath -Leaf

            $itemText = if ($fileName -eq "blackboard.md") { $projName } else { "$projName ($fileName)" }
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $itemText
            $item.Tag = $rPath
            $item.ToolTip = $rPath
            $cbRecentBoards.Items.Add($item) | Out-Null

            $activeBb = (Resolve-Path $script:BlackboardPath -ErrorAction SilentlyContinue).Path
            if ($activeBb -and ($activeBb -eq $rPath)) {
                $selectedIdx = $currentIdx
            }
            $currentIdx++
        }

        if ($selectedIdx -ge 0) {
            $cbRecentBoards.SelectedIndex = $selectedIdx
        }
    } finally {
        $script:SuppressBoardSwitch = $false
    }
}

function Set-ActiveBlackboardPath {
    param([string]$targetPath)
    
    if ([string]::IsNullOrWhiteSpace($targetPath)) { return }
    if (-not (Test-Path $targetPath)) {
        [System.Windows.MessageBox]::Show("Blackboard file not found: $targetPath", "Switch Blackboard", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    try {
        $resolved = (Resolve-Path $targetPath).Path
        $parentDir = Split-Path $resolved -Parent
        $isDotAi = ((Split-Path $parentDir -Leaf) -eq ".ai")
        
        $script:BlackboardPath = $resolved
        if ($isDotAi) {
            $script:AiDir = $parentDir
            $script:RepoRoot = Split-Path $parentDir -Parent
        } else {
            $script:AiDir = Join-Path $parentDir ".ai"
            $script:RepoRoot = $parentDir
        }
        $script:ProjectName = Split-Path $script:RepoRoot -Leaf
        $script:HistoryDir = Join-Path $script:AiDir "history"
        $script:SavedDir = Join-Path $script:AiDir "saved"
        $script:ExamplePath = Join-Path $script:AiDir "blackboard.example.md"
        $script:GitHubRepo = $null

        foreach ($dir in @($script:AiDir, $script:HistoryDir, $script:SavedDir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
        }

        Save-ClientConfiguration
        Populate-SeatClientDropdowns -forceFromBoard
        Populate-RecentBoardsDropdown

        if ($txtBoardPath) {
            $txtBoardPath.Text = $script:BlackboardPath
            $txtBoardPath.ToolTip = "Active Blackboard.md path (Click to copy):`n$script:BlackboardPath"
        }
        $window.Title = "AI Collab Controller - " + $script:AppVersion + " [" + $script:ProjectName + "]"

        $script:FormDirty = $false
        $script:LastReadBlackboardText = ""
        $script:LastCursorPad = $null
        $script:LastGeminiPad = $null
        $script:ActiveTurnOverride = $null
        Load-BlackboardIntoUI
        Update-BlackboardViewer -force
        $txtStatus.Text = "Switched active board to: $script:BlackboardPath (Project: $script:ProjectName)"
    } catch {
        [System.Windows.MessageBox]::Show("Failed to switch blackboard: $($_.Exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

function Reload-ActiveBlackboard {
    param([switch]$force)
    if (-not (Test-Path $script:BlackboardPath)) { return }
    if (-not $force -and -not (Confirm-DiscardUnsavedEdits -actionName "reloading board")) { return }
    $script:FormDirty = $false
    $script:LastReadBlackboardText = ""
    $script:LastCursorPad = $null
    $script:LastGeminiPad = $null
    $script:ActiveTurnOverride = $null
    Populate-SeatClientDropdowns -forceFromBoard
    Load-BlackboardIntoUI
    Update-BlackboardViewer -force
    if ($txtStatus) {
        $txtStatus.Text = "Reloaded blackboard from disk (" + (Get-Date -Format "HH:mm:ss") + "): " + (Split-Path $script:BlackboardPath -Leaf)
    }
}

Populate-SeatClientDropdowns
Populate-RecentBoardsDropdown

if ($cbSeat1Client) {
    $cbSeat1Client.add_SelectionChanged({
        Update-SeatClientLabels
        Save-ClientConfiguration
        Mark-FormDirty
    })
}

if ($cbSeat2Client) {
    $cbSeat2Client.add_SelectionChanged({
        Update-SeatClientLabels
        Save-ClientConfiguration
        Mark-FormDirty
    })
}

if ($window) {
    $window.add_Closing({
        Save-ClientConfiguration
    })
}

if ($chkEnableTooltips) {
    $initialTooltips = if ($script:ClientConfig -and $null -ne $script:ClientConfig.tooltips) { [bool]$script:ClientConfig.tooltips } else { $true }
    $chkEnableTooltips.IsChecked = $initialTooltips
    Set-ControllerTooltips -enabled $initialTooltips

    $chkEnableTooltips.add_Checked({
        Set-ControllerTooltips -enabled $true
        Save-ClientConfiguration
        $txtStatus.Text = "Tooltips enabled across controller."
    })
    $chkEnableTooltips.add_Unchecked({
        Set-ControllerTooltips -enabled $false
        Save-ClientConfiguration
        $txtStatus.Text = "Tooltips disabled across controller."
    })
}

if ($chkAudioCue) {
    $initialAudio = if ($script:ClientConfig -and $null -ne $script:ClientConfig.audioCue) { [bool]$script:ClientConfig.audioCue } else { $false }
    $chkAudioCue.IsChecked = $initialAudio

    $chkAudioCue.add_Checked({
        Save-ClientConfiguration
        $txtStatus.Text = "Turn change audio chime enabled."
    })
    $chkAudioCue.add_Unchecked({
        Save-ClientConfiguration
        $txtStatus.Text = "Turn change audio chime disabled."
    })
}

if ($chkAutoStep) {
    $initialAutoStep = if ($script:ClientConfig -and $null -ne $script:ClientConfig.autoStep) { [bool]$script:ClientConfig.autoStep } else { $true }
    $chkAutoStep.IsChecked = $initialAutoStep
    $chkAutoStep.add_Checked({
        Save-ClientConfiguration
        $txtStatus.Text = "Auto step on. All three sign-offs advance one phase."
        Check-PhaseAutoAdvance
    })
    $chkAutoStep.add_Unchecked({
        Save-ClientConfiguration
        $txtStatus.Text = "Auto step off. The phase stays until you change it."
    })
}

# Live Blackboard Text Viewer Window with Color/Diff Highlighting
$script:ViewerWindow = $null
$script:ViewerRtbBox = $null
$script:ViewerRawBox = $null
$script:ViewerStatus = $null
$script:ViewerBadge  = $null
$script:ViewerIsRaw  = $false
$script:ViewerLastText = ""

function Add-MarkdownRuns {
    param(
        $paragraph,
        [string]$text,
        $brushDefault,
        $brushBold,
        $brushCode
    )
    if ([string]::IsNullOrEmpty($text)) { return }
    $idx = 0
    foreach ($m in [regex]::Matches($text, '(\*\*[^*]+\*\*|`[^`]+`)')) {
        if ($m.Index -gt $idx) {
            $r = New-Object System.Windows.Documents.Run ($text.Substring($idx, $m.Index - $idx))
            $r.Foreground = $brushDefault
            $paragraph.Inlines.Add($r) | Out-Null
        }
        $tok = $m.Value
        if ($tok.StartsWith("**")) {
            $r = New-Object System.Windows.Documents.Run ($tok.Substring(2, $tok.Length - 4))
            $r.Foreground = $brushBold
            $r.FontWeight = [System.Windows.FontWeights]::Bold
        } else {
            $r = New-Object System.Windows.Documents.Run ($tok.Substring(1, $tok.Length - 2))
            $r.Foreground = $brushCode
            $r.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        }
        $paragraph.Inlines.Add($r) | Out-Null
        $idx = $m.Index + $m.Length
    }
    if ($idx -lt $text.Length) {
        $r = New-Object System.Windows.Documents.Run ($text.Substring($idx))
        $r.Foreground = $brushDefault
        $paragraph.Inlines.Add($r) | Out-Null
    }
}

function Render-MarkdownToFlowDocument {
    param(
        [string]$text,
        [switch]$ChatStyle
    )
    if ($null -eq $text) { $text = "" }
    $doc = New-Object System.Windows.Documents.FlowDocument
    $brushH1 = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA")
    $brushH2 = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBA6F7")
    $brushH3 = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
    $brushDiffAdd = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
    $brushDiffDel = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
    $brushQuote = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387")
    $brushTable = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#BAC2DE")
    $brushMuted = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6C7086")
    $brushCheck = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
    $brushDefault = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
    $brushBold = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFFFFF")
    $brushCode = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA")

    if ($ChatStyle) {
        $doc.PagePadding = New-Object System.Windows.Thickness(10)
        $doc.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $doc.FontSize = 13
        $doc.LineHeight = 22
    } else {
        $doc.PagePadding = New-Object System.Windows.Thickness(10)
        $doc.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E1E2E")
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas, Segoe UI")
        $doc.FontSize = 12
    }

    $lines = $text -split "\r?\n"
    foreach ($line in $lines) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)

        if ($line -match "^#\s+(.+)") {
            Add-MarkdownRuns $p $matches[1] $brushH1 $brushH1 $brushCode
            $p.FontWeight = [System.Windows.FontWeights]::Bold
            $p.FontSize = 15
            $p.Margin = New-Object System.Windows.Thickness(0, 8, 0, 3)
        }
        elseif ($line -match "^##\s+(.+)") {
            Add-MarkdownRuns $p $matches[1] $brushH2 $brushH2 $brushCode
            $p.FontWeight = [System.Windows.FontWeights]::Bold
            $p.FontSize = 13.5
            $p.Margin = New-Object System.Windows.Thickness(0, 7, 0, 2)
        }
        elseif ($line -match "^###\s+(.+)") {
            Add-MarkdownRuns $p $matches[1] $brushH3 $brushH3 $brushCode
            $p.FontWeight = [System.Windows.FontWeights]::Bold
            $p.Margin = New-Object System.Windows.Thickness(0, 5, 0, 1)
        }
        elseif ($ChatStyle -and $line -match "^(\s{2,})[-*]\s+(.+)$") {
            # Indented sub-bullet (level 2+)
            $indentSpaces = $matches[1].Length
            $leftMargin = [Math]::Min(14 * [Math]::Floor($indentSpaces / 2), 36)
            $p.Margin = New-Object System.Windows.Thickness($leftMargin, 2, 0, 2)
            Add-MarkdownRuns $p ("◦ " + $matches[2]) $brushDefault $brushBold $brushCode
        }
        elseif ($ChatStyle -and $line -match "^(\s{2,})(\d+[\.)]\s+.+)$") {
            # Indented numbered item
            $indentSpaces = $matches[1].Length
            $leftMargin = [Math]::Min(14 * [Math]::Floor($indentSpaces / 2), 36)
            $p.Margin = New-Object System.Windows.Thickness($leftMargin, 2, 0, 2)
            Add-MarkdownRuns $p $matches[2] $brushDefault $brushBold $brushCode
        }
        elseif ($line -match "^[-*]\s+(.+)$") {
            $topMargin = if ($ChatStyle) { 6 } else { 3 }
            $p.Margin = New-Object System.Windows.Thickness(0, $topMargin, 0, 2)
            Add-MarkdownRuns $p ("• " + $matches[1]) $brushDefault $brushBold $brushCode
        }
        elseif ($ChatStyle) {
            Add-MarkdownRuns $p $line $brushDefault $brushBold $brushCode
        }
        elseif ($line.StartsWith("+") -or $line -match "^\s*\+\s+") {
            $r = New-Object System.Windows.Documents.Run $line
            $r.Foreground = $brushDiffAdd
            $r.FontWeight = [System.Windows.FontWeights]::SemiBold
            $p.Inlines.Add($r) | Out-Null
        }
        elseif ($line.StartsWith("-") -and -not $line.StartsWith("---") -and ($line -match "error|fail|remove|delete|warning|drop|crash")) {
            $r = New-Object System.Windows.Documents.Run $line
            $r.Foreground = $brushDiffDel
            $r.FontWeight = [System.Windows.FontWeights]::SemiBold
            $p.Inlines.Add($r) | Out-Null
        }
        elseif ($line.StartsWith(">")) {
            $r = New-Object System.Windows.Documents.Run $line
            $r.Foreground = $brushQuote
            $p.Inlines.Add($r) | Out-Null
        }
        elseif ($line.StartsWith("|")) {
            $r = New-Object System.Windows.Documents.Run $line
            if ($line -match "\[x\]") {
                $r.Foreground = $brushCheck
            } else {
                $r.Foreground = $brushTable
            }
            $p.Inlines.Add($r) | Out-Null
        }
        elseif ($line.StartsWith("---")) {
            $r = New-Object System.Windows.Documents.Run "────────────────────────────────────────────────────────────"
            $r.Foreground = $brushMuted
            $p.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
            $p.Inlines.Add($r) | Out-Null
        }
        else {
            Add-MarkdownRuns $p $line $brushDefault $brushBold $brushCode
        }
        $doc.Blocks.Add($p) | Out-Null
    }
    return $doc
}

function Show-BlackboardViewer {
    if ($script:ViewerWindow -and $script:ViewerWindow.IsVisible) {
        $script:ViewerWindow.Activate() | Out-Null
        Update-BlackboardViewer
        return
    }
    
    [xml]$viewXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Live Blackboard Output Viewer (Rich Highlight)"
        Height="750" Width="880"
        WindowStartupLocation="CenterScreen"
        Background="#181825" Foreground="#CDD6F4"
        FontFamily="Segoe UI">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Viewer Header -->
        <Border Grid.Row="0" Background="#1E1E2E" CornerRadius="6" Padding="10,6" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="📄 LIVE BLACKBOARD OUTPUT (.ai/blackboard.md)" FontWeight="Bold" FontSize="12" Foreground="#89B4FA" VerticalAlignment="Center"/>
                    <TextBlock Name="txtViewerBadge" Text="🎨 Rich Highlight" FontSize="10" Foreground="#A6E3A1" Background="#313244" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button Name="btnViewerToggle" Content="📝 Raw Edit Mode" Background="#313244" Foreground="#BAC2DE" Padding="10,3" Margin="0,0,6,0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button Name="btnViewerCopy" Content="📋 Copy All" Background="#313244" Foreground="#CDD6F4" Padding="10,3" Margin="0,0,6,0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button Name="btnViewerRefresh" Content="🔄 Refresh" Background="#313244" Foreground="#CDD6F4" Padding="10,3" Margin="0,0,6,0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button Name="btnViewerSave" Content="💾 Save Edits" Background="#89B4FA" Foreground="#11111B" Padding="10,3" FontWeight="Bold" Cursor="Hand" Visibility="Collapsed"/>
                </StackPanel>
            </Grid>
        </Border>
        
        <!-- Content Area -->
        <Border Grid.Row="1" Background="#1E1E2E" CornerRadius="6" Padding="4" BorderBrush="#45475A" BorderThickness="1">
            <Grid>
                <RichTextBox Name="rtbViewerContent" Background="#1E1E2E" Foreground="#CDD6F4" BorderThickness="0"
                             FontFamily="Consolas, Segoe UI" FontSize="12" IsReadOnly="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                <TextBox Name="txtViewerRaw" Background="#1E1E2E" Foreground="#CDD6F4" BorderThickness="0"
                         FontFamily="Consolas" FontSize="12" AcceptsReturn="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         Padding="8" Visibility="Collapsed"/>
            </Grid>
        </Border>
                 
        <!-- Viewer Footer -->
        <Border Grid.Row="2" Background="#11111B" CornerRadius="4" Padding="8,4" Margin="0,6,0,0">
            <TextBlock Name="txtViewerStatus" Text="Showing live color-highlighted content of .ai/blackboard.md" FontSize="11" Foreground="#A6ADC8"/>
        </Border>
    </Grid>
</Window>
"@
    $vReader = (New-Object System.Xml.XmlNodeReader $viewXaml)
    $script:ViewerWindow = [System.Windows.Markup.XamlReader]::Load($vReader)
    $script:ViewerRtbBox = $script:ViewerWindow.FindName("rtbViewerContent")
    $script:ViewerRawBox = $script:ViewerWindow.FindName("txtViewerRaw")
    $script:ViewerStatus = $script:ViewerWindow.FindName("txtViewerStatus")
    $script:ViewerBadge  = $script:ViewerWindow.FindName("txtViewerBadge")
    
    $btnViewerToggle  = $script:ViewerWindow.FindName("btnViewerToggle")
    $btnViewerCopy    = $script:ViewerWindow.FindName("btnViewerCopy")
    $btnViewerRefresh = $script:ViewerWindow.FindName("btnViewerRefresh")
    $btnViewerSave    = $script:ViewerWindow.FindName("btnViewerSave")
    
    $btnViewerToggle.add_Click({
        $script:ViewerIsRaw = -not $script:ViewerIsRaw
        if ($script:ViewerIsRaw) {
            $script:ViewerRtbBox.Visibility = [System.Windows.Visibility]::Collapsed
            $script:ViewerRawBox.Visibility = [System.Windows.Visibility]::Visible
            $btnViewerSave.Visibility = [System.Windows.Visibility]::Visible
            $btnViewerToggle.Content = "🎨 Rich View Mode"
            $script:ViewerBadge.Text = "📝 Raw Edit Mode"
            $script:ViewerBadge.Foreground = [System.Windows.Media.Brushes]::Gold
            if (Test-Path $script:BlackboardPath) {
                $script:ViewerRawBox.Text = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            }
        } else {
            $script:ViewerRawBox.Visibility = [System.Windows.Visibility]::Collapsed
            $script:ViewerRtbBox.Visibility = [System.Windows.Visibility]::Visible
            $btnViewerSave.Visibility = [System.Windows.Visibility]::Collapsed
            $btnViewerToggle.Content = "📝 Raw Edit Mode"
            $script:ViewerBadge.Text = "🎨 Rich Highlight"
            $script:ViewerBadge.Foreground = [System.Windows.Media.Brushes]::LightGreen
            Update-BlackboardViewer
        }
    })
    
    $btnViewerCopy.add_Click({
        try {
            if (Test-Path $script:BlackboardPath) {
                $txt = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
                Safe-SetClipboard $txt
                $script:ViewerStatus.Text = "📋 Copied all blackboard text to clipboard (" + (Get-Date -Format "HH:mm:ss") + ")."
            }
        } catch {}
    })
    
    $btnViewerRefresh.add_Click({
        Update-BlackboardViewer -force
    })
    
    $btnViewerSave.add_Click({
        try {
            [System.IO.File]::WriteAllText($script:BlackboardPath, $script:ViewerRawBox.Text, [System.Text.Encoding]::UTF8)
            $script:ViewerStatus.Text = "💾 Saved edits to .ai/blackboard.md (" + (Get-Date -Format "HH:mm:ss") + ")."
            Load-BlackboardIntoUI
        } catch {
            $script:ViewerStatus.Text = "Error saving edits: $_"
        }
    })
    
    Update-BlackboardViewer -force
    $script:ViewerWindow.Show()
}

function Update-BlackboardViewer {
    param([switch]$force)
    
    if ($script:ViewerWindow -and $script:ViewerWindow.IsVisible) {
        try {
            if (Test-Path $script:BlackboardPath) {
                $txt = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
                if ((-not $force) -and ($script:ViewerLastText -eq $txt)) {
                    return
                }
                $script:ViewerLastText = $txt
                if ($script:ViewerRtbBox -and (-not $script:ViewerIsRaw)) {
                    $offset = $script:ViewerRtbBox.VerticalOffset
                    $doc = Render-MarkdownToFlowDocument $txt
                    $script:ViewerRtbBox.Document = $doc
                    $script:ViewerRtbBox.Dispatcher.BeginInvoke([Action]{
                        $script:ViewerRtbBox.ScrollToVerticalOffset($offset)
                    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
                    if ($script:ViewerStatus) {
                        $script:ViewerStatus.Text = "Color-highlighted from .ai/blackboard.md (" + (Get-Date -Format "HH:mm:ss") + ")."
                    }
                } elseif ($script:ViewerRawBox -and $script:ViewerIsRaw) {
                    if ($script:ViewerRawBox.Text -ne $txt) {
                        $offset = $script:ViewerRawBox.VerticalOffset
                        $script:ViewerRawBox.Text = $txt
                        $script:ViewerRawBox.Dispatcher.BeginInvoke([Action]{
                            $script:ViewerRawBox.ScrollToVerticalOffset($offset)
                        }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
                    }
                }
            }
        } catch {}
    }
}

$btnViewText.add_Click({ Show-BlackboardViewer })

# Review Git Diff Viewer Window (Read-Only)
$script:DiffViewerWindow = $null
$script:DiffViewerRtbBox = $null
$script:DiffViewerStatus = $null

function Test-PngPath {
    param([string]$path)
    return [bool]($path -and ($path -match '(?i)\.png$'))
}

function Add-PngPreview {
    param(
        $paragraph,
        [string]$fullPath,
        [string]$label
    )
    $caption = New-Object System.Windows.Documents.Run("$label`n")
    $caption.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA")
    $paragraph.Inlines.Add($caption)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $miss = New-Object System.Windows.Documents.Run("(PNG preview unavailable)`n")
        $miss.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6C7086")
        $paragraph.Inlines.Add($miss)
        return
    }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.UriSource = New-Object System.Uri ((Resolve-Path -LiteralPath $fullPath).Path)
        $bmp.DecodePixelWidth = 420
        $bmp.EndInit()
        $bmp.Freeze()
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $bmp
        $img.MaxWidth = 420
        $img.Margin = New-Object System.Windows.Thickness(0, 4, 0, 8)
        $paragraph.Inlines.Add((New-Object System.Windows.Documents.InlineUIContainer($img)))
        $paragraph.Inlines.Add((New-Object System.Windows.Documents.Run("`n")))
    } catch {
        $fail = New-Object System.Windows.Documents.Run("(PNG preview failed)`n")
        $fail.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
        $paragraph.Inlines.Add($fail)
    }
}

function Save-GitBlobToFile {
    param(
        [string]$spec,
        [string]$dest
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.WorkingDirectory = [string]$script:RepoRoot
    $psi.Arguments = "show --no-textconv `"$spec`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Open($dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Close()
    }
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 8))
}

function Add-BlobPngPreview {
    param(
        $paragraph,
        [string]$spec,
        [string]$label
    )
    $tmp = Join-Path $env:TEMP ("bb-png-" + [System.IO.Path]::GetRandomFileName() + ".png")
    try {
        if (Save-GitBlobToFile -spec $spec -dest $tmp) {
            Add-PngPreview -paragraph $paragraph -fullPath $tmp -label $label
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-CommittedPngPreview {
    param(
        $paragraph,
        [string]$line,
        [string]$upstream
    )
    if ($line -match 'Binary files a/(.+\.png) and /dev/null differ') {
        $rel = $Matches[1].Trim().Trim('"')
        if ($upstream) {
            Add-BlobPngPreview -paragraph $paragraph -spec "${upstream}:${rel}" -label "PNG deleted (was at ${upstream}): $rel"
        }
        return
    }
    $oldRel = $null
    $newRel = $null
    if ($line -match 'Binary files /dev/null and b/(.+\.png) differ') {
        $newRel = $Matches[1].Trim().Trim('"')
    } elseif ($line -match 'Binary files a/(.+\.png) and b/(.+\.png) differ') {
        $oldRel = $Matches[1].Trim().Trim('"')
        $newRel = $Matches[2].Trim().Trim('"')
    } else {
        return
    }
    if ($oldRel -and $upstream) {
        Add-BlobPngPreview -paragraph $paragraph -spec "${upstream}:${oldRel}" -label "PNG before (${upstream}): $oldRel"
    }
    if ($newRel) {
        Add-BlobPngPreview -paragraph $paragraph -spec "HEAD:${newRel}" -label "PNG at HEAD: $newRel"
    }
}

function Add-WorktreePngPreview {
    param(
        $paragraph,
        [string]$line
    )
    if ($line -match 'Binary files a/(.+\.png) and /dev/null differ') {
        $rel = $Matches[1].Trim().Trim('"')
        Add-BlobPngPreview -paragraph $paragraph -spec "HEAD:${rel}" -label "PNG deleted (removed from the working tree; was at HEAD): $rel"
        return
    }
    if ($line -match 'Binary files .+ and b/(.+\.png) differ') {
        $rel = $Matches[1].Trim().Trim('"')
        $fullPath = Join-Path $script:RepoRoot $rel
        if (Test-Path -LiteralPath $fullPath) {
            Add-PngPreview -paragraph $paragraph -fullPath $fullPath -label "PNG preview: $rel"
        } else {
            Add-BlobPngPreview -paragraph $paragraph -spec "HEAD:${rel}" -label "PNG deleted (removed from the working tree; was at HEAD): $rel"
        }
    }
}

function Update-ReviewDiffViewer {
    if (-not $script:DiffViewerWindow -or -not $script:DiffViewerWindow.IsVisible) { return }
    try {
        $targetUpstream = (git -C $script:RepoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
        if (-not $targetUpstream) {
            if (git -C $script:RepoRoot rev-parse --verify origin/main 2>$null) {
                $targetUpstream = "origin/main"
            } elseif (git -C $script:RepoRoot rev-parse --verify origin/master 2>$null) {
                $targetUpstream = "origin/master"
            }
        }

        $commitsAhead = if ($targetUpstream) {
            @(git -C $script:RepoRoot log --oneline "$targetUpstream..HEAD" 2>$null)
        } else { @() }

        $branchDiff = if ($targetUpstream -and $commitsAhead.Count -gt 0) {
            @(git -C $script:RepoRoot diff "$targetUpstream..HEAD" 2>$null)
        } else { @() }

        $diffRaw = @(git -C $script:RepoRoot diff HEAD 2>$null)
        $statusRaw = @(git -C $script:RepoRoot status --short 2>$null)
        
        $doc = New-Object System.Windows.Documents.FlowDocument
        $doc.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        $doc.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas, Courier New, monospace")
        $doc.FontSize = 12
        $doc.PagePadding = New-Object System.Windows.Thickness(10)

        # 1. Git Status
        if ($statusRaw.Count -gt 0) {
            $pStat = New-Object System.Windows.Documents.Paragraph
            $pStat.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
            $pStat.Inlines.Add((New-Object System.Windows.Documents.Run("=== GIT STATUS (Changed & Untracked Files) ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF") }))
            foreach ($s in $statusRaw) {
                $col = if ($s.StartsWith("??")) { "#F38BA8" } elseif ($s.StartsWith(" M") -or $s.StartsWith("M ")) { "#A6E3A1" } else { "#89B4FA" }
                $pStat.Inlines.Add((New-Object System.Windows.Documents.Run("$s`n") -property @{ Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($col) }))
            }
            $doc.Blocks.Add($pStat)
        }

        # 2. Commits Ahead of Upstream
        if ($commitsAhead.Count -gt 0) {
            $pCommits = New-Object System.Windows.Documents.Paragraph
            $pCommits.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
            $pCommits.Inlines.Add((New-Object System.Windows.Documents.Run("=== COMMITS ON BRANCH (Ahead of $($targetUpstream): $($commitsAhead.Count)) ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF") }))
            foreach ($c in $commitsAhead) {
                $pCommits.Inlines.Add((New-Object System.Windows.Documents.Run("  • $c`n") -property @{ Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89DCEB") }))
            }
            $doc.Blocks.Add($pCommits)
        }

        # 3. Clean check
        if ($diffRaw.Count -eq 0 -and $statusRaw.Count -eq 0 -and $branchDiff.Count -eq 0) {
            $pClean = New-Object System.Windows.Documents.Paragraph
            $pClean.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
            $pClean.Inlines.Add((New-Object System.Windows.Documents.Run("Working tree clean. No uncommitted changes or branch commits ahead of upstream detected.") -property @{ Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1"); FontStyle = [System.Windows.FontStyles]::Italic }))
            $doc.Blocks.Add($pClean)
        }

        # 4. Committed Diff (Upstream..HEAD)
        if ($branchDiff.Count -gt 0) {
            $pBranch = New-Object System.Windows.Documents.Paragraph
            $pBranch.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $pBranch.Inlines.Add((New-Object System.Windows.Documents.Run("=== COMMITTED DIFF ($targetUpstream..HEAD) ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA") }))
            foreach ($line in $branchDiff) {
                $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
                $weight = [System.Windows.FontWeights]::Normal
                if ($line.StartsWith("diff --git") -or $line.StartsWith("index ")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBA6F7")
                    $weight = [System.Windows.FontWeights]::Bold
                } elseif ($line.StartsWith("--- ") -or $line.StartsWith("+++ ")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387")
                    $weight = [System.Windows.FontWeights]::Bold
                } elseif ($line.StartsWith("@@")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89DCEB")
                    $weight = [System.Windows.FontWeights]::SemiBold
                } elseif ($line.StartsWith("+")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
                } elseif ($line.StartsWith("-")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
                }
                $run = New-Object System.Windows.Documents.Run("$line`n")
                $run.Foreground = $brush
                $run.FontWeight = $weight
                $pBranch.Inlines.Add($run)
                Add-CommittedPngPreview -paragraph $pBranch -line $line -upstream $targetUpstream
            }
            $doc.Blocks.Add($pBranch)
        }

        # 5. Uncommitted Diff (HEAD vs Working Tree)
        if ($diffRaw.Count -gt 0) {
            $pDiff = New-Object System.Windows.Documents.Paragraph
            $pDiff.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $pDiff.Inlines.Add((New-Object System.Windows.Documents.Run("=== UNCOMMITTED DIFF (Working Tree vs HEAD) ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1") }))
            foreach ($line in $diffRaw) {
                $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
                $weight = [System.Windows.FontWeights]::Normal
                if ($line.StartsWith("diff --git") -or $line.StartsWith("index ")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBA6F7")
                    $weight = [System.Windows.FontWeights]::Bold
                } elseif ($line.StartsWith("--- ") -or $line.StartsWith("+++ ")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387")
                    $weight = [System.Windows.FontWeights]::Bold
                } elseif ($line.StartsWith("@@")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89DCEB")
                    $weight = [System.Windows.FontWeights]::SemiBold
                } elseif ($line.StartsWith("+")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
                } elseif ($line.StartsWith("-")) {
                    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
                }
                $run = New-Object System.Windows.Documents.Run("$line`n")
                $run.Foreground = $brush
                $run.FontWeight = $weight
                $pDiff.Inlines.Add($run)
                Add-WorktreePngPreview -paragraph $pDiff -line $line
            }
            $doc.Blocks.Add($pDiff)
        }

        # 6. Render contents of untracked files
        $untrackedEntries = @($statusRaw | Where-Object { $_.StartsWith("??") })
        if ($untrackedEntries.Count -gt 0) {
            $pUntracked = New-Object System.Windows.Documents.Paragraph
            $pUntracked.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
            $pUntracked.Inlines.Add((New-Object System.Windows.Documents.Run("=== UNTRACKED FILES CONTENT ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387") }))
            foreach ($entry in $untrackedEntries) {
                $relPath = $entry.Substring(2).Trim().Trim('"')
                $fullPath = Join-Path $script:RepoRoot $relPath
                if ((Test-Path $fullPath) -and -not (Test-Path $fullPath -PathType Container)) {
                    $pUntracked.Inlines.Add((New-Object System.Windows.Documents.Run("--- /dev/null`n+++ b/$relPath`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBA6F7") }))
                    if (Test-PngPath $relPath) {
                        Add-PngPreview -paragraph $pUntracked -fullPath $fullPath -label "PNG preview: $relPath"
                        continue
                    }
                    try {
                        $uLines = @(Get-Content -Path $fullPath -TotalCount 300 -ErrorAction SilentlyContinue)
                        foreach ($ul in $uLines) {
                            $r = New-Object System.Windows.Documents.Run("+$ul`n")
                            $r.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
                            $pUntracked.Inlines.Add($r)
                        }
                        if ((Get-Content -Path $fullPath -ErrorAction SilentlyContinue | Measure-Object).Count -gt 300) {
                            $pUntracked.Inlines.Add((New-Object System.Windows.Documents.Run("[... content truncated after 300 lines ...]`n") -property @{ Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6C7086"); FontStyle = [System.Windows.FontStyles]::Italic }))
                        }
                    } catch {}
                }
            }
            $doc.Blocks.Add($pUntracked)
        }

        $script:DiffViewerRtbBox.Document = $doc
        if ($script:DiffViewerStatus) {
            $script:DiffViewerStatus.Text = "Diff updated (" + (Get-Date -Format "HH:mm:ss") + "). Ahead: $($commitsAhead.Count) commit(s) | Uncommitted lines: " + $diffRaw.Count + " | Changed files: " + $statusRaw.Count
        }
    } catch {
        if ($script:DiffViewerStatus) {
            $script:DiffViewerStatus.Text = "Error rendering diff: $_"
        }
    }
}

function Show-ReviewDiffViewer {
    if ($script:DiffViewerWindow -and $script:DiffViewerWindow.IsVisible) {
        $script:DiffViewerWindow.Activate() | Out-Null
        Update-ReviewDiffViewer
        return
    }
    
    [xml]$diffXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Review Git Diff Viewer (Read-Only)"
        Height="720" Width="880"
        WindowStartupLocation="CenterScreen"
        Background="#181825" Foreground="#CDD6F4"
        FontFamily="Segoe UI">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Diff Viewer Header -->
        <Border Grid.Row="0" Background="#1E1E2E" CornerRadius="6" Padding="10,6" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🔍 REVIEW GIT DIFF (Working Tree &amp; Branch Commits)" FontWeight="Bold" FontSize="12" Foreground="#A6E3A1" VerticalAlignment="Center"/>
                    <TextBlock Text="🔒 Read-Only" FontSize="10" Foreground="#BAC2DE" Background="#313244" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button Name="btnDiffCopy" Content="📋 Copy Diff" Background="#313244" Foreground="#CDD6F4" Padding="10,3" Margin="0,0,6,0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button Name="btnDiffRefresh" Content="🔄 Refresh" Background="#313244" Foreground="#A6E3A1" Padding="10,3" FontWeight="SemiBold" Cursor="Hand"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Diff Content RichTextBox -->
        <Border Grid.Row="1" Background="#11111B" CornerRadius="6" BorderBrush="#313244" BorderThickness="1" Padding="4">
            <RichTextBox Name="rtbDiffContent" IsReadOnly="True" IsTabStop="False" IsUndoEnabled="False"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         Background="#11111B" Foreground="#CDD6F4" BorderThickness="0" Padding="8,6"
                         FontFamily="Consolas, Courier New, monospace" FontSize="12"/>
        </Border>

        <!-- Diff Status Footer -->
        <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="4" Padding="8,4" Margin="0,6,0,0" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="txtDiffStatus" Text="Ready." FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="git diff upstream..HEAD + working tree" FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader($diffXaml)
    $diffWin = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:DiffViewerWindow = $diffWin
    $script:DiffViewerRtbBox = $diffWin.FindName("rtbDiffContent")
    $script:DiffViewerStatus = $diffWin.FindName("txtDiffStatus")
    $btnCopy = $diffWin.FindName("btnDiffCopy")
    $btnRefresh = $diffWin.FindName("btnDiffRefresh")

    $btnRefresh.add_Click({ Update-ReviewDiffViewer })
    $btnCopy.add_Click({
        try {
            $diffText = [System.Collections.Generic.List[string]]::new()
            $targetUpstream = (git -C $script:RepoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
            if (-not $targetUpstream) {
                if (git -C $script:RepoRoot rev-parse --verify origin/main 2>$null) { $targetUpstream = "origin/main" }
            }
            if ($targetUpstream) {
                $commits = @(git -C $script:RepoRoot log --oneline "$targetUpstream..HEAD" 2>$null)
                if ($commits.Count -gt 0) {
                    [void]$diffText.Add("=== COMMITS ON BRANCH (Ahead of $($targetUpstream): $($commits.Count)) ===")
                    foreach ($c in $commits) { [void]$diffText.Add("  • $c") }
                    [void]$diffText.Add("")
                    $bDiff = @(git -C $script:RepoRoot diff "$targetUpstream..HEAD" 2>$null)
                    if ($bDiff.Count -gt 0) {
                        [void]$diffText.Add("=== COMMITTED DIFF ($targetUpstream..HEAD) ===")
                        [void]$diffText.AddRange($bDiff)
                        [void]$diffText.Add("")
                    }
                }
            }
            $raw = @(git -C $script:RepoRoot diff HEAD 2>$null)
            if ($raw.Count -gt 0) {
                [void]$diffText.Add("=== UNCOMMITTED DIFF (Working Tree vs HEAD) ===")
                [void]$diffText.AddRange($raw)
                [void]$diffText.Add("")
            }
            $statusRaw = @(git -C $script:RepoRoot status --short 2>$null)
            $untrackedEntries = @($statusRaw | Where-Object { $_.StartsWith("??") })
            if ($untrackedEntries.Count -gt 0) {
                [void]$diffText.Add("=== UNTRACKED FILES ===")
                foreach ($entry in $untrackedEntries) {
                    $relPath = $entry.Substring(2).Trim().Trim('"')
                    $fullPath = Join-Path $script:RepoRoot $relPath
                    if ((Test-Path $fullPath) -and -not (Test-Path $fullPath -PathType Container)) {
                        if (Test-PngPath $relPath) {
                            [void]$diffText.Add("PNG (shown in the diff viewer, not copied as text): $relPath")
                            continue
                        }
                        [void]$diffText.Add("--- /dev/null")
                        [void]$diffText.Add("+++ b/$relPath")
                        $uLines = @(Get-Content -Path $fullPath -TotalCount 300 -ErrorAction SilentlyContinue)
                        foreach ($ul in $uLines) { [void]$diffText.Add("+$ul") }
                    }
                }
            }
            if ($diffText.Count -gt 0) {
                [System.Windows.Clipboard]::SetText(($diffText -join "`n"))
                $script:DiffViewerStatus.Text = "Diff (including branch commits & untracked files) copied to clipboard."
            } else {
                $script:DiffViewerStatus.Text = "Nothing to copy (working tree clean and no commits ahead)."
            }
        } catch {
            $script:DiffViewerStatus.Text = "Copy failed: $_"
        }
    })

    $diffWin.add_Closed({
        $script:DiffViewerWindow = $null
        $script:DiffViewerRtbBox = $null
        $script:DiffViewerStatus = $null
    })

    $diffWin.Show()
    Update-ReviewDiffViewer
}

if ($btnViewDiff) {
    $btnViewDiff.add_Click({ Show-ReviewDiffViewer })
}

# Side-by-Side Scratchpad Compare Viewer Window (Modeless Pop-Out)
$script:CompareViewerWindow = $null
$script:CompareViewerRtb1 = $null
$script:CompareViewerRtb2 = $null
$script:CompareViewerStatus = $null
$script:CompareViewerBtnPromote = $null
$script:CompareViewerLastS1Text = ""
$script:CompareViewerLastS2Text = ""
$script:CompareViewerHeaderInfo = $null
$script:CompareViewerSeat1Header = $null
$script:CompareViewerSeat2Header = $null

function Get-AgreedSentences {
    param([string]$pad)
    $out = @()
    if ([string]::IsNullOrEmpty($pad)) { return $out }
    $pattern = '(?im)^\s*[-*]?\s*`?(?:-\s*)?`?\*\*Agreed\*\*`?\s*:\s*(.+)$'
    foreach ($m in [regex]::Matches($pad, $pattern)) {
        $val = $m.Groups[1].Value.Trim().Trim('`').Trim()
        if ($val -match '(?i)^\s*[*◦\-`"]*?\s*(?:Summary|Next)\b') { continue }
        if ($val -and ($out -notcontains $val)) { $out += $val }
    }
    return $out
}

function Test-HasAgreeToken {
    param([string]$pad)
    if ([string]::IsNullOrEmpty($pad)) { return $false }
    return [regex]::IsMatch($pad, '(?im)^\s*[-*]?\s*`?(?:-\s*)?`?\*\*Agree\*\*`?\s*:?\s*$')
}

function Get-SharedAgreedLines {
    param([string]$pad1, [string]$pad2)
    $left = @(Get-AgreedSentences $pad1)
    $right = @(Get-AgreedSentences $pad2)
    $shared = New-Object System.Collections.Generic.List[string]
    $add = {
        param($text)
        foreach ($existing in $shared) {
            if ($existing.Equals([string]$text, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        }
        [void]$shared.Add([string]$text)
    }
    if (Test-HasAgreeToken $pad2) { foreach ($s in $left) { & $add $s } }
    if (Test-HasAgreeToken $pad1) { foreach ($s in $right) { & $add $s } }
    foreach ($s in $left) {
        foreach ($t in $right) {
            if ($s.Equals([string]$t, [System.StringComparison]::OrdinalIgnoreCase)) { & $add $s }
        }
    }
    return @($shared)
}

function Render-ScratchpadCompareDoc {
    param([string]$text, [string]$seatTitle)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
    $doc.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
    $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $doc.FontSize = 14
    $doc.PagePadding = New-Object System.Windows.Thickness(12, 10, 12, 10)

    $lines = $text -split "\r?\n"
    foreach ($line in $lines) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.LineHeight = 22
        $top = 0
        if ($line -match '^\s*-\s+\*\*') { $top = 10 }
        if ([string]::IsNullOrWhiteSpace($line)) {
            $p.Margin = New-Object System.Windows.Thickness(0, 6, 0, 6)
            $line = " "
        } else {
            $p.Margin = New-Object System.Windows.Thickness(0, $top, 0, 8)
        }

        $run = New-Object System.Windows.Documents.Run($line)
        if ($line -match '(?i)^\s*[-*]?\s*`?[-*]?\s*`?\*\*(?:Agreed|Agree)\*\*') {
            # Highlight agreement lines in mint green
            $p.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E3A2F")
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
            $run.FontWeight = [System.Windows.FontWeights]::Bold
        } elseif ($line -match '^###\s+') {
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA")
            $run.FontWeight = [System.Windows.FontWeights]::Bold
        } elseif ($line -match '^####\s+') {
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
            $run.FontWeight = [System.Windows.FontWeights]::Bold
        } elseif ($line -match '^\s*-\s+\*\*(?:advise|plan|implement|review|test)\*\*') {
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBA6F7")
            $run.FontWeight = [System.Windows.FontWeights]::SemiBold
        }
        $p.Inlines.Add($run)
        $doc.Blocks.Add($p)
    }
    return $doc
}

function Update-CompareTurnsViewer {
    if (-not $script:CompareViewerWindow -or -not $script:CompareViewerWindow.IsVisible) { return }
    try {
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client

        if ($script:CompareViewerSeat1Header) { $script:CompareViewerSeat1Header.Text = "$s1 Scratchpad (Seat 1)" }
        if ($script:CompareViewerSeat2Header) { $script:CompareViewerSeat2Header.Text = "$s2 Scratchpad (Seat 2)" }

        $raw = if (Test-Path $script:BlackboardPath) { [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8) } else { "" }
        $s1Esc = [regex]::Escape($s1)
        $s2Esc = [regex]::Escape($s2)
        $pad1 = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1|AI\s*1)(?:\s+Scratchpad)?"
        $pad2 = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2|AI\s*2)(?:\s+Scratchpad)?"

        if ($pad1 -ne $script:CompareViewerLastS1Text -or -not $script:CompareViewerRtb1.Document) {
            $script:CompareViewerLastS1Text = $pad1
            $script:CompareViewerRtb1.Document = Render-ScratchpadCompareDoc -text $pad1 -seatTitle $s1
        }
        if ($pad2 -ne $script:CompareViewerLastS2Text -or -not $script:CompareViewerRtb2.Document) {
            $script:CompareViewerLastS2Text = $pad2
            $script:CompareViewerRtb2.Document = Render-ScratchpadCompareDoc -text $pad2 -seatTitle $s2
        }

        $matchedAgreed = @(Get-SharedAgreedLines $pad1 $pad2)

        if ($script:CompareViewerPinnedPanel -and $script:CompareViewerPinnedAgreed) {
            if ($matchedAgreed.Count -gt 0) {
                $script:CompareViewerPinnedAgreed.Text = ($matchedAgreed | ForEach-Object { "- **Agreed**: $_" }) -join [Environment]::NewLine
                $script:CompareViewerPinnedPanel.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $script:CompareViewerPinnedPanel.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }

        $nowStr = Get-Date -Format "HH:mm:ss"
        if ($script:CompareViewerStatus) {
            $l1 = ($pad1 -split "`n").Count
            $l2 = ($pad2 -split "`n").Count
            $script:CompareViewerStatus.Text = "Updated $nowStr | ${s1}: $l1 lines | ${s2}: $l2 lines | Shared consensus items: $($matchedAgreed.Count)"
        }
        if ($script:CompareViewerHeaderInfo) {
            $script:CompareViewerHeaderInfo.Text = "$s1 vs $s2 | $nowStr"
        }
    } catch {
        if ($script:CompareViewerStatus) {
            $script:CompareViewerStatus.Text = "Error updating compare: $_"
        }
    }
}

function Show-CompareTurnsViewer {
    if ($script:CompareViewerWindow -and $script:CompareViewerWindow.IsVisible) {
        $script:CompareViewerWindow.Activate() | Out-Null
        Update-CompareTurnsViewer
        return
    }

    [xml]$compXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="⚖️ Scratchpad Compare Viewer (AI 1 vs AI 2)"
        Height="760" Width="1060"
        WindowStartupLocation="CenterScreen"
        Background="#181825" Foreground="#CDD6F4"
        FontFamily="Segoe UI">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Header -->
        <Border Grid.Row="0" Background="#1E1E2E" CornerRadius="6" Padding="10,6" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <StackPanel>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,8">
                    <TextBlock Text="⚖️ SCRATCHPAD COMPARE VIEWER" FontWeight="Bold" FontSize="12" Foreground="#89B4FA" VerticalAlignment="Center"/>
                    <TextBlock Name="txtCompareHeaderInfo" Text="Side-by-Side AI Turns" FontSize="10" Foreground="#BAC2DE" Background="#313244" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                    <Button Name="btnComparePromote" Content="Promote shared lines" Background="#A6E3A1" Foreground="#11111B" Padding="12,4" Margin="0,0,6,0" FontWeight="Bold" Cursor="Hand" ToolTip="Copy a sentence into Alignment when one scratchpad has - **Agreed**: and the other has - **Agree**"/>
                    <Button Name="btnCompareCopy" Content="Copy Both" Background="#313244" Foreground="#CDD6F4" Padding="10,4" Margin="0,0,6,0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button Name="btnCompareRefresh" Content="Refresh" Background="#313244" Foreground="#89B4FA" Padding="10,4" FontWeight="SemiBold" Cursor="Hand"/>
                </StackPanel>

                <!-- Pinned Consensus Panel -->
                <Border Name="pnlPinnedAgreed" Visibility="Collapsed" Background="#1E3A2F" BorderBrush="#A6E3A1" BorderThickness="1" CornerRadius="4" Padding="8,6" Margin="0,8,0,0">
                    <StackPanel>
                        <TextBlock Text="🤝 PINNED CONSENSUS (- **Agreed**:)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,4"/>
                        <TextBlock Name="txtPinnedAgreed" TextWrapping="Wrap" FontSize="12" Foreground="#CDD6F4" FontFamily="Consolas, Courier New, monospace"/>
                    </StackPanel>
                </Border>
            </StackPanel>
        </Border>

        <!-- Side-by-Side Body Grid -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Column 0: Seat 1 -->
            <Border Grid.Column="0" Background="#11111B" CornerRadius="6" BorderBrush="#313244" BorderThickness="1" Padding="4">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="#181825" Padding="6,4" Margin="0,0,0,4" CornerRadius="4">
                        <TextBlock Name="txtSeat1Header" Text="AI 1 Scratchpad" FontWeight="Bold" FontSize="11" Foreground="#89B4FA"/>
                    </Border>
                    <RichTextBox Name="rtbCompareSeat1" Grid.Row="1" IsReadOnly="True" IsTabStop="False" IsUndoEnabled="False"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                                 Background="#11111B" Foreground="#CDD6F4" BorderThickness="0" Padding="8,6"
                                 FontFamily="Consolas, Courier New, monospace" FontSize="12"/>
                </Grid>
            </Border>

            <!-- Column 1: GridSplitter -->
            <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="#313244"/>

            <!-- Column 2: Seat 2 -->
            <Border Grid.Column="2" Background="#11111B" CornerRadius="6" BorderBrush="#313244" BorderThickness="1" Padding="4">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="#181825" Padding="6,4" Margin="0,0,0,4" CornerRadius="4">
                        <TextBlock Name="txtSeat2Header" Text="AI 2 Scratchpad" FontWeight="Bold" FontSize="11" Foreground="#CBA6F7"/>
                    </Border>
                    <RichTextBox Name="rtbCompareSeat2" Grid.Row="1" IsReadOnly="True" IsTabStop="False" IsUndoEnabled="False"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                                 Background="#11111B" Foreground="#CDD6F4" BorderThickness="0" Padding="8,6"
                                 FontFamily="Consolas, Courier New, monospace" FontSize="12"/>
                </Grid>
            </Border>
        </Grid>

        <!-- Footer -->
        <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="4" Padding="8,4" Margin="0,6,0,0" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="txtCompareStatus" Text="Ready." FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="Modeless Split Viewer" FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader($compXaml)
    $compWin = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:CompareViewerWindow = $compWin
    $script:CompareViewerRtb1 = $compWin.FindName("rtbCompareSeat1")
    $script:CompareViewerRtb2 = $compWin.FindName("rtbCompareSeat2")
    $script:CompareViewerStatus = $compWin.FindName("txtCompareStatus")
    $script:CompareViewerHeaderInfo = $compWin.FindName("txtCompareHeaderInfo")
    $script:CompareViewerSeat1Header = $compWin.FindName("txtSeat1Header")
    $script:CompareViewerSeat2Header = $compWin.FindName("txtSeat2Header")
    $script:CompareViewerPinnedPanel = $compWin.FindName("pnlPinnedAgreed")
    $script:CompareViewerPinnedAgreed = $compWin.FindName("txtPinnedAgreed")
    $btnPromote = $compWin.FindName("btnComparePromote")
    $btnCopy = $compWin.FindName("btnCompareCopy")
    $btnRefresh = $compWin.FindName("btnCompareRefresh")

    $btnRefresh.add_Click({ Update-CompareTurnsViewer })
    $btnCopy.add_Click({
        try {
            $s1 = Get-Seat1Client
            $s2 = Get-Seat2Client
            $combined = "=== [$s1 SCRATCHPAD] ===" + [Environment]::NewLine + $script:CompareViewerLastS1Text + [Environment]::NewLine + [Environment]::NewLine + "=== [$s2 SCRATCHPAD] ===" + [Environment]::NewLine + $script:CompareViewerLastS2Text
            Safe-SetClipboard $combined
            if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "📋 Copied both scratchpads to clipboard." }
        } catch {
            if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "Copy failed: $_" }
        }
    })

    $btnPromote.add_Click({
        try {
            $raw = if (Test-Path $script:BlackboardPath) { [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8) } else { "" }
            $s1 = Get-Seat1Client
            $s2 = Get-Seat2Client
            $s1Esc = [regex]::Escape($s1)
            $s2Esc = [regex]::Escape($s2)
            $pad1 = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1|AI\s*1)(?:\s+Scratchpad)?"
            $pad2 = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2|AI\s*2)(?:\s+Scratchpad)?"

            $shared = @(Get-SharedAgreedLines $pad1 $pad2)
            $newItems = @()
            foreach ($item in $shared) {
                if (-not ($txtAlignment.Text -match [regex]::Escape($item))) {
                    $newItems += $item
                }
            }

            if ($newItems.Count -gt 0) {
                $appendLines = ($newItems | ForEach-Object { "- **Agreed**: $_" }) -join [Environment]::NewLine
                $joined = Join-TextWithSeparator -existing $txtAlignment.Text -addition $appendLines
                if ($joined -eq $txtAlignment.Text) { return }
                $txtAlignment.Text = $joined
                Save-BlackboardContent
                if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "Promoted $($newItems.Count) shared line(s) to Alignment and saved." }
                $txtStatus.Text = "Promoted $($newItems.Count) shared line(s) from Compare Viewer to Alignment."
            } elseif ($shared.Count -eq 0) {
                if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "No shared line yet. One scratchpad needs a - **Agreed**: sentence and the other needs - **Agree**." }
                $txtStatus.Text = "Promote found no shared line."
            } else {
                if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "Those shared lines are already in Alignment." }
            }
        } catch {
            if ($script:CompareViewerStatus) { $script:CompareViewerStatus.Text = "Promote error: $_" }
        }
    })

    $compWin.add_Closed({
        $script:CompareViewerWindow = $null
        $script:CompareViewerRtb1 = $null
        $script:CompareViewerRtb2 = $null
        $script:CompareViewerStatus = $null
        $script:CompareViewerHeaderInfo = $null
        $script:CompareViewerSeat1Header = $null
        $script:CompareViewerSeat2Header = $null
        $script:CompareViewerPinnedPanel = $null
        $script:CompareViewerPinnedAgreed = $null
    })

    $compWin.Show()
    Update-CompareTurnsViewer
}

if ($btnViewCompare) {
    $btnViewCompare.add_Click({ Show-CompareTurnsViewer })
}

if ($btnPromoteNotes) {
    $btnPromoteNotes.add_Click({
        $rawNotes = $txtHumanNotes.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rawNotes) -or $rawNotes -eq "- Active steering notes.") {
            [System.Windows.MessageBox]::Show("Human Notes are empty or default. Enter steering notes first.", "Promote Notes", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        $confirm = [System.Windows.MessageBox]::Show("Promote Human Notes to Current Objective & Prompt?`n`n[Notes Preview]:`n$rawNotes`n`nNote: This will update the Prompt field and mark blackboard dirty. It will not auto-send or create an issue.", "Confirm Promote Notes", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $clean = $rawNotes -replace '^(?:-\s*|\*\s*)', ''
            $txtPrompt.Text = $clean
            Mark-FormDirty
            $txtStatus.Text = "Human Notes promoted to Current Objective & Prompt."
        }
    })
}

function Get-FlowControlString {
    if ($rbStop.IsChecked) { return "$([char]::ConvertFromUtf32(0x1F534)) ALL STOP" }
    if ($rbPause.IsChecked) { return "$([char]::ConvertFromUtf32(0x1F7E1)) PAUSE (Wait for Human)" }
    return "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
}

function Get-PhaseString {
    $item = $cbPhase.SelectedItem
    if ($item) {
        return ($item.Content -split " ")[0].ToLower()
    }
    return "pitch"
}

$script:SuppressPresetSync = $false
$script:LastAutoAdvanceTime = [DateTime]::MinValue
$script:PhaseAdvanceGateLatched = $false
$script:PhaseAdvanceUncheckObserved = $false
$script:SuppressAutoAdvanceLatchReset = $false
$script:SuppressPhaseAutoAdvance = $false
$script:NewSignoffDuringLoad = $false
$script:PendingUnsignedRollback = $false
$script:NewerScriptSinceUtc = $null
$script:NewerScriptWriteTime = [DateTime]::MinValue
$script:AutoRelaunchStarted = $false
$script:AutoRelaunchSettleSeconds = 8

function Read-SignoffBaseline {
    if ($null -ne $script:CursorPadAtPhaseChange -or $null -ne $script:GeminiPadAtPhaseChange) { return }
    if (-not (Test-Path $script:SignoffBaselinePath)) { return }
    try {
        $saved = Get-Content -Raw -Path $script:SignoffBaselinePath | ConvertFrom-Json
        $script:CursorPadAtPhaseChange = [string]$saved.cursor
        $script:GeminiPadAtPhaseChange = [string]$saved.gemini
    } catch {}
}

function Save-SignoffBaseline {
    try {
        $payload = [ordered]@{
            cursor = [string]$script:CursorPadAtPhaseChange
            gemini = [string]$script:GeminiPadAtPhaseChange
        }
        ($payload | ConvertTo-Json -Compress) | Set-Content -Path $script:SignoffBaselinePath -Encoding UTF8
    } catch {}
}

function Sync-PresetFromPhase {
    param([string]$phaseName)
    if ($script:SuppressPresetSync -or -not $cbPresets) { return }
    if ([string]::IsNullOrWhiteSpace($phaseName)) {
        $phaseName = Get-PhaseString
    }
    $p = $phaseName.Trim().ToLower()
    $targetTag = switch ($p) {
        "pitch"     { "Pitch" }
        "discuss"   { "Discuss" }
        "advise"    { "Discuss" }
        "plan"      { "Plan" }
        "implement" { "Implement" }
        "review"    { "Review" }
        "test"      { "Test" }
        default     { $null }
    }
    $script:SuppressPresetSync = $true
    try {
        if ($null -eq $targetTag) {
            $cbPresets.SelectedIndex = -1
        } else {
            $found = $false
            for ($i = 0; $i -lt $cbPresets.Items.Count; $i++) {
                $item = $cbPresets.Items[$i]
                $tag = if ($item.Tag) { [string]$item.Tag } else { [string]$item.Content }
                if ($tag -match "(?i)^$targetTag") {
                    if ($cbPresets.SelectedIndex -ne $i) {
                        $cbPresets.SelectedIndex = $i
                    }
                    $found = $true
                    break
                }
            }
            if (-not $found) { $cbPresets.SelectedIndex = -1 }
        }
    } finally {
        $script:SuppressPresetSync = $false
    }
}

function Set-RolesForPhase {
    param([string]$phaseName)
    if (-not $cbCursorRole -or -not $cbGeminiRole) { return }
    if ([string]::IsNullOrWhiteSpace($phaseName)) { return }
    switch ($phaseName.Trim().ToLower()) {
        "pitch"     { $cbCursorRole.SelectedIndex = 2; $cbGeminiRole.SelectedIndex = 2 }
        "discuss"   { $cbCursorRole.SelectedIndex = 2; $cbGeminiRole.SelectedIndex = 2 }
        "advise"    { $cbCursorRole.SelectedIndex = 2; $cbGeminiRole.SelectedIndex = 2 }
        "plan"      { $cbCursorRole.SelectedIndex = 4; $cbGeminiRole.SelectedIndex = 5 }
        "implement" { $cbCursorRole.SelectedIndex = 1; $cbGeminiRole.SelectedIndex = 1 }
        "review"    { $cbCursorRole.SelectedIndex = 1; $cbGeminiRole.SelectedIndex = 0 }
        "test"      { $cbCursorRole.SelectedIndex = 1; $cbGeminiRole.SelectedIndex = 0 }
        "closing"   { $cbCursorRole.SelectedIndex = 5; $cbGeminiRole.SelectedIndex = 5 }
        "closed"    { $cbCursorRole.SelectedIndex = 5; $cbGeminiRole.SelectedIndex = 5 }
    }
}

function Set-Phase {
    param([string]$targetPhase)
    if ([string]::IsNullOrWhiteSpace($targetPhase)) { return }
    $tgt = $targetPhase.Trim().ToLower()
    for ($i = 0; $i -lt $cbPhase.Items.Count; $i++) {
        $itemText = [string]$cbPhase.Items[$i].Content
        $token = ($itemText -split " ")[0].ToLower()
        if ($token -eq $tgt -or ($tgt -eq "advise" -and $token -eq "discuss") -or ($tgt -eq "discuss" -and $token -eq "advise")) {
            $cbPhase.SelectedIndex = $i
            Sync-PresetFromPhase $tgt
            return
        }
    }
}

function Get-NextPhase {
    param([string]$currentPhase)
    switch ($currentPhase.ToLower()) {
        "pitch"     { return "discuss" }
        "discuss"   { return "implement" }
        "advise"    { return "implement" }
        "plan"      { return "implement" }
        "implement" { return "test" }
        "review"    { return "test" }
        "test"      { return "closing" }
        "closing"   { return "closing" }
        "closed"    { return "closed" }
        default     { return "closed" }
    }
}

function Check-PhaseAutoAdvance {
    if ($script:SuppressPhaseAutoAdvance) { return }
    if ($chkAutoStep -and -not $chkAutoStep.IsChecked) { return }
    $flow = Get-FlowControlString
    if ($flow -match "STOP|PAUSE") { return }

    if ($script:PhaseAdvanceGateLatched) { return }

    if (-not ($chkSignHuman.IsChecked -and $chkSignCursor.IsChecked -and $chkSignGemini.IsChecked)) {
        return
    }

    if ($script:LastAutoAdvanceTime -and ([DateTime]::UtcNow - $script:LastAutoAdvanceTime).TotalSeconds -lt 3) {
        return
    }

    $currentPhase = Get-PhaseString
    if ($currentPhase -eq "closing" -or $currentPhase -eq "closed") { return }

    $nextPhase = Get-NextPhase $currentPhase
    if ($nextPhase -eq $currentPhase) { return }

    $script:LastAutoAdvanceTime = [DateTime]::UtcNow
    $script:PhaseAdvanceGateLatched = $true
    $script:PhaseAdvanceUncheckObserved = $false
    $script:SuppressAutoAdvanceLatchReset = $true
    $script:SuppressFormDirty = $true
    try {
        $chkSignHuman.IsChecked = $false
        $chkSignCursor.IsChecked = $false
        $chkSignGemini.IsChecked = $false

        $raw = if (Test-Path $script:BlackboardPath) { [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8) } else { "" }
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $s1Esc = [regex]::Escape($s1)
        $s2Esc = [regex]::Escape($s2)
        $cPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1)(?:\s+Scratchpad)?"
        $gPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?"
        $script:CursorPadAtPhaseChange = if ($cPad) { ($cPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
        $script:GeminiPadAtPhaseChange = if ($gPad) { ($gPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
        Save-SignoffBaseline

        Set-Phase $nextPhase
        Set-RolesForPhase $nextPhase
        $txtStatus.Text = "Phase auto-advanced: $currentPhase -> $nextPhase (all 3 sign-offs complete)."
        Save-BlackboardContent
        Update-UiActiveTurn -keepOverride
    } finally {
        $script:SuppressAutoAdvanceLatchReset = $false
        $script:SuppressFormDirty = $false
        $allSigned = $chkSignHuman.IsChecked -and $chkSignCursor.IsChecked -and $chkSignGemini.IsChecked
        if (-not $allSigned) {
            $script:PhaseAdvanceGateLatched = $false
            $script:PhaseAdvanceUncheckObserved = $false
        }
    }
}

function Invoke-UnsignedTestRollback {
    if (-not $script:PendingUnsignedRollback) { return }
    $script:PendingUnsignedRollback = $false
    $phaseNow = Get-PhaseString
    if ($phaseNow -ne "test" -and $phaseNow -ne "closing") { return }
    if ($chkAutoStep -and -not $chkAutoStep.IsChecked) { return }
    $flow = Get-FlowControlString
    if ($flow -match "STOP|PAUSE") { return }

    $script:SuppressPhaseAutoAdvance = $true
    $script:SuppressFormDirty = $true
    try {
        if ($chkSignHuman) { $chkSignHuman.IsChecked = $false }
        if ($chkSignCursor) { $chkSignCursor.IsChecked = $false }
        if ($chkSignGemini) { $chkSignGemini.IsChecked = $false }
        Set-Phase "implement"
        Set-RolesForPhase "implement"
        if ($txtStatus) { $txtStatus.Text = "Auto step: an AI $phaseNow turn has no Sign-off [x]. Phase returned to implement." }
        Save-BlackboardContent
        Update-UiActiveTurn -keepOverride
    } finally {
        $script:SuppressPhaseAutoAdvance = $false
        $script:SuppressFormDirty = $false
    }
}

function Promote-SelectedBulletToAlignment {
    param(
        [System.Windows.Controls.RichTextBox]$rtbSource,
        [string]$seatName
    )
    try {
        $selectedText = if ($rtbSource -and $rtbSource.Selection) { $rtbSource.Selection.Text.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($selectedText)) {
            if ($txtStatus) { $txtStatus.Text = "Please highlight text in the $seatName response pane to promote to Alignment." }
            return
        }

        $clean = $selectedText -replace '^(?:-\s*|\*\s*)', '' -replace '^`?-\s*\*\*Agreed\*\*`?\s*:\s*', ''
        $clean = $clean.Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) { return }
        $lineToAdd = "- **Agreed**: $clean"

        if ($txtAlignment.Text -match [regex]::Escape($clean)) {
            if ($txtStatus) { $txtStatus.Text = "Proposal already exists in Alignment." }
            return
        }

        $joined = Join-TextWithSeparator -existing $txtAlignment.Text -addition $lineToAdd
        if ($joined -eq $txtAlignment.Text) { return }
        $txtAlignment.Text = $joined

        Mark-FormDirty
        Save-BlackboardContent
        if ($txtStatus) { $txtStatus.Text = "Promoted selected text from $seatName into Alignment." }
    } catch {
        if ($txtStatus) { $txtStatus.Text = "Promote error: $_" }
    }
}

function Get-ActiveTurn {
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client

    $signHuman = $chkSignHuman.IsChecked
    $signCursor = $chkSignCursor.IsChecked
    $signGemini = $chkSignGemini.IsChecked

    # 1. Flow control paused or stopped -> Waiting on human (even if boxes are checked)
    $flow = Get-FlowControlString
    if ($flow -match "STOP|PAUSE") {
        $badgeTurn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
        $txtActiveTurn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        return "👤 Waiting on Human (Lead) [$flow]"
    }

    # 2. Closed phase with all 3 signed off -> Ready to close / archive
    $phaseNow = Get-PhaseString
    if ($signHuman -and $signCursor -and $signGemini -and ($phaseNow -eq "closing" -or $phaseNow -eq "closed")) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkGreen
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return "✅ Complete - Ready to Close"
    }

    # 3. Active Turn Override (Agent responded)
    if ($script:ActiveTurnOverride) {
        $s2Esc = [regex]::Escape($s2)
        if ($script:ActiveTurnOverride -match "$s2Esc|Gemini|AI 2|Agent 2") {
            $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkBlue
        } else {
            $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkCyan
        }
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return $script:ActiveTurnOverride
    }

    # 4. Check active agents
    $cRole = Get-ComboRoleText $cbCursorRole
    if (-not $cRole) { $cRole = "idle" }
    $gRole = Get-ComboRoleText $cbGeminiRole
    if (-not $gRole) { $gRole = "idle" }

    # Prefer implementer turn first
    if ($cRole -eq "implement" -and -not $signCursor) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkCyan
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return ("$s1 (implement)")
    }
    if ($gRole -eq "implement" -and -not $signGemini) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkBlue
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return ("$s2 (implement)")
    }

    # Active non-idle agents
    if ($cRole -ne "idle" -and -not $signCursor) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkCyan
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return ("$s1 (" + $cRole + ")")
    }
    if ($gRole -ne "idle" -and -not $signGemini) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkBlue
        $txtActiveTurn.Foreground = [System.Windows.Media.Brushes]::White
        return ("$s2 (" + $gRole + ")")
    }

    # 5. Neither agent active or both signed off -> Waiting on human
    $badgeTurn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
    $txtActiveTurn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
    return "👤 Waiting on Human (Lead)"
}

function Update-UiActiveTurn {
    param([switch]$keepOverride)
    if ($script:SuppressTurnReset -and -not $keepOverride) {
        return
    }
    if (-not $keepOverride) {
        $script:ActiveTurnOverride = $null
        $script:TurnCueExpiresAt = $null
    }
    $txtActiveTurn.Text = Get-ActiveTurn
    if ($btnCloseProject) {
        $phaseForClose = Get-PhaseString
        if (($phaseForClose -eq "closing" -or $phaseForClose -eq "closed") -and $chkSignHuman.IsChecked -and $chkSignCursor.IsChecked -and $chkSignGemini.IsChecked) {
            $btnCloseProject.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
            $btnCloseProject.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        } else {
            $btnCloseProject.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#313244")
            $btnCloseProject.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
        }
    }
}

function Get-ComboRoleText {
    param($combo)
    if ($combo -and $combo.SelectedItem -and $combo.SelectedItem.Content) {
        return [string]$combo.SelectedItem.Content
    }
    if ($combo -and $combo.Text) { return [string]$combo.Text }
    return ""
}

function Check-Safety {
    $cursor = Get-ComboRoleText $cbCursorRole
    $gemini = Get-ComboRoleText $cbGeminiRole
    if ($cursor -eq "implement" -and $gemini -eq "implement") {
        $txtSafetyWarning.Text = "⚠️ SAFETY WARNING: Both agents set to implement! Conflict risk."
        $txtSafetyWarning.Foreground = [System.Windows.Media.Brushes]::Salmon
    } else {
        $txtSafetyWarning.Text = ""
    }
    Update-UiActiveTurn
}

function Mark-FormDirty {
    if (-not $script:SuppressFormDirty) {
        $script:FormDirty = $true
    }
}

$cbCursorRole.add_SelectionChanged({ Check-Safety; Mark-FormDirty })
$cbGeminiRole.add_SelectionChanged({ Check-Safety; Mark-FormDirty })
$cbPhase.add_SelectionChanged({
    if (-not $script:SuppressPresetSync) {
        Sync-PresetFromPhase (Get-PhaseString)
    }
    if (-not $script:SuppressAutoAdvanceLatchReset) {
        $script:PhaseAdvanceGateLatched = $false
        $script:PhaseAdvanceUncheckObserved = $false
    }
    Ensure-PitchSeatsAdvise
    Mark-FormDirty
})
$rbGo.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$rbPause.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$rbStop.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignHuman.add_Checked({
    if ($script:PhaseAdvanceGateLatched -and $script:PhaseAdvanceUncheckObserved) {
        $script:PhaseAdvanceGateLatched = $false
        $script:PhaseAdvanceUncheckObserved = $false
    }
    Check-PhaseAutoAdvance
    Update-UiActiveTurn
    Mark-FormDirty
})
$chkSignHuman.add_Unchecked({
    if (-not $script:SuppressAutoAdvanceLatchReset) {
        $script:PhaseAdvanceUncheckObserved = $true
    }
    Update-UiActiveTurn
    Mark-FormDirty
})
$chkSignCursor.add_Checked({
    if ($script:PhaseAdvanceGateLatched -and $script:PhaseAdvanceUncheckObserved) {
        $script:PhaseAdvanceGateLatched = $false
        $script:PhaseAdvanceUncheckObserved = $false
    }
    Check-PhaseAutoAdvance
    Update-UiActiveTurn
    Mark-FormDirty
})
$chkSignCursor.add_Unchecked({
    if (-not $script:SuppressAutoAdvanceLatchReset) {
        $script:PhaseAdvanceUncheckObserved = $true
    }
    Update-UiActiveTurn
    Mark-FormDirty
})
$chkSignGemini.add_Checked({
    if ($script:PhaseAdvanceGateLatched -and $script:PhaseAdvanceUncheckObserved) {
        $script:PhaseAdvanceGateLatched = $false
        $script:PhaseAdvanceUncheckObserved = $false
    }
    Check-PhaseAutoAdvance
    Update-UiActiveTurn
    Mark-FormDirty
})
$chkSignGemini.add_Unchecked({
    if (-not $script:SuppressAutoAdvanceLatchReset) {
        $script:PhaseAdvanceUncheckObserved = $true
    }
    Update-UiActiveTurn
    Mark-FormDirty
})
$txtPrompt.add_TextChanged({ Mark-FormDirty })
$txtAlignment.add_TextChanged({ Mark-FormDirty })
$txtHumanNotes.add_TextChanged({ Mark-FormDirty })
if ($rtbCursorLast) {
    $rtbCursorLast.add_SizeChanged({
        if ($rtbCursorLast.Document -and $rtbCursorLast.ActualWidth -gt 48) {
            $rtbCursorLast.Document.PageWidth = $rtbCursorLast.ActualWidth - 16
        }
    })
    $menu1 = New-Object System.Windows.Controls.ContextMenu
    $item1 = New-Object System.Windows.Controls.MenuItem
    $item1.Header = "🤝 Promote to Alignment"
    $item1.add_Click({
        Promote-SelectedBulletToAlignment -rtbSource $rtbCursorLast -seatName (Get-Seat1Client)
    })
    [void]$menu1.Items.Add($item1)
    $rtbCursorLast.ContextMenu = $menu1
}
if ($rtbGeminiLast) {
    $rtbGeminiLast.add_SizeChanged({
        if ($rtbGeminiLast.Document -and $rtbGeminiLast.ActualWidth -gt 48) {
            $rtbGeminiLast.Document.PageWidth = $rtbGeminiLast.ActualWidth - 16
        }
    })
    $menu2 = New-Object System.Windows.Controls.ContextMenu
    $item2 = New-Object System.Windows.Controls.MenuItem
    $item2.Header = "🤝 Promote to Alignment"
    $item2.add_Click({
        Promote-SelectedBulletToAlignment -rtbSource $rtbGeminiLast -seatName (Get-Seat2Client)
    })
    [void]$menu2.Items.Add($item2)
    $rtbGeminiLast.ContextMenu = $menu2
}
if ($btnPromoteSeat1) {
    $btnPromoteSeat1.add_Click({
        Promote-SelectedBulletToAlignment -rtbSource $rtbCursorLast -seatName (Get-Seat1Client)
    })
}
if ($btnPromoteSeat2) {
    $btnPromoteSeat2.add_Click({
        Promote-SelectedBulletToAlignment -rtbSource $rtbGeminiLast -seatName (Get-Seat2Client)
    })
}
$txtIssueNum.add_TextChanged({
    Mark-FormDirty
    if (-not $txtIssueNum.Text.Trim()) {
        $txtIssueTitle.Text = ""
    }
})

function Get-NormalizedRole {
    param([string]$role)
    if ([string]::IsNullOrWhiteSpace($role)) { return "idle" }
    return (($role.Trim() -split '\s+')[0]).ToLower()
}

function Test-CloseProjectAllowedPath {
    param([string]$relPath)
    $n = ($relPath -replace '\\', '/').Trim().Trim('"')
    if ($n -match '(^|/)\.env($|\.)' -or $n -match '\.pem$' -or $n -match '(?i)secret|credential') { return $false }
    if ($n -eq 'scripts/blackboard-ui.ps1') { return $true }
    if ($n -in @('docs/STATUS.md', 'docs/collaboration.md', 'docs/CHANGELOG.md', 'AGENTS.md', 'GEMINI.md')) { return $true }
    if ($n.StartsWith('.cursor/rules/')) { return $true }
    return $false
}

function Get-CloseProjectGitAudit {
    $raw = @(git -C $script:RepoRoot status --porcelain -uall 2>$null)
    $tracked = [System.Collections.Generic.List[string]]::new()
    $untracked = [System.Collections.Generic.List[string]]::new()
    $allowed = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $isUntracked = $line.StartsWith('??')
        $path = $line.Substring([Math]::Min(3, $line.Length)).Trim()
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim('"') -replace '\\', '/'
        if ($path -match '(^|/)\.ai/') { continue }
        if ($isUntracked) { [void]$untracked.Add($path); continue }
        [void]$tracked.Add($path)
        if (Test-CloseProjectAllowedPath $path) { [void]$allowed.Add($path) } else { [void]$blocked.Add($path) }
    }
    [pscustomobject]@{
        Tracked   = @($tracked)
        Untracked = @($untracked)
        Allowed   = @($allowed)
        Blocked   = @($blocked)
    }
}

function Update-GitStatusSummary {
    if (-not $txtGitStatusSummary) { return }
    try {
        $branch = (git -C $script:RepoRoot branch --show-current 2>$null)
        if (-not $branch) { $branch = "detached" }
        $rawStatus = @(git -C $script:RepoRoot status --porcelain -uall 2>$null)
        $dirty = @($rawStatus | Where-Object { $_ -and $_.Trim() -and ($_ -notmatch '(?i)(^|/)\.ai/') })
        if ($dirty.Count -gt 0) {
            $txtGitStatusSummary.Text = "Git: $branch ($($dirty.Count) changed)"
            $txtGitStatusSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
            $firstFiles = ($dirty | Select-Object -First 8) -join "`n"
            $txtGitStatusSummary.ToolTip = "Branch: $branch`nUncommitted changes ($($dirty.Count)):`n$firstFiles"
        } else {
            $txtGitStatusSummary.Text = "Git: $branch (clean)"
            $txtGitStatusSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
            $txtGitStatusSummary.ToolTip = "Branch: $branch`nWorking tree clean."
        }
    } catch {
        $txtGitStatusSummary.Text = "Git: unavailable"
    }
}

function Invoke-CloseProjectGitShip {
    param([bool]$allSigned)
    if (-not $allSigned) { return }
    $audit = Get-CloseProjectGitAudit
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("Git audit before Close Project ($script:AppVersion):")
    if ($audit.Allowed.Count -gt 0) { [void]$lines.Add("Allowlisted dirty (can commit):`n  " + ($audit.Allowed -join "`n  ")) } else { [void]$lines.Add("Allowlisted dirty: none") }
    if ($audit.Blocked.Count -gt 0) { [void]$lines.Add("Other tracked dirty (will NOT auto-commit):`n  " + ($audit.Blocked -join "`n  ")) }
    if ($audit.Untracked.Count -gt 0) { [void]$lines.Add("Untracked (will NOT auto-add):`n  " + ($audit.Untracked -join "`n  ")) }
    [void]$lines.Add("")
    if ($audit.Allowed.Count -gt 0) {
        [void]$lines.Add("Commit allowlisted files now?")
        $commitAsk = [System.Windows.MessageBox]::Show(($lines -join "`n"), "Close Project git audit", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($commitAsk -eq [System.Windows.MessageBoxResult]::Yes) {
        foreach ($p in $audit.Allowed) {
            git -C $script:RepoRoot add -- $p
        }
        $issueHint = $txtIssueNum.Text.Trim()
        $msg = if ($issueHint -and $issueHint -ne "none") {
            "chore(controller): ship on Close Project $script:AppVersion (Refs #$issueHint)"
        } else {
            "chore(controller): ship on Close Project $script:AppVersion"
        }
        git -C $script:RepoRoot commit -m $msg
        if ($LASTEXITCODE -ne 0) {
            $txtStatus.Text = "Warning: git commit on Close Project failed (exit $LASTEXITCODE)."
        }
        }
    }
    git -C $script:RepoRoot fetch origin main 2>$null | Out-Null
    $aheadStr = (git -C $script:RepoRoot rev-list --count origin/main..HEAD 2>$null)
    $behindStr = (git -C $script:RepoRoot rev-list --count HEAD..origin/main 2>$null)
    $aheadCount = 0
    $behindCount = 0
    if ($aheadStr -match '^\d+$') { $aheadCount = [int]$aheadStr }
    if ($behindStr -match '^\d+$') { $behindCount = [int]$behindStr }

    if ($behindCount -gt 0) {
        # Pre-flight conflict dry run using modern git merge-tree --write-tree
        $hasConflicts = $false
        $mergeTreeOut = @(git -C $script:RepoRoot merge-tree --write-tree HEAD origin/main 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($mergeTreeOut -match 'CONFLICT|conflicts')) {
            $hasConflicts = $true
        }
        if ($hasConflicts) {
            [System.Windows.MessageBox]::Show("Pre-flight conflict dry-run FAILED:`n`nLocal main is behind origin/main by $behindCount commit(s) and potential MERGE CONFLICTS were detected.`n`nPush cannot succeed. Please pull and rebase manually before closing.", "Pre-Flight Conflict Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            $txtStatus.Text = "Pre-flight check: $behindCount commits behind origin/main with conflicts."
        } else {
            [System.Windows.MessageBox]::Show("Pre-flight dry-run check:`n`nLocal main is behind origin/main by $behindCount commit(s).`n`nPush will be rejected until local is updated. Please pull/rebase with origin/main.", "Branch Behind origin/main", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            $txtStatus.Text = "Pre-flight check: $behindCount commits behind origin/main."
        }
    } elseif ($aheadCount -gt 0) {
        $pushPrompt = [System.Windows.MessageBox]::Show("Pre-flight dry-run PASSED: Clean fast-forward verified (0 behind, $aheadCount ahead).`n`nPush to origin/main now?", "Upload to GitHub (Pre-flight Passed)", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($pushPrompt -eq [System.Windows.MessageBoxResult]::Yes) {
            $txtStatus.Text = "Pushing to origin/main..."
            git -C $script:RepoRoot push origin main
            if ($LASTEXITCODE -eq 0) {
                $txtStatus.Text = "Pushed to origin/main."
            } else {
                [System.Windows.MessageBox]::Show("git push failed (exit $LASTEXITCODE). Archive will still run. Pull/rebase if needed.", "Push failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                $txtStatus.Text = "Warning: push failed (exit $LASTEXITCODE)."
            }
        }
    } else {
        $txtStatus.Text = "Pre-flight check: Local is synchronized with origin/main (0 ahead, 0 behind)."
    }
}

function Get-RoleGuidance {
    param([string]$role)
    $boardPath = $script:BlackboardPath
    $phase = Get-PhaseString
    if ($phase -eq "closed") {
        return "This project/objective is CLOSED. All sign-offs complete. Hold IDLE. Do not modify files or execute tasks unless a new objective is assigned."
    }
    if ($phase -eq "closing") {
        return "Project phase is CLOSING. Your role is idle. Do not edit tracked files or start new work. Your one action is the final sign-off: write Sign-off: [x] on your top scratchpad bullet and mark your Agent Roles row [x] so the Human Lead can press Close Project."
    }
    if ($phase -eq "test") {
        return "Project phase is TEST. Verify the program/script/UI already landed. Exercise the live controller or script under test (do not relaunch a second blackboard-ui unless asked). Record pass/fail in your scratchpad. FORBIDDEN: new features. After a recorded pass (or N/A with why), set your Agent Roles Sign-off [x] and scratchpad Sign-off: [x]. GO does not mean implement."
    }
    if ($phase -eq "pitch") {
        return "Project phase is PITCH. Suggest additions, improvements, updates, fixes, or alternatives to whatever is listed in the current objective. Human has the final say on what moves on to discussion. FORBIDDEN: editing tracked files, git operations. Propose options with trade-offs in your scratchpad. End your note with your proposals and phase sign-off when aligned."
    }
    switch (Get-NormalizedRole $role) {
        "implement" { "You hold IMPLEMENT. Review objective and Alignment in '$boardPath', then land the change. Append progress under your scratchpad heading only. Do not edit the other agent's scratchpad or the Human Lead's notes." }
        "review"    { "You hold REVIEW. Read the implementer's notes and diff. Record findings in your scratchpad. FORBIDDEN: editing the same tracked files they are changing. GO does not make you implement." }
        "advise"    { "You hold ADVISE. Analyze and recommend in your scratchpad only. FORBIDDEN: editing tracked repo files, git commit/push, live infrastructure changes. REQUIRED: Edit '$boardPath' under your scratchpad heading. End your note with `- **Agreed**: <decision>` sentences, or a single `- **Agree**` if the other agent's scratchpad is already right, so consensus auto-promotes to Alignment." }
        "plan"      { "You hold PLAN. Propose approach and risks in your scratchpad. Do not edit tracked files unless the Human Lead says so." }
        "inventory" { "You hold INVENTORY. Read environment/tools/git log. No live writes. No tracked-file edits except your blackboard scratchpad." }
        default     { "You hold IDLE. Read the board. Do not act. Do not edit files. Wait." }
    }
}

function Get-NonImplementHardStop {
    param([string]$role)
    $boardPath = $script:BlackboardPath
    if ((Get-PhaseString) -eq "closed") {
        return @"
NOTICE: Project phase is CLOSED. All sign-offs have been completed.
Hold IDLE. Do not modify files, execute tasks, or make commits unless the Human Lead assigns a new active objective.

"@
    }
    if ((Get-PhaseString) -eq "closing") {
        return @"
NOTICE: Project phase is CLOSING. Both seats are idle.
Do not edit tracked files or start new work. Your one action is the final sign-off so the Human Lead can press Close Project.

"@
    }
    $phase = Get-PhaseString
    $r = Get-NormalizedRole $role
    if ($phase -eq "pitch") {
        return @"
STOP. Project phase is pitch. Both seats stay advise.
FORBIDDEN: editing tracked repository files, git commit/push, live production/infrastructure changes.
ALLOWED & REQUIRED: Edit '$boardPath' using your file editing tool under your scratchpad section only (append/update; do not wipe the Human Lead or the other agent).
Flow Control GO means continue in this role — it does not promote you to implement.
If your role is not implement, ignore the GitHub issue's implementation checklist.

"@
    }
    if ($r -eq "implement") { return "" }
    return @"
STOP. Assigned role is $r, not implement.
FORBIDDEN: editing tracked repository files, git commit/push, live production/infrastructure changes.
ALLOWED & REQUIRED: Edit '$boardPath' using your file editing tool under your scratchpad section only (append/update; do not wipe the Human Lead or the other agent).
Flow Control GO means continue in this role — it does not promote you to implement.
If your role is not implement, ignore the GitHub issue's implementation checklist.

"@
}

function Get-SignOffGuidance {
    $phase = Get-PhaseString
    if ($phase -eq "closed") { return "" }
    if ($phase -eq "test") {
        return @"

Sign-off: after you record test evidence, set your Agent Roles Sign-off [x] and scratchpad Sign-off: [x].
"@
    }
    return @"

Phase Sign-off: when your work for the '$phase' phase is complete and aligned, set your Agent Roles Sign-off [x] and scratchpad Sign-off: [x] to advance to the next phase.
"@
}

function Get-AlignmentBlock {
    $align = ""
    if ($txtAlignment -and $txtAlignment.Text) { $align = $txtAlignment.Text.Trim() }
    if (-not $align -or $align -eq "---") { return "" }
    if ($align -match '(?m)^## Working Notes') { return "" }
    return @"

Alignment (binding — do not override from the GitHub issue title):
$align
"@
}

function Get-LatestScratchpadSummary {
    $boardPath = $script:BlackboardPath
    if (-not (Test-Path $boardPath)) { return "" }
    try {
        $raw = [System.IO.File]::ReadAllText($boardPath, [System.Text.Encoding]::UTF8)
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $s1Esc = [regex]::Escape($s1)
        $s2Esc = [regex]::Escape($s2)

        $cPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1|AI\s*1)(?:\s+Scratchpad)?"
        $gPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2|AI\s*2)(?:\s+Scratchpad)?"

        $cRole = if ($cbCursorRole -and $cbCursorRole.Text) { $cbCursorRole.Text } else { "" }
        $gRole = if ($cbGeminiRole -and $cbGeminiRole.Text) { $cbGeminiRole.Text } else { "" }

        $cEx = if ($cPad -and $cPad -notmatch "(?i)^-\s*\((?:$s1Esc|Cursor|Agent\s*1|AI\s*1)\s+(?:updates?|scratchpad)") {
            Get-ScratchpadExcerpt $cPad -PreferRole $cRole -maxLines 15 -maxChars 2000
        } else { "" }
        $gEx = if ($gPad -and $gPad -notmatch "(?i)^-\s*\((?:$s2Esc|Gemini|Agent\s*2|AI\s*2)\s+(?:updates?|scratchpad)") {
            Get-ScratchpadExcerpt $gPad -PreferRole $gRole -maxLines 15 -maxChars 2000
        } else { "" }

        $parts = @()
        if ($cEx) {
            $parts += "### $s1 (Latest Turn):"
            $parts += $cEx.Trim()
        }
        if ($gEx) {
            if ($parts.Count -gt 0) { $parts += "" }
            $parts += "### $s2 (Latest Turn):"
            $parts += $gEx.Trim()
        }
        if ($parts.Count -gt 0) {
            return @"

Latest Notes (scratchpad latest turn only):
$($parts -join [Environment]::NewLine)
"@
        }
    } catch {}
    return ""
}

function Get-KickoffPromptForAgent {
    param(
        [string]$agentName,
        [string]$role,
        [string]$seatId = "seat1"
    )

    $normRole = Get-NormalizedRole $role
    $flow = Get-FlowControlString
    $phase = Get-PhaseString
    $issueNum = $txtIssueNum.Text.Trim()
    $issueText = if ($issueNum -and $issueNum -ne "none") { " for GitHub Issue #$issueNum" } else { "" }
    $boardPath = $script:BlackboardPath
    $objective = $txtPrompt.Text.Trim()
    if (-not $objective) { $objective = "(Refer to $boardPath)" }

    $hardStop = Get-NonImplementHardStop $normRole
    $alignBlock = Get-AlignmentBlock
    $latestNotes = Get-LatestScratchpadSummary
    $roleGuidance = Get-RoleGuidance $normRole
    $signOffGuidance = Get-SignOffGuidance
    $sNameEsc = [regex]::Escape($agentName)
    $scratchpadSection = if ($seatId -eq "seat1" -or $agentName -match 'Cursor|Agent\s*1|AI\s*1') {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### $sNameEsc Scratchpad" -Quiet)) { "### $agentName Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### AI 1 Scratchpad" -Quiet)) { "### AI 1 Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Cursor Scratchpad" -Quiet)) { "### Cursor Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Agent 1 Scratchpad" -Quiet)) { "### Agent 1 Scratchpad" }
        else { "### $agentName Scratchpad" }
    } else {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### $sNameEsc Scratchpad" -Quiet)) { "### $agentName Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### AI 2 Scratchpad" -Quiet)) { "### AI 2 Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Gemini \(Antigravity\) Scratchpad" -Quiet)) { "### Gemini (Antigravity) Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Agent 2 Scratchpad" -Quiet)) { "### Agent 2 Scratchpad" }
        else { "### $agentName Scratchpad" }
    }

    $mandatoryBlock = if ($normRole -eq "implement") {
@"
MANDATORY ACTION:
1. Blackboard Updates: Edit '$boardPath' (targeted chunk/block replacement) to append your plan/progress under '$scratchpadSection' only. Never overwrite the entire blackboard; do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/.
2. Implementation: Land tracked repository changes, code, and documentation as required by the objective.
3. Verification: Ensure the header (GitHub Issue and Objective) matches this prompt. If mismatched, halt and alert the user.
4. Phase Sign-off: When your implementation work is complete and verified, include 'Sign-off: [x]' on your top scratchpad bullet and mark your row '[x]' in the Agent Roles table to advance to the next phase.
Do not only reply in chat; all dual-session collaboration takes place through $boardPath.
"@
    } else {
@"
MANDATORY ACTION:
1. Target File: '$boardPath' ONLY (do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/).
2. Edit Scope: Use your file editing tool (targeted chunk/block replacement) to update under '$scratchpadSection' only. Never overwrite the entire file.
3. Verification: Ensure the header (GitHub Issue and Objective) matches this prompt. If mismatched, halt and alert the user.
4. Phase Sign-off: When your advisory or review notes are complete, include 'Sign-off: [x]' on your top scratchpad bullet and mark your row '[x]' in the Agent Roles table to signal phase readiness.
Do not only reply in chat; all dual-session collaboration takes place through $boardPath.
"@
    }

    return @"
You are collaborating on $script:ProjectName$issueText.
- Agent: $agentName
- Assigned Role: $normRole
- Project Phase: $phase
- Flow Control: $flow
- Canonical Blackboard: $boardPath

$hardStop
Current Objective:
$objective
$alignBlock
$latestNotes

Role Instructions:
$roleGuidance
$signOffGuidance

$mandatoryBlock
"@
}

function Get-RepromptPromptForAgent {
    param(
        [string]$agentName,
        [string]$role,
        [string]$seatId = "seat1",
        [string]$customDirective = ""
    )
    $normRole = Get-NormalizedRole $role
    $flow = Get-FlowControlString
    $phase = Get-PhaseString
    $hardStop = Get-NonImplementHardStop $normRole
    $signOffGuidance = Get-SignOffGuidance
    $boardPath = $script:BlackboardPath
    $sNameEsc = [regex]::Escape($agentName)
    $scratchpadSection = if ($seatId -eq "seat1" -or $agentName -match 'Cursor|Agent\s*1|AI\s*1') {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### $sNameEsc Scratchpad" -Quiet)) { "### $agentName Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### AI 1 Scratchpad" -Quiet)) { "### AI 1 Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Cursor Scratchpad" -Quiet)) { "### Cursor Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Agent 1 Scratchpad" -Quiet)) { "### Agent 1 Scratchpad" }
        else { "### $agentName Scratchpad" }
    } else {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### $sNameEsc Scratchpad" -Quiet)) { "### $agentName Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### AI 2 Scratchpad" -Quiet)) { "### AI 2 Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Gemini \(Antigravity\) Scratchpad" -Quiet)) { "### Gemini (Antigravity) Scratchpad" }
        elseif ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Agent 2 Scratchpad" -Quiet)) { "### Agent 2 Scratchpad" }
        else { "### $agentName Scratchpad" }
    }

    $mandatoryBlock = if ($normRole -eq "implement") {
@"
MANDATORY ACTION:
1. Blackboard Updates: Edit '$boardPath' (targeted chunk/block replacement) to append progress under '$scratchpadSection' only. Never overwrite the entire blackboard; do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/.
2. Implementation: Continue landing tracked repository changes and documentation for this objective.
3. Verification: Ensure the header matches this turn.
Do not only reply in chat. Do not create AI_COLLAB.md, TASKS.md, or .geminirules.
"@
    } else {
@"
MANDATORY ACTION:
1. Target File: '$boardPath' ONLY (do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/).
2. Edit Scope: Use your file editing tool (targeted chunk/block replacement) to update under '$scratchpadSection' only. Never overwrite the entire file.
3. Verification: Ensure the header matches this turn.
Do not only reply in chat. Do not create AI_COLLAB.md, TASKS.md, or .geminirules.
"@
    }

    $leadDirective = if ($customDirective) {
        $customDirective
    } elseif ($phase -eq "pitch") {
        "Read $boardPath again. Pitch suggestions, improvements, updates, or alternative approaches to the current objective in your scratchpad. Human Lead decides what graduates to discussion."
    } elseif ($normRole -eq "advise" -or $phase -eq "advise" -or $phase -eq "discuss") {
        "Read $boardPath again and respond to the latest notes from the other agent or the Human Lead. End your note with `- **Agreed**: <decision>` sentences, or a single `- **Agree**` if the other agent's scratchpad is already right, so consensus auto-promotes to Alignment."
    } else {
        "Read $boardPath again and respond to the latest notes from the other agent or the Human Lead."
    }
    return @"
$leadDirective
- Agent: $agentName
- Assigned Role: $normRole. Stay in that role.
- Project Phase: $phase
- Flow Control: $flow
- Canonical Blackboard: $boardPath
$hardStop
$signOffGuidance
$mandatoryBlock
"@
}

function Remove-DanglingSeparators {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $lines = @($text -split "`r?`n")
    $end = $lines.Count
    while ($end -gt 0) {
        $trimmed = $lines[$end - 1].Trim()
        if ($trimmed -eq "" -or $trimmed -eq "---") { $end-- } else { break }
    }
    if ($end -le 0) { return "" }
    if ($end -eq 1) { return $lines[0].TrimEnd() }
    return (($lines[0..($end - 1)] -join "`n").TrimEnd())
}

function Join-TextWithSeparator {
    param([string]$existing, [string]$addition)
    if ([string]::IsNullOrWhiteSpace($addition)) { return $existing }
    $add = Remove-DanglingSeparators $addition
    if ([string]::IsNullOrWhiteSpace($add)) { return $existing }
    if ([string]::IsNullOrWhiteSpace($existing)) { return $add }
    $base = Remove-DanglingSeparators $existing
    if ([string]::IsNullOrWhiteSpace($base)) { return $add }
    return ($base + [Environment]::NewLine + "---" + [Environment]::NewLine + $add)
}

function Get-LatestTurnText {
    param([string]$pad)
    if ([string]::IsNullOrWhiteSpace($pad)) { return "" }
    $lines = @($pad -split "`r?`n")
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*[-*]\s+\*\*') { $start = $i; break }
    }
    if ($start -lt 0) { return $pad.Trim() }
    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*[-*]\s+\*\*') { $end = $j; break }
    }
    if ($end -le $start) { return "" }
    return (($lines[$start..($end - 1)] -join "`n").Trim())
}

function Test-LatestTurnSigned {
    param([string]$pad)
    $turn = Get-LatestTurnText $pad
    if ([string]::IsNullOrWhiteSpace($turn)) { return $false }
    return $turn -match '(?i)Sign-?off\s*(?:\*\*)?\s*:\s*\[x\]'
}

function Test-AutoRelaunchReady {
    param(
        [bool]$diskNewer,
        [bool]$formDirty,
        $seenUtc,
        $nowUtc,
        [int]$settleSeconds = 8
    )
    if (-not $diskNewer) { return $false }
    if ($formDirty) { return $false }
    if ($null -eq $seenUtc) { return $false }
    return (($nowUtc - $seenUtc).TotalSeconds -ge $settleSeconds)
}

function Test-UnsignedTestRollback {
    param(
        [string]$phase,
        [bool]$autoStep,
        [string]$flow,
        [bool]$padChanged,
        [string]$pad
    )
    if ($phase -ne "test" -and $phase -ne "closing") { return $false }
    if (-not $autoStep) { return $false }
    if ($flow -match "STOP|PAUSE") { return $false }
    if (-not $padChanged) { return $false }
    if ([string]::IsNullOrWhiteSpace($pad)) { return $false }
    if ($pad -match '(?i)^-\s*\(.*(?:updates?|scratchpad)') { return $false }
    return -not (Test-LatestTurnSigned $pad)
}

function Get-LastMarkdownBody {
    param(
        [string]$raw,
        [string]$headingLineRegex
    )
    if ([string]::IsNullOrEmpty($raw)) { return "" }
    $pattern = '(?ms)^' + $headingLineRegex + '\s*\r?\n(.*?)(?=\r?\n(?:## |### )|\Z)'
    $ms = [regex]::Matches($raw, $pattern)
    if ($ms.Count -eq 0) { return "" }
    return $ms[$ms.Count - 1].Groups[1].Value.Trim()
}

function Get-ScratchpadExcerpt {
    param(
        [string]$body,
        [int]$maxChars = 4000,
        [int]$maxLines = 28,
        [string]$PreferRole = ""
    )
    if ([string]::IsNullOrWhiteSpace($body)) { return "" }
    $trimmed = $body.Trim()

    $rawLines = $trimmed -split "\r?\n"
    $cleanLines = @()
    foreach ($l in $rawLines) {
        if ($l -match '(?i)^\s*[-*]?\s*(?:\*\*)?Sign-?off(?:\*\*)?[:\s]') { continue }
        $cleanLines += $l
    }
    if ($cleanLines.Count -eq 0) { return "" }

    $topLevelIndices = @()
    for ($i = 0; $i -lt $cleanLines.Count; $i++) {
        if ($cleanLines[$i] -match '^[-*]\s+\*\*(?:Role|Phase)\*\*') {
            $topLevelIndices += $i
        }
    }
    if ($topLevelIndices.Count -eq 0) {
        for ($i = 0; $i -lt $cleanLines.Count; $i++) {
            if ($cleanLines[$i] -match '^[-*]\s+\*\*') {
                $topLevelIndices += $i
            }
        }
    }

    $startIdx = 0
    $endExclusive = $cleanLines.Count
    if ($topLevelIndices.Count -gt 0) {
        # Prefer the first `- **Role**: \`current\`` turn (prepend or append). Else first titled, skip IDLE.
        $pick = 0
        $roleKey = ([string]$PreferRole).Trim().ToLowerInvariant()
        if ($roleKey) {
            for ($t = 0; $t -lt $topLevelIndices.Count; $t++) {
                $line = $cleanLines[$topLevelIndices[$t]]
                if ($line -match '(?i)^\s*[-*]\s+\*\*Role\*\*' -and $line.ToLowerInvariant().Contains($roleKey)) {
                    $pick = $t
                    break
                }
            }
        }
        if ($cleanLines[$topLevelIndices[$pick]] -match '(?i)^\s*[-*]\s+\*\*[^*]*IDLE') {
            for ($t = 0; $t -lt $topLevelIndices.Count; $t++) {
                if ($cleanLines[$topLevelIndices[$t]] -notmatch '(?i)^\s*[-*]\s+\*\*[^*]*IDLE') {
                    $pick = $t
                    break
                }
            }
        }
        $startIdx = $topLevelIndices[$pick]
        if ($pick -lt ($topLevelIndices.Count - 1)) {
            $endExclusive = $topLevelIndices[$pick + 1]
        } else {
            $endExclusive = $cleanLines.Count
        }
    }

    $excerptLines = @()
    for ($i = $startIdx; $i -lt $endExclusive; $i++) {
        $excerptLines += $cleanLines[$i]
        if ($excerptLines.Count -ge $maxLines) {
            $excerptLines += "…"
            break
        }
    }

    $excerpt = $excerptLines -join [Environment]::NewLine
    if ($excerpt.Length -gt $maxChars) {
        return $excerpt.Substring(0, $maxChars).TrimEnd() + "…"
    }
    return $excerpt
}

function Set-LastResponseDocument {
    param($rtb, [string]$markdown)
    if (-not $rtb) { return }
    if ([string]::IsNullOrWhiteSpace($markdown)) { $markdown = "(no scratchpad yet)" }
    $doc = Render-MarkdownToFlowDocument -text $markdown -ChatStyle
    $w = $rtb.ActualWidth
    if ($w -gt 48) { $doc.PageWidth = $w - 16 }
    $rtb.Document = $doc
}

function Update-LastResponsePanes {
    param(
        [string]$cursorPad,
        [string]$geminiPad
    )
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $cRole = if ($cbCursorRole.Text) { $cbCursorRole.Text } else { "" }
    $gRole = if ($cbGeminiRole.Text) { $cbGeminiRole.Text } else { "" }
    $cText = if ($cursorPad) { Get-ScratchpadExcerpt $cursorPad -PreferRole $cRole } else { "(no $s1 scratchpad yet)" }
    $gText = if ($geminiPad) { Get-ScratchpadExcerpt $geminiPad -PreferRole $gRole } else { "(no $s2 scratchpad yet)" }
    Set-LastResponseDocument $rtbCursorLast $cText
    Set-LastResponseDocument $rtbGeminiLast $gText
}

function Get-LatestTopLevelBullet {
    param([string]$pad)
    if ([string]::IsNullOrEmpty($pad)) { return "" }
    $lines = @($pad -split "`r?`n")
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[-*]\s+\S') { $start = $i; break }
    }
    if ($start -lt 0) { return "" }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[-*]\s+\S') { $end = $i; break }
    }
    return ($lines[$start..($end - 1)] -join "`n")
}

function Set-ComboToRole {
    param($combo, [string]$role)
    if (-not $combo) { return }
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
        if ([string]$combo.Items[$i].Content -eq $role) {
            if ($combo.SelectedIndex -ne $i) { $combo.SelectedIndex = $i }
            return
        }
    }
}

function Ensure-PitchSeatsAdvise {
    if ((Get-PhaseString) -ne "pitch") { return }
    Set-ComboToRole $cbCursorRole "advise"
    Set-ComboToRole $cbGeminiRole "advise"
}

function Test-LatestBulletSignedOff {
    param([string]$pad)
    $latest = Get-LatestTopLevelBullet $pad
    if ([string]::IsNullOrEmpty($latest)) { return $false }
    return [regex]::IsMatch($latest, '(?im)sign-?off(?:\*\*)?\s*:\s*\[x\]')
}

function Sync-SignoffCheckboxes {
    param([string]$raw)
    if ([string]::IsNullOrEmpty($raw)) { return }
    
    Read-SignoffBaseline
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $s1Esc = [regex]::Escape($s1)
    $s2Esc = [regex]::Escape($s2)

    # 2. Seat 1: a new latest Sign-off: [x] checks the box. The note from the last advance does not.
    $cWho = $s1Esc + '|Cursor|Agent\s*1'
    $cCleared = $raw -match ('(?m)\|\s*\*\*(?:' + $cWho + ')\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[\s\]')
    $cTable = ($raw -match ('(?m)\|\s*\*\*(?:' + $cWho + ')\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[x\]'))
    $cPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1)(?:\s+Scratchpad)?"
    $cPadSign = Test-LatestBulletSignedOff $cPad
    $cPadNorm = if ($cPad) { ($cPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
    $cHasBaseline = $null -ne $script:CursorPadAtPhaseChange
    $cPadIsNew = $cHasBaseline -and ($cPadNorm -ne $script:CursorPadAtPhaseChange)
    $cFreshSignoff = $cPadSign -and ($cPadIsNew -or ((-not $cHasBaseline) -and $cCleared))
    if ($cFreshSignoff) {
        $chkSignCursor.IsChecked = $true
        $script:NewSignoffDuringLoad = $true
    } elseif ($cCleared) {
        $chkSignCursor.IsChecked = $false
    } elseif ($cTable) {
        $chkSignCursor.IsChecked = $true
    }
    
    # 1. Human (Lead): role table is the saved box
    if ($raw -match '(?m)\|\s*\*\*([^*]+)\*\*\s*\|\s*`lead`\s*\|\s*Active\s*\|\s*\[\s\]') {
        $chkSignHuman.IsChecked = $false
    } elseif ($raw -match '(?m)\|\s*\*\*([^*]+)\*\*\s*\|\s*`lead`\s*\|\s*Active\s*\|\s*\[x\]') {
        $chkSignHuman.IsChecked = $true
    }

    # 3. Seat 2: a new latest Sign-off: [x] checks the box. The note from the last advance does not.
    $gWho = $s2Esc + '|Gemini(?:\s+\(Antigravity\))?|Agent\s*2'
    $gCleared = $raw -match ('(?m)\|\s*\*\*(?:' + $gWho + ')\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[\s\]')
    $gTable = ($raw -match ('(?m)\|\s*\*\*(?:' + $gWho + ')\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[x\]'))
    $gPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?"
    $gPadSign = Test-LatestBulletSignedOff $gPad
    $gPadNorm = if ($gPad) { ($gPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
    $gHasBaseline = $null -ne $script:GeminiPadAtPhaseChange
    $gPadIsNew = $gHasBaseline -and ($gPadNorm -ne $script:GeminiPadAtPhaseChange)
    $gFreshSignoff = $gPadSign -and ($gPadIsNew -or ((-not $gHasBaseline) -and $gCleared))
    if ($gFreshSignoff) {
        $chkSignGemini.IsChecked = $true
        $script:NewSignoffDuringLoad = $true
    } elseif ($gCleared) {
        $chkSignGemini.IsChecked = $false
    } elseif ($gTable) {
        $chkSignGemini.IsChecked = $true
    }
}

function Save-BlackboardContent {
    param([string]$customPath = $script:BlackboardPath, [switch]$clearScratchpads)
    
    Update-UiActiveTurn -keepOverride
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $s1Esc = [regex]::Escape($s1)
    $s2Esc = [regex]::Escape($s2)

    $flow = Get-FlowControlString
    $phase = Get-PhaseString
    $cursorRole = if ($cbCursorRole.Text) { $cbCursorRole.Text } else { "idle" }
    $geminiRole = if ($cbGeminiRole.Text) { $cbGeminiRole.Text } else { "idle" }
    $issue = $txtIssueNum.Text.Trim()
    $issueRef = if ($issue) { "#$issue" } else { "none" }
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    
    $humanNotes = if ($txtHumanNotes.Text.Trim()) { $txtHumanNotes.Text } else { "- Active steering notes." }
    $humanLabel = "**Human (Lead)**"
    $agent1Label = "**$s1**"
    $agent2Label = "**$s2**"
    $humanHeader = "### Human (Lead)"
    $agent1Header = "### $s1 Scratchpad"
    $agent2Header = "### $s2 Scratchpad"
    $cursorScratchpad = "- ($s1 updates here)"
    $geminiScratchpad = "- ($s2 updates here)"
    if (Test-Path $script:BlackboardPath) {
        try {
            $existing = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            if ($existing -match '(?m)\|\s*\*\*([^*]+?\s+\(Lead\))\*\*\s*\|\s*`lead`') {
                $humanLabel = "**$($matches[1])**"
            }
            if ($existing -match '(?m)^(?:###|##)\s+([^\r\n]+?\s+\(Lead\))') {
                $humanHeader = "### $($matches[1])"
            }

            if (-not $clearScratchpads) {
                # Preserve and migrate Seat 1 scratchpad notes under new client heading
                $cPad = Get-LastMarkdownBody $existing "(?:###|##)\s+$s1Esc(?:\s+Scratchpad)?"
                if (-not $cPad) { $cPad = Get-LastMarkdownBody $existing "(?:###|##)\s+Cursor(?:\s+Scratchpad)?" }
                if (-not $cPad) { $cPad = Get-LastMarkdownBody $existing "(?:###|##)\s+Agent\s*1(?:\s+Scratchpad)?" }
                if (-not $cPad) { $cPad = Get-LastMarkdownBody $existing "(?:###|##)\s+(?:Windsurf|VS\s*Code|Terminal)(?:\s+Scratchpad)?" }

                # Preserve and migrate Seat 2 scratchpad notes under new client heading
                $gPad = Get-LastMarkdownBody $existing "(?:###|##)\s+$s2Esc(?:\s+Scratchpad)?"
                if (-not $gPad) { $gPad = Get-LastMarkdownBody $existing "(?:###|##)\s+Gemini(?:\s+\(Antigravity\))?(?:\s+Scratchpad)?" }
                if (-not $gPad) { $gPad = Get-LastMarkdownBody $existing "(?:###|##)\s+Antigravity(?:\s+Scratchpad)?" }
                if (-not $gPad) { $gPad = Get-LastMarkdownBody $existing "(?:###|##)\s+Agent\s*2(?:\s+Scratchpad)?" }

                if ($cPad) { 
                    $cursorScratchpad = $cPad
                }
                if ($gPad) { 
                    $geminiScratchpad = $gPad
                }
            }
        } catch {}
    }

    $signHuman = if ($chkSignHuman.IsChecked) { "[x]" } else { "[ ]" }
    $signCursor = if ($chkSignCursor.IsChecked) { "[x]" } else { "[ ]" }
    $signGemini = if ($chkSignGemini.IsChecked) { "[x]" } else { "[ ]" }

    $q = [char]96
    $lines = @(
        "# Dual-Session Agent Blackboard",
        "",
        ("> **Flow Control**: " + $q + $flow + $q),
        ("> **Project Phase**: " + $q + $phase + $q),
        ("> **Active Turn**: " + $txtActiveTurn.Text),
        ("> **GitHub Issue**: " + $issueRef),
        ("> **Last Updated**: " + $timestamp),
        "",
        "---",
        "",
        "## Agent Roles & Safety",
        "",
        "| Participant | Active Role | Status | Sign-off (Complete) |",
        "|-------------|-------------|--------|---------------------|",
        ("| " + $humanLabel + " | " + $q + "lead" + $q + " | Active | " + $signHuman + " |"),
        ("| " + $agent1Label + " | " + $q + $cursorRole + $q + " | Active | " + $signCursor + " |"),
        ("| " + $agent2Label + " | " + $q + $geminiRole + $q + " | Active | " + $signGemini + " |"),
        "",
        "> [!NOTE]",
        ("> **Safety Guard**: Only ONE agent may hold the " + $q + "implement" + $q + " role at any time. When one implements, the other must be " + $q + "review" + $q + ", " + $q + "advise" + $q + ", or " + $q + "idle" + $q + "."),
        "",
        "---",
        "",
        "## Current Objective & Prompt",
        "",
        (Remove-DanglingSeparators $txtPrompt.Text),
        "",
        "---",
        "",
        "## Alignment & Agreed Decisions",
        "",
        (Remove-DanglingSeparators $txtAlignment.Text),
        "",
        "---",
        "",
        "## Working Notes & Scratchpads",
        "",
        $humanHeader,
        $humanNotes,
        "",
        $agent1Header,
        $cursorScratchpad,
        "",
        $agent2Header,
        $geminiScratchpad
    )
    
    $content = $lines -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($customPath, $content, [System.Text.Encoding]::UTF8)
    $script:FormDirty = $false
    $script:LastReadBlackboardText = $content
    $txtLastSaved.Text = "Last write: " + (Get-Date -Format "HH:mm:ss")
    $txtStatus.Text = "Saved blackboard to: " + $customPath
    Update-BlackboardViewer
}

function Auto-ArchiveSnapshot {
    param([string]$customLabel)
    if (Test-Path $script:BlackboardPath) {
        $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $suffix = ""
        if ($customLabel) {
            $safe = ($customLabel.Trim() -replace '[^a-zA-Z0-9_-]', '')
            if ($safe) { $suffix = "-" + $safe }
        } else {
            try {
                $name = [Microsoft.VisualBasic.Interaction]::InputBox("Enter custom label for history snapshot (optional):", "Archive Snapshot", "")
                if ($name -and $name.Trim()) {
                    $safe = ($name.Trim() -replace '[^a-zA-Z0-9_-]', '')
                    if ($safe) { $suffix = "-" + $safe }
                }
            } catch {}
        }
        $archiveFile = Join-Path $script:HistoryDir ("blackboard-" + $ts + $suffix + ".md")
        Copy-Item -Path $script:BlackboardPath -Destination $archiveFile -Force
        $txtStatus.Text = "Archived snapshot: " + (Split-Path $archiveFile -Leaf)
        return $archiveFile
    }
}

function Safe-SetClipboard([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($text)
    } catch {
        try {
            [System.Windows.Clipboard]::SetText($text)
        } catch {}
    }
}

function Safe-SendKeys([string]$keys) {
    try {
        [System.Windows.Forms.SendKeys]::SendWait($keys)
    } catch {}
}

function Send-AgentChatPaste {
    param(
        [string]$clientName,
        [bool]$newChat = $false
    )
    
    $procName = ""
    if ($script:ClientConfig -and $script:ClientConfig.profiles) {
        $profiles = $script:ClientConfig.profiles
        if ($profiles.PSObject.Properties[$clientName]) {
            $procName = $profiles.$clientName.process
        }
    }
    if ([string]::IsNullOrWhiteSpace($procName)) {
        if ($clientName -eq "Cursor") { $procName = "Cursor" }
        elseif ($clientName -eq "Antigravity") { $procName = "Antigravity" }
        elseif ($clientName -eq "Windsurf") { $procName = "Windsurf" }
        elseif ($clientName -eq "VS Code") { $procName = "Code" }
        elseif ($clientName -eq "Terminal") { $procName = "WindowsTerminal" }
        elseif ($clientName -eq "Codex" -or $clientName -eq "ChatGPT") { $procName = "ChatGPT" }
    }
    
    if ([string]::IsNullOrWhiteSpace($procName)) {
        return $false
    }
    
    if (-not [WinHelper]::FocusProcess($procName)) {
        return $false
    }
    
    Start-Sleep -Milliseconds 250
    
    switch ($clientName) {
        "Cursor" {
            Safe-SendKeys "{ESC}"
            Start-Sleep -Milliseconds 80
            if ($newChat) {
                Safe-SendKeys "^+p"
                Start-Sleep -Milliseconds 400
                Safe-SendKeys "Chat: New Chat"
                Start-Sleep -Milliseconds 220
                Safe-SendKeys "{ENTER}"
                Start-Sleep -Milliseconds 500
                Safe-SendKeys "{ESC}"
                Start-Sleep -Milliseconds 120
            }
            Safe-SendKeys "^l"
            Start-Sleep -Milliseconds 350
            Safe-SendKeys "^a"
            Start-Sleep -Milliseconds 80
            Safe-SendKeys "^v{ENTER}"
            return $true
        }
        "Antigravity" {
            Safe-SendKeys "^+i"
            if ($newChat) {
                Start-Sleep -Milliseconds 400
                Safe-SendKeys "^+l"
                Start-Sleep -Milliseconds 700
            } else {
                Start-Sleep -Milliseconds 200
            }
            Safe-SendKeys "^v{ENTER}"
            return $true
        }
        "Windsurf" {
            # Keystroke automation unverified on this PC: window focused above, but blind keystrokes skipped for safety.
            # Return $false to prompt manual clipboard paste.
            return $false
        }
        "VS Code" {
            # Keystroke automation unverified on this PC: window focused above, but blind keystrokes skipped for safety.
            # Return $false to prompt manual clipboard paste.
            return $false
        }
        "Terminal" {
            # Terminal / Shell: Blind keystroke injection forbidden for command safety.
            # Return $false to prompt manual clipboard paste.
            return $false
        }
        "Codex" {
            # Electron window: the composer is not in the UI Automation tree.
            # Click the lower-center input, then paste. The Codex process has no window; the app process is ChatGPT.
            if ($newChat) {
                # No Codex-specific new-chat action is verified for the desktop app.
                # Keep the prompt copied and avoid sending it into an unverified conversation.
                return $false
            }
            if (-not [WinHelper]::ClickLowerComposer([WinHelper]::LastHwnd, 110, 50)) {
                return $false
            }
            Start-Sleep -Milliseconds 200
            Safe-SendKeys "^v"
            Start-Sleep -Milliseconds 150
            Safe-SendKeys "{ENTER}"
            return $true
        }
        default {
            return $false
        }
    }
}

function Send-CursorChatPaste {
    param([bool]$newChat = $false)
    $s1 = Get-Seat1Client
    return Send-AgentChatPaste -clientName $s1 -newChat $newChat
}

function Send-GeminiChatPaste {
    param([bool]$newChat = $false)
    $s2 = Get-Seat2Client
    return Send-AgentChatPaste -clientName $s2 -newChat $newChat
}

function Complete-KickoffNewChatOneShot {
    param([bool]$didNew)
    if (-not $didNew) { return }
    if ($chkNewChatKickoff -and $chkNewChatKickoff.IsChecked) {
        $chkNewChatKickoff.IsChecked = $false
    }
}

function Clear-FormInMemory {
    $txtPrompt.Text = ""
    $txtAlignment.Text = ""
    $txtHumanNotes.Text = "- Active steering notes."
    $cbCursorRole.SelectedIndex = 5
    $cbGeminiRole.SelectedIndex = 5
    Set-Phase "pitch"
    $chkSignHuman.IsChecked = $false
    $chkSignCursor.IsChecked = $false
    $chkSignGemini.IsChecked = $false
    $txtActiveTurn.Text = "Human (Lead)"
    $txtIssueNum.Text = ""
    $txtIssueTitle.Text = ""
    if ($chkNewChatKickoff) { $chkNewChatKickoff.IsChecked = $false }
    $script:FormDirty = $true
    Check-Safety
}

$btnApply.add_Click({
    Save-BlackboardContent
    $txtStatus.Text = "Blackboard applied successfully."
})

$btnCloseProject.add_Click({
    $signHuman = $chkSignHuman.IsChecked
    $signCursor = $chkSignCursor.IsChecked
    $signGemini = $chkSignGemini.IsChecked
    $allSigned = ($signHuman -and $signCursor -and $signGemini)
    $phaseNow = Get-PhaseString
    if ($phaseNow -ne "test" -and $phaseNow -ne "closing" -and $phaseNow -ne "closed") {
        $testWarn = [System.Windows.MessageBox]::Show(
            "Project phase is '$phaseNow' (not test). For programs/scripts, sign-off should follow the test phase.`n`nClose anyway?",
            "Testing phase not reached",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($testWarn -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
    }
    
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $confirmMsg = if ($allSigned) {
        "All participants (Human, $s1, $s2) have signed off.`n`nClose this project, archive session history, and reset board to idle?"
    } else {
        "Not all sign-offs are complete.`n`nAre you sure you want to close and archive this project anyway?"
    }
    
    $result = [System.Windows.MessageBox]::Show($confirmMsg, "Close Project", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    Invoke-CloseProjectGitShip -allSigned ([bool]$allSigned)

    $num = $txtIssueNum.Text.Trim()
    if ($num -and $num -ne "none") {
        $closeIssuePrompt = [System.Windows.MessageBox]::Show("Linked GitHub Issue #$num detected.`n`nClose Issue #$num on GitHub via gh CLI?", "Close GitHub Issue #$num", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($closeIssuePrompt -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                $txtStatus.Text = "Closing issue #$num via gh CLI..."
                $targetRepo = Get-TargetGitHubRepo
                $closeArgs = @("issue", "close", $num, "--comment", "Completed with sign-offs from Human, $s1, and $s2.")
                if ($targetRepo) { $closeArgs += @("--repo", $targetRepo) }
                & gh @closeArgs
                $txtStatus.Text = "Closed GitHub Issue #$num."
            } catch {
                $txtStatus.Text = "Warning: Failed to close issue #$num via gh: $_"
            }
        }
    }
    
    # Derive slug for archive
    $slug = "closed"
    if ($num -and $num -ne "none") {
        $slug += "-issue$num"
    } else {
        $firstLine = ($txtPrompt.Text -split "\r?\n")[0].Trim()
        if ($firstLine) {
            $short = ($firstLine -replace '[^a-zA-Z0-9]', '-').Trim('-')
            if ($short.Length -gt 25) { $short = $short.Substring(0, 25).Trim('-') }
            if ($short) { $slug += "-$short" }
        }
    }
    
    Auto-ArchiveSnapshot -customLabel $slug
    Clear-FormInMemory
    if ($chkNewChatKickoff) { $chkNewChatKickoff.IsChecked = $true }
    Set-Phase "closed"
    $rbGo.IsChecked = $true
    Save-BlackboardContent -clearScratchpads
    $txtStatus.Text = "Project closed & archived to .ai/history. Board reset to idle. New Chat armed for next project."
})

$btnReset.add_Click({
    Auto-ArchiveSnapshot
    Clear-FormInMemory
    $rbGo.IsChecked = $true
    Save-BlackboardContent -clearScratchpads
    $txtStatus.Text = "Reset blackboard (Archived previous state to .ai/history)."
})

# Workflow Preset Handler
function Apply-SelectedWorkflowPreset {
    $script:SuppressPresetSync = $true
    try {
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $item = $cbPresets.SelectedItem
        $preset = if ($item -and $item.Tag) { [string]$item.Tag } elseif ($item) { [string]$item.Content } else { "Discuss" }

        switch -Regex ($preset) {
            "Pitch" {
                $cbCursorRole.SelectedIndex = 2 # advise
                $cbGeminiRole.SelectedIndex = 2 # advise
                Set-Phase "pitch"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Pitch Mode ($s1 advise + $s2 advise, phase pitch)"
            }
            "Discuss" {
                $cbCursorRole.SelectedIndex = 2 # advise
                $cbGeminiRole.SelectedIndex = 2 # advise
                Set-Phase "discuss"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Discussion Mode ($s1 advise + $s2 advise, phase discuss)"
            }
            "Plan" {
                $cbCursorRole.SelectedIndex = 4 # plan
                $cbGeminiRole.SelectedIndex = 5 # idle
                Set-Phase "plan"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Planning Mode ($s1 plan + $s2 idle, phase plan)"
            }
            "Implement" {
                $cbCursorRole.SelectedIndex = 1 # review
                $cbGeminiRole.SelectedIndex = 1 # implement
                Set-Phase "implement"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Implementation Mode ($s2 implement + $s1 review, phase implement)"
            }
            "Review" {
                $cbCursorRole.SelectedIndex = 1 # review
                $cbGeminiRole.SelectedIndex = 0 # review
                Set-Phase "review"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Review Mode ($s1 review + $s2 review, phase review)"
                Show-ReviewDiffViewer
            }
            "Test" {
                $cbCursorRole.SelectedIndex = 1 # review
                $cbGeminiRole.SelectedIndex = 0 # review
                Set-Phase "test"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Test Mode ($s1 review + $s2 review, phase test)"
            }
            "Inventory" {
                $cbCursorRole.SelectedIndex = 3 # inventory
                $cbGeminiRole.SelectedIndex = 3 # inventory
                Set-Phase "review"
                $script:FormDirty = $true
                $txtStatus.Text = "Preset applied: Inventory Mode ($s1 inventory + $s2 inventory)"
            }
        }
        Check-Safety
        Update-UiActiveTurn -keepOverride
    } finally {
        $script:SuppressPresetSync = $false
    }
}

if ($cbPresets) {
    $cbPresets.add_SelectionChanged({
        if (-not $script:SuppressPresetSync) {
            Apply-SelectedWorkflowPreset
        }
    })
}

if ($btnApplyPreset) {
    $btnApplyPreset.add_Click({ Apply-SelectedWorkflowPreset })
}

# Kickoff Prompt Target & Button Handlers
function Invoke-CopyKickoffPrompt {
    try {
        Save-BlackboardContent
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $target = if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) {
            $item = $cbKickoffTarget.SelectedItem
            if ($item.Tag) { [string]$item.Tag } else { [string]$item.Content }
        } else { "Both" }

        switch -Regex ($target) {
            "Seat1" {
                $kPrompt = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                Safe-SetClipboard $kPrompt
                $txtStatus.Text = "📋 Copied $s1 Kickoff Prompt (" + $cbCursorRole.Text + ") to clipboard."
            }
            "Seat2" {
                $kPrompt = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                Safe-SetClipboard $kPrompt
                $txtStatus.Text = "📋 Copied $s2 Kickoff Prompt (" + $cbGeminiRole.Text + ") to clipboard."
            }
            default {
                $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                $combined = "=== [$($s1.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent1 + [Environment]::NewLine + [Environment]::NewLine + "=== [$($s2.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent2
                Safe-SetClipboard $combined
                $txtStatus.Text = "📋 Copied combined Kickoff prompts for both $s1 and $s2 to clipboard."
            }
        }
    } catch { $txtStatus.Text = "Error copying kickoff prompt: $_" }
}

function Invoke-SendKickoffPrompt {
    try {
        Save-BlackboardContent
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $doNew = [bool]($chkNewChatKickoff -and $chkNewChatKickoff.IsChecked)
        $target = if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) {
            $item = $cbKickoffTarget.SelectedItem
            if ($item.Tag) { [string]$item.Tag } else { [string]$item.Content }
        } else { "Both" }

        if ($chkDryRunKickoff -and $chkDryRunKickoff.IsChecked) {
            $newNote = if ($doNew) { "New Chat armed" } else { "New Chat off" }
            $txtStatus.Text = "Dry run: target $target ($s1 / $s2), $newNote. No prompt copied or sent."
            return
        }

        switch -Regex ($target) {
            "Seat1" {
                $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                Safe-SetClipboard $pAgent1
                if (Send-AgentChatPaste -clientName $s1 -newChat $doNew) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                    $chatNote = if ($doNew) { " (New Chat, then off)" } else { "" }
                    $txtStatus.Text = if ($doNew -and $s1 -eq "Codex") { "🚀 Opened a new Codex chat with the kickoff prompt ready to send." } else { "🚀 Sent $s1 Kickoff Prompt to active IDE window$chatNote." }
                } else {
                    $txtStatus.Text = if ($doNew -and $s1 -eq "Codex") { "⚠️ Codex New Chat could not be opened or confirmed automatically. Kickoff is copied; open a new Codex chat, verify it, then paste and submit. New Chat remains armed." } elseif ($doNew) { "⚠️ No new $s1 chat was confirmed; kickoff was not sent and New Chat remains armed." } else { "📋 Copied $s1 Kickoff to clipboard (IDE window not found). Focus $s1 and paste." }
                }
            }
            "Seat2" {
                $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                Safe-SetClipboard $pAgent2
                if (Send-AgentChatPaste -clientName $s2 -newChat $doNew) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                    $chatNote = if ($doNew) { " (New Chat, then off)" } else { "" }
                    $txtStatus.Text = if ($doNew -and $s2 -eq "Codex") { "🚀 Opened a new Codex chat with the kickoff prompt ready to send." } else { "🚀 Sent $s2 Kickoff Prompt to active IDE window$chatNote." }
                } else {
                    $txtStatus.Text = if ($doNew -and $s2 -eq "Codex") { "⚠️ Codex New Chat could not be opened or confirmed automatically. Kickoff is copied; open a new Codex chat, verify it, then paste and submit. New Chat remains armed." } elseif ($doNew) { "⚠️ No new $s2 chat was confirmed; kickoff was not sent and New Chat remains armed." } else { "📋 Copied $s2 Kickoff to clipboard (IDE window not found). Focus $s2 and paste." }
                }
            }
            default {
                $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"

                if ($doNew -and ($s1 -eq "Codex" -or $s2 -eq "Codex")) {
                    $txtStatus.Text = "⚠️ Select a single Codex seat for New Chat; both prompts were copied and no chat was changed."
                    Safe-SetClipboard ("=== [$($s1.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent1 + [Environment]::NewLine + [Environment]::NewLine + "=== [$($s2.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent2)
                    return
                }

                # 1. Focus & Send Seat 1
                Safe-SetClipboard $pAgent1
                $cFocused = Send-AgentChatPaste -clientName $s1 -newChat $doNew
                Start-Sleep -Milliseconds 600

                # 2. Focus & Send Seat 2
                Safe-SetClipboard $pAgent2
                $gFocused = Send-AgentChatPaste -clientName $s2 -newChat $doNew

                if ($cFocused -or $gFocused) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                }
                if ($cFocused -and $gFocused) {
                    $chatNote = if ($doNew) { " (New Chat one-shot, now off)" } else { "" }
                    $txtStatus.Text = "🚀 Successfully kicked off both $s1 and $s2!$chatNote"
                } elseif ($cFocused) {
                    $txtStatus.Text = "🚀 Kicked off $s1. ($s2 window not found - focus $s2 to paste prompt)."
                } elseif ($gFocused) {
                    Safe-SetClipboard $pAgent1
                    $txtStatus.Text = "🚀 Kicked off $s2. $s1 prompt copied to clipboard. Focus $s1 to paste."
                } else {
                    Safe-SetClipboard ("=== [$($s1.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent1 + [Environment]::NewLine + [Environment]::NewLine + "=== [$($s2.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent2)
                    $txtStatus.Text = if ($doNew) { "⚠️ No new chat was confirmed; prompts were copied and New Chat remains armed." } else { "📋 Copied both kickoff prompts to clipboard (focus IDEs to paste)." }
                }
            }
        }
    } catch { $txtStatus.Text = "Error during kickoff: $_" }
}

if ($btnCopyKickoffPrompt) { $btnCopyKickoffPrompt.add_Click({ Invoke-CopyKickoffPrompt }) }
if ($btnSendKickoffPrompt) { $btnSendKickoffPrompt.add_Click({ Invoke-SendKickoffPrompt }) }
if ($cbKickoffTarget) { $cbKickoffTarget.add_SelectionChanged({ Update-KickoffButtonTooltips }) }

$btnOpenHistory.add_Click({
    try {
        Start-Process -FilePath "explorer.exe" -ArgumentList $script:HistoryDir
    } catch {}
})

$btnFetchIssue.add_Click({
    $num = $txtIssueNum.Text.Trim()
    if ($num) {
        $txtStatus.Text = "Fetching issue #" + $num + " via gh CLI..."
        try {
            $targetRepo = Get-TargetGitHubRepo
            $ghArgs = @("issue", "view", $num, "--json", "title,state,labels")
            if ($targetRepo) { $ghArgs += @("--repo", $targetRepo) }
            $json = & gh @ghArgs 2>$null | ConvertFrom-Json
            if ($json) {
                $labels = ($json.labels | ForEach-Object { $_.name }) -join ", "
                $txtIssueTitle.Text = $json.title + " [" + $json.state + "] (" + $labels + ")"
                $txtStatus.Text = "Fetched issue #" + $num + ": " + $json.title
            } else {
                $txtIssueTitle.Text = "Issue #" + $num + " not found"
            }
        } catch {
            $txtIssueTitle.Text = "gh CLI lookup failed"
        }
    }
})

$btnNewIssue.add_Click({
    try {
        $title = [Microsoft.VisualBasic.Interaction]::InputBox("Enter GitHub Issue Title:", "Create Issue", "[agent] ")
        if ($title) {
            $body = $txtPrompt.Text
            try {
                $targetRepo = Get-TargetGitHubRepo
                $ghArgs = @("issue", "create", "--title", $title, "--body", $body, "--label", "agent-owned")
                if ($targetRepo) { $ghArgs += @("--repo", $targetRepo) }
                $createdUrl = & gh @ghArgs
                if ($createdUrl) {
                    $issueNo = ($createdUrl -split "/")[-1]
                    $txtIssueNum.Text = $issueNo
                    $txtIssueTitle.Text = "$title [OPEN]"
                    $txtStatus.Text = "Created issue #" + $issueNo + ": " + $createdUrl
                    Save-BlackboardContent
                }
            } catch {
                [System.Windows.MessageBox]::Show("Failed to create issue via gh CLI: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    } catch {}
})

function Trigger-AgentReprompt {
    param([string]$target)

    try {
        Save-BlackboardContent
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $pAgent1 = Get-RepromptPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
        $pAgent2 = Get-RepromptPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
        $cFocused = $false
        $gFocused = $false

        if ($target -eq "Seat1" -or $target -eq "Cursor" -or $target -eq "Both") {
            Safe-SetClipboard $pAgent1
            if (Send-AgentChatPaste -clientName $s1 -newChat $false) {
                $cFocused = $true
            }
        }
        if ($target -eq "Both") {
            Start-Sleep -Milliseconds 600
        }
        if ($target -eq "Seat2" -or $target -eq "Gemini" -or $target -eq "Both") {
            Safe-SetClipboard $pAgent2
            if (Send-AgentChatPaste -clientName $s2 -newChat $false) {
                $gFocused = $true
            }
        }

        if ($cFocused -and $gFocused) {
            $txtStatus.Text = "⚡ Re-prompted $s1 & $s2 (role-aware)."
        } elseif ($target -eq "Both" -and $cFocused) {
            Safe-SetClipboard $pAgent2
            $txtStatus.Text = "⚡ Re-prompted $s1. $s2 prompt copied ($s2 not found)."
        } elseif ($target -eq "Both" -and $gFocused) {
            Safe-SetClipboard $pAgent1
            $txtStatus.Text = "⚡ Re-prompted $s2. $s1 prompt copied ($s1 not found)."
        } elseif ($cFocused -or $gFocused) {
            $who = if ($cFocused) { $s1 } else { $s2 }
            $txtStatus.Text = "⚡ Re-prompted $who (role-aware)."
        } else {
            if ($target -eq "Seat1" -or $target -eq "Cursor") { Safe-SetClipboard $pAgent1 }
            elseif ($target -eq "Seat2" -or $target -eq "Gemini") { Safe-SetClipboard $pAgent2 }
            else {
                Safe-SetClipboard ("=== [$($s1.ToUpper())] ===" + [Environment]::NewLine + $pAgent1 + [Environment]::NewLine + [Environment]::NewLine + "=== [$($s2.ToUpper())] ===" + [Environment]::NewLine + $pAgent2)
            }
            $txtStatus.Text = "⚡ Copied role-aware re-prompt to clipboard (no IDE focused)."
        }
    } catch { $txtStatus.Text = "Error during re-prompt: $_" }
}

function Trigger-CompareNotesReprompt {
    try {
        Save-BlackboardContent
        Show-CompareTurnsViewer
        $s1 = Get-Seat1Client
        $s2 = Get-Seat2Client
        $compareDirective = "Read $script:BlackboardPath again. Compare notes with the other agent's scratchpad: identify agreements, highlight key differences, and synthesize recommendations without replacing the Objective or Alignment. End your note with `- **Agreed**: <decision>` sentences, or a single `- **Agree**` if the other note is already right."
        $pAgent1 = Get-RepromptPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1" -customDirective $compareDirective
        $pAgent2 = Get-RepromptPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2" -customDirective $compareDirective

        Safe-SetClipboard $pAgent1
        $cFocused = Send-AgentChatPaste -clientName $s1 -newChat $false
        Start-Sleep -Milliseconds 600

        Safe-SetClipboard $pAgent2
        $gFocused = Send-AgentChatPaste -clientName $s2 -newChat $false

        if ($cFocused -and $gFocused) {
            $txtStatus.Text = "⚖️ Compare Notes prompt dispatched to $s1 & $s2."
        } elseif ($cFocused) {
            Safe-SetClipboard $pAgent2
            $txtStatus.Text = "⚖️ Compare Notes sent to $s1. $s2 prompt copied ($s2 window not found)."
        } elseif ($gFocused) {
            Safe-SetClipboard $pAgent1
            $txtStatus.Text = "⚖️ Compare Notes sent to $s2. $s1 prompt copied ($s1 window not found)."
        } else {
            Safe-SetClipboard ("=== [$($s1.ToUpper()) COMPARE NOTES] ===" + [Environment]::NewLine + $pAgent1 + [Environment]::NewLine + [Environment]::NewLine + "=== [$($s2.ToUpper()) COMPARE NOTES] ===" + [Environment]::NewLine + $pAgent2)
            $txtStatus.Text = "⚖️ Copied Compare Notes prompts to clipboard (no IDE window focused)."
        }
    } catch { $txtStatus.Text = "Error dispatching Compare Notes: $_" }
}

$btnRepromptCursor.add_Click({ Trigger-AgentReprompt -target "Cursor" })
$btnRepromptGemini.add_Click({ Trigger-AgentReprompt -target "Gemini" })
$btnRepromptBoth.add_Click({ Trigger-AgentReprompt -target "Both" })
if ($btnCompareNotes) {
    $btnCompareNotes.add_Click({ Trigger-CompareNotesReprompt })
}

function Invoke-ControllerRelaunch {
    param([switch]$force)
    if (-not $force -and $script:FormDirty) {
        $res = [System.Windows.MessageBox]::Show("You have unsaved changes in the Blackboard UI.`n`nDo you want to save before relaunching?`n`nYes = Save & Relaunch`nNo = Discard & Relaunch`nCancel = Stay here", "Unsaved Changes", [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
        if ($res -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        if ($res -eq [System.Windows.MessageBoxResult]::Yes) { Save-BlackboardContent }
    }
    
    $targetScript = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot "blackboard-ui.ps1" }
    $psExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
    $txtStatus.Text = "Relaunching controller..."
    Start-Process $psExe -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$targetScript`"" -WorkingDirectory $script:RepoRoot
    Start-Sleep -Milliseconds 250
    $window.Close()
}

function Invoke-ControllerUpdate {
    if ($script:FormDirty) {
        $res = [System.Windows.MessageBox]::Show("You have unsaved changes in the Blackboard UI.`n`nDo you want to save before checking for updates?`n`nYes = Save & Check`nNo = Discard & Check`nCancel = Abort", "Unsaved Changes", [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
        if ($res -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        if ($res -eq [System.Windows.MessageBoxResult]::Yes) { Save-BlackboardContent }
    }

    $txtStatus.Text = "Checking online GitHub (origin/main) for controller updates..."
    try {
        git -C $script:RepoRoot fetch origin main --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            $txtStatus.Text = "Could not reach online GitHub (fetch failed / offline)."
            [System.Windows.MessageBox]::Show("Could not reach online GitHub (origin/main). Please check your network connection.", "Update Check Failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        
        $localDirty = git -C $script:RepoRoot status --porcelain scripts/blackboard-ui.ps1 2>$null
        if ($localDirty) {
            $dirtyWarn = [System.Windows.MessageBox]::Show("Warning: You have uncommitted local modifications in 'scripts/blackboard-ui.ps1'.`n`nRunning git pull may overwrite or conflict with your local edits.`n`nProceed with git pull anyway?", "Uncommitted Script Changes", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($dirtyWarn -ne [System.Windows.MessageBoxResult]::Yes) {
                $txtStatus.Text = "Update aborted: local modifications detected in scripts/blackboard-ui.ps1."
                return
            }
        }

        # Check if upstream commits exist behind current HEAD for controller
        $behindCount = 0
        $behindStr = git -C $script:RepoRoot rev-list --count 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
        if ($LASTEXITCODE -eq 0 -and $behindStr) {
            $behindCount = [int]$behindStr
        }

        # Check if scripts/blackboard-ui.ps1 has diff against upstream
        $diffOut = git -C $script:RepoRoot diff --stat 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null

        if ($behindCount -eq 0 -or -not $diffOut) {
            $txtStatus.Text = "Controller is up-to-date with online GitHub ($script:AppVersion)."
            $btnUpdateController.Content = "🔄 Update App"
            $btnUpdateController.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#313244")
            $btnUpdateController.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA")
            $btnUpdateController.FontWeight = [System.Windows.FontWeights]::SemiBold
            [System.Windows.MessageBox]::Show("Blackboard Controller is already up-to-date with online GitHub ($script:AppVersion).", "Controller Up-To-Date", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }

        $confirm = [System.Windows.MessageBox]::Show("A newer version of the Blackboard Controller is available on online GitHub ($behindCount commit(s) ahead)!`n`nPull the latest changes and relaunch now?", "Update Available", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $txtStatus.Text = "Pulling latest changes from online GitHub..."
            git -C $script:RepoRoot pull --ff-only origin main
            if ($LASTEXITCODE -ne 0) {
                $txtStatus.Text = "Error: git pull --ff-only failed with exit code $LASTEXITCODE. Relaunch cancelled."
                [System.Windows.MessageBox]::Show("git pull --ff-only encountered an issue (divergent history or merge conflict). Please resolve git state manually.", "Pull Failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }
            $txtStatus.Text = "Updated to latest from online GitHub! Relaunching..."
            Invoke-ControllerRelaunch -force
        } else {
            $txtStatus.Text = "Update deferred."
        }
    } catch {
        $txtStatus.Text = "Update check failed: $_"
    }
}

function Start-StartupUpdateCheck {
    [System.Threading.Tasks.Task]::Run([Action]{
        try {
            git -C $script:RepoRoot fetch origin main --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { return }

            $behindCount = 0
            $behindStr = git -C $script:RepoRoot rev-list --count 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
            if ($LASTEXITCODE -eq 0 -and $behindStr) {
                $behindCount = [int]$behindStr
            }

            $diffOut = git -C $script:RepoRoot diff --stat 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
            $hasUpdate = ($behindCount -gt 0 -and $diffOut)

            $window.Dispatcher.Invoke([Action]{
                if ($hasUpdate) {
                    $btnUpdateController.Content = "🔔 Update Available!"
                    $btnUpdateController.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
                    $btnUpdateController.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
                    $btnUpdateController.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnUpdateController.ToolTip = "Online GitHub has a newer controller ($behindCount commit(s) ahead). Click to pull and relaunch."
                    $txtStatus.Text = "🔔 Update available on online GitHub ($behindCount controller commit(s) ahead). Click 'Update Available' to pull and relaunch."
                }
            })
        } catch {}
    }) | Out-Null
}

$btnRelaunch.add_Click({ Invoke-ControllerRelaunch })
$btnUpdateController.add_Click({ Invoke-ControllerUpdate })

$script:LastReadBlackboardText = ""
$script:LastCursorPad = $null
$script:LastGeminiPad = $null
$script:ActiveTurnOverride = $null
$script:TurnCueExpiresAt = $null
$script:SuppressTurnReset = $false
$script:SuppressFormDirty = $false
$script:FormDirty = $false

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.add_Tick({
    if (Test-Path $script:ScriptFilePath) {
        try {
            $diskTime = (Get-Item $script:ScriptFilePath).LastWriteTime
            if ($diskTime -gt $script:LoadedScriptWriteTime) {
                $script:DiskScriptIsNewer = $true
                if ($diskTime -ne $script:NewerScriptWriteTime) {
                    $script:NewerScriptWriteTime = $diskTime
                    $script:NewerScriptSinceUtc = [DateTime]::UtcNow
                    $script:AutoRelaunchStarted = $false
                }
                if ($btnRelaunch -and $btnRelaunch.Content -notmatch "Newer on Disk") {
                    $btnRelaunch.Content = "⏭️ Relaunch (Newer on Disk)"
                    $btnRelaunch.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
                    $btnRelaunch.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
                    $btnRelaunch.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnRelaunch.ToolTip = "scripts/blackboard-ui.ps1 on disk is newer ($($diskTime.ToString('HH:mm:ss'))). Relaunch is automatic after $($script:AutoRelaunchSettleSeconds)s when the form is clean."
                }
                $ready = Test-AutoRelaunchReady -diskNewer $true -formDirty ([bool]$script:FormDirty) -seenUtc $script:NewerScriptSinceUtc -nowUtc ([DateTime]::UtcNow) -settleSeconds $script:AutoRelaunchSettleSeconds
                if ($ready -and -not $script:AutoRelaunchStarted) {
                    $script:AutoRelaunchStarted = $true
                    if ($txtStatus) { $txtStatus.Text = "Script on disk stayed newer and the form is clean. Relaunching..." }
                    Invoke-ControllerRelaunch -force
                }
            } else {
                $script:NewerScriptSinceUtc = $null
                $script:AutoRelaunchStarted = $false
            }
        } catch {}
    }
    Update-GitStatusSummary
    if ($badgeTurn) {
        if ($script:TurnCueExpiresAt -and [DateTime]::UtcNow -lt $script:TurnCueExpiresAt) {
            $badgeTurn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
            $badgeTurn.BorderThickness = New-Object System.Windows.Thickness(2)
        } else {
            $badgeTurn.BorderThickness = New-Object System.Windows.Thickness(0)
            $badgeTurn.BorderBrush = $null
        }
    }
    if (Test-Path $script:BlackboardPath) {
        try {
            $text = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            if ($text -ne $script:LastReadBlackboardText) {
                $script:LastReadBlackboardText = $text
                Load-BlackboardIntoUI -fromTimer
            }
            Update-BlackboardViewer
        } catch {}
    }
})
$timer.Start()

function Load-BlackboardIntoUI {
    param([switch]$fromTimer)
    if (Test-Path $script:BlackboardPath) {
        $script:SuppressTurnReset = $true
        $script:SuppressFormDirty = $true
        $script:SuppressPhaseAutoAdvance = $true
        $script:NewSignoffDuringLoad = $false
        try {
            $raw = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            
            if (-not $fromTimer -or -not $script:FormDirty) {
                if ($raw -match '>\s*\*\*Flow Control\*\*:\s*`([^`]+)`') {
                    $f = $matches[1]
                    if ($f -match "STOP") { $rbStop.IsChecked = $true }
                    elseif ($f -match "PAUSE") { $rbPause.IsChecked = $true }
                    else { $rbGo.IsChecked = $true }
                }
                
                if ($raw -match '>\s*\*\*Project Phase\*\*:\s*`([^`]+)`') {
                    $p = $matches[1].Trim()
                    Set-Phase $p
                }
                
                if ($raw -match '>\s*\*\*GitHub Issue\*\*:\s*#?(\d+)') {
                    $txtIssueNum.Text = $matches[1].Trim()
                } else {
                    $txtIssueNum.Text = ""
                    $txtIssueTitle.Text = ""
                }
                
                $s1 = Get-Seat1Client
                $s2 = Get-Seat2Client
                $s1Esc = [regex]::Escape($s1)
                $s2Esc = [regex]::Escape($s2)

                if ($raw -match ('(?m)\|\s*\*\*(?:' + $s1Esc + '|Cursor|Agent\s*1|AI\s*1)\*\*\s*\|\s*`([^`]+)`')) {
                    $r = $matches[1].Trim()
                    for ($i = 0; $i -lt $cbCursorRole.Items.Count; $i++) {
                        if ($cbCursorRole.Items[$i].Content -eq $r) {
                            $cbCursorRole.SelectedIndex = $i
                            break
                        }
                    }
                }
                
                if ($raw -match ('(?m)\|\s*\*\*(?:' + $s2Esc + '|Gemini(?:\s+\(Antigravity\))?|Agent\s*2|AI\s*2)\*\*\s*\|\s*`([^`]+)`')) {
                    $r = $matches[1].Trim()
                    for ($i = 0; $i -lt $cbGeminiRole.Items.Count; $i++) {
                        if ($cbGeminiRole.Items[$i].Content -eq $r) {
                            $cbGeminiRole.SelectedIndex = $i
                            break
                        }
                    }
                }
                if ((Get-PhaseString) -eq "pitch") { Ensure-PitchSeatsAdvise }
            }
            
            if ($script:DiskScriptIsNewer) {
                $txtLastSaved.Text = "⚠️ Script on disk is newer! Click Relaunch"
                $txtLastSaved.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
            } elseif ($raw -match '>\s*\*\*Last Updated\*\*:\s*(.+)') {
                $txtLastSaved.Text = "File updated: " + $matches[1].Trim()
                $txtLastSaved.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6C7086")
            }
            
            Sync-SignoffCheckboxes $raw

            $s1 = Get-Seat1Client
            $s2 = Get-Seat2Client
            $s1Esc = [regex]::Escape($s1)
            $s2Esc = [regex]::Escape($s2)

            $newCursorPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1|AI\s*1)(?:\s+Scratchpad)?"
            $newGeminiPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2|AI\s*2)(?:\s+Scratchpad)?"
            Update-LastResponsePanes -cursorPad $newCursorPad -geminiPad $newGeminiPad
            
            if ($null -eq $script:LastCursorPad) {
                $script:LastCursorPad = $newCursorPad
                $script:LastGeminiPad = $newGeminiPad
                $script:ActiveTurnOverride = $null
            } else {
                $turnChanged = $false
                $autoOn = -not ($chkAutoStep -and -not $chkAutoStep.IsChecked)
                $flowNow = Get-FlowControlString
                if ($newCursorPad -ne $script:LastCursorPad -and $newCursorPad -notmatch "(?i)^-\s*\((?:$s1Esc|Cursor|Agent\s*1|AI\s*1)\s+(?:updates?|scratchpad)" -and $newCursorPad.Trim()) {
                    $script:LastCursorPad = $newCursorPad
                    $script:ActiveTurnOverride = "$s1 responded at " + (Get-Date -Format "HH:mm")
                    $turnChanged = $true
                    if (Test-UnsignedTestRollback -phase (Get-PhaseString) -autoStep $autoOn -flow $flowNow -padChanged $true -pad $newCursorPad) {
                        $script:PendingUnsignedRollback = $true
                    }
                }
                if ($newGeminiPad -ne $script:LastGeminiPad -and $newGeminiPad -notmatch "(?i)^-\s*\((?:$s2Esc|Gemini|Agent\s*2|AI\s*2)\s+(?:updates?|scratchpad)" -and $newGeminiPad.Trim()) {
                    $script:LastGeminiPad = $newGeminiPad
                    $script:ActiveTurnOverride = "$s2 responded at " + (Get-Date -Format "HH:mm")
                    $turnChanged = $true
                    if (Test-UnsignedTestRollback -phase (Get-PhaseString) -autoStep $autoOn -flow $flowNow -padChanged $true -pad $newGeminiPad) {
                        $script:PendingUnsignedRollback = $true
                    }
                }
                if ($turnChanged) {
                    $script:TurnCueExpiresAt = [DateTime]::UtcNow.AddSeconds(6)
                    if ($badgeTurn) {
                        $badgeTurn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
                        $badgeTurn.BorderThickness = New-Object System.Windows.Thickness(2)
                    }
                    if ($chkAudioCue -and $chkAudioCue.IsChecked) {
                        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
                    }
                }
            }
            
            if (-not $fromTimer) {
                $txtPrompt.Text = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Current Objective\s*&\s*Prompt')
                $alignLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Alignment\s*&\s*Agreed Decisions')
                $txtAlignment.Text = $alignLoaded
                $humanLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Human(?:\s+\(Lead\))?|[^\r\n]+?\s+\(Lead\)|Lead)')
                if ($humanLoaded) { $txtHumanNotes.Text = $humanLoaded }
                $script:FormDirty = $false
            } else {
                if (-not $script:FormDirty) {
                    $promptLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Current Objective\s*&\s*Prompt')
                    if ($promptLoaded -and $promptLoaded -ne $txtPrompt.Text) {
                        $txtPrompt.Text = $promptLoaded
                    }
                    $alignLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Alignment\s*&\s*Agreed Decisions')
                    if ($alignLoaded -ne $txtAlignment.Text) {
                        $txtAlignment.Text = $alignLoaded
                    }
                    $humanLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Human(?:\s+\(Lead\))?|[^\r\n]+?\s+\(Lead\)|Lead)')
                    if ($humanLoaded -and $humanLoaded -ne $txtHumanNotes.Text) {
                        $txtHumanNotes.Text = $humanLoaded
                    }
                }
            }

            # Auto-promote a - **Agreed**: sentence when the other scratchpad has - **Agree**, or when both sentences match.
            $currentPhase = if ($cbPhase -and $cbPhase.SelectedItem) { [string]$cbPhase.SelectedItem.Content } else { "" }
            if ($currentPhase -match '^(?:pitch|advise|discuss|plan)' -and (-not $script:FormDirty)) {
                $sharedLines = @(Get-SharedAgreedLines $newCursorPad $newGeminiPad)
                $newAgreedItems = @()
                foreach ($item in $sharedLines) {
                    if ($item -match '(?i)^\s*[*◦\-`"]*?\s*(?:Summary|Next)\b') { continue }
                    $alreadyInAlign = ($txtAlignment.Text -match [regex]::Escape($item))
                    if (-not $alreadyInAlign -and -not ($newAgreedItems -contains $item)) {
                        $newAgreedItems += $item
                    }
                }
                
                if ($newAgreedItems.Count -gt 0) {
                    $appendLines = ($newAgreedItems | ForEach-Object { "- **Agreed**: $_" }) -join [Environment]::NewLine
                    $joined = Join-TextWithSeparator -existing $txtAlignment.Text -addition $appendLines
                    if ($joined -ne $txtAlignment.Text) {
                        $txtAlignment.Text = $joined
                        Save-BlackboardContent
                        $txtStatus.Text = "Auto-promoted $($newAgreedItems.Count) agreed decision(s) to Alignment."
                    }
                }
            }
            
            if ($script:DiskScriptIsNewer -and (-not $script:FormDirty)) {
                $txtStatus.Text = "⚠️ Controller script on disk is newer than this open window. It relaunches after a short settle while the form stays clean."
            } elseif (-not $fromTimer) {
                $txtStatus.Text = "Loaded blackboard from .ai/blackboard.md"
            } elseif (-not $script:FormDirty) {
                $txtStatus.Text = "Updated from disk"
            }
            Check-Safety
            Update-UiActiveTurn -keepOverride
            Update-BlackboardViewer
            if ($script:CompareViewerWindow -and $script:CompareViewerWindow.IsVisible) {
                Update-CompareTurnsViewer
            }
            Update-GitStatusSummary
        } catch {
            $txtStatus.Text = "Error loading blackboard: $_"
        } finally {
            $script:SuppressTurnReset = $false
            $script:SuppressFormDirty = $false
            $script:SuppressPhaseAutoAdvance = $false
        }
        if ($script:PendingUnsignedRollback) {
            $script:NewSignoffDuringLoad = $false
            Invoke-UnsignedTestRollback
        } elseif ($script:NewSignoffDuringLoad) {
            $script:NewSignoffDuringLoad = $false
            Check-PhaseAutoAdvance
        }
    } else {
        Save-BlackboardContent
    }
}

if ($script:ClientConfig -and $script:ClientConfig.boardPath -and (Test-Path $script:ClientConfig.boardPath)) {
    Set-ActiveBlackboardPath -targetPath $script:ClientConfig.boardPath
} else {
    Load-BlackboardIntoUI
    Populate-RecentBoardsDropdown
}
if ($chkNewChatKickoff) { $chkNewChatKickoff.IsChecked = $false }
Start-StartupUpdateCheck

$window.ShowDialog() | Out-Null

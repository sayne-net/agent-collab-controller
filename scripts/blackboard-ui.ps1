# Dual-Session Blackboard Controller (WPF UI)
# Version 1.5.43
# Edit this file in place. Do not regenerate it from a scratch generator (that overwrote v1.5.3).

$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null

$script:AppVersion = "v1.5.43"
$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$script:ProjectName = (Split-Path $script:RepoRoot -Leaf)
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
$script:AiDir = Join-Path $script:RepoRoot ".ai"
$script:HistoryDir = Join-Path $script:AiDir "history"
$script:SavedDir = Join-Path $script:AiDir "saved"
$script:BlackboardPath = Join-Path $script:AiDir "blackboard.md"
$script:ExamplePath = Join-Path $script:AiDir "blackboard.example.md"

foreach ($dir in @($script:AiDir, $script:HistoryDir, $script:SavedDir)) {
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
            <RowDefinition Height="*" MinHeight="120"/> <!-- 3: Objective, Alignment & Steven Notes -->
            <RowDefinition Height="*" MinHeight="240"/> <!-- 4: Cursor | Gemini last-response panes -->
            <RowDefinition Height="Auto"/> <!-- 5: Agent Kickoff & Re-prompting -->
            <RowDefinition Height="Auto"/> <!-- 6: Actions -->
            <RowDefinition Height="Auto"/> <!-- 7: Status -->
        </Grid.RowDefinitions>

        <!-- 0: Header Bar & Quick Workflow Presets -->
        <Grid Grid.Row="0" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Presets Group -->
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="⚡ 1-Click Presets:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <Button Name="btnPresetDiscuss" Content="💬 Discuss" ToolTip="Cursor advise + Gemini advise (Phase: advise)" Margin="0,0,4,0"/>
                <Button Name="btnPresetPlan" Content="📋 Plan" ToolTip="Cursor plan + Gemini idle (Phase: plan)" Margin="0,0,4,0"/>
                <Button Name="btnPresetImplement" Content="🛠️ Implement" ToolTip="Gemini implement + Cursor review (Phase: implement)" Margin="0,0,4,0" Background="#45475A" Foreground="#89B4FA" FontWeight="SemiBold"/>
                <Button Name="btnPresetReview" Content="🔍 Review" ToolTip="Cursor review + Gemini review (Phase: review)" Margin="0,0,4,0"/>
                <Button Name="btnPresetTest" Content="🧪 Test" ToolTip="Cursor review + Gemini review (Phase: test). Sign-off after verification." Margin="0,0,4,0"/>
                <Button Name="btnPresetInventory" Content="📦 Inventory" ToolTip="Cursor inventory + Gemini inventory (Phase: review)" Margin="0,0,4,0"/>
                <Button Name="btnPresetIdle" Content="⏸️ All Idle" ToolTip="Reset all agents to idle" Margin="0,0,6,0"/>
                <Button Name="btnPromoteAlign" Content="🚀 Promote Align" ToolTip="Promote agreed decisions directly to status and notes" Background="#313244" Foreground="#A6E3A1"/>
            </StackPanel>

            <!-- Active Turn Badge, Relaunch & Update Buttons -->
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button Name="btnUpdateController" Content="🔄 Update App" Background="#313244" Foreground="#89B4FA" Margin="0,0,4,0" Padding="8,3" ToolTip="Check online GitHub for newer controller version, pull, and relaunch" FontWeight="SemiBold"/>
                <Button Name="btnRelaunch" Content="⏭️ Relaunch" Background="#313244" Foreground="#BAC2DE" Margin="0,0,8,0" Padding="8,3" ToolTip="Relaunch controller script immediately (reloads local code changes)"/>
                <Border Name="badgeTurn" Background="#45475A" CornerRadius="12" Padding="10,3">
                    <TextBlock Name="txtActiveTurn" Text="Steven (Lead)" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1"/>
                </Border>
            </StackPanel>
        </Grid>

        <!-- 1: Stoplight Flow Control & Phase Selector -->
        <Border Grid.Row="1" Background="#1E1E2E" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Stoplight -->
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🚦 Flow Control:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <RadioButton Name="rbGo" Content="🟢 GO" IsChecked="True" Foreground="#A6E3A1" VerticalAlignment="Center" ToolTip="Normal execution"/>
                    <RadioButton Name="rbPause" Content="🟡 PAUSE" Foreground="#F9E2AF" VerticalAlignment="Center" ToolTip="Wait for human input/review"/>
                    <RadioButton Name="rbStop" Content="🔴 ALL STOP" Foreground="#F38BA8" VerticalAlignment="Center" ToolTip="Emergency freeze"/>
                </StackPanel>

                <!-- Phase Selector -->
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="📍 Project Phase:" FontWeight="Bold" FontSize="12" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox Name="cbPhase" Width="180" SelectedIndex="0">
                        <ComboBoxItem Content="advise (Discussion)"/>
                        <ComboBoxItem Content="plan (Architecture &amp; Design)"/>
                        <ComboBoxItem Content="implement (Active Coding)"/>
                        <ComboBoxItem Content="review (Audit &amp; Verification)"/>
                        <ComboBoxItem Content="test (Verify scripts/UI)"/>
                        <ComboBoxItem Content="closed (Completed &amp; Closed)"/>
                    </ComboBox>
                </StackPanel>
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

                <!-- Agent 1 Role -->
                <StackPanel Grid.Column="0" Margin="0,0,6,0">
                    <TextBlock Text="Agent 1 Role" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,4"/>
                    <ComboBox Name="cbCursorRole" SelectedIndex="5">
                        <ComboBoxItem Content="implement"/>
                        <ComboBoxItem Content="review"/>
                        <ComboBoxItem Content="advise"/>
                        <ComboBoxItem Content="inventory"/>
                        <ComboBoxItem Content="plan"/>
                        <ComboBoxItem Content="idle"/>
                    </ComboBox>
                </StackPanel>

                <!-- Agent 2 Role -->
                <StackPanel Grid.Column="1" Margin="6,0,6,0">
                    <TextBlock Text="Agent 2 Role" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,4"/>
                    <ComboBox Name="cbGeminiRole" SelectedIndex="5">
                        <ComboBoxItem Content="review"/>
                        <ComboBoxItem Content="implement"/>
                        <ComboBoxItem Content="advise"/>
                        <ComboBoxItem Content="inventory"/>
                        <ComboBoxItem Content="plan"/>
                        <ComboBoxItem Content="idle"/>
                    </ComboBox>
                </StackPanel>

                <!-- Completion Sign-offs -->
                <StackPanel Grid.Column="2" Margin="6,0,6,0">
                    <TextBlock Text="Project Sign-off" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <CheckBox Name="chkSignSteven" Content="Human" Margin="0,0,6,0"/>
                        <CheckBox Name="chkSignCursor" Content="Agent 1" Margin="0,0,6,0"/>
                        <CheckBox Name="chkSignGemini" Content="Agent 2"/>
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
                        <TextBox Name="txtIssueNum" Text="" VerticalContentAlignment="Center"/>
                        <Button Name="btnFetchIssue" Grid.Column="1" Content="🔍" Margin="4,0,0,0" Padding="5,2" ToolTip="Fetch Issue info via gh CLI"/>
                        <Button Name="btnNewIssue" Grid.Column="2" Content="➕" Margin="2,0,0,0" Padding="5,2" ToolTip="Create new issue on GitHub"/>
                    </Grid>
                    <TextBlock Name="txtIssueTitle" Text="" FontSize="10" Foreground="#A6ADC8" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 3: Objective, Alignment & Steven Steering Notes -->
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

            <!-- Steven (Lead) Steering Notes -->
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
                        <TextBlock Text="👑 HUMAN (LEAD) NOTES" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center"/>
                        <Button Grid.Column="1" Name="btnPromoteNotes" Content="📝 Promote to Prompt" Background="#313244" Foreground="#F9E2AF" Padding="6,2" FontSize="10" ToolTip="Draft a Prompt from these steering notes (requires confirmation before replacing Current Objective)"/>
                    </Grid>
                    <TextBox Name="txtStevenNotes" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                             MinHeight="64" VerticalAlignment="Stretch"
                             Text="- Active steering notes."/>
                </Grid>
            </Border>
        </Grid>

        <!-- 4: Agent 1 | Agent 2 last-response panes (#23) -->
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
                    <TextBlock Grid.Row="0" Text="💠 AGENT 1 LAST RESPONSE" FontWeight="Bold" FontSize="11" Foreground="#89B4FA" Margin="0,0,0,6"/>
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
                    <TextBlock Grid.Row="0" Text="🪐 AGENT 2 LAST RESPONSE" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,6"/>
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

                <!-- Row 0 Left: Kickoff Buttons -->
                <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🚀 Kickoff:" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <Button Name="btnCopyCursorKickoff" Content="📋 Copy Agent 1" Background="#313244" Margin="0,0,4,0" ToolTip="Copy tailored Kickoff Prompt for Agent 1 to Clipboard"/>
                    <Button Name="btnSendCursorKickoff" Content="🚀 Send Agent 1" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" ToolTip="Focus Agent 1 window and paste Kickoff Prompt"/>
                    <Button Name="btnCopyGeminiKickoff" Content="📋 Copy Agent 2" Background="#313244" Margin="0,0,4,0" ToolTip="Copy tailored Kickoff Prompt for Agent 2 to Clipboard"/>
                    <Button Name="btnSendGeminiKickoff" Content="🚀 Send Agent 2" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" ToolTip="Focus Agent 2 window and paste Kickoff Prompt"/>
                    <Button Name="btnCopyBothKickoff" Content="📋 Copy Both" Background="#313244" Foreground="#BAC2DE" Margin="0,0,4,0" ToolTip="Copy combined Kickoff prompts for both agents to Clipboard"/>
                    <Button Name="btnSendBothKickoff" Content="🚀 Send Both" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,4,0" ToolTip="Sequence and send Kickoff prompts to both Agent 1 and Agent 2"/>
                    <CheckBox Name="chkNewChatKickoff" Content="New Chat" IsChecked="False" VerticalAlignment="Center" Margin="6,0,4,0" Foreground="#A6E3A1" ToolTip="Optional one-shot on Kickoff (default off at launch and Reset; armed on Close Project). Cursor palette Chat: New Chat; Antigravity Ctrl+Shift+I then Ctrl+Shift+L (never Ctrl+L / Ctrl+N). Unchecks after send. Re-prompt never opens a new chat."/>
                </StackPanel>

                <!-- Center Safety Warning -->
                <TextBlock Name="txtSafetyWarning" Grid.Row="0" Grid.Column="1" Text="" Foreground="#FAB387" FontWeight="Bold" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Center" TextAlignment="Center"/>

                <!-- Row 0 Right: Re-prompt Buttons -->
                <StackPanel Grid.Row="0" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡ Re-prompt Sync:" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <Button Name="btnRepromptCursor" Content="Agent 1" Background="#313244" Margin="0,0,4,0" ToolTip="Focus Agent 1 &amp; re-prompt"/>
                    <Button Name="btnRepromptGemini" Content="Agent 2" Background="#313244" Margin="0,0,4,0" ToolTip="Focus Agent 2 &amp; re-prompt"/>
                    <Button Name="btnRepromptBoth" Content="⚡ Both" Background="#45475A" Foreground="#F9E2AF" ToolTip="Re-prompt both agents"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 6: Action Controls -->
        <Grid Grid.Row="6" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Left Controls: Apply, Close Project, Reset, Snapshots, Text Output Button -->
            <StackPanel Orientation="Horizontal">
                <Button Name="btnApply" Content="💾 Apply Blackboard" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="12,5"/>
                <Button Name="btnCloseProject" Content="🏁 Close Project" Background="#313244" Foreground="#A6E3A1" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5" ToolTip="Audit git, optionally commit allowlisted files and ff-only push, then archive and idle"/>
                <Button Name="btnResetNoSave" Content="🧹 Reset (No Save)" Background="#45475A" Foreground="#CDD6F4" FontWeight="SemiBold" Margin="0,0,6,0" Padding="10,5" ToolTip="Clear prompt and idle agents in UI only; disk blackboard and history unchanged (later Apply keeps agent scratchpads)"/>
                <Button Name="btnReset" Content="🔄 Reset (Auto-Save)" Background="#F38BA8" Foreground="#11111B" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5" ToolTip="Optional named snapshot to .ai/history, then clears prompt and idles agents"/>
                <Button Name="btnSaveState" Content="📦 Save Snapshot" Margin="0,0,6,0" Padding="8,5"/>
                <Button Name="btnLoadState" Content="📂 Load State" Margin="0,0,6,0" Padding="8,5"/>
                <Button Name="btnViewText" Content="📄 Blackboard Output" Background="#45475A" Foreground="#89B4FA" Margin="0,0,6,0" Padding="8,5" ToolTip="Open separate window showing live blackboard markdown text"/>
                <Button Name="btnViewDiff" Content="🔍 Review Diff" Background="#45475A" Foreground="#A6E3A1" Margin="0,0,6,0" Padding="8,5" ToolTip="Open window showing git diff of uncommitted changes"/>
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
$window.Title = "Dual-Session Blackboard Controller - " + $script:AppVersion

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
$chkSignSteven         = $window.FindName("chkSignSteven")
$chkSignCursor         = $window.FindName("chkSignCursor")
$chkSignGemini         = $window.FindName("chkSignGemini")
$txtIssueNum           = $window.FindName("txtIssueNum")
$txtIssueTitle         = $window.FindName("txtIssueTitle")
$btnFetchIssue         = $window.FindName("btnFetchIssue")
$btnNewIssue           = $window.FindName("btnNewIssue")
$txtPrompt             = $window.FindName("txtPrompt")
$txtAlignment          = $window.FindName("txtAlignment")
$txtStevenNotes        = $window.FindName("txtStevenNotes")
$rtbCursorLast         = $window.FindName("rtbCursorLast")
$rtbGeminiLast         = $window.FindName("rtbGeminiLast")
$btnPresetDiscuss      = $window.FindName("btnPresetDiscuss")
$btnPresetImplement    = $window.FindName("btnPresetImplement")
$btnPresetReview       = $window.FindName("btnPresetReview")
$btnPresetTest         = $window.FindName("btnPresetTest")
$btnPresetInventory    = $window.FindName("btnPresetInventory")
$btnPresetPlan         = $window.FindName("btnPresetPlan")
$btnPresetIdle         = $window.FindName("btnPresetIdle")
$btnPromoteAlign       = $window.FindName("btnPromoteAlign")
$btnCopyCursorKickoff  = $window.FindName("btnCopyCursorKickoff")
$btnSendCursorKickoff  = $window.FindName("btnSendCursorKickoff")
$btnCopyGeminiKickoff  = $window.FindName("btnCopyGeminiKickoff")
$btnSendGeminiKickoff  = $window.FindName("btnSendGeminiKickoff")
$btnCopyBothKickoff    = $window.FindName("btnCopyBothKickoff")
$btnSendBothKickoff    = $window.FindName("btnSendBothKickoff")
$chkNewChatKickoff     = $window.FindName("chkNewChatKickoff")
$btnRepromptCursor     = $window.FindName("btnRepromptCursor")
$btnRepromptGemini     = $window.FindName("btnRepromptGemini")
$btnRepromptBoth       = $window.FindName("btnRepromptBoth")
$btnApply              = $window.FindName("btnApply")
$btnCloseProject        = $window.FindName("btnCloseProject")
$btnResetNoSave        = $window.FindName("btnResetNoSave")
$btnReset              = $window.FindName("btnReset")
$btnSaveState          = $window.FindName("btnSaveState")
$btnLoadState          = $window.FindName("btnLoadState")
$btnViewText           = $window.FindName("btnViewText")
$btnViewDiff           = $window.FindName("btnViewDiff")
$btnPromoteNotes       = $window.FindName("btnPromoteNotes")
$btnOpenHistory        = $window.FindName("btnOpenHistory")
$txtSafetyWarning      = $window.FindName("txtSafetyWarning")
$txtStatus             = $window.FindName("txtStatus")
$txtLastSaved          = $window.FindName("txtLastSaved")

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

function Update-ReviewDiffViewer {
    if (-not $script:DiffViewerWindow -or -not $script:DiffViewerWindow.IsVisible) { return }
    try {
        $diffRaw = @(git -C $script:RepoRoot diff HEAD 2>$null)
        $statusRaw = @(git -C $script:RepoRoot status --short 2>$null)
        
        $doc = New-Object System.Windows.Documents.FlowDocument
        $doc.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        $doc.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas, Courier New, monospace")
        $doc.FontSize = 12
        $doc.PagePadding = New-Object System.Windows.Thickness(10)

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

        if ($diffRaw.Count -eq 0 -and $statusRaw.Count -eq 0) {
            $pClean = New-Object System.Windows.Documents.Paragraph
            $pClean.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
            $pClean.Inlines.Add((New-Object System.Windows.Documents.Run("Working tree clean. No uncommitted changes detected.") -property @{ Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1"); FontStyle = [System.Windows.FontStyles]::Italic }))
            $doc.Blocks.Add($pClean)
        } elseif ($diffRaw.Count -gt 0) {
            $pDiff = New-Object System.Windows.Documents.Paragraph
            $pDiff.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $pDiff.Inlines.Add((New-Object System.Windows.Documents.Run("=== GIT DIFF (HEAD) ===`n") -property @{ FontWeight = [System.Windows.FontWeights]::Bold; Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#89B4FA") }))
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
            }
            $doc.Blocks.Add($pDiff)
        }

        # Render contents of untracked files
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
            $script:DiffViewerStatus.Text = "Diff updated (" + (Get-Date -Format "HH:mm:ss") + "). Lines: " + $diffRaw.Count + " | Changed files: " + $statusRaw.Count
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
                    <TextBlock Text="🔍 REVIEW GIT DIFF (Working Tree vs HEAD)" FontWeight="Bold" FontSize="12" Foreground="#A6E3A1" VerticalAlignment="Center"/>
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
                <TextBlock Grid.Column="1" Text="git diff HEAD" FontSize="10" Foreground="#6C7086" VerticalAlignment="Center"/>
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
            $raw = @(git -C $script:RepoRoot diff HEAD 2>$null)
            if ($raw.Count -gt 0) { [void]$diffText.AddRange($raw) }
            $statusRaw = @(git -C $script:RepoRoot status --short 2>$null)
            $untrackedEntries = @($statusRaw | Where-Object { $_.StartsWith("??") })
            foreach ($entry in $untrackedEntries) {
                $relPath = $entry.Substring(2).Trim().Trim('"')
                $fullPath = Join-Path $script:RepoRoot $relPath
                if ((Test-Path $fullPath) -and -not (Test-Path $fullPath -PathType Container)) {
                    [void]$diffText.Add("--- /dev/null")
                    [void]$diffText.Add("+++ b/$relPath")
                    $uLines = @(Get-Content -Path $fullPath -TotalCount 300 -ErrorAction SilentlyContinue)
                    foreach ($ul in $uLines) { [void]$diffText.Add("+$ul") }
                }
            }
            if ($diffText.Count -gt 0) {
                [System.Windows.Clipboard]::SetText(($diffText -join "`n"))
                $script:DiffViewerStatus.Text = "Diff (including untracked files) copied to clipboard."
            } else {
                $script:DiffViewerStatus.Text = "Nothing to copy (working tree clean)."
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

    Update-ReviewDiffViewer
    $diffWin.Show()
}

if ($btnViewDiff) {
    $btnViewDiff.add_Click({ Show-ReviewDiffViewer })
}

if ($btnPromoteNotes) {
    $btnPromoteNotes.add_Click({
        $rawNotes = $txtStevenNotes.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rawNotes) -or $rawNotes -eq "- Active steering notes.") {
            [System.Windows.MessageBox]::Show("Steven Notes are empty or default. Enter steering notes first.", "Promote Notes", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        $confirm = [System.Windows.MessageBox]::Show("Promote Steven Notes to Current Objective & Prompt?`n`n[Notes Preview]:`n$rawNotes`n`nNote: This will update the Prompt field and mark blackboard dirty. It will not auto-send or create an issue.", "Confirm Promote Notes", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $clean = $rawNotes -replace '^(?:-\s*|\*\s*)', ''
            $txtPrompt.Text = $clean
            Mark-FormDirty
            $txtStatus.Text = "Steven Notes promoted to Current Objective & Prompt."
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
        return ($item.Content -split " ")[0]
    }
    return "plan"
}

function Get-ActiveTurn {
    if ($script:ActiveTurnOverride) {
        if ($script:ActiveTurnOverride -match "Gemini|Agent 2") {
            $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkBlue
        } else {
            $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkCyan
        }
        return $script:ActiveTurnOverride
    }
    $signSteven = $chkSignSteven.IsChecked
    $signCursor = $chkSignCursor.IsChecked
    $signGemini = $chkSignGemini.IsChecked
    if ($signSteven -and $signCursor -and $signGemini) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkGreen
        return "✅ Complete - Ready to Close"
    }
    if (-not $signSteven) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::SlateGray
        return "Human (Lead)"
    }
    $cRole = if ($cbCursorRole.Text) { $cbCursorRole.Text } else { "idle" }
    $gRole = if ($cbGeminiRole.Text) { $cbGeminiRole.Text } else { "idle" }
    if ($cRole -ne "idle" -and -not $signCursor) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkCyan
        return ("Agent 1 (" + $cRole + ")")
    }
    if ($gRole -ne "idle" -and -not $signGemini) {
        $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkBlue
        return ("Agent 2 (" + $gRole + ")")
    }
    $badgeTurn.Background = [System.Windows.Media.Brushes]::DarkGreen
    return "✅ Complete - Ready to Close"
}

function Update-UiActiveTurn {
    param([switch]$keepOverride)
    if ($script:SuppressTurnReset -and -not $keepOverride) {
        return
    }
    if (-not $keepOverride) {
        $script:ActiveTurnOverride = $null
    }
    $txtActiveTurn.Text = Get-ActiveTurn
    if ($btnCloseProject) {
        if ($chkSignSteven.IsChecked -and $chkSignCursor.IsChecked -and $chkSignGemini.IsChecked) {
            $btnCloseProject.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
            $btnCloseProject.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
        } else {
            $btnCloseProject.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#313244")
            $btnCloseProject.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6E3A1")
        }
    }
}

function Check-Safety {
    $cursor = $cbCursorRole.Text
    $gemini = $cbGeminiRole.Text
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
$cbPhase.add_SelectionChanged({ Mark-FormDirty })
$rbGo.add_Checked({ Mark-FormDirty })
$rbPause.add_Checked({ Mark-FormDirty })
$rbStop.add_Checked({ Mark-FormDirty })
$chkSignSteven.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignSteven.add_Unchecked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignCursor.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignCursor.add_Unchecked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignGemini.add_Checked({ Update-UiActiveTurn; Mark-FormDirty })
$chkSignGemini.add_Unchecked({ Update-UiActiveTurn; Mark-FormDirty })
$txtPrompt.add_TextChanged({ Mark-FormDirty })
$txtAlignment.add_TextChanged({ Mark-FormDirty })
$txtStevenNotes.add_TextChanged({ Mark-FormDirty })
if ($rtbCursorLast) {
    $rtbCursorLast.add_SizeChanged({
        if ($rtbCursorLast.Document -and $rtbCursorLast.ActualWidth -gt 48) {
            $rtbCursorLast.Document.PageWidth = $rtbCursorLast.ActualWidth - 16
        }
    })
}
if ($rtbGeminiLast) {
    $rtbGeminiLast.add_SizeChanged({
        if ($rtbGeminiLast.Document -and $rtbGeminiLast.ActualWidth -gt 48) {
            $rtbGeminiLast.Document.PageWidth = $rtbGeminiLast.ActualWidth - 16
        }
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
    if ((Get-PhaseString) -eq "closed") {
        return "This project/objective is CLOSED. All sign-offs complete. Hold IDLE. Do not modify files or execute tasks unless a new objective is assigned."
    }
    if ((Get-PhaseString) -eq "test") {
        return "Project phase is TEST. Verify the program/script/UI already landed. Exercise the live controller or script under test (do not relaunch a second blackboard-ui unless asked). Record pass/fail in your scratchpad. FORBIDDEN: new features. After a recorded pass (or N/A with why), set your Agent Roles Sign-off [x] and scratchpad Sign-off: [x]. GO does not mean implement."
    }
    switch (Get-NormalizedRole $role) {
        "implement" { "You hold IMPLEMENT. Review objective and Alignment in '$boardPath', then land the change. Append progress under your scratchpad heading only. Do not edit the other agent's scratchpad or Steven's notes." }
        "review"    { "You hold REVIEW. Read the implementer's notes and diff. Record findings in your scratchpad. FORBIDDEN: editing the same tracked files they are changing. GO does not make you implement." }
        "advise"    { "You hold ADVISE. Analyze and recommend in your scratchpad only. FORBIDDEN: editing tracked repo files, git commit/push, live fabric changes. REQUIRED: Edit '$boardPath' under your scratchpad heading." }
        "plan"      { "You hold PLAN. Propose approach and risks in your scratchpad. Do not edit tracked files unless Steven says so." }
        "inventory" { "You hold INVENTORY. Read MCP/hosts/STATUS/INDEX/git log. No live writes. No tracked-file edits except your blackboard scratchpad." }
        default     { "You hold IDLE. Read the board. Do not act. Do not edit files. Wait." }
    }
}

function Get-NonImplementHardStop {
    param([string]$role)
    $boardPath = $script:BlackboardPath
    if ((Get-PhaseString) -eq "closed") {
        return @"
NOTICE: Project phase is CLOSED. All sign-offs have been completed.
Hold IDLE. Do not modify files, execute tasks, or make commits unless Steven assigns a new active objective.

"@
    }
    $r = Get-NormalizedRole $role
    if ($r -eq "implement") { return "" }
    return @"
STOP. Assigned role is $r, not implement.
FORBIDDEN: editing tracked repository files, git commit/push, live fabric changes (Omada/DNS/Unraid).
ALLOWED & REQUIRED: Edit '$boardPath' using your file editing tool under your scratchpad section only (append/update; do not wipe Steven or the other agent).
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

Do not mark Sign-off complete yet. For programs/scripts, sign off only after the test phase with recorded verification.
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

function Get-KickoffPromptForAgent {
    param(
        [string]$agentName,
        [string]$role
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
    $roleGuidance = Get-RoleGuidance $normRole
    $scratchpadSection = if ($agentName -match 'Cursor|Agent\s*1') {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Cursor Scratchpad" -Quiet)) { "### Cursor Scratchpad" } else { "### Agent 1 Scratchpad" }
    } else {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Gemini \(Antigravity\) Scratchpad" -Quiet)) { "### Gemini (Antigravity) Scratchpad" } else { "### Agent 2 Scratchpad" }
    }

    $mandatoryBlock = if ($normRole -eq "implement") {
@"
MANDATORY ACTION:
1. Blackboard Updates: Edit '$boardPath' (targeted chunk/block replacement) to append your plan/progress under '$scratchpadSection' only. Never overwrite the entire blackboard; do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/.
2. Implementation: Land tracked repository changes, code, and documentation as required by the objective.
3. Verification: Ensure the header (GitHub Issue and Objective) matches this prompt. If mismatched, halt and alert the user.
Do not only reply in chat; all dual-session collaboration takes place through $boardPath.
"@
    } else {
@"
MANDATORY ACTION:
1. Target File: '$boardPath' ONLY (do NOT edit blackboard.example.md, .ai/history/, or .ai/saved/).
2. Edit Scope: Use your file editing tool (targeted chunk/block replacement) to update under '$scratchpadSection' only. Never overwrite the entire file.
3. Verification: Ensure the header (GitHub Issue and Objective) matches this prompt. If mismatched, halt and alert the user.
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

Role Instructions:
$roleGuidance
$signOffGuidance

$mandatoryBlock
"@
}

function Get-RepromptPromptForAgent {
    param(
        [string]$agentName,
        [string]$role
    )
    $normRole = Get-NormalizedRole $role
    $flow = Get-FlowControlString
    $phase = Get-PhaseString
    $hardStop = Get-NonImplementHardStop $normRole
    $signOffGuidance = Get-SignOffGuidance
    $boardPath = $script:BlackboardPath
    $scratchpadSection = if ($agentName -match 'Cursor|Agent\s*1') {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Cursor Scratchpad" -Quiet)) { "### Cursor Scratchpad" } else { "### Agent 1 Scratchpad" }
    } else {
        if ((Test-Path $boardPath) -and (Select-String -Path $boardPath -Pattern "### Gemini \(Antigravity\) Scratchpad" -Quiet)) { "### Gemini (Antigravity) Scratchpad" } else { "### Agent 2 Scratchpad" }
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

    return @"
Read $boardPath again and respond to the latest notes from the other agent or Steven.
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
    $cRole = if ($cbCursorRole.Text) { $cbCursorRole.Text } else { "" }
    $gRole = if ($cbGeminiRole.Text) { $cbGeminiRole.Text } else { "" }
    $cText = if ($cursorPad) { Get-ScratchpadExcerpt $cursorPad -PreferRole $cRole } else { "(no Cursor scratchpad yet)" }
    $gText = if ($geminiPad) { Get-ScratchpadExcerpt $geminiPad -PreferRole $gRole } else { "(no Gemini scratchpad yet)" }
    Set-LastResponseDocument $rtbCursorLast $cText
    Set-LastResponseDocument $rtbGeminiLast $gText
}

function Sync-SignoffCheckboxes {
    param([string]$raw)
    if ([string]::IsNullOrEmpty($raw)) { return }
    
    $signPattern = '(?im)^\s*[-*]\s+(?:\*\*)?(?:(?:Cursor|Gemini|Agent\s*1|Agent\s*2)\s+)?sign-?off(?:\*\*)?[:\s].*?(\[x\]|yes|complete|approved)'
    
    # 1. Human (Lead) / Steven: role table [x] or manual GUI check
    if ($raw -match '(?m)\|\s*\*\*(?:Human|Steven)\s*(?:\(Lead\))?\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[x\]') {
        $chkSignSteven.IsChecked = $true
    }
    
    # 2. Agent 1 (Cursor): role table [x] OR last scratchpad sign-off confirmation
    $cTable = ($raw -match '(?m)\|\s*\*\*(?:Cursor|Agent\s*1)\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[x\]')
    $cPad = Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Cursor|Agent\s*1)(?:\s+Scratchpad)?'
    $cPadSign = ($cPad -match $signPattern)
    if ($cTable -or $cPadSign) {
        $chkSignCursor.IsChecked = $true
    }
    
    # 3. Agent 2 (Gemini): role table [x] OR last scratchpad sign-off confirmation
    $gTable = ($raw -match '(?m)\|\s*\*\*(?:Gemini(?:\s+\(Antigravity\))?|Agent\s*2)\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*\[x\]')
    $gPad = Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?'
    $gPadSign = ($gPad -match $signPattern)
    if ($gTable -or $gPadSign) {
        $chkSignGemini.IsChecked = $true
    }
}

function Save-BlackboardContent {
    param([string]$customPath = $script:BlackboardPath, [switch]$clearScratchpads)
    
    Update-UiActiveTurn -keepOverride
    $flow = Get-FlowControlString
    $phase = Get-PhaseString
    $cursorRole = if ($cbCursorRole.Text) { $cbCursorRole.Text } else { "idle" }
    $geminiRole = if ($cbGeminiRole.Text) { $cbGeminiRole.Text } else { "idle" }
    $issue = $txtIssueNum.Text.Trim()
    $issueRef = if ($issue) { "#$issue" } else { "none" }
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    
    $stevenNotes = if ($txtStevenNotes.Text.Trim()) { $txtStevenNotes.Text } else { "- Active steering notes." }
    $humanLabel = "**Human (Lead)**"
    $agent1Label = "**Agent 1**"
    $agent2Label = "**Agent 2**"
    $humanHeader = "### Human (Lead)"
    $agent1Header = "### Agent 1 Scratchpad"
    $agent2Header = "### Agent 2 Scratchpad"
    $cursorScratchpad = "- (Agent 1 updates here)"
    $geminiScratchpad = "- (Agent 2 updates here)"
    $cPadSign = $false
    $gPadSign = $false
    $signPattern = '(?im)^\s*[-*]\s+(?:\*\*)?(?:(?:Cursor|Gemini|Agent\s*1|Agent\s*2)\s+)?sign-?off(?:\*\*)?[:\s].*?(\[x\]|yes|complete|approved)'
    if (Test-Path $script:BlackboardPath) {
        try {
            $existing = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            if ($existing -match '(?m)\|\s*\*\*Steven \(Lead\)\*\*') { $humanLabel = "**Steven (Lead)**" }
            if ($existing -match '(?m)\|\s*\*\*Cursor\*\*') { $agent1Label = "**Cursor**" }
            if ($existing -match '(?m)\|\s*\*\*Gemini \(Antigravity\)\*\*') { $agent2Label = "**Gemini (Antigravity)**" }
            if ($existing -match '### Steven \(Lead\)') { $humanHeader = "### Steven (Lead)" }
            if ($existing -match '### Cursor Scratchpad') { 
                $agent1Header = "### Cursor Scratchpad"
                $cursorScratchpad = "- (Cursor updates here)"
            }
            if ($existing -match '### Gemini \(Antigravity\) Scratchpad') { 
                $agent2Header = "### Gemini (Antigravity) Scratchpad"
                $geminiScratchpad = "- (Gemini updates here)"
            }

            if (-not $clearScratchpads) {
                $cPad = Get-LastMarkdownBody $existing '(?:###|##)\s+(?:Cursor|Agent\s*1)(?:\s+Scratchpad)?'
                $gPad = Get-LastMarkdownBody $existing '(?:###|##)\s+(?:Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?'
                if ($cPad) { 
                    $cursorScratchpad = $cPad
                    $cPadSign = ($cPad -match $signPattern)
                }
                if ($gPad) { 
                    $geminiScratchpad = $gPad
                    $gPadSign = ($gPad -match $signPattern)
                }
            }
        } catch {}
    }

    $signSteven = if ($chkSignSteven.IsChecked) { "[x]" } else { "[ ]" }
    $signCursor = if ($chkSignCursor.IsChecked -or $cPadSign) { "[x]" } else { "[ ]" }
    $signGemini = if ($chkSignGemini.IsChecked -or $gPadSign) { "[x]" } else { "[ ]" }

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
        ("| " + $humanLabel + " | " + $q + "lead" + $q + " | Active | " + $signSteven + " |"),
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
        $txtPrompt.Text,
        "",
        "---",
        "",
        "## Alignment & Agreed Decisions",
        "",
        $txtAlignment.Text,
        "",
        "---",
        "",
        "## Working Notes & Scratchpads",
        "",
        $humanHeader,
        $stevenNotes,
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

# Cursor chat caret: focus Cursor, optionally open a new chat via Command Palette, then paste+enter.
function Send-CursorChatPaste {
    param([bool]$newChat = $false)
    if (-not [WinHelper]::FocusProcess("Cursor")) { return $false }
    Start-Sleep -Milliseconds 150
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

# Gemini (Antigravity): never type guessed palette titles. Never Ctrl+L (toggles agent panel shut).
# Never click the composer — empty New Chat is centered, so pixel clicks steal focus.
# New Chat: Ctrl+Shift+I then Ctrl+Shift+L, wait for the centered composer caret, paste.
# Same-thread Kickoff / Re-prompt: Ctrl+Shift+I (focus composer, no new thread), then paste.
# Never Esc (dismisses composer), Ctrl+N, or Ctrl+A.
function Send-GeminiChatPaste {
    param([bool]$newChat = $false)
    if (-not [WinHelper]::FocusProcess("Antigravity")) { return $false }
    Start-Sleep -Milliseconds 280
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
    $txtStevenNotes.Text = "- Active steering notes."
    $cbCursorRole.SelectedIndex = 5
    $cbGeminiRole.SelectedIndex = 5
    $cbPhase.SelectedIndex = 0
    $chkSignSteven.IsChecked = $false
    $chkSignCursor.IsChecked = $false
    $chkSignGemini.IsChecked = $false
    $txtActiveTurn.Text = "Steven (Lead)"
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
    $signSteven = $chkSignSteven.IsChecked
    $signCursor = $chkSignCursor.IsChecked
    $signGemini = $chkSignGemini.IsChecked
    $allSigned = ($signSteven -and $signCursor -and $signGemini)
    $phaseNow = Get-PhaseString
    if ($phaseNow -ne "test" -and $phaseNow -ne "closed") {
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
    
    $confirmMsg = if ($allSigned) {
        "All participants (Steven, Cursor, Gemini) have signed off.`n`nClose this project, archive session history, and reset board to idle?"
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
                $closeArgs = @("issue", "close", $num, "--comment", "Completed with sign-offs from Steven, Cursor, and Gemini.")
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
    $cbPhase.SelectedIndex = 5 # closed
    $rbGo.IsChecked = $true
    Save-BlackboardContent -clearScratchpads
    $txtStatus.Text = "Project closed & archived to .ai/history. Board reset to idle. New Chat armed for next project."
})

$btnResetNoSave.add_Click({
    Clear-FormInMemory
    $txtStatus.Text = "Reset form in UI only — disk blackboard unchanged."
})

$btnReset.add_Click({
    Auto-ArchiveSnapshot
    Clear-FormInMemory
    $rbGo.IsChecked = $true
    Save-BlackboardContent -clearScratchpads
    $txtStatus.Text = "Reset blackboard (Archived previous state to .ai/history)."
})

$btnPromoteAlign.add_Click({
    $align = $txtAlignment.Text.Trim()
    if ($align) {
        $txtPrompt.Text = "Promoted Alignment Decision:" + [Environment]::NewLine + $align
        $cbPhase.SelectedIndex = 2 # implement
        $cbCursorRole.SelectedIndex = 1 # review
        $cbGeminiRole.SelectedIndex = 1 # implement
        $txtStevenNotes.Text = "- Active steering notes."
        Save-BlackboardContent -clearScratchpads
        $txtStatus.Text = "Promoted agreed decisions to active implementation objective."
    }
})

# 1-Click Workflow Preset Handlers
$btnPresetDiscuss.add_Click({
    $cbCursorRole.SelectedIndex = 2
    $cbGeminiRole.SelectedIndex = 2
    $cbPhase.SelectedIndex = 0
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Discussion Mode (Cursor advise + Gemini advise)"
    Check-Safety
})

$btnPresetImplement.add_Click({
    $cbCursorRole.SelectedIndex = 1
    $cbGeminiRole.SelectedIndex = 1
    $cbPhase.SelectedIndex = 2
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Implementation Mode (Gemini implement + Cursor review)"
    Check-Safety
})

$btnPresetReview.add_Click({
    $cbCursorRole.SelectedIndex = 1
    $cbGeminiRole.SelectedIndex = 0
    $cbPhase.SelectedIndex = 3
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Review Mode (Cursor review + Gemini review)"
    Check-Safety
    Show-ReviewDiffViewer
})

$btnPresetTest.add_Click({
    $cbCursorRole.SelectedIndex = 1
    $cbGeminiRole.SelectedIndex = 0
    $cbPhase.SelectedIndex = 4
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Test Mode (Cursor review + Gemini review, phase test)"
    Check-Safety
})

$btnPresetInventory.add_Click({
    $cbCursorRole.SelectedIndex = 3
    $cbGeminiRole.SelectedIndex = 3
    $cbPhase.SelectedIndex = 3
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Inventory Mode (Cursor inventory + Gemini inventory)"
    Check-Safety
})

$btnPresetPlan.add_Click({
    $cbCursorRole.SelectedIndex = 4
    $cbGeminiRole.SelectedIndex = 5
    $cbPhase.SelectedIndex = 1
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: Planning Mode (Cursor plan + Gemini idle)"
    Check-Safety
})

$btnPresetIdle.add_Click({
    $cbCursorRole.SelectedIndex = 5
    $cbGeminiRole.SelectedIndex = 5
    $script:FormDirty = $true
    $txtStatus.Text = "Preset: All Agents Idle"
    Check-Safety
})

# Kickoff Prompt Button Handlers
$btnCopyCursorKickoff.add_Click({
    try {
        Save-BlackboardContent
        $kPrompt = Get-KickoffPromptForAgent -agentName "Cursor" -role $cbCursorRole.Text
        Safe-SetClipboard $kPrompt
        $txtStatus.Text = "📋 Copied Cursor Kickoff Prompt (" + $cbCursorRole.Text + ") to clipboard."
    } catch { $txtStatus.Text = "Error copying prompt: $_" }
})

$btnCopyGeminiKickoff.add_Click({
    try {
        Save-BlackboardContent
        $kPrompt = Get-KickoffPromptForAgent -agentName "Gemini (Antigravity)" -role $cbGeminiRole.Text
        Safe-SetClipboard $kPrompt
        $txtStatus.Text = "📋 Copied Gemini Kickoff Prompt (" + $cbGeminiRole.Text + ") to clipboard."
    } catch { $txtStatus.Text = "Error copying prompt: $_" }
})

$btnSendCursorKickoff.add_Click({
    try {
        Save-BlackboardContent
        $kPrompt = Get-KickoffPromptForAgent -agentName "Cursor" -role $cbCursorRole.Text
        Safe-SetClipboard $kPrompt
        $doNew = [bool]($chkNewChatKickoff -and $chkNewChatKickoff.IsChecked)
        if (Send-CursorChatPaste -newChat $doNew) {
            Complete-KickoffNewChatOneShot -didNew $doNew
            $chatNote = if ($doNew) { " (New Chat, then off)" } else { "" }
            $txtStatus.Text = "🚀 Sent Cursor Kickoff Prompt to active Cursor window$chatNote."
        } else {
            $txtStatus.Text = "📋 Copied Cursor Kickoff to clipboard (Cursor window not found). Focus Cursor and paste."
        }
    } catch { $txtStatus.Text = "Error sending prompt: $_" }
})

$btnSendGeminiKickoff.add_Click({
    try {
        Save-BlackboardContent
        $kPrompt = Get-KickoffPromptForAgent -agentName "Gemini (Antigravity)" -role $cbGeminiRole.Text
        Safe-SetClipboard $kPrompt
        $doNew = [bool]($chkNewChatKickoff -and $chkNewChatKickoff.IsChecked)
        if (Send-GeminiChatPaste -newChat $doNew) {
            Complete-KickoffNewChatOneShot -didNew $doNew
            $chatNote = if ($doNew) { " (New Chat Ctrl+Shift+I then Ctrl+Shift+L, then off)" } else { "" }
            $txtStatus.Text = "🚀 Sent Gemini Kickoff Prompt to Antigravity$chatNote."
        } else {
            $txtStatus.Text = "📋 Copied Gemini Kickoff to clipboard (Antigravity window not found). Focus Antigravity and paste."
        }
    } catch { $txtStatus.Text = "Error sending prompt: $_" }
})

$btnCopyBothKickoff.add_Click({
    try {
        Save-BlackboardContent
        $pCursor = Get-KickoffPromptForAgent -agentName "Cursor" -role $cbCursorRole.Text
        $pGemini = Get-KickoffPromptForAgent -agentName "Gemini (Antigravity)" -role $cbGeminiRole.Text
        $combined = "=== [CURSOR KICKOFF PROMPT] ===" + [Environment]::NewLine + $pCursor + [Environment]::NewLine + [Environment]::NewLine + "=== [GEMINI KICKOFF PROMPT] ===" + [Environment]::NewLine + $pGemini
        Safe-SetClipboard $combined
        $txtStatus.Text = "📋 Copied combined Kickoff prompts for both Cursor and Gemini to clipboard."
    } catch { $txtStatus.Text = "Error copying prompts: $_" }
})

$btnSendBothKickoff.add_Click({
    try {
        Save-BlackboardContent
        $pCursor = Get-KickoffPromptForAgent -agentName "Cursor" -role $cbCursorRole.Text
        $pGemini = Get-KickoffPromptForAgent -agentName "Gemini (Antigravity)" -role $cbGeminiRole.Text
        $doNew = [bool]($chkNewChatKickoff -and $chkNewChatKickoff.IsChecked)

        # 1. Focus & Send Cursor
        Safe-SetClipboard $pCursor
        $cFocused = Send-CursorChatPaste -newChat $doNew
        Start-Sleep -Milliseconds 600

        # 2. Focus & Send Gemini (Antigravity only)
        Safe-SetClipboard $pGemini
        $gFocused = Send-GeminiChatPaste -newChat $doNew

        if ($cFocused -or $gFocused) {
            Complete-KickoffNewChatOneShot -didNew $doNew
        }
        if ($cFocused -and $gFocused) {
            $chatNote = if ($doNew) { " (New Chat one-shot, now off)" } else { "" }
            $txtStatus.Text = "🚀 Successfully kicked off both Cursor and Gemini agents!$chatNote"
        } elseif ($cFocused) {
            $txtStatus.Text = "🚀 Kicked off Cursor. (Antigravity window not found - focus Antigravity to paste Gemini prompt)."
        } elseif ($gFocused) {
            Safe-SetClipboard $pCursor
            $txtStatus.Text = "🚀 Kicked off Gemini. Cursor prompt copied to clipboard (Cursor window not found). Focus Cursor to paste."
        } else {
            Safe-SetClipboard ("=== [CURSOR KICKOFF PROMPT] ===" + [Environment]::NewLine + $pCursor + [Environment]::NewLine + [Environment]::NewLine + "=== [GEMINI KICKOFF PROMPT] ===" + [Environment]::NewLine + $pGemini)
            $txtStatus.Text = "📋 Copied both kickoff prompts to clipboard (focus IDEs to paste)."
        }
    } catch { $txtStatus.Text = "Error during dual kickoff: $_" }
})

$btnSaveState.add_Click({
    try {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("Named snapshot (no tokens/passwords). File goes to .ai/saved/ — git add only after a secrets glance:", "Save Project State", "project-" + (Get-Date -Format "yyyyMMdd-HHmm"))
        if ($name) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($name.Trim())
            $safe = ($base -replace '[^a-zA-Z0-9_-]', '-')
            if (-not $safe) { $safe = "project-" + (Get-Date -Format "yyyyMMdd-HHmm") }
            $name = $safe + ".md"
            $target = Join-Path $script:SavedDir $name
            Save-BlackboardContent -customPath $target
            [System.Windows.MessageBox]::Show("Saved state to .ai/saved/" + $name, "State Saved", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    } catch { $txtStatus.Text = "Error saving state: $_" }
})

$btnLoadState.add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.InitialDirectory = $script:AiDir
        $dlg.Filter = "Markdown files (*.md)|*.md|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $loadedContent = [System.IO.File]::ReadAllText($dlg.FileName)
            [System.IO.File]::WriteAllText($script:BlackboardPath, $loadedContent, [System.Text.Encoding]::UTF8)
            Load-BlackboardIntoUI
            $txtStatus.Text = "Loaded state from: " + [System.IO.Path]::GetFileName($dlg.FileName)
        }
    } catch { $txtStatus.Text = "Error loading state: $_" }
})

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
        $pCursor = Get-RepromptPromptForAgent -agentName "Cursor" -role $cbCursorRole.Text
        $pGemini = Get-RepromptPromptForAgent -agentName "Gemini (Antigravity)" -role $cbGeminiRole.Text
        $cFocused = $false
        $gFocused = $false

        if ($target -eq "Cursor" -or $target -eq "Both") {
            Safe-SetClipboard $pCursor
            if (Send-CursorChatPaste -newChat $false) {
                $cFocused = $true
            }
        }
        if ($target -eq "Both") {
            Start-Sleep -Milliseconds 600
        }
        if ($target -eq "Gemini" -or $target -eq "Both") {
            Safe-SetClipboard $pGemini
            if (Send-GeminiChatPaste -newChat $false) {
                $gFocused = $true
            }
        }

        if ($cFocused -and $gFocused) {
            $txtStatus.Text = "⚡ Re-prompted Cursor & Gemini (role-aware)."
        } elseif ($target -eq "Both" -and $cFocused) {
            Safe-SetClipboard $pGemini
            $txtStatus.Text = "⚡ Re-prompted Cursor. Gemini prompt copied (Antigravity not found)."
        } elseif ($target -eq "Both" -and $gFocused) {
            Safe-SetClipboard $pCursor
            $txtStatus.Text = "⚡ Re-prompted Gemini. Cursor prompt copied (Cursor not found)."
        } elseif ($cFocused -or $gFocused) {
            $who = if ($cFocused) { "Cursor" } else { "Gemini" }
            $txtStatus.Text = "⚡ Re-prompted $who (role-aware)."
        } else {
            if ($target -eq "Cursor") { Safe-SetClipboard $pCursor }
            elseif ($target -eq "Gemini") { Safe-SetClipboard $pGemini }
            else {
                Safe-SetClipboard ("=== [CURSOR] ===" + [Environment]::NewLine + $pCursor + [Environment]::NewLine + [Environment]::NewLine + "=== [GEMINI] ===" + [Environment]::NewLine + $pGemini)
            }
            $txtStatus.Text = "⚡ Copied role-aware re-prompt to clipboard (no IDE focused)."
        }
    } catch { $txtStatus.Text = "Error during re-prompt: $_" }
}

$btnRepromptCursor.add_Click({ Trigger-AgentReprompt -target "Cursor" })
$btnRepromptGemini.add_Click({ Trigger-AgentReprompt -target "Gemini" })
$btnRepromptBoth.add_Click({ Trigger-AgentReprompt -target "Both" })

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
$script:SuppressTurnReset = $false
$script:SuppressFormDirty = $false
$script:FormDirty = $false

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.add_Tick({
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
                    for ($i = 0; $i -lt $cbPhase.Items.Count; $i++) {
                        if ($cbPhase.Items[$i].Content -like "$p*") {
                            $cbPhase.SelectedIndex = $i
                            break
                        }
                    }
                }
                
                if ($raw -match '>\s*\*\*GitHub Issue\*\*:\s*#?(\d+)') {
                    $txtIssueNum.Text = $matches[1].Trim()
                } else {
                    $txtIssueNum.Text = ""
                    $txtIssueTitle.Text = ""
                }
                
                if ($raw -match '\|\s*\*\*Cursor\*\*\s*\|\s*`([^`]+)`') {
                    $r = $matches[1].Trim()
                    for ($i = 0; $i -lt $cbCursorRole.Items.Count; $i++) {
                        if ($cbCursorRole.Items[$i].Content -eq $r) {
                            $cbCursorRole.SelectedIndex = $i
                            break
                        }
                    }
                }
                
                if ($raw -match '\|\s*\*\*Gemini \(Antigravity\)\*\*\s*\|\s*`([^`]+)`') {
                    $r = $matches[1].Trim()
                    for ($i = 0; $i -lt $cbGeminiRole.Items.Count; $i++) {
                        if ($cbGeminiRole.Items[$i].Content -eq $r) {
                            $cbGeminiRole.SelectedIndex = $i
                            break
                        }
                    }
                }
            }
            
            if ($raw -match '>\s*\*\*Last Updated\*\*:\s*(.+)') {
                $txtLastSaved.Text = "File updated: " + $matches[1].Trim()
            }
            
            Sync-SignoffCheckboxes $raw
            
            $newCursorPad = Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Cursor|Agent\s*1)(?:\s+Scratchpad)?'
            $newGeminiPad = Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?'
            Update-LastResponsePanes -cursorPad $newCursorPad -geminiPad $newGeminiPad
            
            if ($null -eq $script:LastCursorPad) {
                $script:LastCursorPad = $newCursorPad
                $script:LastGeminiPad = $newGeminiPad
                $script:ActiveTurnOverride = $null
            } else {
                if ($newCursorPad -ne $script:LastCursorPad -and $newCursorPad -notmatch '(?i)^-\s*\((?:Cursor|Agent\s*1)\s+(?:updates?|scratchpad)' -and $newCursorPad.Trim()) {
                    $script:LastCursorPad = $newCursorPad
                    $script:ActiveTurnOverride = "Agent 1 responded at " + (Get-Date -Format "HH:mm")
                }
                if ($newGeminiPad -ne $script:LastGeminiPad -and $newGeminiPad -notmatch '(?i)^-\s*\((?:Gemini|Agent\s*2)\s+(?:updates?|scratchpad)' -and $newGeminiPad.Trim()) {
                    $script:LastGeminiPad = $newGeminiPad
                    $script:ActiveTurnOverride = "Agent 2 responded at " + (Get-Date -Format "HH:mm")
                }
            }
            
            if (-not $fromTimer) {
                $txtPrompt.Text = Get-LastMarkdownBody $raw '##\s+Current Objective\s*&\s*Prompt'
                $alignLoaded = Get-LastMarkdownBody $raw '##\s+Alignment\s*&\s*Agreed Decisions'
                if ($alignLoaded -eq "---") { $alignLoaded = "" }
                $txtAlignment.Text = $alignLoaded
                $stevenLoaded = Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Human|Steven)(?:\s+\(Lead\))?'
                if ($stevenLoaded) { $txtStevenNotes.Text = $stevenLoaded }
                $script:FormDirty = $false
            }
            
            if (-not $fromTimer) {
                $txtStatus.Text = "Loaded blackboard from .ai/blackboard.md"
            } elseif (-not $script:FormDirty) {
                $txtStatus.Text = "Updated from disk"
            }
            Check-Safety
            Update-UiActiveTurn -keepOverride
            Update-BlackboardViewer
        } catch {
            $txtStatus.Text = "Error loading blackboard: $_"
        } finally {
            $script:SuppressTurnReset = $false
            $script:SuppressFormDirty = $false
        }
    } else {
        Save-BlackboardContent
    }
}

Load-BlackboardIntoUI
if ($chkNewChatKickoff) { $chkNewChatKickoff.IsChecked = $false }
Start-StartupUpdateCheck

$window.ShowDialog() | Out-Null

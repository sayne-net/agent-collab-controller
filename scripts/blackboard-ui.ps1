# AI Collab Controller (WPF UI)
# Version 1.5.6
# Standalone dual-session controller for multi-agent collaboration with human-in-the-loop steering.
# SemVer tracks protocol and feature releases. Do not bump the patch on every local edit.
# 1.5.6: kickoff and re-prompt no longer paste scratchpad excerpts or repeat the scratchpad rule.
# 1.5.5: last-response panes show the whole scratchpad, not the first bold bullet.
# 1.5.4: headless UI test for Refresh, F5, Promote, Demote, reconcile, and control round-trip.
# 1.5.3: strip multiline alignment indexes and drop repeated decisions.
# 1.5.2: F5 refresh, none seats, debrief questions, AG indexes, item codes, reconcile.

param(
    [string]$TargetRepo = "",
    [switch]$HeadlessTest
)

$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null

$script:AppVersion = "v1.5.6"
$script:EnabledPhases = @("pitch","discuss","plan","implement","review","test","closing","debrief")
$script:UnsignedRollbackStreak = 0
$script:PhaseBeforeReconcile = ""
$script:ReconcileTurns1 = 0
$script:ReconcileTurns2 = 0
$script:ControllerRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:UserConfigDir = Join-Path $HOME ".blackboard"
$script:UserConfigPath = Join-Path $script:UserConfigDir "config.json"

function Test-SameFullPath {
    param([string]$left, [string]$right)
    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { return $false }
    try {
        $a = [System.IO.Path]::GetFullPath($left).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($right).TrimEnd('\', '/')
        return $a.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-UserBlackboardConfig {
    $empty = [PSCustomObject]@{ lastOpenedRepo = "" }
    if (-not (Test-Path $script:UserConfigPath)) { return $empty }
    try {
        $json = Get-Content $script:UserConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json) { return $empty }
        if (-not $json.PSObject.Properties['lastOpenedRepo']) {
            $json | Add-Member -NotePropertyName "lastOpenedRepo" -NotePropertyValue "" -Force
        }
        return $json
    } catch {
        return $empty
    }
}

function Save-LastOpenedRepo {
    param([string]$repoPath)
    if ([string]::IsNullOrWhiteSpace($repoPath)) { return }
    try {
        if (-not (Test-Path $script:UserConfigDir)) {
            New-Item -ItemType Directory -Force -Path $script:UserConfigDir | Out-Null
        }
        $cfg = Get-UserBlackboardConfig
        $cfg.lastOpenedRepo = $repoPath
        $exportObj = [PSCustomObject]@{ lastOpenedRepo = $repoPath }
        $jsonStr = $exportObj | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:UserConfigPath, $jsonStr, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Warning "Save-LastOpenedRepo failed: $_"
    }
}

function Resolve-LaunchRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($TargetRepo)) {
        if (Test-Path -LiteralPath $TargetRepo) {
            return (Resolve-Path -LiteralPath $TargetRepo).Path
        }
        Write-Warning "TargetRepo not found: $TargetRepo"
    }
    $saved = [string](Get-UserBlackboardConfig).lastOpenedRepo
    if ($saved -and (Test-Path -LiteralPath $saved)) {
        $resolved = (Resolve-Path -LiteralPath $saved).Path
        if (-not (Test-SameFullPath $resolved $script:ControllerRoot)) {
            return $resolved
        }
    }
    return $null
}

$script:LaunchRepoRoot = Resolve-LaunchRepoRoot
if ($script:LaunchRepoRoot) {
    $script:RepoRoot = $script:LaunchRepoRoot
} else {
    $script:RepoRoot = $script:ControllerRoot
}
$script:ProjectName = (Split-Path $script:RepoRoot -Leaf)
$script:ScriptFilePath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot "blackboard-ui.ps1" }
$script:LoadedScriptWriteTime = if (Test-Path $script:ScriptFilePath) { (Get-Item $script:ScriptFilePath).LastWriteTime } else { [DateTime]::MinValue }
$script:DiskScriptIsNewer = $false
$script:ClosingSignoffsCompleted = $false
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
                <TextBlock Text="⚡ Task Preset:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox Name="cbPresets" Width="150" SelectedIndex="0" Margin="0,0,10,0" ToolTip="Task preset sets which phase badges are on. It does not assign roles.">
                    <ComboBoxItem Content="Full" Tag="Full" ToolTip="Phases on: pitch, discuss, plan, implement, review, test, closing, debrief"/>
                    <ComboBoxItem Content="Hotfix" Tag="Hotfix" ToolTip="Phases on: implement, test, closing, debrief"/>
                    <ComboBoxItem Content="Docs" Tag="Docs" ToolTip="Phases on: discuss, implement, test, debrief"/>
                    <ComboBoxItem Content="RFC" Tag="RFC" ToolTip="Phases on: pitch, discuss, debrief"/>
                </ComboBox>
                <TextBlock Text="📍 Current Phase:" FontWeight="Bold" FontSize="11" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox Name="cbPhase" Width="175" SelectedIndex="0" ToolTip="Current project workflow phase step">
                    <ComboBoxItem Content="ready (Waiting for Objective)"/>
                    <ComboBoxItem Content="pitch (Proposals &amp; Ideas)"/>
                    <ComboBoxItem Content="discuss (Discussion &amp; Debate)"/>
                    <ComboBoxItem Content="plan (Architecture &amp; Design)"/>
                    <ComboBoxItem Content="implement (Active Coding)"/>
                    <ComboBoxItem Content="review (Audit &amp; Verification)"/>
                    <ComboBoxItem Content="test (Verify scripts/UI)"/>
                    <ComboBoxItem Content="closing (Final sign-off)"/>
                    <ComboBoxItem Content="debrief (Post-run Review)"/>
                    <ComboBoxItem Content="reconcile (Disagreement turns)"/>
                </ComboBox>
            </StackPanel>

            <!-- Active Turn Badge, Relaunch, Update Buttons & Tooltip/Audio Toggles -->
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <CheckBox Name="chkEnableTooltips" Content="💡 Tooltips" IsChecked="True" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <CheckBox Name="chkAudioCue" Content="🔔 Sound" IsChecked="False" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="Play subtle audio chime when an agent responds or changes turn (default off)"/>
                <CheckBox Name="chkShowObjective" Content="Objective" IsChecked="True" Foreground="#BAC2DE" Margin="0,0,6,0"/>
                <CheckBox Name="chkShowAlignment" Content="Alignment" IsChecked="True" Foreground="#BAC2DE" Margin="0,0,6,0"/>
                <CheckBox Name="chkShowNotes" Content="Notes" IsChecked="True" Foreground="#BAC2DE" Margin="0,0,6,0"/>
                <CheckBox Name="chkShowResponses" Content="Responses" IsChecked="True" Foreground="#BAC2DE" Margin="0,0,6,0"/>
                <CheckBox Name="chkAutoStep" Content="⚡ Auto Step" IsChecked="False" Foreground="#BAC2DE" VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Off by default. On: sign-offs advance one enabled phase. A disagreement jumps to reconcile and returns after sign-off. Roles stay as assigned."/>
                <Button Name="btnStats" Content="📊 Stats" Background="#313244" Foreground="#F9E2AF" Margin="0,0,8,0" Padding="8,3" ToolTip="Open the per-seat stats window"/>
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
                        <Button Name="btnNewBoard" Content="➕ New Project Board" FontSize="10" Padding="5,1" Margin="0,0,3,0" Background="#313244" Foreground="#A6E3A1" FontWeight="SemiBold" ToolTip="Ask for a folder, create .ai/blackboard.md, and carry the current objective"/>
                        <Button Name="btnSwitchBoard" Content="📂 Browse" FontSize="10" Padding="5,1" Margin="0,0,3,0" Background="#313244" Foreground="#BAC2DE" ToolTip="Browse to select an existing blackboard.md file"/>
                        <Button Name="btnReloadBoard" Content="🔄 Refresh" FontSize="10" Padding="5,1" Margin="0,0,0,0" Background="#313244" Foreground="#89B4FA" FontWeight="SemiBold" ToolTip="Reload the blackboard from disk (F5). If the form is dirty, confirm first. Disk wins."/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>

        <!-- 2: Agent Roles, Sign-off, & Issue Tracker Card -->
        <Border Grid.Row="2" Background="#1E1E2E" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" BorderBrush="#313244" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="1.2*"/>
                    <ColumnDefinition Width="*"/>
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
                                <ComboBoxItem Content="none"/>
                            </ComboBox>
                        </StackPanel>
                    </Grid>
                </StackPanel>

                <StackPanel Grid.Column="1" Margin="6,0" VerticalAlignment="Center">
                    <TextBlock Text="Implementation Task" FontWeight="Bold" FontSize="11" Foreground="#CBA6F7" Margin="0,0,0,4"/>
                    <ComboBox Name="cbImplementMode" Width="160" SelectedIndex="0">
                        <ComboBoxItem Content="Code" ToolTip="Edits tracked files in the target repo."/>
                        <ComboBoxItem Content="Submit GitHub Issues" ToolTip="Files GitHub issues and does not edit tracked files."/>
                    </ComboBox>
                </StackPanel>

                <!-- AI 2 Role -->
                <StackPanel Grid.Column="2" Margin="6,0,6,0">
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
                                <ComboBoxItem Content="none"/>
                            </ComboBox>
                        </StackPanel>
                    </Grid>
                </StackPanel>

                <!-- Completion Sign-offs -->
                <StackPanel Grid.Column="3" Margin="6,0,6,0">
                    <TextBlock Text="Project Sign-off" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" Margin="0,0,0,4"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <CheckBox Name="chkSignHuman" Content="Human" Margin="0,0,8,0" ToolTip="Human stays required for Close Project"/>
                        <CheckBox Name="chkSignCursor" Content="AI 1" Margin="0,0,4,0"/>
                        <CheckBox Name="chkGateSeat1" Content="Gate" IsChecked="True" Margin="0,0,8,0" ToolTip="Seat 1 counts toward sign-off"/>
                        <CheckBox Name="chkSignGemini" Content="AI 2" Margin="0,0,4,0"/>
                        <CheckBox Name="chkGateSeat2" Content="Gate" IsChecked="True" Margin="0,0,8,0" ToolTip="Seat 2 counts toward sign-off"/>
                    </StackPanel>
                    <TextBlock Name="txtGitStatusSummary" Text="Git: clean" FontSize="10" Foreground="#A6ADC8" Margin="0,3,0,0" ToolTip="Read-only git status for active repository"/>
                </StackPanel>

                <!-- GitHub Issue Tracker -->
                <StackPanel Grid.Column="4" Margin="6,0,0,0">
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
            <Border Name="borderObjective" Grid.Column="0" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="0,0,4,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
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
            <Border Name="borderAlignment" Grid.Column="1" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,4,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="🤝 ALIGNMENT &amp; DECISIONS" FontWeight="Bold" FontSize="11" Foreground="#A6E3A1" Margin="0,0,0,6"/>
                    <TextBox Name="txtAlignment" Grid.Row="1" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                             MinHeight="64" VerticalAlignment="Stretch"
                             Text="- Follow Windows WPF / PowerShell standards.&#x0a;- Maintain safety guard: max 1 implement agent.&#x0a;- Ephemeral snapshots in .ai/history/."/>
                    <TextBlock Grid.Row="2" Text="Bug / disagreement" FontSize="10" Foreground="#F38BA8" Margin="0,6,0,2"/>
                    <TextBox Name="txtBugs" Grid.Row="3" AcceptsReturn="True" TextWrapping="Wrap" MinHeight="36" Margin="0,0,0,0" ToolTip="Bugs and disagreements. A disagreement jumps to reconcile when Auto Step is on."/>
                    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,6,0,0">
                        <TextBox Name="txtItemCode" Width="88" Margin="0,0,4,0" ToolTip="Item code such as CUR1 or ANT1. Click a colored code to fill this box."/>
                        <Button Name="btnPromoteCode" Content="Promote" Margin="0,0,4,0" Padding="8,2" ToolTip="Add this code's suggestion to Alignment if it is not already there"/>
                        <Button Name="btnDemoteCode" Content="Demote" Padding="8,2" ToolTip="Remove this code from Alignment"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Human (Lead) Steering Notes -->
            <Border Name="borderNotes" Grid.Column="2" Background="#1E1E2E" CornerRadius="8" Padding="10" Margin="4,0,0,0" BorderBrush="#313244" BorderThickness="1" VerticalAlignment="Stretch">
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
        <Grid Name="gridResponses" Grid.Row="4" Margin="0,0,0,8">
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
                    <Button Name="btnCopyKickoffPrompt" Content="📋 Copy Prompt" Background="#89B4FA" Foreground="#11111B" FontWeight="Bold" Margin="0,0,4,0" ToolTip="Canonical handoff. Copy the kickoff prompt to the clipboard."/>
                    <Button Name="btnSendKickoffPrompt" Content="Send (best-effort)" Background="#313244" Foreground="#BAC2DE" Margin="0,0,6,0" ToolTip="Best-effort only. Focus and SendKeys can miss Electron chats. The prompt is also copied to the clipboard."/>
                    <CheckBox Name="chkNewChatKickoff" Content="New Chat" IsChecked="False" VerticalAlignment="Center" Margin="4,0,4,0" Foreground="#A6E3A1" ToolTip="Optional one-shot on Kickoff. Cursor uses Chat: New Chat; Antigravity uses Ctrl+Shift+I then Ctrl+Shift+L. Codex New Chat is unavailable (desktop app limitation; open new chat manually in Codex). Re-prompt never opens a new chat."/>
                    <CheckBox Name="chkDryRunKickoff" Content="Dry run" IsChecked="False" VerticalAlignment="Center" Margin="4,0,4,0" Foreground="#89B4FA" ToolTip="Record the selected kickoff target, New Chat state, and status. Do not copy or send the prompt."/>
                </StackPanel>

                <!-- Center Safety Warning -->
                <TextBlock Name="txtSafetyWarning" Grid.Row="0" Grid.Column="1" Text="" Foreground="#FAB387" FontWeight="Bold" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Center" TextAlignment="Center"/>

                <!-- Row 0 Right: Re-prompt Buttons -->
                <StackPanel Grid.Row="0" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="⚡ Re-prompt Sync:" FontWeight="Bold" FontSize="11" Foreground="#F9E2AF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <Button Name="btnRepromptCursor" Content="AI 1 (best-effort)" Background="#313244" Margin="0,0,4,0" ToolTip="Best-effort re-prompt for AI 1. Clipboard copy is the reliable handoff."/>
                    <Button Name="btnRepromptGemini" Content="AI 2 (best-effort)" Background="#313244" Margin="0,0,4,0" ToolTip="Best-effort re-prompt for AI 2. Clipboard copy is the reliable handoff."/>
                    <Button Name="btnRepromptBoth" Content="Both (best-effort)" Background="#45475A" Foreground="#F9E2AF" Margin="0,0,6,0" ToolTip="Best-effort re-prompt for both seats. Clipboard copy is the reliable handoff."/>
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
                <Button Name="btnCloseProject" Content="🏁 Close Project" Background="#313244" Foreground="#A6E3A1" FontWeight="Bold" Margin="0,0,6,0" Padding="10,5" ToolTip="Audit the target repo git status, confirm tracked files, ff-only push, then archive and idle"/>
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
                
                $carried = if ($txtPrompt) { $txtPrompt.Text } else { "" }
                Set-ActiveBlackboardPath -targetPath $targetBlackboard
                if ($carried -and $txtPrompt) {
                    $txtPrompt.Text = $carried
                    Save-BlackboardContent
                }
                $txtStatus.Text = "New project board: $targetBlackboard"
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
$window.add_PreviewKeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) {
        $_.Handled = $true
        Reload-ActiveBlackboard
    }
})

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
$txtBugs               = $window.FindName("txtBugs")
$txtItemCode           = $window.FindName("txtItemCode")
$btnPromoteCode        = $window.FindName("btnPromoteCode")
$btnDemoteCode         = $window.FindName("btnDemoteCode")
$cbImplementMode       = $window.FindName("cbImplementMode")
$btnStats              = $window.FindName("btnStats")
$chkGateSeat1          = $window.FindName("chkGateSeat1")
$chkGateSeat2          = $window.FindName("chkGateSeat2")
$chkShowObjective      = $window.FindName("chkShowObjective")
$chkShowAlignment      = $window.FindName("chkShowAlignment")
$chkShowNotes          = $window.FindName("chkShowNotes")
$chkShowResponses      = $window.FindName("chkShowResponses")
$borderObjective       = $window.FindName("borderObjective")
$borderAlignment       = $window.FindName("borderAlignment")
$borderNotes           = $window.FindName("borderNotes")
$gridResponses         = $window.FindName("gridResponses")
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
        autoStep = $false
        profiles = [PSCustomObject]@{
            "AI 1" = [PSCustomObject]@{ process = ""; description = "Generic Seat 1 (Manual Clipboard Copy)" }
            "AI 2" = [PSCustomObject]@{ process = ""; description = "Generic Seat 2 (Manual Clipboard Copy)" }
            "Cursor" = [PSCustomObject]@{ process = "Cursor"; description = "Cursor AI IDE" }
            "Antigravity" = [PSCustomObject]@{ process = "Antigravity"; description = "Google Antigravity IDE" }
            "Windsurf" = [PSCustomObject]@{ process = "Windsurf"; description = "Codeium Windsurf IDE" }
            "VS Code" = [PSCustomObject]@{ process = "Code"; description = "VS Code / GitHub Copilot" }
            "Terminal" = [PSCustomObject]@{ process = "WindowsTerminal"; description = "Windows Terminal (Claude Code, Aider, CLI)" }
            "Codex" = [PSCustomObject]@{ process = "ChatGPT"; description = "OpenAI Codex in the ChatGPT desktop app" }
            "None" = [PSCustomObject]@{ process = ""; description = "Empty seat. Left out of kickoff and the sign-off gate." }
        }
    }

    $ensureConfig = {
        param($obj)
        if ($obj) {
            if (-not $obj.PSObject.Properties['recentBoards']) { $obj | Add-Member -NotePropertyName "recentBoards" -NotePropertyValue @() -Force }
            if (-not $obj.PSObject.Properties['boardSeats']) { $obj | Add-Member -NotePropertyName "boardSeats" -NotePropertyValue ([PSCustomObject]@{}) -Force }
            if (-not $obj.PSObject.Properties['tooltips']) { $obj | Add-Member -NotePropertyName "tooltips" -NotePropertyValue $true -Force }
            if (-not $obj.PSObject.Properties['audioCue']) { $obj | Add-Member -NotePropertyName "audioCue" -NotePropertyValue $false -Force }
            if (-not $obj.PSObject.Properties['autoStep']) { $obj | Add-Member -NotePropertyName "autoStep" -NotePropertyValue $false -Force }
            if ($obj.profiles) {
                if (-not $obj.profiles.PSObject.Properties['None']) {
                    $obj.profiles | Add-Member -NotePropertyName "None" -NotePropertyValue ([PSCustomObject]@{ process = ""; description = "Empty seat. Left out of kickoff and the sign-off gate." }) -Force
                }
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
    "btnReloadBoard"       = "Reload the blackboard from disk (F5). If the form is dirty, confirm first. Disk wins."
    "cbPhase"              = "Select current project workflow phase (ready, pitch, discuss, plan, implement, review, test, closing, debrief)"

    # Seat Profiles, Roles, Sign-offs & Issues
    "cbSeat1Client"        = "Select AI client / IDE profile for Seat 1"
    "cbSeat2Client"        = "Select AI client / IDE profile for Seat 2"
    "cbCursorRole"         = "Select active role permissions for Seat 1"
    "cbGeminiRole"         = "Select active role permissions for Seat 2"
    "chkSignHuman"         = "Phase sign-off approval from Human Lead (all 3 advance phase / close project)"
    "chkSignCursor"        = "Phase sign-off approval from Seat 1 (all 3 advance phase / close project)"
    "chkSignGemini"        = "Phase sign-off approval from Seat 2 (all 3 advance phase / close project)"
    "chkAutoStep"          = "Off by default. On advances one phase badge when all three sign-offs are checked. Roles are not changed."
    "txtGitStatusSummary"  = "Read-only summary of active git branch and uncommitted changes"
    "txtIssueNum"          = "Associated GitHub issue number (e.g. 24 or none)"
    "txtIssueTitle"        = "Fetched title of the linked GitHub issue"
    "btnFetchIssue"        = "Fetch issue title and metadata via gh CLI"
    "btnNewIssue"          = "Create a new issue on GitHub via gh CLI"

    # Prompt, Alignment & Steering Notes
    "txtPrompt"            = "Enter primary task objective, requirements, and acceptance criteria"
    "txtAlignment"         = "Key design rules, architectural constraints, and agreed decisions"
    "txtHumanNotes"        = "Active steering notes and directives from the Human Lead"
    "btnPromoteNotes"      = "Draft a Prompt from these steering notes (appends to Current Objective)"

    # Response Panes
    "rtbCursorLast"        = "Formatted view of Seat 1's latest scratchpad response"
    "rtbGeminiLast"        = "Formatted view of Seat 2's latest scratchpad response"
    "btnPromoteSeat1"      = "Promote selected text or latest proposal bullet from Seat 1 into Alignment"
    "btnPromoteSeat2"      = "Promote selected text or latest proposal bullet from Seat 2 into Alignment"

    # Kickoff & Reprompt Dispatch
    "cbKickoffTarget"      = "Select kickoff recipient target (Seat 1, Seat 2, or Both)"
    "btnCopyKickoffPrompt" = "Canonical handoff. Copy the kickoff prompt to the clipboard."
    "btnSendKickoffPrompt" = "Best-effort only. Focus and SendKeys can miss the chat. The prompt is also on the clipboard."
    "chkNewChatKickoff"    = "Optional one-shot on Kickoff. Cursor uses Chat: New Chat; Antigravity uses Ctrl+Shift+I then Ctrl+Shift+L. Codex New Chat is unavailable (desktop app limitation; open new chat manually in Codex). Re-prompt never opens a new chat."
    "chkDryRunKickoff"     = "Record the selected kickoff target, New Chat state, and status. Do not copy or send the prompt."
    "btnRepromptCursor"    = "Best-effort re-prompt for Seat 1. Clipboard copy is the reliable handoff."
    "btnRepromptGemini"    = "Best-effort re-prompt for Seat 2. Clipboard copy is the reliable handoff."
    "btnRepromptBoth"      = "Best-effort re-prompt for both seats. Clipboard copy is the reliable handoff."
    "btnCompareNotes"      = "Send a compare-notes re-prompt to both agents without replacing Objective or Alignment"

    # Bottom Toolbar Actions
    "btnApply"             = "Write current form configuration to active blackboard.md on disk"
    "btnCloseProject"      = "Audit the target repo, confirm tracked files, archive the session to .ai/history, and reset the board"
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
            "autoStep"     = $false
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
        $autoStepVal = if ($chkAutoStep) { [bool]$chkAutoStep.IsChecked } elseif ($null -ne $cfg.autoStep) { [bool]$cfg.autoStep } else { $false }
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

$script:CodexAlertTimer = $null
$script:CodexFlashCount = 0
$script:LastCodexTargeted = $false

function Trigger-CodexNewChatAlert {
    param([string]$message = "⚠️ New Chat unavailable for Codex: manually open a new chat in the Codex app.")
    
    if ($txtStatus) {
        $txtStatus.Text = $message
        $txtStatus.FontWeight = [System.Windows.FontWeights]::Bold
        $txtStatus.FontSize = 12
        $txtStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387")
    }
    
    $cursorRole = if (Get-Command Get-ComboRoleText -ErrorAction SilentlyContinue) { Get-ComboRoleText $cbCursorRole } else { "" }
    $geminiRole = if (Get-Command Get-ComboRoleText -ErrorAction SilentlyContinue) { Get-ComboRoleText $cbGeminiRole } else { "" }
    $hasRoleConflict = ($cursorRole -eq "implement" -and $geminiRole -eq "implement")
    if (-not $hasRoleConflict -and $txtSafetyWarning) {
        $txtSafetyWarning.Text = $message
        $txtSafetyWarning.FontWeight = [System.Windows.FontWeights]::Bold
        $txtSafetyWarning.FontSize = 11
        $txtSafetyWarning.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
    }

    if ($script:CodexAlertTimer) {
        $script:CodexAlertTimer.Stop()
    }
    $script:CodexFlashCount = 0
    $script:CodexAlertTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:CodexAlertTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $script:CodexAlertTimer.add_Tick({
        $script:CodexFlashCount++
        $isBright = ($script:CodexFlashCount % 2 -eq 1)
        
        if ($txtStatus) {
            $txtStatus.Foreground = if ($isBright) {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
            } else {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FAB387")
            }
        }
        if (-not $hasRoleConflict -and $txtSafetyWarning) {
            $txtSafetyWarning.Foreground = if ($isBright) {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F38BA8")
            } else {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
            }
        }
        
        if ($script:CodexFlashCount -ge 6) {
            $script:CodexAlertTimer.Stop()
            $script:CodexAlertTimer = $null
            if ($txtStatus) {
                $txtStatus.FontWeight = [System.Windows.FontWeights]::Normal
                $txtStatus.FontSize = 11
                $txtStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6ADC8")
            }
        }
    })
    $script:CodexAlertTimer.Start()
}

function Sync-CodexNewChatState {
    param(
        [string]$seat1,
        [string]$seat2,
        [string]$target
    )

    if (-not $chkNewChatKickoff) { return }

    $isCodexTargeted = ($target -eq "Both" -and ($seat1 -eq "Codex" -or $seat2 -eq "Codex")) -or `
                       ($target -eq "Seat1" -and $seat1 -eq "Codex") -or `
                       ($target -eq "Seat2" -and $seat2 -eq "Codex")

    if ($isCodexTargeted) {
        $wasChecked = $chkNewChatKickoff.IsChecked
        $chkNewChatKickoff.IsChecked = $false
        $chkNewChatKickoff.IsEnabled = $false
        $chkNewChatKickoff.Opacity = 0.4
        $chkNewChatKickoff.ToolTip = "New Chat is unavailable when Codex is targeted (ChatGPT client limitation). Please manually open a new chat in the Codex app."

        if (-not $script:LastCodexTargeted -or $wasChecked) {
            Trigger-CodexNewChatAlert -message "⚠️ New Chat unavailable for Codex: manually open a new chat in the Codex app."
        }
        $script:LastCodexTargeted = $true
    } else {
        $chkNewChatKickoff.IsEnabled = $true
        $chkNewChatKickoff.Opacity = 1.0
        if ($script:MasterTooltips -and $script:MasterTooltips["chkNewChatKickoff"]) {
            $chkNewChatKickoff.ToolTip = $script:MasterTooltips["chkNewChatKickoff"]
        } else {
            $chkNewChatKickoff.ToolTip = "Optional one-shot on Kickoff. Cursor uses Chat: New Chat; Antigravity uses Ctrl+Shift+I then Ctrl+Shift+L. Codex New Chat is unavailable (desktop app limitation; open new chat manually in Codex). Re-prompt never opens a new chat."
        }
        
        if ($txtSafetyWarning -and $txtSafetyWarning.Text -like "*New Chat unavailable for Codex*") {
            $txtSafetyWarning.Text = ""
        }
        $script:LastCodexTargeted = $false
    }
}

function Update-KickoffButtonTooltips {
    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $targetName = "Both ($s1 & $s2)"
    $targetTag = "Both"
    if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) {
        $tag = [string]$cbKickoffTarget.SelectedItem.Tag
        if ($tag -eq "Seat1") { 
            $targetName = $s1 
            $targetTag = "Seat1"
        }
        elseif ($tag -eq "Seat2") { 
            $targetName = $s2 
            $targetTag = "Seat2"
        }
    }
    if (-not $script:DiskScriptIsNewer) {
        if ($btnCopyKickoffPrompt) {
            $btnCopyKickoffPrompt.ToolTip = "Canonical handoff. Copy the $targetName kickoff prompt to the clipboard."
        }
        if ($btnSendKickoffPrompt) {
            $btnSendKickoffPrompt.ToolTip = "Best-effort focus and SendKeys for $targetName. The prompt is also copied to the clipboard."
        }
    }

    Sync-CodexNewChatState -seat1 $s1 -seat2 $s2 -target $targetTag
}

function Update-PromptButtonsLockState {
    param([bool]$locked)

    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    $brushConv = [System.Windows.Media.BrushConverter]::new()

    if ($locked) {
        $redBg = $brushConv.ConvertFromString("#F38BA8")
        $darkFg = $brushConv.ConvertFromString("#11111B")
        $borderBrush = $brushConv.ConvertFromString("#EBA0AC")
        $lockCursor = [System.Windows.Input.Cursors]::No
        $lockedTip = "🔒 Prompt dispatch is locked because scripts/blackboard-ui.ps1 was modified on disk. Please click 'Relaunch' before prompting."

        if ($btnCopyKickoffPrompt) {
            $btnCopyKickoffPrompt.Background = $redBg
            $btnCopyKickoffPrompt.Foreground = $darkFg
            $btnCopyKickoffPrompt.BorderBrush = $borderBrush
            $btnCopyKickoffPrompt.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnCopyKickoffPrompt.FontWeight = [System.Windows.FontWeights]::Bold
            $btnCopyKickoffPrompt.Content = "🔒 Copy (Locked)"
            $btnCopyKickoffPrompt.ToolTip = $lockedTip
            $btnCopyKickoffPrompt.Cursor = $lockCursor
        }
        if ($btnSendKickoffPrompt) {
            $btnSendKickoffPrompt.Background = $redBg
            $btnSendKickoffPrompt.Foreground = $darkFg
            $btnSendKickoffPrompt.BorderBrush = $borderBrush
            $btnSendKickoffPrompt.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnSendKickoffPrompt.FontWeight = [System.Windows.FontWeights]::Bold
            $btnSendKickoffPrompt.Content = "🔒 Send (Locked)"
            $btnSendKickoffPrompt.ToolTip = $lockedTip
            $btnSendKickoffPrompt.Cursor = $lockCursor
        }
        if ($btnRepromptCursor) {
            $btnRepromptCursor.Background = $redBg
            $btnRepromptCursor.Foreground = $darkFg
            $btnRepromptCursor.BorderBrush = $borderBrush
            $btnRepromptCursor.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnRepromptCursor.FontWeight = [System.Windows.FontWeights]::Bold
            $btnRepromptCursor.Content = "🔒 $s1 (Locked)"
            $btnRepromptCursor.ToolTip = $lockedTip
            $btnRepromptCursor.Cursor = $lockCursor
        }
        if ($btnRepromptGemini) {
            $btnRepromptGemini.Background = $redBg
            $btnRepromptGemini.Foreground = $darkFg
            $btnRepromptGemini.BorderBrush = $borderBrush
            $btnRepromptGemini.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnRepromptGemini.FontWeight = [System.Windows.FontWeights]::Bold
            $btnRepromptGemini.Content = "🔒 $s2 (Locked)"
            $btnRepromptGemini.ToolTip = $lockedTip
            $btnRepromptGemini.Cursor = $lockCursor
        }
        if ($btnRepromptBoth) {
            $btnRepromptBoth.Background = $redBg
            $btnRepromptBoth.Foreground = $darkFg
            $btnRepromptBoth.BorderBrush = $borderBrush
            $btnRepromptBoth.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnRepromptBoth.FontWeight = [System.Windows.FontWeights]::Bold
            $btnRepromptBoth.Content = "🔒 Both (Locked)"
            $btnRepromptBoth.ToolTip = $lockedTip
            $btnRepromptBoth.Cursor = $lockCursor
        }
        if ($btnCompareNotes) {
            $btnCompareNotes.Background = $redBg
            $btnCompareNotes.Foreground = $darkFg
            $btnCompareNotes.BorderBrush = $borderBrush
            $btnCompareNotes.BorderThickness = New-Object System.Windows.Thickness(2)
            $btnCompareNotes.FontWeight = [System.Windows.FontWeights]::Bold
            $btnCompareNotes.Content = "🔒 Compare (Locked)"
            $btnCompareNotes.ToolTip = $lockedTip
            $btnCompareNotes.Cursor = $lockCursor
        }
    } else {
        $defaultCursor = [System.Windows.Input.Cursors]::Arrow
        $defaultBorder = $brushConv.ConvertFromString("#45475A")
        $darkBg = $brushConv.ConvertFromString("#313244")
        $lightFg = $brushConv.ConvertFromString("#CDD6F4")

        if ($btnCopyKickoffPrompt) {
            $btnCopyKickoffPrompt.Background = $brushConv.ConvertFromString("#89B4FA")
            $btnCopyKickoffPrompt.Foreground = $brushConv.ConvertFromString("#11111B")
            $btnCopyKickoffPrompt.BorderBrush = $defaultBorder
            $btnCopyKickoffPrompt.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnCopyKickoffPrompt.FontWeight = [System.Windows.FontWeights]::Bold
            $btnCopyKickoffPrompt.Content = "📋 Copy Prompt"
            $btnCopyKickoffPrompt.Cursor = $defaultCursor
        }
        if ($btnSendKickoffPrompt) {
            $btnSendKickoffPrompt.Background = $darkBg
            $btnSendKickoffPrompt.Foreground = $lightFg
            $btnSendKickoffPrompt.BorderBrush = $defaultBorder
            $btnSendKickoffPrompt.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnSendKickoffPrompt.FontWeight = [System.Windows.FontWeights]::Normal
            $btnSendKickoffPrompt.Content = "Send (best-effort)"
            $btnSendKickoffPrompt.Cursor = $defaultCursor
        }
        if ($btnRepromptCursor) {
            $btnRepromptCursor.Background = $darkBg
            $btnRepromptCursor.Foreground = $lightFg
            $btnRepromptCursor.BorderBrush = $defaultBorder
            $btnRepromptCursor.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnRepromptCursor.FontWeight = [System.Windows.FontWeights]::Normal
            $btnRepromptCursor.Content = "$s1 (best-effort)"
            $btnRepromptCursor.ToolTip = "Best-effort re-prompt for $s1. Clipboard copy is the reliable handoff."
            $btnRepromptCursor.Cursor = $defaultCursor
        }
        if ($btnRepromptGemini) {
            $btnRepromptGemini.Background = $darkBg
            $btnRepromptGemini.Foreground = $lightFg
            $btnRepromptGemini.BorderBrush = $defaultBorder
            $btnRepromptGemini.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnRepromptGemini.FontWeight = [System.Windows.FontWeights]::Normal
            $btnRepromptGemini.Content = "$s2 (best-effort)"
            $btnRepromptGemini.ToolTip = "Best-effort re-prompt for $s2. Clipboard copy is the reliable handoff."
            $btnRepromptGemini.Cursor = $defaultCursor
        }
        if ($btnRepromptBoth) {
            $btnRepromptBoth.Background = $brushConv.ConvertFromString("#45475A")
            $btnRepromptBoth.Foreground = $brushConv.ConvertFromString("#F9E2AF")
            $btnRepromptBoth.BorderBrush = $defaultBorder
            $btnRepromptBoth.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnRepromptBoth.FontWeight = [System.Windows.FontWeights]::Normal
            $btnRepromptBoth.Content = "Both (best-effort)"
            $btnRepromptBoth.ToolTip = "Best-effort re-prompt for both seats. Clipboard copy is the reliable handoff."
            $btnRepromptBoth.Cursor = $defaultCursor
        }
        if ($btnCompareNotes) {
            $btnCompareNotes.Background = $darkBg
            $btnCompareNotes.Foreground = $brushConv.ConvertFromString("#89B4FA")
            $btnCompareNotes.BorderBrush = $defaultBorder
            $btnCompareNotes.BorderThickness = New-Object System.Windows.Thickness(1)
            $btnCompareNotes.FontWeight = [System.Windows.FontWeights]::SemiBold
            $btnCompareNotes.Content = "⚖️ Compare Notes"
            $btnCompareNotes.ToolTip = "Send a compare-notes re-prompt to both agents without replacing Objective or Alignment"
            $btnCompareNotes.Cursor = $defaultCursor
        }
        Update-KickoffButtonTooltips
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
    
    if (-not $script:DiskScriptIsNewer) {
        if ($btnRepromptCursor) { $btnRepromptCursor.Content = $s1 }
        if ($btnRepromptGemini) { $btnRepromptGemini.Content = $s2 }
    }
    
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
        Save-LastOpenedRepo -repoPath $script:RepoRoot

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
    if (-not $force) {
        if ($script:FormDirty) {
            $res = [System.Windows.MessageBox]::Show(
                "The form has unsaved edits. Reload from disk and discard those edits?",
                "Refresh from disk",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($res -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }
    }
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

function Update-PhaseSelectionLock {
    if ($cbPhase) {
        $locked = ($chkAutoStep -and $chkAutoStep.IsChecked)
        $cbPhase.IsEnabled = -not $locked
    }
}

if ($chkAutoStep) {
    $initialAutoStep = if ($script:ClientConfig -and $null -ne $script:ClientConfig.autoStep) { [bool]$script:ClientConfig.autoStep } else { $false }
    $chkAutoStep.IsChecked = $initialAutoStep
    $chkAutoStep.add_Checked({
        Save-ClientConfiguration
        $txtStatus.Text = "Auto step on. Gated sign-offs advance one enabled phase badge. Manual phase selection is off."
        Update-PhaseSelectionLock
        Check-PhaseAutoAdvance
    })
    $chkAutoStep.add_Unchecked({
        Save-ClientConfiguration
        $txtStatus.Text = "Auto step off. You can change the phase."
        Update-PhaseSelectionLock
    })
    Update-PhaseSelectionLock
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
    foreach ($m in [regex]::Matches($text, '(\*\*[^*]+\*\*|`[^`]+`|\b(?:CUR|ANT|HUM)\d+\b)')) {
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
        } elseif ($tok.StartsWith('`')) {
            $r = New-Object System.Windows.Documents.Run ($tok.Substring(1, $tok.Length - 2))
            $r.Foreground = $brushCode
            $r.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
        } else {
            $r = New-Object System.Windows.Documents.Run ($tok)
            $r.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
            $r.FontWeight = [System.Windows.FontWeights]::Bold
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
        $selected = if ($txtHumanNotes -and $txtHumanNotes.SelectionLength -gt 0) { $txtHumanNotes.SelectedText.Trim() } else { "" }
        $rawNotes = if ($selected) { $selected } else { if ($txtHumanNotes) { $txtHumanNotes.Text.Trim() } else { "" } }
        if ([string]::IsNullOrWhiteSpace($rawNotes) -or $rawNotes -eq "- Active steering notes.") {
            [System.Windows.MessageBox]::Show("Human Notes are empty or default. Enter steering notes first.", "Promote Notes", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
        $confirm = [System.Windows.MessageBox]::Show("Promote Human Notes to Current Objective & Prompt?`n`n[Notes Preview]:`n$rawNotes`n`nNote: This will append to the Prompt field and mark blackboard dirty. It will not auto-send or create an issue.", "Confirm Promote Notes", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $clean = $rawNotes -replace '^(?:-\s*|\*\s*)', ''
            $joined = Join-TextWithSeparator -existing $txtPrompt.Text -addition $clean
            $txtPrompt.Text = $joined
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
$script:RelaunchFlashToggle = $false

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
    $pair = switch ($phaseName.Trim().ToLower()) {
        "ready"     { "idle","idle" }
        "pitch"     { "advise","advise" }
        "discuss"   { "advise","advise" }
        "advise"    { "advise","advise" }
        "plan"      { "plan","idle" }
        "implement" { "implement","review" }
        "review"    { "review","review" }
        "test"      { "review","review" }
        "closing"   { "idle","idle" }
        "debrief"   { "advise","advise" }
        "reconcile" { "advise","advise" }
        "closed"    { "idle","idle" }
        default     { $null }
    }
    if (-not $pair) { return }
    if (-not (Test-RoleNone $cbCursorRole.Text)) { Set-ComboToRole $cbCursorRole $pair[0] }
    if (-not (Test-RoleNone $cbGeminiRole.Text)) { Set-ComboToRole $cbGeminiRole $pair[1] }
    if ((Get-NormalizedRole $cbCursorRole.Text) -eq "implement" -and (Get-NormalizedRole $cbGeminiRole.Text) -eq "implement") {
        Set-ComboToRole $cbGeminiRole "review"
    }
}

function Set-Phase {
    param([string]$targetPhase)
    if ([string]::IsNullOrWhiteSpace($targetPhase)) { return }
    $script:SuppressRoleDefault = $true
    try {
        $tgt = $targetPhase.Trim().ToLower()
        if ($tgt -in @("pitch", "discuss", "implement", "test")) {
            $script:ClosingSignoffsCompleted = $false
        }
        for ($i = 0; $i -lt $cbPhase.Items.Count; $i++) {
            $itemText = [string]$cbPhase.Items[$i].Content
            $token = ($itemText -split " ")[0].ToLower()
            if ($token -eq $tgt -or ($tgt -eq "advise" -and $token -eq "discuss") -or ($tgt -eq "discuss" -and $token -eq "advise")) {
                $cbPhase.SelectedIndex = $i
                Sync-PresetFromPhase $tgt
                return
            }
        }
    } finally {
        $script:SuppressRoleDefault = $false
    }
}

function Get-NextPhase {
    param([string]$currentPhase)
    $ladder = @("pitch","discuss","plan","implement","review","test","closing","debrief","ready")
    $cur = $currentPhase.ToLower()
    if ($cur -eq "advise") { $cur = "discuss" }
    if ($cur -eq "closed") { $cur = "ready" }
    if ($cur -eq "reconcile") {
        $back = [string]$script:PhaseBeforeReconcile
        if ($back) { return $back.ToLower() }
        return "discuss"
    }
    $start = [array]::IndexOf($ladder, $cur)
    if ($start -lt 0) { $start = -1 }
    for ($step = 1; $step -le $ladder.Count; $step++) {
        $candidate = $ladder[($start + $step) % $ladder.Count]
        if ($candidate -eq "ready" -or $script:EnabledPhases -contains $candidate) { return $candidate }
    }
    return "ready"
}

function Test-RoleNone {
    param([string]$role)
    return (Get-NormalizedRole $role) -eq "none"
}

function Test-SeatRequired {
    param(
        $roleCombo,
        [string]$clientName,
        $gate
    )
    if ($roleCombo -and (Test-RoleNone $roleCombo.Text)) { return $false }
    if ($clientName -eq "None") { return $false }
    if ($gate -and -not $gate.IsChecked) { return $false }
    return $true
}

function Test-RequiredSignoffsMet {
    $seat1 = Get-Seat1Client
    $seat2 = Get-Seat2Client
    $need1 = Test-SeatRequired $cbCursorRole $seat1 $chkGateSeat1
    $need2 = Test-SeatRequired $cbGeminiRole $seat2 $chkGateSeat2
    if ($chkSignHuman -and -not $chkSignHuman.IsChecked) { return $false }
    if ($need1 -and $chkSignCursor -and -not $chkSignCursor.IsChecked) { return $false }
    if ($need2 -and $chkSignGemini -and -not $chkSignGemini.IsChecked) { return $false }
    return $true
}

function Update-BugsVisibility {
    if (-not $txtBugs) { return }
    $txtBugs.Visibility = [System.Windows.Visibility]::Visible
}

function Update-PanelVisibility {
    if ($borderObjective -and $chkShowObjective) { $borderObjective.Visibility = if ($chkShowObjective.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($borderAlignment -and $chkShowAlignment) { $borderAlignment.Visibility = if ($chkShowAlignment.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($borderNotes -and $chkShowNotes) { $borderNotes.Visibility = if ($chkShowNotes.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    if ($gridResponses -and $chkShowResponses) { $gridResponses.Visibility = if ($chkShowResponses.IsChecked) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
}

function Add-SeatStat {
    param([string]$seat, [string]$field, [int]$amount = 1)
    if ([string]::IsNullOrWhiteSpace($seat) -or $seat -eq "None") { return }
    $path = Join-Path $script:UserConfigDir "stats.json"
    $stats = [PSCustomObject]@{}
    if (Test-Path $path) {
        try { $stats = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $stats = [PSCustomObject]@{} }
    }
    if (-not $stats.PSObject.Properties[$seat]) {
        $stats | Add-Member -NotePropertyName $seat -NotePropertyValue ([PSCustomObject]@{ runs = 0; reviewCatches = 0; linesAdded = 0; linesRemoved = 0; promptsCopied = 0 }) -Force
    }
    $row = $stats.$seat
    $current = 0
    if ($row.PSObject.Properties[$field]) { $current = [int]$row.$field }
    $row | Add-Member -NotePropertyName $field -NotePropertyValue ($current + $amount) -Force
    if (-not (Test-Path $script:UserConfigDir)) { New-Item -ItemType Directory -Force -Path $script:UserConfigDir | Out-Null }
    [System.IO.File]::WriteAllText($path, ($stats | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
}

function Test-UnsafeObjective {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    if ($text -match '(?i)secret|password|private key|drop table|format c:|rm -rf /') {
        if ($txtStatus) { $txtStatus.Text = "Safety: this objective mentions secrets or a destructive command. Keep secrets out of the board and out of git. You still decide." }
    }
}

function Check-PhaseAutoAdvance {
    if ($script:SuppressPhaseAutoAdvance) { return }
    if ($chkAutoStep -and -not $chkAutoStep.IsChecked) { return }
    $flow = Get-FlowControlString
    if ($flow -match "STOP|PAUSE") { return }

    if ($script:PhaseAdvanceGateLatched) { return }

    if (-not (Test-RequiredSignoffsMet)) {
        return
    }

    if ($script:LastAutoAdvanceTime -and ([DateTime]::UtcNow - $script:LastAutoAdvanceTime).TotalSeconds -lt 3) {
        return
    }

    $currentPhase = Get-PhaseString
    if ($currentPhase -eq "ready" -or $currentPhase -eq "closed") { return }

    $nextPhase = Get-NextPhase $currentPhase
    if ($nextPhase -eq $currentPhase) { return }

    if ($currentPhase -eq "closing") {
        $script:ClosingSignoffsCompleted = $true
        $askClose = [System.Windows.MessageBox]::Show(
            "All 3 sign-offs complete for Closing.`n`nShip project code now (run git audit, commit, push) and proceed to Debrief?`n`nClick 'Yes' to Ship code and advance to Debrief.`nClick 'No' to advance to Debrief without shipping yet.",
            "Ship Code and Advance to Debrief",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($askClose -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-CloseProjectGitShip -allSigned $true
        }
    }

    if ($currentPhase -eq "debrief") {
        $askClose = [System.Windows.MessageBox]::Show(
            "Debrief complete with all 3 sign-offs.`n`nClose Project now (run git audit, commit, push, archive, and open ready)?`n`nClick 'Yes' to Close and Ship project now.`nClick 'No' to arm New Chat and move to ready.",
            "Close Project or Advance to Ready",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($askClose -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-CloseProjectWorkflow -promptConfirm $false
            return
        }
    }

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
        if ($nextPhase -eq "ready") {
            $implSeat = if ($cbCursorRole -and $cbCursorRole.Text -eq "implement") { Get-Seat1Client } elseif ($cbGeminiRole -and $cbGeminiRole.Text -eq "implement") { Get-Seat2Client } else { "Human" }
            Add-SeatStat -seat $implSeat -field "runs"
            $num = @(git -C $script:RepoRoot diff --numstat HEAD 2>$null)
            $added = 0; $removed = 0
            foreach ($row in $num) {
                if ($row -match '^(\d+)\s+(\d+)\s+') { $added += [int]$Matches[1]; $removed += [int]$Matches[2] }
            }
            if ($added -gt 0) { Add-SeatStat -seat $implSeat -field "linesAdded" -amount $added }
            if ($removed -gt 0) { Add-SeatStat -seat $implSeat -field "linesRemoved" -amount $removed }
        }

        if ($currentPhase -eq "debrief" -and $nextPhase -eq "ready") {
            $targetTag = if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) { [string]$cbKickoffTarget.SelectedItem.Tag } else { "Both" }
            $isCodex = ($targetTag -eq "Both" -and ($s1 -eq "Codex" -or $s2 -eq "Codex")) -or `
                       ($targetTag -eq "Seat1" -and $s1 -eq "Codex") -or `
                       ($targetTag -eq "Seat2" -and $s2 -eq "Codex")
            if ($chkNewChatKickoff -and -not $isCodex) {
                $chkNewChatKickoff.IsChecked = $true
            }
            Update-KickoffButtonTooltips
        }

        $txtStatus.Text = "Phase auto-advanced: $currentPhase -> $nextPhase (required sign-offs complete)."
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
        $script:UnsignedRollbackStreak++
        if ($cbCursorRole -and $cbCursorRole.Text -eq "review") { Add-SeatStat -seat (Get-Seat1Client) -field "reviewCatches" }
        if ($cbGeminiRole -and $cbGeminiRole.Text -eq "review") { Add-SeatStat -seat (Get-Seat2Client) -field "reviewCatches" }
        if ($txtStatus) { $txtStatus.Text = "Auto step: an AI $phaseNow turn has no Sign-off [x]. Phase badge returned to implement. Roles were left as assigned. Streak $($script:UnsignedRollbackStreak)." }
        if ($script:UnsignedRollbackStreak -ge 3) {
            $swapAsk = [System.Windows.MessageBox]::Show(
                "This run has rolled back from test or closing 3 times without a sign-off.`n`nSwap the implement seat to the other AI?",
                "Swap implement seat?",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question,
                [System.Windows.MessageBoxResult]::No
            )
            $script:UnsignedRollbackStreak = 0
            if ($swapAsk -eq [System.Windows.MessageBoxResult]::Yes -and $cbCursorRole -and $cbGeminiRole) {
                $role1 = [string]$cbCursorRole.Text
                $role2 = [string]$cbGeminiRole.Text
                Set-ComboToRole $cbCursorRole $role2
                Set-ComboToRole $cbGeminiRole $role1
                if ($txtStatus) { $txtStatus.Text = "Implement seat swap confirmed by the operator." }
            }
        }
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
    if ((Test-RequiredSignoffsMet) -and ($phaseNow -eq "closing" -or $phaseNow -eq "debrief" -or $phaseNow -eq "ready" -or $phaseNow -eq "closed")) {
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
        $isSignedOrCompleted = ($chkSignHuman.IsChecked -and $chkSignCursor.IsChecked -and $chkSignGemini.IsChecked) -or ($script:ClosingSignoffsCompleted -and ($phaseForClose -eq "debrief" -or $phaseForClose -eq "ready"))
        if (($phaseForClose -eq "closing" -or $phaseForClose -eq "debrief" -or $phaseForClose -eq "ready" -or $phaseForClose -eq "closed") -and $isSignedOrCompleted) {
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
    } elseif ($script:LastCodexTargeted) {
        $txtSafetyWarning.Text = "⚠️ New Chat unavailable for Codex: manually open a new chat in the Codex app."
        $txtSafetyWarning.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
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

$cbCursorRole.add_SelectionChanged({
    if (Test-RoleNone $cbCursorRole.Text) {
        if ($chkSignCursor) { $chkSignCursor.IsChecked = $false }
        if ($chkGateSeat1) { $chkGateSeat1.IsChecked = $false }
    }
    Check-Safety
    Mark-FormDirty
})
$cbGeminiRole.add_SelectionChanged({
    if (Test-RoleNone $cbGeminiRole.Text) {
        if ($chkSignGemini) { $chkSignGemini.IsChecked = $false }
        if ($chkGateSeat2) { $chkGateSeat2.IsChecked = $false }
    }
    Check-Safety
    Mark-FormDirty
})
function Clear-SignoffBoxesForPhaseChange {
    $script:SuppressPhaseAutoAdvance = $true
    $script:SuppressAutoAdvanceLatchReset = $true
    $script:SuppressFormDirty = $true
    try {
        if ($chkSignHuman) { $chkSignHuman.IsChecked = $false }
        if ($chkSignCursor) { $chkSignCursor.IsChecked = $false }
        if ($chkSignGemini) { $chkSignGemini.IsChecked = $false }
        if (Test-Path $script:BlackboardPath) {
            $raw = [System.IO.File]::ReadAllText($script:BlackboardPath, [System.Text.Encoding]::UTF8)
            $s1 = Get-Seat1Client
            $s2 = Get-Seat2Client
            $s1Esc = [regex]::Escape($s1)
            $s2Esc = [regex]::Escape($s2)
            $cPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s1Esc|Cursor|Agent\s*1)(?:\s+Scratchpad)?"
            $gPad = Get-LastMarkdownBody $raw "(?:###|##)\s+(?:$s2Esc|Gemini(?:\s+\(Antigravity\))?|Agent\s*2)(?:\s+Scratchpad)?"
            $script:CursorPadAtPhaseChange = if ($cPad) { ($cPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
            $script:GeminiPadAtPhaseChange = if ($gPad) { ($gPad -replace '\r\n', "`n" -replace '\r', "`n").Trim() } else { "" }
            Save-SignoffBaseline
        }
        Save-BlackboardContent
    } finally {
        $script:SuppressPhaseAutoAdvance = $false
        $script:SuppressAutoAdvanceLatchReset = $false
        $script:SuppressFormDirty = $false
    }
}

$cbPhase.add_SelectionChanged({
    if (-not $script:SuppressPresetSync) {
        Sync-PresetFromPhase (Get-PhaseString)
    }
    if (-not $script:SuppressRoleDefault -and $chkAutoStep -and -not $chkAutoStep.IsChecked) {
        Set-RolesForPhase (Get-PhaseString)
    }
    if (-not $script:SuppressAutoAdvanceLatchReset) {
        $script:PhaseAdvanceGateLatched = $false
        $script:PhaseAdvanceUncheckObserved = $false
    }
    Ensure-PitchSeatsAdvise
    if (-not $script:SuppressPhaseAutoAdvance -and -not $script:SuppressFormDirty) {
        Clear-SignoffBoxesForPhaseChange
    }
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
$txtPrompt.add_TextChanged({ Mark-FormDirty; Test-UnsafeObjective $txtPrompt.Text })
if ($txtBugs) { $txtBugs.add_TextChanged({ Update-BugsVisibility; Mark-FormDirty; Enter-ReconcilePhase }) }
foreach ($hide in @($chkShowObjective, $chkShowAlignment, $chkShowNotes, $chkShowResponses)) {
    if ($hide) { $hide.add_Click({ Update-PanelVisibility }) }
}
Update-PanelVisibility
Update-BugsVisibility
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

function Test-CloseProjectDeniedPath {
    param([string]$relPath)
    $n = ($relPath -replace '\\', '/').Trim().Trim('"')
    if ($n -match '(^|/)\.env($|\.)' -or $n -match '\.pem$' -or $n -match '(?i)secret|credential') { return $true }
    if ($n -match '(^|/)\.ai/') { return $true }
    return $false
}

function Get-CloseAllowPatterns {
    $allowFile = Join-Path $script:AiDir "close-allow.json"
    if (-not (Test-Path -LiteralPath $allowFile)) { return $null }
    try {
        $json = Get-Content -LiteralPath $allowFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json -and $json.paths) { return @($json.paths | Where-Object { $_ }) }
    } catch {}
    return $null
}

function Test-CloseProjectAllowedPath {
    param([string]$relPath)
    $n = ($relPath -replace '\\', '/').Trim().Trim('"')
    if (Test-CloseProjectDeniedPath $n) { return $false }
    $patterns = Get-CloseAllowPatterns
    if ($null -eq $patterns -or $patterns.Count -eq 0) { return $true }
    foreach ($pattern in $patterns) {
        $p = ([string]$pattern) -replace '\\', '/'
        if ($n -like $p) { return $true }
    }
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
    if (Test-SameFullPath $script:RepoRoot $script:ControllerRoot) {
        $selfAsk = [System.Windows.MessageBox]::Show(
            "The active git root is the controller repo itself:`n$script:RepoRoot`n`nClose Project will commit and push that repo. Continue only if this session is about the controller.",
            "Controller repo is the git target",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($selfAsk -ne [System.Windows.MessageBoxResult]::Yes) {
            $txtStatus.Text = "Close Project git ship cancelled. Browse to the target repo board first."
            return
        }
    }
    $audit = Get-CloseProjectGitAudit
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("Git audit before Close Project ($script:AppVersion):")
    [void]$lines.Add("Repo: $script:RepoRoot")
    if ($audit.Allowed.Count -gt 0) { [void]$lines.Add("Tracked dirty (can commit):`n  " + ($audit.Allowed -join "`n  ")) } else { [void]$lines.Add("Tracked dirty: none") }
    if ($audit.Blocked.Count -gt 0) { [void]$lines.Add("Refused (secrets, .ai, or outside optional close-allow.json):`n  " + ($audit.Blocked -join "`n  ")) }
    if ($audit.Untracked.Count -gt 0) { [void]$lines.Add("Untracked (will NOT auto-add):`n  " + ($audit.Untracked -join "`n  ")) }
    [void]$lines.Add("")
    if ($audit.Allowed.Count -gt 0) {
        [void]$lines.Add("Commit these tracked files now?")
        $commitAsk = [System.Windows.MessageBox]::Show(($lines -join "`n"), "Close Project git audit", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($commitAsk -eq [System.Windows.MessageBoxResult]::Yes) {
        foreach ($p in $audit.Allowed) {
            git -C $script:RepoRoot add -- $p
        }
        $issueHint = $txtIssueNum.Text.Trim()
        $msg = if ($issueHint -and $issueHint -ne "none") {
            "docs: ship on Close Project (Refs #$issueHint)"
        } else {
            "docs: ship on Close Project"
        }
        git -C $script:RepoRoot commit -m $msg
        if ($LASTEXITCODE -ne 0) {
            $txtStatus.Text = "Warning: git commit on Close Project failed (exit $LASTEXITCODE)."
        }
        }
    }
    if ($audit.Blocked.Count -gt 0) {
        [System.Windows.MessageBox]::Show("Push skipped. Refused dirty paths are still in the working tree:`n`n" + ($audit.Blocked -join "`n"), "Close Project push skipped", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        $txtStatus.Text = "Push skipped: refused dirty paths remain."
        return
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

function Invoke-CloseProjectWorkflow {
    param(
        [bool]$promptConfirm = $true
    )
    $signHuman = if ($chkSignHuman) { [bool]$chkSignHuman.IsChecked } else { $false }
    $signCursor = if ($chkSignCursor) { [bool]$chkSignCursor.IsChecked } else { $false }
    $signGemini = if ($chkSignGemini) { [bool]$chkSignGemini.IsChecked } else { $false }
    $allSigned = ($signHuman -and $signCursor -and $signGemini) -or $script:ClosingSignoffsCompleted
    $phaseNow = Get-PhaseString

    if ($promptConfirm) {
        if ($phaseNow -ne "test" -and $phaseNow -ne "closing" -and $phaseNow -ne "debrief" -and $phaseNow -ne "ready" -and $phaseNow -ne "closed") {
            $testWarn = [System.Windows.MessageBox]::Show(
                "Project phase is '$phaseNow' (not test). For programs/scripts, sign-off should follow the test phase.`n`nClose anyway?",
                "Testing phase not reached",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($testWarn -ne [System.Windows.MessageBoxResult]::Yes) {
                return $false
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
            return $false
        }
    }

    $s1 = Get-Seat1Client
    $s2 = Get-Seat2Client
    Invoke-CloseProjectGitShip -allSigned ([bool]$allSigned)

    $num = if ($txtIssueNum) { $txtIssueNum.Text.Trim() } else { "" }
    if ($num -and $num -ne "none") {
        $closeIssuePrompt = [System.Windows.MessageBox]::Show("Linked GitHub Issue #$num detected.`n`nClose Issue #$num on GitHub via gh CLI?", "Close GitHub Issue #$num", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($closeIssuePrompt -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                if ($txtStatus) { $txtStatus.Text = "Closing issue #$num via gh CLI..." }
                $targetRepo = Get-TargetGitHubRepo
                $closeArgs = @("issue", "close", $num, "--comment", "Completed with sign-offs from Human, $s1, and $s2.")
                if ($targetRepo) { $closeArgs += @("--repo", $targetRepo) }
                & gh @closeArgs
                if ($txtStatus) { $txtStatus.Text = "Closed GitHub Issue #$num." }
            } catch {
                if ($txtStatus) { $txtStatus.Text = "Warning: Failed to close issue #$num via gh: $_" }
            }
        }
    }

    # Derive slug for archive
    $slug = "closed"
    if ($num -and $num -ne "none") {
        $slug += "-issue$num"
    } else {
        $firstLine = if ($txtPrompt) { ($txtPrompt.Text -split "\r?\n")[0].Trim() } else { "" }
        if ($firstLine) {
            $short = ($firstLine -replace '[^a-zA-Z0-9]', '-').Trim('-')
            if ($short.Length -gt 25) { $short = $short.Substring(0, 25).Trim('-') }
            if ($short) { $slug += "-$short" }
        }
    }

    Auto-ArchiveSnapshot -customLabel $slug
    Clear-FormInMemory
    $script:ClosingSignoffsCompleted = $false
    if ($chkNewChatKickoff) {
        $targetTag = if ($cbKickoffTarget -and $cbKickoffTarget.SelectedItem) { [string]$cbKickoffTarget.SelectedItem.Tag } else { "Both" }
        $isCodex = ($targetTag -eq "Both" -and ($s1 -eq "Codex" -or $s2 -eq "Codex")) -or `
                   ($targetTag -eq "Seat1" -and $s1 -eq "Codex") -or `
                   ($targetTag -eq "Seat2" -and $s2 -eq "Codex")
        if (-not $isCodex) {
            $chkNewChatKickoff.IsChecked = $true
        }
    }
    Update-KickoffButtonTooltips
    Set-Phase "ready"
    if ($rbGo) { $rbGo.IsChecked = $true }
    Save-BlackboardContent -clearScratchpads
    if ($txtStatus) { $txtStatus.Text = "Project closed & archived to .ai/history. Controller reset to ready state. New Chat armed for next project." }
    return $true
}

function Get-RoleGuidance {
    param([string]$role)
    $boardPath = $script:BlackboardPath
    $phase = Get-PhaseString
    if ($phase -eq "ready" -or $phase -eq "closed") {
        return "This project/objective is READY. All sign-offs complete. Hold IDLE. Do not modify files or execute tasks unless a new active objective is assigned."
    }
    if ($phase -eq "debrief") {
        return "Project phase is DEBRIEF. Answer these four items for this run: Did we complete the mission? Give a short grade for yourself and for the other occupied seat. What would you do differently? Give one suggestion covering the process, the work, and the rules. Do not modify tracked files. Sign off after the Human Lead."
    }
    if ($phase -eq "reconcile") {
        return "Project phase is RECONCILE. The human advances one occupied seat at a time. The seat that disagreed goes first and states why. Each occupied seat has five turns, not five shared. If it is still open after those turns, the human makes the call. Reconcile ends when every occupied seat and the human have signed off. Do not modify tracked files."
    }
    if ($phase -eq "review") {
        return "Project phase is REVIEW. Read the implementer's notes and diff. On this first review pass, write each UI control to the board, read that markdown back into the control, and compare them before sign-off. A parse-only check does not pass review. FORBIDDEN: editing the same tracked files the implementer is changing. GO does not make you implement."
    }
    if ($phase -eq "closing") {
        return "Project phase is CLOSING. Your role is idle. Do not edit tracked files or start new work. Your one action is the final sign-off: write Sign-off: [x] on your top scratchpad bullet and mark your Agent Roles row [x] so the project can advance to debrief."
    }
    if ($phase -eq "test") {
        return "Project phase is TEST. Run scripts/blackboard-ui-test.ps1. It uses a hidden window and does not attach to the already-open controller. Record its PASS or FAIL in your scratchpad. Do not start a second interactive controller. FORBIDDEN: new features. After a recorded pass (or N/A with why), set your Agent Roles Sign-off [x] and scratchpad Sign-off: [x]. GO does not mean implement."
    }
    if ($phase -eq "discuss") {
        return "You hold ADVISE. The first discuss note includes one turn-parameter table with columns parameter, value, and who decided. Reconcile turns are five per occupied seat, not five shared. The other seat edits a cell or answers Agree. End your note with `- **Agreed**: <decision>` sentences, or a single `- **Agree** if the other agent's scratchpad is already right. FORBIDDEN: editing tracked repo files."
    }
    if ($phase -eq "pitch") {
        return "Project phase is PITCH. Suggest additions, improvements, updates, fixes, or alternatives to whatever is listed in the current objective. Human has the final say on what moves on to discussion. FORBIDDEN: editing tracked files, git operations. Propose options with trade-offs in your scratchpad. End your note with your proposals and phase sign-off when aligned."
    }
    switch (Get-NormalizedRole $role) {
        "implement" {
            $modeNote = ""
            if ($cbImplementMode -and $cbImplementMode.SelectedItem -and [string]$cbImplementMode.SelectedItem.Content -match 'Issue') {
                $modeNote = " Implement mode is Submit GitHub Issues. File GitHub issues only. Do not edit tracked files."
            }
            "You hold IMPLEMENT. Before the first code edit, copy the current build into .ai/saved/ and write that path on the board. That copy is not a git commit. Review objective and Alignment in '$boardPath', then land the change. Append progress under your scratchpad heading only. Do not edit the other agent's scratchpad or the Human Lead's notes.$modeNote"
        }
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
    if ((Get-PhaseString) -eq "ready" -or (Get-PhaseString) -eq "closed") {
        return @"
NOTICE: Project phase is READY. Awaiting new objective.
Hold IDLE. Do not modify files, execute tasks, or make commits unless the Human Lead assigns a new active objective.

"@
    }
    if ((Get-PhaseString) -eq "debrief") {
        return @"
NOTICE: Project phase is DEBRIEF.
Answer these four items: Did we complete the mission? Grade yourself and the other occupied seat. What would you do differently? One suggestion for the process, the work, and the rules. Do not modify tracked files or make commits. Sign off after the Human Lead.

"@
    }
    if ((Get-PhaseString) -eq "reconcile") {
        return @"
NOTICE: Project phase is RECONCILE.
The human advances one occupied seat at a time. The seat that disagreed goes first. Each occupied seat has five turns. If it stays open, the human makes the call. Sign off when your part is done. Do not modify tracked files.

"@
    }
    if ((Get-PhaseString) -eq "closing") {
        return @"
NOTICE: Project phase is CLOSING. Both seats are idle.
Do not edit tracked files or start new work. Your one action is the final sign-off so the project can advance to debrief.

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
    if ($phase -eq "ready" -or $phase -eq "closed") { return "" }
    if ($phase -eq "debrief") {
        return @"

Debrief Sign-off:
- Answer the four debrief questions in your scratchpad.
- Once the Human Lead signs off, add 'Sign-off: [x]' on your top bullet and mark your row '[x]' in Agent Roles.
"@
    }
    if ($phase -eq "reconcile") {
        return @"

Reconcile Sign-off:
- Each occupied seat has five turns. The human advances one seat at a time.
- When your part is done, add 'Sign-off: [x]' on your top bullet and mark your row '[x]'.
- Reconcile ends when every occupied seat and the human have signed off. A none seat is skipped.
"@
    }
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

    $alignBlock = Get-AlignmentBlock
    $roleGuidance = Get-RoleGuidance $normRole
    $signOffGuidance = Get-SignOffGuidance
    if ($normRole -eq "idle" -or $phase -eq "closing") {
        return @"
You hold IDLE on $script:ProjectName$issueText.
Phase: $phase. Flow: $flow.
Read $boardPath. Do not act and do not edit files.
"@
    }
    $writeRule = "Edit only your own scratchpad section on $boardPath. Do not overwrite the file or edit the other seat. Reply on the board, not only in chat."
    return @"
Read $boardPath. Follow the blackboard skill. Open one other project skill only when this objective matches it. Do not paste skill bodies into chat.
- Agent: $agentName
- Assigned Role: $normRole
- Project Phase: $phase
- Flow Control: $flow
- Canonical Blackboard: $boardPath

Current Objective:
$objective
$alignBlock

$roleGuidance
$signOffGuidance
$writeRule
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
    $boardPath = $script:BlackboardPath
    $leadDirective = if ($customDirective) {
        $customDirective
    } elseif ($phase -eq "pitch") {
        "Read $boardPath again. Pitch suggestions, improvements, updates, or alternative approaches to the current objective in your scratchpad. Human Lead decides what graduates to discussion."
    } elseif ($normRole -eq "advise" -or $phase -eq "advise" -or $phase -eq "discuss") {
        "Read $boardPath again and respond to the latest notes from the other agent or the Human Lead. End your note with `- **Agreed**: <decision>` sentences, or a single `- **Agree**` if the other agent's scratchpad is already right, so consensus auto-promotes to Alignment."
    } else {
        "Read $boardPath again and respond to the latest notes from the other agent or the Human Lead."
    }
    if ($normRole -eq "idle" -or $phase -eq "closing") {
        return "IDLE. Phase: $phase. Read $boardPath. Do not act and do not edit files."
    }
    return @"
$leadDirective
Stay in role $normRole. Phase: $phase. Flow: $flow.
Read $boardPath again. Do not paste the scratchpad into chat.
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
        if ($lines[$i] -match '^[-*]\s+(?!\*\*Agreed\*\*)') { $start = $i; break }
    }
    if ($start -lt 0) { return $pad.Trim() }
    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^[-*]\s+(?!\*\*Agreed\*\*)') { $end = $j; break }
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
    # Automatic relaunch timer removed in v1.2.36 in favor of prompt button lockout.
    return $false
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
    # Do not treat every "- **title**" bullet as a turn. That cut the pane to one line
    # whenever a note used bold labels (SUG-01, Agree, Accept). Split only on Role/Phase headers.

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
    $cText = if ($cursorPad) { Get-ScratchpadExcerpt $cursorPad -PreferRole $cRole -maxLines 120 -maxChars 12000 } else { "(no $s1 scratchpad yet)" }
    $gText = if ($geminiPad) { Get-ScratchpadExcerpt $geminiPad -PreferRole $gRole -maxLines 120 -maxChars 12000 } else { "(no $s2 scratchpad yet)" }
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
    if (Test-RoleNone $cbCursorRole.Text) {
        if ($chkSignCursor) { $chkSignCursor.IsChecked = $false }
        if ($chkGateSeat1) { $chkGateSeat1.IsChecked = $false }
    } else {
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
    } elseif (-not [string]::IsNullOrWhiteSpace($cPad) -and -not $cPadSign) {
        $chkSignCursor.IsChecked = $false
    } elseif ($cCleared) {
        $chkSignCursor.IsChecked = $false
    } elseif ($cTable) {
        $chkSignCursor.IsChecked = $true
    }
    }
    
    # 1. Human (Lead): role table is the saved box
    if ($raw -match '(?m)\|\s*\*\*([^*]+)\*\*\s*\|\s*`lead`\s*\|\s*Active\s*\|\s*\[\s\]') {
        $chkSignHuman.IsChecked = $false
    } elseif ($raw -match '(?m)\|\s*\*\*([^*]+)\*\*\s*\|\s*`lead`\s*\|\s*Active\s*\|\s*\[x\]') {
        $chkSignHuman.IsChecked = $true
    }

    # 3. Seat 2: a new latest Sign-off: [x] checks the box. The note from the last advance does not.
    if (Test-RoleNone $cbGeminiRole.Text) {
        if ($chkSignGemini) { $chkSignGemini.IsChecked = $false }
        if ($chkGateSeat2) { $chkGateSeat2.IsChecked = $false }
    } else {
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
    } elseif (-not [string]::IsNullOrWhiteSpace($gPad) -and -not $gPadSign) {
        $chkSignGemini.IsChecked = $false
    } elseif ($gCleared) {
        $chkSignGemini.IsChecked = $false
    } elseif ($gTable) {
        $chkSignGemini.IsChecked = $true
    }
    }
}

function Get-ImplementModeString {
    if ($cbImplementMode -and $cbImplementMode.SelectedItem) { return [string]$cbImplementMode.SelectedItem.Content }
    return "Code"
}

function Remove-AlignmentIndexPrefix {
    param([string]$body)
    $body = $body.Trim()
    for ($i = 0; $i -lt 8; $i++) {
        if ($body -match '(?s)^\s*\[(?:AG|DEC)-\d+\]\s*(.*)$') {
            $body = $Matches[1].Trim()
            continue
        }
        if ($body -match '(?s)^\s*\[A(\d+)\]\s*(.*)$') {
            $num = [int]$Matches[1]
            $rest = $Matches[2].Trim()
            $seatToken = ($num -eq 1 -or $num -eq 2) -and ($rest -match '(?is)^(is Cursor|is Antigravity|seat id)')
            if ($seatToken) { break }
            $body = $rest
            continue
        }
        break
    }
    return $body.Trim()
}

function Get-AlignmentWords {
    param([string]$body)
    $t = $body.ToLowerInvariant() -replace '[^\p{L}\p{N}]+', ' '
    $t = $t -replace '\s+', ' '
    return @($t.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.Length -gt 3 })
}

function Test-AlignmentRepeat {
    param([string]$earlier, [string]$later)
    $a = @(Get-AlignmentWords $earlier)
    $b = @(Get-AlignmentWords $later)
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $false }
    $setA = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $setB = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $a) { [void]$setA.Add($w) }
    foreach ($w in $b) { [void]$setB.Add($w) }
    $inter = 0
    foreach ($w in $setA) { if ($setB.Contains($w)) { $inter++ } }
    $union = $setA.Count + $setB.Count - $inter
    if ($union -gt 0 -and (($inter / $union) -ge 0.38)) { return $true }
    $e = $earlier.ToLowerInvariant()
    $l = $later.ToLowerInvariant()
    if ($e -match 'until promote' -and $l -match 'auto-promot') { return $true }
    if ($e -match 'five turns total' -and $l -match 'not five turns shared') { return $true }
    if ($e -match 'halt phase' -and $l -match 'reconcile') { return $true }
    if ($e -match '5-turn' -and $l -match 'five turns') { return $true }
    if ($e -match '\bcur-?\d+' -and $e -match '\bant-?\d+' -and $l -match '\bcur-?\d+' -and $l -match '\bant-?\d+') { return $true }
    if ($e -match 'is cursor' -and $e -match 'is antigravity' -and $l -match 'is cursor' -and $l -match 'is antigravity') { return $true }
    if ($e -match 'through v1\.5\.1' -and $l -match 'through v1\.5\.1') { return $true }
    return $false
}

function Format-AlignmentIds {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }
    $lines = $text -split "`r?`n"
    $blocks = New-Object System.Collections.Generic.List[string]
    $buf = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*---\s*$') { continue }
        if ($line -match '^\s*-\s+\*\*Agreed\*\*' -and $buf.Count -gt 0) {
            [void]$blocks.Add(($buf -join "`n").Trim())
            $buf.Clear()
        }
        [void]$buf.Add($line)
    }
    if ($buf.Count -gt 0) { [void]$blocks.Add(($buf -join "`n").Trim()) }
    $bodies = New-Object System.Collections.Generic.List[string]
    $other = New-Object System.Collections.Generic.List[string]
    foreach ($b in $blocks) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if ($b -match '(?s)^\s*-\s+\*\*Agreed\*\*\s*:\s*(.*)$') {
            $raw = Remove-AlignmentIndexPrefix $Matches[1]
            $parts = @($raw -split '(?m)(?=^\s*[◦•]\s*Agreed\s*:)')
            foreach ($part in $parts) {
                $body = ($part -replace '^\s*[◦•]\s*Agreed\s*:\s*', '').Trim()
                if ($body) { [void]$bodies.Add($body) }
            }
        } else {
            [void]$other.Add($b.Trim())
        }
    }
    $keep = New-Object System.Collections.Generic.List[string]
    for ($i = $bodies.Count - 1; $i -ge 0; $i--) {
        $drop = $false
        foreach ($later in $keep) {
            if (Test-AlignmentRepeat $bodies[$i] $later) { $drop = $true; break }
        }
        if (-not $drop) { $keep.Insert(0, $bodies[$i]) }
    }
    $n = 0
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $other) { [void]$out.Add($line) }
    foreach ($body in $keep) {
        $n++
        [void]$out.Add("- **Agreed**: [AG-$n] $body")
    }
    return ($out -join "`n`n")
}

function Get-ItemCodeToken {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    if ($text -match '(?i)\b((?:CUR|ANT|HUM))-?(\d+)\b') {
        return ($Matches[1].ToUpper() + $Matches[2])
    }
    return ""
}

function Test-DisagreementText {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text.Trim() -eq "_None_") { return $false }
    return $text -match '(?i)\*\*Disagreed\*\*|\[D\d+\]|\bdisagreement\b'
}

function Enter-ReconcilePhase {
    if ($script:SuppressPhaseAutoAdvance) { return }
    if ($chkAutoStep -and -not $chkAutoStep.IsChecked) { return }
    $flow = Get-FlowControlString
    if ($flow -match "STOP|PAUSE") { return }
    $cur = Get-PhaseString
    if ($cur -eq "reconcile") { return }
    if (-not (Test-DisagreementText $(if ($txtBugs) { $txtBugs.Text } else { "" }))) { return }
    $script:PhaseBeforeReconcile = $cur
    $script:ReconcileTurns1 = 0
    $script:ReconcileTurns2 = 0
    Set-Phase "reconcile"
    if ($txtStatus) { $txtStatus.Text = "Auto Step: disagreement opened reconcile. The seat that disagreed goes first. Return phase is $cur." }
}

function Note-ReconcileTurn {
    param([string]$seatKey)
    if ((Get-PhaseString) -ne "reconcile") { return }
    if ($seatKey -eq "seat1") {
        if (Test-RoleNone $cbCursorRole.Text) { return }
        $script:ReconcileTurns1++
        $n = $script:ReconcileTurns1
        $name = Get-Seat1Client
    } else {
        if (Test-RoleNone $cbGeminiRole.Text) { return }
        $script:ReconcileTurns2++
        $n = $script:ReconcileTurns2
        $name = Get-Seat2Client
    }
    if ($n -ge 5 -and $txtStatus) {
        $txtStatus.Text = "$name has used 5 reconcile turns. If the disagreement is still open, the human makes the call."
    }
}

function Find-SuggestionLineByCode {
    param([string]$code)
    $sources = @()
    if ($txtHumanNotes) { $sources += $txtHumanNotes.Text }
    if ($script:LastCursorPad) { $sources += $script:LastCursorPad }
    if ($script:LastGeminiPad) { $sources += $script:LastGeminiPad }
    if ($txtAlignment) { $sources += $txtAlignment.Text }
    foreach ($src in $sources) {
        foreach ($line in ($src -split "`r?`n")) {
            $hit = Get-ItemCodeToken $line
            if ($hit -eq $code) { return $line.Trim() }
        }
    }
    return ""
}

function Invoke-PromoteItemCode {
    $code = Get-ItemCodeToken $(if ($txtItemCode) { $txtItemCode.Text } else { "" })
    if (-not $code) {
        if ($txtStatus) { $txtStatus.Text = "Enter a code such as CUR1 or ANT1." }
        return
    }
    if ($txtAlignment -and $txtAlignment.Text -match [regex]::Escape($code)) {
        if ($txtStatus) { $txtStatus.Text = "$code is already in Alignment." }
        return
    }
    $line = Find-SuggestionLineByCode $code
    if (-not $line) {
        if ($txtStatus) { $txtStatus.Text = "No suggestion found for $code." }
        return
    }
    $clean = $line -replace '^(?:-\s*)?\*\*Agreed\*\*:\s*', ''
    $joined = Join-TextWithSeparator -existing $txtAlignment.Text -addition "- **Agreed**: $clean"
    $txtAlignment.Text = $joined
    Mark-FormDirty
    Save-BlackboardContent
    if ($txtStatus) { $txtStatus.Text = "Promoted $code into Alignment." }
}

function Invoke-DemoteItemCode {
    $code = Get-ItemCodeToken $(if ($txtItemCode) { $txtItemCode.Text } else { "" })
    if (-not $code) {
        if ($txtStatus) { $txtStatus.Text = "Enter a code such as CUR1 or ANT1." }
        return
    }
    if (-not $txtAlignment) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = $false
    foreach ($block in ($txtAlignment.Text -split "(?m)(?=^\s*-\s+\*\*Agreed\*\*)")) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        if ((Get-ItemCodeToken $block) -eq $code -or $block -match [regex]::Escape($code)) {
            $removed = $true
            continue
        }
        [void]$kept.Add($block.Trim())
    }
    if (-not $removed) {
        if ($txtStatus) { $txtStatus.Text = "$code is not in Alignment." }
        return
    }
    $txtAlignment.Text = ($kept -join "`n`n")
    Mark-FormDirty
    Save-BlackboardContent
    if ($txtStatus) { $txtStatus.Text = "Demoted $code from Alignment." }
}

function Register-ItemCodeClick {
    param($rtb)
    if (-not $rtb) { return }
    $rtb.add_PreviewMouseLeftButtonUp({
        param($sender, $e)
        try {
            $pos = $sender.GetPositionFromPoint($e.GetPosition($sender), $true)
            if (-not $pos) { return }
            $back = $pos
            $fwd = $pos
            for ($i = 0; $i -lt 8; $i++) {
                $prev = $back.GetNextInsertionPosition([System.Windows.Documents.LogicalDirection]::Backward)
                if (-not $prev) { break }
                $back = $prev
            }
            for ($i = 0; $i -lt 8; $i++) {
                $next = $fwd.GetNextInsertionPosition([System.Windows.Documents.LogicalDirection]::Forward)
                if (-not $next) { break }
                $fwd = $next
            }
            $range = New-Object System.Windows.Documents.TextRange($back, $fwd)
            $code = Get-ItemCodeToken $range.Text
            if ($code -and $txtItemCode) { $txtItemCode.Text = $code }
        } catch {}
    })
}

function Show-StatsWindow {
    $path = Join-Path $script:UserConfigDir "stats.json"
    $body = "No stats yet."
    if (Test-Path $path) {
        try {
            $stats = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $lines = @()
            foreach ($p in $stats.PSObject.Properties) {
                $r = $p.Value
                $lines += ("{0}: runs {1}, catches {2}, +{3}/-{4}, prompts {5}" -f $p.Name, $r.runs, $r.reviewCatches, $r.linesAdded, $r.linesRemoved, $r.promptsCopied)
            }
            if ($lines.Count -gt 0) { $body = $lines -join [Environment]::NewLine }
        } catch {
            $body = "Could not read stats.json."
        }
    }
    $win = New-Object System.Windows.Window
    $win.Title = "Per-seat stats"
    $win.Width = 520
    $win.Height = 320
    $win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E1E2E")
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $body
    $box.IsReadOnly = $true
    $box.AcceptsReturn = $true
    $box.TextWrapping = "Wrap"
    $box.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
    $box.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F9E2AF")
    $box.BorderThickness = 0
    $box.Margin = New-Object System.Windows.Thickness(12)
    $box.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $win.Content = $box
    $win.Owner = $window
    [void]$win.ShowDialog()
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
        ("> **Enabled Phases**: " + $q + ($script:EnabledPhases -join ",") + $q),
        ("> **Implement Mode**: " + $q + (Get-ImplementModeString) + $q),
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
        (Format-AlignmentIds (Remove-DanglingSeparators $txtAlignment.Text)),
        "",
        "---",
        "",
        "## Bugs",
        "",
        $(if ($txtBugs -and $txtBugs.Text.Trim()) { $txtBugs.Text.Trim() } else { "_None_" }),
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
    $script:ClosingSignoffsCompleted = $false
    $txtPrompt.Text = ""
    $txtAlignment.Text = ""
    $txtHumanNotes.Text = "- Active steering notes."
    $cbCursorRole.SelectedIndex = 5
    $cbGeminiRole.SelectedIndex = 5
    Set-Phase "ready"
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
    Invoke-CloseProjectWorkflow -promptConfirm $true
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
            "Hotfix" { $script:EnabledPhases = @("implement","test","closing","debrief") }
            "Docs"   { $script:EnabledPhases = @("discuss","implement","test","debrief") }
            "RFC"    { $script:EnabledPhases = @("pitch","discuss","debrief") }
            default  { $script:EnabledPhases = @("pitch","discuss","plan","implement","review","test","closing","debrief") }
        }
        $script:FormDirty = $true
        $txtStatus.Text = "Task preset applied: $preset. Roles were not changed. Enabled phases: $($script:EnabledPhases -join ', ')"
        Check-Safety
        Update-UiActiveTurn -keepOverride
    } finally {
        $script:SuppressPresetSync = $false
    }
}

if ($btnStats) { $btnStats.add_Click({ Show-StatsWindow }) }
if ($btnPromoteCode) { $btnPromoteCode.add_Click({ Invoke-PromoteItemCode }) }
if ($btnDemoteCode) { $btnDemoteCode.add_Click({ Invoke-DemoteItemCode }) }
Register-ItemCodeClick $rtbCursorLast
Register-ItemCodeClick $rtbGeminiLast
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
    if ($script:DiskScriptIsNewer) {
        if ($txtStatus) { $txtStatus.Text = "🔒 Controller script on disk is newer. Please click 'Relaunch' before prompting." }
        [System.Windows.MessageBox]::Show("scripts/blackboard-ui.ps1 has been updated on disk.`n`nPrompt dispatching is locked until the controller is relaunched.", "Relaunch Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
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
                if (Test-RoleNone $cbCursorRole.Text) {
                    $txtStatus.Text = "Seat 1 role is none. No kickoff."
                    return
                }
                $kPrompt = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                Safe-SetClipboard $kPrompt
                Add-SeatStat -seat $s1 -field "promptsCopied"
                $txtStatus.Text = "📋 Copied $s1 Kickoff Prompt (" + $cbCursorRole.Text + ") to clipboard."
            }
            "Seat2" {
                if (Test-RoleNone $cbGeminiRole.Text) {
                    $txtStatus.Text = "Seat 2 role is none. No kickoff."
                    return
                }
                $kPrompt = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                Safe-SetClipboard $kPrompt
                Add-SeatStat -seat $s2 -field "promptsCopied"
                $txtStatus.Text = "📋 Copied $s2 Kickoff Prompt (" + $cbGeminiRole.Text + ") to clipboard."
            }
            default {
                $skip1 = Test-RoleNone $cbCursorRole.Text
                $skip2 = Test-RoleNone $cbGeminiRole.Text
                if ($skip1 -and $skip2) {
                    $txtStatus.Text = "Both AI seats are none. No kickoff."
                    return
                }
                $parts = @()
                if (-not $skip1) {
                    $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                    $parts += "=== [$($s1.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent1
                    Add-SeatStat -seat $s1 -field "promptsCopied"
                }
                if (-not $skip2) {
                    $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                    $parts += "=== [$($s2.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent2
                    Add-SeatStat -seat $s2 -field "promptsCopied"
                }
                Safe-SetClipboard ($parts -join ([Environment]::NewLine + [Environment]::NewLine))
                $txtStatus.Text = "Copied kickoff for occupied seats only."
            }
        }
    } catch { $txtStatus.Text = "Error copying kickoff prompt: $_" }
}

function Invoke-SendKickoffPrompt {
    if ($script:DiskScriptIsNewer) {
        if ($txtStatus) { $txtStatus.Text = "🔒 Controller script on disk is newer. Please click 'Relaunch' before prompting." }
        [System.Windows.MessageBox]::Show("scripts/blackboard-ui.ps1 has been updated on disk.`n`nPrompt dispatching is locked until the controller is relaunched.", "Relaunch Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
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
                if (Test-RoleNone $cbCursorRole.Text) {
                    $txtStatus.Text = "Seat 1 role is none. No kickoff."
                    return
                }
                $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1"
                Safe-SetClipboard $pAgent1
                if (Send-AgentChatPaste -clientName $s1 -newChat $doNew) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                    $chatNote = if ($doNew) { " (New Chat, then off)" } else { "" }
                    $txtStatus.Text = "Best-effort send for $s1$chatNote. Prompt is on the clipboard. Confirm it landed in chat."
                } else {
                    $txtStatus.Text = if ($doNew) { "⚠️ No new $s1 chat was confirmed; kickoff was not sent and New Chat remains armed." } else { "📋 Copied $s1 Kickoff to clipboard (IDE window not found). Focus $s1 and paste." }
                }
            }
            "Seat2" {
                if (Test-RoleNone $cbGeminiRole.Text) {
                    $txtStatus.Text = "Seat 2 role is none. No kickoff."
                    return
                }
                $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2"
                Safe-SetClipboard $pAgent2
                if (Send-AgentChatPaste -clientName $s2 -newChat $doNew) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                    $chatNote = if ($doNew) { " (New Chat, then off)" } else { "" }
                    $txtStatus.Text = "Best-effort send for $s2$chatNote. Prompt is on the clipboard. Confirm it landed in chat."
                } else {
                    $txtStatus.Text = if ($doNew) { "⚠️ No new $s2 chat was confirmed; kickoff was not sent and New Chat remains armed." } else { "📋 Copied $s2 Kickoff to clipboard (IDE window not found). Focus $s2 and paste." }
                }
            }
            default {
                $skip1 = Test-RoleNone $cbCursorRole.Text
                $skip2 = Test-RoleNone $cbGeminiRole.Text
                if ($skip1 -and $skip2) {
                    $txtStatus.Text = "Both AI seats are none. No kickoff."
                    return
                }
                $pAgent1 = ""
                $pAgent2 = ""
                if (-not $skip1) { $pAgent1 = Get-KickoffPromptForAgent -agentName $s1 -role $cbCursorRole.Text -seatId "seat1" }
                if (-not $skip2) { $pAgent2 = Get-KickoffPromptForAgent -agentName $s2 -role $cbGeminiRole.Text -seatId "seat2" }

                $cFocused = $false
                $gFocused = $false
                if (-not $skip1) {
                    Safe-SetClipboard $pAgent1
                    $cFocused = Send-AgentChatPaste -clientName $s1 -newChat $doNew
                    if (-not $skip2) { Start-Sleep -Milliseconds 600 }
                }
                if (-not $skip2) {
                    Safe-SetClipboard $pAgent2
                    $gFocused = Send-AgentChatPaste -clientName $s2 -newChat $doNew
                }

                if ($cFocused -or $gFocused) {
                    Complete-KickoffNewChatOneShot -didNew $doNew
                }
                if ($cFocused -and $gFocused) {
                    $chatNote = if ($doNew) { " (New Chat one-shot, now off)" } else { "" }
                    $txtStatus.Text = "Kicked off occupied seats $s1 and $s2.$chatNote"
                } elseif ($cFocused -or ($skip2 -and $cFocused)) {
                    $txtStatus.Text = "Kicked off $s1."
                } elseif ($gFocused) {
                    $txtStatus.Text = "Kicked off $s2."
                } else {
                    $clip = @()
                    if (-not $skip1) { $clip += "=== [$($s1.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent1 }
                    if (-not $skip2) { $clip += "=== [$($s2.ToUpper()) KICKOFF PROMPT] ===" + [Environment]::NewLine + $pAgent2 }
                    Safe-SetClipboard ($clip -join ([Environment]::NewLine + [Environment]::NewLine))
                    $txtStatus.Text = "Copied kickoff for occupied seats. Focus the IDE to paste."
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
            if ($txtAlignment -and $txtAlignment.SelectionLength -gt 0) { $body = $txtAlignment.SelectedText }
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

    if ($script:DiskScriptIsNewer) {
        if ($txtStatus) { $txtStatus.Text = "🔒 Controller script on disk is newer. Please click 'Relaunch' before prompting." }
        [System.Windows.MessageBox]::Show("scripts/blackboard-ui.ps1 has been updated on disk.`n`nPrompt dispatching is locked until the controller is relaunched.", "Relaunch Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

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
    if ($script:DiskScriptIsNewer) {
        if ($txtStatus) { $txtStatus.Text = "🔒 Controller script on disk is newer. Please click 'Relaunch' before prompting." }
        [System.Windows.MessageBox]::Show("scripts/blackboard-ui.ps1 has been updated on disk.`n`nPrompt dispatching is locked until the controller is relaunched.", "Relaunch Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
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
    if (-not $force -and $script:DiskScriptIsNewer) {
        $secondsSinceWrite = if ($script:NewerScriptSinceUtc) { ([DateTime]::UtcNow - $script:NewerScriptSinceUtc).TotalSeconds } else { 999 }
        $isImplementActive = ((Get-PhaseString) -eq "implement" -or ($cbCursorRole -and $cbCursorRole.Text -eq "implement") -or ($cbGeminiRole -and $cbGeminiRole.Text -eq "implement"))
        if (($secondsSinceWrite -lt 4) -or ($isImplementActive -and $secondsSinceWrite -lt 6)) {
            [System.Windows.MessageBox]::Show("An AI is actively updating the controller's code.`n`nPlease wait until the update finishes before relaunching.", "Relaunch Locked", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }
    }
    if (-not $force -and $script:FormDirty) {
        $res = [System.Windows.MessageBox]::Show("You have unsaved changes in the Blackboard UI.`n`nDo you want to save before relaunching?`n`nYes = Save & Relaunch`nNo = Discard & Relaunch`nCancel = Stay here", "Unsaved Changes", [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
        if ($res -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        if ($res -eq [System.Windows.MessageBoxResult]::Yes) { Save-BlackboardContent }
    }
    
    $targetScript = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot "blackboard-ui.ps1" }
    $psExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
    $txtStatus.Text = "Relaunching controller..."
    $relaunchArgs = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$targetScript`""
    if ($script:RepoRoot -and -not (Test-SameFullPath $script:RepoRoot $script:ControllerRoot)) {
        $relaunchArgs += " -TargetRepo `"$script:RepoRoot`""
    }
    Start-Process $psExe -ArgumentList $relaunchArgs -WorkingDirectory $script:ControllerRoot
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
        git -C $script:ControllerRoot fetch origin main --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            $txtStatus.Text = "Could not reach online GitHub (fetch failed / offline)."
            [System.Windows.MessageBox]::Show("Could not reach online GitHub (origin/main). Please check your network connection.", "Update Check Failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        
        $localDirty = git -C $script:ControllerRoot status --porcelain scripts/blackboard-ui.ps1 2>$null
        if ($localDirty) {
            $dirtyWarn = [System.Windows.MessageBox]::Show("Warning: You have uncommitted local modifications in 'scripts/blackboard-ui.ps1'.`n`nRunning git pull may overwrite or conflict with your local edits.`n`nProceed with git pull anyway?", "Uncommitted Script Changes", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($dirtyWarn -ne [System.Windows.MessageBoxResult]::Yes) {
                $txtStatus.Text = "Update aborted: local modifications detected in scripts/blackboard-ui.ps1."
                return
            }
        }

        # Check if upstream commits exist behind current HEAD for controller
        $behindCount = 0
        $behindStr = git -C $script:ControllerRoot rev-list --count 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
        if ($LASTEXITCODE -eq 0 -and $behindStr) {
            $behindCount = [int]$behindStr
        }

        # Check if scripts/blackboard-ui.ps1 has diff against upstream
        $diffOut = git -C $script:ControllerRoot diff --stat 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null

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
            git -C $script:ControllerRoot pull --ff-only origin main
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
            git -C $script:ControllerRoot fetch origin main --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { return }

            $behindCount = 0
            $behindStr = git -C $script:ControllerRoot rev-list --count 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
            if ($LASTEXITCODE -eq 0 -and $behindStr) {
                $behindCount = [int]$behindStr
            }

            $diffOut = git -C $script:ControllerRoot diff --stat 'HEAD..origin/main' -- scripts/blackboard-ui.ps1 2>$null
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
                }

                $secondsSinceWrite = if ($script:NewerScriptSinceUtc) { ([DateTime]::UtcNow - $script:NewerScriptSinceUtc).TotalSeconds } else { 999 }
                $isImplementActive = ((Get-PhaseString) -eq "implement" -or ($cbCursorRole -and $cbCursorRole.Text -eq "implement") -or ($cbGeminiRole -and $cbGeminiRole.Text -eq "implement"))
                $aiActivelyUpdating = ($secondsSinceWrite -lt 4) -or ($isImplementActive -and $secondsSinceWrite -lt 6)

                Update-PromptButtonsLockState -locked $true

                if ($btnRelaunch) {
                    if ($aiActivelyUpdating) {
                        $btnRelaunch.IsEnabled = $false
                        $btnRelaunch.Content = "🔒 Relaunch (AI Updating Code)"
                        $btnRelaunch.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#45475A")
                        $btnRelaunch.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A6ADC8")
                        $btnRelaunch.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#313244")
                        $btnRelaunch.BorderThickness = New-Object System.Windows.Thickness(1)
                        $btnRelaunch.FontWeight = [System.Windows.FontWeights]::SemiBold
                        $btnRelaunch.ToolTip = "scripts/blackboard-ui.ps1 is actively being updated by an AI. Relaunch will unlock when write activity settles."
                    } else {
                        $btnRelaunch.IsEnabled = $true
                        $script:RelaunchFlashToggle = -not $script:RelaunchFlashToggle
                        $flashBg = if ($script:RelaunchFlashToggle) { "#F9E2AF" } else { "#FAB387" }
                        $flashBorder = if ($script:RelaunchFlashToggle) { "#FAB387" } else { "#F9E2AF" }
                        $btnRelaunch.Content = "⏭️ Relaunch is needed"
                        $btnRelaunch.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($flashBg)
                        $btnRelaunch.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#11111B")
                        $btnRelaunch.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($flashBorder)
                        $btnRelaunch.BorderThickness = New-Object System.Windows.Thickness(2)
                        $btnRelaunch.FontWeight = [System.Windows.FontWeights]::Bold
                        $btnRelaunch.ToolTip = "scripts/blackboard-ui.ps1 on disk is newer ($($diskTime.ToString('HH:mm:ss'))). Click to relaunch controller."
                    }
                }
            } else {
                $script:NewerScriptSinceUtc = $null
                if ($script:DiskScriptIsNewer) {
                    $script:DiskScriptIsNewer = $false
                    Update-PromptButtonsLockState -locked $false
                    if ($btnRelaunch) {
                        $btnRelaunch.IsEnabled = $true
                        $btnRelaunch.Content = "⏭️ Relaunch"
                        $btnRelaunch.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#313244")
                        $btnRelaunch.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CDD6F4")
                        $btnRelaunch.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#45475A")
                        $btnRelaunch.BorderThickness = New-Object System.Windows.Thickness(1)
                        $btnRelaunch.FontWeight = [System.Windows.FontWeights]::Normal
                        $btnRelaunch.ToolTip = "Restart Blackboard UI to pick up code changes or reset state"
                    }
                }
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
                if ($raw -match '>\s*\*\*Enabled Phases\*\*:\s*`([^`]+)`') {
                    $script:EnabledPhases = @($matches[1].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                if ($cbImplementMode -and $raw -match '>\s*\*\*Implement Mode\*\*:\s*`([^`]+)`') {
                    $mode = $matches[1].Trim()
                    for ($i = 0; $i -lt $cbImplementMode.Items.Count; $i++) {
                        if ([string]$cbImplementMode.Items[$i].Content -eq $mode) {
                            $cbImplementMode.SelectedIndex = $i
                            break
                        }
                    }
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
                    Note-ReconcileTurn "seat1"
                }
                if ($newGeminiPad -ne $script:LastGeminiPad -and $newGeminiPad -notmatch "(?i)^-\s*\((?:$s2Esc|Gemini|Agent\s*2|AI\s*2)\s+(?:updates?|scratchpad)" -and $newGeminiPad.Trim()) {
                    $script:LastGeminiPad = $newGeminiPad
                    $script:ActiveTurnOverride = "$s2 responded at " + (Get-Date -Format "HH:mm")
                    $turnChanged = $true
                    if (Test-UnsignedTestRollback -phase (Get-PhaseString) -autoStep $autoOn -flow $flowNow -padChanged $true -pad $newGeminiPad) {
                        $script:PendingUnsignedRollback = $true
                    }
                    Note-ReconcileTurn "seat2"
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
                $alignLoaded = Format-AlignmentIds (Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Alignment\s*&\s*Agreed Decisions'))
                $txtAlignment.Text = $alignLoaded
                $bugsLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Bugs')
                if ($txtBugs) {
                    if ($bugsLoaded -and $bugsLoaded.Trim() -ne "_None_") { $txtBugs.Text = $bugsLoaded.Trim() } else { $txtBugs.Text = "" }
                    Update-BugsVisibility
                    Enter-ReconcilePhase
                }
                $humanLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '(?:###|##)\s+(?:Human(?:\s+\(Lead\))?|[^\r\n]+?\s+\(Lead\)|Lead)')
                if ($humanLoaded) { $txtHumanNotes.Text = $humanLoaded }
                $script:FormDirty = $false
            } else {
                if (-not $script:FormDirty) {
                    $promptLoaded = Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Current Objective\s*&\s*Prompt')
                    if ($promptLoaded -and $promptLoaded -ne $txtPrompt.Text) {
                        $txtPrompt.Text = $promptLoaded
                    }
                    $alignLoaded = Format-AlignmentIds (Remove-DanglingSeparators (Get-LastMarkdownBody $raw '##\s+Alignment\s*&\s*Agreed Decisions'))
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
                $txtStatus.Text = "⚠️ Controller script on disk is newer than this open window. Prompt buttons are locked until relaunched."
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
        $allSignedNow = Test-RequiredSignoffsMet
        $openDisagreement = (Get-PhaseString) -ne "reconcile" -and (Test-DisagreementText $(if ($txtBugs) { $txtBugs.Text } else { "" }))
        if ($openDisagreement) {
            Enter-ReconcilePhase
        } elseif ($allSignedNow) {
            $script:PendingUnsignedRollback = $false
            $script:NewSignoffDuringLoad = $false
            Check-PhaseAutoAdvance
        } elseif ($script:PendingUnsignedRollback) {
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

function Ensure-RepoBlackboardFile {
    param([string]$repo)
    $ai = Join-Path $repo ".ai"
    $bb = Join-Path $ai "blackboard.md"
    if (-not (Test-Path -LiteralPath $ai)) { New-Item -ItemType Directory -Force -Path $ai | Out-Null }
    foreach ($sub in @("history", "saved")) {
        $subPath = Join-Path $ai $sub
        if (-not (Test-Path -LiteralPath $subPath)) { New-Item -ItemType Directory -Force -Path $subPath | Out-Null }
    }
    if (-not (Test-Path -LiteralPath $bb)) {
        $example = Join-Path $script:ControllerAiDir "blackboard.example.md"
        if (Test-Path -LiteralPath $example) {
            Copy-Item -LiteralPath $example -Destination $bb
        }
    }
    return $bb
}

if ($script:LaunchRepoRoot) {
    $launchBoard = Ensure-RepoBlackboardFile -repo $script:LaunchRepoRoot
    if (Test-Path -LiteralPath $launchBoard) {
        Set-ActiveBlackboardPath -targetPath $launchBoard
    } else {
        Load-BlackboardIntoUI
        Populate-RecentBoardsDropdown
    }
} elseif ($script:ClientConfig -and $script:ClientConfig.boardPath -and (Test-Path $script:ClientConfig.boardPath)) {
    Set-ActiveBlackboardPath -targetPath $script:ClientConfig.boardPath
} else {
    Load-BlackboardIntoUI
    Populate-RecentBoardsDropdown
}
if ($chkNewChatKickoff) { $chkNewChatKickoff.IsChecked = $false }
Update-KickoffButtonTooltips
if (-not $HeadlessTest) { Start-StartupUpdateCheck }

function Invoke-HeadlessUiTest {
    $fails = New-Object System.Collections.Generic.List[string]
    $log = Join-Path $env:TEMP "blackboard-ui-test-last.txt"
    function Add-Fail([string]$msg) { [void]$fails.Add($msg); Add-Content $log "FAIL $msg"; Write-Output "FAIL $msg" }
    function Add-Pass([string]$msg) { Add-Content $log "PASS $msg"; Write-Output "PASS $msg" }
    $fixture = @"
- **Agreed**: [A23] Disagreements jump to
``reconcile`` later.

- **Agreed**: [A1] is Cursor and [A2] is Antigravity.

- **Agreed**: Keep the latest decision only.

- **Agreed**: Keep the latest decision only.
"@
    $formatted = Format-AlignmentIds $fixture
    if ($formatted -match '\[A23\]') { Add-Fail "wrapped [A23] survived" } else { Add-Pass "A23" }
    if ($formatted -notmatch '\[A1\] is Cursor') { Add-Fail "seat id [A1] was dropped" } else { Add-Pass "SEAT" }
    $latest = @($formatted -split "`n" | Where-Object { $_ -match 'latest decision' })
    if ($latest.Count -ne 1) { Add-Fail "repeated Alignment line count $($latest.Count)" } else { Add-Pass "TRIM" }

    $token = "ROUNDTRIP-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $txtPrompt.Text = $token
    Save-BlackboardContent
    $txtPrompt.Text = ""
    Load-BlackboardIntoUI
    if ($txtPrompt.Text -notmatch [regex]::Escape($token)) { Add-Fail "prompt did not round-trip" } else { Add-Pass "ROUNDTRIP" }

    $diskToken = "DISK-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $raw = [System.IO.File]::ReadAllText($script:BlackboardPath)
    $raw2 = $raw -replace [regex]::Escape($token), $diskToken
    [System.IO.File]::WriteAllText($script:BlackboardPath, $raw2)
    $script:FormDirty = $false
    $btnReloadBoard.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    if ($txtPrompt.Text -notmatch [regex]::Escape($diskToken)) { Add-Fail "Refresh click did not load disk" } else { Add-Pass "REFRESH" }

    $f5Token = "F5-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $raw = [System.IO.File]::ReadAllText($script:BlackboardPath)
    $raw3 = $raw -replace [regex]::Escape($diskToken), $f5Token
    [System.IO.File]::WriteAllText($script:BlackboardPath, $raw3)
    $script:FormDirty = $false
    $src = [System.Windows.PresentationSource]::FromVisual($window)
    if (-not $src) { Add-Fail "F5 has no presentation source" }
    else {
        $key = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::F5)
        $key.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $window.RaiseEvent($key)
        if ($txtPrompt.Text -notmatch [regex]::Escape($f5Token)) { Add-Fail "F5 did not reload disk" } else { Add-Pass "F5" }
    }

    $txtItemCode.Text = "CUR1"
    $btnPromoteCode.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    if ($txtAlignment.Text -notmatch 'CUR1') { Add-Fail "Promote did not add CUR1" } else { Add-Pass "PROMOTE" }
    $btnDemoteCode.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    if ($txtAlignment.Text -match 'CUR1') { Add-Fail "Demote left CUR1 in Alignment" } else { Add-Pass "DEMOTE" }

    if ($chkAutoStep) { $chkAutoStep.IsChecked = $true }
    $txtBugs.Text = "**Disagreed**: headless check"
    Enter-ReconcilePhase
    if ((Get-PhaseString) -ne "reconcile") { Add-Fail "Auto Step did not open reconcile" } else { Add-Pass "RECONCILE" }

    if ($fails.Count -eq 0) { Add-Pass "ALL"; return 0 }
    Add-Fail ("count " + $fails.Count)
    return 1
}

if ($HeadlessTest) {
    $window.WindowState = [System.Windows.WindowState]::Minimized
    $window.ShowInTaskbar = $false
    $window.Visibility = [System.Windows.Visibility]::Hidden
    $window.Show()
    $script:HeadlessExitCode = Invoke-HeadlessUiTest
    $window.Close()
    exit $script:HeadlessExitCode
}

$window.ShowDialog() | Out-Null

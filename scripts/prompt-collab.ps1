# Dual-Session Agent Blackboard CLI
[CmdletBinding()]
param(
    [ValidateSet('go', 'pause', 'stop')]
    [string]$Flow,

    [ValidateSet('advise', 'plan', 'implement', 'review')]
    [string]$Phase,

    [Alias('CursorRole')]
    [ValidateSet('implement', 'review', 'advise', 'inventory', 'plan', 'idle')]
    [string]$Agent1Role,

    [Alias('GeminiRole')]
    [ValidateSet('implement', 'review', 'advise', 'inventory', 'plan', 'idle')]
    [string]$Agent2Role,

    [ValidateSet('discuss', 'implement', 'audit', 'plan', 'idle')]
    [string]$Preset,

    [string]$Prompt,
    [string]$Alignment,
    [string]$Issue,
    [string]$Turn,
    [switch]$Reset,
    [switch]$Promote,
    [switch]$Show
)

$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$AiDir = Join-Path $RepoRoot '.ai'
$HistoryDir = Join-Path $AiDir 'history'
$BlackboardPath = Join-Path $AiDir 'blackboard.md'

if (-not (Test-Path $AiDir)) { New-Item -ItemType Directory -Force -Path $AiDir | Out-Null }
if (-not (Test-Path $HistoryDir)) { New-Item -ItemType Directory -Force -Path $HistoryDir | Out-Null }

# Read-only show mode
$hasModifyingArgs = $PSBoundParameters.ContainsKey('Flow') -or $PSBoundParameters.ContainsKey('Phase') -or `
                    $PSBoundParameters.ContainsKey('Agent1Role') -or $PSBoundParameters.ContainsKey('Agent2Role') -or `
                    $PSBoundParameters.ContainsKey('Preset') -or $PSBoundParameters.ContainsKey('Prompt') -or `
                    $PSBoundParameters.ContainsKey('Alignment') -or $PSBoundParameters.ContainsKey('Issue') -or `
                    $PSBoundParameters.ContainsKey('Turn') -or $Reset -or $Promote

if ($Show -and (-not $hasModifyingArgs)) {
    if (Test-Path $BlackboardPath) {
        Get-Content $BlackboardPath -Raw
    } else {
        Write-Warning "Blackboard file does not exist: $BlackboardPath"
    }
    return
}

# Parse existing content if present
$currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
$currentPhase = 'plan'
$currentTurn = 'Human (Lead)'
$currentIssue = 'none'
$currentAgent1 = 'idle'
$currentAgent2 = 'idle'
$currentPrompt = ''
$currentAlign = ''
$currentHuman = '- Active steering notes.'
$currentAgent1Pad = '- (Agent 1 updates here)'
$currentAgent2Pad = '- (Agent 2 updates here)'
$signHuman = '[ ]'
$signAgent1 = '[ ]'
$signAgent2 = '[ ]'

if (Test-Path $BlackboardPath) {
    $raw = Get-Content -Path $BlackboardPath -Raw
    if ($raw -match '>\s*\*\*Flow Control\*\*:\s*`([^`]+)`') { $currentFlow = $matches[1] }
    if ($raw -match '>\s*\*\*Project Phase\*\*:\s*`([^`]+)`') { $currentPhase = $matches[1] }
    if ($raw -match '>\s*\*\*Active Turn\*\*:\s*(.+)') { $currentTurn = $matches[1].Trim() }
    if ($raw -match '>\s*\*\*GitHub Issue\*\*:\s*(.+)') { $currentIssue = $matches[1].Trim() }
    if ($raw -match '\|\s*\*\*(?:Agent\s*1|Cursor)\*\*\s*\|\s*`([^`]+)`') { $currentAgent1 = $matches[1] }
    if ($raw -match '\|\s*\*\*(?:Agent\s*2|Gemini(?:\s+\(Antigravity\))?)\*\*\s*\|\s*`([^`]+)`') { $currentAgent2 = $matches[1] }

    if ($raw -match '(?m)\|\s*\*\*([^*]+)\*\*\s*\|\s*`lead`\s*\|\s*Active\s*\|\s*(\[[ xX]\])') { $signHuman = $matches[2] }
    if ($raw -match '\|\s*\*\*(?:Agent\s*1|Cursor)\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*(\[[ xX]\])') { $signAgent1 = $matches[1] }
    if ($raw -match '\|\s*\*\*(?:Agent\s*2|Gemini(?:\s+\(Antigravity\))?)\*\*\s*\|\s*`[^`]*`\s*\|\s*Active\s*\|\s*(\[[ xX]\])') { $signAgent2 = $matches[1] }

    if ($raw -match '(?ms)^##\s+Current Objective\s*&\s*Prompt\s*\r?\n(.*?)(?=\r?\n\s*---\s*\r?\n\s*##|\Z)') { $currentPrompt = $matches[1].Trim() }
    if ($raw -match '(?ms)^##\s+Alignment\s*&\s*Agreed Decisions\s*\r?\n(.*?)(?=\r?\n\s*---\s*\r?\n\s*##|\Z)') { $currentAlign = $matches[1].Trim() }
    if ($raw -match '(?ms)^(?:###|##)\s+(?:Human(?:\s+\(Lead\))?|[^\r\n]+?\s+\(Lead\)|Lead)\s*\r?\n(.*?)(?=\r?\n\s*(?:###|##)|\Z)') { $currentHuman = $matches[1].Trim() }
    if ($raw -match '(?ms)^(?:###|##)\s+(?:Agent\s*1|Cursor)(?:\s+Scratchpad)?\s*\r?\n(.*?)(?=\r?\n\s*(?:###|##)\s+(?:Agent\s*2|Gemini)|\Z)') { $currentAgent1Pad = $matches[1].Trim() }
    if ($raw -match '(?ms)^(?:###|##)\s+(?:Agent\s*2|Gemini(?:\s+\(Antigravity\))?)(?:\s+Scratchpad)?\s*\r?\n(.*?)\Z') { $currentAgent2Pad = $matches[1].Trim() }
}

if ($Preset) {
    switch ($Preset) {
        'discuss' {
            $currentAgent1 = 'advise'
            $currentAgent2 = 'advise'
            $currentPhase = 'advise'
            $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
        }
        'implement' {
            $currentAgent1 = 'implement'
            $currentAgent2 = 'review'
            $currentPhase = 'implement'
            $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
        }
        'audit' {
            $currentAgent1 = 'inventory'
            $currentAgent2 = 'review'
            $currentPhase = 'review'
            $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
        }
        'plan' {
            $currentAgent1 = 'plan'
            $currentAgent2 = 'idle'
            $currentPhase = 'plan'
            $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
        }
        'idle' {
            $currentAgent1 = 'idle'
            $currentAgent2 = 'idle'
        }
    }
}

if ($Reset) {
    if (Test-Path $BlackboardPath) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -Path $BlackboardPath -Destination (Join-Path $HistoryDir ("blackboard-$ts.md")) -Force
        Write-Host "Archived current blackboard to .ai/history/blackboard-$ts.md" -ForegroundColor Cyan
    }
    $currentPrompt = ''
    $currentAlign = ''
    $currentAgent1 = 'idle'
    $currentAgent2 = 'idle'
    $currentPhase = 'advise'
    $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
    $currentTurn = 'Human (Lead)'
    $currentHuman = '- Active steering notes.'
    $currentAgent1Pad = '- (Agent 1 updates here)'
    $currentAgent2Pad = '- (Agent 2 updates here)'
    $signHuman = '[ ]'
    $signAgent1 = '[ ]'
    $signAgent2 = '[ ]'
}

if ($Promote) {
    if ($currentAlign) {
        $currentPrompt = "Promoted Alignment Decision:" + [Environment]::NewLine + $currentAlign
        $currentPhase = 'implement'
        $currentAgent1 = 'implement'
        $currentAgent2 = 'review'
        $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO"
        $currentHuman = '- Active steering notes.'
        $currentAgent1Pad = '- (Agent 1 updates here)'
        $currentAgent2Pad = '- (Agent 2 updates here)'
        Write-Host "Promoted alignment decisions to implementation objective." -ForegroundColor Green
    } else {
        Write-Warning "Cannot promote: Alignment section is empty."
    }
}

if ($Flow -eq 'go') { $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E2)) GO" }
elseif ($Flow -eq 'pause') { $currentFlow = "$([char]::ConvertFromUtf32(0x1F7E1)) PAUSE (Wait for Human)" }
elseif ($Flow -eq 'stop') { $currentFlow = "$([char]::ConvertFromUtf32(0x1F534)) ALL STOP" }

if ($Phase) { $currentPhase = $Phase }
if ($Agent1Role) { $currentAgent1 = $Agent1Role }
if ($Agent2Role) { $currentAgent2 = $Agent2Role }
if ($Turn) { $currentTurn = $Turn }
if ($Issue) { $currentIssue = if ($Issue.StartsWith('#')) { $Issue } else { "#$Issue" } }
if ($PSBoundParameters.ContainsKey('Prompt')) { $currentPrompt = $Prompt }
if ($PSBoundParameters.ContainsKey('Alignment')) { $currentAlign = $Alignment }

if ($currentAgent1 -eq 'implement' -and $currentAgent2 -eq 'implement') {
    Write-Warning "SAFETY GUARD: Both Agent 1 and Agent 2 are configured with implement role! Risk of concurrent write collision."
}

$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$q = [char]96

$lines = @(
    '# Dual-Session Agent Blackboard',
    '',
    "> **Flow Control**: $q$currentFlow$q",
    "> **Project Phase**: $q$currentPhase$q",
    "> **Active Turn**: $currentTurn",
    "> **GitHub Issue**: $currentIssue",
    "> **Last Updated**: $timestamp",
    '',
    '---',
    '',
    '## Agent Roles & Safety',
    '',
    '| Participant | Active Role | Status | Sign-off (Complete) |',
    '|-------------|-------------|--------|---------------------|',
    "| **Human (Lead)** | $($q)lead$($q) | Active | $signHuman |",
    "| **Agent 1** | $q$currentAgent1$q | Active | $signAgent1 |",
    "| **Agent 2** | $q$currentAgent2$q | Active | $signAgent2 |",
    '',
    '> [!NOTE]',
    "> **Safety Guard**: Only ONE agent may hold the $($q)implement$($q) role at any time. When one implements, the other must be $($q)review$($q), $($q)advise$($q), or $($q)idle$($q).",
    '',
    '---',
    '',
    '## Current Objective & Prompt',
    '',
    $currentPrompt,
    '',
    '---',
    '',
    '## Alignment & Agreed Decisions',
    '',
    $currentAlign,
    '',
    '---',
    '',
    '## Working Notes & Scratchpads',
    '',
    '### Human (Lead)',
    $currentHuman,
    '',
    '### Agent 1 Scratchpad',
    $currentAgent1Pad,
    '',
    '### Agent 2 Scratchpad',
    $currentAgent2Pad
)

$outputContent = $lines -join [Environment]::NewLine
[System.IO.File]::WriteAllText($BlackboardPath, $outputContent, [System.Text.Encoding]::UTF8)

Write-Host "Blackboard updated ($BlackboardPath)" -ForegroundColor Green
Write-Host "Flow: $currentFlow | Phase: $currentPhase | Agent 1: $currentAgent1 | Agent 2: $currentAgent2" -ForegroundColor Cyan

if ($Show) {
    Get-Content $BlackboardPath
}

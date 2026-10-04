#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Automated Headless Test Runner for AI Collab Controller.
.DESCRIPTION
    Executes blackboard-ui.ps1 with -HeadlessTest asserting DeepSeek profile,
    implement->review default roles, gate persistence, Implementation Scope,
    Auto Step levels, Kickoff Auto-Switch, and dual-implement refusal with
    full test isolation on temporary blackboard instances.
#>
[CmdletBinding()]
param(
    [Alias("summary-only")]
    [switch]$SummaryOnly
)

$scriptPath = Join-Path $PSScriptRoot "blackboard-ui.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Controller script not found at $scriptPath"
    exit 1
}

function Get-ProcessTreeIds {
    param([int]$RootId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootId)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $all) {
            $procId = [int]$p.ProcessId
            $parent = [int]$p.ParentProcessId
            if ($ids.Contains($parent) -and -not $ids.Contains($procId)) {
                [void]$ids.Add($procId)
                $changed = $true
            }
        }
    }
    return $ids
}

$proc = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-HeadlessTest" -PassThru -NoNewWindow
$seen = [System.Collections.Generic.HashSet[int]]::new()
$deadline = [DateTime]::UtcNow.AddSeconds(120)
while (-not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    foreach ($id in (Get-ProcessTreeIds -RootId $proc.Id)) { [void]$seen.Add($id) }
    Start-Sleep -Milliseconds 200
}
if (-not $proc.HasExited) {
    & taskkill.exe /PID $proc.Id /T /F | Out-Null
    Write-Error "FAIL: headless run exceeded 120s and was killed."
    exit 1
}
Start-Sleep -Milliseconds 400
$left = @()
foreach ($id in $seen) {
    if ($id -eq $proc.Id) { continue }
    if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $left += $id }
}
if ($left.Count -gt 0) {
    foreach ($id in $left) { & taskkill.exe /PID $id /T /F | Out-Null }
    $still = @($left | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($still.Count -gt 0) {
        Write-Error "FAIL: headless child still running: $($still -join ',')"
        exit 1
    }
    Write-Error "FAIL: headless child outlived the test and was killed: $($left -join ',')"
    exit 1
}
$log = Join-Path $env:TEMP "blackboard-ui-test-last.txt"
$logFail = $false
$logPassAll = $false
if (Test-Path $log) {
    $logFail = [bool](Select-String -Path $log -Pattern "^FAIL " -Quiet)
    $logPassAll = [bool](Select-String -Path $log -Pattern "^PASS ALL" -Quiet)
}
if ($logPassAll -and -not $logFail) {
    Write-Host "PASS: All blackboard UI headless checks passed." -ForegroundColor Green
    exit 0
}
$code = if ($proc.ExitCode -and $proc.ExitCode -ne 0) { $proc.ExitCode } else { 1 }
Write-Error "FAIL: Blackboard UI headless checks failed with exit code $code."
exit $code

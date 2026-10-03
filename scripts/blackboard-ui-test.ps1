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

$proc = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-HeadlessTest" -PassThru -Wait -NoNewWindow
$log = Join-Path $env:TEMP "blackboard-ui-test-last.txt"
$logFail = $false
if (Test-Path $log) {
    $logFail = [bool](Select-String -Path $log -Pattern "^FAIL " -Quiet)
}
if ($proc.ExitCode -eq 0 -and -not $logFail) {
    Write-Host "PASS: All blackboard UI headless checks passed." -ForegroundColor Green
    exit 0
}
$code = if ($proc.ExitCode -and $proc.ExitCode -ne 0) { $proc.ExitCode } else { 1 }
Write-Error "FAIL: Blackboard UI headless checks failed with exit code $code."
exit $code

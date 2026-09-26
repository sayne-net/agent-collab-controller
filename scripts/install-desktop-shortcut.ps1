# Creates a Desktop shortcut for the Blackboard Controller on the current machine
# Usage: pwsh .\scripts\install-desktop-shortcut.ps1

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo "scripts\blackboard-ui.ps1"
$desktop = [Environment]::GetFolderPath("Desktop")

if (-not (Test-Path $scriptPath)) {
    throw "Cannot find blackboard-ui.ps1 at $scriptPath"
}

$WshShell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path $desktop "Blackboard Controller.lnk"
$Shortcut = $WshShell.CreateShortcut($shortcutPath)

# Check if pwsh (PowerShell 7) is available, otherwise use powershell.exe
$pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    $pwshPath = "powershell.exe"
}

$Shortcut.TargetPath = $pwshPath
$Shortcut.Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$Shortcut.WorkingDirectory = $repo
$Shortcut.IconLocation = "powershell.exe,0"
$Shortcut.Description = "Dual-Session Blackboard Controller"
$Shortcut.Save()

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Shortcut successfully created on your Desktop!" -ForegroundColor Green
Write-Host " Location: $shortcutPath" -ForegroundColor Yellow
Write-Host " Target:   $scriptPath" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan

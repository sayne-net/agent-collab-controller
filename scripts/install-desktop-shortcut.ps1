# Creates a Desktop shortcut for the Blackboard Controller on the current machine
# Usage: pwsh .\scripts\install-desktop-shortcut.ps1

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo "scripts\blackboard-ui.ps1"
$desktop = [Environment]::GetFolderPath("Desktop")

if (-not (Test-Path $scriptPath)) {
    throw "Cannot find blackboard-ui.ps1 at $scriptPath"
}

$WshShell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path $desktop "AI Collab Controller.lnk"
$legacyShortcutPath = Join-Path $desktop "Agent Collab Controller.lnk"
if (Test-Path $legacyShortcutPath) {
    try {
        $legacyShortcut = $WshShell.CreateShortcut($legacyShortcutPath)
        $targetName = [System.IO.Path]::GetFileName($legacyShortcut.TargetPath)
        $isPowerShell = $targetName -in @("pwsh.exe", "powershell.exe")

        $normWorkDir = if ($legacyShortcut.WorkingDirectory) { [System.IO.Path]::GetFullPath($legacyShortcut.WorkingDirectory).TrimEnd('\', '/') } else { "" }
        $normRepo = [System.IO.Path]::GetFullPath($repo).TrimEnd('\', '/')
        $isSameRepo = ($normWorkDir -eq $normRepo)

        $expectedArg1 = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $expectedArg2 = "-STA -NoProfile -ExecutionPolicy Bypass -File $scriptPath"
        $trimmedArgs = ($legacyShortcut.Arguments -replace '\s+', ' ').Trim()
        $isDefaultArgs = ($trimmedArgs -eq $expectedArg1 -or $trimmedArgs -eq $expectedArg2)

        if ($isPowerShell -and $isSameRepo -and $isDefaultArgs) {
            Remove-Item $legacyShortcutPath -Force -ErrorAction SilentlyContinue
            Write-Host "Migrated uncustomized legacy shortcut: $legacyShortcutPath" -ForegroundColor DarkGray
        } else {
            Write-Host "Preserved customized or ambiguous legacy shortcut: $legacyShortcutPath" -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Could not inspect legacy shortcut: $_"
    }
}
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
$Shortcut.Description = "AI Collab Controller"
$Shortcut.Save()

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Shortcut successfully created on your Desktop!" -ForegroundColor Green
Write-Host " Location: $shortcutPath" -ForegroundColor Yellow
Write-Host " Target:   $scriptPath" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan

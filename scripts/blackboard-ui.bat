@echo off
where pwsh.exe >nul 2>nul
if %ERRORLEVEL% equ 0 (
    start "" pwsh.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0blackboard-ui.ps1"
) else (
    start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0blackboard-ui.ps1"
)

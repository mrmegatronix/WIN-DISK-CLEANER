@echo off
setlocal
title Windows 11 Safe System Disk Cleanup Launcher
set "SCRIPT_PATH=%~dp0Win11-DiskCleanup.ps1"

if not exist "%SCRIPT_PATH%" (
    echo [ERROR] Could not find "%SCRIPT_PATH%"
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
endlocal

@echo off
setlocal
title WIN-DISK-CLEANER Launcher

:: Check for Administrator privileges; self-elevate this .cmd if needed
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [INFO] Requesting Administrator privileges...
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT_PATH=%~dp0Win11-DiskCleanup.ps1"
if not exist "%SCRIPT_PATH%" (
    echo [ERROR] Could not find "%SCRIPT_PATH%"
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%SCRIPT_PATH%' -ErrorAction SilentlyContinue"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Script exited with code %ERRORLEVEL%.
    pause
)
endlocal

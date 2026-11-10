#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds WIN-DISK-CLEANER release artifacts:
    - dist/WIN-DISK-CLEANER-SingleFile.cmd (self-contained batch + PowerShell polyglot)
    - dist/WIN-DISK-CLEANER-v6.0.0-Portable.zip (complete portable bundle)
    - dist/SHA256SUMS.txt (SHA-256 integrity hashes)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'

if (-not (Test-Path -LiteralPath $dist)) {
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
}

# 1. Verify syntax of Win11-DiskCleanup.ps1 before building
$ps1Path = Join-Path $root 'Win11-DiskCleanup.ps1'
$errors  = $null
$tokens  = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "Syntax error in Win11-DiskCleanup.ps1: $($errors[0])"
}

# 2. Build Single-File Polyglot (.cmd that embeds the full PowerShell script)
$ps1Body = Get-Content -LiteralPath $ps1Path -Raw
# Strip #Requires -Version 5.1 from top since polyglot header is on line 1
$ps1BodyClean = $ps1Body -replace '^\s*#Requires\s+-Version\s+5\.1\r?\n', ''

$polyglotHeader = @'
<# :
@echo off
setlocal
title WIN-DISK-CLEANER v6.0.0 — Self-Contained Edition
set "TEMP_PS1=%TEMP%\Win11-DiskCleanup_%RANDOM%.ps1"
more +14 "%~f0" > "%TEMP_PS1%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TEMP_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
del /f /q "%TEMP_PS1%" >nul 2>&1
exit /b %EXIT_CODE%
#>
#Requires -Version 5.1
'@

$singleCmdPath = Join-Path $dist 'WIN-DISK-CLEANER-SingleFile.cmd'
$fullSingle = ($polyglotHeader -replace "`r?`n", "`r`n") + "`r`n" + ($ps1BodyClean -replace "`r?`n", "`r`n")
[System.IO.File]::WriteAllText($singleCmdPath, $fullSingle, [System.Text.Encoding]::UTF8)

# 3. Build Portable ZIP package
$zipPath = Join-Path $dist 'WIN-DISK-CLEANER-v6.0.0-Portable.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
$filesToPack = @(
    (Join-Path $root 'Win11-DiskCleanup.ps1'),
    (Join-Path $root 'Run-Cleanup.cmd'),
    $singleCmdPath,
    (Join-Path $root 'exclusions.txt'),
    (Join-Path $root 'README.md')
)
Compress-Archive -LiteralPath $filesToPack -DestinationPath $zipPath -CompressionLevel Optimal

# 4. Generate SHA256SUMS.txt
$sumsPath = Join-Path $dist 'SHA256SUMS.txt'
$sumLines = foreach ($f in @($singleCmdPath, $zipPath, $ps1Path)) {
    $h = Get-FileHash -LiteralPath $f -Algorithm SHA256
    '{0}  {1}' -f $h.Hash.ToLowerInvariant(), (Split-Path $f -Leaf)
}
[System.IO.File]::WriteAllLines($sumsPath, $sumLines, [System.Text.Encoding]::UTF8)

Write-Host "BUILD SUCCESSFUL:" -ForegroundColor Green
Get-ChildItem -LiteralPath $dist | Select-Object Name, Length | Format-Table -AutoSize

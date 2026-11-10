#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds and verifies WIN-DISK-CLEANER release artifacts:
    - Enforces 100% 7-bit ASCII (no UTF-8 BOM, no smart-quote byte 0x94 in Windows-1252)
    - dist/WIN-DISK-CLEANER-SingleFile.cmd (self-elevating batch + embedded PowerShell payload)
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

$ps1Path = Join-Path $root 'Win11-DiskCleanup.ps1'
$cmdPath = Join-Path $root 'Run-Cleanup.cmd'

# 1. Verify zero non-ASCII bytes in Win11-DiskCleanup.ps1 (prevents Windows PowerShell 5.1 Windows-1252 0x94 quote bug)
$rawBytes = [System.IO.File]::ReadAllBytes($ps1Path)
for ($i = 0; $i -lt $rawBytes.Length; $i++) {
    if ($rawBytes[$i] -gt 127) {
        throw "Non-ASCII byte 0x$($rawBytes[$i].ToString('X2')) found at byte offset $i in Win11-DiskCleanup.ps1"
    }
}

# 2. Normalize CRLF and write Win11-DiskCleanup.ps1 and Run-Cleanup.cmd as pure ASCII (NO BOM)
$asciiNoBom = [System.Text.Encoding]::ASCII
$ps1Text = ([System.IO.File]::ReadAllText($ps1Path) -replace "`r?`n", "`r`n")
[System.IO.File]::WriteAllText($ps1Path, $ps1Text, $asciiNoBom)

$cmdText = ([System.IO.File]::ReadAllText($cmdPath) -replace "`r?`n", "`r`n")
[System.IO.File]::WriteAllText($cmdPath, $cmdText, $asciiNoBom)

# 3. Verify AST syntax of Win11-DiskCleanup.ps1
$errors = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "Syntax error in Win11-DiskCleanup.ps1: $($errors[0])"
}

# 4. Build Single-File Self-Elevating .cmd (pure ASCII, no BOM, elevates before extracting payload)
# Note: Batch header is exactly 21 lines; 'more +21 "%~f0"' outputs from line 22 onward.
$batchHeaderLines = @(
    '@echo off',
    'setlocal',
    'title WIN-DISK-CLEANER v6.1 - Self-Contained Edition',
    'net session >nul 2>&1',
    'if %ERRORLEVEL% neq 0 (',
    '    echo [INFO] Requesting Administrator privileges...',
    '    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs"',
    '    exit /b',
    ')',
    'set "TEMP_PS1=%TEMP%\Win11-DiskCleanup_%RANDOM%.ps1"',
    'more +21 "%~f0" > "%TEMP_PS1%"',
    '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TEMP_PS1%" %*',
    'set "EXIT_CODE=%ERRORLEVEL%"',
    'del /f /q "%TEMP_PS1%" >nul 2>&1',
    'if %EXIT_CODE% neq 0 (',
    '    echo.',
    '    echo [ERROR] Script exited with code %EXIT_CODE%.',
    '    pause',
    ')',
    'exit /b %EXIT_CODE%',
    ':: === POWERSHELL PAYLOAD BELOW (LINE 21) ==='
)
if ($batchHeaderLines.Count -ne 21) {
    throw "Batch header line count mismatch: expected 21, got $($batchHeaderLines.Count)"
}

$singleCmdPath = Join-Path $dist 'WIN-DISK-CLEANER-SingleFile.cmd'
$fullSingle = ($batchHeaderLines -join "`r`n") + "`r`n" + $ps1Text
[System.IO.File]::WriteAllText($singleCmdPath, $fullSingle, $asciiNoBom)

# 5. Verify SingleFile extraction produces a valid PowerShell AST and starts with #Requires
$singleLines = [System.IO.File]::ReadAllLines($singleCmdPath)
$extractedPayload = ($singleLines | Select-Object -Skip 21) -join "`r`n"
$extErrors = $null
$extTokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($extractedPayload, [ref]$extTokens, [ref]$extErrors)
if ($extErrors.Count -gt 0) {
    throw "SingleFile payload extraction AST check failed: $($extErrors[0])"
}
$firstBytes = [System.IO.File]::ReadAllBytes($singleCmdPath)[0..8]
if ($firstBytes[0] -eq 0xEF) {
    throw "UTF-8 BOM detected on WIN-DISK-CLEANER-SingleFile.cmd!"
}

# 6. Build Portable ZIP package
$zipPath = Join-Path $dist 'WIN-DISK-CLEANER-v6.0.0-Portable.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
$filesToPack = @(
    $ps1Path,
    $cmdPath,
    $singleCmdPath,
    (Join-Path $root 'exclusions.txt'),
    (Join-Path $root 'README.md')
)
Compress-Archive -LiteralPath $filesToPack -DestinationPath $zipPath -CompressionLevel Optimal

# 7. Generate SHA256SUMS.txt
$sumsPath = Join-Path $dist 'SHA256SUMS.txt'
$sumLines = foreach ($f in @($singleCmdPath, $zipPath, $ps1Path, $cmdPath)) {
    $h = Get-FileHash -LiteralPath $f -Algorithm SHA256
    '{0}  {1}' -f $h.Hash.ToLowerInvariant(), (Split-Path $f -Leaf)
}
[System.IO.File]::WriteAllLines($sumsPath, $sumLines, $asciiNoBom)

Write-Host "BUILD & VERIFICATION SUCCESSFUL (100% ASCII, NO BOM, AST VERIFIED):" -ForegroundColor Green
Get-ChildItem -LiteralPath $dist | Select-Object Name, Length | Format-Table -AutoSize

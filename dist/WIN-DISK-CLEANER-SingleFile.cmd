@echo off
setlocal
title WIN-DISK-CLEANER v6.1 - Self-Contained Edition
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [INFO] Requesting Administrator privileges...
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set "TEMP_PS1=%TEMP%\Win11-DiskCleanup_%RANDOM%.ps1"
more +21 "%~f0" > "%TEMP_PS1%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TEMP_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"
del /f /q "%TEMP_PS1%" >nul 2>&1
if %EXIT_CODE% neq 0 (
    echo.
    echo [ERROR] Script exited with code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%
:: === POWERSHELL PAYLOAD BELOW (LINE 21) ===
#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Safe System Disk Cleanup, Driver Backup, Quarantine, Repair & Reporting Utility (Plan v6.1)
.DESCRIPTION
    Scan-first, confirm-all Windows 11 cleanup utility with:
    - Self-elevation and automatic relaunch in Windows PowerShell 5.1 if started from PowerShell 7
    - Pre-Scan read-only system health checks (OS build, pending reboot, WU busy, disk health, dirty bit, battery, VSS)
    - Safe stack-based file walker that never traverses junctions or symlinks (ReparsePoints)
    - Quick / Standard / Deep / Manual confirmation presets (every category still confirmed; Irreversible requires 'YES')
    - Mandatory verified Driver Backup & Windows Event Log Backup
    - 7-day Quarantine mode on a secondary drive with manifest.csv and one-click restore script
    - Wildcard exclusion list (inline + exclusions.txt)
    - Nested progress bars, console title status bar, in-place status line, and Windows Terminal taskbar progress
    - System Repair mode (DISM ScanHealth / RestoreHealth + SFC /scannow)
    - Read-only disk analysis reports (Top 25 folders/files, Old Downloads >180d, Installed apps by size)
    - Self-contained 1080p HTML report + persistent history.csv
#>
[CmdletBinding()]
param(
    [Parameter()][ValidateRange(0, 8760)]
    [int]$MinAgeHours = 24,

    [Parameter()][ValidateRange(1, 9999)]
    [int]$SagesetNumber = 500,

    [Parameter()]
    [string]$DriverBackupPath,

    [Parameter()]
    [string]$EventLogBackupPath,

    [Parameter()]
    [string]$ReportPath,

    [Parameter()]
    [string]$ReportCopyPath,

    [Parameter()][ValidateRange(5, 360)]
    [int]$CleanMgrTimeoutMin = 60,

    [Parameter()][ValidateRange(1, 365)]
    [int]$QuarantineDays = 7,

    [Parameter()]
    [string]$RepairSource,

    [Parameter()]
    [switch]$NoProgress
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# USER CONFIGURATION: CUSTOM CLEANUP PATHS & EXCLUSIONS
# ============================================================================
# Empty by default. Uncomment and edit to add custom cache folders (contents only will be removed).
$CustomPaths = @(
    # @{ Name = 'MyApp Cache'; Path = Join-Path $env:LOCALAPPDATA 'MyApp\Cache'; Process = 'myapp*' }
)

# Wildcard patterns never touched during scan or cleanup (also loaded from exclusions.txt next to script).
$Exclusions = @(
    # "$env:LOCALAPPDATA\Temp\MyImportantTool\*"
    # '*.vhdx'
)

# ============================================================================
# ELEVATION & POWERSHELL 5.1 ENFORCEMENT
# ============================================================================
function Test-IsAdministrator {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevationAndHostCheck {
    param([hashtable]$BoundParams, [string]$ScriptPath)

    $needs51    = ($PSVersionTable.PSEdition -eq 'Core')
    $needsAdmin = -not (Test-IsAdministrator)

    if (-not $needs51 -and -not $needsAdmin) { return }

    # If running inside a compiled EXE (ps2exe) where $ScriptPath is empty, check admin only
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        if ($needsAdmin) {
            Write-Host '[ERROR] Please right-click and select "Run as administrator".' -ForegroundColor Red
            Read-Host 'Press Enter to exit'
            exit 1
        }
        return
    }

    try { Unblock-File -LiteralPath $ScriptPath -ErrorAction SilentlyContinue } catch { }

    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPs)) { $winPs = 'powershell.exe' }

    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add('-NoProfile')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add(('"{0}"' -f $ScriptPath))

    foreach ($kv in $BoundParams.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList.Add("-$($kv.Key)") }
        } elseif ($null -ne $kv.Value -and "$($kv.Value)" -ne '') {
            $escaped = "$($kv.Value)" -replace '"', '\"'
            $argList.Add("-$($kv.Key)")
            $argList.Add(('"{0}"' -f $escaped))
        }
    }

    if ($needs51) {
        Write-Host '[INFO] Relaunching in Windows PowerShell 5.1 for native cmdlet compatibility...' -ForegroundColor Yellow
    }
    if ($needsAdmin) {
        Write-Host '[INFO] Administrator privileges required. Requesting UAC elevation...' -ForegroundColor Yellow
    }

    $startParams = @{
        FilePath     = $winPs
        ArgumentList = ($argList -join ' ')
        Wait         = $true
    }
    if ($needsAdmin) { $startParams['Verb'] = 'RunAs' }

    try {
        Start-Process @startParams | Out-Null
    } catch {
        Write-Host "[ERROR] Failed to relaunch elevated session: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    exit 0
}

$resolvedSelfPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($resolvedSelfPath)) { $resolvedSelfPath = $PSCommandPath }
Invoke-SelfElevationAndHostCheck -BoundParams $PSBoundParameters -ScriptPath $resolvedSelfPath

# ============================================================================
# SLEEP PREVENTION (P/INVOKE)
# ============================================================================
Add-Type -Namespace Win32 -Name PowerUtil -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction SilentlyContinue

function Set-PreventSleep {
    param([bool]$Enable)
    try {
        $ES_CONTINUOUS      = [uint32]2147483648 # 0x80000000
        $ES_SYSTEM_REQUIRED = [uint32]1          # 0x00000001
        if ($Enable) {
            [void][Win32.PowerUtil]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
        } else {
            [void][Win32.PowerUtil]::SetThreadExecutionState($ES_CONTINUOUS)
        }
    } catch { }
}

# ============================================================================
# GLOBALS, LOGGING & UI HELPERS
# ============================================================================
$script:SysDrive       = ($env:SystemDrive).TrimEnd('\')
$script:SysDriveLetter = $script:SysDrive.TrimEnd(':')
$script:DataRoot       = Join-Path $env:ProgramData 'Win11DiskCleanup'
$script:LogDir         = Join-Path $script:DataRoot 'logs'
$script:ReportDir      = Join-Path $script:DataRoot 'reports'
$script:HistoryCsv     = Join-Path $script:DataRoot 'history.csv'
$script:Timestamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile        = Join-Path $script:LogDir "cleanup_$($script:Timestamp).log"
$script:HtmlReportFile = Join-Path $script:ReportDir "report_$($script:Timestamp).html"
$script:OriginalTitle  = $Host.UI.RawUI.WindowTitle
$script:RunStopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
$script:UiStopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
$script:Stats = @{
    StageIndex      = 1
    StageTotal      = 7
    StageName       = 'Initializing'
    EstimatedBytes  = [int64]0
    FreedBytes      = [int64]0
    QuarantinedBytes= [int64]0
    LockedCount     = 0
    ExcludedCount   = 0
    ErrorCount      = 0
}

function Initialize-DirectoriesAndLog {
    foreach ($d in @($script:DataRoot, $script:LogDir, $script:ReportDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    # Keep last 10 logs
    $oldLogs = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'cleanup_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 9)
    foreach ($ol in $oldLogs) {
        Remove-Item -LiteralPath $ol.FullName -Force -ErrorAction SilentlyContinue
    }
    Write-Log -Message "=== Win11 Disk Cleanup v6 started by $env:USERNAME on $env:COMPUTERNAME ===" -Level 'INFO'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DELETE','QUARANTINE','SKIP')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1,-10}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Format-Bytes {
    param([int64]$Bytes)
    $sign = if ($Bytes -lt 0) { '-' } else { '' }
    $abs  = [math]::Abs($Bytes)
    if ($abs -ge 1TB) { return ('{0}{1:N2} TB' -f $sign, ($abs / 1TB)) }
    if ($abs -ge 1GB) { return ('{0}{1:N2} GB' -f $sign, ($abs / 1GB)) }
    if ($abs -ge 1MB) { return ('{0}{1:N1} MB' -f $sign, ($abs / 1MB)) }
    if ($abs -ge 1KB) { return ('{0}{1:N1} KB' -f $sign, ($abs / 1KB)) }
    return "$sign$abs B"
}

function Format-MiddleEllipsis {
    param([string]$Text, [int]$MaxLength = 60)
    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $MaxLength) { return $Text }
    if ($MaxLength -lt 10) { return $Text.Substring(0, $MaxLength) }
    $half = [math]::Floor(($MaxLength - 3) / 2)
    return ($Text.Substring(0, $half) + '...' + $Text.Substring($Text.Length - $half))
}

function Set-TaskbarProgress {
    param(
        [ValidateSet('None','Normal','Error','Indeterminate')]
        [string]$State = 'Normal',
        [int]$Percent = 0
    )
    if ($NoProgress -or -not $env:WT_SESSION) { return }
    $code = switch ($State) {
        'None'          { '0' }
        'Normal'        { "1;$Percent" }
        'Error'         { "2;$Percent" }
        'Indeterminate' { '3' }
    }
    $esc = [char]27
    $bel = [char]7
    Write-Host -NoNewline "$esc]9;4;$code$bel"
}

function Update-StatusBar {
    param([int]$OverallPercent = 0)
    $elapsed = $script:RunStopwatch.Elapsed.ToString('hh\:mm\:ss')
    $freed   = Format-Bytes ($script:Stats.FreedBytes + $script:Stats.QuarantinedBytes)
    $title   = 'Win11 Disk Cleanup - Stage {0}/{1}: {2} - {3}% - Freed {4} - {5}' -f `
        $script:Stats.StageIndex, $script:Stats.StageTotal, $script:Stats.StageName, $OverallPercent, $freed, $elapsed
    try { $Host.UI.RawUI.WindowTitle = $title } catch { }
}

function Write-StatusLine {
    $width = 100
    try { $width = [math]::Max(40, [Console]::WindowWidth - 1) } catch { }
    $elapsed = $script:RunStopwatch.Elapsed.ToString('hh\:mm\:ss')
    $reclaimed = Format-Bytes ($script:Stats.FreedBytes + $script:Stats.QuarantinedBytes)
    $est       = Format-Bytes $script:Stats.EstimatedBytes
    $line = ' STATUS | Stage {0}/{1} {2} | Reclaimed {3} / Est {4} | Locked {5} | Errors {6} | {7}' -f `
        $script:Stats.StageIndex, $script:Stats.StageTotal, $script:Stats.StageName, `
        $reclaimed, $est, $script:Stats.LockedCount, $script:Stats.ErrorCount, $elapsed
    if ($line.Length -gt $width) {
        $line = $line.Substring(0, [math]::Max(1, $width - 3)) + '...'
    } else {
        $line = $line.PadRight($width)
    }
    Write-Host $line -ForegroundColor DarkCyan
}

function Update-UiProgress {
    param(
        [int]$OverallPercent = -1,
        [string]$CategoryName = '',
        [int]$CategoryPercent = -1,
        [string]$ItemText = '',
        [switch]$Force
    )
    if ($NoProgress) { return }
    if (-not $Force -and $script:UiStopwatch.ElapsedMilliseconds -lt 200) { return }
    $script:UiStopwatch.Restart()

    if ($OverallPercent -ge 0) {
        $pct = [math]::Min(100, [math]::Max(0, $OverallPercent))
        Write-Progress -Id 0 -Activity ("Stage {0}/{1}: {2}" -f $script:Stats.StageIndex, $script:Stats.StageTotal, $script:Stats.StageName) `
            -Status "$pct% Complete" -PercentComplete $pct
        Update-StatusBar -OverallPercent $pct
        Set-TaskbarProgress -State 'Normal' -Percent $pct
    }
    if ($CategoryName -ne '') {
        $cpct = if ($CategoryPercent -ge 0) { [math]::Min(100, [math]::Max(0, $CategoryPercent)) } else { 0 }
        Write-Progress -Id 1 -ParentId 0 -Activity $CategoryName -Status "$cpct%" -PercentComplete $cpct
    }
    if ($ItemText -ne '') {
        Write-Progress -Id 2 -ParentId 1 -Activity 'Current Item' -Status (Format-MiddleEllipsis -Text $ItemText -MaxLength 70)
    }
}

function Complete-AllProgress {
    if (-not $NoProgress) {
        Write-Progress -Id 2 -Activity 'Done' -Completed -ErrorAction SilentlyContinue
        Write-Progress -Id 1 -Activity 'Done' -Completed -ErrorAction SilentlyContinue
        Write-Progress -Id 0 -Activity 'Done' -Completed -ErrorAction SilentlyContinue
        Set-TaskbarProgress -State 'None'
    }
}

# ============================================================================
# EXCLUSIONS & SAFETY ALLOWLIST / BLOCKLIST
# ============================================================================
function Initialize-Exclusions {
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $Exclusions) {
        if (-not [string]::IsNullOrWhiteSpace($e)) { $list.Add($e.Trim()) }
    }
    $baseDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        try { $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory } catch { $baseDir = '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($baseDir)) {
        $extFile = Join-Path $baseDir 'exclusions.txt'
        if (Test-Path -LiteralPath $extFile) {
            foreach ($line in (Get-Content -LiteralPath $extFile -ErrorAction SilentlyContinue)) {
                $trimmed = $line.Trim()
                if ($trimmed -ne '' -and -not $trimmed.StartsWith('#')) {
                    $list.Add([Environment]::ExpandEnvironmentVariables($trimmed))
                }
            }
        }
    }
    $script:ActiveExclusions = $list.ToArray()
}

function Test-IsExcluded {
    param([Parameter(Mandatory)][string]$FullPath)
    foreach ($pattern in $script:ActiveExclusions) {
        if ($FullPath -like $pattern) { return $true }
    }
    return $false
}

function Get-BlocklistedRoots {
    $roots = @(
        "$($script:SysDrive)\",
        $env:SystemRoot,
        "$env:SystemRoot\System32",
        "$env:SystemRoot\SysWOW64",
        "$env:SystemRoot\WinSxS",
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        "$($script:SysDrive)\Users",
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    )
    $subFolders = @('Desktop','Documents','Downloads','Pictures','Videos','Music','OneDrive')
    foreach ($sf in $subFolders) {
        $roots += (Join-Path $env:USERPROFILE $sf)
    }
    return ($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd('\') })
}

function Test-CustomPathIsSafe {
    param([Parameter(Mandatory)][string]$PathToCheck)
    if ([string]::IsNullOrWhiteSpace($PathToCheck)) { return @{ Safe = $false; Reason = 'Empty path' } }
    if (-not (Test-Path -LiteralPath $PathToCheck -PathType Container)) {
        return @{ Safe = $false; Reason = 'Folder does not exist' }
    }
    try {
        $item = Get-Item -LiteralPath $PathToCheck -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            return @{ Safe = $false; Reason = 'Folder is a junction or symlink (ReparsePoint)' }
        }
        $full = $item.FullName.TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') {
            return @{ Safe = $false; Reason = 'Drive root is forbidden' }
        }
        foreach ($blocked in (Get-BlocklistedRoots)) {
            if ($full -ieq $blocked) {
                return @{ Safe = $false; Reason = "Matches protected root: $blocked" }
            }
        }
        foreach ($protTree in @("$env:SystemRoot\System32", "$env:SystemRoot\WinSxS", $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($protTree -and $full.StartsWith($protTree, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Safe = $false; Reason = "Inside protected system tree: $protTree" }
            }
        }
        return @{ Safe = $true; FullPath = $full; Reason = 'OK' }
    } catch {
        return @{ Safe = $false; Reason = $_.Exception.Message }
    }
}

function Test-ChildUnderAllowedRoot {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )
    foreach ($root in $AllowedRoots) {
        $normRoot = $root.TrimEnd('\') + '\'
        if ($ChildPath.StartsWith($normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# ============================================================================
# SAFE STACK-BASED FILE WALKER (NO REPARSE POINT TRAVERSAL)
# ============================================================================
function Get-FilesSafe {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [string]$FileFilter = '*',
        [int]$MinAgeHoursFilter = 0,
        [string]$CategoryName = 'Scanning'
    )
    $files      = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $totalBytes = [int64]0
    $excluded   = 0
    $cutoffUtc  = if ($MinAgeHoursFilter -gt 0) { (Get-Date).ToUniversalTime().AddHours(-$MinAgeHoursFilter) } else { [datetime]::MaxValue }
    $stack      = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'

    foreach ($r in $Roots) {
        if ([string]::IsNullOrWhiteSpace($r) -or -not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        try {
            $di = New-Object System.IO.DirectoryInfo($r)
            if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                $stack.Push($di)
            } else {
                Write-Log -Message "Skipped reparse-point root: $r" -Level 'SKIP'
            }
        } catch { }
    }

    $visitedDirs = 0
    while ($stack.Count -gt 0) {
        $currentDir = $stack.Pop()
        $visitedDirs++
        Update-UiProgress -CategoryName $CategoryName -ItemText $currentDir.FullName

        try {
            foreach ($fi in $currentDir.EnumerateFiles($FileFilter)) {
                if (($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($MinAgeHoursFilter -gt 0 -and $fi.LastWriteTimeUtc -gt $cutoffUtc) { continue }
                if (Test-IsExcluded -FullPath $fi.FullName) {
                    $excluded++
                    continue
                }
                $len = [int64]$fi.Length
                $totalBytes += $len
                $files.Add([pscustomobject]@{
                    FullName = $fi.FullName
                    Length   = $len
                })
            }
        } catch { }

        if ($FileFilter -eq '*') {
            try {
                foreach ($sub in $currentDir.EnumerateDirectories()) {
                    if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $stack.Push($sub)
                    } else {
                        Write-Log -Message "Skipped junction/symlink directory: $($sub.FullName)" -Level 'SKIP'
                    }
                }
            } catch { }
        }
    }

    return [pscustomobject]@{
        Files         = $files
        TotalBytes    = $totalBytes
        ExcludedCount = $excluded
    }
}

# ============================================================================
# STAGE 1: PRE-SCAN SYSTEM HEALTH CHECKS (READ-ONLY)
# ============================================================================
function Invoke-PreScan {
    $script:Stats.StageIndex = 1
    $script:Stats.StageName  = 'Pre-Scan Health Checks'
    Update-UiProgress -OverallPercent 5 -CategoryName 'Pre-Scan' -CategoryPercent 0 -Force

    $checks   = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $disabled = @{}
    $hasBlock = $false

    # 1. OS Build Check (Windows 11 >= 22000)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $build = if ($os) { [int]$os.BuildNumber } else { 0 }
    if ($build -lt 22000) {
        $checks.Add([pscustomobject]@{ Check = 'Windows 11 Build'; Status = 'BLOCK'; Detail = "Build $build detected (Windows 11 22000+ required)" })
        $hasBlock = $true
    } else {
        $checks.Add([pscustomobject]@{ Check = 'Windows 11 Build'; Status = 'OK'; Detail = "$($os.Caption) (Build $build)" })
    }

    # 2. Pending Reboot Check
    $rebootPending = $false
    $cbsReboot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wuReboot  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if ((Test-Path $cbsReboot) -or (Test-Path $wuReboot)) { $rebootPending = $true }
    if ($rebootPending) {
        $checks.Add([pscustomobject]@{ Check = 'Pending Reboot'; Status = 'WARN'; Detail = 'Reboot pending; DISM categories disabled for safety' })
        $disabled['DISM_StartComponentCleanup'] = 'Pending system reboot'
        $disabled['DISM_ResetBase']             = 'Pending system reboot'
    } else {
        $checks.Add([pscustomobject]@{ Check = 'Pending Reboot'; Status = 'OK'; Detail = 'No pending reboot detected' })
    }

    # 3. Windows Update / Servicing Activity
    $busyProcs = @(Get-Process -Name 'TiWorker','TrustedInstaller','MoUsoCoreWorker' -ErrorAction SilentlyContinue)
    if ($busyProcs.Count -gt 0) {
        $names = ($busyProcs | Select-Object -ExpandProperty Name -Unique) -join ', '
        $checks.Add([pscustomobject]@{ Check = 'Servicing Activity'; Status = 'WARN'; Detail = "Active ($names); WU & DISM categories disabled" })
        $disabled['WU_DownloadCache']           = "Servicing active ($names)"
        $disabled['DISM_StartComponentCleanup'] = "Servicing active ($names)"
        $disabled['DISM_ResetBase']             = "Servicing active ($names)"
    } else {
        $checks.Add([pscustomobject]@{ Check = 'Servicing Activity'; Status = 'OK'; Detail = 'Idle' })
    }

    # 4. Concurrent Cleanup Check
    $cleanProcs = @(Get-Process -Name 'cleanmgr','dism' -ErrorAction SilentlyContinue)
    if ($cleanProcs.Count -gt 0) {
        $checks.Add([pscustomobject]@{ Check = 'Concurrent Cleanup'; Status = 'BLOCK'; Detail = 'cleanmgr or dism is already running' })
        $hasBlock = $true
    } else {
        $checks.Add([pscustomobject]@{ Check = 'Concurrent Cleanup'; Status = 'OK'; Detail = 'None running' })
    }

    # 5. Power / Battery Status
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if ($battery -and $battery.BatteryStatus -eq 1) {
        $checks.Add([pscustomobject]@{ Check = 'Power Source'; Status = 'WARN'; Detail = "Running on battery ($($battery.EstimatedChargeRemaining)%)" })
    } else {
        $checks.Add([pscustomobject]@{ Check = 'Power Source'; Status = 'OK'; Detail = 'AC Power / Desktop' })
    }

    # 6. Physical Disk Health & SSD Detection
    $isSsd = $false
    $diskHealth = 'Unknown'
    try {
        $part = Get-Partition -DriveLetter $script:SysDriveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        $diskHealth = "$($disk.HealthStatus)"
        $phys = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($disk.Number)" } | Select-Object -First 1
        if ($phys -and $phys.MediaType -eq 'SSD') { $isSsd = $true }
    } catch { }

    if ($diskHealth -ieq 'Unhealthy') {
        $checks.Add([pscustomobject]@{ Check = 'System Disk Health'; Status = 'BLOCK'; Detail = 'Disk reports UNHEALTHY. Back up data immediately.' })
        $hasBlock = $true
    } elseif ($diskHealth -ieq 'Healthy') {
        $checks.Add([pscustomobject]@{ Check = 'System Disk Health'; Status = 'OK'; Detail = "Healthy ($(if ($isSsd) {'SSD'} else {'HDD/Virtual'}))" })
    } else {
        $checks.Add([pscustomobject]@{ Check = 'System Disk Health'; Status = 'WARN'; Detail = "Status: $diskHealth" })
    }

    # 7. Dirty Bit Check
    $dirtyOut = ''
    try { $dirtyOut = (& fsutil.exe dirty query $script:SysDrive 2>&1) -join ' ' } catch { }
    if ($dirtyOut -match 'is dirty') {
        $checks.Add([pscustomobject]@{ Check = 'NTFS Dirty Bit'; Status = 'WARN'; Detail = 'Volume is marked dirty; run chkdsk' })
    } else {
        $checks.Add([pscustomobject]@{ Check = 'NTFS Dirty Bit'; Status = 'OK'; Detail = 'Clean' })
    }

    # 8. System Restore Status
    $srEnabled = $false
    try {
        $rp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -ErrorAction SilentlyContinue
        if ($rp -and $rp.RPSessionInterval -ge 1) { $srEnabled = $true }
    } catch { }
    $checks.Add([pscustomobject]@{
        Check  = 'System Protection'
        Status = 'INFO'
        Detail = if ($srEnabled) { 'Enabled (Restore point can be created)' } else { 'Disabled on system drive' }
    })

    # 9. Free Space Snapshot & Hibernation Info
    $vol = Get-Volume -DriveLetter $script:SysDriveLetter -ErrorAction SilentlyContinue
    $freeBefore = if ($vol) { [int64]$vol.SizeRemaining } else { [int64](Get-PSDrive $script:SysDriveLetter).Free }
    $totalSize  = if ($vol) { [int64]$vol.Size } else { [int64]0 }
    $checks.Add([pscustomobject]@{
        Check  = "System Drive ($($script:SysDrive))"
        Status = 'INFO'
        Detail = ('Free: {0} / Total: {1}' -f (Format-Bytes $freeBefore), (Format-Bytes $totalSize))
    })

    $hiberFile = Join-Path "$($script:SysDrive)\" 'hiberfil.sys'
    if (Test-Path -LiteralPath $hiberFile) {
        $hLen = (Get-Item -LiteralPath $hiberFile -Force).Length
        $checks.Add([pscustomobject]@{
            Check  = 'Hibernation File'
            Status = 'INFO'
            Detail = ('{0} (Tip: powercfg /h off reclaims this if hibernation is unused)' -f (Format-Bytes $hLen))
        })
    }

    Update-UiProgress -OverallPercent 10 -CategoryName 'Pre-Scan Complete' -CategoryPercent 100 -Force

    Write-Host "`n==================== PRE-SCAN SYSTEM HEALTH CHECKS ====================" -ForegroundColor Cyan
    foreach ($c in $checks) {
        $color = switch ($c.Status) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'BLOCK' { 'Red' }
            default { 'Gray' }
        }
        Write-Host (' [{0,-5}] {1,-24} : {2}' -f $c.Status, $c.Check, $c.Detail) -ForegroundColor $color
        Write-Log -Message "PreScan [$($c.Status)] $($c.Check): $($c.Detail)" -Level ($(if ($c.Status -eq 'BLOCK') {'ERROR'} elseif ($c.Status -eq 'WARN') {'WARN'} else {'INFO'}))
    }
    Write-Host "=======================================================================`n" -ForegroundColor Cyan

    return [pscustomobject]@{
        Checks             = $checks
        DisabledCategories = $disabled
        HasBlocker         = $hasBlock
        IsSsd              = $isSsd
        SystemRestoreOn    = $srEnabled
        FreeSpaceBefore    = $freeBefore
        TotalDriveSize     = $totalSize
    }
}

# ============================================================================
# QUARANTINE EXPIRY PURGE CHECK
# ============================================================================
function Invoke-ExpiredQuarantinePurge {
    $cutoff = (Get-Date).AddDays(-$QuarantineDays)
    $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
        $_.DriveLetter -and $_.DriveType -in @('Fixed','Removable') -and $_.DriveLetter -ne $script:SysDriveLetter
    })
    foreach ($v in $vols) {
        $qRoot = "$($v.DriveLetter):\Win11Quarantine"
        if (-not (Test-Path -LiteralPath $qRoot)) { continue }
        $expired = @(Get-ChildItem -LiteralPath $qRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt $cutoff })
        foreach ($dir in $expired) {
            $scan = Get-FilesSafe -Roots @($dir.FullName) -CategoryName 'Checking expired quarantine'
            Write-Host ("[QUARANTINE] Expired set found: {0} ({1}, created {2:yyyy-MM-dd})" -f $dir.FullName, (Format-Bytes $scan.TotalBytes), $dir.CreationTime) -ForegroundColor Yellow
            $ans = Read-Host "Purge this expired quarantine folder permanently? [y/N]"
            if ($ans -match '^[Yy]$') {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log -Message "Purged expired quarantine folder: $($dir.FullName)" -Level 'DELETE'
                Write-Host "  -> Purged $($dir.FullName)" -ForegroundColor Green
            }
        }
    }
}

# ============================================================================
# OLD DRIVER PACKAGE SCANNER (PNPUTIL)
# ============================================================================
function Get-OldDriverPackages {
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    $out  = @(& pnputil.exe /enum-drivers 2>$null)
    $pkgs = New-Object 'System.Collections.Generic.List[pscustomobject]'

    $curr = @{}
    foreach ($line in $out) {
        if ($line -match '^\s*[^:]+:\s*(oem\d+\.inf)\s*$') {
            if ($curr.ContainsKey('PublishedName')) { $pkgs.Add([pscustomobject]$curr); $curr = @{} }
            $curr['PublishedName'] = $Matches[1].ToLowerInvariant()
        } elseif ($line -match '^\s*[^:]+:\s*(.+\.inf)\s*$' -and -not $curr.ContainsKey('OriginalName')) {
            $curr['OriginalName'] = $Matches[1].Trim().ToLowerInvariant()
        } elseif ($line -match ':\s*(\d{2}/\d{2}/\d{4})\s+([0-9\.]+)\s*$') {
            $curr['DriverDateStr'] = $Matches[1]
            $curr['DriverVersion'] = $Matches[2]
            $parsedDate = [datetime]::MinValue
            [void][datetime]::TryParse($Matches[1], [ref]$parsedDate)
            $curr['DriverDate'] = $parsedDate
        }
    }
    if ($curr.ContainsKey('PublishedName')) { $pkgs.Add([pscustomobject]$curr) }

    # Group by OriginalName; only consider groups with 2+ packages, keep the newest Version/Date
    $superseded = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $totalBytes = [int64]0

    $groups = $pkgs | Where-Object { $_.OriginalName } | Group-Object OriginalName | Where-Object { $_.Count -gt 1 }
    foreach ($g in $groups) {
        $sorted = @($g.Group | Sort-Object -Property @{Expression={
            try { [version]$_.DriverVersion } catch { [version]'0.0.0.0' }
        }; Descending=$true}, @{Expression={$_.DriverDate}; Descending=$true})

        $oldList = $sorted | Select-Object -Skip 1
        foreach ($old in $oldList) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($old.OriginalName)
            $dirs = @(Get-ChildItem -LiteralPath $repo -Directory -Filter "$base.inf_*" -ErrorAction SilentlyContinue)
            $pkgBytes = [int64]0
            if ($dirs.Count -gt 0) {
                # Average folder size if multiple folders share base name
                $sum = [int64]0
                foreach ($d in $dirs) {
                    $s = Get-FilesSafe -Roots @($d.FullName) -CategoryName 'Measuring DriverStore'
                    $sum += $s.TotalBytes
                }
                $pkgBytes = [int64]($sum / [math]::Max(1, $g.Count))
            }
            $totalBytes += $pkgBytes
            $superseded.Add([pscustomobject]@{
                PublishedName = $old.PublishedName
                OriginalName  = $old.OriginalName
                DriverVersion = $old.DriverVersion
                EstBytes      = $pkgBytes
            })
        }
    }

    return [pscustomobject]@{
        Packages   = $superseded
        TotalBytes = $totalBytes
        AllCount   = $pkgs.Count
    }
}

# ============================================================================
# BUILD CATEGORY DEFINITIONS
# ============================================================================
function Get-TargetUserProfiles {
    param([bool]$IncludeAllUsers)
    $profiles = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $profiles.Add([pscustomobject]@{
        UserName = $env:USERNAME
        Root     = $env:USERPROFILE
        AppData  = $env:APPDATA
        LocalApp = $env:LOCALAPPDATA
    })
    if ($IncludeAllUsers) {
        $wmiProfs = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
            -not $_.Special -and $_.LocalPath -and ($_.LocalPath -ine $env:USERPROFILE)
        })
        foreach ($wp in $wmiProfs) {
            if (Test-Path -LiteralPath $wp.LocalPath) {
                $profiles.Add([pscustomobject]@{
                    UserName = Split-Path $wp.LocalPath -Leaf
                    Root     = $wp.LocalPath
                    AppData  = Join-Path $wp.LocalPath 'AppData\Roaming'
                    LocalApp = Join-Path $wp.LocalPath 'AppData\Local'
                })
            }
        }
    }
    return $profiles
}

function Get-CleanupCategories {
    param(
        [bool]$IncludeAllUsers,
        [hashtable]$DisabledMap
    )
    $profs = Get-TargetUserProfiles -IncludeAllUsers $IncludeAllUsers
    $cats  = New-Object 'System.Collections.Generic.List[pscustomobject]'

    # Helper to add category
    function Add-Cat {
        param(
            [string]$Id, [string]$Name, [string]$Risk, [string]$Method,
            [string[]]$Roots = @(), [string]$FileFilter = '*',
            [bool]$UseAgeFilter = $false, [bool]$CanQuarantine = $false,
            [string[]]$StopProcesses = @(), [string]$WarningText = '',
            [string[]]$PresetModes = @()
        )
        $disReason = if ($DisabledMap.ContainsKey($Id)) { $DisabledMap[$Id] } else { '' }
        $cats.Add([pscustomobject]@{
            Id              = $Id
            Name            = $Name
            Risk            = $Risk           # Safe, Moderate, Irreversible
            Method          = $Method         # Files, RecycleBin, DeliveryOpt, WUFiles, CleanMgr, OldDrivers, DISM_Component, DISM_ResetBase, VSS_Old, DevCaches, WindowsOld
            Roots           = @($Roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
            FileFilter      = $FileFilter
            UseAgeFilter    = $UseAgeFilter
            CanQuarantine   = $CanQuarantine
            StopProcesses   = $StopProcesses
            WarningText     = $WarningText
            PresetModes     = $PresetModes
            DisabledReason  = $disReason
            ScannedFiles    = @()
            DriverPackages  = @()
            EstimatedBytes  = [int64]0
            FileCount       = 0
            ExcludedCount   = 0
            Confirmed       = $false
        })
    }

    # 1. User & System Temp
    $tempRoots = @("$env:SystemRoot\Temp")
    foreach ($p in $profs) { $tempRoots += (Join-Path $p.LocalApp 'Temp') }
    Add-Cat -Id 'UserSystemTemp' -Name 'User & System Temp Files' -Risk 'Safe' -Method 'Files' `
        -Roots ($tempRoots | Select-Object -Unique) -UseAgeFilter $true -CanQuarantine $true `
        -PresetModes @('Quick','Standard','Deep')

    # 1b. Previous Backups Stored on System Drive (C:\DriverBackup, C:\EventLogBackup)
    $sysBackupRoots = @(
        (Join-Path "$($script:SysDrive)\" 'DriverBackup'),
        (Join-Path "$($script:SysDrive)\" 'EventLogBackup')
    )
    Add-Cat -Id 'SysDriveBackups' -Name "Driver/EventLog Backups Stored on $($script:SysDrive)" -Risk 'Safe' -Method 'Files' `
        -Roots $sysBackupRoots -CanQuarantine $false `
        -WarningText "Removes DriverBackup / EventLogBackup folders that were saved onto $($script:SysDrive) and are consuming system drive space." `
        -PresetModes @('Quick','Standard','Deep')

    # 1c. Hibernation File (hiberfil.sys via powercfg /h off)
    $hiberFile = Join-Path "$($script:SysDrive)\" 'hiberfil.sys'
    Add-Cat -Id 'HibernationFile' -Name 'Hibernation File (hiberfil.sys -> powercfg /h off)' -Risk 'Moderate' -Method 'HibernationOff' `
        -Roots @("$($script:SysDrive)\") -FileFilter 'hiberfil.sys' `
        -WarningText 'Disables Hibernation (powercfg /h off) to immediately reclaim the entire hiberfil.sys size (typically 6-16 GB).' `
        -PresetModes @('Standard','Deep')

    # 2. Windows Error Reporting (WER)
    $werRoots = @(
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\Temp"
    )
    foreach ($p in $profs) { $werRoots += (Join-Path $p.LocalApp 'Microsoft\Windows\WER') }
    Add-Cat -Id 'WER' -Name 'Windows Error Reporting (WER)' -Risk 'Safe' -Method 'Files' `
        -Roots $werRoots -UseAgeFilter $true -CanQuarantine $true -PresetModes @('Quick','Standard','Deep')

    # 3. Application CrashDumps
    $dumpRoots = @()
    foreach ($p in $profs) { $dumpRoots += (Join-Path $p.LocalApp 'CrashDumps') }
    Add-Cat -Id 'CrashDumps' -Name 'Application Crash Dumps' -Risk 'Safe' -Method 'Files' `
        -Roots $dumpRoots -UseAgeFilter $true -CanQuarantine $true -PresetModes @('Quick','Standard','Deep')

    # 4. DirectX Shader Cache
    $d3dRoots = @()
    foreach ($p in $profs) { $d3dRoots += (Join-Path $p.LocalApp 'D3DSCache') }
    Add-Cat -Id 'D3DSCache' -Name 'DirectX Shader Cache' -Risk 'Safe' -Method 'Files' `
        -Roots $d3dRoots -CanQuarantine $true -PresetModes @('Quick','Standard','Deep')

    # 5. Explorer Thumbnail Cache
    $thumbRoots = @()
    foreach ($p in $profs) { $thumbRoots += (Join-Path $p.LocalApp 'Microsoft\Windows\Explorer') }
    Add-Cat -Id 'ThumbCache' -Name 'Explorer Thumbnail Cache' -Risk 'Safe' -Method 'Files' `
        -Roots $thumbRoots -FileFilter 'thumbcache_*.db' -CanQuarantine $false -PresetModes @('Quick','Standard','Deep')

    # 6. Recycle Bin
    Add-Cat -Id 'RecycleBin' -Name 'Recycle Bin (All Fixed Drives)' -Risk 'Safe' -Method 'RecycleBin' `
        -PresetModes @('Quick','Standard','Deep')

    # 7. Delivery Optimization Cache
    $doRoot = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    Add-Cat -Id 'DeliveryOpt' -Name 'Delivery Optimization Cache' -Risk 'Safe' -Method 'DeliveryOpt' `
        -Roots @($doRoot) -PresetModes @('Quick','Standard','Deep')

    # 8. Windows Update Download Cache
    Add-Cat -Id 'WU_DownloadCache' -Name 'Windows Update Download Cache' -Risk 'Safe' -Method 'WUFiles' `
        -Roots @("$env:SystemRoot\SoftwareDistribution\Download") -CanQuarantine $true `
        -PresetModes @('Quick','Standard','Deep')

    # 9. Browser Caches (Cache folders only - never cookies/history/logins)
    $browserRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $profs) {
        $chromiumBases = @(
            (Join-Path $p.LocalApp 'Microsoft\Edge\User Data'),
            (Join-Path $p.LocalApp 'Google\Chrome\User Data'),
            (Join-Path $p.LocalApp 'BraveSoftware\Brave-Browser\User Data')
        )
        foreach ($cb in $chromiumBases) {
            if (Test-Path -LiteralPath $cb) {
                $profDirs = @(Get-ChildItem -LiteralPath $cb -Directory -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -eq 'Default' -or $_.Name -like 'Profile *'
                })
                foreach ($pd in $profDirs) {
                    foreach ($sub in @('Cache\Cache_Data','Code Cache','GPUCache')) {
                        $cand = Join-Path $pd.FullName $sub
                        if (Test-Path -LiteralPath $cand) { $browserRoots.Add($cand) }
                    }
                }
            }
        }
        $ffBase = Join-Path $p.LocalApp 'Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ffBase) {
            foreach ($fp in (Get-ChildItem -LiteralPath $ffBase -Directory -ErrorAction SilentlyContinue)) {
                $c2 = Join-Path $fp.FullName 'cache2'
                if (Test-Path -LiteralPath $c2) { $browserRoots.Add($c2) }
            }
        }
    }
    Add-Cat -Id 'BrowserCaches' -Name 'Browser Caches (Edge/Chrome/Brave/Firefox)' -Risk 'Safe' -Method 'Files' `
        -Roots $browserRoots.ToArray() -CanQuarantine $true -StopProcesses @('msedge','chrome','brave','firefox') `
        -PresetModes @('Quick','Standard','Deep')

    # 10. GPU Shader Caches (NVIDIA / AMD / Intel)
    $gpuRoots = @("$env:ProgramData\NVIDIA Corporation\NV_Cache")
    foreach ($p in $profs) {
        $gpuRoots += @(
            (Join-Path $p.LocalApp 'NVIDIA\DXCache'),
            (Join-Path $p.LocalApp 'NVIDIA\GLCache'),
            (Join-Path $p.LocalApp 'AMD\DxCache'),
            (Join-Path $p.LocalApp 'AMD\DxcCache'),
            (Join-Path $p.LocalApp 'AMD\VkCache'),
            (Join-Path $p.LocalApp 'Intel\ShaderCache')
        )
    }
    Add-Cat -Id 'GpuShaderCaches' -Name 'GPU Shader Caches (NVIDIA/AMD/Intel)' -Risk 'Safe' -Method 'Files' `
        -Roots $gpuRoots -CanQuarantine $true -PresetModes @('Quick','Standard','Deep')

    # 11. Leftover Extracted Driver Installers (C:\NVIDIA, C:\AMD, C:\Intel)
    $leftoverRoots = @()
    foreach ($cand in @("$($script:SysDrive)\NVIDIA", "$($script:SysDrive)\AMD", "$($script:SysDrive)\Intel")) {
        if (Test-Path -LiteralPath $cand) {
            $hasSetup = @(Get-ChildItem -LiteralPath $cand -Recurse -File -Include 'setup.exe','*.inf','*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($hasSetup.Count -gt 0) { $leftoverRoots += $cand }
        }
    }
    Add-Cat -Id 'LeftoverDriverDirs' -Name 'Leftover Extracted Driver Folders (C:\NVIDIA, AMD, Intel)' -Risk 'Moderate' -Method 'Files' `
        -Roots $leftoverRoots -UseAgeFilter $true -CanQuarantine $true `
        -WarningText 'Removes extracted installer files only (installed drivers are untouched).' `
        -PresetModes @('Standard','Deep')

    # 12. Windows Prefetch
    Add-Cat -Id 'Prefetch' -Name 'Windows Prefetch Cache' -Risk 'Moderate' -Method 'Files' `
        -Roots @("$env:SystemRoot\Prefetch") -CanQuarantine $true `
        -WarningText 'Next boot and initial app launches may be slightly slower while Windows rebuilds Prefetch.' `
        -PresetModes @('Deep')

    # 13. CBS & Setup Logs
    Add-Cat -Id 'CbsLogs' -Name 'CBS & DISM Servicing Logs' -Risk 'Moderate' -Method 'Files' `
        -Roots @("$env:SystemRoot\Logs\CBS") -UseAgeFilter $true -CanQuarantine $true `
        -WarningText 'Removes older servicing log files; active CBS.log is kept if locked.' `
        -PresetModes @('Deep')

    # 14. Developer Caches (npm, pip, NuGet, Yarn, Gradle, Go)
    $devRoots = @()
    foreach ($p in $profs) {
        $devRoots += @(
            (Join-Path $p.LocalApp 'npm-cache'),
            (Join-Path $p.LocalApp 'pip\Cache'),
            (Join-Path $p.Root '.nuget\packages'),
            (Join-Path $p.LocalApp 'Yarn\Cache'),
            (Join-Path $p.Root '.gradle\caches'),
            (Join-Path $p.LocalApp 'go-build')
        )
    }
    Add-Cat -Id 'DevCaches' -Name 'Developer Package Caches (npm/pip/NuGet/Gradle/Go)' -Risk 'Moderate' -Method 'Files' `
        -Roots $devRoots -CanQuarantine $true -StopProcesses @('java','gradle','node','dotnet') `
        -WarningText 'Packages will be re-downloaded on your next project build.' `
        -PresetModes @('Deep')

    # 15. App Caches (Teams, Discord, Spotify, Office File Cache)
    $appRoots = @()
    foreach ($p in $profs) {
        $appRoots += @(
            (Join-Path $p.AppData 'Microsoft\Teams\Cache'),
            (Join-Path $p.AppData 'Microsoft\Teams\Code Cache'),
            (Join-Path $p.AppData 'Microsoft\Teams\GPUCache'),
            (Join-Path $p.LocalApp 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'),
            (Join-Path $p.AppData 'discord\Cache\Cache_Data'),
            (Join-Path $p.AppData 'discord\Code Cache'),
            (Join-Path $p.AppData 'discord\GPUCache'),
            (Join-Path $p.LocalApp 'Spotify\Data'),
            (Join-Path $p.LocalApp 'Microsoft\Office\16.0\OfficeFileCache')
        )
    }
    Add-Cat -Id 'AppCaches' -Name 'App Caches (Teams / Discord / Spotify / Office)' -Risk 'Moderate' -Method 'Files' `
        -Roots $appRoots -UseAgeFilter $true -CanQuarantine $true -StopProcesses @('Teams','ms-teams','Discord','Spotify') `
        -WarningText 'Ensure no pending Office/OneDrive document uploads are waiting before clearing.' `
        -PresetModes @()

    # 16. Superseded Device Driver Packages (pnputil, mandatory backup)
    Add-Cat -Id 'OldDrivers' -Name 'Superseded Device Driver Packages (Backup Required)' -Risk 'Moderate' -Method 'OldDrivers' `
        -WarningText 'Removes older duplicate driver versions from DriverStore (newest version is kept; full driver backup runs first).' `
        -PresetModes @('Standard','Deep')

    # 17. DISM Component Store Cleanup (/StartComponentCleanup)
    Add-Cat -Id 'DISM_StartComponentCleanup' -Name 'WinSxS Component Store (DISM /StartComponentCleanup)' -Risk 'Moderate' -Method 'DISM_Component' `
        -WarningText 'Cleans superseded Windows component versions safely (keeps update uninstall ability).' `
        -PresetModes @('Standard','Deep')

    # 18. cleanmgr Temporary Setup Files
    Add-Cat -Id 'CleanMgr_TempSetup' -Name 'Disk Cleanup: Temporary Setup Files (cleanmgr)' -Risk 'Safe' -Method 'CleanMgr' `
        -PresetModes @('Quick','Standard','Deep')

    # 19. Windows Event Logs (wevtutil, mandatory backup before clearing)
    $evtxRoot = Join-Path $env:SystemRoot 'System32\winevt\Logs'
    Add-Cat -Id 'EventLogs' -Name 'Windows Event Logs (Backup Required Before Clear)' -Risk 'Moderate' -Method 'EventLogs' `
        -Roots @($evtxRoot) -FileFilter '*.evtx' `
        -WarningText 'Exports all .evtx logs to your chosen backup folder first, verifies the backup, then clears Event Logs via wevtutil.' `
        -PresetModes @('Deep')

    # 20. Windows Search Index Database (Windows.edb rebuild)
    $edbRoot = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
    Add-Cat -Id 'SearchIndex' -Name 'Windows Search Index Database (Windows.edb Rebuild)' -Risk 'Moderate' -Method 'SearchIndex' `
        -Roots @($edbRoot) -FileFilter 'Windows.edb' `
        -WarningText 'Stops Windows Search (WSearch), deletes bloated Windows.edb, and restarts WSearch to rebuild the index in the background.' `
        -PresetModes @('Deep')

    # 21. WSL2 & Docker Virtual Disks (ext4.vhdx compaction)
    $vhdxRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $profs) {
        $dockerWsl = Join-Path $p.LocalApp 'Docker\wsl'
        if (Test-Path -LiteralPath $dockerWsl) { $vhdxRoots.Add($dockerWsl) }
        $pkgsDir = Join-Path $p.LocalApp 'Packages'
        if (Test-Path -LiteralPath $pkgsDir) {
            foreach ($pkg in (Get-ChildItem -LiteralPath $pkgsDir -Directory -ErrorAction SilentlyContinue)) {
                $ls = Join-Path $pkg.FullName 'LocalState'
                if (Test-Path -LiteralPath (Join-Path $ls 'ext4.vhdx')) { $vhdxRoots.Add($ls) }
            }
        }
    }
    Add-Cat -Id 'WslVhdxCompact' -Name 'WSL2 & Docker Virtual Disks (ext4.vhdx Compaction)' -Risk 'Moderate' -Method 'WslVhdx' `
        -Roots $vhdxRoots.ToArray() -FileFilter '*.vhdx' `
        -WarningText 'Shuts down WSL2 cleanly and shrinks unused slack space inside ext4.vhdx files without deleting Linux files.' `
        -PresetModes @('Standard','Deep')

    # 22. Custom Extra Paths (user-configured)
    $idx = 0
    foreach ($cp in $CustomPaths) {
        $idx++
        $check = Test-CustomPathIsSafe -PathToCheck $cp.Path
        if (-not $check.Safe) {
            Write-Host ("[SKIP CUSTOM PATH] '{0}' ({1}) rejected: {2}" -f $cp.Name, $cp.Path, $check.Reason) -ForegroundColor Red
            Write-Log -Message "Rejected custom path '$($cp.Name)' ($($cp.Path)): $($check.Reason)" -Level 'WARN'
            continue
        }
        $procs = if ($cp.Process) { @($cp.Process) } else { @() }
        Add-Cat -Id "Custom_$idx" -Name "Custom: $($cp.Name)" -Risk 'Moderate' -Method 'Files' `
            -Roots @($check.FullPath) -UseAgeFilter $true -CanQuarantine $true -StopProcesses $procs `
            -WarningText "Custom folder contents in $($check.FullPath)" -PresetModes @('Deep')
    }

    # 20. IRREVERSIBLE: Old System Restore Points
    Add-Cat -Id 'VSS_OldRestorePoints' -Name 'Old System Restore Shadow Copies (Keep Newest Only)' -Risk 'Irreversible' -Method 'VSS_Old' `
        -WarningText 'IRREVERSIBLE: Removes older System Restore points so you cannot roll back to them.'

    # 21. IRREVERSIBLE: Windows.old / Previous Installations
    $winOldPath = Join-Path "$($script:SysDrive)\" 'Windows.old'
    Add-Cat -Id 'WindowsOld' -Name 'Previous Windows Installation (Windows.old)' -Risk 'Irreversible' -Method 'WindowsOld' `
        -Roots @($winOldPath) `
        -WarningText 'IRREVERSIBLE: Permanently removes the ability to roll back to your previous Windows version.'

    # 22. IRREVERSIBLE: DISM /ResetBase
    Add-Cat -Id 'DISM_ResetBase' -Name 'WinSxS ResetBase (DISM /StartComponentCleanup /ResetBase)' -Risk 'Irreversible' -Method 'DISM_ResetBase' `
        -WarningText 'IRREVERSIBLE: All currently installed Windows Updates become permanent and cannot be uninstalled.'

    return $cats
}

# ============================================================================
# STAGE 2: READ-ONLY MEASUREMENT OF ALL CATEGORIES
# ============================================================================
function Measure-AllCategories {
    param([System.Collections.Generic.List[pscustomobject]]$Categories)

    $script:Stats.StageIndex = 2
    $script:Stats.StageName  = 'Scanning Disk (Read-Only)'
    $totalCats = $Categories.Count
    $catIndex  = 0

    foreach ($cat in $Categories) {
        $catIndex++
        $pct = [int](($catIndex / [math]::Max(1, $totalCats)) * 100)
        Update-UiProgress -OverallPercent (10 + [int]($pct * 0.25)) -CategoryName "Scanning: $($cat.Name)" -CategoryPercent $pct -Force

        if ($cat.DisabledReason -ne '') { continue }

        switch ($cat.Method) {
            'HibernationOff' {
                $hiberPath = Join-Path "$($script:SysDrive)\" 'hiberfil.sys'
                if (Test-Path -LiteralPath $hiberPath) {
                    $hItem = Get-Item -LiteralPath $hiberPath -Force -ErrorAction SilentlyContinue
                    if ($hItem) {
                        $cat.FileCount      = 1
                        $cat.EstimatedBytes = [int64]$hItem.Length
                    }
                }
            }
            { $_ -in @('Files','WUFiles','DeliveryOpt','WindowsOld','EventLogs','SearchIndex','WslVhdx') } {
                if ($cat.Roots.Count -eq 0) { continue }
                $age = if ($cat.UseAgeFilter) { $MinAgeHours } else { 0 }
                $res = Get-FilesSafe -Roots $cat.Roots -FileFilter $cat.FileFilter -MinAgeHoursFilter $age -CategoryName $cat.Name
                $cat.ScannedFiles   = $res.Files
                $cat.FileCount      = $res.Files.Count
                $cat.EstimatedBytes = $res.TotalBytes
                $cat.ExcludedCount  = $res.ExcludedCount
                $script:Stats.ExcludedCount += $res.ExcludedCount
            }
            'RecycleBin' {
                $rbRoots = @()
                $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })
                foreach ($v in $vols) {
                    $rb = "$($v.DriveLetter):\`$Recycle.Bin"
                    if (Test-Path -LiteralPath $rb) { $rbRoots += $rb }
                }
                if ($rbRoots.Count -gt 0) {
                    $res = Get-FilesSafe -Roots $rbRoots -CategoryName $cat.Name
                    $cat.FileCount      = $res.Files.Count
                    $cat.EstimatedBytes = $res.TotalBytes
                }
            }
            'OldDrivers' {
                $drv = Get-OldDriverPackages
                $cat.DriverPackages = $drv.Packages
                $cat.FileCount      = if ($drv.Packages.Count -gt 0) { $drv.Packages.Count } else { [math]::Max(1, $drv.AllCount) }
                $cat.EstimatedBytes = if ($drv.TotalBytes -gt 0) { $drv.TotalBytes } else { -1 }
            }
            'DISM_Component' {
                # Fast estimate via WinSxS Temp/Backup folders without blocking for 5 min on AnalyzeComponentStore unless needed
                $sxsTemp = Join-Path $env:SystemRoot 'WinSxS\Temp'
                if (Test-Path -LiteralPath $sxsTemp) {
                    $res = Get-FilesSafe -Roots @($sxsTemp) -CategoryName $cat.Name
                    $cat.EstimatedBytes = $res.TotalBytes
                    $cat.FileCount      = $res.Files.Count
                }
                if ($cat.EstimatedBytes -eq 0) { $cat.EstimatedBytes = -1 } # -1 indicates 'est. by DISM'
            }
            'DISM_ResetBase' {
                $cat.EstimatedBytes = -1
            }
            'CleanMgr' {
                $cat.EstimatedBytes = -1
            }
            'VSS_Old' {
                $shadows = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object {
                    $_.VolumeName -and (Get-CimInstance -ClassName Win32_Volume -Filter "DeviceID='$($_.VolumeName.Replace('\','\\'))'" -ErrorAction SilentlyContinue).DriveLetter -ieq $script:SysDrive
                })
                if ($shadows.Count -gt 1) {
                    $cat.FileCount = $shadows.Count - 1
                    $storage = Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($storage -and $storage.UsedSpace) {
                        $cat.EstimatedBytes = [int64](($storage.UsedSpace * ($shadows.Count - 1)) / $shadows.Count)
                    } else {
                        $cat.EstimatedBytes = -1
                    }
                }
            }
        }
    }
}

# ============================================================================
# STAGE 3: DISPLAY SCAN TABLE & CONFIRM EVERY CATEGORY
# ============================================================================
function Show-ScanTable {
    param([System.Collections.Generic.List[pscustomobject]]$Categories)

    Write-Host "`n============================== SCAN RESULTS (READ-ONLY) ==============================" -ForegroundColor Cyan
    Write-Host (' {0,-3} {1,-12} {2,-46} {3,8} {4,12}' -f '#', 'Risk', 'Category', 'Items', 'Est. Size') -ForegroundColor White
    Write-Host ('-' * 86) -ForegroundColor DarkGray

    $idx = 0
    $totalEst = [int64]0
    foreach ($cat in $Categories) {
        $idx++
        $sizeStr = if ($cat.DisabledReason -ne '') {
            "DISABLED ($($cat.DisabledReason))"
        } elseif ($cat.EstimatedBytes -lt 0) {
            'est. n/a'
        } else {
            $totalEst += $cat.EstimatedBytes
            Format-Bytes $cat.EstimatedBytes
        }
        $color = if ($cat.DisabledReason -ne '') {
            'DarkGray'
        } elseif ($cat.Risk -eq 'Safe') {
            'Green'
        } elseif ($cat.Risk -eq 'Moderate') {
            'Yellow'
        } else {
            'Red'
        }
        Write-Host (' {0,-3} {1,-12} {2,-46} {3,8} {4,12}' -f $idx, $cat.Risk, (Format-MiddleEllipsis $cat.Name 45), $cat.FileCount, $sizeStr) -ForegroundColor $color
    }
    Write-Host ('-' * 86) -ForegroundColor DarkGray
    Write-Host (' Total Measurable Reclaimable Space: {0} (Excluded files skipped: {1})' -f (Format-Bytes $totalEst), $script:Stats.ExcludedCount) -ForegroundColor Cyan
    Write-Host "======================================================================================`n" -ForegroundColor Cyan
}

function Read-AllCategoryConfirmations {
    param(
        [System.Collections.Generic.List[pscustomobject]]$Categories,
        [string]$Preset
    )
    $script:Stats.StageIndex = 3
    $script:Stats.StageName  = 'Confirming Categories'
    Update-UiProgress -OverallPercent 40 -CategoryName 'Waiting for User Confirmation' -CategoryPercent 0 -Force

    Write-Host "Confirm each non-empty category below. Type 'q' at any prompt to cancel without deleting anything.`n" -ForegroundColor Cyan

    foreach ($cat in $Categories) {
        if ($cat.DisabledReason -ne '') { continue }
        if ($cat.EstimatedBytes -eq 0 -and $cat.FileCount -eq 0) { continue }

        # Check running processes warning
        if ($cat.StopProcesses.Count -gt 0) {
            $running = @(Get-Process -Name $cat.StopProcesses -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                $rNames = ($running | Select-Object -ExpandProperty Name -Unique) -join ', '
                Write-Host "  [!] Running app detected for '$($cat.Name)': $rNames (close app first or files will be skipped)" -ForegroundColor Yellow
            }
        }

        if ($cat.WarningText -ne '') {
            Write-Host "  Note: $($cat.WarningText)" -ForegroundColor DarkYellow
        }

        $sizeStr = if ($cat.EstimatedBytes -lt 0) { 'est. n/a' } else { Format-Bytes $cat.EstimatedBytes }

        if ($cat.Risk -eq 'Irreversible') {
            $prompt = "  [IRREVERSIBLE] Clean '$($cat.Name)' ($sizeStr)? Type YES in capitals to confirm, or Enter to skip"
            $ans = Read-Host $prompt
            if ($ans -ceq 'q' -or $ans -ceq 'Q') { return $false }
            $cat.Confirmed = ($ans -ceq 'YES')
        } else {
            $defaultYes = ($Preset -ne 'Manual' -and ($cat.PresetModes -contains $Preset))
            $suffix     = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
            $prompt     = "  [$($cat.Risk)] Clean '$($cat.Name)' ($sizeStr)? $suffix"
            $ans        = Read-Host $prompt
            if ($ans -match '^[Qq]$') { return $false }
            if ([string]::IsNullOrWhiteSpace($ans)) {
                $cat.Confirmed = $defaultYes
            } else {
                $cat.Confirmed = ($ans -match '^[Yy]$')
            }
        }
    }
    return $true
}

# ============================================================================
# SHARED INTERACTIVE STORAGE LOCATION SELECTOR (DRIVER BACKUP & QUARANTINE)
# ============================================================================
function Select-StorageLocation {
    param(
        [Parameter(Mandatory)][string]$Purpose,          # 'DriverBackup' or 'Quarantine'
        [Parameter(Mandatory)][int64]$RequiredBytes,
        [Parameter(Mandatory)][bool]$AllowSystemDrive,
        [string]$PresetPath = ''
    )
    $needWithMargin = [int64]($RequiredBytes * 1.15)
    $subFolder      = '{0}\{1}_{2}' -f $Purpose, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm')

    while ($true) {
        Write-Host "`n---------------- SELECT $($Purpose.ToUpper()) DESTINATION ----------------" -ForegroundColor Cyan
        Write-Host ("Estimated space needed: ~{0}" -f (Format-Bytes $RequiredBytes)) -ForegroundColor Gray

        $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object {
            $_.DeviceID -and $_.DriveType -in @(2, 3, 4)
        } | Sort-Object @{Expression={ $_.DeviceID -ieq $script:SysDrive }; Ascending=$true}, DeviceID)

        $selectable = New-Object 'System.Collections.Generic.List[pscustomobject]'
        $idx = 0
        foreach ($ld in $logicalDisks) {
            $isSys = ($ld.DeviceID -ieq $script:SysDrive)
            if ($isSys -and -not $AllowSystemDrive) { continue }
            $idx++
            $freeBytes = [int64]$ld.FreeSpace
            $typeLabel = switch ($ld.DriveType) {
                2 { 'Removable' }
                3 { 'Fixed' }
                4 { 'Network' }
                default { 'Drive' }
            }
            $status = if ($freeBytes -lt $needWithMargin) {
                'LOW SPACE'
            } elseif ($isSys) {
                'WARN: System drive (uses space being cleaned)'
            } else {
                'Recommended'
            }
            $selectable.Add([pscustomobject]@{
                Index  = $idx
                Letter = "$($ld.DeviceID)"
                Label  = "$($ld.VolumeName)"
                Type   = $typeLabel
                Free   = $freeBytes
                Status = $status
            })
            Write-Host ('  {0}  {1,-4} {2,-14} {3,-10} Free: {4,-10} [{5}]' -f $idx, "$($ld.DeviceID)", "$($ld.VolumeName)", $typeLabel, (Format-Bytes $freeBytes), $status)
        }
        if ($selectable.Count -eq 0) {
            Write-Host "  [!] No secondary drive letter detected (System drive $($script:SysDrive) is excluded so it does not lose free space)." -ForegroundColor Yellow
            Write-Host "      Plug in a USB drive and press R to refresh, or choose B/T for a network share (\\server\share), or S to skip." -ForegroundColor Yellow
        }
        Write-Host '  R  Refresh drive list (after plugging in USB / external drive)'
        Write-Host '  B  Browse for a folder (another drive or network share)...'
        Write-Host '  T  Type a custom path on another drive or \\server\share'
        Write-Host "  S  Skip $Purpose"
        Write-Host '  Q  Quit cleanup'

        $nonSysSelectable = @($selectable | Where-Object { $_.Letter -ine $script:SysDrive })
        $defaultHint = if ($PresetPath) { $PresetPath } elseif ($nonSysSelectable.Count -gt 0) { "$($nonSysSelectable[0].Index)" } else { 'B' }
        $choice = Read-Host "Choice [$defaultHint]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultHint }

        if ($choice -match '^[Rr]$') { continue }
        if ($choice -match '^[Qq]$') { return @{ Action = 'Quit'; Path = '' } }
        if ($choice -match '^[Ss]$') { return @{ Action = 'Skip'; Path = '' } }

        $basePath = ''
        if ($choice -match '^\d+$') {
            $num = [int]$choice
            $sel = $selectable | Where-Object { $_.Index -eq $num } | Select-Object -First 1
            if (-not $sel) {
                Write-Host '  [!] Invalid drive number.' -ForegroundColor Red
                continue
            }
            $basePath = Join-Path "$($sel.Letter)\" $subFolder
        } elseif ($choice -match '^[Bb]$') {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "Select destination root for $Purpose"
                $dlg.ShowNewFolderButton = $true
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $basePath = Join-Path $dlg.SelectedPath $subFolder
                } else {
                    continue
                }
            } catch {
                Write-Host '  [!] GUI folder dialog unavailable; please choose T to type a path.' -ForegroundColor Yellow
                continue
            }
        } elseif ($choice -match '^[Tt]$') {
            $typed = Read-Host 'Enter full destination path'
            if ([string]::IsNullOrWhiteSpace($typed)) { continue }
            $basePath = Join-Path $typed.Trim('"') $subFolder
        } else {
            $basePath = Join-Path $choice.Trim('"') $subFolder
        }

        # Validate path safety & writability
        if (-not $AllowSystemDrive -and $basePath.StartsWith($script:SysDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  [!] $Purpose cannot be stored on the system drive ($($script:SysDrive))." -ForegroundColor Red
            continue
        }
        if ($basePath.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '  [!] Destination cannot be inside the Windows directory.' -ForegroundColor Red
            continue
        }

        $confirm = Read-Host "Save $Purpose to `"$basePath`"? [Y/n]"
        if ($confirm -match '^[Nn]$') { continue }

        try {
            if (-not (Test-Path -LiteralPath $basePath)) {
                New-Item -ItemType Directory -Path $basePath -Force -ErrorAction Stop | Out-Null
            }
            $testFile = Join-Path $basePath '.write_test.tmp'
            Set-Content -LiteralPath $testFile -Value 'ok' -ErrorAction Stop
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
            return @{ Action = 'Selected'; Path = $basePath }
        } catch {
            Write-Host "  [!] Destination is not writable: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ============================================================================
# STAGE 4: MANDATORY VERIFIED DRIVER BACKUP
# ============================================================================
function Backup-Drivers {
    param([Parameter(Mandatory)][string]$DestinationPath)

    $script:Stats.StageIndex = 4
    $script:Stats.StageName  = 'Backing Up Drivers'
    Update-UiProgress -OverallPercent 45 -CategoryName 'Driver Backup (pnputil)' -CategoryPercent 0 -Force

    Write-Host "`n[DRIVER BACKUP] Exporting third-party drivers to: $DestinationPath" -ForegroundColor Cyan
    Write-Log -Message "Starting driver backup to $DestinationPath" -Level 'INFO'

    $allPkgs = (Get-OldDriverPackages).AllCount
    if ($allPkgs -lt 1) { $allPkgs = 1 }

    # Export inventory CSV first
    $csvPath = Join-Path $DestinationPath 'drivers.csv'
    try {
        Get-WindowsDriver -Online -ErrorAction SilentlyContinue |
            Select-Object Driver, OriginalFileName, ProviderName, ClassName, Version, Date |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    } catch {
        Write-Log -Message "Get-WindowsDriver inventory note: $($_.Exception.Message)" -Level 'WARN'
    }

    # Run pnputil /export-driver * with progress polling
    $proc = Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/export-driver', '*', ('"{0}"' -f $DestinationPath)) `
        -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $DestinationPath 'pnputil_export.log')

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        $exportedDirs = @(Get-ChildItem -LiteralPath $DestinationPath -Directory -ErrorAction SilentlyContinue).Count
        $pct = [math]::Min(99, [int](($exportedDirs / $allPkgs) * 100))
        Update-UiProgress -OverallPercent 48 -CategoryName "Exporting Drivers ($exportedDirs / $allPkgs)" -CategoryPercent $pct -Force
    }

    # Verify exported .inf count
    $infFiles = @(Get-ChildItem -LiteralPath $DestinationPath -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue)
    if ($infFiles.Count -eq 0) {
        Write-Host '[ERROR] Driver backup verification failed: 0 .inf files exported!' -ForegroundColor Red
        Write-Log -Message 'Driver backup verification failed: 0 .inf files exported.' -Level 'ERROR'
        return $false
    }

    # Write Restore-Drivers.cmd helper
    $restoreCmd = Join-Path $DestinationPath 'Restore-Drivers.cmd'
    $cmdBody = @"
@echo off
echo Restoring backed-up drivers from %~dp0 ...
pnputil /add-driver "%~dp0*.inf" /subdirs /install
echo.
echo Driver restore complete.
pause
"@
    Set-Content -LiteralPath $restoreCmd -Value $cmdBody -Encoding ASCII

    Write-Host ("[OK] Driver backup verified: {0} driver INF packages exported + Restore-Drivers.cmd created." -f $infFiles.Count) -ForegroundColor Green
    Write-Log -Message "Driver backup verified ($($infFiles.Count) INF files) at $DestinationPath" -Level 'INFO'
    return $true
}

# ============================================================================
# MANDATORY VERIFIED WINDOWS EVENT LOG BACKUP
# ============================================================================
function Backup-EventLogs {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][object[]]$ScannedEvtxFiles
    )
    $script:Stats.StageIndex = 4
    $script:Stats.StageName  = 'Backing Up Event Logs'
    Update-UiProgress -OverallPercent 51 -CategoryName 'Windows Event Log Backup' -CategoryPercent 0 -Force

    Write-Host "`n[EVENT LOG BACKUP] Exporting Windows Event Logs (.evtx) to: $DestinationPath" -ForegroundColor Cyan
    Write-Log -Message "Starting Windows Event Log backup to $DestinationPath" -Level 'INFO'

    $evtxDir = Join-Path $DestinationPath 'evtx'
    if (-not (Test-Path -LiteralPath $evtxDir)) {
        New-Item -ItemType Directory -Path $evtxDir -Force | Out-Null
    }

    $total = [math]::Max(1, $ScannedEvtxFiles.Count)
    $idx   = 0
    $exportedCount = 0
    $inventory = New-Object 'System.Collections.Generic.List[pscustomobject]'

    foreach ($f in $ScannedEvtxFiles) {
        $idx++
        $pct = [int](($idx / $total) * 100)
        $leaf = Split-Path -Path $f.FullName -Leaf
        Update-UiProgress -OverallPercent 52 -CategoryName "Exporting Event Logs ($idx / $total)" -CategoryPercent $pct -ItemText $leaf

        $destFile = Join-Path $evtxDir $leaf
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $destFile -Force -ErrorAction Stop
            $exportedCount++
            $inventory.Add([pscustomobject]@{
                FileName   = $leaf
                SourcePath = $f.FullName
                BackupPath = $destFile
                Length     = $f.Length
                Timestamp  = (Get-Date -Format 'o')
            })
        } catch {
            Write-Log -Message "Could not copy event log $($f.FullName): $($_.Exception.Message)" -Level 'WARN'
        }
    }

    # Also export core channels via wevtutil epl for consistent structured snapshots
    foreach ($chan in @('System','Application','Security','Setup')) {
        $chanFile = Join-Path $DestinationPath "channel_$chan.evtx"
        try { [void](& wevtutil.exe epl $chan $chanFile /ow:true 2>$null) } catch { }
    }

    $csvPath = Join-Path $DestinationPath 'eventlogs_inventory.csv'
    $inventory | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $helperCmd = Join-Path $DestinationPath 'Open-EventViewer.cmd'
    $cmdBody = @"
@echo off
echo Opening backed up Windows Event Logs folder and Event Viewer...
start "" "%~dp0evtx"
start "" eventvwr.msc
"@
    Set-Content -LiteralPath $helperCmd -Value $cmdBody -Encoding ASCII

    $backedUpFiles = @(Get-ChildItem -LiteralPath $evtxDir -Filter '*.evtx' -File -ErrorAction SilentlyContinue)
    if ($backedUpFiles.Count -eq 0) {
        Write-Host '[ERROR] Event Log backup verification failed: 0 .evtx files backed up!' -ForegroundColor Red
        Write-Log -Message 'Event Log backup verification failed: 0 .evtx files backed up.' -Level 'ERROR'
        return $false
    }

    Write-Host ("[OK] Event Log backup verified: {0} .evtx files archived + eventlogs_inventory.csv created." -f $backedUpFiles.Count) -ForegroundColor Green
    Write-Log -Message "Event Log backup verified ($($backedUpFiles.Count) .evtx files) at $DestinationPath" -Level 'INFO'
    return $true
}

# ============================================================================
# STAGE 5: OPTIONAL SYSTEM RESTORE POINT
# ============================================================================
function Invoke-OptionalRestorePoint {
    param([bool]$SystemRestoreEnabled)
    $script:Stats.StageIndex = 5
    $script:Stats.StageName  = 'System Restore Point'
    Update-UiProgress -OverallPercent 55 -CategoryName 'System Restore Point' -CategoryPercent 0 -Force

    if (-not $SystemRestoreEnabled) {
        Write-Host '[INFO] System Protection is disabled on the system drive; skipping restore point.' -ForegroundColor Gray
        return
    }

    $ans = Read-Host "`nCreate a System Restore Point before cleaning? [y/N]"
    if ($ans -notmatch '^[Yy]$') { return }

    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $origFreq = $null
    try {
        $prop = Get-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        if ($null -ne $prop) { $origFreq = $prop.SystemRestorePointCreationFrequency }

        # Check if a restore point was created in last 24h
        $recent = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object {
            $_.CreationTime -and ([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) -gt (Get-Date).AddHours(-24))
        })
        if ($recent.Count -gt 0) {
            $forceAns = Read-Host 'A restore point was already created within the last 24h. Force a new one anyway? [y/N]'
            if ($forceAns -match '^[Yy]$') {
                Set-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            } else {
                return
            }
        }

        Write-Host '[RESTORE POINT] Creating System Restore Point...' -ForegroundColor Cyan
        Checkpoint-Computer -Description 'Win11-DiskCleanup Pre-Clean' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Host '[OK] System Restore Point created.' -ForegroundColor Green
        Write-Log -Message 'System Restore Point created.' -Level 'INFO'
    } catch {
        Write-Host "[WARN] Could not create Restore Point: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Log -Message "Restore Point warning: $($_.Exception.Message)" -Level 'WARN'
    } finally {
        if ($null -ne $origFreq) {
            Set-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value $origFreq -Type DWord -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# STAGE 6: EXECUTE CONFIRMED CLEANUP CATEGORIES
# ============================================================================
function New-QuarantineRestoreScript {
    param([string]$QuarantineSetDir)
    $restorePs1 = Join-Path $QuarantineSetDir 'Restore-Quarantine.ps1'
    $body = @'
#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$manifest = Join-Path $PSScriptRoot 'manifest.csv'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host "manifest.csv not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}
$rows = Import-Csv -LiteralPath $manifest
$restored = 0
$skipped  = 0
foreach ($r in $rows) {
    if (-not (Test-Path -LiteralPath $r.QuarantinePath)) { continue }
    if (Test-Path -LiteralPath $r.OriginalPath) {
        $existing = Get-Item -LiteralPath $r.OriginalPath -Force
        $qItem    = Get-Item -LiteralPath $r.QuarantinePath -Force
        if ($existing.LastWriteTimeUtc -ge $qItem.LastWriteTimeUtc) {
            $skipped++
            continue
        }
    }
    $parent = Split-Path -Path $r.OriginalPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Move-Item -LiteralPath $r.QuarantinePath -Destination $r.OriginalPath -Force
    $restored++
}
Write-Host "Quarantine restore complete: $restored restored, $skipped skipped (newer file existed)." -ForegroundColor Green
'@
    Set-Content -LiteralPath $restorePs1 -Value $body -Encoding UTF8
}

function Invoke-FileListCleanup {
    param(
        [pscustomobject]$Category,
        [bool]$UseQuarantine,
        [string]$QuarantineSetDir
    )
    $freed  = [int64]0
    $locked = 0
    $errors = 0
    $total  = [math]::Max(1, $Category.ScannedFiles.Count)
    $idx    = 0
    $manifestPath = if ($UseQuarantine -and $QuarantineSetDir) { Join-Path $QuarantineSetDir 'manifest.csv' } else { '' }

    foreach ($f in $Category.ScannedFiles) {
        $idx++
        $pct = [int](($idx / $total) * 100)
        Update-UiProgress -CategoryName "Cleaning: $($Category.Name)" -CategoryPercent $pct -ItemText $f.FullName

        # Re-verify allowlist & existence
        if (-not (Test-ChildUnderAllowedRoot -ChildPath $f.FullName -AllowedRoots $Category.Roots)) {
            Write-Log -Message "Refused out-of-bounds path: $($f.FullName)" -Level 'ERROR'
            $errors++
            continue
        }
        if (-not (Test-Path -LiteralPath $f.FullName -PathType Leaf)) { continue }

        try {
            $item = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            if ($UseQuarantine -and $Category.CanQuarantine -and $QuarantineSetDir) {
                $relPath = $f.FullName -replace '^([A-Za-z]):\\', '$1\'
                $qDest   = Join-Path (Join-Path $QuarantineSetDir $Category.Id) $relPath
                $qParent = Split-Path -Path $qDest -Parent
                if (-not (Test-Path -LiteralPath $qParent)) {
                    New-Item -ItemType Directory -Path $qParent -Force -ErrorAction Stop | Out-Null
                }
                Move-Item -LiteralPath $f.FullName -Destination $qDest -Force -ErrorAction Stop
                $row = [pscustomobject]@{
                    Category       = $Category.Id
                    OriginalPath   = $f.FullName
                    QuarantinePath = $qDest
                    Length         = $f.Length
                    Timestamp      = (Get-Date -Format 'o')
                }
                $row | Export-Csv -LiteralPath $manifestPath -Append -NoTypeInformation -Encoding UTF8
                $freed += $f.Length
                $script:Stats.QuarantinedBytes += $f.Length
                Write-Log -Message "Quarantined: $($f.FullName) -> $qDest" -Level 'QUARANTINE'
            } else {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $freed += $f.Length
                $script:Stats.FreedBytes += $f.Length
                Write-Log -Message "Deleted: $($f.FullName) ($($f.Length) B)" -Level 'DELETE'
            }
        } catch {
            $locked++
            $script:Stats.LockedCount++
            Write-Log -Message "Locked/Skipped: $($f.FullName) ($($_.Exception.Message))" -Level 'SKIP'
        }
    }

    return [pscustomobject]@{ FreedBytes = $freed; LockedCount = $locked; ErrorCount = $errors }
}

function Invoke-DismCleanup {
    param([bool]$ResetBase)
    $argsList = if ($ResetBase) {
        '/Online /Cleanup-Image /StartComponentCleanup /ResetBase'
    } else {
        '/Online /Cleanup-Image /StartComponentCleanup'
    }
    $label = if ($ResetBase) { 'DISM /ResetBase' } else { 'DISM /StartComponentCleanup' }
    Write-Host "  >> Running $label..." -ForegroundColor Cyan

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'dism.exe'
    $psi.Arguments              = $argsList
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($line -match '(\d{1,3}\.\d)%') {
            $pct = [int][double]$Matches[1]
            Update-UiProgress -CategoryName $label -CategoryPercent $pct -ItemText $line.Trim() -Force
        }
    }
    $proc.WaitForExit()
    Write-Log -Message "$label finished with exit code $($proc.ExitCode)" -Level 'INFO'
}

function Invoke-CleanMgrHandlers {
    param([string[]]$Handlers)
    if ($Handlers.Count -eq 0) { return }

    $formatted   = $SagesetNumber.ToString('D4')
    $flagName    = "StateFlags$formatted"
    $volCacheReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

    try {
        # Clear any stale flags for this sageset number first
        foreach ($sub in (Get-ChildItem -LiteralPath $volCacheReg -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -LiteralPath $sub.PSPath -Name $flagName -ErrorAction SilentlyContinue
        }
        foreach ($h in $Handlers) {
            $hPath = Join-Path $volCacheReg $h
            if (Test-Path -LiteralPath $hPath) {
                Set-ItemProperty -LiteralPath $hPath -Name $flagName -Value 2 -Type DWord -ErrorAction Stop
            }
        }

        Write-Host "  >> Running cleanmgr /sagerun:$SagesetNumber ($($Handlers -join ', '))..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList "/sagerun:$SagesetNumber" -PassThru -NoNewWindow
        $timeoutMs = $CleanMgrTimeoutMin * 60 * 1000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 2
            if ($sw.ElapsedMilliseconds -gt $timeoutMs) {
                Write-Host "  [WARN] cleanmgr exceeded timeout ($CleanMgrTimeoutMin min); stopping process." -ForegroundColor Yellow
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                break
            }
            Update-UiProgress -CategoryName 'cleanmgr /sagerun' -CategoryPercent 50 -ItemText ("Elapsed: {0:mm\:ss}" -f $sw.Elapsed) -Force
        }
        Write-Log -Message "cleanmgr /sagerun:$SagesetNumber completed." -Level 'INFO'
    } finally {
        foreach ($sub in (Get-ChildItem -LiteralPath $volCacheReg -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -LiteralPath $sub.PSPath -Name $flagName -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ConfirmedCategories {
    param(
        [System.Collections.Generic.List[pscustomobject]]$Categories,
        [bool]$UseQuarantine,
        [string]$QuarantineSetDir
    )
    $script:Stats.StageIndex = 6
    $script:Stats.StageName  = 'Cleaning Selected Categories'

    $confirmed = @($Categories | Where-Object { $_.Confirmed })
    $cleanMgrHandlers = New-Object 'System.Collections.Generic.List[string]'
    $results = New-Object 'System.Collections.Generic.List[pscustomobject]'

    if ($UseQuarantine -and $QuarantineSetDir) {
        New-QuarantineRestoreScript -QuarantineSetDir $QuarantineSetDir
    }

    $idx = 0
    foreach ($cat in $confirmed) {
        $idx++
        $overallPct = 60 + [int](($idx / [math]::Max(1, $confirmed.Count)) * 30)
        Update-UiProgress -OverallPercent $overallPct -CategoryName $cat.Name -CategoryPercent 0 -Force

        # Check running processes before cleaning
        if ($cat.StopProcesses.Count -gt 0) {
            $running = @(Get-Process -Name $cat.StopProcesses -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                $rNames = ($running | Select-Object -ExpandProperty Name -Unique) -join ', '
                Write-Host (" [WARN] Skipped {0}: app is currently running ({1})" -f $cat.Name, $rNames) -ForegroundColor Yellow
                Write-Log -Message "Skipped $($cat.Name) because processes were running: $rNames" -Level 'SKIP'
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Skipped (App Running)'; Reclaimed = 0; Locked = 0 })
                continue
            }
        }

        switch ($cat.Method) {
            'HibernationOff' {
                $hiberPath = Join-Path "$($script:SysDrive)\" 'hiberfil.sys'
                $hLen = if (Test-Path -LiteralPath $hiberPath) { (Get-Item -LiteralPath $hiberPath -Force).Length } else { [int64]0 }
                [void](& powercfg.exe /h off 2>&1)
                if (-not (Test-Path -LiteralPath $hiberPath)) {
                    $script:Stats.FreedBytes += $hLen
                    Write-Host (" [OK] {0,-48} {1,10} reclaimed" -f $cat.Name, (Format-Bytes $hLen)) -ForegroundColor Green
                    Write-Log -Message "Disabled hibernation (powercfg /h off); reclaimed $hLen bytes" -Level 'DELETE'
                    $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Disabled Hibernation'; Reclaimed = $hLen; Locked = 0 })
                } else {
                    Write-Host (" [WARN] Could not remove hiberfil.sys" -f $cat.Name) -ForegroundColor Yellow
                }
            }
            'Files' {
                $r = Invoke-FileListCleanup -Category $cat -UseQuarantine $UseQuarantine -QuarantineSetDir $QuarantineSetDir
                Write-Host (" [OK] {0,-48} {1,10} reclaimed ({2} locked)" -f $cat.Name, (Format-Bytes $r.FreedBytes), $r.LockedCount) -ForegroundColor Green
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Cleaned'; Reclaimed = $r.FreedBytes; Locked = $r.LockedCount })
            }
            'WUFiles' {
                $services = @('wuauserv','bits')
                try {
                    Stop-Service -Name $services -Force -ErrorAction SilentlyContinue
                    $r = Invoke-FileListCleanup -Category $cat -UseQuarantine $UseQuarantine -QuarantineSetDir $QuarantineSetDir
                    Write-Host (" [OK] {0,-48} {1,10} reclaimed ({2} locked)" -f $cat.Name, (Format-Bytes $r.FreedBytes), $r.LockedCount) -ForegroundColor Green
                    $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Cleaned'; Reclaimed = $r.FreedBytes; Locked = $r.LockedCount })
                } finally {
                    Start-Service -Name $services -ErrorAction SilentlyContinue
                }
            }
            'DeliveryOpt' {
                try {
                    Start-Service -Name 'dosvc' -ErrorAction SilentlyContinue
                    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                    $script:Stats.FreedBytes += [math]::Max(0, $cat.EstimatedBytes)
                    Write-Host (" [OK] {0,-48} {1,10} reclaimed" -f $cat.Name, (Format-Bytes $cat.EstimatedBytes)) -ForegroundColor Green
                    Write-Log -Message 'Cleared Delivery Optimization Cache via Delete-DeliveryOptimizationCache' -Level 'DELETE'
                    $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Cleaned'; Reclaimed = $cat.EstimatedBytes; Locked = 0 })
                } catch {
                    $script:Stats.ErrorCount++
                    Write-Host (" [ERR] {0}: {1}" -f $cat.Name, $_.Exception.Message) -ForegroundColor Red
                    Write-Log -Message "DeliveryOptimization error: $($_.Exception.Message)" -Level 'ERROR'
                }
            }
            'RecycleBin' {
                try {
                    Clear-RecycleBin -Force -ErrorAction Stop
                    $script:Stats.FreedBytes += [math]::Max(0, $cat.EstimatedBytes)
                    Write-Host (" [OK] {0,-48} {1,10} reclaimed" -f $cat.Name, (Format-Bytes $cat.EstimatedBytes)) -ForegroundColor Green
                    Write-Log -Message 'Emptied Recycle Bin via Clear-RecycleBin' -Level 'DELETE'
                    $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Cleaned'; Reclaimed = $cat.EstimatedBytes; Locked = 0 })
                } catch {
                    $script:Stats.ErrorCount++
                    Write-Log -Message "RecycleBin error: $($_.Exception.Message)" -Level 'ERROR'
                }
            }
            'OldDrivers' {
                $drvFreed = [int64]0
                $drvLocked = 0
                foreach ($pkg in $cat.DriverPackages) {
                    $out = (& pnputil.exe /delete-driver $pkg.PublishedName 2>&1) -join ' '
                    if ($LASTEXITCODE -eq 0) {
                        $drvFreed += $pkg.EstBytes
                        $script:Stats.FreedBytes += $pkg.EstBytes
                        Write-Log -Message "Removed superseded driver $($pkg.PublishedName) ($($pkg.OriginalName) v$($pkg.DriverVersion))" -Level 'DELETE'
                    } else {
                        $drvLocked++
                        Write-Log -Message "Skipped in-use driver $($pkg.PublishedName): $out" -Level 'SKIP'
                    }
                }
                $cleanMgrHandlers.Add('Device Driver Packages')
                Write-Host (" [OK] {0,-48} {1,10} reclaimed ({2} in-use kept)" -f $cat.Name, (Format-Bytes $drvFreed), $drvLocked) -ForegroundColor Green
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Cleaned'; Reclaimed = $drvFreed; Locked = $drvLocked })
            }
            'VSS_Old' {
                $shadows = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue | Sort-Object InstallDate -Descending)
                $oldShadows = @($shadows | Select-Object -Skip 1)
                $removedCount = 0
                foreach ($sh in $oldShadows) {
                    $id = $sh.ID
                    [void](& vssadmin.exe delete shadows "/shadow=$id" /quiet 2>&1)
                    if ($LASTEXITCODE -eq 0) {
                        $removedCount++
                        Write-Log -Message "Deleted old VSS shadow copy $id" -Level 'DELETE'
                    }
                }
                Write-Host (" [OK] {0,-48} {1} old shadow copies removed" -f $cat.Name, $removedCount) -ForegroundColor Green
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = "Removed $removedCount shadows"; Reclaimed = [math]::Max(0, $cat.EstimatedBytes); Locked = 0 })
            }
            'CleanMgr' {
                $cleanMgrHandlers.Add('Temporary Setup Files')
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Queued for cleanmgr'; Reclaimed = 0; Locked = 0 })
            }
            'WindowsOld' {
                $cleanMgrHandlers.Add('Previous Installations')
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Queued for cleanmgr'; Reclaimed = $cat.EstimatedBytes; Locked = 0 })
            }
            'DISM_Component' {
                Invoke-DismCleanup -ResetBase $false
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Completed'; Reclaimed = [math]::Max(0, $cat.EstimatedBytes); Locked = 0 })
            }
            'DISM_ResetBase' {
                Invoke-DismCleanup -ResetBase $true
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Completed'; Reclaimed = 0; Locked = 0 })
            }
            'EventLogs' {
                $evtxDir = Join-Path $env:SystemRoot 'System32\winevt\Logs'
                $beforeScan = Get-FilesSafe -Roots @($evtxDir) -FileFilter '*.evtx' -CategoryName 'Measuring Event Logs Before Clear'
                $channels = @(& wevtutil.exe el 2>$null)
                $cleared = 0
                $skippedLogs = 0
                $cIdx = 0
                $cTot = [math]::Max(1, $channels.Count)
                foreach ($ch in $channels) {
                    $cIdx++
                    if ([string]::IsNullOrWhiteSpace($ch)) { continue }
                    Update-UiProgress -CategoryName 'Clearing Windows Event Logs' -CategoryPercent ([int](($cIdx / $cTot) * 100)) -ItemText $ch
                    [void](& wevtutil.exe cl "$ch" 2>$null)
                    if ($LASTEXITCODE -eq 0) { $cleared++ } else { $skippedLogs++ }
                }
                $afterScan = Get-FilesSafe -Roots @($evtxDir) -FileFilter '*.evtx' -CategoryName 'Measuring Event Logs After Clear'
                $reclaimedEvtx = [math]::Max([int64]0, ($beforeScan.TotalBytes - $afterScan.TotalBytes))
                $script:Stats.FreedBytes += $reclaimedEvtx
                Write-Host (" [OK] {0,-48} {1,10} reclaimed ({2} logs cleared)" -f $cat.Name, (Format-Bytes $reclaimedEvtx), $cleared) -ForegroundColor Green
                Write-Log -Message "Cleared $cleared Windows Event Logs ($skippedLogs skipped); reclaimed $reclaimedEvtx bytes" -Level 'DELETE'
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = "Cleared $cleared logs"; Reclaimed = $reclaimedEvtx; Locked = $skippedLogs })
            }
            'SearchIndex' {
                $edbReclaimed = [int64]0
                try {
                    Stop-Service -Name 'WSearch' -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 1
                    foreach ($f in $cat.ScannedFiles) {
                        if (Test-Path -LiteralPath $f.FullName) {
                            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                            $edbReclaimed += $f.Length
                            $script:Stats.FreedBytes += $f.Length
                            Write-Log -Message "Deleted Windows Search Index: $($f.FullName) ($($f.Length) B)" -Level 'DELETE'
                        }
                    }
                    Write-Host (" [OK] {0,-48} {1,10} reclaimed" -f $cat.Name, (Format-Bytes $edbReclaimed)) -ForegroundColor Green
                    $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Index Reset'; Reclaimed = $edbReclaimed; Locked = 0 })
                } catch {
                    $script:Stats.ErrorCount++
                    Write-Host (" [ERR] {0}: {1}" -f $cat.Name, $_.Exception.Message) -ForegroundColor Red
                    Write-Log -Message "SearchIndex reset error: $($_.Exception.Message)" -Level 'ERROR'
                } finally {
                    Start-Service -Name 'WSearch' -ErrorAction SilentlyContinue
                }
            }
            'WslVhdx' {
                $vhdxSaved = [int64]0
                try { [void](& wsl.exe --shutdown 2>$null) } catch { }
                $hasOptVhd = $null -ne (Get-Command -Name 'Optimize-VHD' -ErrorAction SilentlyContinue)
                foreach ($f in $cat.ScannedFiles) {
                    if (-not (Test-Path -LiteralPath $f.FullName)) { continue }
                    $lenBefore = (Get-Item -LiteralPath $f.FullName -Force).Length
                    Update-UiProgress -CategoryName 'Compacting WSL2/Docker VHDX' -CategoryPercent 50 -ItemText $f.FullName -Force
                    if ($hasOptVhd) {
                        try { Optimize-VHD -Path $f.FullName -Mode Full -ErrorAction Stop } catch { }
                    } else {
                        $dpScript = Join-Path $env:TEMP "compact_vhdx_$PID.txt"
                        $dpLines = @(
                            "select vdisk file=`"$($f.FullName)`"",
                            'attach vdisk readonly',
                            'compact vdisk',
                            'detach vdisk',
                            'exit'
                        )
                        Set-Content -LiteralPath $dpScript -Value ($dpLines -join "`r`n") -Encoding ASCII
                        try { [void](& diskpart.exe /s $dpScript 2>$null) } finally {
                            Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $lenAfter = (Get-Item -LiteralPath $f.FullName -Force).Length
                    $diff = [math]::Max([int64]0, ($lenBefore - $lenAfter))
                    $vhdxSaved += $diff
                    $script:Stats.FreedBytes += $diff
                    Write-Log -Message "Compacted VHDX $($f.FullName): saved $diff bytes" -Level 'DELETE'
                }
                Write-Host (" [OK] {0,-48} {1,10} reclaimed" -f $cat.Name, (Format-Bytes $vhdxSaved)) -ForegroundColor Green
                $results.Add([pscustomobject]@{ Category = $cat.Name; Status = 'Compacted'; Reclaimed = $vhdxSaved; Locked = 0 })
            }
        }
        Write-StatusLine
    }

    if ($cleanMgrHandlers.Count -gt 0) {
        Invoke-CleanMgrHandlers -Handlers $cleanMgrHandlers.ToArray()
    }

    return $results
}

function Invoke-SsdTrimIfApplicable {
    param([bool]$IsSsd)
    if (-not $IsSsd) { return }
    $ans = Read-Host "`nSystem drive is an SSD. Run SSD ReTrim (Optimize-Volume -ReTrim) now? [Y/n]"
    if ($ans -match '^[Nn]$') { return }
    try {
        Write-Host '[SSD TRIM] Running Optimize-Volume -ReTrim...' -ForegroundColor Cyan
        Optimize-Volume -DriveLetter $script:SysDriveLetter -ReTrim -ErrorAction Stop
        Write-Host '[OK] SSD TRIM completed.' -ForegroundColor Green
        Write-Log -Message 'Executed Optimize-Volume -ReTrim on system SSD.' -Level 'INFO'
    } catch {
        Write-Host "[WARN] SSD TRIM warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================================================
# MODE 2: SYSTEM REPAIR (DISM SCANHEALTH / RESTOREHEALTH + SFC)
# ============================================================================
function Invoke-SystemRepair {
    $script:Stats.StageIndex = 2
    $script:Stats.StageName  = 'System Repair (DISM + SFC)'
    Update-UiProgress -OverallPercent 20 -CategoryName 'DISM /ScanHealth' -CategoryPercent 0 -Force

    $repairResults = New-Object 'System.Collections.Generic.List[pscustomobject]'
    Write-Host "`n==================== SYSTEM REPAIR (DISM + SFC) ====================" -ForegroundColor Cyan

    # 1. DISM /ScanHealth
    Write-Host '[1/3] Running DISM /Online /Cleanup-Image /ScanHealth...' -ForegroundColor Cyan
    & dism.exe /Online /Cleanup-Image /ScanHealth
    $scanCode = $LASTEXITCODE
    $repairResults.Add([pscustomobject]@{ Step = 'DISM /ScanHealth'; ExitCode = $scanCode })
    Write-Log -Message "DISM /ScanHealth finished with exit code $scanCode" -Level 'INFO'

    # 2. Optional DISM /RestoreHealth
    $ans = Read-Host "`nRun DISM /RestoreHealth to repair component store corruption? [y/N]"
    if ($ans -match '^[Yy]$') {
        Write-Host '[2/3] Running DISM /Online /Cleanup-Image /RestoreHealth...' -ForegroundColor Cyan
        if ($RepairSource) {
            & dism.exe /Online /Cleanup-Image /RestoreHealth "/Source:$RepairSource" /LimitAccess
        } else {
            & dism.exe /Online /Cleanup-Image /RestoreHealth
        }
        $repairResults.Add([pscustomobject]@{ Step = 'DISM /RestoreHealth'; ExitCode = $LASTEXITCODE })
        Write-Log -Message "DISM /RestoreHealth finished with exit code $LASTEXITCODE" -Level 'INFO'
    }

    # 3. SFC /scannow
    $sfcAns = Read-Host "`nRun System File Checker (sfc /scannow)? [Y/n]"
    if ($sfcAns -notmatch '^[Nn]$') {
        Write-Host '[3/3] Running sfc /scannow...' -ForegroundColor Cyan
        & sfc.exe /scannow
        $repairResults.Add([pscustomobject]@{ Step = 'sfc /scannow'; ExitCode = $LASTEXITCODE })
        Write-Log -Message "sfc /scannow finished with exit code $LASTEXITCODE" -Level 'INFO'
    }

    return $repairResults
}

# ============================================================================
# READ-ONLY REPORTS (TOP FOLDERS, OLD DOWNLOADS >180D, INSTALLED APPS)
# ============================================================================
function Get-DiskReadOnlyReports {
    Write-Host "`n[REPORTS] Generating read-only disk usage reports..." -ForegroundColor Cyan

    # 1. Top 25 Second-Level Folders on System Drive
    $topFolders = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $lvl1 = @(Get-ChildItem -LiteralPath "$($script:SysDrive)\" -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and $_.Name -notin @('Windows','System Volume Information','$Recycle.Bin')
    })
    foreach ($d in $lvl1) {
        $s = Get-FilesSafe -Roots @($d.FullName) -CategoryName "Measuring $($d.Name)"
        $topFolders.Add([pscustomobject]@{ Path = $d.FullName; Bytes = $s.TotalBytes; Size = (Format-Bytes $s.TotalBytes) })
    }
    $sortedFolders = @($topFolders | Sort-Object Bytes -Descending | Select-Object -First 25)

    # 2. Old Downloads (> 180 days, never deleted automatically)
    $dlFolder = Join-Path $env:USERPROFILE 'Downloads'
    $oldDownloads = @()
    if (Test-Path -LiteralPath $dlFolder) {
        $res = Get-FilesSafe -Roots @($dlFolder) -MinAgeHoursFilter (180 * 24) -CategoryName 'Scanning Old Downloads (>180d)'
        $oldDownloads = @($res.Files | Sort-Object Length -Descending | Select-Object -First 25 | ForEach-Object {
            [pscustomobject]@{ Path = $_.FullName; Bytes = $_.Length; Size = (Format-Bytes $_.Length) }
        })
    }

    # 3. Installed Applications by Estimated Size
    $uninstPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = @(Get-ItemProperty -Path $uninstPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['EstimatedSize'] -and $_.EstimatedSize -gt 0 } |
        Select-Object DisplayName, DisplayVersion, Publisher, @{Name='Bytes';Expression={[int64]$_.EstimatedSize * 1KB}}, @{Name='Size';Expression={Format-Bytes ([int64]$_.EstimatedSize * 1KB)}} |
        Sort-Object Bytes -Descending | Select-Object -First 25)

    return [pscustomobject]@{
        TopFolders   = $sortedFolders
        OldDownloads = $oldDownloads
        InstalledApps= $apps
    }
}

# ============================================================================
# STAGE 7: 1080P SELF-CONTAINED HTML REPORT & RUN HISTORY CSV
# ============================================================================
function Export-HtmlReportAndHistory {
    param(
        [string]$ModeName,
        [string]$PresetName,
        [pscustomobject]$PreScan,
        [System.Collections.Generic.List[pscustomobject]]$Categories,
        [object[]]$ExecutionResults,
        [string]$DriverBackupDir,
        [string]$EventLogBackupDir = '',
        [string]$QuarantineDir,
        [object[]]$RepairResults,
        [pscustomobject]$ReadOnlyReports
    )
    $script:Stats.StageIndex = 7
    $script:Stats.StageName  = 'Generating Report'
    Update-UiProgress -OverallPercent 95 -CategoryName 'HTML Report & History' -CategoryPercent 90 -Force

    $volAfter  = Get-Volume -DriveLetter $script:SysDriveLetter -ErrorAction SilentlyContinue
    $freeAfter = if ($volAfter) { [int64]$volAfter.SizeRemaining } else { [int64](Get-PSDrive $script:SysDriveLetter).Free }
    $volDelta  = $freeAfter - $PreScan.FreeSpaceBefore

    # Append to history.csv
    $histRow = [pscustomobject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = $ModeName
        Preset           = $PresetName
        EstimatedBytes   = $script:Stats.EstimatedBytes
        DeletedBytes     = $script:Stats.FreedBytes
        QuarantinedBytes = $script:Stats.QuarantinedBytes
        FreeSpaceBefore  = $PreScan.FreeSpaceBefore
        FreeSpaceAfter   = $freeAfter
        VolumeDeltaBytes = $volDelta
        LockedFiles      = $script:Stats.LockedCount
        Errors           = $script:Stats.ErrorCount
        DurationSec      = [int]$script:RunStopwatch.Elapsed.TotalSeconds
    }
    $histRow | Export-Csv -LiteralPath $script:HistoryCsv -Append -NoTypeInformation -Encoding UTF8

    if ($ReportPath) {
        $Categories | Select-Object Id, Name, Risk, FileCount, EstimatedBytes, Confirmed, DisabledReason |
            Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    }

    # Build HTML tables
    $preRows = ($PreScan.Checks | ForEach-Object {
        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Status))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Check))</td><td title='$([System.Net.WebUtility]::HtmlEncode($_.Detail))'>$([System.Net.WebUtility]::HtmlEncode($_.Detail))</td></tr>"
    }) -join "`n"

    $catRows = ($Categories | ForEach-Object {
        $sz = if ($_.EstimatedBytes -lt 0) { 'est. n/a' } else { Format-Bytes $_.EstimatedBytes }
        $st = if ($_.DisabledReason) { "Disabled: $($_.DisabledReason)" } elseif ($_.Confirmed) { 'Confirmed' } else { 'Skipped' }
        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($_.Risk))</td><td title='$([System.Net.WebUtility]::HtmlEncode($_.Name))'>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.FileCount)</td><td>$sz</td><td>$([System.Net.WebUtility]::HtmlEncode($st))</td></tr>"
    }) -join "`n"

    $roHtml = ''
    if ($ReadOnlyReports) {
        $appRows = ($ReadOnlyReports.InstalledApps | ForEach-Object {
            "<tr><td title='$([System.Net.WebUtility]::HtmlEncode($_.DisplayName))'>$([System.Net.WebUtility]::HtmlEncode($_.DisplayName))</td><td>$([System.Net.WebUtility]::HtmlEncode($_.DisplayVersion))</td><td>$($_.Size)</td></tr>"
        }) -join "`n"
        $dlRows = ($ReadOnlyReports.OldDownloads | ForEach-Object {
            "<tr><td title='$([System.Net.WebUtility]::HtmlEncode($_.Path))'>$([System.Net.WebUtility]::HtmlEncode($_.Path))</td><td>$($_.Size)</td></tr>"
        }) -join "`n"
        $roHtml = @"
<div class="grid2">
  <div class="card"><h2>Top Installed Applications by Size</h2><table><thead><tr><th>Application</th><th>Version</th><th>Size</th></tr></thead><tbody>$appRows</tbody></table></div>
  <div class="card"><h2>Old Downloads (&gt;180 Days, Untouched)</h2><table><thead><tr><th>File Path</th><th>Size</th></tr></thead><tbody>$dlRows</tbody></table></div>
</div>
"@
    }

    $clockTime = Get-Date -Format 'HH:mm'
    $clockParts = $clockTime -split ':'
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Win11 Disk Cleanup Report - $($script:Timestamp)</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0b0f19; color: #e2e8f0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 20px 28px; max-width: 1920px; margin: 0 auto; overflow-x: hidden; }
  header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #1e293b; padding-bottom: 12px; margin-bottom: 18px; }
  h1 { font-size: 1.5rem; color: #38bdf8; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  h2 { font-size: 1.05rem; color: #94a3b8; margin-bottom: 10px; text-transform: uppercase; letter-spacing: 0.05em; white-space: nowrap; }
  .clock { font-family: Consolas, monospace; font-size: 1.4rem; color: #22d3ee; white-space: nowrap; }
  .blink { animation: blinker 1s step-start infinite; }
  @keyframes blinker { 50% { opacity: 0; } }
  .kpis { display: grid; grid-template-columns: repeat(5, 1fr); gap: 14px; margin-bottom: 18px; }
  .kpi { background: #111827; border: 1px solid #1f2937; border-radius: 8px; padding: 12px 16px; overflow: hidden; }
  .kpi .lbl { font-size: 0.8rem; color: #94a3b8; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
  .kpi .val { font-size: 1.35rem; font-weight: 700; color: #f8fafc; margin-top: 4px; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
  .card { background: #111827; border: 1px solid #1f2937; border-radius: 8px; padding: 14px; overflow: hidden; }
  table { width: 100%; border-collapse: collapse; table-layout: fixed; font-size: 0.85rem; }
  th, td { padding: 6px 8px; text-align: left; border-bottom: 1px solid #1e293b; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  th { color: #38bdf8; font-weight: 600; }
  footer { margin-top: 14px; font-size: 0.8rem; color: #64748b; display: flex; justify-content: space-between; white-space: nowrap; }
</style>
</head>
<body>
<header>
  <h1>Windows 11 System Disk Cleanup &amp; Diagnostic Report ($env:COMPUTERNAME)</h1>
  <div class="clock">$($clockParts[0])<span class="blink">:</span>$($clockParts[1])</div>
</header>
<div class="kpis">
  <div class="kpi"><div class="lbl">Free Space Before</div><div class="val">$(Format-Bytes $PreScan.FreeSpaceBefore)</div></div>
  <div class="kpi"><div class="lbl">Free Space After</div><div class="val">$(Format-Bytes $freeAfter)</div></div>
  <div class="kpi"><div class="lbl">Net Volume Change</div><div class="val">$(Format-Bytes $volDelta)</div></div>
  <div class="kpi"><div class="lbl">Deleted / Quarantined</div><div class="val">$(Format-Bytes $script:Stats.FreedBytes) / $(Format-Bytes $script:Stats.QuarantinedBytes)</div></div>
  <div class="kpi"><div class="lbl">Locked / Errors</div><div class="val">$($script:Stats.LockedCount) / $($script:Stats.ErrorCount)</div></div>
</div>
<div class="grid2">
  <div class="card">
    <h2>Pre-Scan Health Checks</h2>
    <table><thead><tr><th style="width:16%">Status</th><th style="width:34%">Check</th><th style="width:50%">Detail</th></tr></thead><tbody>$preRows</tbody></table>
  </div>
  <div class="card">
    <h2>Cleanup Categories</h2>
    <table><thead><tr><th style="width:16%">Risk</th><th style="width:42%">Category</th><th style="width:12%">Items</th><th style="width:15%">Estimate</th><th style="width:15%">Action</th></tr></thead><tbody>$catRows</tbody></table>
  </div>
</div>
$roHtml
<footer>
  <div>Log: $([System.Net.WebUtility]::HtmlEncode($script:LogFile))</div>
  <div>Driver Backup: $([System.Net.WebUtility]::HtmlEncode($(if ($DriverBackupDir) {$DriverBackupDir} else {'None'}))) | EventLog Backup: $([System.Net.WebUtility]::HtmlEncode($(if ($EventLogBackupDir) {$EventLogBackupDir} else {'None'}))) | Quarantine: $([System.Net.WebUtility]::HtmlEncode($(if ($QuarantineDir) {$QuarantineDir} else {'None'})))</div>
</footer>
</body>
</html>
"@
    Set-Content -LiteralPath $script:HtmlReportFile -Value $html -Encoding UTF8
    if ($ReportCopyPath) {
        try { Copy-Item -LiteralPath $script:HtmlReportFile -Destination $ReportCopyPath -Force } catch { }
    }

    return [pscustomobject]@{
        FreeBefore = $PreScan.FreeSpaceBefore
        FreeAfter  = $freeAfter
        VolDelta   = $volDelta
        ReportFile = $script:HtmlReportFile
    }
}

# ============================================================================
# MAIN ENTRYPOINT
# ============================================================================
try {
    Initialize-DirectoriesAndLog
    Initialize-Exclusions

    Write-Host '=======================================================================' -ForegroundColor Cyan
    Write-Host '   WINDOWS 11 SAFE SYSTEM DISK CLEANUP, DRIVER BACKUP & REPAIR (v6)    ' -ForegroundColor Cyan
    Write-Host '=======================================================================' -ForegroundColor Cyan
    Write-Host '  1  Cleanup        (Pre-Scan -> Scan -> Confirm Each -> Backup -> Clean)'
    Write-Host '  2  System Repair  (DISM ScanHealth / RestoreHealth + SFC /scannow)'
    Write-Host '  3  Reports Only   (Read-only Top Folders, Old Downloads, App Sizes)'
    Write-Host '  Q  Quit'
    $modeChoice = Read-Host "`nSelect Mode [1]"
    if ([string]::IsNullOrWhiteSpace($modeChoice)) { $modeChoice = '1' }
    if ($modeChoice -match '^[Qq]$') {
        Write-Host 'Exiting without changes.' -ForegroundColor Gray
        exit 0
    }

    $preScan = Invoke-PreScan
    if ($preScan.HasBlocker) {
        Write-Host '[ABORTED] Pre-Scan detected a blocking condition. Nothing was modified.' -ForegroundColor Red
        exit 1
    }

    if ($modeChoice -eq '2') {
        Set-PreventSleep -Enable $true
        $rep = Invoke-SystemRepair
        $catsEmpty = New-Object 'System.Collections.Generic.List[pscustomobject]'
        $sum = Export-HtmlReportAndHistory -ModeName 'Repair' -PresetName 'N/A' -PreScan $preScan `
            -Categories $catsEmpty -ExecutionResults @() -DriverBackupDir '' -QuarantineDir '' -RepairResults $rep -ReadOnlyReports $null
        Write-Host "`nHTML Report saved to: $($sum.ReportFile)" -ForegroundColor Green
        exit 0
    }

    if ($modeChoice -eq '3') {
        $ro = Get-DiskReadOnlyReports
        $catsEmpty = New-Object 'System.Collections.Generic.List[pscustomobject]'
        $sum = Export-HtmlReportAndHistory -ModeName 'ReportsOnly' -PresetName 'N/A' -PreScan $preScan `
            -Categories $catsEmpty -ExecutionResults @() -DriverBackupDir '' -QuarantineDir '' -RepairResults @() -ReadOnlyReports $ro
        Write-Host "`nHTML Report saved to: $($sum.ReportFile)" -ForegroundColor Green
        $openAns = Read-Host 'Open HTML report in browser? [Y/n]'
        if ($openAns -notmatch '^[Nn]$') { Start-Process $sum.ReportFile }
        exit 0
    }

    # Mode 1: Cleanup
    Invoke-ExpiredQuarantinePurge

    $allUsersAns = Read-Host 'Include all user profiles on this PC? [y/N]'
    $includeAllUsers = ($allUsersAns -match '^[Yy]$')

    Write-Host "`nSelect Confirmation Preset (merely sets default [Y/n] vs [y/N]; every category is still asked):" -ForegroundColor Cyan
    Write-Host '  1  Manual   (Every prompt defaults to No [y/N])'
    Write-Host '  2  Quick    (Safe categories default to Yes)'
    Write-Host '  3  Standard (Safe + DISM Component Cleanup + Old Drivers default to Yes)'
    Write-Host '  4  Deep     (All Safe & Moderate categories except Office cache default to Yes)'
    $presetAns = Read-Host 'Choice [1]'
    $presetName = switch ($presetAns) {
        '2'     { 'Quick' }
        '3'     { 'Standard' }
        '4'     { 'Deep' }
        default { 'Manual' }
    }

    $categories = Get-CleanupCategories -IncludeAllUsers $includeAllUsers -DisabledMap $preScan.DisabledCategories
    Measure-AllCategories -Categories $categories
    Show-ScanTable -Categories $categories

    $proceedConfirm = Read-AllCategoryConfirmations -Categories $categories -Preset $presetName
    if (-not $proceedConfirm) {
        Write-Host "`n[CANCELLED] User aborted during confirmation. Nothing was deleted." -ForegroundColor Yellow
        exit 0
    }

    $selectedCats = @($categories | Where-Object { $_.Confirmed })
    if ($selectedCats.Count -eq 0) {
        Write-Host "`n[INFO] No categories were selected for cleanup. Exiting cleanly." -ForegroundColor Yellow
        exit 0
    }

    # Ask Delete vs Quarantine if any selected category supports quarantine
    $useQuarantine = $false
    $quarantineDir = ''
    $quarantinableBytes = [int64](($selectedCats | Where-Object { $_.CanQuarantine -and $_.EstimatedBytes -gt 0 } | Measure-Object -Property EstimatedBytes -Sum).Sum)
    if ($quarantinableBytes -gt 0) {
        $dqAns = Read-Host "`nMode for file-based categories: (D)elete permanently or (Q)uarantine for $QuarantineDays days on another drive? [D/q]"
        if ($dqAns -match '^[Qq]$') {
            $qLoc = Select-StorageLocation -Purpose 'Win11Quarantine' -RequiredBytes $quarantinableBytes -AllowSystemDrive $false
            if ($qLoc.Action -eq 'Quit') { exit 0 }
            if ($qLoc.Action -eq 'Selected') {
                $useQuarantine = $true
                $quarantineDir = $qLoc.Path
            } else {
                Write-Host '  [INFO] Quarantine skipped; reverting to permanent delete.' -ForegroundColor Yellow
            }
        }
    }

    # Ask where to save Driver Backup (always on ANOTHER drive, never C:!)
    $driverBackupDir = ''
    $drvCat = $selectedCats | Where-Object { $_.Id -eq 'OldDrivers' } | Select-Object -First 1
    $wantDriverBackup = ($null -ne $drvCat)
    if (-not $wantDriverBackup) {
        $askBk = Read-Host "`nBack up all third-party drivers to another drive before cleaning? [Y/n]"
        if ($askBk -notmatch '^[Nn]$') { $wantDriverBackup = $true }
    }
    if ($wantDriverBackup) {
        $repoSize = [int64]1GB
        $loc = Select-StorageLocation -Purpose 'DriverBackup' -RequiredBytes $repoSize -AllowSystemDrive $false -PresetPath $DriverBackupPath
        if ($loc.Action -eq 'Quit') { exit 0 }
        if ($loc.Action -eq 'Skip') {
            if ($drvCat) {
                $drvCat.Confirmed = $false
                $selectedCats = @($categories | Where-Object { $_.Confirmed })
                Write-Host '  [INFO] Driver backup skipped; Superseded Device Driver Packages cleanup has been DISABLED.' -ForegroundColor Yellow
            } else {
                Write-Host '  [INFO] Optional driver backup skipped.' -ForegroundColor Yellow
            }
        } else {
            $driverBackupDir = $loc.Path
        }
    }

    # Ask where to save Windows Event Log Backup if EventLogs is selected (always on ANOTHER drive, never C:!)
    $eventLogBackupDir = ''
    $evtCat = $selectedCats | Where-Object { $_.Id -eq 'EventLogs' } | Select-Object -First 1
    if ($evtCat) {
        $evtSize = [math]::Max([int64]50MB, $evtCat.EstimatedBytes)
        $eLoc = Select-StorageLocation -Purpose 'EventLogBackup' -RequiredBytes $evtSize -AllowSystemDrive $false -PresetPath $EventLogBackupPath
        if ($eLoc.Action -eq 'Quit') { exit 0 }
        if ($eLoc.Action -eq 'Skip') {
            $evtCat.Confirmed = $false
            $selectedCats = @($categories | Where-Object { $_.Confirmed })
            Write-Host '  [INFO] Event Log backup skipped; Windows Event Logs cleanup has been DISABLED.' -ForegroundColor Yellow
        } else {
            $eventLogBackupDir = $eLoc.Path
        }
    }

    # Final Summary before touching anything
    $totalSelectedBytes = [int64](($selectedCats | Where-Object { $_.EstimatedBytes -gt 0 } | Measure-Object -Property EstimatedBytes -Sum).Sum)
    $script:Stats.EstimatedBytes = $totalSelectedBytes

    Write-Host "`n============================== FINAL SUMMARY ==============================" -ForegroundColor Cyan
    foreach ($sc in $selectedCats) {
        $sz = if ($sc.EstimatedBytes -lt 0) { 'est. n/a' } else { Format-Bytes $sc.EstimatedBytes }
        Write-Host ('  * [{0,-12}] {1,-48} ({2})' -f $sc.Risk, $sc.Name, $sz)
    }
    Write-Host ('-' * 75) -ForegroundColor DarkGray
    Write-Host ("  Selected Categories : {0}" -f $selectedCats.Count)
    Write-Host ("  Estimated Reclaim   : {0}" -f (Format-Bytes $totalSelectedBytes))
    Write-Host ("  Action Mode         : {0}" -f $(if ($useQuarantine) { "Quarantine ($quarantineDir)" } else { 'Permanent Delete' }))
    if ($driverBackupDir) {
        Write-Host ("  Driver Backup Path  : {0}" -f $driverBackupDir)
    }
    if ($eventLogBackupDir) {
        Write-Host ("  EventLog Backup Path: {0}" -f $eventLogBackupDir)
    }
    Write-Host "===========================================================================`n" -ForegroundColor Cyan

    $finalGo = Read-Host 'Proceed with cleanup now? Type Y to execute'
    if ($finalGo -notmatch '^[Yy]$') {
        Write-Host '[CANCELLED] Nothing was modified.' -ForegroundColor Yellow
        exit 0
    }

    Set-PreventSleep -Enable $true
    Invoke-OptionalRestorePoint -SystemRestoreEnabled $preScan.SystemRestoreOn

    # Execute driver backup if a backup destination was chosen
    if ($driverBackupDir) {
        $bkOk = Backup-Drivers -DestinationPath $driverBackupDir
        if (-not $bkOk -and $drvCat) {
            $drvCat.Confirmed = $false
            Write-Host '[WARN] Driver cleanup was deselected because driver backup verification did not pass.' -ForegroundColor Yellow
        }
    }

    # Execute mandatory Event Log backup if EventLogs is still confirmed
    if ($evtCat -and $evtCat.Confirmed) {
        $evtOk = Backup-EventLogs -DestinationPath $eventLogBackupDir -ScannedEvtxFiles $evtCat.ScannedFiles
        if (-not $evtOk) {
            $evtCat.Confirmed = $false
            Write-Host '[WARN] Event Log cleanup was deselected because Event Log backup verification did not pass.' -ForegroundColor Yellow
        }
    }

    $execResults = Invoke-ConfirmedCategories -Categories $categories -UseQuarantine $useQuarantine -QuarantineSetDir $quarantineDir
    Invoke-SsdTrimIfApplicable -IsSsd $preScan.IsSsd

    $roAns = Read-Host "`nInclude read-only disk analysis (Top folders, Old Downloads, Installed App sizes) in the HTML report? [y/N]"
    $roData = if ($roAns -match '^[Yy]$') { Get-DiskReadOnlyReports } else { $null }

    $summary = Export-HtmlReportAndHistory -ModeName 'Cleanup' -PresetName $presetName -PreScan $preScan `
        -Categories $categories -ExecutionResults $execResults -DriverBackupDir $driverBackupDir `
        -EventLogBackupDir $eventLogBackupDir -QuarantineDir $quarantineDir -RepairResults @() -ReadOnlyReports $roData

    Complete-AllProgress

    Write-Host "`n============================== CLEANUP COMPLETE ==============================" -ForegroundColor Green
    Write-Host ("  Free Space Before      : {0}" -f (Format-Bytes $summary.FreeBefore))
    Write-Host ("  Free Space After       : {0}" -f (Format-Bytes $summary.FreeAfter))
    Write-Host ("  Net Volume Gain        : {0}" -f (Format-Bytes $summary.VolDelta))
    Write-Host ("  Deleted by Script      : {0}" -f (Format-Bytes $script:Stats.FreedBytes))
    if ($useQuarantine) {
        Write-Host ("  Moved to Quarantine    : {0} ({1})" -f (Format-Bytes $script:Stats.QuarantinedBytes), $quarantineDir)
    }
    Write-Host ("  Locked / Skipped Files : {0}" -f $script:Stats.LockedCount)
    Write-Host ("  Log File               : {0}" -f $script:LogFile)
    Write-Host ("  HTML Report            : {0}" -f $summary.ReportFile)
    Write-Host "==============================================================================`n" -ForegroundColor Green

    $openReport = Read-Host 'Open HTML report in browser? [Y/n]'
    if ($openReport -notmatch '^[Nn]$') {
        Start-Process $summary.ReportFile
    }
    Read-Host "`nCleanup session finished. Press Enter to close this window"
} catch {
    Complete-AllProgress
    Write-Host "`n[FATAL ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    try { Write-Log -Message "FATAL ERROR: $($_.Exception.Message) | $($_.InvocationInfo.PositionMessage)" -Level 'ERROR' } catch { }
    Read-Host "`nPress Enter to close this window"
} finally {
    Complete-AllProgress
    Set-PreventSleep -Enable $false
    try { $Host.UI.RawUI.WindowTitle = $script:OriginalTitle } catch { }
}

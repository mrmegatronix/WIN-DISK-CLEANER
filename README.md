# WIN-DISK-CLEANER (`Win11-DiskCleanup.ps1`)

Safe, scan-first, confirm-all Windows 11 system disk cleanup, driver backup, Windows Event Log backup, WSL2/Docker `.vhdx` compaction, `Windows.edb` index rebuild, 7-day quarantine, system repair, and 1080p HTML reporting utility.

## Files
- [`Win11-DiskCleanup.ps1`](./Win11-DiskCleanup.ps1) — Main PowerShell 5.1 cleanup, driver backup, Event Log backup, quarantine, system repair, and reporting script.
- [`Run-Cleanup.cmd`](./Run-Cleanup.cmd) — Double-click batch launcher (automatically launches Windows PowerShell 5.1 and elevates to Administrator).
- [`exclusions.txt`](./exclusions.txt) — Wildcard exclusion patterns skipped during scan and cleanup.
- [`index.html`](./index.html) — 1080p web overview and quick-download portal.

## Usage
1. **One-line remote launch (Elevated PowerShell):**
   ```powershell
   irm https://mrmegatronix.github.io/WIN-DISK-CLEANER/Win11-DiskCleanup.ps1 -OutFile $env:TEMP\Win11-DiskCleanup.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\Win11-DiskCleanup.ps1
   ```
2. **Local launch:** Double-click `Run-Cleanup.cmd` or run:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Win11-DiskCleanup.ps1
   ```
3. **Optional parameters:**
   ```powershell
   .\Win11-DiskCleanup.ps1 -MinAgeHours 24 -SagesetNumber 500 -QuarantineDays 7 -DriverBackupPath D:\Backups -EventLogBackupPath D:\Backups -ReportPath .\scan.csv
   ```

## Restoring Backups & Quarantine
- **Driver Restore:** Open your selected `DriverBackup\<PC>_<Timestamp>` folder and run `Restore-Drivers.cmd` as Administrator.
- **Event Log Archive:** Open your selected `EventLogBackup\<PC>_<Timestamp>` folder and run `Open-EventViewer.cmd` or inspect `eventlogs_inventory.csv`.
- **Quarantine Restore:** Open your selected `Win11Quarantine\<PC>_<Timestamp>` folder and run `Restore-Quarantine.ps1` as Administrator.

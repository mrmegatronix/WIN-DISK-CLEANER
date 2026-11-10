# WIN-DISK-CLEANER (`Win11-DiskCleanup.ps1`)

Safe, scan-first, confirm-all Windows 11 system disk cleanup, driver backup, 7-day quarantine, system repair, and 1080p HTML reporting utility.

## Files
- [`Win11-DiskCleanup.ps1`](./Win11-DiskCleanup.ps1) — Main PowerShell 5.1 cleanup, driver backup, quarantine, system repair, and reporting script.
- [`Run-Cleanup.cmd`](./Run-Cleanup.cmd) — Double-click batch launcher (automatically launches Windows PowerShell 5.1 and elevates to Administrator).
- [`exclusions.txt`](./exclusions.txt) — Wildcard exclusion patterns skipped during scan and cleanup.
- [`index.html`](./index.html) — 1080p web overview and quick-download portal.

## Usage
1. Double-click `Run-Cleanup.cmd` or run from PowerShell:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Win11-DiskCleanup.ps1
   ```
2. Optional parameters:
   ```powershell
   .\Win11-DiskCleanup.ps1 -MinAgeHours 24 -SagesetNumber 500 -QuarantineDays 7 -ReportPath .\scan.csv
   ```

## Restoring Drivers or Quarantined Files
- **Driver Restore:** Open your selected `DriverBackup\<PC>_<Timestamp>` folder and run `Restore-Drivers.cmd` as Administrator.
- **Quarantine Restore:** Open your selected `Win11Quarantine\<PC>_<Timestamp>` folder and run `Restore-Quarantine.ps1` as Administrator.

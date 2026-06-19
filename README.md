# ScanImageAutomation

PowerShell automation for ScanImage-adjacent workflows.

This project intentionally stays separate from `MATLAB\UserFunction`:

- `MATLAB\UserFunction`: MATLAB user functions called directly by ScanImage.
- `ScanImageAutomation`: upload automation, Discord notifications, background workers, scheduled-task installers, logs, docs, and operational scripts.

## Important Paths

- Upload script: `scripts\upload\upload_completed_sessions_from_config.ps1`
- Upload task installer: `scripts\upload\install_session_upload_task_from_config.ps1`
- Discord helper: `scripts\discord\Send-DiscordAlert.ps1`
- Copy worker: `workers\CopyWorker\external_copy_worker.ps1`
- Upload config: `config\upload_sessions_config.json`
- Upload config template: `config\upload_sessions_config.template.json`

Runtime logs, state files, local configs, and generated artifacts are ignored by git.

## Dry-Run Tests

Use the 2026-06-18 data as a non-uploading regression set:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1" `
  -SessionDate 2026-06-18 `
  -DryRun
```

Use today's routine filter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1" `
  -DryRun
```

Install or refresh the daily upload task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\install_session_upload_task_from_config.ps1"
```

## Upload Screening

Before uploading, `upload_completed_sessions_from_config.ps1` checks each
session folder and its `external_copy_status.json`.

Normal upload requires:

- Required local files exist: `.tif`, `.h5`, tracking `.mp4`, and timestamp `.csv`
- Major data files are non-empty
- The folder is stable for `stableMinutes`
- Animal code evidence is consistent when `strictAnimalCode` is enabled
- `external_copy_status.json` exists when `requireCopyStatus` is enabled
- CopyWorker status is `DONE`
- CopyWorker `fail_count` is `0`
- CopyWorker warnings are allowed only when `allowWarnings` is enabled

If a session fails screening, upload is skipped and a Discord alert is sent when
Discord is enabled in `config\upload_sessions_config.json`.

Manual review is stored inside the same `external_copy_status.json`; no extra
marker file is required in the session folder. A reviewed session is included in
future upload scans for up to `manualReviewRetryDays` days, default 3, so old
sessions do not stay in the retry pool forever.

Approve a session after checking a CopyWorker failure:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\set_upload_manual_review.ps1" `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER_NAME" `
  -ReviewedBy "jisoo" `
  -Note "Checked manually; missing BPod summary is acceptable." `
  -AllowCopyStatusFailure
```

Approve a session while explicitly allowing a missing pattern:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\set_upload_manual_review.ps1" `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER_NAME" `
  -ReviewedBy "jisoo" `
  -Note "Tracking timestamps intentionally unavailable." `
  -AllowMissingPatterns "*timestamps*.csv"
```

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

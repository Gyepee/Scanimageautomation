# ScanImageAutomation

Operational PowerShell automation for ScanImage session cleanup, external file
copying, upload gating, and Discord notifications.

This repository intentionally tracks only reusable code and templates. Runtime
state, logs, machine-specific configs, and backups are ignored by git.

## Active Automations

- `ScanImageCompletedSessionUpload`
  - Runs daily at 20:00.
  - Calls `scripts\upload\upload_completed_sessions_from_config.ps1`.
  - Uploads complete session folders after local validation.

- `ScanImageCopySourceNetworkCheck`
  - Runs daily at 00:00.
  - Calls `scripts\network\check_copy_sources.ps1`.
  - Checks access to the Mini2P auxiliary tracking and BPod shares.

- `workers\CopyWorker\external_copy_worker.ps1`
  - Launched by the ScanImage/MATLAB consolidation user function through job
    files under `state\copy_jobs`.
  - Copies tracking, BPod session outputs, and protocol backups.
  - Writes `external_copy_status.json` into each session folder.

## Core Files

- `workers\CopyWorker\external_copy_worker.ps1`
  - External copy worker.
  - Guards BPod `.mat` timing against the ScanImage `.tif/.h5` reference.
  - Keeps BPod summary `.txt/.csv` paired to the selected `.mat`.

- `scripts\upload\upload_completed_sessions_from_config.ps1`
  - Upload gate and transfer runner.
  - Requires expected imaging, tracking, and copy status evidence before upload.
  - Ignores metadata files when checking folder stability.

- `scripts\upload\verify_session_folder_for_upload.ps1`
  - Manual repair helper.
  - Re-checks a session folder after files are manually fixed and can rewrite
    `external_copy_status.json` with `-UpdateStatus`.

- `scripts\upload\set_upload_manual_review.ps1`
  - Exception helper.
  - Records a manual approval in `external_copy_status.json` when an upload
    should proceed despite a known allowed issue.

- `scripts\network\check_copy_sources.ps1`
  - Verifies the tracking and BPod network shares.

- `scripts\discord\Send-DiscordAlert.ps1`
  - Shared Discord webhook sender.

## Local Configs

Copy these templates to machine-local config files and fill them in locally:

- `config\upload_sessions_config.template.json`
- `config\copy_sources_config.template.json`

The real config files are intentionally ignored:

- `config\upload_sessions_config.json`
- `config\copy_sources_config.json`

## Useful Commands

Dry-run upload screening:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1" `
  -DryRun
```

Verify a manually repaired session and rewrite its status:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\verify_session_folder_for_upload.ps1" `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER_NAME" `
  -UpdateStatus
```

Approve a reviewed exception:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\set_upload_manual_review.ps1" `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER_NAME" `
  -ReviewedBy "jisoo" `
  -Note "Checked manually; allowed exception." `
  -AllowCopyStatusFailure
```

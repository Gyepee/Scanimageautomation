# ScanImage Automation Operations

> Current architecture and version compatibility are defined in
> `WORKFLOW_GUIDE.md`. This file keeps recovery-oriented commands and older
> operational notes. If the two documents differ, follow `WORKFLOW_GUIDE.md`.

This repo is the PowerShell side of the ScanImage session consolidation and
upload workflow. It does not contain the ScanImage MATLAB user functions
themselves, but it is launched by them and depends on their naming rules.

## System Shape

1. ScanImage finishes a grab.
2. MATLAB user function consolidates local ScanImage outputs into a session
   folder under `F:\Data\jisooj`.
3. MATLAB writes an external copy job under this repo's `state\copy_jobs`.
4. `workers\CopyWorker\external_copy_worker.ps1` copies Bonsai tracking and
   BPod files into that session folder.
5. `external_copy_status.json` is written inside the session folder.
6. The scheduled upload worker validates complete session folders and uploads
   them to the configured remote.

## MATLAB Entry Points

These files live outside this repo:

- `C:\Users\ScanImage\Documents\MATLAB\UserFunction\userfcn_LocalConsolidate.m`
  - Main ScanImage consolidation callback.
  - Moves local `.tif` and `.h5` files into a session folder.
  - Prefixes moved files with `scan<experimentID>_`.
  - Queues the PowerShell copy worker by writing a JSON job file.

- `C:\Users\ScanImage\Documents\MATLAB\UserFunction\userfunction_getfileID.m`
  - Generates the `scan...` / `sess...` ID.
  - Rule: `dec2base(int64(now() * 10^6), 36, 8)`.
  - IDs such as `9G0XLGF4` are base36 timestamps, not random strings.

- `C:\Users\ScanImage\Documents\MATLAB\UserFunction\userfcn_InstallPreGrabGuard.m`
  - Installs the settings-only pre-GRAB guard.
  - It never moves TIFF/H5 files.

## Session Naming

Session folders follow:

```text
JJ_ROS-2325_2026-06-29_scan9G0XLGF4_sess9G0XLGF4
```

Imaging pairs preserve the ScanImage numbering:

```text
scan9G0XLGF4_JJ_ROS-2325_02028.tif
scan9G0XLGF4_JJ_ROS-2325_2028.h5
```

The `.tif` number is zero-padded (`02028`); the `.h5` uses the same number
without that extra leading zero (`2028`).

If files are recovered from `_archived_by_preflight`, do not merge different
imaging numbers into an existing session folder. Create or reconstruct the
matching session folder, preserve the imaging number, add the correct
`scan<id>_` prefix, then run the verifier.

## Important Runtime Paths

- Data root: `F:\Data\jisooj`
- Cancelled sessions: `F:\Data\jisooj\_cancelled_sessions\YYYY-MM-DD`
- Unresolved residuals: `F:\Data\jisooj\_unresolved_sessions\YYYY-MM-DD`
- Historical preflight archive (legacy only): `F:\Data\jisooj\_archived_by_preflight`
- Copy jobs: `state\copy_jobs`
- Tracking repair jobs: `state\tracking_repair_jobs`
- Upload state: `state\upload_state`
- Upload logs: `state\upload_state\logs`

Runtime state and real configs are intentionally ignored by git.

## Main Scripts

- `workers\CopyWorker\external_copy_worker.ps1`
  - Reads copy job JSON.
  - Copies Bonsai tracking video/timestamps and BPod session files.
  - Writes `external_copy_status.json`.
  - Creates tracking repair jobs when copied MP4 files are not finalized.

- `workers\TrackingRepairWorker\mp4checker.ps1`
  - Re-checks pending MP4 repair jobs.
  - Copies finalized MP4/CSV files when the Bonsai source later becomes valid.
  - Re-runs the session verifier.

- `scripts\upload\verify_session_folder_for_upload.ps1`
  - Re-validates one session folder.
  - Use after manual repair or manual consolidation.

- `scripts\upload\upload_completed_sessions_from_config.ps1`
  - Scheduled upload gate.
  - Runs pre-upload MP4 repair.
  - Uploads folders only after local validation passes.

## Discord Policy

Discord should be actionable, not noisy.

- Send Discord when an error appears.
- Send Discord once per day if the same error is still unresolved.
- Do not send Discord for normal success, repair success, verifier success, or
  upload success.
- Normal success is recorded in logs and JSON state instead.

Useful records:

- Session status: `F:\Data\jisooj\<SESSION>\external_copy_status.json`
- Upload completion: `state\upload_state\<SESSION>.uploaded.json`
- Upload logs: `state\upload_state\logs\upload_completed_sessions_YYYYMMDD.log`
- Tracking repair state: `state\tracking_repair_jobs\*.json`

## Common Commands

Dry-run upload screening:

```powershell
.\scripts\upload\upload_completed_sessions_from_config.ps1 -DryRun
```

Verify and rewrite one session status:

```powershell
.\scripts\upload\verify_session_folder_for_upload.ps1 `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER_NAME" `
  -UpdateStatus
```

Run pending MP4 repair jobs once:

```powershell
.\mp4checker.ps1 -Once
```

Wrapper for verifying by scan ID:

```powershell
.\verifyworker.ps1 9G0XLGF4 -UpdateStatus
```

## Manual Consolidation Checklist

When someone manually moved files or preflight archived a valid session:

1. Identify the animal/date and imaging pair.
2. Reconstruct the folder name using the ScanImage ID rule if possible.
3. Copy imaging files with `scan<id>_` prefixes.
4. Add matching Bonsai tracking MP4/CSV by timestamp.
5. Add matching BPod `.mat`, summary `.txt`, summary `.csv`, and backup `.m`.
6. Run `verify_session_folder_for_upload.ps1 -UpdateStatus`.
7. Run upload dry-run and confirm the folder is `DRYRUN would upload`, not
   `WAIT`.

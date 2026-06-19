# 2026-06-18 Upload Miss Root Cause

## Summary

The 2026-06-18 sessions were locally consolidated and complete, but they were not actually uploaded.

Evidence found on 2026-06-19:

- Six local session folders exist under `F:\Data\jisooj` for `2026-06-18`.
- All six pass the upload script completeness checks in dry-run mode.
- No `*.uploaded.json` state files exist for `2026-06-18`.
- The only 2026-06-18 upload run log shows `DryRun=True`.
- No `transfer_20260618_2000*.log` file was created.
- After refreshing the task on 2026-06-19, Task Scheduler reported `Last Run Time: 6/18/2026 8:00:00 PM` and `Last Result: 1`, meaning the 20:00 scheduled run failed.

## Local Sessions Checked

- `JJ_ROS-2325_2026-06-18_scan9G0R1ML1_sess9G0R1ML1`
- `JJ_ROS-2326_2026-06-18_scan9G0R2GE3_sess9G0R2GE3`
- `JJ_ROS-2329_2026-06-18_scan9G0R3C7F_sess9G0R3C7F`
- `JJ_ROS-2309_2026-06-18_scan9G0R66SH_sess9G0R66SH`
- `JJ_ROS-2314_2026-06-18_scan9G0R6UWS_sess9G0R6UWS`
- `JJ_ROS-2316_2026-06-18_scan9G0R7LXQ_sess9G0R7LXQ`

## Most Likely Cause

The scheduled upload task did not perform a real upload on 2026-06-18.

The handoff note from 2026-06-18 says the previous scheduled task was pointing at non-existent paths:

- Broken script path: `MATLAB\UserFunction\upload_completed_sessions_from_config.ps1`
- Broken config path: `MATLAB\UserFunction\upload_sessions_config.json`

The only observed 2026-06-18 run was a manual or test dry-run at 16:59:

```text
Starting upload scan ... SessionDate=2026-06-18 DryRun=True
DRYRUN would upload: ...
Upload scan finished.
```

Because it was a dry-run, it intentionally did not upload files and did not write `.uploaded.json` state markers.

Task Scheduler also showed that the 20:00 scheduled run on 2026-06-18 exited with result code `1`, so the automatic route failed independently of the dry-run test.

## Secondary Finding

`scripts\upload\install_session_upload_task_from_config.ps1` previously hid `schtasks /Create` output and did not verify that the task was queryable after creation. That made it possible to see a success-looking message even when Task Scheduler registration was not actually healthy.

This has been hardened so task creation fails loudly if `schtasks` returns a non-zero exit code or if the task cannot be queried after creation.

## Test Data Policy

Keep the 2026-06-18 sessions unmarked as uploaded until they are intentionally used for upload automation testing.

Regression dry-run command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1" `
  -SessionDate 2026-06-18 `
  -DryRun
```

Today-routine dry-run command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1" `
  -DryRun
```

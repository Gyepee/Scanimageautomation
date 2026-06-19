# Consolidation Logic Notes

This note summarizes the current understanding of the ScanImage user-function
consolidation workflow and the intended direction for testing V3.

## Files

- `userfcn_ConsolidateFilesV2.m`
  - Current baseline consolidation function.
  - Do not modify casually; keep it as the working reference version.

- `userfcn_ConsolidateFilesV3.m`
  - Earlier test version created from the V2 logic.
  - Kept for history/reference while local consolidation is split out.

- `userfcn_LocalConsolidate.m`
  - Current user-function candidate for the local-consolidate workflow.
  - Main purpose: reduce unsafe user mistakes around external Bonsai files.
  - Moves local ScanImage `.tif/.h5` files synchronously.
  - Queues external Bonsai/BPod copy as a background worker job.
  - Should be tested before replacing the V2 workflow.

- `copy_external_files.m`
  - Copies tracking/Bonsai and BPod files into the consolidated session folder.
  - Writes `external_copy_summary.txt`.
  - Already has basic file-stability waiting for copied external files.

- `copy_external_filesV3.m`
  - V3-only external copy helper.
  - Keeps V2 helper untouched.
  - Adds BPod animal-code guarding and operator-focused failure logs.
  - Kept as MATLAB reference logic; current V3 queues the external copy through
    `CopyWorker` instead of calling this directly.

- `C:\Users\ScanImage\Documents\ScanImageAutomation\workers\CopyWorker\external_copy_worker.ps1`
  - Personal non-MATLAB worker program.
  - Runs external Bonsai/BPod copy in the background after V3 creates an
    internal job file under `ScanImageAutomation\state\copy_jobs`.
  - Writes `external_copy_status.json` and `external_copy_summary.txt`.

- `append_session_note_prompt.m`
  - Optional post-consolidation note dialog.

- `userfcn_AddSessionNoteOnModeDone.m`
  - Uses global `LAST_CONSOLIDATED` to append session notes after consolidation.

## Core Workflow

The consolidation function is called after a ScanImage session ends.

High-level flow:

1. Check ScanImage acquisition state.
2. Skip if acquisition was `focus`.
3. Wait until ScanImage becomes `idle`.
4. Close shutters only after ScanImage is idle.
5. Ask the user to stop external systems before consolidation.
6. Create a session-specific folder.
7. Move ScanImage `.tif` files.
8. Move ScanImage AUX `.h5` file.
9. Write an internal copy-worker job under
   `ScanImageAutomation\state\copy_jobs` and write
   `external_copy_status.json` in the session folder.
10. Launch the external copy worker in the background.
11. Return control to ScanImage/MATLAB without waiting for network copy.

## Important Experimental Constraint

Bonsai runs on another PC and writes the tracking files.

The Bonsai files are not guaranteed to be complete until the human operator
manually stops Bonsai. Therefore the user prompt is not just cosmetic. It is a
required safety checkpoint.

The most important external files are:

- `mini2p2_top_video*.mp4`
- `mini2p2_top_video_timestamps*.csv`

Both are Bonsai outputs and should be treated as critical for V3.

BPod is different:

- BPod may still be running or not fully ended.
- This should not block Bonsai/tracking consolidation.
- BPod can be copied if a safe same-animal, same-day, time-matched file is
  available.
- If BPod cannot be matched safely, V3 should continue but mark BPod as failed
  and require manual consolidation.

## V3 Behavior

V3 keeps the manual checkpoint but makes it harder to proceed accidentally.

The first consolidation prompt is now a custom MATLAB dialog instead of a
standard `questdlg`.

Current intent:

- It should be visually obvious.
- It should appear on top when possible.
- It should use large text.
- It should explicitly instruct the user to stop Bonsai and press ESC on BPod.
- The action button says:

```text
Bonsai Stopped, Consolidate
```

Current prompt text:

```text
BEFORE CONSOLIDATION

Do NOT continue until Bonsai has fully stopped. Press ESC on BPod.
```

After this button is pressed, V3 finishes local consolidation and queues the
external copy worker. The worker checks whether Bonsai `.mp4` and timestamp
`.csv` have become size-stable before copying them.

If those files are missing or still changing, the worker records the failure in
`external_copy_status.json` and `external_copy_summary.txt`. It does not block
the next ScanImage session.

The upload automation uses `external_copy_status.json` as the upload gate. A
session is held back and reported to Discord if the status is missing when
required, still `QUEUED`/`RUNNING`, not `DONE`, has a nonzero `fail_count`, or
has warnings while warnings are not allowed.

If the operator manually reviews a held session, the approval is recorded inside
`external_copy_status.json` under `manual_review`. Reviewed sessions are scanned
again for up to `manualReviewRetryDays` days, default 3, so no extra marker files
are needed in the session folder and old sessions do not stay in the retry pool.

## Stability Logic

V3 currently uses simple file-size stability for local ScanImage files. The
background worker uses simple file-size stability for Bonsai outputs.

The helper waits until a file's byte size stays unchanged for a configured
duration.

Important experimental note: size stability is not a perfect proof that a Bonsai
mp4 is finalized. However, `VideoReader`, file-handle checks, and mp4 atom checks
were tested and were either too slow, unreliable on long/network mp4 files, or
too likely to block the experimental workflow. The current V3 design therefore
keeps the code-side check simple and relies on the explicit operator prompt as
the primary safety guard.

BPod is intentionally not waited on in the V3 MATLAB function. BPod `.mat` and
B2B summary `.txt/.csv` files have not been the problematic write/finalization
case, and BPod remains non-blocking. BPod safety is handled by animal-code and
session-time matching in the external copy worker.

Current defaults:

- `localStableSec`: 3 seconds
- `externalStableSec`: 6 seconds
- `externalSettleTimeoutSec`: 90 seconds
- `bpodMaxDiffMin`: 30 minutes
- `externalCopyWorkerDir`: `C:\Users\ScanImage\Documents\ScanImageAutomation\workers\CopyWorker`

Critical V3 behavior:

- Bonsai `.mp4` must be found and size-stable.
- Bonsai timestamp `.csv` must be found and size-stable.
- BPod `.mat` and B2B summary `.txt/.csv` are not waited on in the V3 MATLAB
  function.
- BPod files must come from the same core animal code when copied.
- BPod files must be close enough to the session time when copied.
- BPod mismatch or missing data should be logged as manual action, not silently
  accepted.

If critical Bonsai files never become stable, the worker marks the job as failed
and writes operator action items to `external_copy_summary.txt`.

## Popup Philosophy

The goal is not to remove all popups.

The first manual stop reminder is essential because external writing only stops
after the human operator stops Bonsai.

The goal is to minimize unnecessary popups while keeping the essential warning
very explicit.

Useful popups:

- Initial "stop Bonsai before consolidation" checkpoint.

Less useful popups:

- Repeated generic continue/cancel dialogs.
- Popups for external copy progress/failure; the worker should write status/logs
  instead.
- Popups for BPod availability, since BPod is non-blocking.

## Known Risks / Things To Watch

- `newestfile.m` and `newestfile_samedate.m` have fragile behavior when no file
  is found. They may return dummy or empty values in ways that can hide real
  failure modes.

- `copy_external_filesV3.m` extracts the core `ROS-####` animal code from the
  ScanImage stem and searches BPod animal folders that contain that exact code.
  This supports both `ROS-####` and prefixed names like `JJ_ROS-####`.

- If no safe BPod animal folder is found, or if the closest BPod file is too far
  from the session time, the worker writes a failure/action item to
  `external_copy_summary.txt`.

- MATLAB `JavaFrame` is used as a best-effort way to make the custom dialog
  appear above other windows. It is undocumented. If it fails, the dialog should
  still appear as a normal modal MATLAB dialog.

- `checkcode` currently reports style/deprecation warnings such as `datestr`,
  `now`, `datenum`, `global`, and `JavaFrame`. These are not currently treated
  as blockers for V3 testing.

## Suggested Next Steps

1. Test `userfcn_LocalConsolidate.m` in a dry run with fake or copied Bonsai
   files.
2. Confirm the first dialog is visible above the Bonsai/ScanImage workflow.
3. Confirm the button text is not clipped:

```text
Bonsai Stopped, Consolidate
```

4. Test the mistake case:
   - Click the button before Bonsai has fully stopped.
   - Confirm the worker marks `.mp4` or `.csv` failure if files do not stabilize.
   - Confirm MATLAB returns without blocking the next session.

5. Test the normal case:
   - Stop Bonsai.
   - Press the button.
   - Confirm `.mp4` and `.csv` stabilize and worker copy proceeds.

6. Inspect `external_copy_status.json` and `external_copy_summary.txt` after
   each V3 test. They should read like an operator result sheet: what copied,
   what failed, and what manual action is required.


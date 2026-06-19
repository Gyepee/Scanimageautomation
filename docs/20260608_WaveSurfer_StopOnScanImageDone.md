# 2026-06-08 WaveSurfer Stop-on-ScanImage-Done Patch

## Summary

WaveSurfer was patched so that a ScanImage-normal-completion command stops the current WaveSurfer run.

This makes a long WaveSurfer duration, such as `2500 sec`, act as a maximum duration. If ScanImage finishes first, WaveSurfer should stop instead of continuing to poll DAQmx until the full WaveSurfer duration expires.

## Why

Intermittent NI-DAQmx Error `-200983` was observed when ScanImage had already finished but WaveSurfer was still running.

The likely race was:

1. ScanImage finished the GRAB/LOOP acquisition.
2. ScanImage told WaveSurfer that the acquisition mode completed normally.
3. The unpatched WaveSurfer command handler ignored that normal-completion command.
4. WaveSurfer continued its run and timer-based DAQmx polling.
5. A later WaveSurfer poll queried `DAQmxGetReadAvailSampPerChan` after the relevant DAQmx task was no longer in a state where that property can be read, producing `-200983`.

## Code Change

Target file:

```text
C:\Program Files\+ws\WavesurferModel.m
```

Command handler:

```matlab
case 'did-complete-acquisition-mode-normally'
```

Changed behavior:

```matlab
% Stop the WaveSurfer run so it does not keep polling
% DAQmx after ScanImage has already finished.
self.stop() ;
```

## Expected Runtime Behavior

If WaveSurfer is set to `2500 sec` but ScanImage finishes earlier:

1. ScanImage detects end of acquisition mode.
2. ScanImage runs its shutdown/cleanup path.
3. ScanImage `WSConnector` sends `did-complete-acquisition-mode-normally`.
4. WaveSurfer receives that command.
5. WaveSurfer calls `self.stop()`.

This should happen shortly after ScanImage finishes. It is not exactly instantaneous because ScanImage cleanup, file-based WaveSurfer/ScanImage command polling, and MATLAB scheduling add a small delay. In normal use, expect roughly sub-second to about one second of latency.

## Backups

Local backup made before editing:

```text
C:\Users\ScanImage\Documents\MATLAB\UserFunction\WaveSurfer_backups\20260608_185133\WavesurferModel.m
```

Program Files backup made by the installer:

```text
C:\Program Files\+ws\WavesurferModel.m.bak_20260608_185236
```

`WaveSurfer_backups/` and `WaveSurfer_patch/` are intentionally ignored by git because they contain local copies of third-party WaveSurfer source files.

## Install

Run PowerShell as administrator:

```powershell
cd C:\Users\ScanImage\Documents\MATLAB\UserFunction
.\InstallWaveSurferPatch.ps1
```

Restart WaveSurfer after applying the patch so MATLAB reloads the changed code.

## Restore

Run PowerShell as administrator:

```powershell
cd C:\Users\ScanImage\Documents\MATLAB\UserFunction
.\RestoreWaveSurferFromBackup.ps1 -Backup "C:\Program Files\+ws\WavesurferModel.m.bak_20260608_185236"
```

Then restart WaveSurfer.

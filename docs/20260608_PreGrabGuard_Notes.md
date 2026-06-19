# 2026-06-08 Pre-GRAB Guard Notes

## Goal

Make ScanImage GRAB/LOOP safer for experiments by checking required state before acquisition starts:

- Archive leftover `.tif` and `.h5` files from failed consolidation.
- Ensure the ScanImage data directory is `F:\Data\jisooj`.
- Ensure ScanImage logging/save is enabled.
- Ensure WaveSurfer YOKE is connected.
- Ensure `PortBlankAO` is active before acquisition proceeds.

## Final Approach

The final solution uses a MATLAB property listener installed on `hSI.acqState`.

The listener is installed by:

```matlab
userfcn_InstallPreGrabGuard
```

It listens to:

```matlab
addlistener(hSI, 'acqState', 'PreSet', @preAcqStateSet)
```

This runs before ScanImage changes from `idle` to `grab` or `loop`, so the guard can still:

- enable WaveSurfer YOKE,
- start `PortBlankAO`,
- change logging settings,
- block GRAB/LOOP if something fails.

This avoids editing ScanImage source code.

## ScanImage User Function Registration

Register this user function:

```text
EventName: applicationOpen
UserFcnName: userfcn_InstallPreGrabGuard
Enable: true
Arguments: {}
```

This installs the guard automatically when ScanImage opens.

The guard does not try to connect WaveSurfer at ScanImage startup. It only shows a reminder. Actual WaveSurfer YOKE connection is attempted immediately before GRAB/LOOP, when the experiment is about to start.

## Runtime Behavior

When the user presses GRAB/LOOP, the guard runs before acquisition starts:

1. Set data directory to `F:\Data\jisooj` if needed.
2. Enable ScanImage logging/save if disabled.
3. Archive lingering `.tif` and `.h5` files to:

   ```text
   F:\Data\jisooj\_archived_by_preflight\yyyymmdd_HHMMSS
   ```

4. If WaveSurfer YOKE is off, run:

   ```matlab
   hSI.hWSConnector.enable = true;
   hSI.hWSConnector.ping();
   ```

5. If `PortBlankAO` is inactive, run:

   ```matlab
   hPortBlankAO.startTask();
   ```

6. If any check fails, show an error dialog and prevent GRAB/LOOP from starting.

## Relevant Machine Data File Findings

The analog output of interest is:

```text
Resource name: PortBlankAO
Class: dabs.generic.WaveformGenerator
Task type: Analog
Control: /vDAQ0/AO6
Start trigger: /vDAQ0/D1.7
Waveform function: LEDBlankAO_F
```

Other AO channels found in the MDF:

```text
hAOZoom        /vDAQ0/AO1
920nm AOM      /vDAQ0/AO2
TLens          /vDAQ0/AO3
MEMS slow axis /vDAQ0/AO0
PortBlankAO    /vDAQ0/AO6
```

## Event Trace Finding

A temporary event trace showed that the first normal ScanImage user-function event during GRAB is:

```text
EVENT=acqModeStart | acqState=grab
```

This is already too late to enable WaveSurfer YOKE, because `hWSConnector.enable = true` requires ScanImage to be idle.

That is why the final solution uses an `acqState` `PreSet` listener instead of a normal `acqModeStart` user function.

## Files Kept Active

```text
userfcn_InstallPreGrabGuard.m
userfcn_RemovePreGrabGuard.m
```

To remove the guard during a session:

```matlab
userfcn_RemovePreGrabGuard
```

## Archived Experimental Files

Intermediate experimental functions were moved to:

```text
Archive\20260608_pregrab_guard_experiments
```

Archived files:

```text
userfcn_PreflightGrab.m
userfcn_SafeGrab.m
userfcn_EnableEventTrace.m
userfcn_DisableEventTrace.m
```

## Successful Test Output

Example successful guard run:

```text
=== Pre-GRAB guard ===
ScanImage data directory: F:\Data\jisooj
Archiving 2 lingering .tif/.h5 file(s) to:
F:\Data\jisooj\_archived_by_preflight\20260608_172918
WaveSurfer YOKE is not enabled. Connecting...
WaveSurfer connection successful
WaveSurfer/YOKE OK.
PortBlankAO task is not active. Starting task...
PortBlankAO active on /vDAQ0/AO6.
Pre-GRAB guard OK.
```

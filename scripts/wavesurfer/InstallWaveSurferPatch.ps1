param(
    [string]$Target = "C:\Program Files\+ws\WavesurferModel.m"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Target)) {
    throw "WaveSurfer target file not found: $Target"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$targetBackup = "$Target.bak_$stamp"
Copy-Item -LiteralPath $Target -Destination $targetBackup -Force
Write-Host "Backup created at: $targetBackup"

$text = Get-Content -LiteralPath $Target -Raw
$changed = $false

# ── Patch 1: stop WaveSurfer when ScanImage completes normally ────────────────
$p1Marker = "Stop the WaveSurfer run so it does not keep polling"
if ($text -match [regex]::Escape($p1Marker)) {
    Write-Host "Patch 1 (stop-on-SI-done): already installed."
} else {
    $p1Old = @"
                case 'did-complete-acquisition-mode-normally'
                    % SI sends this when "acquisiition mode" (aka a loop or
                    % grab) finishes without problems on its end.
                    % Currently, we don't do anything in response to this.
"@
    $p1New = @"
                case 'did-complete-acquisition-mode-normally'
                    % SI sends this when "acquisiition mode" (aka a loop or
                    % grab) finishes without problems on its end.
                    % Stop the WaveSurfer run so it does not keep polling
                    % DAQmx after ScanImage has already finished.
                    self.stop() ;
"@
    if (-not $text.Contains($p1Old)) {
        throw "Patch 1: expected command block not found. Target may be a different version."
    }
    $text = $text.Replace($p1Old, $p1New)
    $changed = $true
    Write-Host "Patch 1 (stop-on-SI-done): applied."
}

# ── Patch 2: suppress DAQmx error dialog when yoked to ScanImage ─────────────
# When ScanImage finishes, there is a ~50 ms window between hardware release
# and WaveSurfer receiving the stop command. The TheBigTimer_ can fire in that
# window, hit error -200983, and show an error dialog even though everything
# stopped correctly. Suppress the dialog for these transient yoking errors.
$p2Marker = "When yoked to ScanImage, a DAQmx error at the very end"
if ($text -match [regex]::Escape($p2Marker)) {
    Write-Host "Patch 2 (suppress-yoked-daq-dialog): already installed."
} else {
    $p2Old = @"
            catch exception
                if self.IsPerformingRun_ ,
                    if self.IsPerformingSweep_ ,
                        self.abortTheOngoingSweep_() ;
                    end
                    self.abortOngoingRun_() ;
                end
                if self.IsHeaded_ ,
                    self.broadcast('RaiseDialogOnException', exception);
                else
                    throw(exception) ;
                end
            end
"@
    $p2New = @"
            catch exception
                if self.IsPerformingRun_ ,
                    if self.IsPerformingSweep_ ,
                        self.abortTheOngoingSweep_() ;
                    end
                    self.abortOngoingRun_() ;
                end
                if self.IsHeaded_ ,
                    % When yoked to ScanImage, a DAQmx error at the very end of a
                    % run is expected: ScanImage may release shared hardware before
                    % WaveSurfer's file-polled stop command is processed (~50 ms
                    % race window). Suppress the dialog for these transient errors
                    % so the operator does not see a spurious alert on normal stops.
                    isDaqError = contains(exception.identifier, 'Daq', 'IgnoreCase', true) || ...
                                 contains(exception.message, 'DAQmx', 'IgnoreCase', true) || ...
                                 contains(exception.message, '-200983') ;
                    if ~(self.IsYokedToScanImage && isDaqError) ,
                        self.broadcast('RaiseDialogOnException', exception);
                    end
                else
                    throw(exception) ;
                end
            end
"@
    if (-not $text.Contains($p2Old)) {
        throw "Patch 2: expected handleTimerTick catch block not found. Target may be a different version."
    }
    $text = $text.Replace($p2Old, $p2New)
    $changed = $true
    Write-Host "Patch 2 (suppress-yoked-daq-dialog): applied."
}

if ($changed) {
    Set-Content -LiteralPath $Target -Value $text -NoNewline
    Write-Host "WaveSurferModel.m written."
} else {
    Write-Host "No changes needed — all patches already installed."
}

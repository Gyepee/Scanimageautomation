param(
    [Parameter(Mandatory=$true)]
    [string]$JobPath
)

$ErrorActionPreference = "Stop"

$script:Job = $null

function NowStamp {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
}

function Write-Status {
    param(
        [string]$Status,
        [string]$Message,
        [object[]]$Items = @()
    )

    $ok   = @($Items | Where-Object status -eq "OK").Count
    $warn = @($Items | Where-Object status -eq "WARN").Count
    $skip = @($Items | Where-Object status -eq "SKIP").Count
    $fail = @($Items | Where-Object status -eq "FAIL").Count

    $j = $script:Job
    $obj = [ordered]@{
        status            = $Status
        message           = $Message
        session_timestamp = if ($j) { [string]$j.session_timestamp } else { "" }
        animal_label      = if ($j) { [string]$j.animalID } else { "" }
        animal_code       = if ($j) { [string]$j.animalCode } else { "" }
        scan_id           = if ($j) { [string]$j.experimentID } else { "" }
        destination       = if ($j) { [string]$j.data_path } else { "" }
        ok_count          = $ok
        warn_count        = $warn
        skip_count        = $skip
        fail_count        = $fail
        items             = $Items
        updated_at        = NowStamp
    }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatusPath -Encoding UTF8
}

function Add-Item {
    param(
        [string]$Label,
        [string]$Pattern,
        [string]$Status,
        [string]$Note,
        [string]$Src = "",
        [string]$Dst = "",
        [double]$TimeDiffMin = -1
    )

    $item = [pscustomobject]@{
        label   = $Label
        pattern = $Pattern
        status  = $Status
        note    = $Note
        src     = $Src
        dst     = $Dst
    }
    if ($TimeDiffMin -ge 0) {
        $item | Add-Member -NotePropertyName time_diff_min -NotePropertyValue ([math]::Round($TimeDiffMin, 1))
    }
    $script:Items += $item
    Write-Host "[$Status] $Label - $Note"
}

function Parse-Date {
    param([string]$Text)
    try {
        return [datetime]::ParseExact($Text, "yyyy-MM-dd HH:mm:ss.fff", [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return Get-Date
    }
}

function Wait-Stable {
    param(
        [string]$Path,
        [double]$StableSec,
        [double]$TimeoutSec
    )

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $last = -1L
    $stableStart = Get-Date
    $overallStart = Get-Date

    while (((Get-Date) - $overallStart).TotalSeconds -le $TimeoutSec) {
        if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
            Start-Sleep -Milliseconds 250
            continue
        }

        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -eq $last) {
            if (((Get-Date) - $stableStart).TotalSeconds -ge $StableSec) {
                return $true
            }
        } else {
            $last = $len
            $stableStart = Get-Date
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Select-SameDayClosest {
    param(
        [string]$Root,
        [string]$Pattern,
        [datetime]$SessionTime
    )

    if (!(Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject]@{ File = $null; Detail = "folder not accessible: $Root" }
    }

    $files = @(Get-ChildItem -LiteralPath $Root -Filter $Pattern -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ File = $null; Detail = "no files match pattern $Pattern in $Root" }
    }

    $sameDay = @($files | Where-Object { $_.LastWriteTime.Date -eq $SessionTime.Date })
    if ($sameDay.Count -eq 0) {
        $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        return [pscustomobject]@{
            File = $null
            Detail = "files exist but none on session date; latest is $($latest.Name) at $($latest.LastWriteTime)"
        }
    }

    $best = $sameDay | Sort-Object @{ Expression = { [math]::Abs(($_.LastWriteTime - $SessionTime).TotalMinutes) } } | Select-Object -First 1
    return [pscustomobject]@{ File = $best; Detail = "selected closest same-day file by LastWriteTime" }
}

function Copy-WithPrefix {
    param(
        [System.IO.FileInfo]$File,
        [string]$ExperimentID,
        [string]$Dest
    )

    $dst = Join-Path $Dest ("scan{0}_{1}" -f $ExperimentID, $File.Name)
    Copy-Item -LiteralPath $File.FullName -Destination $dst -Force
    return $dst
}

function Get-AnimalCode {
    param([string]$AnimalID)
    $m = [regex]::Match($AnimalID, "ROS-\d{4}")
    if ($m.Success) { return $m.Value }
    return ""
}

function Get-AnimalLabel {
    param([string]$Text)
    $m = [regex]::Match($Text, '([A-Za-z]+_)?ROS-\d{4}')
    if ($m.Success) { return $m.Value }
    return ""
}

function Get-ReferenceImagingFile {
    param([string]$Dest)

    if (!(Test-Path -LiteralPath $Dest -PathType Container)) {
        return $null
    }

    $imagingFiles = @(Get-ChildItem -LiteralPath $Dest -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "*.tif" -or $_.Name -like "*.h5"
    })

    if ($imagingFiles.Count -eq 0) {
        return $null
    }

    return ($imagingFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Test-BpodMatAgainstImagingTime {
    param(
        [System.IO.FileInfo]$BpodMat,
        [string]$Dest,
        [double]$MaxDiffMin
    )

    $ref = Get-ReferenceImagingFile -Dest $Dest
    if ($null -eq $ref) {
        return [pscustomobject]@{
            Ok = $false
            DiffMin = [double]::PositiveInfinity
            ImagingFile = $null
            Note = "No ScanImage imaging reference file (*.tif or *.h5) found in destination; BPod copy blocked."
        }
    }

    $diff = [math]::Abs(($BpodMat.LastWriteTime - $ref.LastWriteTime).TotalMinutes)
    if ($diff -gt $MaxDiffMin) {
        return [pscustomobject]@{
            Ok = $false
            DiffMin = $diff
            ImagingFile = $ref
            Note = ("BPod .mat LastWriteTime differs from ScanImage imaging file by {0:n1} min, limit {1:n1} min. Check ScanImage basename/animal label." -f $diff, $MaxDiffMin)
        }
    }

    return [pscustomobject]@{
        Ok = $true
        DiffMin = $diff
        ImagingFile = $ref
        Note = ("BPod .mat and ScanImage imaging write times agree within {0:n1} min; |dt|={1:n1} min." -f $MaxDiffMin, $diff)
    }
}

function Send-CopyDiscordAlert {
    param(
        [string]$Title,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($script:DiscordWebhookUrl)) { return }

    try {
        Invoke-DiscordWebhook -WebhookUrl $script:DiscordWebhookUrl `
            -Title $Title `
            -Message $Message `
            -Username $script:DiscordUsername
    } catch {
        Write-Host "WARNING: Discord alert failed: $_"
    }
}

function Select-BpodCompanion {
    param(
        [string]$Root,
        [System.IO.FileInfo]$MatFile,
        [string]$Suffix,
        [string]$FallbackPattern,
        [datetime]$SessionTime
    )

    if ($null -ne $MatFile) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($MatFile.Name)
        $exact = Join-Path $Root ($base + $Suffix)
        if (Test-Path -LiteralPath $exact -PathType Leaf) {
            return [pscustomobject]@{
                File = Get-Item -LiteralPath $exact
                Detail = "selected companion file matching BPod .mat stem"
            }
        }
    }

    return Select-SameDayClosest -Root $Root -Pattern $FallbackPattern -SessionTime $SessionTime
}

. (Join-Path $PSScriptRoot "..\..\scripts\discord\Send-DiscordAlert.ps1")

$script:DiscordWebhookUrl = ""
$script:DiscordUsername = "ScanImage Copy Bot"
$_uploadCfgPath = Join-Path $PSScriptRoot "..\..\config\upload_sessions_config.json"
if (Test-Path -LiteralPath $_uploadCfgPath) {
    try {
        $_uploadCfg = Get-Content -LiteralPath $_uploadCfgPath -Raw | ConvertFrom-Json
        if ($_uploadCfg.discord -and $_uploadCfg.discord.enabled -and
            -not [string]::IsNullOrWhiteSpace($_uploadCfg.discord.webhookUrl)) {
            $script:DiscordWebhookUrl = [string]$_uploadCfg.discord.webhookUrl
            if ($_uploadCfg.discord.username) { $script:DiscordUsername = [string]$_uploadCfg.discord.username }
        }
    } catch { }
}

function Find-BpodAnimalFolder {
    param(
        [string]$BpodRoot,
        [string]$AnimalCode
    )

    if ($AnimalCode -eq "" -or !(Test-Path -LiteralPath $BpodRoot -PathType Container)) {
        return $null
    }

    $dirs = @(Get-ChildItem -LiteralPath $BpodRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "ROS-\d{4}" -and $Matches[0] -eq $AnimalCode
    })
    if ($dirs.Count -eq 0) { return $null }

    $ranked = $dirs | Sort-Object @{ Expression = {
        if ($_.Name -eq $AnimalCode) { 0 }
        elseif ($_.Name -like "*_$AnimalCode") { 1 }
        else { 2 }
    }}, Name
    return ($ranked | Select-Object -First 1)
}

function Select-BpodSessionFolder {
    param(
        [string]$AnimalFolder,
        [datetime]$SessionTime
    )

    $sessionDirs = @(Get-ChildItem -LiteralPath $AnimalFolder -Recurse -Directory -Filter "Session Data" -ErrorAction SilentlyContinue)
    if ($sessionDirs.Count -eq 0) {
        return [pscustomobject]@{ Folder = $null; Detail = "no Session Data folder under $AnimalFolder"; DiffMin = [double]::PositiveInfinity }
    }

    $candidates = @()
    foreach ($dir in $sessionDirs) {
        $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "*.mat" -or
            $_.Name -like "*SessionSummary.txt" -or
            $_.Name -like "*SessionSummary.csv" -or
            $_.Name -like "*.m"
        })
        if ($files.Count -eq 0) {
            $latestTime = $dir.LastWriteTime
        } else {
            $latestTime = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        }

        $diff = [math]::Abs(($latestTime - $SessionTime).TotalMinutes)
        $sameDayBoost = if ($latestTime.Date -eq $SessionTime.Date) { 0 } else { 1000000 }
        $testPenalty = if ($dir.FullName -match "\\(DEBUG|TEST|TESTING)\\") { 30 } else { 0 }
        $score = $sameDayBoost + $diff + $testPenalty
        $candidates += [pscustomobject]@{ Folder = $dir; LatestTime = $latestTime; DiffMin = $diff; Score = $score }
    }

    $best = $candidates | Sort-Object Score | Select-Object -First 1
    return [pscustomobject]@{
        Folder = $best.Folder
        Detail = ("latest file time {0}, |dt|={1:n1} min" -f $best.LatestTime, $best.DiffMin)
        DiffMin = $best.DiffMin
    }
}

try {
    if (!(Test-Path -LiteralPath $JobPath -PathType Leaf)) {
        throw "Job file not found: $JobPath"
    }

    $job = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json
    $script:Job = $job
    $script:StatusPath = $job.status_path
    $script:Items = @()

    Write-Status -Status "RUNNING" -Message "External copy worker started"

    $sessionTime = Parse-Date $job.session_timestamp
    $dest = [string]$job.data_path
    $exp = [string]$job.experimentID
    $timeDiffWarnMin = if ($null -ne $job.timeDiffWarnMin) { [double]$job.timeDiffWarnMin } else { 5.0 }
    $bpodImagingMaxDiffMin = if ($null -ne $job.bpodImagingMaxDiffMin) { [double]$job.bpodImagingMaxDiffMin } else { 3.0 }

    $jobAnimalCode = [string]$job.animalCode
    if ($jobAnimalCode -eq "") { $jobAnimalCode = Get-AnimalCode ([string]$job.animalID) }

    $pathAnimalLabel = Get-AnimalLabel $dest
    $pathAnimalCode = Get-AnimalCode $pathAnimalLabel
    if ($pathAnimalCode -ne "" -and $jobAnimalCode -ne "" -and $pathAnimalCode -ne $jobAnimalCode) {
        Add-Item -Label "Animal code guard" -Pattern "data_path vs job" -Status "WARN" -Note "Job animal code $jobAnimalCode did not match destination animal code $pathAnimalCode; using destination code for BPod lookup."
        $jobAnimalCode = $pathAnimalCode
        $job.animalCode = $pathAnimalCode
        if ($pathAnimalLabel -ne "") { $job.animalID = $pathAnimalLabel }
    } elseif ($jobAnimalCode -eq "" -and $pathAnimalCode -ne "") {
        Add-Item -Label "Animal code guard" -Pattern "data_path" -Status "WARN" -Note "Job animal code was empty; using destination animal code $pathAnimalCode for BPod lookup."
        $jobAnimalCode = $pathAnimalCode
        $job.animalCode = $pathAnimalCode
        if ($pathAnimalLabel -ne "") { $job.animalID = $pathAnimalLabel }
    }

    foreach ($spec in @(
        @{ Label = "Tracking video (.mp4)"; Pattern = "mini2p2_top_video*.mp4" },
        @{ Label = "Tracking timestamps (.csv)"; Pattern = "mini2p2_top_video_timestamps*.csv" }
    )) {
        $sel = Select-SameDayClosest -Root $job.tracking_root -Pattern $spec.Pattern -SessionTime $sessionTime
        if ($null -eq $sel.File) {
            Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" -Note $sel.Detail
            continue
        }

        if (!(Wait-Stable -Path $sel.File.FullName -StableSec ([double]$job.externalStableSec) -TimeoutSec ([double]$job.externalSettleTimeoutSec))) {
            Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" -Note "file did not become size-stable before timeout" -Src $sel.File.FullName
            continue
        }

        $dst = Copy-WithPrefix -File $sel.File -ExperimentID $exp -Dest $dest
        $tDiff = [math]::Abs(($sel.File.LastWriteTime - $sessionTime).TotalMinutes)
        if ($tDiff -gt $timeDiffWarnMin) {
            Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "WARN" `
                -Note ("{0}; {1:n1} min from session time - review required" -f $sel.Detail, $tDiff) `
                -Src $sel.File.FullName -Dst $dst -TimeDiffMin $tDiff
        } else {
            Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "OK" `
                -Note $sel.Detail -Src $sel.File.FullName -Dst $dst -TimeDiffMin $tDiff
        }
    }

    $animalCode = $jobAnimalCode
    $animalFolder = Find-BpodAnimalFolder -BpodRoot $job.bpod_root -AnimalCode $animalCode
    if ($null -eq $animalFolder) {
        Add-Item -Label "BPod session files" -Pattern "*.mat/*.txt/*.csv" -Status "FAIL" -Note "No BPod animal folder matched core animal code $animalCode"
    } else {
        $bpodSel = Select-BpodSessionFolder -AnimalFolder $animalFolder.FullName -SessionTime $sessionTime
        if ($null -eq $bpodSel.Folder) {
            Add-Item -Label "BPod session files" -Pattern "Session Data" -Status "FAIL" -Note $bpodSel.Detail
        } elseif ($bpodSel.DiffMin -gt [double]$job.bpodMaxDiffMin) {
            Add-Item -Label "BPod session files" -Pattern "Session Data" -Status "FAIL" -Note ("Closest BPod data too far from session time: {0:n1} min, limit {1:n1} min. Manual copy required." -f $bpodSel.DiffMin, [double]$job.bpodMaxDiffMin) -Src $bpodSel.Folder.FullName
        } else {
            $bpodMatSel = Select-SameDayClosest -Root $bpodSel.Folder.FullName -Pattern "*.mat" -SessionTime $sessionTime
            $bpodTimingOk = $false

            if ($null -eq $bpodMatSel.File) {
                Add-Item -Label "BPod session (.mat)" -Pattern "*.mat" -Status "FAIL" -Note $bpodMatSel.Detail
            } else {
                $timingCheck = Test-BpodMatAgainstImagingTime -BpodMat $bpodMatSel.File -Dest $dest -MaxDiffMin $bpodImagingMaxDiffMin
                if (-not $timingCheck.Ok) {
                    $imgPath = if ($timingCheck.ImagingFile) { $timingCheck.ImagingFile.FullName } else { "" }
                    Add-Item -Label "BPod vs ScanImage timing guard" -Pattern "*.mat vs *.tif/*.h5" -Status "FAIL" `
                        -Note $timingCheck.Note `
                        -Src $bpodMatSel.File.FullName -Dst $imgPath -TimeDiffMin $timingCheck.DiffMin

                    $sessionLabel = if ($script:Job) { [string]$script:Job.animalID } else { "?" }
                    $scanID = if ($script:Job) { [string]$script:Job.experimentID } else { "?" }
                    $imgLines = if ($timingCheck.ImagingFile) {
                        @(
                            "ScanImage file: $($timingCheck.ImagingFile.FullName)",
                            "ScanImage LastWriteTime: $($timingCheck.ImagingFile.LastWriteTime)"
                        )
                    } else {
                        @("ScanImage file: NOT FOUND")
                    }
                    $lines = @(
                        "BPod files were not copied.",
                        "Reason: $($timingCheck.Note)",
                        "",
                        "Session time: $($job.session_timestamp)",
                        "Destination: $dest",
                        "BPod mat: $($bpodMatSel.File.FullName)",
                        "BPod LastWriteTime: $($bpodMatSel.File.LastWriteTime)"
                    ) + $imgLines + @(
                        "",
                        "Action needed: check the ScanImage basename/animal label. If needed, manually place the correct BPod files in the session folder, then run the verification worker."
                    )
                    Send-CopyDiscordAlert -Title "BPod copy blocked: $sessionLabel scan$scanID" -Message ($lines -join "`n")
                } else {
                    Add-Item -Label "BPod vs ScanImage timing guard" -Pattern "*.mat vs *.tif/*.h5" -Status "OK" `
                        -Note $timingCheck.Note `
                        -Src $bpodMatSel.File.FullName -Dst $timingCheck.ImagingFile.FullName -TimeDiffMin $timingCheck.DiffMin
                    $bpodTimingOk = $true
                }
            }

            if ($bpodTimingOk) {
            foreach ($spec in @(
                @{ Label = "BPod session (.mat)"; Pattern = "*.mat" },
                @{ Label = "BPod session summary (.txt)"; Pattern = "*SessionSummary.txt" },
                @{ Label = "BPod session summary (.csv)"; Pattern = "*SessionSummary.csv" }
            )) {
                if ($spec.Pattern -eq "*.mat") {
                    $sel = $bpodMatSel
                } elseif ($spec.Pattern -eq "*SessionSummary.txt") {
                    $sel = Select-BpodCompanion -Root $bpodSel.Folder.FullName -MatFile $bpodMatSel.File -Suffix "_SessionSummary.txt" -FallbackPattern $spec.Pattern -SessionTime $sessionTime
                } else {
                    $sel = Select-BpodCompanion -Root $bpodSel.Folder.FullName -MatFile $bpodMatSel.File -Suffix "_SessionSummary.csv" -FallbackPattern $spec.Pattern -SessionTime $sessionTime
                }
                if ($null -eq $sel.File) {
                    Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" -Note $sel.Detail
                    continue
                }
                $dst = Copy-WithPrefix -File $sel.File -ExperimentID $exp -Dest $dest
                $tDiff = [math]::Abs(($sel.File.LastWriteTime - $sessionTime).TotalMinutes)
                if ($tDiff -gt $timeDiffWarnMin) {
                    Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "WARN" `
                        -Note ("{0}; {1:n1} min from session time - review required" -f $sel.Detail, $tDiff) `
                        -Src $sel.File.FullName -Dst $dst -TimeDiffMin $tDiff
                } else {
                    Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "OK" `
                        -Note $sel.Detail -Src $sel.File.FullName -Dst $dst -TimeDiffMin $tDiff
                }
            }

            $mFile = @(Get-ChildItem -LiteralPath $bpodSel.Folder.FullName -Filter "*.m" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1)
            if ($mFile.Count -gt 0) {
                $dst = Copy-WithPrefix -File $mFile[0] -ExperimentID $exp -Dest $dest
                Add-Item -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "OK" `
                    -Note "Copied latest protocol backup; timestamp may be older when protocol code has not changed" `
                    -Src $mFile[0].FullName -Dst $dst
            } else {
                Add-Item -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "SKIP" -Note "No protocol backup found"
            }
            }
        }
    }

    $fail = @($script:Items | Where-Object status -eq "FAIL").Count
    $warnItems = @($script:Items | Where-Object { $_.status -eq "WARN" -and $null -ne $_.time_diff_min })

    if ($warnItems.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($script:DiscordWebhookUrl)) {
        $sessionLabel = if ($script:Job) { [string]$script:Job.animalID } else { "?" }
        $scanID       = if ($script:Job) { [string]$script:Job.experimentID } else { "?" }
        $lines = @(
            "Session time: $($job.session_timestamp)",
            "",
            "Files with large time gap (>${timeDiffWarnMin} min from session):"
        )
        foreach ($it in $warnItems) {
            $lines += "  - $($it.label) - $($it.time_diff_min) min"
        }
        $lines += ""
        $bpodWarn  = @($warnItems | Where-Object { $_.label -like "BPod*" }).Count
        $trackWarn = @($warnItems | Where-Object { $_.label -notlike "BPod*" }).Count
        if ($bpodWarn -gt 0 -and $trackWarn -eq 0) {
            $lines += "Tip: only BPod files are flagged. ScanImage animal label may not have been updated before scanning."
        }
        try {
            Invoke-DiscordWebhook -WebhookUrl $script:DiscordWebhookUrl `
                -Title "Review required: $sessionLabel scan$scanID" `
                -Message ($lines -join "`n") `
                -Username $script:DiscordUsername
        } catch { Write-Host "WARNING: Discord alert failed: $_" }
    }

    if ($fail -gt 0) {
        Write-Status -Status "FAILED" -Message "External copy completed with failures; manual review required" -Items $script:Items
    } elseif ($warnItems.Count -gt 0) {
        Write-Status -Status "DONE" -Message "External copy completed with warnings; review required" -Items $script:Items
    } else {
        Write-Status -Status "DONE" -Message "External copy completed" -Items $script:Items
    }
} catch {
    if ($script:StatusPath) {
        Write-Status -Status "FAILED" -Message $_.Exception.Message -Items $script:Items
    }
    throw
}

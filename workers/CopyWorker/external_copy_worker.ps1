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
        [string]$Dst = ""
    )

    $script:Items += [pscustomobject]@{
        label = $Label
        pattern = $Pattern
        status = $Status
        note = $Note
        src = $Src
        dst = $Dst
    }
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
            $_.Name -like "*_B2BSessionSummary.txt" -or
            $_.Name -like "*_B2BSessionSummary.csv" -or
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
        Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "OK" -Note $sel.Detail -Src $sel.File.FullName -Dst $dst
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
            foreach ($spec in @(
                @{ Label = "BPod session (.mat)"; Pattern = "*.mat" },
                @{ Label = "BPod session summary (.txt)"; Pattern = "*_B2BSessionSummary.txt" },
                @{ Label = "BPod session summary (.csv)"; Pattern = "*_B2BSessionSummary.csv" }
            )) {
                $sel = Select-SameDayClosest -Root $bpodSel.Folder.FullName -Pattern $spec.Pattern -SessionTime $sessionTime
                if ($null -eq $sel.File) {
                    Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" -Note $sel.Detail
                    continue
                }
                $dst = Copy-WithPrefix -File $sel.File -ExperimentID $exp -Dest $dest
                Add-Item -Label $spec.Label -Pattern $spec.Pattern -Status "OK" -Note $sel.Detail -Src $sel.File.FullName -Dst $dst
            }

            $mFile = @(Get-ChildItem -LiteralPath $bpodSel.Folder.FullName -Filter "*.m" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($mFile.Count -gt 0) {
                $dst = Copy-WithPrefix -File $mFile[0] -ExperimentID $exp -Dest $dest
                Add-Item -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "OK" -Note "Copied latest protocol backup" -Src $mFile[0].FullName -Dst $dst
            } else {
                Add-Item -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "SKIP" -Note "No protocol backup found"
            }
        }
    }

    $fail = @($script:Items | Where-Object status -eq "FAIL").Count
    if ($fail -gt 0) {
        Write-Status -Status "FAILED" -Message "External copy completed with failures; manual review required" -Items $script:Items
    } else {
        Write-Status -Status "DONE" -Message "External copy completed" -Items $script:Items
    }
} catch {
    if ($script:StatusPath) {
        Write-Status -Status "FAILED" -Message $_.Exception.Message -Items $script:Items
    }
    throw
}

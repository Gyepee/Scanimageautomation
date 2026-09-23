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

function Write-TrackingRepairJob {
    param(
        [string]$Kind,
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$CsvSourcePath = "",
        [string]$CsvDestinationPath = "",
        [string]$Reason,
        [string]$Token,
        [object]$Job
    )

    $jobRoot = Join-Path $PSScriptRoot "..\..\state\tracking_repair_jobs"
    New-Item -ItemType Directory -Path $jobRoot -Force | Out-Null

    $scanID = if ($Job) { [string]$Job.experimentID } else { "unknownscan" }
    $safeToken = if ([string]::IsNullOrWhiteSpace($Token)) { "notoken" } else { $Token -replace '[^\w.-]', '_' }
    $safeKind = $Kind -replace '[^\w.-]', '_'
    $jobPath = Join-Path $jobRoot ("tracking_repair_{0}_{1}_{2}.json" -f $scanID, $safeToken, $safeKind)

    $existingAttempts = 0
    if (Test-Path -LiteralPath $jobPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json
            if ($null -ne $existing.attempt_count) { $existingAttempts = [int]$existing.attempt_count }
        } catch { }
    }

    $repairJob = [ordered]@{
        status = "PENDING"
        kind = $Kind
        reason = $Reason
        source_path = $SourcePath
        destination_path = $DestinationPath
        csv_source_path = $CsvSourcePath
        csv_destination_path = $CsvDestinationPath
        token = $Token
        scan_id = $scanID
        session_timestamp = if ($Job) { [string]$Job.session_timestamp } else { "" }
        session_path = if ($Job) { [string]$Job.data_path } else { "" }
        status_path = if ($Job) { [string]$Job.status_path } else { "" }
        tracking_root = if ($Job) { [string]$Job.tracking_root } else { "" }
        attempt_count = $existingAttempts
        created_or_updated_at = NowStamp
        last_result = ""
    }

    $repairJob | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jobPath -Encoding UTF8
    Write-Host "[REPAIR_JOB] $jobPath"
    return $jobPath
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

function Get-BonsaiToken {
    param([string]$Name)
    $m = [regex]::Match($Name, "\d{4}-\d{2}-\d{2}T\d{2}_\d{2}_\d{2}")
    if ($m.Success) { return $m.Value }
    return ""
}

function Test-Mp4ContainerClosed {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Note = "mp4 file not found." }
    }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $hasMoov = $false
        $hasMdat = $false
        while ($fs.Position -lt $fs.Length) {
            $offset = $fs.Position
            $header = New-Object byte[] 8
            $read = $fs.Read($header, 0, 8)
            if ($read -lt 8) {
                return [pscustomobject]@{ Ok = $false; Note = "mp4 has trailing bytes too short for an atom header at offset $offset." }
            }

            [array]::Reverse($header, 0, 4)
            $size = [int64][BitConverter]::ToUInt32($header, 0)
            $type = [System.Text.Encoding]::ASCII.GetString($header, 4, 4)
            $headerSize = 8L

            if ($size -eq 1) {
                $wide = New-Object byte[] 8
                $readWide = $fs.Read($wide, 0, 8)
                if ($readWide -lt 8) {
                    return [pscustomobject]@{ Ok = $false; Note = "mp4 extended atom size is truncated at offset $offset." }
                }
                [array]::Reverse($wide)
                $size = [int64][BitConverter]::ToUInt64($wide, 0)
                $headerSize = 16L
            } elseif ($size -eq 0) {
                $size = $fs.Length - $offset
            }

            if ($size -lt $headerSize) {
                return [pscustomobject]@{ Ok = $false; Note = "mp4 atom $type has invalid size $size at offset $offset." }
            }
            $end = $offset + $size
            if ($end -gt $fs.Length) {
                return [pscustomobject]@{ Ok = $false; Note = "mp4 atom $type extends past EOF at offset $offset." }
            }

            if ($type -eq "moov") { $hasMoov = $true }
            if ($type -eq "mdat") { $hasMdat = $true }
            $fs.Seek($end, [System.IO.SeekOrigin]::Begin) | Out-Null
        }

        if (-not $hasMdat) {
            return [pscustomobject]@{ Ok = $false; Note = "mp4 has no mdat media atom." }
        }
        if (-not $hasMoov) {
            return [pscustomobject]@{ Ok = $false; Note = "mp4 has no moov atom; Bonsai/encoder likely had not finalized the file when it was copied." }
        }
        return [pscustomobject]@{ Ok = $true; Note = "mp4 container has mdat and moov atoms." }
    }
    finally {
        $fs.Close()
    }
}

function Test-TrackingCsvComplete {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV file not found." }
    }

    $first = @(Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
    $last = @(Get-Content -LiteralPath $Path -Tail 1 -ErrorAction Stop)
    if ($first.Count -eq 0 -or [string]::IsNullOrWhiteSpace($first[0])) {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV is empty." }
    }
    if ($last.Count -eq 0 -or [string]::IsNullOrWhiteSpace($last[0])) {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV has no final row." }
    }

    $firstCols = ([string]$first[0]).Split(",").Count
    $lastCols = ([string]$last[0]).Split(",").Count
    if ($firstCols -lt 5) {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV first row has too few columns ($firstCols)." }
    }
    if ($lastCols -ne $firstCols) {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV final row appears truncated: first row has $firstCols columns, final row has $lastCols columns." }
    }

    $ts = ([string]$last[0]).Split(",")[0]
    try {
        [datetimeoffset]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture) | Out-Null
    } catch {
        return [pscustomobject]@{ Ok = $false; Note = "tracking CSV final row timestamp is not parseable: $ts" }
    }

    return [pscustomobject]@{ Ok = $true; Note = "tracking CSV first/final row column counts match ($firstCols), and final timestamp parses." }
}

function Select-TrackingPair {
    param(
        [string]$Root,
        [datetime]$SessionTime,
        [double]$MaxDiffMin = 30.0
    )

    $csvSel = Select-SameDayClosest -Root $Root -Pattern "mini2p2_top_video_timestamps*.csv" -SessionTime $SessionTime
    if ($null -eq $csvSel.File) {
        return [pscustomobject]@{
            Video = $null
            Csv = $null
            Token = ""
            Detail = $csvSel.Detail
        }
    }

    $csvDiffMin = [math]::Abs(($csvSel.File.LastWriteTime - $SessionTime).TotalMinutes)
    if ($csvDiffMin -gt $MaxDiffMin) {
        return [pscustomobject]@{
            Video = $null
            Csv = $null
            Token = ""
            Detail = ("closest tracking timestamp file is {0:n1} min from session time; limit is {1:n1} min" -f $csvDiffMin, $MaxDiffMin)
        }
    }

    $token = Get-BonsaiToken $csvSel.File.Name
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{
            Video = $null
            Csv = $csvSel.File
            Token = ""
            Detail = "timestamp CSV selected, but no Bonsai timestamp token was found in its filename"
        }
    }

    $videos = @(Get-ChildItem -LiteralPath $Root -Filter "mini2p2_top_video*.mp4" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$token*" })

    if ($videos.Count -eq 0) {
        return [pscustomobject]@{
            Video = $null
            Csv = $csvSel.File
            Token = $token
            Detail = "timestamp CSV selected, but no paired mp4 with Bonsai token $token was found"
        }
    }

    $video = $videos | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return [pscustomobject]@{
        Video = $video
        Csv = $csvSel.File
        Token = $token
        Detail = "selected paired Bonsai tracking files by timestamp token $token"
    }
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
            if ($_uploadCfg.discord.copyUsername) { $script:DiscordUsername = [string]$_uploadCfg.discord.copyUsername }
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

function Update-CollectionManifestBehavior {
    param(
        [string]$Dest,
        [string]$BehaviorType
    )

    $manifestPath = Join-Path $Dest "collection_manifest.json"
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host "[WARN] Collection manifest not found; behavior type was not recorded: $manifestPath"
        return
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($null -eq $manifest.PSObject.Properties["behavior_protocol"]) {
            $manifest | Add-Member -NotePropertyName behavior_protocol -NotePropertyValue $BehaviorType
        } else {
            $manifest.behavior_protocol = $BehaviorType
        }
        $tmpPath = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
        Move-Item -LiteralPath $tmpPath -Destination $manifestPath -Force
        Write-Host "[OK] Collection manifest behavior type: $BehaviorType"
    } catch {
        Write-Host "[WARN] Could not update collection manifest behavior metadata: $_"
    }
}

function Finalize-CollectionManifest {
    param([string]$Dest)

    $manifestPath = Join-Path $Dest "collection_manifest.json"
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $files = @(Get-ChildItem -LiteralPath $Dest -File | Where-Object {
            $_.Name -notin @("collection_manifest.json", "external_copy_status.json")
        } | Sort-Object Name | ForEach-Object {
            [ordered]@{
                name = $_.Name
                bytes = $_.Length
            }
        })
        $manifest.collected_files = $files
        $manifest.collection_status = "finalized"
        $manifest.finalized_at = NowStamp
        $tmpPath = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
        Move-Item -LiteralPath $tmpPath -Destination $manifestPath -Force
        Write-Host "[OK] Collection manifest finalized with $($files.Count) files"
    } catch {
        Write-Host "[WARN] Could not finalize collection manifest: $_"
    }
}

function Set-QCManifestClassification {
    param([string]$Dest, [bool]$HasTrackingVideo)

    $manifestPath = Join-Path $Dest "collection_manifest.json"
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $capture = $manifest.qc_capture
        if ($HasTrackingVideo) {
            $manifest.collection_purpose = "openfield_fov_qc"
            $manifest.behavior_protocol = "openfield_free"
            $manifest.data_use_notes = "FOV QC with tracking video/timestamps; FastZ identifies the miniscope focal-plane setting."
            if ($null -ne $capture -and $null -ne $capture.utlens_z_candidate) {
                $manifest | Add-Member -Force -NotePropertyName utlens_z -NotePropertyValue $capture.utlens_z_candidate
            }
            $manifest.PSObject.Properties.Remove("motor_position")
        } else {
            $manifest.collection_purpose = "headfixed_fov_qc"
            $manifest.behavior_protocol = "none"
            $manifest.data_use_notes = "Head-fixed FOV QC without tracking video; motor coordinates identify the relative FOV location."
            if ($null -ne $capture -and $null -ne $capture.motor_position_candidate) {
                $manifest | Add-Member -Force -NotePropertyName motor_position -NotePropertyValue $capture.motor_position_candidate
            }
            $manifest.PSObject.Properties.Remove("utlens_z")
        }
        $manifest.PSObject.Properties.Remove("qc_capture")
        $tmpPath = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
        Move-Item -LiteralPath $tmpPath -Destination $manifestPath -Force
    } catch {
        Write-Host "[WARN] Could not classify QC manifest: $_"
    }
}

function Set-StandardManifestClassification {
    param([string]$Dest, [string]$BehaviorType)

    $manifestPath = Join-Path $Dest "collection_manifest.json"
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $hasPower = $false
        foreach ($beam in @($manifest.laser_power.beams)) {
            if (($null -ne $beam.power_fraction -and [double]$beam.power_fraction -gt 0) -or
                ($null -ne $beam.power_percent_legacy -and [double]$beam.power_percent_legacy -gt 0)) {
                $hasPower = $true
            }
        }
        if ($BehaviorType -match "Training") {
            $manifest.collection_purpose = "behavior_training"
            $manifest.PSObject.Properties.Remove("utlens_z")
        } elseif ($hasPower) {
            $manifest.collection_purpose = "openfield_experiment"
        } else {
            $manifest.collection_purpose = "behavior_training"
            $manifest.PSObject.Properties.Remove("utlens_z")
        }
        $tmpPath = "$manifestPath.tmp"
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
        Move-Item -LiteralPath $tmpPath -Destination $manifestPath -Force
    } catch {
        Write-Host "[WARN] Could not classify standard manifest: $_"
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
    $isFovQc = ([string]$job.collection_mode -eq "fov_qc")

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

    $trackingPair = Select-TrackingPair -Root $job.tracking_root -SessionTime $sessionTime -MaxDiffMin 30.0
    if ($null -eq $trackingPair.Csv) {
        $missingTrackingStatus = if ($isFovQc) { "SKIP" } else { "FAIL" }
        Add-Item -Label "Tracking timestamps (.csv)" -Pattern "mini2p2_top_video_timestamps*.csv" -Status $missingTrackingStatus -Note $trackingPair.Detail
        Add-Item -Label "Tracking video (.mp4)" -Pattern "mini2p2_top_video*.mp4" -Status $missingTrackingStatus -Note "No timestamp CSV was available to identify the matching Bonsai mp4."
    } elseif ($null -eq $trackingPair.Video) {
        Add-Item -Label "Tracking timestamps (.csv)" -Pattern "mini2p2_top_video_timestamps*.csv" -Status "OK" -Note $trackingPair.Detail -Src $trackingPair.Csv.FullName
        Add-Item -Label "Tracking video (.mp4)" -Pattern "mini2p2_top_video*.mp4" -Status "FAIL" -Note $trackingPair.Detail
    } else {
        foreach ($pairItem in @(
            @{ Label = "Tracking video (.mp4)"; Pattern = "mini2p2_top_video*.mp4"; File = $trackingPair.Video },
            @{ Label = "Tracking timestamps (.csv)"; Pattern = "mini2p2_top_video_timestamps*.csv"; File = $trackingPair.Csv }
        )) {
            if (!(Wait-Stable -Path $pairItem.File.FullName -StableSec ([double]$job.externalStableSec) -TimeoutSec ([double]$job.externalSettleTimeoutSec))) {
                Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "FAIL" -Note "file did not become size-stable before timeout" -Src $pairItem.File.FullName
                continue
            }

            $dst = Copy-WithPrefix -File $pairItem.File -ExperimentID $exp -Dest $dest
            if ($pairItem.Pattern -like "*.mp4") {
                $mp4Check = Test-Mp4ContainerClosed -Path $dst
                if (-not $mp4Check.Ok) {
                    $pairedCsvDst = if ($trackingPair.Csv) { Join-Path $dest ("scan{0}_{1}" -f $exp, $trackingPair.Csv.Name) } else { "" }
                    $pairedCsvSrc = if ($trackingPair.Csv) { $trackingPair.Csv.FullName } else { "" }
                    Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "FAIL" `
                        -Note ($trackingPair.Detail + "; " + $mp4Check.Note) `
                        -Src $pairItem.File.FullName -Dst $dst
                    Write-TrackingRepairJob -Kind "mp4" `
                        -SourcePath $pairItem.File.FullName `
                        -DestinationPath $dst `
                        -CsvSourcePath $pairedCsvSrc `
                        -CsvDestinationPath $pairedCsvDst `
                        -Reason $mp4Check.Note `
                        -Token $trackingPair.Token `
                        -Job $job | Out-Null
                    continue
                }
                Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "OK" `
                    -Note ($trackingPair.Detail + "; " + $mp4Check.Note + " mp4 LastWriteTime is ignored because post-session merging can update it.") `
                    -Src $pairItem.File.FullName -Dst $dst
            } elseif ($pairItem.Pattern -like "*.csv") {
                $csvCheck = Test-TrackingCsvComplete -Path $dst
                if (-not $csvCheck.Ok) {
                    Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "WARN" `
                        -Note ($trackingPair.Detail + "; " + $csvCheck.Note) `
                        -Src $pairItem.File.FullName -Dst $dst
                    continue
                }
                Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "OK" `
                    -Note ($trackingPair.Detail + "; " + $csvCheck.Note) `
                    -Src $pairItem.File.FullName -Dst $dst
            } else {
                Add-Item -Label $pairItem.Label -Pattern $pairItem.Pattern -Status "OK" `
                    -Note $trackingPair.Detail `
                    -Src $pairItem.File.FullName -Dst $dst
            }
        }
    }

    $qcHasTrackingVideo = ($null -ne $trackingPair.Csv -and $null -ne $trackingPair.Video)
    $animalCode = $jobAnimalCode
    if (-not $isFovQc) {
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

            $behaviorType = $bpodSel.Folder.Parent.Name
            Update-CollectionManifestBehavior -Dest $dest `
                -BehaviorType $behaviorType
            Set-StandardManifestClassification -Dest $dest `
                -BehaviorType $behaviorType
            }
        }
    }
    }

    if ($isFovQc) {
        Set-QCManifestClassification -Dest $dest -HasTrackingVideo $qcHasTrackingVideo
    }

    Finalize-CollectionManifest -Dest $dest

    $fail = @($script:Items | Where-Object status -eq "FAIL").Count
    $failItems = @($script:Items | Where-Object status -eq "FAIL")
    $warnItems = @($script:Items | Where-Object { $_.status -eq "WARN" -and $null -ne $_.time_diff_min })

    if ($failItems.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($script:DiscordWebhookUrl)) {
        $sessionLabel = if ($script:Job) { [string]$script:Job.animalID } else { "?" }
        $scanID       = if ($script:Job) { [string]$script:Job.experimentID } else { "?" }
        $lines = @(
            "Copy completed with failures; upload will be blocked.",
            "",
            "Session date/time: $($job.session_timestamp)",
            "Scan: scan$scanID",
            "Destination: $dest",
            "",
            "Files needing manual review:"
        )
        foreach ($it in $failItems) {
            $lines += "  - [$($it.status)] $($it.label): $($it.note)"
            if (-not [string]::IsNullOrWhiteSpace([string]$it.src)) { $lines += "    src: $($it.src)" }
            if (-not [string]::IsNullOrWhiteSpace([string]$it.dst)) { $lines += "    dst: $($it.dst)" }
        }
        $lines += ""
        $lines += "Action needed: re-copy or regenerate the flagged files, then run the verifier before upload."
        Send-CopyDiscordAlert -Title "Copy failed/manual review: $sessionLabel scan$scanID" -Message ($lines -join "`n")
    }

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

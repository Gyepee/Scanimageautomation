param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath,

    [double]$MaxBpodImagingDiffMin = 3.0,
    [double]$MaxTrackingImagingDiffMin = 10.0,

    [switch]$UpdateStatus,
    [switch]$AlertDiscord
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\discord\Send-DiscordAlert.ps1")

function NowStamp {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
}

function Get-AnimalCode {
    param([string]$Text)
    $m = [regex]::Match($Text, "ROS-\d{4}")
    if ($m.Success) { return $m.Value }
    return ""
}

function Get-ScanId {
    param([string]$Text)
    $m = [regex]::Match($Text, "scan([A-Za-z0-9]+)_sess")
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($Text, "scan([A-Za-z0-9]+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Get-SessionDateFromName {
    param([string]$Text)
    $m = [regex]::Match($Text, "_(\d{4}-\d{2}-\d{2})_scan")
    if (-not $m.Success) { return $null }
    try {
        return [datetime]::ParseExact($m.Groups[1].Value, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture).Date
    } catch {
        return $null
    }
}

function Get-BonsaiToken {
    param([string]$Name)
    $m = [regex]::Match($Name, "\d{4}-\d{2}-\d{2}T\d{2}_\d{2}_\d{2}")
    if ($m.Success) { return $m.Value }
    return ""
}

function Get-BonsaiTokenDate {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token) -or $Token.Length -lt 10) { return $null }
    try {
        return [datetime]::ParseExact($Token.Substring(0, 10), "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture).Date
    } catch {
        return $null
    }
}

function Add-CheckItem {
    param(
        [System.Collections.ArrayList]$Items,
        [string]$Label,
        [string]$Pattern,
        [string]$Status,
        [string]$Note,
        [string]$Src = "",
        [string]$Dst = "",
        [double]$TimeDiffMin = -1
    )

    $item = [ordered]@{
        label = $Label
        pattern = $Pattern
        status = $Status
        note = $Note
        src = $Src
        dst = $Dst
    }
    if ($TimeDiffMin -ge 0 -and -not [double]::IsInfinity($TimeDiffMin)) {
        $item.time_diff_min = [math]::Round($TimeDiffMin, 1)
    }
    [void]$Items.Add([pscustomobject]$item)
    Write-Host "[$Status] $Label - $Note"
}

function Select-NewestFile {
    param([string]$Root, [string[]]$Patterns)

    $files = @()
    foreach ($pat in $Patterns) {
        $files += @(Get-ChildItem -LiteralPath $Root -File -Filter $pat -ErrorAction SilentlyContinue)
    }
    if ($files.Count -eq 0) { return $null }
    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Select-ExpectedFile {
    param(
        [string]$Root,
        [string]$Pattern,
        [string]$ScanId = ""
    )

    $files = @(Get-ChildItem -LiteralPath $Root -File -Filter $Pattern -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($ScanId)) {
        $scanFiles = @($files | Where-Object { $_.Name -like "*scan$ScanId*" -or $_.Name -like "*$ScanId*" })
        if ($scanFiles.Count -gt 0) {
            return ($scanFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }
    }

    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Compare-TimeToReference {
    param(
        [System.IO.FileInfo]$File,
        [System.IO.FileInfo]$Reference,
        [double]$LimitMin
    )

    if ($null -eq $File -or $null -eq $Reference) {
        return [pscustomobject]@{ Ok = $false; DiffMin = [double]::PositiveInfinity }
    }

    $diff = [math]::Abs(($File.LastWriteTime - $Reference.LastWriteTime).TotalMinutes)
    return [pscustomobject]@{ Ok = ($diff -le $LimitMin); DiffMin = $diff }
}

function Select-TrackingVideoForCsv {
    param(
        [string]$Root,
        [System.IO.FileInfo]$CsvFile,
        [string]$ScanId = ""
    )

    if ($null -eq $CsvFile) { return $null }
    $token = Get-BonsaiToken $CsvFile.Name
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }

    $files = @(Get-ChildItem -LiteralPath $Root -File -Filter "*.mp4" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$token*" })

    if (-not [string]::IsNullOrWhiteSpace($ScanId)) {
        $scanFiles = @($files | Where-Object { $_.Name -like "*scan$ScanId*" -or $_.Name -like "*$ScanId*" })
        if ($scanFiles.Count -gt 0) { $files = $scanFiles }
    }

    if ($files.Count -eq 0) { return $null }
    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Load-DiscordFromConfig {
    $cfgPath = Join-Path $PSScriptRoot "..\..\config\upload_sessions_config.json"
    $script:DiscordWebhookUrl = ""
    $script:DiscordUsername = "ScanImage Verify Bot"

    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($cfg.discord -and $cfg.discord.enabled -and -not [string]::IsNullOrWhiteSpace($cfg.discord.webhookUrl)) {
                $script:DiscordWebhookUrl = [string]$cfg.discord.webhookUrl
                if ($cfg.discord.username) { $script:DiscordUsername = [string]$cfg.discord.username }
            }
        } catch { }
    }
}

function Send-VerifyDiscordAlert {
    param([string]$Title, [string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:DiscordWebhookUrl)) { return }
    Invoke-DiscordWebhook -WebhookUrl $script:DiscordWebhookUrl -Title $Title -Message $Message -Username $script:DiscordUsername
}

if (!(Test-Path -LiteralPath $SessionPath -PathType Container)) {
    throw "Session folder not found: $SessionPath"
}

$sessionDir = Get-Item -LiteralPath $SessionPath
$items = New-Object System.Collections.ArrayList
$sessionName = $sessionDir.Name
$animalCode = Get-AnimalCode $sessionName
$scanId = Get-ScanId $sessionName
$sessionDate = Get-SessionDateFromName $sessionName
$statusPath = Join-Path $sessionDir.FullName "external_copy_status.json"

$imagingRef = Select-NewestFile -Root $sessionDir.FullName -Patterns @("*.tif", "*.h5")
if ($null -eq $imagingRef) {
    Add-CheckItem -Items $items -Label "ScanImage imaging reference" -Pattern "*.tif/*.h5" -Status "FAIL" -Note "No imaging file found."
} else {
    Add-CheckItem -Items $items -Label "ScanImage imaging reference" -Pattern "*.tif/*.h5" -Status "OK" -Note "Using newest imaging file as timing reference." -Src $imagingRef.FullName
}

$trackingCsv = Select-ExpectedFile -Root $sessionDir.FullName -Pattern "*timestamps*.csv" -ScanId $scanId
if ($null -eq $trackingCsv) {
    Add-CheckItem -Items $items -Label "Tracking timestamps (.csv)" -Pattern "*timestamps*.csv" -Status "FAIL" -Note "Required file missing."
    Add-CheckItem -Items $items -Label "Tracking video (.mp4)" -Pattern "*.mp4" -Status "FAIL" -Note "No timestamp CSV was available to identify the matching Bonsai mp4."
} else {
    $token = Get-BonsaiToken $trackingCsv.Name
    $tokenDate = Get-BonsaiTokenDate $token
    if ([string]::IsNullOrWhiteSpace($token)) {
        Add-CheckItem -Items $items -Label "Tracking timestamps (.csv)" -Pattern "*timestamps*.csv" -Status "FAIL" -Note "No Bonsai timestamp token found in CSV filename." -Src $trackingCsv.FullName
    } elseif ($null -ne $sessionDate -and $null -ne $tokenDate -and $tokenDate -ne $sessionDate) {
        Add-CheckItem -Items $items -Label "Tracking timestamps (.csv)" -Pattern "*timestamps*.csv" -Status "FAIL" -Note "Bonsai token date $($tokenDate.ToString('yyyy-MM-dd')) does not match session date $($sessionDate.ToString('yyyy-MM-dd'))." -Src $trackingCsv.FullName
    } else {
        $csvNote = "Present; Bonsai token $token matches session date."
        $csvDiff = -1
        if ($null -ne $imagingRef) {
            $cmp = Compare-TimeToReference -File $trackingCsv -Reference $imagingRef -LimitMin ([double]$MaxTrackingImagingDiffMin)
            $csvDiff = $cmp.DiffMin
            $csvNote += (" CSV LastWriteTime is {0:n1} min from imaging reference." -f $cmp.DiffMin)
        }
        Add-CheckItem -Items $items -Label "Tracking timestamps (.csv)" -Pattern "*timestamps*.csv" -Status "OK" `
            -Note $csvNote -Src $trackingCsv.FullName -Dst $(if ($imagingRef) { $imagingRef.FullName } else { "" }) -TimeDiffMin $csvDiff
    }

    $trackingVideo = Select-TrackingVideoForCsv -Root $sessionDir.FullName -CsvFile $trackingCsv -ScanId $scanId
    if ($null -eq $trackingVideo) {
        Add-CheckItem -Items $items -Label "Tracking video (.mp4)" -Pattern "*.mp4" -Status "FAIL" -Note "No paired mp4 found with the same Bonsai timestamp token as the CSV." -Src $trackingCsv.FullName
    } else {
        Add-CheckItem -Items $items -Label "Tracking video (.mp4)" -Pattern "*.mp4" -Status "OK" `
            -Note "Present and paired to timestamp CSV by Bonsai token $token; mp4 LastWriteTime is ignored because post-session merging can update it." `
            -Src $trackingVideo.FullName -Dst $trackingCsv.FullName
    }
}

$requiredSpecs = @(
    @{ Label = "BPod session (.mat)"; Pattern = "*.mat"; TimingLimit = $MaxBpodImagingDiffMin },
    @{ Label = "BPod session summary (.txt)"; Pattern = "*SessionSummary.txt"; TimingLimit = $MaxBpodImagingDiffMin },
    @{ Label = "BPod session summary (.csv)"; Pattern = "*SessionSummary.csv"; TimingLimit = $MaxBpodImagingDiffMin }
)

foreach ($spec in $requiredSpecs) {
    $f = Select-ExpectedFile -Root $sessionDir.FullName -Pattern $spec.Pattern -ScanId $scanId
    if ($null -eq $f) {
        Add-CheckItem -Items $items -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" -Note "Required file missing."
        continue
    }

    $fileAnimalCode = Get-AnimalCode $f.Name
    if ($animalCode -ne "" -and $fileAnimalCode -ne "" -and $fileAnimalCode -ne $animalCode) {
        Add-CheckItem -Items $items -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" `
            -Note "Animal code mismatch: folder=$animalCode file=$fileAnimalCode" `
            -Src $f.FullName
        continue
    }

    if ($null -ne $imagingRef) {
        $cmp = Compare-TimeToReference -File $f -Reference $imagingRef -LimitMin ([double]$spec.TimingLimit)
        if (-not $cmp.Ok) {
            Add-CheckItem -Items $items -Label $spec.Label -Pattern $spec.Pattern -Status "FAIL" `
                -Note ("LastWriteTime differs from imaging reference by {0:n1} min, limit {1:n1} min." -f $cmp.DiffMin, [double]$spec.TimingLimit) `
                -Src $f.FullName -Dst $imagingRef.FullName -TimeDiffMin $cmp.DiffMin
            continue
        }
        Add-CheckItem -Items $items -Label $spec.Label -Pattern $spec.Pattern -Status "OK" `
            -Note ("Present and time-consistent with imaging reference; |dt|={0:n1} min." -f $cmp.DiffMin) `
            -Src $f.FullName -Dst $imagingRef.FullName -TimeDiffMin $cmp.DiffMin
    } else {
        Add-CheckItem -Items $items -Label $spec.Label -Pattern $spec.Pattern -Status "OK" -Note "Present; timing not checked because imaging reference is missing." -Src $f.FullName
    }
}

$protocol = Select-ExpectedFile -Root $sessionDir.FullName -Pattern "*.m" -ScanId $scanId
if ($null -eq $protocol) {
    Add-CheckItem -Items $items -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "SKIP" -Note "No protocol backup found."
} else {
    $protocolCode = Get-AnimalCode $protocol.Name
    if ($animalCode -ne "" -and $protocolCode -ne "" -and $protocolCode -ne $animalCode) {
        Add-CheckItem -Items $items -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "WARN" `
            -Note "Animal code mismatch in protocol backup: folder=$animalCode file=$protocolCode" `
            -Src $protocol.FullName
    } else {
        Add-CheckItem -Items $items -Label "BPod protocol backup (.m)" -Pattern "*.m" -Status "OK" -Note "Protocol backup present." -Src $protocol.FullName
    }
}

$ok = @($items | Where-Object status -eq "OK").Count
$warn = @($items | Where-Object status -eq "WARN").Count
$skip = @($items | Where-Object status -eq "SKIP").Count
$fail = @($items | Where-Object status -eq "FAIL").Count
$status = if ($fail -gt 0) { "FAILED" } else { "DONE" }
$message = if ($fail -gt 0) { "Manual verification failed; upload blocked" } else { "Manual verification passed; upload ready" }

$obj = [ordered]@{
    status = $status
    message = $message
    session_timestamp = ""
    animal_label = $animalCode
    animal_code = $animalCode
    scan_id = $scanId
    destination = $sessionDir.FullName
    ok_count = $ok
    warn_count = $warn
    skip_count = $skip
    fail_count = $fail
    items = @($items)
    updated_at = NowStamp
    verified_at = NowStamp
    verifier = "verify_session_folder_for_upload.ps1"
    bpod_imaging_max_diff_min = $MaxBpodImagingDiffMin
    tracking_imaging_max_diff_min = $MaxTrackingImagingDiffMin
}

if ($UpdateStatus) {
    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    Write-Host "`nWrote: $statusPath"
} else {
    Write-Host "`nDry run only. Add -UpdateStatus to rewrite external_copy_status.json."
}

if ($AlertDiscord) {
    Load-DiscordFromConfig
    $title = if ($fail -gt 0) { "Session verification failed: $animalCode scan$scanId" } else { "Session verification passed: $animalCode scan$scanId" }
    $bad = @($items | Where-Object { $_.status -eq "FAIL" -or $_.status -eq "WARN" })
    $lines = @(
        "Session: $($sessionDir.Name)",
        "Status: $status",
        "Message: $message",
        ""
    )
    if ($bad.Count -gt 0) {
        $lines += "Items needing attention:"
        foreach ($it in $bad) {
            $lines += "  - [$($it.status)] $($it.label) - $($it.note)"
        }
    } else {
        $lines += "All required files are present and time-consistent."
    }
    try { Send-VerifyDiscordAlert -Title $title -Message ($lines -join "`n") } catch { Write-Host "WARNING: Discord alert failed: $_" }
}

$obj | ConvertTo-Json -Depth 8

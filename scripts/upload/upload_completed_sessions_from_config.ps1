param(
    [string]$ConfigPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\config\upload_sessions_config.json",
    [string]$SessionDate = "",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "..\discord\Send-DiscordAlert.ps1")

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy upload_sessions_config.template.json to upload_sessions_config.json and fill it in."
}

$cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$DataRoot = if ($cfg.dataRoot) { [string]$cfg.dataRoot } else { "F:\Data\jisooj" }
$RemoteRoot = if ($cfg.remoteRoot) { [string]$cfg.remoteRoot } else { "/data/jisooj" }
$StateDir = if ($cfg.stateDir) { [string]$cfg.stateDir } else { "C:\Users\ScanImage\Documents\ScanImageAutomation\state\upload_state" }
$StableMinutes = if ($cfg.stableMinutes) { [int]$cfg.stableMinutes } else { 10 }
$SinceDays = if ($cfg.sinceDays) { [int]$cfg.sinceDays } else { 2 }
$AllowWarnings = if ($null -ne $cfg.allowWarnings) { [bool]$cfg.allowWarnings } else { $true }
$RequireBPod = if ($null -ne $cfg.requireBPod) { [bool]$cfg.requireBPod } else { $false }
$RequireCopyStatus = if ($null -ne $cfg.requireCopyStatus) { [bool]$cfg.requireCopyStatus } else { $true }
$OnlySessionDateToday = if ($null -ne $cfg.onlySessionDateToday) { [bool]$cfg.onlySessionDateToday } else { $false }
$StrictAnimalCode = if ($null -ne $cfg.strictAnimalCode) { [bool]$cfg.strictAnimalCode } else { $true }
$Method = if ($cfg.method) { ([string]$cfg.method).ToLowerInvariant() } else { "winscp" }
$ManualReviewRetryDays = if ($cfg.manualReviewRetryDays) { [int]$cfg.manualReviewRetryDays } else { 3 }
$UploadExcludePatterns = if ($cfg.uploadExcludePatterns) {
    @($cfg.uploadExcludePatterns | ForEach-Object { [string]$_ })
} else {
    @("external_copy_job.json", "external_copy_summary*.txt")
}

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    Write-Host $line
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Add-Content -Path $script:RunLog -Value $line
            return
        }
        catch {
            if ($i -eq 4) { throw }
            Start-Sleep -Milliseconds (100 * ($i + 1))
        }
    }
}

function Join-RemotePath {
    param([string]$Left, [string]$Right)
    $l = $Left.TrimEnd('/')
    $r = $Right.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($l)) { return "/$r" }
    return "$l/$r"
}

function Get-RemoteParentPath {
    param([string]$Path)
    $p = $Path.TrimEnd('/')
    $idx = $p.LastIndexOf('/')
    if ($idx -le 0) { return "/" }
    return $p.Substring(0, $idx)
}

function ConvertTo-SafeName {
    param([string]$Name)
    return ($Name -replace '[^\w.-]', '_')
}

function Get-RosCode {
    param([string]$Text)
    $m = [regex]::Match($Text, 'ROS-\d{4}')
    if ($m.Success) { return $m.Value }
    return ""
}

function Add-CodeEvidence {
    param(
        [System.Collections.ArrayList]$Evidence,
        [string]$Source,
        [string]$Code
    )

    if (-not [string]::IsNullOrWhiteSpace($Code)) {
        [void]$Evidence.Add([ordered]@{ source = $Source; code = $Code })
    }
}

function Get-SessionDateFromName {
    param([string]$Name)

    $m = [regex]::Match($Name, '_(\d{4}-\d{2}-\d{2})_scan')
    if (-not $m.Success) { return $null }

    try {
        return [datetime]::ParseExact($m.Groups[1].Value, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture).Date
    }
    catch {
        return $null
    }
}

function Test-AnimalCodeConsistency {
    param(
        [System.IO.DirectoryInfo]$Dir,
        [string]$StatusJsonPath
    )

    $evidence = New-Object System.Collections.ArrayList
    Add-CodeEvidence -Evidence $evidence -Source "folder" -Code (Get-RosCode $Dir.Name)

    $allFiles = Get-ChildItem -Path $Dir.FullName -File -Force
    foreach ($f in $allFiles) {
        if ($f.Name -eq "external_copy_status.json" -or $f.Name -eq "external_copy_job.json") { continue }

        $code = Get-RosCode $f.Name
        if ([string]::IsNullOrWhiteSpace($code)) { continue }

        if ($f.Name -match '\.(tif|h5)$') {
            Add-CodeEvidence -Evidence $evidence -Source ("imaging:" + $f.Name) -Code $code
        }
        elseif ($f.Name -match '\.(mat|m|csv|txt)$' -and $f.Name -notmatch 'mini2p2|timestamps') {
            Add-CodeEvidence -Evidence $evidence -Source ("bpod:" + $f.Name) -Code $code
        }
    }

    if (Test-Path $StatusJsonPath) {
        try {
            $statusData = Get-Content -Path $StatusJsonPath -Raw | ConvertFrom-Json
            # Prefer explicit fields; fall back to extracting code from items[].dst (CopyWorker format)
            if ($statusData.animal_code) {
                Add-CodeEvidence -Evidence $evidence -Source "status:animal_code" -Code $statusData.animal_code
            } elseif ($statusData.destination) {
                Add-CodeEvidence -Evidence $evidence -Source "status:destination" -Code (Get-RosCode $statusData.destination)
            } else {
                $firstDst = @($statusData.items) | Where-Object { $_.dst } | Select-Object -First 1
                if ($firstDst) {
                    Add-CodeEvidence -Evidence $evidence -Source "status:items_dst" -Code (Get-RosCode ([string]$firstDst.dst))
                }
            }
        } catch { }
    }

    $codes = @($evidence | ForEach-Object { $_.code } | Sort-Object -Unique)
    if ($codes.Count -le 1) {
        return @{ Ok = $true; Codes = $codes; Evidence = @($evidence) }
    }

    $detail = (($evidence | ForEach-Object { "$($_.source)=$($_.code)" }) -join "; ")
    return @{ Ok = $false; Codes = $codes; Evidence = @($evidence); Detail = $detail }
}

function Send-DiscordAlert {
    param(
        [string]$Title,
        [string]$Message
    )

    if (-not $cfg.discord) { return }
    $enabled = if ($null -ne $cfg.discord.enabled) { [bool]$cfg.discord.enabled } else { $false }
    $webhookUrl = if ($cfg.discord.webhookUrl) { [string]$cfg.discord.webhookUrl } else { "" }
    if (-not $enabled -or [string]::IsNullOrWhiteSpace($webhookUrl)) { return }

    try {
        $username = if ($cfg.discord.username) { [string]$cfg.discord.username } else { "ScanImage Upload Bot" }
        Invoke-DiscordWebhook -WebhookUrl $webhookUrl -Title $Title -Message $Message -Username $username
    }
    catch {
        Write-Log ("WARNING: Discord alert failed: " + $_.Exception.Message)
    }
}

function Test-ManualReviewBool {
    param([object]$ManualReview, [string]$PropertyName)
    return ($null -ne $ManualReview -and
        $null -ne $ManualReview.approved_for_upload -and
        [bool]$ManualReview.approved_for_upload -and
        $null -ne $ManualReview.$PropertyName -and
        [bool]$ManualReview.$PropertyName)
}

function Test-MissingPatternAllowed {
    param([object]$ManualReview, [string]$Pattern)

    if ($null -eq $ManualReview -or
        $null -eq $ManualReview.approved_for_upload -or
        -not [bool]$ManualReview.approved_for_upload -or
        $null -eq $ManualReview.allow_missing_patterns) {
        return $false
    }

    foreach ($allowed in @($ManualReview.allow_missing_patterns)) {
        if ([string]$allowed -eq $Pattern -or $Pattern -like [string]$allowed) {
            return $true
        }
    }
    return $false
}

function Test-SessionComplete {
    param([System.IO.DirectoryInfo]$Dir)

    $flags = New-Object System.Collections.Generic.List[string]
    $statusJson = Join-Path $Dir.FullName "external_copy_status.json"
    $statusData = $null
    $manualReview = $null

    if (-not (Test-Path $statusJson)) {
        $flags.Add("status_missing")
        if ($RequireCopyStatus) {
            return @{ Ok = $false; Reason = "external_copy_status.json is missing"; Flags = @($flags) }
        }
    } else {
        try {
            $statusData = Get-Content -Path $statusJson -Raw | ConvertFrom-Json
            if ($null -ne $statusData.manual_review -and
                $null -ne $statusData.manual_review.approved_for_upload -and
                [bool]$statusData.manual_review.approved_for_upload) {
                $manualReview = $statusData.manual_review
                $flags.Add("manual_review")
            }
        }
        catch {
            $flags.Add("status_parse_error")
            return @{ Ok = $false; Reason = "external_copy_status.json parse error"; Flags = @($flags) }
        }
    }

    $files = Get-ChildItem -Path $Dir.FullName -File -Force
    if (-not $files) {
        return @{ Ok = $false; Reason = "folder contains no files" }
    }

    $newestWrite = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $ageMin = ((Get-Date) - $newestWrite).TotalMinutes
    if ($ageMin -lt $StableMinutes) {
        return @{ Ok = $false; Reason = ("not stable yet; newest file age {0:N1} min" -f $ageMin) }
    }

    foreach ($pat in @("*.tif", "*.h5", "*.mp4", "*timestamps*.csv")) {
        if (-not (Get-ChildItem -Path $Dir.FullName -File -Filter $pat -ErrorAction SilentlyContinue)) {
            if (Test-MissingPatternAllowed -ManualReview $manualReview -Pattern $pat) {
                $flags.Add("manual_review_missing_$pat")
            } else {
                return @{ Ok = $false; Reason = "missing required file pattern $pat"; Flags = @($flags) }
            }
        }
    }

    $zeroMajor = $files | Where-Object {
        $_.Length -eq 0 -and $_.Extension -match '^\.(tif|h5|mp4|csv|mat)$'
    } | Select-Object -First 1
    if ($zeroMajor) {
        return @{ Ok = $false; Reason = "zero-byte data file: $($zeroMajor.Name)" }
    }

    if ($StrictAnimalCode) {
        $animalCheck = Test-AnimalCodeConsistency -Dir $Dir -StatusJsonPath $statusJson
        if (-not $animalCheck.Ok) {
            return @{
                Ok = $false
                Reason = "animal code mismatch: " + $animalCheck.Detail
                Flags = @("animal_code_mismatch")
            }
        }
    }

    $bpodMat = Get-ChildItem -Path $Dir.FullName -File -Filter "*.mat" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bpodMat) {
        $flags.Add("bpod_missing")
        if ($RequireBPod) {
            return @{ Ok = $false; Reason = "missing BPod .mat"; Flags = @($flags) }
        }
    }

    if ($null -ne $statusData) {
        try {
            $copyStatus = [string]$statusData.status
            if ($copyStatus -eq "QUEUED" -or $copyStatus -eq "RUNNING") {
                return @{ Ok = $false; Reason = "CopyWorker status is $copyStatus; not yet complete"; Flags = @("copy_in_progress") }
            }
            if ($copyStatus -ne "" -and $copyStatus -ne "DONE") {
                $flags.Add("copy_status_$copyStatus")
                if (Test-ManualReviewBool -ManualReview $manualReview -PropertyName "allow_copy_status_failure") {
                    $flags.Add("manual_review_copy_status_failure")
                } else {
                    return @{ Ok = $false; Reason = "CopyWorker status is $copyStatus"; Flags = @($flags) }
                }
            }

            # Prefer explicit top-level fields; fall back to counting from items[] (CopyWorker format).
            $statusItems = @($statusData.items)
            $failCount = if ($null -ne $statusData.fail_count) {
                [int]$statusData.fail_count
            } elseif ($statusItems.Count -gt 0) {
                @($statusItems | Where-Object { $_.status -eq "FAIL" }).Count
            } else { -1 }

            if ($failCount -gt 0) {
                $flags.Add("status_fail_$failCount")
                if (Test-ManualReviewBool -ManualReview $manualReview -PropertyName "allow_copy_status_failure") {
                    $flags.Add("manual_review_copy_status_failure")
                } else {
                    return @{ Ok = $false; Reason = "CopyWorker reported fail_count=$failCount"; Flags = @($flags) }
                }
            } elseif ($failCount -lt 0) {
                $flags.Add("status_fail_count_missing")
                if (Test-ManualReviewBool -ManualReview $manualReview -PropertyName "allow_copy_status_failure") {
                    $flags.Add("manual_review_copy_status_failure")
                } else {
                    return @{ Ok = $false; Reason = "CopyWorker status missing fail_count"; Flags = @($flags) }
                }
            }

            $warnCount = if ($null -ne $statusData.warn_count) {
                [int]$statusData.warn_count
            } elseif ($statusItems.Count -gt 0) {
                @($statusItems | Where-Object { $_.status -eq "WARN" }).Count
            } else { -1 }

            if ($warnCount -gt 0) {
                $flags.Add("status_warn_$warnCount")
                if (-not $AllowWarnings -and -not (Test-ManualReviewBool -ManualReview $manualReview -PropertyName "allow_warnings")) {
                    return @{ Ok = $false; Reason = "status reports warn_count=$warnCount"; Flags = @($flags) }
                }
                if (-not $AllowWarnings) {
                    $flags.Add("manual_review_warnings")
                }
            } elseif ($warnCount -lt 0) {
                $flags.Add("status_warn_count_missing")
            }
        } catch {
            $flags.Add("status_parse_error")
            return @{ Ok = $false; Reason = "external_copy_status.json parse error"; Flags = @($flags) }
        }
    }

    return @{ Ok = $true; Reason = "complete"; Flags = @($flags) }
}

function Invoke-WinSCPUpload {
    param([System.IO.DirectoryInfo]$Dir, [string]$RemoteFolder)

    $winscpPath = [string]$cfg.winscp.path
    $openTarget = if ($cfg.winscp.openTarget) { [string]$cfg.winscp.openTarget } else { "" }
    $useStoredConfig = if ($null -ne $cfg.winscp.useStoredConfig) { [bool]$cfg.winscp.useStoredConfig } else { $true }
    if (-not (Test-Path $winscpPath)) { throw "WinSCP.com not found: $winscpPath" }

    $openCommand = ""
    if ([string]::IsNullOrWhiteSpace($openTarget)) {
        $hostName = if ($cfg.winscp.host) { [string]$cfg.winscp.host } else { "" }
        $userName = if ($cfg.winscp.user) { [string]$cfg.winscp.user } else { "" }
        $password = if ($cfg.winscp.password) { [string]$cfg.winscp.password } else { "" }
        $hostKey = if ($cfg.winscp.hostKey) { [string]$cfg.winscp.hostKey } else { "" }

        if ([string]::IsNullOrWhiteSpace($hostName) -or
            [string]::IsNullOrWhiteSpace($userName) -or
            [string]::IsNullOrWhiteSpace($password) -or
            [string]::IsNullOrWhiteSpace($hostKey)) {
            throw "Set winscp.openTarget, or fill winscp.host/user/password/hostKey in config."
        }

        $userEsc = [System.Uri]::EscapeDataString($userName)
        $passEsc = [System.Uri]::EscapeDataString($password)
        $openTarget = "sftp://$userEsc`:$passEsc@$hostName/ -hostkey=`"$hostKey`""
        $openCommand = "open $openTarget"
        $useStoredConfig = $false
    }
    else {
        $openCommand = "open `"$openTarget`""
    }

    $tmpScript = Join-Path $env:TEMP ("winscp_upload_" + [guid]::NewGuid().ToString("N") + ".txt")
    $localMask = Join-Path $Dir.FullName "*"
    $fileMask = ""
    if ($UploadExcludePatterns.Count -gt 0) {
        $fileMask = "| " + ($UploadExcludePatterns -join "; ")
    }

    $commands = @(
        "option batch abort",
        "option confirm off",
        $openCommand,
        "option batch continue",
        "mkdir `"$RemoteFolder`"",
        "option batch abort",
        "put -resume -nopermissions -nopreservetime -filemask=`"$fileMask`" `"$localMask`" `"$RemoteFolder/`"",
        "exit"
    )

    Set-Content -Path $tmpScript -Value $commands -Encoding ASCII
    try {
        if ($useStoredConfig) {
            & $winscpPath /script="$tmpScript" /log="$script:TransferLog"
        }
        else {
            & $winscpPath /ini=nul /script="$tmpScript" /log="$script:TransferLog"
        }
        if ($LASTEXITCODE -ne 0) { throw "WinSCP failed with exit code $LASTEXITCODE" }
    }
    finally {
        Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RcloneUpload {
    param([System.IO.DirectoryInfo]$Dir, [string]$RemoteFolder)

    $rclonePath = if ($cfg.rclone.path) { [string]$cfg.rclone.path } else { "rclone" }
    $remote = [string]$cfg.rclone.remote
    if ([string]::IsNullOrWhiteSpace($remote)) { throw "rclone.remote is empty in config" }

    $remoteTarget = "$remote`:$RemoteFolder"
    $rcloneArgs = @("copy", $Dir.FullName, $remoteTarget, "--create-empty-src-dirs", "--log-file", $script:TransferLog, "--log-level", "INFO")
    foreach ($pat in $UploadExcludePatterns) {
        $rcloneArgs += @("--exclude", $pat)
    }

    if ($cfg.rclone.extraArgs) {
        foreach ($arg in $cfg.rclone.extraArgs) { $rcloneArgs += [string]$arg }
    }

    & $rclonePath @rcloneArgs
    if ($LASTEXITCODE -ne 0) { throw "rclone failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path $DataRoot)) { throw "DataRoot not found: $DataRoot" }

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$logDir = Join-Path $StateDir "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:RunLog = Join-Path $logDir ("upload_completed_sessions_" + (Get-Date -Format "yyyyMMdd") + ".log")
$script:TransferLog = Join-Path $logDir ("transfer_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

if ([string]::IsNullOrWhiteSpace($SessionDate)) {
    $filterSessionDate = Get-Date -Format "yyyy-MM-dd"
}
else {
    $filterSessionDate = $SessionDate
}

Write-Log "Starting upload scan. Method=$Method DataRoot=$DataRoot RemoteRoot=$RemoteRoot OnlySessionDateToday=$OnlySessionDateToday SessionDate=$filterSessionDate DryRun=$DryRun"

$cutoff = (Get-Date).Date.AddDays(-1 * [Math]::Max($SinceDays - 1, 0))
$dirs = Get-ChildItem -Path $DataRoot -Directory -ErrorAction Stop |
    Where-Object {
        $isSessionFolder = ($_.Name -match '_scan.+_sess')
        if (-not $isSessionFolder) {
            $false
        }
        elseif ($OnlySessionDateToday) {
            $_.Name -match "_$([regex]::Escape($filterSessionDate))_scan"
        }
        else {
            $_.LastWriteTime -ge $cutoff
        }
    } |
    Sort-Object LastWriteTime

$manualReviewDirs = Get-ChildItem -Path $DataRoot -Directory -ErrorAction Stop |
    Where-Object {
        if ($_.Name -notmatch '_scan.+_sess') { return $false }
        $sessionDate = Get-SessionDateFromName -Name $_.Name
        if ($null -eq $sessionDate) { return $false }
        $today = (Get-Date).Date
        $oldestRetryDate = $today.AddDays(-1 * [Math]::Max($ManualReviewRetryDays - 1, 0))
        if ($sessionDate -lt $oldestRetryDate -or $sessionDate -gt $today) { return $false }

        $statusPath = Join-Path $_.FullName "external_copy_status.json"
        if (-not (Test-Path $statusPath)) { return $false }
        try {
            $sd = Get-Content -Path $statusPath -Raw | ConvertFrom-Json
            return ($null -ne $sd.manual_review -and
                $null -ne $sd.manual_review.approved_for_upload -and
                [bool]$sd.manual_review.approved_for_upload)
        }
        catch {
            return $false
        }
    }

$dirs = @($dirs + $manualReviewDirs) |
    Sort-Object FullName -Unique |
    Sort-Object LastWriteTime

foreach ($dir in $dirs) {
    $stateFile = Join-Path $StateDir ((ConvertTo-SafeName $dir.Name) + ".uploaded.json")
    if (Test-Path $stateFile) {
        Write-Log "SKIP already uploaded: $($dir.Name)"
        continue
    }

    $check = Test-SessionComplete -Dir $dir
    if (-not $check.Ok) {
        Write-Log "WAIT $($dir.Name): $($check.Reason)"

        $discordBody = "Session: $($dir.Name)`nReason: $($check.Reason)"
        $statusJsonPath = Join-Path $dir.FullName "external_copy_status.json"
        if (Test-Path $statusJsonPath) {
            try {
                $sd = Get-Content -Path $statusJsonPath -Raw | ConvertFrom-Json
                $badItems = @($sd.items | Where-Object { $_.status -eq "FAIL" })
                if ($badItems.Count -gt 0) {
                    $discordBody += "`n`nFailed items:"
                    foreach ($it in $badItems) { $discordBody += "`n  [$($it.status)] $($it.label) — $($it.note)" }
                }
            } catch { }
        }
        if ($DryRun) {
            Write-Log "DRYRUN would alert Discord: Upload waiting: $($dir.Name)"
        } else {
            Send-DiscordAlert -Title "Upload waiting: $($dir.Name)" -Message $discordBody
        }
        continue
    }

    $remoteFolder = Join-RemotePath $RemoteRoot $dir.Name

    if ($DryRun) {
        $flagText = if ($check.Flags -and $check.Flags.Count -gt 0) { " flags=" + (($check.Flags) -join ",") } else { "" }
        Write-Log "DRYRUN would upload: $($dir.FullName) -> $remoteFolder$flagText"
        continue
    }

    $flagText = if ($check.Flags -and $check.Flags.Count -gt 0) { " flags=" + (($check.Flags) -join ",") } else { "" }
    Write-Log "UPLOAD $($dir.FullName) -> $remoteFolder$flagText"
    try {
        switch ($Method) {
            "winscp" { Invoke-WinSCPUpload -Dir $dir -RemoteFolder $remoteFolder }
            "rclone" { Invoke-RcloneUpload -Dir $dir -RemoteFolder $remoteFolder }
            default { throw "Unsupported method: $Method" }
        }
    }
    catch {
        $err = $_.Exception.Message
        Write-Log "FAILED upload $($dir.Name): $err"
        Send-DiscordAlert `
            -Title "Upload failed: $($dir.Name)" `
            -Message "Session: $($dir.Name)`nLocal: $($dir.FullName)`nRemote: $remoteFolder`nReason: $err"
        continue
    }

    [ordered]@{
        method = $Method
        local_path = $dir.FullName
        remote_path = $remoteFolder
        flags = @($check.Flags)
        uploaded_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        source_last_write = $dir.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding ASCII

    Write-Log "DONE $($dir.Name)"
}

Write-Log "Upload scan finished."

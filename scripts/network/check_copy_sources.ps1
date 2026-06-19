param(
    [string]$ConfigPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\config\copy_sources_config.json",
    [string]$Mini2pAuxIp = "172.21.241.8",
    [string]$TrackingPath = "\\172.21.241.8\data\tracking",
    [string]$BpodPath = "\\172.21.241.8\Bpod Local",
    [string]$LogDir = "C:\Users\ScanImage\Documents\ScanImageAutomation\logs\network",
    [int]$TimeoutMinutes = 10,
    [int]$PollSeconds = 30,
    [string]$Username = "",
    [string]$Password = ""
)

$ErrorActionPreference = 'Continue'

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.mini2pAuxIp) { $Mini2pAuxIp = [string]$cfg.mini2pAuxIp }
        if ($cfg.trackingPath) { $TrackingPath = [string]$cfg.trackingPath }
        if ($cfg.bpodPath) { $BpodPath = [string]$cfg.bpodPath }
        if ($cfg.logDir) { $LogDir = [string]$cfg.logDir }
        if ($cfg.timeoutMinutes) { $TimeoutMinutes = [int]$cfg.timeoutMinutes }
        if ($cfg.pollSeconds) { $PollSeconds = [int]$cfg.pollSeconds }
        if ($cfg.username) { $Username = [string]$cfg.username }
        if ($cfg.password) { $Password = [string]$cfg.password }
    }
    catch {
        throw "Failed to read config file: $ConfigPath. $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunLog = Join-Path $LogDir ("copy_source_check_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $RunLog -Value $line
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port
    )

    try {
        $result = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
        return [bool]$result.TcpTestSucceeded
    }
    catch {
        Write-Log ("WARN: Test-NetConnection failed for {0}:{1}: {2}" -f $ComputerName, $Port, $_.Exception.Message)
        return $false
    }
}

function Test-SharePath {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path) {
            return @{ Ok = $true; Reason = "accessible" }
        }
        return @{ Ok = $false; Reason = "not found or not accessible" }
    }
    catch {
        return @{ Ok = $false; Reason = $_.Exception.Message }
    }
}

function Invoke-NetUse {
    param([string]$UncPath)

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        Write-Log ("Trying Windows reconnect: net use ""{0}"" /persistent:yes" -f $UncPath)
        $output = cmd /c net use "$UncPath" /persistent:yes 2>&1
    }
    else {
        Write-Log ("Trying Windows reconnect with configured username: net use ""{0}"" /user:""{1}"" /persistent:yes" -f $UncPath, $Username)
        $output = cmd /c net use "$UncPath" "$Password" /user:"$Username" /persistent:yes 2>&1
    }

    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log ("  net use: " + $line)
        }
    }
    return ($exitCode -eq 0)
}

function Get-ShareRoot {
    param([string]$Path)

    $trimmed = $Path.TrimStart('\')
    $parts = $trimmed -split '\\'
    if ($parts.Count -lt 2) { return $Path }
    return "\\{0}\{1}" -f $parts[0], $parts[1]
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$trackingOk = $false
$bpodOk = $false

Write-Log "=== Copy source network check started ==="
Write-Log ("mini2paux IP : {0}" -f $Mini2pAuxIp)
Write-Log ("Tracking path: {0}" -f $TrackingPath)
Write-Log ("BPod path    : {0}" -f $BpodPath)
if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Log "Credentials : not configured; using current Windows session/remembered credentials."
}
else {
    Write-Log ("Credentials : configured username '{0}'; password is hidden." -f $Username)
}

while ((Get-Date) -le $deadline) {
    $pingOk = Test-Connection -ComputerName $Mini2pAuxIp -Count 1 -Quiet
    $smb445 = Test-TcpPort -ComputerName $Mini2pAuxIp -Port 445
    $smb139 = Test-TcpPort -ComputerName $Mini2pAuxIp -Port 139

    Write-Log ("Ping={0}; SMB445={1}; SMB139={2}" -f $pingOk, $smb445, $smb139)

    $tracking = Test-SharePath -Path $TrackingPath
    $bpod = Test-SharePath -Path $BpodPath

    Write-Log ("Tracking: {0} ({1})" -f $tracking.Ok, $tracking.Reason)
    Write-Log ("BPod    : {0} ({1})" -f $bpod.Ok, $bpod.Reason)

    if (-not $tracking.Ok -and ($smb445 -or $smb139)) {
        Invoke-NetUse -UncPath (Get-ShareRoot -Path $TrackingPath) | Out-Null
        $tracking = Test-SharePath -Path $TrackingPath
    }

    if (-not $bpod.Ok -and ($smb445 -or $smb139)) {
        Invoke-NetUse -UncPath (Get-ShareRoot -Path $BpodPath) | Out-Null
        $bpod = Test-SharePath -Path $BpodPath
    }

    $trackingOk = [bool]$tracking.Ok
    $bpodOk = [bool]$bpod.Ok

    if ($trackingOk -and $bpodOk) {
        Write-Log "SUCCESS: all copy source paths are accessible."
        exit 0
    }

    if ((Get-Date) -lt $deadline) {
        Write-Log ("Waiting {0} seconds before retry..." -f $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
    }
}

Write-Log ("FAILED: copy source check timed out. TrackingOk={0}; BPodOk={1}" -f $trackingOk, $bpodOk)
Write-Log "If ping works but SMB445/139 fail, check mini2paux Windows file sharing, firewall, network profile, and share permissions."
exit 2

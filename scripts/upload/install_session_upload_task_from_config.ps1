param(
    [string]$ScriptPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\upload\upload_completed_sessions_from_config.ps1",
    [string]$ConfigPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\config\upload_sessions_config.json",
    [string]$TaskName = "ScanImageCompletedSessionUpload",
    [string]$Time = "20:00"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { throw "Upload script not found: $ScriptPath" }
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

$taskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

$createOutput = & schtasks.exe /Create /F /SC DAILY /ST $Time /TN $TaskName /TR $taskCmd 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create scheduled task '$TaskName' (exit $LASTEXITCODE): $($createOutput -join "`n")"
}

$queryOutput = & schtasks.exe /Query /TN "\$TaskName" /V /FO LIST 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Scheduled task '$TaskName' was not verifiable after creation (exit $LASTEXITCODE): $($queryOutput -join "`n")"
}

Write-Host "Scheduled task '$TaskName' created."
Write-Host "Runs daily at $Time."
Write-Host "Config: $ConfigPath"
Write-Host ""
Write-Host $queryOutput


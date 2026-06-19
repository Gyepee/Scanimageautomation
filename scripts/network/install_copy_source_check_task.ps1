param(
    [string]$ScriptPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\network\check_copy_sources.ps1",
    [string]$ConfigPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\config\copy_sources_config.json",
    [string]$TaskName = "ScanImageCopySourceNetworkCheck",
    [string]$DailyTime = "00:00",
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}

$taskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

schtasks /Create /F /SC DAILY /ST $DailyTime /TN $TaskName /TR $taskCmd | Out-Null
schtasks /Create /F /SC ONLOGON /DELAY 0002:00 /TN ($TaskName + "AtLogon") /TR $taskCmd | Out-Null

Write-Host "Scheduled task '$TaskName' created. Runs daily at $DailyTime."
Write-Host "Scheduled task '$($TaskName)AtLogon' created. Runs 2 minutes after user logon."
Write-Host "Script: $ScriptPath"
Write-Host "Config: $ConfigPath"

if ($RunNow) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ConfigPath $ConfigPath
}


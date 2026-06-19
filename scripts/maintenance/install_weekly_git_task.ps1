param(
    [string]$RepoPath = "C:\Users\ScanImage\Documents\MATLAB\UserFunction",
    [string]$ScriptPath = "C:\Users\ScanImage\Documents\ScanImageAutomation\scripts\maintenance\weekly_git_update.ps1",
    [string]$TaskName = "ScanImageWeeklyGitUpdate",
    [string]$DayOfWeek = "MON",
    [string]$Time = "20:00"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}
if (-not (Test-Path $RepoPath)) {
    throw "RepoPath not found: $RepoPath"
}

$startDate = Get-Date -Format 'MM/dd/yyyy'

$taskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -RepoPath `"$RepoPath`""

schtasks /Create /F /SC WEEKLY /D $DayOfWeek /ST $Time /SD $startDate /TN $TaskName /TR $taskCmd | Out-Null

Write-Host "Scheduled task '$TaskName' created."
Write-Host "Starts: $startDate $Time, repeats weekly on $DayOfWeek"
Write-Host "Script: $ScriptPath"
Write-Host "Repo: $RepoPath"

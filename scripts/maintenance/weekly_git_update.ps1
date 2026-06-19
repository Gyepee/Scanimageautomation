param(
    [string]$RepoPath = "C:\Users\ScanImage\Documents\MATLAB\UserFunction",
    [string]$Branch = "main"
)

$ErrorActionPreference = 'Stop'

$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) {
    $git = "git"
}

if (-not (Test-Path $RepoPath)) {
    throw "RepoPath not found: $RepoPath"
}

Set-Location $RepoPath

if (-not (Test-Path ".git")) {
    throw "No .git folder found in $RepoPath"
}

# Try to refresh ScanImage version snapshot if MATLAB is available.
$matlabCandidates = @(
    "$Env:ProgramFiles\MATLAB\R2026a\bin\matlab.exe",
    "$Env:ProgramFiles\MATLAB\R2025b\bin\matlab.exe",
    "$Env:ProgramFiles\MATLAB\R2025a\bin\matlab.exe",
    "$Env:ProgramFiles\MATLAB\R2024b\bin\matlab.exe",
    "$Env:ProgramFiles\MATLAB\R2024a\bin\matlab.exe"
)

$matlabExe = $matlabCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($matlabExe -and (Test-Path (Join-Path $RepoPath "capture_scanimage_version.m"))) {
    & $matlabExe -batch "try, cd('$RepoPath'); capture_scanimage_version; catch ME, disp(getReport(ME)); end"
}

& $git add -A

$status = & $git status --porcelain
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "No changes to commit."
    exit 0
}

$msg = "chore: weekly ScanImage update $(Get-Date -Format 'yyyy-MM-dd')"
& $git commit -m $msg

$originUrl = & $git remote get-url origin 2>$null
if ([string]::IsNullOrWhiteSpace($originUrl)) {
    Write-Host "Committed locally, but no 'origin' remote is configured yet."
    exit 0
}

& $git push origin $Branch

Write-Host "Weekly update completed."
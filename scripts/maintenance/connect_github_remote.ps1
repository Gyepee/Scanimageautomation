param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,
    [string]$RepoPath = "C:\Users\ScanImage\Documents\MATLAB\UserFunction",
    [string]$Branch = "main"
)

$ErrorActionPreference = 'Stop'

$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) {
    $git = "git"
}

Set-Location $RepoPath

$existingOrigin = ""
$remotes = & $git remote
if ($remotes -contains 'origin') {
    $existingOrigin = & $git remote get-url origin
}

if ([string]::IsNullOrWhiteSpace($existingOrigin)) {
    & $git remote add origin $RepoUrl
} else {
    & $git remote set-url origin $RepoUrl
}

& $git push -u origin $Branch

Write-Host "Remote connected and branch '$Branch' pushed."
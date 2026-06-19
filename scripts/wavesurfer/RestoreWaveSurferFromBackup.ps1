param(
    [Parameter(Mandatory = $true)]
    [string]$Backup,
    [string]$Target = "C:\Program Files\+ws\WavesurferModel.m"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Backup)) {
    throw "Backup file not found: $Backup"
}

Copy-Item -LiteralPath $Backup -Destination $Target -Force
Write-Host "WaveSurfer restored from: $Backup"

param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath,
    [string]$ReviewedBy = $env:USERNAME,
    [string]$Note = "",
    [switch]$AllowCopyStatusFailure,
    [switch]$AllowWarnings,
    [string[]]$AllowMissingPatterns = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SessionPath -PathType Container)) {
    throw "Session folder not found: $SessionPath"
}

$statusPath = Join-Path $SessionPath "external_copy_status.json"
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "external_copy_status.json not found: $statusPath"
}

$status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json

$manualReview = [ordered]@{
    approved_for_upload = $true
    reviewed_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    reviewed_by = $ReviewedBy
    note = $Note
    allow_copy_status_failure = [bool]$AllowCopyStatusFailure
    allow_warnings = [bool]$AllowWarnings
    allow_missing_patterns = @($AllowMissingPatterns)
}

$status | Add-Member -NotePropertyName "manual_review" -NotePropertyValue $manualReview -Force
$status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8

Write-Host "Manual upload review written to:"
Write-Host $statusPath

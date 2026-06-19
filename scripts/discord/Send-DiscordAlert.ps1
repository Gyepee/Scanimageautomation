param(
    [string]$WebhookUrl = "",
    [string]$Title = "",
    [string]$Message = "ScanImage upload automation Discord test",
    [string]$Username = "ScanImage Upload Bot"
)

function Invoke-DiscordWebhook {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl,
        [string]$Title = "",
        [string]$Message = "",
        [string]$Username = "ScanImage Upload Bot"
    )

    $content = if ([string]::IsNullOrWhiteSpace($Title)) { $Message } else { "**$Title**`n$Message" }
    $payload = @{ username = $Username; content = $content } | ConvertTo-Json -Depth 4
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" | Out-Null
}

# When run directly (not dot-sourced): send a test message.
# Usage: .\Send-DiscordAlert.ps1 -WebhookUrl "https://discord.com/api/webhooks/..."
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "WebhookUrl is required. Usage: .\Send-DiscordAlert.ps1 -WebhookUrl <url> [-Title <title>] [-Message <msg>] [-Username <name>]"
    }
    Invoke-DiscordWebhook -WebhookUrl $WebhookUrl -Title $Title -Message $Message -Username $Username
    Write-Host "Discord message sent."
}

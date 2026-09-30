# Shared, in-memory Claude provider validation; never writes credentials to disk.
Set-StrictMode -Version 2.0
$script:ClaudeEnvAllowList = @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_REASONING_MODEL'
)

function ConvertTo-CcSwitchSecureString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return (ConvertTo-SecureString -String $Value -AsPlainText -Force)
}

function Test-CcSwitchPlaceholderSecret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $candidate = $Value.Trim()
    if ($candidate -match '^(?i:PROXY_MANAGED)$') { return $true }
    return ($candidate -match '(?i)placeholder|your.?key|在这里填|<.*>')
}

function ConvertFrom-CcSwitchClaudeDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Trim().Length -gt 80 -or $Name -match '[\x00-\x1f]') { throw 'Profile name must contain 1 to 80 valid characters.' }
    if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'The selected JSON root must be an object.' }
    $envProperty = $document.PSObject.Properties['env']
    if (-not $envProperty -or $null -eq $envProperty.Value -or $envProperty.Value -isnot [pscustomobject]) {
        throw 'The selected JSON must contain an env object in the Claude Code settings format.'
    }

    $safeEnvironment = [ordered]@{}
    foreach ($key in $script:ClaudeEnvAllowList) {
        $property = $envProperty.Value.PSObject.Properties[$key]
        if ($property -and $property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
            $safeEnvironment[$key] = [string]$property.Value
        }
    }

    $authToken = [string]$safeEnvironment['ANTHROPIC_AUTH_TOKEN']
    $apiKey = [string]$safeEnvironment['ANTHROPIC_API_KEY']
    if (-not [string]::IsNullOrWhiteSpace($authToken)) { $authToken = $authToken.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $apiKey.Trim() }
    if ((-not [string]::IsNullOrWhiteSpace($authToken)) -and (-not [string]::IsNullOrWhiteSpace($apiKey))) {
        throw 'The selected JSON contains both Claude auth token and API key fields; resolve the ambiguity before import.'
    }
    $secret = if (-not [string]::IsNullOrWhiteSpace($authToken)) { $authToken } else { $apiKey }
    if ($secret -match '[\x00-\x1f]') { throw 'The selected credential contains unsupported control characters.' }
    if (Test-CcSwitchPlaceholderSecret -Value $secret) {
        throw 'The selected file does not contain a usable direct credential; proxy placeholders and blank values cannot be imported.'
    }
    foreach ($modelKey in @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_REASONING_MODEL')) {
        if ($safeEnvironment.Contains($modelKey) -and (Test-CcSwitchPlaceholderSecret -Value ([string]$safeEnvironment[$modelKey]))) {
            $safeEnvironment.Remove($modelKey)
        }
    }

    $baseUrl = ([string]$safeEnvironment['ANTHROPIC_BASE_URL']).Trim()
    $parsedUrl = $null
    if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$parsedUrl) -or @('http', 'https') -notcontains $parsedUrl.Scheme -or $parsedUrl.UserInfo -or $parsedUrl.Query -or $parsedUrl.Fragment) {
        throw 'The selected Claude configuration must contain a valid HTTP(S) ANTHROPIC_BASE_URL without embedded credentials, query, or fragment.'
    }
    $hostName = $parsedUrl.DnsSafeHost.TrimEnd('.').ToLowerInvariant()
    $ipAddress = $null
    $isIp = [Net.IPAddress]::TryParse($hostName, [ref]$ipAddress)
    if ($hostName -eq 'localhost' -or $hostName.EndsWith('.localhost', [StringComparison]::OrdinalIgnoreCase) -or $hostName -eq 'localhost.localdomain' -or ($isIp -and [Net.IPAddress]::IsLoopback($ipAddress))) {
        throw 'Localhost and loopback API endpoints cannot be imported as a provider.'
    }

    $modelValues = [ordered]@{}
    foreach ($modelKey in @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_REASONING_MODEL')) {
        if ($safeEnvironment.Contains($modelKey)) {
            $modelValue = [string]$safeEnvironment[$modelKey]
            if ($modelValue.Length -gt 256 -or $modelValue -match '[\x00-\x1f]') { throw "The selected model field $modelKey is invalid." }
            $modelValues[$modelKey] = $modelValue
        }
    }
    $secureSecret = ConvertTo-CcSwitchSecureString -Value $secret
    $secret = $null
    $authToken = $null
    $apiKey = $null
    return [pscustomobject]@{
        Name = $Name.Trim()
        BaseUrl = $parsedUrl.GetLeftPart([UriPartial]::Path).TrimEnd('/')
        Secret = $secureSecret
        AuthEnvironmentName = $(if ($safeEnvironment.Contains('ANTHROPIC_AUTH_TOKEN')) { 'ANTHROPIC_AUTH_TOKEN' } else { 'ANTHROPIC_API_KEY' })
        Models = $modelValues
    }
}


[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-provider.ps1')

function Get-CcSwitchUnifiedMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $path = Get-ToolboxSettingsPath -StickRoot $StickRoot
    Assert-ToolboxProviderPath -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'settings.json root must be a JSON object.' }
    $document = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'settings.json root must be a JSON object.' }
    $unified = $document.PSObject.Properties['ccSwitchUnifiedConfig']
    $provider = $document.PSObject.Properties['ccSwitchClaudeProvider']
    if ($unified -and $unified.Value -isnot [bool]) { throw 'settings.json ccSwitchUnifiedConfig must be a JSON boolean.' }
    if ($provider -and $provider.Value -isnot [bool]) { throw 'settings.json ccSwitchClaudeProvider must be a JSON boolean.' }
    $enabled = if ($unified) { [bool]$unified.Value } else { $false }
    if ($enabled -and (-not $provider -or -not $provider.Value)) { throw 'Unified configuration marker requires ccSwitchClaudeProvider=true.' }
    return $enabled
}

function Assert-CcSwitchUnifiedHarnessSupported([string]$StickRoot) {
    $registryPath = Join-Path ([IO.Path]::GetFullPath($StickRoot)) 'harness\registry.json'
    Assert-ToolboxProviderPath -Path $registryPath
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Unified CC Switch mode requires an existing harness registry.' }
    try { $registry = [IO.File]::ReadAllText($registryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Unified CC Switch mode cannot read the harness registry.' }
    if (-not $registry -or -not $registry.PSObject.Properties['harnesses']) { throw 'Unified CC Switch mode requires a valid harness registry.' }
    $enabled = @($registry.harnesses | Where-Object { $_.enabled })
    if ($enabled.Count -eq 0 -or [string]$enabled[0].id -cne 'claude') {
        throw 'Unified CC Switch mode currently supports Claude Code as the first enabled harness only.'
    }
}

function Test-CcSwitchUnifiedActivationReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $root = [IO.Path]::GetFullPath($StickRoot)
    if (Get-CcSwitchUnifiedMode -StickRoot $root) {
        return [pscustomobject]@{ Ready = $true; AlreadyActive = $true; ProviderName = $null }
    }
    Assert-CcSwitchUnifiedHarnessSupported -StickRoot $root
    if (-not (Test-ToolboxCcEncryptedStorePresent -StickRoot $root)) {
        throw 'CC Switch encrypted store is missing; migration/unlock must be completed before unified mode activation.'
    }
    if (-not (Get-Command Get-CcSecureSessionStatus -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $root
    }
    $sessionStatus = Get-CcSecureSessionStatus -StickRoot $root
    if (-not $sessionStatus.Unlocked) { throw 'CC Switch secure session is locked; unified mode was not activated.' }
    $bundle = Get-CcSecureSessionClaudeLaunchBundle -StickRoot $root
    try {
        $provider = $bundle.Provider
        if (-not $provider -or [string]::IsNullOrWhiteSpace([string]$provider.BaseUrl) -or
            -not ($provider.Secret -is [Security.SecureString]) -or $provider.Secret.Length -eq 0 -or
            [string]::IsNullOrWhiteSpace([string]$provider.AuthEnvironmentName)) {
            throw 'The existing CC Switch Claude provider is incomplete; unified mode was not activated.'
        }
        $settings = @($bundle.LaunchFiles | Where-Object { [string]$_.Path -ceq 'settings.json' })
        if ($settings.Count -ne 1) { throw 'The current CC Switch snapshot has no complete settings.json; unified mode was not activated.' }
        return [pscustomobject]@{ Ready = $true; AlreadyActive = $false; ProviderName = [string]$provider.Name }
    } finally {
        if ($provider -and $provider.Secret -is [IDisposable]) { $provider.Secret.Dispose() }
    }
}

function Enable-CcSwitchUnifiedMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $root = [IO.Path]::GetFullPath($StickRoot)
    $readiness = Test-CcSwitchUnifiedActivationReadiness -StickRoot $root
    if ($readiness.AlreadyActive) { return $true }
    $path = Get-ToolboxSettingsPath -StickRoot $root
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The toolbox config directory must exist before unified mode activation.' }
    Assert-ToolboxProviderPath -Path $parent
    $lockPath = $path + '.lock'
    Assert-ToolboxProviderPath -Path $lockPath
    $lock = $null
    $temp = $null
    $backup = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $lock -and (Get-Date) -lt $deadline) {
        try { $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if (-not $lock) { throw 'Unable to acquire settings.json write lock.' }
    try {
        $readiness = Test-CcSwitchUnifiedActivationReadiness -StickRoot $root
        if ($readiness.AlreadyActive) { return $true }
        Assert-ToolboxProviderPath -Path $path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'settings.json root must be a JSON object.' }
            $document = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'settings.json root must be a JSON object.' }
        } else { $document = [pscustomobject]@{} }
        $existing = $document.PSObject.Properties['ccSwitchUnifiedConfig']
        if ($existing -and $existing.Value -isnot [bool]) { throw 'settings.json ccSwitchUnifiedConfig must be a JSON boolean.' }
        if ($existing -and $existing.Value) {
            if (-not $document.ccSwitchClaudeProvider) { throw 'Unified configuration marker is inconsistent.' }
            return $true
        }
        $strays = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop | Where-Object { $_.Name -like 'settings.json.*.tmp' -or $_.Name -like 'settings.json.*.bak' })
        if ($strays.Count -gt 0) { throw 'Unfinished settings transaction files were found; inspect them before unified mode activation.' }
        $document | Add-Member -NotePropertyName ccSwitchUnifiedConfig -NotePropertyValue $true -Force
        $document | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $true -Force
        $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, ($document | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($false)))
        Assert-ToolboxProviderPath -Path $temp
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $backup = $path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
            Assert-ToolboxProviderPath -Path $backup
            [IO.File]::Move($path, $backup)
        }
        try {
            [IO.File]::Move($temp, $path)
            $temp = $null
            $verify = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $verify -or $verify.ccSwitchUnifiedConfig -isnot [bool] -or -not $verify.ccSwitchUnifiedConfig -or
                $verify.ccSwitchClaudeProvider -isnot [bool] -or -not $verify.ccSwitchClaudeProvider) { throw 'Unified mode transaction verification failed.' }
            if ($backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop; $backup = $null }
        } catch {
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf) -and -not (Test-Path -LiteralPath $path)) {
                Assert-ToolboxProviderPath -Path $backup
                Assert-ToolboxProviderPath -Path $path
                [IO.File]::Move($backup, $path)
                $backup = $null
            }
            throw
        }
        return $true
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        $lock.Dispose()
    }
}

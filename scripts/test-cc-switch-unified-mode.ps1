[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-unified-mode.ps1')

$script:root = Join-Path ([IO.Path]::GetTempPath()) ('cc-unified-mode-' + [guid]::NewGuid().ToString('N'))
$script:passed = 0
$script:failed = 0
$script:unlocked = $true
$script:providerAvailable = $true
$script:launchSettingsAvailable = $true
$script:bundleReadCount = 0

function Get-CcSecureSessionStatus([string]$StickRoot) {
    return [pscustomobject]@{ Unlocked = [bool]$script:unlocked }
}
function Get-CcSecureSessionClaudeLaunchBundle([string]$StickRoot) {
    $script:bundleReadCount++
    if (-not $script:providerAvailable) { throw 'Synthetic existing provider unavailable.' }
    $files = if ($script:launchSettingsAvailable) { @([pscustomobject]@{ Path='settings.json'; ContentBase64='e30=' }) } else { @() }
    return [pscustomobject]@{
        Revision = 'synthetic-revision'
        Provider = [pscustomobject]@{
            Name = 'synthetic-provider'
            BaseUrl = 'https://synthetic.invalid/v1'
            AuthEnvironmentName = 'ANTHROPIC_AUTH_TOKEN'
            Secret = ConvertTo-SecureString 'synthetic-secret-never-persisted' -AsPlainText -Force
        }
        LaunchFiles = $files
    }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Script, [string]$Message) {
    $failure = $null
    try { & $Script | Out-Null } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -notlike "*$Message*") { throw "Expected error containing '$Message'." }
}
function Invoke-Case([string]$Name, [scriptblock]$Script) {
    try { & $Script; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

try {
    [void][IO.Directory]::CreateDirectory((Join-Path $script:root 'config'))
    Write-Fixture (Join-Path $script:root 'harness\registry.json') '{"harnesses":[{"id":"claude","enabled":true}]}'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:root 'config\cc-switch\secure-store'))
    $settings = Join-Path $script:root 'config\settings.json'
    $script:bundleReadCount = 0

    Invoke-Case 'mode defaults off without creating settings' {
        Assert-True (-not (Get-CcSwitchUnifiedMode -StickRoot $script:root)) 'Unified mode should default to off.'
        Assert-True (-not (Test-Path -LiteralPath $settings)) 'Status read created settings.json.'
    }
    Invoke-Case 'activation readiness validates existing unlocked encrypted provider' {
        $ready = Test-CcSwitchUnifiedActivationReadiness -StickRoot $script:root
        Assert-True $ready.Ready 'Readiness did not pass.'
        Assert-True ($ready.ProviderName -eq 'synthetic-provider') 'Unexpected provider label.'
        Assert-True ($script:bundleReadCount -eq 1) 'Readiness did not retrieve the provider and settings bundle exactly once.'
    }
    Invoke-Case 'locked session fails closed without writing marker' {
        $script:unlocked = $false
        Assert-Throws { Enable-CcSwitchUnifiedMode -StickRoot $script:root } 'secure session is locked'
        Assert-True (-not (Test-Path -LiteralPath $settings)) 'Locked activation changed settings.json.'
        $script:unlocked = $true
    }
    Invoke-Case 'missing encrypted store fails without creating one or a password' {
        $empty = Join-Path $script:root 'no-store'
        [void][IO.Directory]::CreateDirectory((Join-Path $empty 'config'))
        Write-Fixture (Join-Path $empty 'harness\registry.json') '{"harnesses":[{"id":"claude","enabled":true}]}'
        Assert-Throws { Enable-CcSwitchUnifiedMode -StickRoot $empty } 'encrypted store is missing'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $empty 'config\cc-switch\secure-store'))) 'Activation created encrypted store.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $empty 'config\settings.json'))) 'Failed activation wrote settings.'
    }
    Invoke-Case 'only first enabled Claude harness can activate unified mode' {
        Write-Fixture (Join-Path $script:root 'harness\registry.json') '{"harnesses":[{"id":"fixture-other","enabled":true},{"id":"claude","enabled":true}]}'
        Assert-Throws { Enable-CcSwitchUnifiedMode -StickRoot $script:root } 'supports Claude Code as the first enabled harness'
        Assert-True (-not (Test-Path -LiteralPath $settings)) 'Unsupported harness activation changed settings.'
        Write-Fixture (Join-Path $script:root 'harness\registry.json') '{"harnesses":[{"id":"claude","enabled":true}]}'
    }
    Invoke-Case 'missing current provider fails without marker' {
        $script:providerAvailable = $false
        Assert-Throws { Enable-CcSwitchUnifiedMode -StickRoot $script:root } 'Synthetic existing provider unavailable'
        Assert-True (-not (Test-Path -LiteralPath $settings)) 'Unavailable provider changed settings.json.'
        $script:providerAvailable = $true
    }
    Invoke-Case 'missing or incomplete Claude settings blocks activation' {
        $script:launchSettingsAvailable = $false
        Assert-Throws { Enable-CcSwitchUnifiedMode -StickRoot $script:root } 'no complete settings.json'
        Assert-True (-not (Test-Path -LiteralPath $settings)) 'Incomplete settings changed settings.json.'
        $script:launchSettingsAvailable = $true
    }
    Invoke-Case 'activation atomically marks unified and CC provider while preserving fields' {
        Write-Fixture $settings '{"provider":"legacy-retained","lastWorkDir":"synthetic","ccSwitchClaudeProvider":false,"other":{"keep":9}}'
        Assert-True (Enable-CcSwitchUnifiedMode -StickRoot $script:root) 'Activation returned false.'
        $saved = [IO.File]::ReadAllText($settings, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-True ($saved.ccSwitchUnifiedConfig -is [bool] -and $saved.ccSwitchUnifiedConfig) 'Unified marker missing.'
        Assert-True ($saved.ccSwitchClaudeProvider -is [bool] -and $saved.ccSwitchClaudeProvider) 'CC provider marker missing.'
        Assert-True ($saved.provider -eq 'legacy-retained' -and $saved.other.keep -eq 9) 'Unrelated settings were lost.'
        Assert-True (Get-CcSwitchUnifiedMode -StickRoot $script:root) 'Unified status did not report active.'
    }
    Invoke-Case 'active mode is one-way and does not reread provider or rewrite marker' {
        $hash = (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
        $reads = $script:bundleReadCount
        $script:providerAvailable = $false
        Assert-True (Enable-CcSwitchUnifiedMode -StickRoot $script:root) 'Repeated activation failed.'
        Assert-True ((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -eq $hash) 'Repeated activation rewrote the marker.'
        Assert-True ($script:bundleReadCount -eq $reads) 'Already-active mode tried to switch provider.'
        $script:providerAvailable = $true
    }
    Invoke-Case 'malformed unified marker fails closed' {
        Write-Fixture $settings '{"ccSwitchUnifiedConfig":"true"}'
        Assert-Throws { Get-CcSwitchUnifiedMode -StickRoot $script:root } 'must be a JSON boolean'
    }
    Invoke-Case 'unified marker cannot be active while CC provider flag is off' {
        Write-Fixture $settings '{"ccSwitchUnifiedConfig":true,"ccSwitchClaudeProvider":false}'
        Assert-Throws { Get-CcSwitchUnifiedMode -StickRoot $script:root } 'requires ccSwitchClaudeProvider=true'
    }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + '\'
    $resolved = [IO.Path]::GetFullPath($script:root).TrimEnd('\', '/')
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'cc-unified-mode-*') {
        throw 'Refusing cleanup outside the GUID-scoped synthetic test root.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop }
}

Write-Host ("CC Switch unified mode tests: {0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }

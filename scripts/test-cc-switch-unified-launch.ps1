[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Assert-UnifiedLaunchTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$launchPath = Join-Path $PSScriptRoot 'launch.ps1'
$tokens = $null
$parseErrors = $null
$launchAst = [Management.Automation.Language.Parser]::ParseFile($launchPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Could not parse launch.ps1 for the synthetic unified-launch integration test.' }

$providersAssignment = $launchAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'providers'
}, $true) | Select-Object -First 1
$sourceBranch = $launchAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'if\s*\(\s*\$ccSwitchMode\s*\)'
}, $true) | Select-Object -First 1
if (-not $providersAssignment -or -not $sourceBranch) { throw 'The expected provider selection/launch branches were not found in launch.ps1.' }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixtureRoot = Join-Path $tempRoot ('aistick-unified-launch-' + [guid]::NewGuid().ToString('N'))
$script:UnifiedLaunchFallbackCalls = 0
$script:UnifiedLaunchBrokerLocked = $false

function global:Get-CcSwitchUnifiedMode { param([string]$StickRoot) return $true }
function global:Read-ProviderConfiguration { param([string]$Path) throw 'Legacy providers.json must not be opened in unified mode.' }
function global:Get-CcSecureSessionClaudeLaunchBundle {
    param([string]$StickRoot)
    if ($script:UnifiedLaunchBrokerLocked) { throw 'Synthetic secure broker is locked.' }
    $secret = ConvertTo-SecureString -String 'synthetic-only-token' -AsPlainText -Force
    return [pscustomobject]@{
        Revision = 'synthetic-revision'
        Provider = [pscustomobject]@{
            Name = 'Synthetic active provider'
            BaseUrl = 'https://provider.invalid/v1'
            AuthEnvironmentName = 'ANTHROPIC_AUTH_TOKEN'
            Secret = $secret
            Models = @{ ANTHROPIC_MODEL = 'synthetic-model'; ANTHROPIC_SMALL_FAST_MODEL = 'synthetic-small' }
        }
        LaunchFiles = @(
            [pscustomobject]@{ Path = '.claude/settings.json'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"env":{"ANTHROPIC_MODEL":"synthetic-model"}}')) },
            [pscustomobject]@{ Path = 'CLAUDE.md'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic full settings bundle')) },
            [pscustomobject]@{ Path = 'skills/fixture/SKILL.md'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic skill')) }
        )
    }
}
function global:Test-ToolboxCcEncryptedStorePresent { param([string]$StickRoot) return $true }
function global:Get-ToolboxCcSwitchClaudeProvider {
    param([string]$StickRoot)
    $script:UnifiedLaunchFallbackCalls++
    throw 'Legacy CC Switch settings fallback must not be used in unified mode.'
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'harness')) | Out-Null
    # Deliberately leave harness/providers.json absent. Execute the real source
    # selection expression copied from launch.ps1, with its unified-mode predicate stubbed.
    $script:StickRoot = $fixtureRoot
    $script:unifiedMode = $true
    $script:ProvidersPath = Join-Path $fixtureRoot 'harness\providers.json'
    Assert-UnifiedLaunchTest (-not (Test-Path -LiteralPath $script:ProvidersPath)) 'Fixture unexpectedly contains legacy providers.json.'
    Invoke-Expression $providersAssignment.Extent.Text
    Assert-UnifiedLaunchTest ($script:providers.default -eq 'cc-switch-current' -and $script:providers.providers.Count -eq 0) 'Unified mode did not select the empty CC Switch provider source.'
    Assert-UnifiedLaunchTest ($script:UnifiedLaunchFallbackCalls -eq 0) 'The no-providers.json selection attempted a legacy provider read.'

    # Run the actual launch.ps1 provider-resolution branch. The one dot-source
    # line is omitted so the fixture can substitute a controlled broker response.
    $launchSource = $sourceBranch.Extent.Text
    $launchSource = [regex]::Replace($launchSource, '(?m)^\s*\. \(Join-Path \$PSScriptRoot ''cc-switch-secure-session\.ps1''\) -StickRoot \$StickRoot\s*$', '')
    $script:unifiedMode = $true
    $script:ccSwitchMode = $true
    $script:h = [pscustomobject]@{ id = 'claude'; providerEnv = [pscustomobject]@{ baseUrl = 'ANTHROPIC_BASE_URL'; apiKey = 'ANTHROPIC_AUTH_TOKEN' } }
    $script:ccLaunchFiles = $null
    $script:keyVal = $null
    $script:ccProfile = $null
    $script:prov = $null
    $script:UnifiedLaunchBrokerLocked = $false
    Invoke-Expression $launchSource
    Assert-UnifiedLaunchTest ($script:prov.baseUrl -eq 'https://provider.invalid/v1' -and $script:prov.apikeyEnv -eq 'ANTHROPIC_AUTH_TOKEN') 'The launcher did not use the bundled active provider.'
    Assert-UnifiedLaunchTest ($script:keyVal -eq 'synthetic-only-token') 'The launcher did not receive the synthetic broker credential.'
    Assert-UnifiedLaunchTest ($script:ccLaunchFiles.Count -eq 3 -and $script:ccLaunchFiles[2].Path -eq 'skills/fixture/SKILL.md') 'The launcher did not retain the full synthetic launch-file bundle.'
    Assert-UnifiedLaunchTest ($script:UnifiedLaunchFallbackCalls -eq 0) 'The unlocked unified branch consulted the legacy provider fallback.'
    $script:keyVal = $null
    $script:ccLaunchFiles = $null

    $script:UnifiedLaunchBrokerLocked = $true
    $lockedFailed = $false
    try { Invoke-Expression $launchSource } catch { $lockedFailed = $true }
    Assert-UnifiedLaunchTest $lockedFailed 'A locked broker unexpectedly allowed unified launch configuration to continue.'
    Assert-UnifiedLaunchTest ($script:UnifiedLaunchFallbackCalls -eq 0) 'A locked unified broker fell back to toolbox providers or old settings.'
    Write-Output 'PASS: synthetic launcher selects CC Switch without providers.json, uses the broker bundle, and fails closed when locked.'
} finally {
    Remove-Item Function:\global:Get-CcSwitchUnifiedMode -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Read-ProviderConfiguration -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-CcSecureSessionClaudeLaunchBundle -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Test-ToolboxCcEncryptedStorePresent -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-ToolboxCcSwitchClaudeProvider -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $full = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\','/')
        if ((Split-Path -Parent $full).TrimEnd('\','/') -cne $tempRoot -or (Split-Path -Leaf $full) -notmatch '^aistick-unified-launch-[0-9a-f]{32}$') { throw 'Refusing to clean an unexpected unified-launch fixture path.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Assert-LaunchRace {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$launchPath = Join-Path $PSScriptRoot 'launch.ps1'
$parseTokens = $null
$parseErrors = $null
$launchAst = [Management.Automation.Language.Parser]::ParseFile($launchPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Could not parse launch.ps1 for the dynamic Save-UserSettings regression.' }
foreach ($functionName in @('Save-UserSettings','Show-ProviderSwitcher')) {
    $definition = $launchAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true) | Select-Object -First 1
    if (-not $definition) { throw "The launch function $functionName was not found." }
    Invoke-Expression $definition.Extent.Text
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixtureRoot = Join-Path $tempRoot ('aistick-launch-race-' + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $fixtureRoot 'config'
$script:SettingsPath = Join-Path $configDir 'settings.json'
$script:StickRoot = $fixtureRoot
$script:UnifiedRaceReadCount = 0
$script:RaceFilePath = $script:SettingsPath
$script:RaceFixtureRoot = $fixtureRoot

try {
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    $script:settingsBaseline = [pscustomobject]@{
        provider = 'legacy-provider'
        ccSwitchClaudeProvider = $true
        ccSwitchUnifiedConfig = $false
        lastWorkDir = 'old-workspace'
    }
    $script:userSettings = [pscustomobject]@{
        provider = 'legacy-provider'
        ccSwitchClaudeProvider = $true
        ccSwitchUnifiedConfig = $false
        lastWorkDir = 'new-workspace'
    }
    $script:providers = [pscustomobject]@{ providers = @([pscustomobject]@{ id = 'legacy-provider'; name = 'Old provider'; enabled = $true }) }

    function global:Get-CcSwitchUnifiedMode {
        param([string]$StickRoot)
        $script:UnifiedRaceReadCount++
        return ($script:UnifiedRaceReadCount -gt 1)
    }
    function global:Read-Host {
        param([string]$Prompt)
        # Simulate another process activating unified mode after the old window
        # passed Show-ProviderSwitcher's guard but before its selection is saved.
        [IO.File]::WriteAllText($script:RaceFilePath, '{"provider":"cc-switch-current","ccSwitchClaudeProvider":true,"ccSwitchUnifiedConfig":true,"lastWorkDir":"disk-workspace","sentinel":{"retain":7}}', (New-Object Text.UTF8Encoding($false)))
        return '1'
    }

    Show-ProviderSwitcher

    $saved = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    Assert-LaunchRace ($script:UnifiedRaceReadCount -ge 2) 'The fixture did not exercise both the stale UI guard and the locked save-time recheck.'
    Assert-LaunchRace ($saved.ccSwitchUnifiedConfig -is [bool] -and $saved.ccSwitchUnifiedConfig) 'The active unified marker was overwritten.'
    Assert-LaunchRace ($saved.ccSwitchClaudeProvider -is [bool] -and $saved.ccSwitchClaudeProvider) 'The active CC Switch provider flag was overwritten.'
    Assert-LaunchRace ($saved.provider -eq 'cc-switch-current') 'A stale legacy provider selection replaced the active provider marker.'
    Assert-LaunchRace ($saved.sentinel.retain -eq 7) 'An unrelated settings field was lost.'
    Assert-LaunchRace ($script:userSettings.ccSwitchClaudeProvider -and $script:userSettings.ccSwitchUnifiedConfig) 'The old window did not synchronize its in-memory source flags.'
    Write-Output 'PASS: dynamic stale-window race preserves active unified mode and CC Switch provider source.'
} finally {
    Remove-Item Function:\global:Get-CcSwitchUnifiedMode -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $full = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\','/')
        if ((Split-Path -Parent $full).TrimEnd('\','/') -cne $tempRoot -or (Split-Path -Leaf $full) -notmatch '^aistick-launch-race-[0-9a-f]{32}$') { throw 'Refusing to clean an unexpected launch-race fixture path.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-provider.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-menu.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cc-provider-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$failed = 0
$script:menuChoices = @()
$script:menuChoiceIndex = 0

function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { throw 'Menu test unexpectedly requested a password.' }
    if ($script:menuChoiceIndex -ge $script:menuChoices.Count) { return '0' }
    $value = $script:menuChoices[$script:menuChoiceIndex]
    $script:menuChoiceIndex++
    return $value
}
function Invoke-MenuChoices([string[]]$Choices) {
    $script:menuChoices = $Choices
    $script:menuChoiceIndex = 0
    return @(Show-ToolboxCcSwitchMenu -StickRoot $testRoot 6>&1 | Out-String) -join ''
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
function Write-Json([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $settingsPath = Join-Path $testRoot 'config\settings.json'
    $ccSettings = Join-Path $testRoot 'harness\cc-switch\claude\settings.json'

    Invoke-Case 'drive-root path planning preserves the root without accessing it' {
        $planned = Get-ToolboxSettingsPath -StickRoot 'E:\'
        Assert-True ($planned -eq 'E:\config\settings.json') 'Drive-root derivation changed unexpectedly.'
    }

    Invoke-Case 'mode defaults off without creating settings' {
        Assert-True (-not (Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot)) 'Mode should default to off.'
        Assert-True (-not (Test-Path -LiteralPath $settingsPath)) 'Get must not create settings.'
    }
    Invoke-Case 'mode writes and preserves unrelated settings' {
        Write-Json $settingsPath '{"provider":"ordinary","lastWorkDir":"C:\\synthetic-project","unrelated":{"keep":7}}'
        Set-ToolboxCcSwitchClaudeMode -StickRoot $testRoot -Enabled $true
        $saved = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        Assert-True ($saved.ccSwitchClaudeProvider -eq $true) 'Mode flag was not persisted.'
        Assert-True ($saved.provider -eq 'ordinary' -and $saved.unrelated.keep -eq 7) 'Other settings were lost.'
        Set-ToolboxCcSwitchClaudeMode -StickRoot $testRoot -Enabled $false
        Assert-True (-not (Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot)) 'Mode did not switch off.'
    }
    Invoke-Case 'setter rejects absent config parent without writing' {
        $absentRoot = Join-Path $testRoot 'missing-parent'
        [void][IO.Directory]::CreateDirectory($absentRoot)
        Assert-Throws { Set-ToolboxCcSwitchClaudeMode -StickRoot $absentRoot -Enabled $true } 'config directory must exist'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $absentRoot 'config'))) 'Setter created a missing parent.'
    }
    Invoke-Case 'mode field must be a JSON boolean' {
        Write-Json $settingsPath '{"ccSwitchClaudeProvider":"true"}'
        Assert-Throws { Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot } 'must be a JSON boolean'
    }
    Invoke-Case 'malformed mode settings fail under Continue without changing caller preference' {
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Assert-Throws { Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot } 'must be a JSON boolean'
            Assert-True ($ErrorActionPreference -eq 'Continue') 'The module changed caller ErrorActionPreference.'
        } finally { $ErrorActionPreference = $oldPreference }
    }
    Invoke-Case 'reads current profile only from the fixed USB path and keeps secret secure' {
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1/","ANTHROPIC_AUTH_TOKEN":"synthetic-secret-token","ANTHROPIC_MODEL":"synthetic-model","OTHER_SECRET":"do-not-return"},"permissions":{"allow":["Bash(*)"]}}'
        $profile = Get-ToolboxCcSwitchClaudeProvider -StickRoot $testRoot
        try {
            Assert-True ($profile.BaseUrl -eq 'https://provider.example/v1') 'Base URL mismatch.'
            Assert-True ($profile.Secret -is [Security.SecureString]) 'Credential must remain secure until launcher injection.'
            Assert-True ($profile.AuthEnvironmentName -eq 'ANTHROPIC_AUTH_TOKEN') 'The original credential variable was lost.'
            Assert-True ($profile.Models['ANTHROPIC_MODEL'] -eq 'synthetic-model') 'Model was not allowlisted.'
            Assert-True (-not ($profile | ConvertTo-Json -Depth 5).Contains('synthetic-secret-token')) 'Secret leaked from returned profile.'
            Assert-True (-not ($profile | ConvertTo-Json -Depth 5).Contains('do-not-return')) 'Unexpected field was returned.'
        } finally { if ($profile.Secret) { $profile.Secret.Dispose() } }
    }
    Invoke-Case 'API key field retains its original environment name' {
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1","ANTHROPIC_API_KEY":"synthetic-api-key"}}'
        $profile = Get-ToolboxCcSwitchClaudeProvider -StickRoot $testRoot
        try { Assert-True ($profile.AuthEnvironmentName -eq 'ANTHROPIC_API_KEY') 'API key was mapped to the wrong variable.' }
        finally { if ($profile.Secret) { $profile.Secret.Dispose() } }
    }
    Invoke-Case 'missing fixed profile fails closed' {
        Remove-Item -LiteralPath $ccSettings -Force
        Assert-Throws { Get-ToolboxCcSwitchClaudeProvider -StickRoot $testRoot } 'settings.json is missing'
    }
    Invoke-Case 'invalid local proxy placeholder fails closed' {
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1","ANTHROPIC_AUTH_TOKEN":"PROXY_MANAGED"}}'
        Assert-Throws { Get-ToolboxCcSwitchClaudeProvider -StickRoot $testRoot } 'proxy placeholders'
    }
    Invoke-Case 'menu 4 enables only a validated profile and never prints credential' {
        Write-Json $settingsPath '{"provider":"ordinary","ccSwitchClaudeProvider":false}'
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1","ANTHROPIC_AUTH_TOKEN":"menu-synthetic-secret"}}'
        $output = Invoke-MenuChoices @('4', '0')
        Assert-True (Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot) 'Menu 4 did not persist enabled mode.'
        Assert-True (-not $output.Contains('menu-synthetic-secret')) 'Menu output disclosed the credential.'
    }
    Invoke-Case 'menu 5 disables CC Switch override' {
        $null = Invoke-MenuChoices @('5', '0')
        Assert-True (-not (Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot)) 'Menu 5 did not turn mode off.'
    }
    Invoke-Case 'menu 4 invalid profile leaves mode disabled' {
        Write-Json $settingsPath '{"provider":"ordinary","ccSwitchClaudeProvider":false}'
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1","ANTHROPIC_AUTH_TOKEN":"PROXY_MANAGED"}}'
        $null = Invoke-MenuChoices @('4', '0')
        Assert-True (-not (Get-ToolboxCcSwitchClaudeMode -StickRoot $testRoot)) 'Invalid profile enabled mode.'
    }
    Invoke-Case 'partial encrypted store blocks a valid plaintext provider fallback' {
        Write-Json $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider.example/v1","ANTHROPIC_AUTH_TOKEN":"synthetic-legacy-secret"}}'
        $secureRoot = Join-Path $testRoot 'config\cc-switch\secure-store'
        [void][IO.Directory]::CreateDirectory($secureRoot)
        Assert-Throws { Get-ToolboxCcSwitchClaudeProvider -StickRoot $testRoot } 'plaintext fallback is disabled'
        [IO.Directory]::Delete($secureRoot, $false)
    }
    Invoke-Case 'setter refuses to proceed with dangling transaction artifacts' {
        $stray = $settingsPath + '.interrupted.tmp'
        Write-Json $stray '{"partial":true}'
        Assert-Throws { Set-ToolboxCcSwitchClaudeMode -StickRoot $testRoot -Enabled $true } 'Unfinished settings transaction'
        Assert-True (Test-Path -LiteralPath $stray) 'The module unexpectedly removed an unknown temp file.'
        Remove-Item -LiteralPath $stray -Force
    }
    Invoke-Case 'reparse path is rejected' {
        $link = Join-Path $testRoot 'harness\cc-switch\claude-link'
        try {
            New-Item -ItemType Junction -Path $link -Target (Split-Path -Parent $ccSettings) -ErrorAction Stop | Out-Null
            $linkedRoot = Join-Path $testRoot 'linked-root'
            [void][IO.Directory]::CreateDirectory((Join-Path $linkedRoot 'harness\cc-switch'))
            New-Item -ItemType Junction -Path (Join-Path $linkedRoot 'harness\cc-switch\claude') -Target (Split-Path -Parent $ccSettings) -ErrorAction Stop | Out-Null
            Assert-Throws { Get-ToolboxCcSwitchClaudeProvider -StickRoot $linkedRoot } 'reparse point'
        } catch [System.UnauthorizedAccessException] { Write-Host 'SKIP reparse path test: junction creation unavailable.' -ForegroundColor Yellow }
    }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\', '/')
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'cc-provider-test-*') {
        throw 'Refusing to clean a test path outside the GUID-scoped test root.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop }
}
Write-Host ("CC Switch provider tests: {0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }

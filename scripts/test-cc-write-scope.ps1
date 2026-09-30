# Synthetic USB/host roots only. Never launches CC Switch or any AI harness.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-menu.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('cc-scope-' + [guid]::NewGuid().ToString('N'))
$stick = Join-Path $root 'usb'
$hostFixture = Join-Path $root 'host'
$link = $null
$password = ConvertTo-SecureString 'synthetic-scope-password' -AsPlainText -Force
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0
function Assert-Scope([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++; Write-Host "PASS $Message" -ForegroundColor Green
}
try {
    foreach ($path in @('usb\config', 'usb\harness', 'host\.claude', 'host\.codex', 'host\harness', 'escaped-usb')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $path))
    }
    $sentinels = @('host\.claude\settings.json', 'host\.codex\config.toml', 'host\harness\providers.json')
    $hashes = @{}
    foreach ($relative in $sentinels) {
        $path = Join-Path $root $relative
        [IO.File]::WriteAllText($path, 'synthetic-host-configuration-do-not-touch', $utf8)
        $hashes[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $hostFilesBefore = @(Get-ChildItem -LiteralPath $hostFixture -Recurse -File).Count
    $provider = Join-Path $stick 'harness\providers.json'
    [IO.File]::WriteAllText($provider, '{"default":"fixture","providers":[]}', $utf8)
    $vaultPath = Join-Path $stick 'config\credentials.vault.json'
    $null = Write-PortableVault -Path $vaultPath -Password $password -Secrets @{ FIXTURE = 'synthetic-only' } -ExpectedRevision $null
    $profilePath = Join-Path $stick 'selected-settings.json'
    $document = @{
        env = @{
            ANTHROPIC_BASE_URL = 'https://example.invalid'; ANTHROPIC_API_KEY = 'synthetic-import-only'
            ANTHROPIC_MODEL = 'fixture-model'; CLAUDE_CONFIG_DIR = (Join-Path $hostFixture '.claude')
            CODEX_HOME = (Join-Path $hostFixture '.codex')
        }
        claudeConfigDir = (Join-Path $hostFixture '.claude')
        hooks = @{ injected = 'never execute' }
    }
    [IO.File]::WriteAllText($profilePath, ($document | ConvertTo-Json -Depth 5), $utf8)
    $imported = Import-ToolboxCcSwitchProvider -StickRoot $stick -ProfilePath $profilePath -Name 'USB only' -Password $password
    $parsed = [IO.File]::ReadAllText($provider) | ConvertFrom-Json
    Assert-Scope ($parsed.providers.Count -eq 1 -and $parsed.providers[0].id -eq $imported.Id) 'selected provider is written to the synthetic USB harness'
    $providerText = [IO.File]::ReadAllText($provider)
    Assert-Scope (-not $providerText.Contains('CLAUDE_CONFIG_DIR') -and -not $providerText.Contains('CODEX_HOME') -and -not $providerText.Contains('hooks') -and -not $providerText.Contains('claudeConfigDir')) 'imported host path overrides and hooks are discarded'
    Assert-Scope (-not $providerText.Contains('synthetic-import-only') -and -not [IO.File]::ReadAllText($vaultPath).Contains('synthetic-import-only')) 'imported credential remains encrypted on USB'

    $escaped = Join-Path $root 'escaped-usb'
    $link = Join-Path $escaped 'harness'
    New-Item -ItemType Junction -Path $link -Target (Join-Path $hostFixture 'harness') | Out-Null
    $denied = $false
    try { $null = Import-ToolboxCcSwitchProvider -StickRoot $escaped -ProfilePath $profilePath -Name 'Escape rejected' -Password $password }
    catch { $denied = $true }
    Assert-Scope $denied 'USB harness path cannot redirect writes into a host directory'
    Assert-Scope (-not (Test-Path -LiteralPath (Join-Path $escaped 'config\credentials.vault.json'))) 'rejected destination performs no credential commit'
    foreach ($relative in $sentinels) {
        Assert-Scope ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash -eq $hashes[$relative]) "host sentinel unchanged: $relative"
    }
    Assert-Scope (@(Get-ChildItem -LiteralPath $hostFixture -Recurse -File).Count -eq $hostFilesBefore) 'no new host configuration files were created'
} finally {
    $password.Dispose()
    $full = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $full) -notmatch '^cc-scope-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    if ($link -and [IO.Directory]::Exists($link)) {
        if ([IO.Path]::GetFullPath($link) -ne (Join-Path $full 'escaped-usb\harness')) { throw 'Unsafe junction cleanup path.' }
        [IO.Directory]::Delete($link)
    }
    if (Test-Path -LiteralPath $full) {
        $links = @(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count -gt 0) { throw 'Refusing recursive cleanup through a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Host "CC write scope: $passed passed. Synthetic fixtures only."

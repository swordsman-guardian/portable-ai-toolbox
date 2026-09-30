# Only synthetic keys and passwords. No production configuration is opened.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'vault-menu.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-menu.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('ai-vault-int-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'config'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'harness'))
$keys = Join-Path $root 'config\keys.env'
$vault = Join-Path $root 'config\credentials.vault.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$password = ConvertTo-SecureString 'synthetic-test-password-only' -AsPlainText -Force
$wrong = ConvertTo-SecureString 'wrong-synthetic-password-only' -AsPlainText -Force
$secret = 'synthetic-original-value-only'
$passed = 0
function Check([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "Integration failed: $Label" }
    $script:passed++; Write-Host "PASS $Label" -ForegroundColor Green
}
try {
    [IO.File]::WriteAllText($keys, "FIXTURE_KEY=$secret", $utf8)
    Check ((Get-ProviderSecret -KeysFile $keys -Name FIXTURE_KEY) -eq $secret) 'legacy reading before initialization'
    $migration = Initialize-ToolboxVault -StickRoot $root -Password $password
    Check ($migration.Count -eq 1 -and -not (Test-Path -LiteralPath $keys)) 'migration removes plaintext only after verified readback'
    Check ((Get-ProviderSecret -KeysFile $keys -Name FIXTURE_KEY -VaultPassword $password) -eq $secret) 'launcher secret reader uses encrypted vault'
    Check (-not [IO.File]::ReadAllText($vault).Contains($secret)) 'encrypted file contains no literal secret'
    [IO.File]::WriteAllText($keys, 'FIXTURE_KEY=forbidden-plaintext-fallback', $utf8)
    $denied = $false
    try { $null = Get-ProviderSecret -KeysFile $keys -Name FIXTURE_KEY -VaultPassword $wrong } catch { $denied = $true }
    Check $denied 'wrong password never uses legacy fallback'
    $denied = $false
    try { $null = Get-ProviderSecret -KeysFile $keys -Name FIXTURE_KEY } catch { $denied = $true }
    Check $denied 'locked vault requires an explicit password'
    $providerFile = Join-Path $root 'harness\providers.json'
    [IO.File]::WriteAllText($providerFile, '{"default":"fixture","providers":[]}', $utf8)
    $profileFile = Join-Path $root 'source-profile.json'
    $importSecret = 'synthetic-import-value-only'
    [IO.File]::WriteAllText($profileFile, ('{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid","ANTHROPIC_AUTH_TOKEN":"' + $importSecret + '","ANTHROPIC_MODEL":"fixture-model"},"hooks":{"ignored":"never executed"}}'), $utf8)
    $import = Import-ToolboxCcSwitchProvider -StickRoot $root -ProfilePath $profileFile -Name 'Synthetic import' -Password $password
    $metadataText = [IO.File]::ReadAllText($providerFile)
    $metadata = $metadataText | ConvertFrom-Json
    Check ($metadata.providers.Count -eq 1 -and $metadata.providers[0].id -eq $import.Id) 'provider metadata is registered'
    Check (-not $metadataText.Contains($importSecret) -and -not $metadataText.Contains('hooks')) 'metadata excludes raw credential and unrelated settings'
    Check ((Get-ProviderSecret -KeysFile $keys -Name $import.KeyReference -VaultPassword $password) -eq $importSecret) 'imported credential is read through vault'
    $before = (Get-FileHash -LiteralPath $providerFile -Algorithm SHA256).Hash
    $denied = $false
    try { $null = Import-ToolboxCcSwitchProvider -StickRoot $root -ProfilePath $profileFile -Name 'Wrong password import' -Password $wrong } catch { $denied = $true }
    Check ($denied -and (Get-FileHash -LiteralPath $providerFile -Algorithm SHA256).Hash -eq $before) 'failed import leaves provider metadata untouched'
    [IO.File]::Move($vault, ($vault + '.tmp'))
    $denied = $false
    try { $null = Get-ProviderSecret -KeysFile $keys -Name FIXTURE_KEY -VaultPassword $password } catch { $denied = $true }
    Check $denied 'interrupted vault with no primary never falls back to plaintext'
    $null = Restore-PortableVault -Path $vault -Password $password -Source Backup
    $restored = Read-PortableVault -Path $vault -Password $password
    try { $null = Write-PortableVault -Path $vault -Password $password -Secrets $restored.Secrets -ExpectedRevision $restored.Revision }
    finally { $restored.Secrets.Clear() }
    Check (-not (Test-Path -LiteralPath ($vault + '.tmp'))) 'backup recovery preserves pending data under another name and allows future writes'
    $recoveryOnly = Join-Path $root 'recovery-only'
    [void][IO.Directory]::CreateDirectory($recoveryOnly)
    $recoveryKeys = Join-Path $recoveryOnly 'keys.env'
    [IO.File]::WriteAllText($recoveryKeys, 'FIXTURE_KEY=forbidden-fallback', $utf8)
    [IO.File]::WriteAllText((Join-Path $recoveryOnly 'credentials.vault.json.restore.tmp'), '{}', $utf8)
    $denied = $false
    try { $null = Get-ProviderSecret -KeysFile $recoveryKeys -Name FIXTURE_KEY -VaultPassword $password } catch { $denied = $true }
    Check $denied 'restore staging marker alone blocks plaintext fallback'
    Write-Host "Vault integration: $passed passed. Synthetic evidence: $root"
} finally { $password.Dispose(); $wrong.Dispose() }

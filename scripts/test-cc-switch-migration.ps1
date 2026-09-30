[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-migration.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('cc-migration-test-' + [guid]::NewGuid().ToString('N'))
$session = $null
$password = ConvertTo-SecureString 'Synthetic migration password 2026!' -AsPlainText -Force
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Write-Fake([string]$Root,[string]$Tag) {
    $cc = Join-Path $Root 'config\cc-switch\home\.cc-switch'
    $claude = Join-Path $Root 'harness\cc-switch\claude'
    [void][IO.Directory]::CreateDirectory($cc)
    [void][IO.Directory]::CreateDirectory($claude)
    [IO.File]::WriteAllText((Join-Path $cc 'cc-switch.db'),('synthetic-db-' + $Tag))
    [IO.File]::WriteAllText((Join-Path $claude 'settings.json'),('{"env":{"ANTHROPIC_BASE_URL":"https://migration.invalid","ANTHROPIC_AUTH_TOKEN":"synthetic-' + $Tag + '"}}'))
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $usb = Join-Path $work 'usb'
    [void][IO.Directory]::CreateDirectory($usb)
    $source = Join-Path $work 'source'
    Write-Fake $source 'previous'
    $null = Save-CcSwitchStoreSnapshot -StickRoot $usb -SourceRoot $source -StoppedOnly
    Write-Fake $source 'current'
    $null = Save-CcSwitchStoreSnapshot -StickRoot $usb -SourceRoot $source -StoppedOnly
    $session = Open-CcEncryptedStoreSession -StickRoot $usb -Password $password -Create
    $result = Initialize-CcEncryptedStoreFromLegacy -StickRoot $usb -Session $session
    Assert ($result.Status -eq 'Migrated' -and $result.EncryptedRevisions -eq 2) 'Both legacy revisions must migrate.'
    Assert (@(Get-CcLegacyMigrationFiles -StickRoot $usb).Count -eq 0) 'Legacy plaintext remains.'
    $restored = Join-Path $work 'restored'
    $null = Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $restored -StoppedOnly
    Assert ([IO.File]::ReadAllText((Join-Path $restored 'config\cc-switch\home\.cc-switch\cc-switch.db')) -eq 'synthetic-db-current') 'Current revision mismatch.'
    $previous = Join-Path $work 'previous'
    $null = Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $previous -StoppedOnly -Previous
    Assert ([IO.File]::ReadAllText((Join-Path $previous 'config\cc-switch\home\.cc-switch\cc-switch.db')) -eq 'synthetic-db-previous') 'Previous revision mismatch.'
    Assert ((Initialize-CcEncryptedStoreFromLegacy -StickRoot $usb -Session $session).Status -eq 'NotNeeded') 'Repeated migration should be a no-op.'
    Write-Host 'PASS two-revision migration, plaintext cleanup, restore and repeat'
    Close-CcEncryptedStoreSession -Session $session
    $session = $null

    $usb = Join-Path $work 'conflict'
    [void][IO.Directory]::CreateDirectory($usb)
    $null = Save-CcSwitchStoreSnapshot -StickRoot $usb -SourceRoot $source -StoppedOnly
    $export = Join-Path $usb 'harness\cc-switch\claude\settings.json'
    [IO.File]::WriteAllText($export,'{"env":{"ANTHROPIC_AUTH_TOKEN":"synthetic-conflict"}}')
    $session = Open-CcEncryptedStoreSession -StickRoot $usb -Password $password -Create
    $rejected = $false
    try { $null = Initialize-CcEncryptedStoreFromLegacy -StickRoot $usb -Session $session } catch { $rejected = $true }
    Assert $rejected 'Conflicting legacy export accepted.'
    Assert ([IO.File]::ReadAllText($export).Contains('synthetic-conflict')) 'Conflict deleted original.'
    Assert (-not (Get-CcEncryptedStoreStatus -StickRoot $usb).CurrentRevision) 'Conflict published a partial migration.'
    $marker = Join-Path $usb 'config\cc-switch\secure-store\migration.pending.json'
    [IO.File]::WriteAllText($marker,'{"version":1,"state":"MigrationInProgress"}')
    $rejected = $false
    try { $null = Initialize-CcEncryptedStoreFromLegacy -StickRoot $usb -Session $session } catch { $rejected = $true }
    Assert $rejected 'Interrupted migration silently resumed.'
    Write-Host 'PASS conflict preserves originals and interrupted migration blocks launch'
    Close-CcEncryptedStoreSession -Session $session
    $session = $null

    $usb = Join-Path $work 'unrepresented-backup'
    Write-Fake $usb 'standalone'
    $backup = Join-Path $usb 'config\cc-switch\home\.cc-switch\old.backup'
    [IO.File]::WriteAllText($backup,'synthetic-important-backup')
    $session = Open-CcEncryptedStoreSession -StickRoot $usb -Password $password -Create
    $rejected = $false
    try { $null = Initialize-CcEncryptedStoreFromLegacy -StickRoot $usb -Session $session } catch { $rejected = $true }
    Assert $rejected 'Unrepresented backup was silently discarded.'
    Assert ([IO.File]::ReadAllText($backup) -eq 'synthetic-important-backup') 'Backup was not preserved.'
    Assert (-not (Get-CcEncryptedStoreStatus -StickRoot $usb).CurrentRevision) 'Unrepresented data published a migration.'
    Write-Host 'PASS unrepresented legacy backup blocks migration without deleting data'
} finally {
    if ($session) { Close-CcEncryptedStoreSession -Session $session }
    $password.Dispose()
    $full = [IO.Path]::GetFullPath($work)
    if ((Split-Path -Parent $full) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $full) -notmatch '^cc-migration-test-[0-9a-f]{32}$') { throw 'Unexpected test cleanup path.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

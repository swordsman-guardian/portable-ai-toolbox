# Synthetic-only regression tests for cc-switch-encrypted-store.ps1.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('ccenc-test-'+[guid]::NewGuid().ToString('N'))
$usb=Join-Path $work 'usb';$src=Join-Path $work 'source';$dest=Join-Path $work 'restore';$prevDest=Join-Path $work 'restore-previous';$failed=0
$session=$null;$staleSession=$null;$recoverySession=$null
function Assert([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}
function New-FakeSource([string]$Root,[string]$Token){$null=New-Item -ItemType Directory -Force -Path (Join-Path $Root 'config\cc-switch\home\.cc-switch');$null=New-Item -ItemType Directory -Force -Path (Join-Path $Root 'harness\cc-switch\claude');[IO.File]::WriteAllText((Join-Path $Root 'config\cc-switch\home\.cc-switch\db.json'),('{"api_key":"'+$Token+'"}'),(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText((Join-Path $Root 'harness\cc-switch\claude\settings.json'),('{"name":"synthetic","env":{"ANTHROPIC_BASE_URL":"https://example.invalid","ANTHROPIC_AUTH_TOKEN":"'+$Token+'","ANTHROPIC_MODEL":"synthetic-model"}}'),(New-Object Text.UTF8Encoding($false)));$blob=New-Object byte[] (2MB);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($blob);[IO.File]::WriteAllBytes((Join-Path $Root 'config\cc-switch\home\.cc-switch\synthetic-large.bin'),$blob)}finally{$rng.Dispose();[Array]::Clear($blob,0,$blob.Length)}}
try{
    $null=New-Item -ItemType Directory -Path $work
    New-FakeSource $src 'SYNTHETIC-CREDENTIAL-ALPHA-19b27f'
    $password=ConvertTo-SecureString 'Test only passphrase 01!' -AsPlainText -Force
    $session=Open-CcEncryptedStoreSession -StickRoot $usb -Password $password -Create
    $a=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly
    Assert ($a.Files -eq 3) 'first snapshot file count including multi-megabyte fixture'
    $probe=New-Object byte[] (2MB);$probeRng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$probeRng.GetBytes($probe);$probeCipher=Protect-CcEncBytes $probe $session.DataKey;Assert ($probeCipher -is [byte[]]) 'multi-megabyte encryption result must be byte[]';$probePlain=Unprotect-CcEncBytes $probeCipher $session.DataKey;Assert ($probePlain.Length -eq $probe.Length) 'multi-megabyte crypto roundtrip'}finally{$probeRng.Dispose();[Array]::Clear($probe,0,$probe.Length);if($probePlain){[Array]::Clear($probePlain,0,$probePlain.Length)}}
    $recoveryRoot=Join-Path $work 'recovery-package'
    $beforeRecoveryRevision=$session.Revision
    $detachedUsb=Join-Path $work 'usb-detached'
    [IO.Directory]::Move($usb,$detachedUsb)
    try {$recovery=Save-CcEncryptedRecoverySnapshot -Session $session -SourceRoot $src -DestinationRoot $recoveryRoot -StoppedOnly}
    finally {[IO.Directory]::Move($detachedUsb,$usb)}
    Assert ($session.Revision -eq $beforeRecoveryRevision) 'recovery save changed USB session revision'
    $recoveryGen=Join-Path $recoveryRoot ('config\cc-switch\secure-store\generations\'+$recovery.Revision+'.bin')
    $recoveryText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($recoveryGen))
    Assert (-not $recoveryText.Contains('SYNTHETIC-CREDENTIAL-ALPHA-19b27f')) 'recovery package contains plaintext secret'
    $recoverySession=Open-CcEncryptedStoreSession -StickRoot $recoveryRoot -Password $password
    $recoveryRestore=Join-Path $work 'recovery-restore'
    $null=Restore-CcEncryptedSnapshot -Session $recoverySession -DestinationRoot $recoveryRestore -StoppedOnly
    Assert ([IO.File]::ReadAllText((Join-Path $recoveryRestore 'harness\cc-switch\claude\settings.json')).Contains('ALPHA-19b27f')) 'recovery package could not independently restore'
    Close-CcEncryptedStoreSession $recoverySession
    $usbText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $usb ('config\cc-switch\secure-store\generations\'+$a.Revision+'.bin'))))
    Assert (-not $usbText.Contains('SYNTHETIC-CREDENTIAL-ALPHA-19b27f')) 'credential appeared in encrypted generation'
    $provider=Get-CcEncryptedClaudeProvider -Session $session
    Assert ($provider.Name -eq 'synthetic' -and $provider.Secret -is [Security.SecureString]) 'provider shape'
    Assert ($provider.Models['ANTHROPIC_MODEL'] -eq 'synthetic-model') 'provider model mapping'
    $emptyModels=ConvertFrom-CcSwitchClaudeDocument -Document ([pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_BASE_URL='https://example.invalid';ANTHROPIC_AUTH_TOKEN='synthetic-token'}}) -Name 'synthetic-empty-models'
    Assert ($null -ne $emptyModels.Models -and $emptyModels.Models.Count -eq 0) 'empty provider Models must be a non-null dictionary'
    $proxyRejected=$false;try{$null=ConvertFrom-CcSwitchClaudeDocument -Document ([pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_BASE_URL='https://example.invalid';ANTHROPIC_AUTH_TOKEN='PROXY_MANAGED'}}) -Name 'synthetic-proxy'}catch{$proxyRejected=$true};Assert $proxyRejected 'proxy placeholder was accepted'
    $loopbackRejected=$false;try{$null=ConvertFrom-CcSwitchClaudeDocument -Document ([pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_BASE_URL='http://127.0.0.1:8080';ANTHROPIC_AUTH_TOKEN='synthetic-token'}}) -Name 'synthetic-loopback'}catch{$loopbackRejected=$true};Assert $loopbackRejected 'loopback API URL was accepted'
    $rejected=0
    foreach($unsafe in @('harness/cc-switch/claude/a:stream','harness/cc-switch/claude/trailing.','harness/cc-switch/claude/CON.txt')) {
        try { Assert-CcEncRelativePath $unsafe } catch {$rejected++}
    }
    Assert ($rejected -eq 3) 'unsafe ZIP path rejection'
    $held=Enter-CcEncLock (Get-CcEncPaths $usb).Store
    $busy=$false;try{$null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly}catch{$busy=$true}finally{$held.Dispose()}
    Assert $busy 'concurrent store lock was ignored'
    $staleSession=Open-CcEncryptedStoreSession -StickRoot $usb -Password $password
    $bad=$false;try{$wrong=ConvertTo-SecureString 'incorrect password' -AsPlainText -Force;$null=Open-CcEncryptedStoreSession -StickRoot $usb -Password $wrong}catch{$bad=$true};Assert $bad 'wrong password accepted'
    New-FakeSource $src 'SYNTHETIC-CREDENTIAL-BETA-92ce11'
    $b=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly
    Assert ((Get-CcEncryptedStoreStatus -StickRoot $usb).PreviousRevision -eq $a.Revision) 'previous generation not retained'
    $stale=$false;try{$null=Save-CcEncryptedSnapshot -Session $staleSession -SourceRoot $src -StoppedOnly}catch{$stale=$true}
    Assert $stale 'stale session revision was allowed to overwrite current'
    $null=Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $dest -StoppedOnly
    Assert ([IO.File]::ReadAllText((Join-Path $dest 'harness\cc-switch\claude\settings.json')).Contains('BETA-92ce11')) 'restore content mismatch'
    $null=Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $prevDest -StoppedOnly -Previous
    Assert ([IO.File]::ReadAllText((Join-Path $prevDest 'harness\cc-switch\claude\settings.json')).Contains('ALPHA-19b27f')) 'previous generation recovery mismatch'
    New-FakeSource $src 'SYNTHETIC-CREDENTIAL-GAMMA-9f45b2'
    $pending=Join-Path (Get-CcEncPaths $usb).Store 'migration.pending.json'
    [IO.File]::WriteAllText($pending,'{"version":1,"state":"MigrationInProgress"}',(New-Object Text.UTF8Encoding($false)))
    $unauthorized=$false;try{$null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly}catch{$unauthorized=$true}
    Assert $unauthorized 'migration pending marker did not block ordinary save'
    $leftover=Join-Path (Join-Path (Get-CcEncPaths $usb).Store 'generations') 'incomplete.tmp'
    [IO.File]::WriteAllText($leftover,'partial')
    $unsafeMigration=$false;try{$null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly -MigrationAuthorized}catch{$unsafeMigration=$true}
    Assert $unsafeMigration 'migration authorization bypassed unrelated recovery debris'
    [IO.File]::Delete($leftover)
    $cGeneration=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly -MigrationAuthorized
    [IO.File]::Delete($pending)
    $generationFiles=@(Get-ChildItem -LiteralPath (Join-Path $usb 'config\cc-switch\secure-store\generations') -Filter '*.bin')
    Assert ($generationFiles.Count -eq 2) 'stale encrypted generation cleanup'
    $gen=Join-Path $usb ('config\cc-switch\secure-store\generations\'+$cGeneration.Revision+'.bin');$envObj=[IO.File]::ReadAllText($gen)|ConvertFrom-Json;$c=[Convert]::FromBase64String($envObj.ciphertext);$c[0]=$c[0] -bxor 1;$envObj.ciphertext=[Convert]::ToBase64String($c);$tampered=(ConvertTo-Json $envObj -Compress);[IO.File]::WriteAllText($gen,$tampered,(New-Object Text.UTF8Encoding($false)))
    $tamper=$false;try{$null=Get-CcEncryptedClaudeProvider -Session $session}catch{$tamper=$true};Assert $tamper 'tampered ciphertext accepted'
    Close-CcEncryptedStoreSession $staleSession
    Close-CcEncryptedStoreSession $session;Assert ($session.Locked -and $null -eq $session.DataKey) 'session key not cleared'
    $keylessRoot=Join-Path $work 'keyless';$keylessGen=Join-Path $keylessRoot 'config\cc-switch\secure-store\generations';$null=New-Item -ItemType Directory -Path $keylessGen -Force;[IO.File]::WriteAllText((Join-Path $keylessGen ('00000000000000000000000000000001.bin')),'ciphertext')
    Assert ((Get-CcEncryptedStoreStatus -StickRoot $keylessRoot).State -eq 'RecoveryRequired') 'keyless encrypted data not marked for recovery'
    $newKeyRejected=$false;try{$null=Open-CcEncryptedStoreSession -StickRoot $keylessRoot -Password $password -Create}catch{$newKeyRejected=$true};Assert $newKeyRejected 'Create overwrote data after wrapped key loss'
    'PASS: encrypted snapshot, secret provider, wrong password, previous generation, restore, tamper rejection, close'
}finally{if($recoverySession){Close-CcEncryptedStoreSession $recoverySession};if($staleSession){Close-CcEncryptedStoreSession $staleSession};if($session){Close-CcEncryptedStoreSession $session};if([IO.Directory]::Exists($work)){Remove-Item -LiteralPath $work -Recurse -Force}}

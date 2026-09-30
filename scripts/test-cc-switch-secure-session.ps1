[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1')
$pass=0;$fail=0
function Check([string]$Name,[bool]$Ok){if($Ok){$script:pass++;Write-Host "PASS $Name" -ForegroundColor Green}else{$script:fail++;Write-Host "FAIL $Name" -ForegroundColor Red}}
function New-TestSecureString([AllowEmptyString()][string]$Value) { ConvertTo-SecureString $Value -AsPlainText -Force }
function Test-TestSecureStringDisposed([Security.SecureString]$Value) {
 try { $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value);[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);return $false }
 catch { return ($_.Exception -is [Management.Automation.MethodInvocationException] -or $_.Exception.InnerException -is [ObjectDisposedException]) }
}
function Get-TestTreeFingerprint([string]$Root) {
 $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
 return (@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
  $_.FullName.Substring($prefix.Length)+'='+((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
 }) -join "`n")
}
function Read-Host {
 param([string]$Prompt,[switch]$AsSecureString)
 $script:testPrompts.Add($Prompt)
 if($script:testInputQueue.Count -eq 0){throw 'Synthetic Read-Host input exhausted.'}
 return $script:testInputQueue.Dequeue()
}
$base=Join-Path ([IO.Path]::GetTempPath()) ('cc-secure-session-synthetic-'+[guid]::NewGuid().ToString('N'))
try {
 [IO.Directory]::CreateDirectory($base)|Out-Null
 $rootA=Join-Path $base 'volume-a';$rootB=Join-Path $base 'volume-b'
 [IO.Directory]::CreateDirectory($rootA)|Out-Null;[IO.Directory]::CreateDirectory($rootB)|Out-Null
 $pipeA=Get-CcSecurePipeName $rootA;$pipeAAgain=Get-CcSecurePipeName $rootA;$pipeB=Get-CcSecurePipeName $rootB
 Check 'pipe name is stable for one canonical root' ($pipeA -ceq $pipeAAgain)
 Check 'pipe name is distinct across roots on one volume' ($pipeA -cne $pipeB)
 $models=ConvertTo-CcSecureHashtable ([pscustomobject]@{sonnet='synthetic-model';haiku='synthetic-fast'})
 Check 'provider models convert to dictionary shape' ($models -is [System.Collections.IDictionary] -and $models['sonnet'] -ceq 'synthetic-model')
 $rejected=$false;try{Send-CcSecureSessionRequest -Root $rootA -Action 'RunCommand'}catch{$rejected=$_.Exception.Message -eq 'Unsupported broker operation.'}
 Check 'broker rejects arbitrary operation before connecting' $rejected
 $bounded=$false;try{$stream=New-Object IO.MemoryStream;$bytes=[Text.Encoding]::UTF8.GetBytes(('x'*32));$stream.Write($bytes,0,$bytes.Length);$stream.Position=0;Read-CcSecurePipeLine -Stream $stream -TimeoutMilliseconds 100 -MaxBytes 16|Out-Null}catch{$bounded=$_.Exception.Message -like '*fixed limit*'}
 Check 'pipe messages have a strict size cap' $bounded
 $script:lastSaveStatus='SaveFailed';$script:lastFailure='synthetic recovery package write failed';$script:locked=$false;$script:session=[pscustomobject]@{SyntheticKeyStillHeld=$true}
 $lockRejected=$false;$lockError=''
 try{Assert-CcSecureSessionActionAllowed -Action 'Lock'}catch{$lockRejected=$true;$lockError=$_.Exception.Message}
 Check 'Lock is refused after an unresolved save failure' ($lockRejected -and $lockError -like '*SaveFailed*' -and $lockError -like '*synthetic recovery package write failed*')
 Check 'failed Lock preserves unlocked session and recovery error' (-not $script:locked -and $script:session.SyntheticKeyStillHeld -and $script:lastSaveStatus -ceq 'SaveFailed' -and $script:lastFailure -ceq 'synthetic recovery package write failed')
 function Invoke-CcSecureSessionAction([string]$Action){$script:testCapturedAction=$Action;Assert-CcSecureSessionActionAllowed -Action $Action}
 $consoleOutput=@(Invoke-CcSecureConsoleLock 3>&1);$consoleWarnings=@($consoleOutput|Where-Object {$_ -is [Management.Automation.WarningRecord]});$consoleLockResult=($consoleOutput -contains $false)
 Check 'console Lock routes through guarded Lock action and reports refusal' ($consoleLockResult -and $script:testCapturedAction -ceq 'Lock' -and ([string]($consoleWarnings -join ' ') -like '*SaveFailed*') -and -not $script:locked -and $script:session.SyntheticKeyStillHeld)
 $launchRejected=$false;$launchError=''
 try{Assert-CcSecureSessionActionAllowed -Action 'LaunchGui'}catch{$launchRejected=$true;$launchError=$_.Exception.Message}
 Check 'GUI relaunch is refused without clearing failure evidence' ($launchRejected -and $launchError -like '*SaveFailed*' -and $script:lastSaveStatus -ceq 'SaveFailed' -and $script:lastFailure -ceq 'synthetic recovery package write failed')
 $cleanupRejected=$false;$cleanupError='';$control=[hashtable]::Synchronized(@{Saved=$true;CleanupComplete=$false})
 try{Assert-CcSecureSessionCleanupConfirmed -Control $control}catch{$cleanupRejected=$true;$cleanupError=$_.Exception.Message}
 Check 'worker save without plaintext cleanup confirmation is rejected' ($cleanupRejected -and $cleanupError -like '*cleanup*' -and $control.Saved -and -not $control.CleanupComplete)
 $cleanupAllowed=$true;$control.CleanupComplete=$true;try{Assert-CcSecureSessionCleanupConfirmed -Control $control}catch{$cleanupAllowed=$false}
 Check 'worker completion is accepted only after cleanup confirmation' $cleanupAllowed
 $script:lastSaveStatus='Saved';$script:lastFailure=$null
 $resolvedAllowed=$true;try{Assert-CcSecureSessionActionAllowed -Action 'LaunchGui';Assert-CcSecureSessionActionAllowed -Action 'Lock'}catch{$resolvedAllowed=$false}
 Check 'Lock and GUI relaunch are allowed after explicit resolution state' $resolvedAllowed

 # The retry helper is exercised with mock input/open calls, then against a
 # real synthetic encrypted store to verify a bad password never changes bytes.
 . (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
 $script:testInputQueue=New-Object 'System.Collections.Generic.Queue[object]'
 $script:testPrompts=New-Object 'System.Collections.Generic.List[string]'
 $script:testReadSecrets=New-Object 'System.Collections.Generic.List[Security.SecureString]'
 $script:testOpenCount=0
 $script:testExpectedPassword='right'
 $script:testOpenError=$null
 $originalOpen=(Get-Command Open-CcEncryptedStoreSession -CommandType Function).ScriptBlock
 Set-Item Function:\Open-CcEncryptedStoreSession -Value {
  param([string]$StickRoot,[Security.SecureString]$Password,[switch]$Create)
  $script:testOpenCount++
  $script:testReadSecrets.Add($Password)
  if($script:testOpenError){throw $script:testOpenError}
  $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
  if($plain -cne $script:testExpectedPassword){throw '主密码错误，或保险箱认证失败；原文件未修改。'}
  return [pscustomobject]@{SyntheticSession=$true;Create=[bool]$Create}
 }
 foreach($value in @('bad-one','bad-two','right')){$s=New-TestSecureString $value;$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $opened=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA
 Check 'master password retries wrong, wrong, then opens on correct input' ($opened.SyntheticSession -and $script:testOpenCount -eq 3 -and $script:testPrompts.Count -eq 3)
 Check 'all SecureStrings are disposed after successful retry' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)

 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear();$script:testOpenCount=0
 foreach($value in @('bad-one','bad-two','bad-three')){$s=New-TestSecureString $value;$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $threeFailed=$false;try{$null=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA}catch{$threeFailed=$_.Exception.Message -like '*三次主密码机会已用尽*'}
 Check 'three authentication failures stop after exactly three attempts' ($threeFailed -and $script:testOpenCount -eq 3 -and $script:testPrompts.Count -eq 3)
 Check 'all SecureStrings are disposed after exhausted retries' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)

 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear();$script:testOpenCount=0;$script:testOpenError='Encrypted store metadata is corrupt.'
 $s=New-TestSecureString 'right';$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)
 $nonAuth=$false;try{$null=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA}catch{$nonAuth=$_.Exception.Message -ceq 'Encrypted store metadata is corrupt.'}
 Check 'non-authentication errors fail immediately without retry' ($nonAuth -and $script:testOpenCount -eq 1 -and $script:testPrompts.Count -eq 1)
 Check 'SecureString is disposed after immediate non-authentication failure' (Test-TestSecureStringDisposed $s)
 $script:testOpenError=$null

 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear();$script:testOpenCount=0
 foreach($value in @('first','mismatch','right','right')){$s=New-TestSecureString $value;$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $created=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA -Create
 Check 'initial password confirmation mismatch can be retried before creating the store' ($created.SyntheticSession -and $created.Create -and $script:testOpenCount -eq 1 -and $script:testPrompts.Count -eq 4)
 Check 'confirmation passwords are disposed after retry' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)

 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear();$script:testOpenCount=0
 foreach($value in @('first','different-one','second','different-two','third','different-three')){$s=New-TestSecureString $value;$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $confirmExhausted=$false;try{$null=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA -Create}catch{$confirmExhausted=$_.Exception.Message -like '*三次确认机会已用尽*'}
 Check 'three initial confirmation mismatches never create or overwrite the store' ($confirmExhausted -and $script:testOpenCount -eq 0 -and $script:testPrompts.Count -eq 6)
 Check 'SecureStrings from all failed creation confirmations are disposed' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)

 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear();$script:testOpenCount=0
 for($i=0;$i -lt 3;$i++){$s=New-Object Security.SecureString; $script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $emptyRejected=$false;try{$null=Read-CcEncryptedStoreUnlockedSession -StickRoot $rootA}catch{$emptyRejected=$_.Exception.Message -like '*三次输入机会已用尽*'}
 Check 'empty passwords consume three attempts and do not call the store opener' ($emptyRejected -and $script:testOpenCount -eq 0 -and $script:testPrompts.Count -eq 3)
 Check 'empty SecureStrings are also disposed' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)

 Set-Item Function:\Open-CcEncryptedStoreSession -Value $originalOpen
 $syntheticVaultRoot=Join-Path $base 'synthetic-encrypted-store'
 [IO.Directory]::CreateDirectory($syntheticVaultRoot)|Out-Null
 $realPassword=New-TestSecureString 'synthetic-correct-password'
 $seedRoot=Join-Path $base 'synthetic-encrypted-seed'
 [IO.Directory]::CreateDirectory((Join-Path $seedRoot 'harness\cc-switch\claude'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $seedRoot 'harness\cc-switch\claude\settings.json'),'{}',(New-Object Text.UTF8Encoding($false)))
 try {
  $seedSession=Open-CcEncryptedStoreSession -StickRoot $syntheticVaultRoot -Password $realPassword -Create
  $null=Save-CcEncryptedSnapshot -Session $seedSession -SourceRoot $seedRoot -StoppedOnly
  $null=Save-CcEncryptedSnapshot -Session $seedSession -SourceRoot $seedRoot -StoppedOnly
  Close-CcEncryptedStoreSession -Session $seedSession
 } finally {$realPassword.Dispose()}
 $syntheticStoreRoot=Join-Path $syntheticVaultRoot 'config\cc-switch\secure-store'
 $storeFingerprintBefore=Get-TestTreeFingerprint $syntheticStoreRoot
 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear()
 foreach($value in @('synthetic-wrong-one','synthetic-wrong-two','synthetic-wrong-three')){$s=New-TestSecureString $value;$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)}
 $syntheticThreeFailed=$false;try{$null=Read-CcEncryptedStoreUnlockedSession -StickRoot $syntheticVaultRoot}catch{$syntheticThreeFailed=$_.Exception.Message -like '*三次主密码机会已用尽*'}
 $storeFingerprintAfter=Get-TestTreeFingerprint $syntheticStoreRoot
 Check 'synthetic encrypted vault stops after three wrong passwords without changing any ciphertext, pointer or generation bytes' ($syntheticThreeFailed -and $script:testPrompts.Count -eq 3 -and $storeFingerprintBefore -ceq $storeFingerprintAfter)
 Check 'synthetic vault failed-attempt SecureStrings are disposed' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)
 $script:testInputQueue.Clear();$script:testPrompts.Clear();$script:testReadSecrets.Clear()
 $s=New-TestSecureString 'synthetic-correct-password';$script:testInputQueue.Enqueue($s);$script:testReadSecrets.Add($s)
 $realSession=Read-CcEncryptedStoreUnlockedSession -StickRoot $syntheticVaultRoot
 Check 'synthetic encrypted vault still opens with its original password after failed retries' ($null -ne $realSession.DataKey -and $script:testPrompts.Count -eq 1)
 Check 'synthetic vault prompt SecureStrings are disposed' (@($script:testReadSecrets|Where-Object {-not (Test-TestSecureStringDisposed $_)}).Count -eq 0)
 Close-CcEncryptedStoreSession -Session $realSession
} finally {
 $full=[IO.Path]::GetFullPath($base);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if($full.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -like 'cc-secure-session-synthetic-*' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
Write-Host "Secure session synthetic checks: $pass passed, $fail failed"
if($fail){exit 1};exit 0

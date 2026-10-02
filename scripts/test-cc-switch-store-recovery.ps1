# Synthetic-only tests for the narrowly scoped interrupted-commit repair.
[CmdletBinding()]param([string]$TestParent)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-store-recovery.ps1')
$base=if($TestParent){[IO.Path]::GetFullPath($TestParent)}else{[IO.Path]::GetTempPath()}
$work=Join-Path $base ('ccenc-repair-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
function New-Source([string]$root,[string]$value){$d=Join-Path $root 'harness\cc-switch\claude';[void][IO.Directory]::CreateDirectory($d);[IO.File]::WriteAllText((Join-Path $d 'fixture.json'),('{"synthetic":"'+$value+'"}'),(New-Object Text.UTF8Encoding($false)))}
function PointerBytes([string]$rev){(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json ([ordered]@{format=$script:CcEncFormat;revision=$rev}) -Compress))}
function Active-Fingerprint([string]$store){$rows=New-Object 'System.Collections.Generic.List[string]';foreach($f in [IO.Directory]::GetFiles($store,'*',[IO.SearchOption]::AllDirectories)){if([IO.Path]::GetFileName($f) -ceq 'store.lock'){continue};$rel=$f.Substring($store.Length).TrimStart('\');$rows.Add($rel+'='+ (Get-CcEncRecoveryHash $f))};@($rows|Sort-Object) -join "`n"}
function Make-Interrupted([string]$root,$session,$src){
    New-Source $src 'second'
    $null=Save-CcEncryptedSnapshot -Session $session -SourceRoot $src -StoppedOnly
    $store=(Get-CcEncPaths $root).Store;$cur=Get-CcEncRecoveryPointer (Join-Path $store 'current.json');$pr=Get-CcEncRecoveryPointer (Join-Path $store 'previous.json')
    $tmp=Join-Path $store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp');$bak=Join-Path $store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.bak')
    [IO.File]::WriteAllBytes($tmp,$cur.Bytes);[IO.File]::WriteAllBytes($bak,$pr.Bytes)
    [Array]::Clear($cur.Bytes,0,$cur.Bytes.Length);[Array]::Clear($pr.Bytes,0,$pr.Bytes.Length)
    [IO.File]::Delete((Join-Path $store 'previous.json'))
    $gens=Join-Path $store 'generations';$orphan=[guid]::NewGuid().ToString('N')
    [IO.File]::Copy((Join-Path $gens ($session.Revision+'.bin')),(Join-Path $gens ($orphan+'.bin')))
    return [pscustomobject]@{Store=$store;Tmp=$tmp;Bak=$bak;Orphan=$orphan;ExpectedPrevious=$pr.Revision}
}
function New-TwoSnapshotFixture([string]$root,[string]$src,$password){
    New-Source $src 'fixture-first';$ss=Open-CcEncryptedStoreSession -StickRoot $root -Password $password -Create
    $first=Save-CcEncryptedSnapshot -Session $ss -SourceRoot $src -StoppedOnly
    New-Source $src 'fixture-second';$second=Save-CcEncryptedSnapshot -Session $ss -SourceRoot $src -StoppedOnly
    [pscustomobject]@{Session=$ss;Store=(Get-CcEncPaths $root).Store;Current=$second.Revision;Previous=$first.Revision}
}
try {
    [void][IO.Directory]::CreateDirectory($work);$password=ConvertTo-SecureString 'synthetic-only recovery password' -AsPlainText -Force
    $src=Join-Path $work 'src';[void][IO.Directory]::CreateDirectory($src);New-Source $src 'first'
    $goodRoot=Join-Path $work 'good';$s=Open-CcEncryptedStoreSession -StickRoot $goodRoot -Password $password -Create
    $null=Save-CcEncryptedSnapshot -Session $s -SourceRoot $src -StoppedOnly
    $state=Make-Interrupted $goodRoot $s $src
    $expectedBak=Get-CcEncRecoveryPointer $state.Bak
    $preparedStage=Join-Path $state.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllBytes($preparedStage,(PointerBytes $expectedBak.Revision))
    [Array]::Clear($expectedBak.Bytes,0,$expectedBak.Bytes.Length)
    Assert ((Get-CcEncryptedStoreStatus $goodRoot).State -eq 'RecoveryRequired') 'interrupted fixture did not require recovery'
    $repaired=Repair-CcEncryptedStore -Session $s
    Assert ($repaired.State -ceq 'Recovered' -and $repaired.PreviousRevision -ceq $state.ExpectedPrevious) 'historical previous revision was not restored with explicit recovered result'
    Assert ((Get-CcEncryptedStoreStatus $goodRoot).State -eq 'Locked') 'repaired store did not become clean'
    Assert (-not [IO.File]::Exists($state.Tmp) -and -not [IO.File]::Exists($state.Bak)) 'recovery pointer artifacts remain active'
    Assert (-not [IO.File]::Exists((Join-Path $state.Store ('generations\'+$state.Orphan+'.bin')))) 'orphan generation remains active'
    Assert ([IO.File]::Exists((Join-Path $state.Store ('generations\'+$s.Revision+'.bin'))) -and [IO.File]::Exists((Join-Path $state.Store ('generations\'+$repaired.PreviousRevision+'.bin')))) 'current/previous generations were not retained'
    Assert ([IO.Directory]::Exists((Join-Path $goodRoot 'config\cc-switch\recovery-archives'))) 'encrypted archive is missing'
    # Retry after the previous pointer commit, as if cleanup was interrupted.
    $resumeRoot=Join-Path $work 'resume';$resumeSession=Open-CcEncryptedStoreSession -StickRoot $goodRoot -Password $password
    # status is now clean; synthesize the same post-write cleanup state again.
    $cur=Get-CcEncRecoveryPointer (Join-Path $state.Store 'current.json');$bakNow=Join-Path $state.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.bak');$tmpNow=Join-Path $state.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllBytes($tmpNow,$cur.Bytes);[IO.File]::WriteAllBytes($bakNow,(PointerBytes $repaired.PreviousRevision));[Array]::Clear($cur.Bytes,0,$cur.Bytes.Length)
    [IO.File]::Delete((Join-Path $state.Store 'previous.json'))
    # Commit previous from backup, then call again to exercise resumable cleanup.
    [IO.File]::WriteAllBytes((Join-Path $state.Store 'previous.json'),(PointerBytes $repaired.PreviousRevision))
    $null=Repair-CcEncryptedStore -Session $resumeSession
    Assert ((Get-CcEncryptedStoreStatus $goodRoot).State -eq 'Locked') 'cleanup continuation did not finish'
    Close-CcEncryptedStoreSession $resumeSession;Close-CcEncryptedStoreSession $s

    # Exercise normal Write-CcEncBytes completion with backup cleanup interrupted:
    # previous now equals current, .bak still points to historical previous.
    foreach($case in @('save-window','replace-staged','replace-committed','partial-cleanup')) {
        $caseRoot=Join-Path $work ('case-'+$case);$fixture=New-TwoSnapshotFixture $caseRoot $src $password
        $prevPath=Join-Path $fixture.Store 'previous.json';$curPath=Join-Path $fixture.Store 'current.json';$bakPath=Join-Path $fixture.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.bak')
        $curPointer=Get-CcEncRecoveryPointer $curPath;$prevPointer=Get-CcEncRecoveryPointer $prevPath
        if($case -eq 'save-window') {
            [IO.File]::WriteAllBytes($bakPath,$prevPointer.Bytes);[IO.File]::WriteAllBytes($prevPath,$curPointer.Bytes)
        } elseif($case -eq 'replace-staged') {
            [IO.File]::WriteAllBytes($bakPath,$prevPointer.Bytes);[IO.File]::WriteAllBytes($prevPath,$curPointer.Bytes)
            $stage=Join-Path $fixture.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllBytes($stage,$prevPointer.Bytes)
        } elseif($case -eq 'replace-committed') {
            [IO.File]::WriteAllBytes($bakPath,$prevPointer.Bytes)
            # previous already holds the historical value; only the cleanup remains.
            $witness=Join-Path $fixture.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllBytes($witness,$curPointer.Bytes)
        } else {
            # The backup was already removed, but the current witness and orphan remain.
            $witness=Join-Path $fixture.Store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllBytes($witness,$curPointer.Bytes)
        }
        [Array]::Clear($curPointer.Bytes,0,$curPointer.Bytes.Length);[Array]::Clear($prevPointer.Bytes,0,$prevPointer.Bytes.Length)
        if($case -eq 'save-window' -or $case -eq 'replace-staged'){[IO.File]::Delete($prevPath)}
        if($case -eq 'save-window' -or $case -eq 'replace-staged') {
            # Emulate the completed temporary-pointer move: previous=current.
            [IO.File]::WriteAllBytes($prevPath,(PointerBytes $fixture.Current))
        }
        $orphan=[guid]::NewGuid().ToString('N');[IO.File]::Copy((Join-Path $fixture.Store ('generations\'+$fixture.Current+'.bin')),(Join-Path $fixture.Store ('generations\'+$orphan+'.bin')))
        $caseResult=Repair-CcEncryptedStore -Session $fixture.Session
        Assert ($caseResult.State -ceq 'Recovered' -and $caseResult.PreviousRevision -ceq $fixture.Previous) ($case+' did not recover historical previous')
        Assert ((Get-CcEncryptedStoreStatus $caseRoot).State -ceq 'Locked') ($case+' left recovery debris active')
        Assert (-not [IO.File]::Exists((Join-Path $fixture.Store ('generations\'+$orphan+'.bin')))) ($case+' left orphan generation active')
        Close-CcEncryptedStoreSession $fixture.Session
    }

    foreach($kind in @('wrong-key','tampered','unsupported','changed-keyring')) {
        $r=Join-Path $work $kind;$ss=Open-CcEncryptedStoreSession -StickRoot $r -Password $password -Create
        New-Source $src 'case-'+$kind;$null=Save-CcEncryptedSnapshot -Session $ss -SourceRoot $src -StoppedOnly
        $fx=Make-Interrupted $r $ss $src
        if($kind -eq 'unsupported'){[IO.File]::WriteAllText((Join-Path $fx.Store 'unexpected.bin'),'x')}
        if($kind -eq 'tampered'){$g=Join-Path $fx.Store ('generations\'+$ss.Revision+'.bin');$b=[IO.File]::ReadAllBytes($g);$b[$b.Length-2]=$b[$b.Length-2] -bxor 1;[IO.File]::WriteAllBytes($g,$b);[Array]::Clear($b,0,$b.Length)}
        if($kind -eq 'changed-keyring'){$kp=Get-CcEncKeyring $fx.Store;$kb=[IO.File]::ReadAllBytes($kp);$kb[$kb.Length-1]=$kb[$kb.Length-1] -bxor 1;[IO.File]::WriteAllBytes($kp,$kb);[Array]::Clear($kb,0,$kb.Length)}
        $before=Active-Fingerprint $fx.Store
        if($kind -eq 'wrong-key'){$real=$ss.DataKey;$bad=New-Object byte[] 32;for($bi=0;$bi -lt $bad.Length;$bi++){$bad[$bi]=0x5a};$ss.DataKey=$bad}
        $rejected=$false;try{$null=Repair-CcEncryptedStore -Session $ss}catch{$rejected=$true}
        if($kind -eq 'wrong-key'){$ss.DataKey=$real;[Array]::Clear($bad,0,$bad.Length)}
        Assert $rejected ($kind+' recovery was not rejected')
        Assert ((Active-Fingerprint $fx.Store) -ceq $before) ($kind+' rejection modified active store')
        Close-CcEncryptedStoreSession $ss
    }
    $busyRoot=Join-Path $work 'busy';$busySession=Open-CcEncryptedStoreSession -StickRoot $busyRoot -Password $password -Create
    New-Source $src 'busy';$null=Save-CcEncryptedSnapshot -Session $busySession -SourceRoot $src -StoppedOnly;$busyFx=Make-Interrupted $busyRoot $busySession $src
    $held=Enter-CcEncLock $busyFx.Store;$busy=$false;try{$null=Repair-CcEncryptedStore -Session $busySession}catch{$busy=$true}finally{$held.Dispose()};Assert $busy 'concurrent lock was ignored'
    Close-CcEncryptedStoreSession $busySession
    'PASS: interrupted previous commit repair, archive, retained history, resume, fail-closed corruption/key/unsupported/lock cases'
} finally {if([IO.Directory]::Exists($work)){[IO.Directory]::Delete($work,$true)}}

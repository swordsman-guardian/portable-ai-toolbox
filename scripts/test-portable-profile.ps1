# Synthetic-only tests for portable-profile.ps1; never reads application/user data.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'portable-profile.ps1')

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "测试失败：$Message" } }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $thrown=$false; try { & $Action } catch { $thrown=$true }; Assert-True $thrown $Message }
function New-TestPassword([string]$Text) { ConvertTo-SecureString -String $Text -AsPlainText -Force }
function Write-MaliciousProfile([string]$File,[Security.SecureString]$Password,[string]$Path) {
    $payload=[ordered]@{format='portable-application-profile';version=1;files=@(@{path=$Path;data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('marker'))})}
    $json=ConvertTo-Json -InputObject $payload -Depth 5 -Compress
    $dict=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $dict.Add('portable-profile-payload',[Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($json)))
    [void](Write-PortableVault -Path $File -Password $Password -Secrets $dict -ExpectedRevision $null)
    $dict.Clear()
}
function Write-ProfilePayload([string]$File,[Security.SecureString]$Password,[object[]]$Entries) {
    $payload=[ordered]@{format='portable-application-profile';version=1;files=$Entries}
    $json=ConvertTo-Json -InputObject $payload -Depth 5 -Compress
    $dict=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $dict.Add('portable-profile-payload',[Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($json)))
    [void](Write-PortableVault -Path $File -Password $Password -Secrets $dict -ExpectedRevision $null)
    $dict.Clear()
}

$work=Join-Path ([IO.Path]::GetTempPath()) ('portable-profile-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$good=New-TestPassword 'synthetic-passphrase'
$wrong=New-TestPassword 'wrong-passphrase'
try {
    $src=Join-Path $work 'source'; [IO.Directory]::CreateDirectory((Join-Path $src 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'settings.json'),'synthetic settings only')
    [IO.File]::WriteAllBytes((Join-Path $src 'nested\data.bin'),[byte[]](0,1,2,3,255))
    $profile=Join-Path $work 'profile.enc'
    $saved=Save-PortableProfile -Path $profile -Password $good -SourceRoot $src -ExpectedRevision $null
    Assert-True ($saved.FileCount -eq 2 -and $saved.Revision.Length -eq 64) 'save metadata'
    $missingParent=Join-Path $work 'first-save\missing\profile.enc'
    Assert-Throws { Save-PortableProfile -Path $missingParent -Password $good -SourceRoot $src -ExpectedRevision $null } 'missing profile parent rejected'
    Assert-True (-not [IO.Directory]::Exists((Split-Path -Parent (Split-Path -Parent $missingParent))) -and -not [IO.File]::Exists($missingParent)) 'missing parent failure writes nothing'
    $dest=Join-Path $work 'restored'
    $restored=Restore-PortableProfile -Path $profile -Password $good -DestinationRoot $dest
    Assert-True ($restored.FileCount -eq 2 -and [IO.File]::ReadAllText((Join-Path $dest 'settings.json')) -eq 'synthetic settings only') 'roundtrip text'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dest 'nested\data.bin'))) -eq 'AAECA/8=') 'roundtrip binary'
    $otherRoot=Join-Path $work 'independent-local-root'
    $otherDest=Join-Path $otherRoot 'app\fresh-config'
    $crossRoot=Restore-PortableProfile -Path $profile -Password $good -DestinationRoot $otherDest
    Assert-True ($crossRoot.FileCount -eq 2 -and [IO.File]::ReadAllText((Join-Path $otherDest 'settings.json')) -eq 'synthetic settings only') 'restore under independent root'

    $badDest=Join-Path $work 'wrong-password-dest'
    Assert-Throws { Restore-PortableProfile -Path $profile -Password $wrong -DestinationRoot $badDest } 'wrong password rejected'
    Assert-True (-not [IO.Directory]::Exists($badDest)) 'wrong password creates no plaintext destination'

    $oldRevision=$saved.Revision
    [IO.File]::AppendAllText((Join-Path $src 'settings.json'),' changed')
    $newSaved=Save-PortableProfile -Path $profile -Password $good -SourceRoot $src -ExpectedRevision $oldRevision
    Assert-True ($newSaved.Revision -ne $oldRevision) 'update creates revision'
    Assert-Throws { Save-PortableProfile -Path $profile -Password $wrong -SourceRoot $src -ExpectedRevision $newSaved.Revision } 'wrong password cannot update existing profile'
    Assert-True ((Get-PortableProfileStatus -Path $profile).Revision -eq $newSaved.Revision) 'wrong password leaves profile unchanged'
    [IO.File]::WriteAllText((Join-Path $src 'settings.json'),'should not replace')
    Assert-Throws { Save-PortableProfile -Path $profile -Password $good -SourceRoot $src -ExpectedRevision $oldRevision } 'stale revision rejected'
    Assert-True ((Get-PortableProfileStatus -Path $profile).Revision -eq $newSaved.Revision) 'conflict leaves stored revision unchanged'

    $nonempty=Join-Path $work 'nonempty'; [IO.Directory]::CreateDirectory($nonempty) | Out-Null
    [IO.File]::WriteAllText((Join-Path $nonempty 'keep.txt'),'keep')
    Assert-Throws { Restore-PortableProfile -Path $profile -Password $good -DestinationRoot $nonempty } 'nonempty target rejected'
    Assert-True ([IO.File]::ReadAllText((Join-Path $nonempty 'keep.txt')) -eq 'keep') 'nonempty target preserved'

    $tampered=Join-Path $work 'tampered.enc'; [IO.File]::Copy($profile,$tampered)
    $bytes=[IO.File]::ReadAllBytes($tampered); $bytes[$bytes.Length-5]=$bytes[$bytes.Length-5] -bxor 1; [IO.File]::WriteAllBytes($tampered,$bytes)
    $tamperDest=Join-Path $work 'tamper-dest'
    Assert-Throws { Restore-PortableProfile -Path $tampered -Password $good -DestinationRoot $tamperDest } 'tampered envelope rejected'
    Assert-True (-not [IO.Directory]::Exists($tamperDest)) 'tampering creates no output'

    foreach ($malicious in @('../escape','C:/ads','folder/../escape','CON.txt','folder/Name.')) {
        $evil=Join-Path $work ('evil-'+[Guid]::NewGuid().ToString('N')+'.enc')
        Write-MaliciousProfile $evil $good $malicious
        $evilDest=Join-Path $work ('evil-dest-'+[Guid]::NewGuid().ToString('N'))
        Assert-Throws { Restore-PortableProfile -Path $evil -Password $good -DestinationRoot $evilDest } "malicious path rejected: $malicious"
        Assert-True (-not [IO.Directory]::Exists($evilDest)) 'invalid manifest produces no output'
    }

    $rollbackProfile=Join-Path $work 'rollback.enc'
    $rollbackEntries=@(
        @{path='created-first.txt';data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic'))},
        @{path='trigger-fault.txt';data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('late failure'))}
    )
    Write-ProfilePayload $rollbackProfile $good $rollbackEntries
    $rollbackDest=Join-Path $work 'rollback-output'
    $script:profileWriteCount=0
    $script:profileExternalMarker=Join-Path $rollbackDest 'external.txt'
    $script:profileOriginalWriter=(Get-Command Write-PortableProfileStreamBytes).ScriptBlock
    Set-Item Function:\Write-PortableProfileStreamBytes -Value {
        param([IO.FileStream]$Stream,[byte[]]$Bytes)
        $script:profileWriteCount++
        if ($script:profileWriteCount -eq 2) {
            [IO.File]::WriteAllText($script:profileExternalMarker,'external synthetic file')
            throw 'synthetic write failure after first restored file'
        }
        & $script:profileOriginalWriter -Stream $Stream -Bytes $Bytes
    }
    try {
        Assert-Throws { Restore-PortableProfile -Path $rollbackProfile -Password $good -DestinationRoot $rollbackDest } 'late filesystem failure is surfaced'
        Assert-True ([IO.File]::Exists($script:profileExternalMarker) -and [IO.File]::ReadAllText($script:profileExternalMarker) -eq 'external synthetic file') 'rollback preserves external file'
        Assert-True (-not [IO.File]::Exists((Join-Path $rollbackDest 'created-first.txt'))) 'rollback deletes its partial file'
    } finally { Set-Item Function:\Write-PortableProfileStreamBytes -Value $script:profileOriginalWriter }

    $raceDest=Join-Path $work 'raced-target'
    $script:profileOriginalReader=(Get-Command Read-PortableProfilePayload).ScriptBlock
    Set-Item Function:\Read-PortableProfilePayload -Value {
        param([string]$Path,[Security.SecureString]$Password)
        $payload=& $script:profileOriginalReader -Path $Path -Password $Password
        [IO.Directory]::CreateDirectory($script:profileRaceDestination) | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:profileRaceDestination 'external.txt'),'external synthetic file')
        return $payload
    }
    $script:profileRaceDestination=$raceDest
    try {
        Assert-Throws { Restore-PortableProfile -Path $profile -Password $good -DestinationRoot $raceDest } 'target rechecked after decryption'
        Assert-True ([IO.File]::ReadAllText((Join-Path $raceDest 'external.txt')) -eq 'external synthetic file') 'post-decryption target check preserves external data'
    } finally { Set-Item Function:\Read-PortableProfilePayload -Value $script:profileOriginalReader }

    $recoveryPath=Join-Path $work 'recovery-status.enc'
    [IO.File]::WriteAllText(($recoveryPath+'.tmp'),'synthetic interrupted write')
    Assert-True ((Get-PortableProfileStatus -Path $recoveryPath).State -eq 'RecoveryRequired') 'missing main with temp is recovery-required'

    $limit=Join-Path $work 'limit'; [IO.Directory]::CreateDirectory($limit) | Out-Null
    for($i=0;$i -lt 513;$i++){[IO.File]::WriteAllBytes((Join-Path $limit ('f'+$i)),[byte[]]@())}
    $limitProfile=Join-Path $work 'limit.enc'
    Assert-Throws { Save-PortableProfile -Path $limitProfile -Password $good -SourceRoot $limit -ExpectedRevision $null } 'file count limit enforced'
    Assert-True (-not [IO.File]::Exists($limitProfile)) 'limit failure creates no profile'

    $treeLimit=Join-Path $work 'tree-limit'; [IO.Directory]::CreateDirectory($treeLimit) | Out-Null
    for($i=0;$i -lt 2049;$i++){[IO.Directory]::CreateDirectory((Join-Path $treeLimit ('d'+$i))) | Out-Null}
    Assert-Throws { Save-PortableProfile -Path (Join-Path $work 'tree-limit.enc') -Password $good -SourceRoot $treeLimit -ExpectedRevision $null } 'directory entry budget enforced'
    Assert-True (-not [IO.File]::Exists((Join-Path $work 'tree-limit.enc'))) 'tree budget failure creates no profile'

    $depthLimit=Join-Path $work 'depth-limit'; [IO.Directory]::CreateDirectory($depthLimit) | Out-Null
    $deep=$depthLimit
    for($i=0;$i -lt 33;$i++){$deep=Join-Path $deep ('d'+$i);[IO.Directory]::CreateDirectory($deep) | Out-Null}
    Assert-Throws { Save-PortableProfile -Path (Join-Path $work 'depth-limit.enc') -Password $good -SourceRoot $depthLimit -ExpectedRevision $null } 'directory depth budget enforced'
    Assert-True (-not [IO.File]::Exists((Join-Path $work 'depth-limit.enc'))) 'depth budget failure creates no profile'

    $maxDepthSource=Join-Path $work 'max-depth-source'; [IO.Directory]::CreateDirectory($maxDepthSource) | Out-Null
    $maxDepthDir=$maxDepthSource
    for($i=0;$i -lt 32;$i++){$maxDepthDir=Join-Path $maxDepthDir ('d'+$i);[IO.Directory]::CreateDirectory($maxDepthDir) | Out-Null}
    [IO.File]::WriteAllText((Join-Path $maxDepthDir 'leaf.txt'),'depth 32 synthetic')
    $maxDepthProfile=Join-Path $work 'max-depth.enc'
    [void](Save-PortableProfile -Path $maxDepthProfile -Password $good -SourceRoot $maxDepthSource -ExpectedRevision $null)
    $maxDepthDest=Join-Path $work 'max-depth-restore'
    $maxDepthResult=Restore-PortableProfile -Path $maxDepthProfile -Password $good -DestinationRoot $maxDepthDest
    Assert-True ($maxDepthResult.FileCount -eq 1 -and [IO.File]::ReadAllText((Join-Path $maxDepthDest 'd0\d1\d2\d3\d4\d5\d6\d7\d8\d9\d10\d11\d12\d13\d14\d15\d16\d17\d18\d19\d20\d21\d22\d23\d24\d25\d26\d27\d28\d29\d30\d31\leaf.txt')) -eq 'depth 32 synthetic') 'exactly 32 directory levels roundtrip'

    $sizeLimit=Join-Path $work 'size-limit'; [IO.Directory]::CreateDirectory($sizeLimit) | Out-Null
    $big=New-Object byte[] (16MB+1); [IO.File]::WriteAllBytes((Join-Path $sizeLimit 'large.bin'),$big); [Array]::Clear($big,0,$big.Length)
    Assert-Throws { Save-PortableProfile -Path (Join-Path $work 'size-limit.enc') -Password $good -SourceRoot $sizeLimit -ExpectedRevision $null } 'byte size limit enforced'

    Write-Output 'PASS: portable profile synthetic tests'
} finally {
    # Verify the generated test root is exactly the child created above before removal.
    $expectedPrefix=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'portable-profile-test-'))
    $fullWork=[IO.Path]::GetFullPath($work)
    if (-not $fullWork.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or $fullWork -eq $expectedPrefix) { throw 'refusing test cleanup outside its verified temp root' }
    if ([IO.Directory]::Exists($fullWork)) { Remove-Item -LiteralPath $fullWork -Recurse -Force }
}


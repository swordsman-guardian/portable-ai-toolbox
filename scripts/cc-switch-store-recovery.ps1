# Narrow repair for an interrupted previous.json replacement. Dot-source after
# opening an authenticated encrypted-store session.
Set-StrictMode -Version 2.0

if(-not (Get-Command Get-VolumeIdentity -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'lib.ps1') }
if(-not ('CcEncRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CcEncRecoveryNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool MoveFileEx(string existingName, string newName, uint flags);
    public static void ReplaceExisting(string source, string destination) {
        const uint MOVEFILE_REPLACE_EXISTING = 0x1;
        const uint MOVEFILE_WRITE_THROUGH = 0x8;
        if(!MoveFileEx(source, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}

function Get-CcEncRecoveryPointer([string]$Path) {
    $b=Read-CcEncBytesLimited $Path 4096
    try {
        $o=(New-Object Text.UTF8Encoding($false,$true)).GetString($b)|ConvertFrom-Json -ErrorAction Stop
        if($o.format -cne $script:CcEncFormat -or [string]$o.revision -notmatch '^[0-9a-f]{32}$') { throw 'Invalid recovery pointer.' }
        return [pscustomobject]@{Revision=[string]$o.revision;Bytes=$b}
    } catch { [Array]::Clear($b,0,$b.Length); throw 'Recovery pointer is malformed or unsupported.' }
}
function Get-CcEncRecoveryHash([string]$Path) {
    $s=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($s)).Replace('-','').ToLowerInvariant()) }
    finally {$sha.Dispose();$s.Dispose()}
}
function Assert-CcEncRecoveryEnvironment($Session,$ExpectedVolume) {
    if(-not (Test-StickPresent -Expected $ExpectedVolume)){throw 'The encrypted store volume was removed or replaced during recovery.'}
    if(-not $Session.KeyringBytes){throw 'Authenticated session does not contain its wrapped-key fingerprint.'}
    $now=Read-CcEncBytesLimited (Get-CcEncKeyring (Get-CcEncPaths $Session.StickRoot).Store) 50331648
    $left=$null;$right=$null
    try {
        $left=Get-CcEncRecoveryHashBytes $Session.KeyringBytes;$right=Get-CcEncRecoveryHashBytes $now
        if(-not (Test-VaultBytesEqual -A $left -B $right)){throw 'Wrapped key changed since session authentication.'}
    } finally {[Array]::Clear($now,0,$now.Length);if($left){[Array]::Clear($left,0,$left.Length)};if($right){[Array]::Clear($right,0,$right.Length)}}
}
function Get-CcEncRecoveryHashBytes([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ,$sha.ComputeHash($Bytes)}finally{$sha.Dispose()}
}
function Copy-CcEncRecoveryArchive([string]$Store,[string]$ArchiveStore) {
    Assert-CcEncNoReparse $Store -Children
    [void][IO.Directory]::CreateDirectory($ArchiveStore)
    Assert-CcEncNoReparse $ArchiveStore
    $records=New-Object 'System.Collections.Generic.List[object]'
    $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($Store)
    while($stack.Count) {
        $dir=$stack.Pop()
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            Assert-CcEncNoReparse $entry
            $attr=[IO.File]::GetAttributes($entry)
            $relative=$entry.Substring($Store.TrimEnd('\','/').Length).TrimStart('\','/')
            if(($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                $target=Join-Path $ArchiveStore $relative;[void][IO.Directory]::CreateDirectory($target);Assert-CcEncNoReparse $target;$stack.Push($entry)
            } else {
                if($relative -ceq 'store.lock') { continue }
                $before=Get-CcEncRecoveryHash $entry
                $target=Join-Path $ArchiveStore $relative
                $parent=Split-Path -Parent $target
                if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)}
                Assert-CcEncNoReparse $parent;Assert-CcEncNoReparse $target
                [IO.File]::Copy($entry,$target,$false)
                $flush=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                try {$flush.Flush($true)} finally {$flush.Dispose()}
                Assert-CcEncNoReparse $target
                $after=Get-CcEncRecoveryHash $entry;$copy=Get-CcEncRecoveryHash $target
                if($before -cne $after -or $before -cne $copy){throw 'Encrypted store changed during recovery archive verification.'}
                $records.Add([pscustomobject]@{Source=$entry;Archive=$target;Hash=$before})
            }
        }
    }
    # A zero-byte lock marker is useful when reviewing the archived tree; lock
    # contents are process-local and are deliberately never copied.
    $lockArchive=Join-Path $ArchiveStore 'store.lock'
    Assert-CcEncNoReparse $lockArchive
    if(-not [IO.File]::Exists($lockArchive)){[IO.File]::WriteAllBytes($lockArchive,(New-Object byte[] 0))}
    return ,$records
}
function Repair-CcEncryptedStore {
    [CmdletBinding()]param([Parameter(Mandatory)]$Session)
    if($Session.Locked -or -not $Session.DataKey){throw 'Encrypted store session is locked.'}
    $p=Get-CcEncPaths $Session.StickRoot;$store=$p.Store
    Assert-CcEncNoReparse $p.StickRoot;Assert-CcEncNoReparse $store -Children
    $expectedVolume=Get-VolumeIdentity -StickRoot $p.StickRoot
    $lock=Enter-CcEncLock $store
    $current=$null;$targetBytes=$null
    try {
        Assert-CcEncRecoveryEnvironment $Session $expectedVolume
        $status=Get-CcEncryptedStoreStatus $p.StickRoot
        if($status.State -eq 'Corrupt'){throw 'Encrypted store metadata is corrupt.'}
        if($status.CurrentRevision -cne [string]$Session.Revision){throw 'Encrypted store revision changed; reopen before repair.'}
        if(-not $status.CurrentRevision -or [IO.File]::Exists((Join-Path $store 'migration.pending.json'))){throw 'This encrypted recovery state is unsupported.'}
        $keyPath=Get-CcEncKeyring $store
        if(-not [IO.File]::Exists($keyPath)){throw 'Encrypted recovery requires the existing wrapped key.'}

        $allowedRoot=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($n in @('keyring.vault.json','keyring.vault.json.lock','current.json','previous.json','generations','store.lock')){[void]$allowedRoot.Add($n)}
        $sidecars=New-Object 'System.Collections.Generic.List[string]'
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($store)) {
            Assert-CcEncNoReparse $entry
            $leaf=[IO.Path]::GetFileName($entry)
            if($allowedRoot.Contains($leaf)){continue}
            if($leaf -match '^current\.json\.[0-9a-f]{32}\.(tmp|bak)$'){throw 'Current pointer recovery artifacts are unsupported.'}
            if($leaf -match '^previous\.json\.([0-9a-f]{32})\.(tmp|bak)$') {$sidecars.Add($entry);continue}
            throw 'Encrypted recovery found an unsupported store entry.'
        }
        $gens=Join-Path $store 'generations';Assert-CcEncNoReparse $gens
        $genFiles=New-Object 'System.Collections.Generic.List[string]'
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($gens)) {
            Assert-CcEncNoReparse $entry
            if([IO.Directory]::Exists($entry)){throw 'Encrypted recovery found a directory in generations.'}
            $leaf=[IO.Path]::GetFileName($entry)
            if($leaf -notmatch '^[0-9a-f]{32}\.bin$'){throw 'Encrypted recovery found an unsupported generation file.'}
            $genFiles.Add($entry)
        }
        $currentPath=Join-Path $store 'current.json';$current=Get-CcEncRecoveryPointer $currentPath
        if($current.Revision -cne [string]$Session.Revision){[Array]::Clear($current.Bytes,0,$current.Bytes.Length);throw 'Current pointer changed since authentication.'}
        $v=Get-CcEncVerifiedZip $store $current.Revision $Session.DataKey;$v.Zip.Dispose();$v.Stream.Dispose();[Array]::Clear($v.Plain,0,$v.Plain.Length)

        $prevPath=Join-Path $store 'previous.json';$targetBytes=$null;$targetRevision=$null
        $tmp=@($sidecars|Where-Object{[IO.Path]::GetFileName($_) -match '^previous\.json\.[0-9a-f]{32}\.tmp$'})
        $bak=@($sidecars|Where-Object{[IO.Path]::GetFileName($_) -match '^previous\.json\.[0-9a-f]{32}\.bak$'})
        if($bak.Count -gt 1 -or $sidecars.Count -ne ($tmp.Count+$bak.Count) -or $tmp.Count -gt 2){throw 'This interrupted pointer state is ambiguous or unsupported.'}
        $prevRevision=$null
        $prevBytes=$null
        if([IO.File]::Exists($prevPath)) {$prev=Get-CcEncRecoveryPointer $prevPath;$prevRevision=$prev.Revision;$prevBytes=$prev.Bytes}
        if($prevRevision -and $prevRevision -cne $current.Revision) {$targetRevision=$prevRevision;$targetBytes=$prevBytes;if($bak.Count -eq 1){$old=Get-CcEncRecoveryPointer $bak[0];try{if($old.Revision -cne $targetRevision){throw 'Previous pointer differs from its transaction backup.'}}finally{[Array]::Clear($old.Bytes,0,$old.Bytes.Length)}}}
        else {
            if($bak.Count -ne 1){if($prevBytes){[Array]::Clear($prevBytes,0,$prevBytes.Length)};throw 'Previous history is unavailable in this interrupted state.'}
            $old=Get-CcEncRecoveryPointer $bak[0]
            if($old.Revision -ceq $current.Revision){[Array]::Clear($old.Bytes,0,$old.Bytes.Length);if($prevBytes){[Array]::Clear($prevBytes,0,$prevBytes.Length)};throw 'Interrupted backup does not identify a distinct previous generation.'}
            $targetBytes=$old.Bytes;$targetRevision=$old.Revision
        }
        $tmpRevisions=New-Object 'System.Collections.Generic.List[string]'
        foreach($t in $tmp) {$tp=Get-CcEncRecoveryPointer $t;$tmpRevisions.Add($tp.Revision);[Array]::Clear($tp.Bytes,0,$tp.Bytes.Length)}
        foreach($tr in $tmpRevisions){if($tr -cne $current.Revision -and $tr -cne $targetRevision){throw 'Interrupted temporary pointer is unrelated to current or previous.'}}
        $seenTmp=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($tr in $tmpRevisions){if(-not $seenTmp.Add($tr)){throw 'Duplicate interrupted temporary pointers are ambiguous.'}}
        if(-not $prevRevision -and (-not $tmpRevisions.Contains($current.Revision) -or $bak.Count -ne 1)){throw 'Missing previous pointer has no complete interrupted-commit evidence.'}
        if($prevRevision -ceq $current.Revision -and $bak.Count -ne 1){throw 'Current previous pointer has no historical transaction backup.'}
        if($prevRevision -ceq $targetRevision -and $tmpRevisions.Contains($targetRevision)){throw 'Committed previous pointer has a duplicate recovery staging file.'}
        if($prevRevision -ceq $current.Revision -and $tmpRevisions.Contains($current.Revision)){throw 'Current pointer has an unsupported duplicate temporary file.'}
        $v=Get-CcEncVerifiedZip $store $targetRevision $Session.DataKey;$v.Zip.Dispose();$v.Stream.Dispose();[Array]::Clear($v.Plain,0,$v.Plain.Length)
        Assert-CcEncRecoveryEnvironment $Session $expectedVolume
        $keep=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$keep.Add($current.Revision);[void]$keep.Add($targetRevision)
        foreach($g in $genFiles){$r=[IO.Path]::GetFileNameWithoutExtension($g);if(-not $keep.Contains($r) -and $r -notmatch '^[0-9a-f]{32}$'){throw 'Unsupported orphan generation.'}}

        $archiveParent=Join-Path $p.StickRoot 'config\cc-switch\recovery-archives'
        if(-not [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($archiveParent)).Equals([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($store)),[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery archive must remain on the encrypted store volume.'}
        Assert-CcEncNoReparse $archiveParent
        $archiveStore=Join-Path (Join-Path $archiveParent ([guid]::NewGuid().ToString('N'))) 'store'
        $archiveRecords=Copy-CcEncRecoveryArchive $store $archiveStore
        # Revalidate every source after archive and before any active-store change.
        foreach($r in $archiveRecords){if((Get-CcEncRecoveryHash $r.Source) -cne $r.Hash -or (Get-CcEncRecoveryHash $r.Archive) -cne $r.Hash){throw 'Recovery archive verification failed.'}}
        $postFiles=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($f in [IO.Directory]::EnumerateFiles($store,'*',[IO.SearchOption]::AllDirectories)) {Assert-CcEncNoReparse $f;if([IO.Path]::GetFileName($f) -cne 'store.lock'){[void]$postFiles.Add([IO.Path]::GetFullPath($f))}}
        $archivedFiles=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($r in $archiveRecords){[void]$archivedFiles.Add([IO.Path]::GetFullPath($r.Source))}
        if($postFiles.Count -ne $archivedFiles.Count){throw 'Encrypted store file inventory changed during recovery archive.'}
        foreach($f in $postFiles){if(-not $archivedFiles.Contains($f)){throw 'Encrypted store file inventory changed during recovery archive.'}}
        Assert-CcEncRecoveryEnvironment $Session $expectedVolume
        if($prevRevision -cne $targetRevision) {
            $stageFiles=New-Object 'System.Collections.Generic.List[string]'
            foreach($t in $tmp){$tp=Get-CcEncRecoveryPointer $t;try{if($tp.Revision -ceq $targetRevision){$stageFiles.Add($t)}}finally{[Array]::Clear($tp.Bytes,0,$tp.Bytes.Length)}}
            if($stageFiles.Count -gt 1){throw 'Multiple recovery staging pointers are ambiguous.'}
            if($stageFiles.Count -eq 1){$stagePath=$stageFiles[0]}
            else {$stagePath=Join-Path $store ('previous.json.'+[guid]::NewGuid().ToString('N')+'.tmp');$f=[IO.File]::Open($stagePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($targetBytes,0,$targetBytes.Length);$f.Flush($true)}finally{$f.Dispose()}}
            Assert-CcEncNoReparse $stagePath
            $staged=Get-CcEncRecoveryPointer $stagePath
            if($staged.Revision -cne $targetRevision){[Array]::Clear($staged.Bytes,0,$staged.Bytes.Length);throw 'Recovery staging pointer does not match the authenticated previous generation.'}
            [Array]::Clear($staged.Bytes,0,$staged.Bytes.Length)
            Assert-CcEncRecoveryEnvironment $Session $expectedVolume
            if([IO.File]::Exists($prevPath)){[CcEncRecoveryNative]::ReplaceExisting($stagePath,$prevPath)}else{[IO.File]::Move($stagePath,$prevPath)}
            [void]$sidecars.Remove($stagePath)
        }
        $committed=Get-CcEncRecoveryPointer $prevPath
        if($committed.Revision -cne $targetRevision){[Array]::Clear($committed.Bytes,0,$committed.Bytes.Length);throw 'Recovered previous pointer failed verification.'}
        [Array]::Clear($committed.Bytes,0,$committed.Bytes.Length)
        $v=Get-CcEncVerifiedZip $store $committed.Revision $Session.DataKey;$v.Zip.Dispose();$v.Stream.Dispose();[Array]::Clear($v.Plain,0,$v.Plain.Length)
        foreach($item in $sidecars) {
            if(-not [IO.File]::Exists($item)){throw 'A recovery pointer artifact changed during cleanup.'}
            Assert-CcEncNoReparse $item;$archiveItem=Join-Path $archiveStore ($item.Substring($store.TrimEnd('\','/').Length).TrimStart('\','/'));Assert-CcEncNoReparse $archiveItem
            $record=@($archiveRecords|Where-Object{$_.Source -ceq $item})
            if($record.Count -ne 1 -or (Get-CcEncRecoveryHash $item) -cne $record[0].Hash -or (Get-CcEncRecoveryHash $record[0].Archive) -cne $record[0].Hash){throw 'Refusing to remove an unarchived recovery pointer artifact.'}
            Assert-CcEncRecoveryEnvironment $Session $expectedVolume
            [IO.File]::Delete($item)
        }
        foreach($g in $genFiles) {
            $rev=[IO.Path]::GetFileNameWithoutExtension($g)
            if($keep.Contains($rev)){continue}
            if(-not [IO.File]::Exists($g)){throw 'An orphan generation changed during cleanup.'}
            Assert-CcEncNoReparse $g;$archiveItem=Join-Path $archiveStore ($g.Substring($store.TrimEnd('\','/').Length).TrimStart('\','/'));Assert-CcEncNoReparse $archiveItem
            $record=@($archiveRecords|Where-Object{$_.Source -ceq $g})
            if($record.Count -ne 1 -or (Get-CcEncRecoveryHash $g) -cne $record[0].Hash -or (Get-CcEncRecoveryHash $record[0].Archive) -cne $record[0].Hash){throw 'Refusing to remove an unarchived generation.'}
            Assert-CcEncRecoveryEnvironment $Session $expectedVolume
            [IO.File]::Delete($g)
        }
        $Session.Revision=$current.Revision
        Assert-CcEncRecoveryEnvironment $Session $expectedVolume
        $final=Get-CcEncryptedStoreStatus $p.StickRoot
        if($final.State -cne 'Locked' -or $final.CurrentRevision -cne $current.Revision -or $final.PreviousRevision -cne $targetRevision){throw 'Recovered encrypted store failed its final status check.'}
        return [pscustomobject]@{State='Recovered';Revision=$current.Revision;PreviousRevision=$targetRevision;ArchivePath=(Split-Path -Parent $archiveStore)}
    } finally {
        if($targetBytes){[Array]::Clear([byte[]]$targetBytes,0,$targetBytes.Length)}
        if($current -and $current.Bytes){[Array]::Clear([byte[]]$current.Bytes,0,$current.Bytes.Length)}
        $lock.Dispose()
    }
}

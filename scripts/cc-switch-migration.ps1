# One-time, stopped legacy CC Switch migration. Never migrate a live GUI tree.
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'cc-switch-store.ps1')

function Get-CcLegacyMigrationFiles {
    param([Parameter(Mandatory)][string]$StickRoot)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $total = [long]0
    foreach ($relativeRoot in @('config\cc-switch\store','config\cc-switch\home\.cc-switch','harness\cc-switch')) {
        $top = Join-Path $StickRoot $relativeRoot
        Assert-CcStoreNoReparse $top
        if (-not (Test-Path -LiteralPath $top)) { continue }
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($top)
        $entries = 0
        while ($pending.Count) {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
                $entries++
                if ($entries -gt 12000) { throw 'Legacy migration tree exceeds the entry limit.' }
                Assert-CcStoreNoReparse $entry
                $item = Get-Item -LiteralPath $entry -Force
                if ($item.PSIsContainer) { $pending.Push($entry); continue }
                if ($item.Name -in @('live-session.lock','store.lock')) { continue }
                $total += $item.Length
                if ($total -gt 256MB -or $records.Count -ge 10000) { throw 'Legacy migration exceeds the supported size.' }
                $records.Add([pscustomobject]@{Path=$entry;Length=$item.Length;Hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash})
            }
        }
    }
    return $records.ToArray()
}

function Assert-CcMigrationFilesUnchanged {
    param([string]$StickRoot,[object[]]$Before)
    $after = @(Get-CcLegacyMigrationFiles -StickRoot $StickRoot)
    if ($after.Count -ne $Before.Count) { throw 'Legacy files changed during encryption; originals were retained.' }
    $map = @{}
    foreach ($item in $after) { $map[$item.Path] = $item }
    foreach ($item in $Before) {
        if (-not $map.ContainsKey($item.Path) -or $map[$item.Path].Hash -ne $item.Hash) { throw 'Legacy files changed during encryption; originals were retained.' }
    }
}

function Copy-CcMigrationSnapshot {
    param([string]$SourceRoot,[string]$DestinationRoot)
    $inventory = Get-CcStoreInventory -SourceRoot $SourceRoot
    [void][IO.Directory]::CreateDirectory($DestinationRoot)
    foreach ($dir in $inventory.Directories) { [void][IO.Directory]::CreateDirectory((Join-Path $DestinationRoot $dir.RelativePath)) }
    foreach ($file in $inventory.Files) {
        Assert-CcStoreNoReparse $file.FullPath
        $hash = (Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash
        $target = Join-Path $DestinationRoot $file.RelativePath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-CcStoreFileVerified -Source $file.FullPath -Destination $target -Length $file.Length -Hash $hash
    }
}

function Assert-CcMigrationRoundtrip {
    param([string]$SourceRoot,[string]$RestoredRoot)
    $source = Get-CcStoreInventory -SourceRoot $SourceRoot
    $restored = Get-CcStoreInventory -SourceRoot $RestoredRoot
    if ($source.Files.Count -ne $restored.Files.Count) { throw 'Encrypted migration roundtrip file count differs.' }
    foreach ($file in $source.Files) {
        $target = Join-Path $RestoredRoot $file.RelativePath
        if (-not (Test-CcStoreFileHash -Path $target -ExpectedLength $file.Length -ExpectedHash ((Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash))) {
            throw 'Encrypted migration roundtrip failed; plaintext originals were retained.'
        }
    }
}

function Assert-CcMigrationCoverage {
    param([string]$StickRoot,[object[]]$Legacy,[string[]]$Sources,$OldPaths,$Pointer)
    $covered = @{}
    foreach ($source in $Sources) {
        foreach ($file in (Get-CcStoreInventory -SourceRoot $source).Files) {
            $relative = $file.RelativePath.Replace('/','\')
            if (-not $covered.ContainsKey($relative)) { $covered[$relative] = @() }
            $covered[$relative] += (Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash
        }
    }
    $prefix = $StickRoot.TrimEnd('\') + '\'
    foreach ($file in $Legacy) {
        $relative = $file.Path.Substring($prefix.Length)
        if ($relative -eq 'config\cc-switch\store\current.json') { continue }
        if ($relative -match '^config\\cc-switch\\store\\generations\\([0-9a-f]{32})\\(.+)$') {
            if (-not $Pointer -or $Matches[1] -notin @($Pointer.CurrentRevision,$Pointer.PreviousRevision)) { throw 'Unreferenced legacy files require recovery before migration.' }
            $tail = $Matches[2]
            if ($tail -eq 'manifest.json') { continue }
            if (-not $tail.StartsWith('payload\')) { throw 'Unknown legacy generation file would not be encrypted; originals retained.' }
            $relative = $tail.Substring(8)
        }
        if ($covered.ContainsKey($relative) -and $file.Hash -in $covered[$relative]) { continue }
        if ($relative -eq 'harness\cc-switch\claude\settings.json' -and $file.Length -le 64 -and [IO.File]::ReadAllText($file.Path).Trim() -ceq '{"env":{}}') { continue }
        throw 'Legacy backup, log, or other unrepresented file requires review before migration; originals retained.'
    }
}

function Initialize-CcEncryptedStoreFromLegacy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot,[Parameter(Mandatory)]$Session)
    $ErrorActionPreference = 'Stop'
    $stick = ConvertTo-CcStoreFullPath $StickRoot
    if ((ConvertTo-CcStoreFullPath $Session.StickRoot) -ne $stick) { throw 'Encryption session belongs to another USB root.' }
    $secureRoot = Join-Path $stick 'config\cc-switch\secure-store'
    $pendingPath = Join-Path $secureRoot 'migration.pending.json'
    Assert-CcStoreNoReparse $pendingPath
    if (Test-Path -LiteralPath $pendingPath) { throw 'A previous migration was interrupted; encrypted and legacy copies require recovery before launch.' }
    $legacy = @(Get-CcLegacyMigrationFiles -StickRoot $stick)
    if ($legacy.Count -eq 0) { return [pscustomobject]@{Status='NotNeeded';Migrated=$false} }
    $secureStatus = Get-CcEncryptedStoreStatus -StickRoot $stick
    if ($secureStatus.CurrentRevision) { throw 'Encrypted and legacy data coexist; refusing to overwrite either configuration automatically.' }
    $oldPaths = Get-CcStorePaths -StickRoot $stick
    $locks = New-Object 'System.Collections.Generic.List[IDisposable]'
    $localRoot = $null
    $pendingWritten = $false
    try {
        [void][IO.Directory]::CreateDirectory($oldPaths.StoreRoot)
        foreach ($name in @('live-session.lock','store.lock')) {
            $lockPath = Join-Path $oldPaths.StoreRoot $name
            Assert-CcStoreNoReparse $lockPath
            $locks.Add((New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)))
        }
        Assert-CcMigrationFilesUnchanged -StickRoot $stick -Before $legacy
        $oldStatus = Get-CcSwitchStoreStatus -StickRoot $stick
        if ($oldStatus.Status -eq 'RecoveryRequired') { throw 'Legacy storage requires recovery before migration.' }
        $localRoot = Join-Path ([IO.Path]::GetTempPath()) ('aistick-cc-migration-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($localRoot)
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
            [void]$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
        }
        [IO.Directory]::SetAccessControl($localRoot,$acl)
        $sources = New-Object 'System.Collections.Generic.List[string]'
        $pointer = $null
        if ($oldStatus.Status -eq 'Present') {
            $pointer = Read-CcStoreCurrent -Paths $oldPaths
            $revisions = @($pointer.PreviousRevision,$pointer.CurrentRevision) | Where-Object { $_ }
            foreach ($directory in [IO.Directory]::EnumerateDirectories($oldPaths.GenerationsRoot)) {
                if ((Split-Path -Leaf $directory) -notin $revisions) { throw 'Unreferenced legacy generations require recovery before migration.' }
            }
            foreach ($revision in $revisions) {
                $manifest = Join-Path $oldPaths.GenerationsRoot ($revision + '\manifest.json')
                Assert-CcStoreNoReparse $manifest
                $candidate = [pscustomobject]@{CurrentRevision=$revision;ManifestSha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash}
                if ($revision -eq $pointer.CurrentRevision) { $candidate.ManifestSha256=$pointer.ManifestSha256 }
                $snapshot = Get-CcStoreGeneration -Paths $oldPaths -Pointer $candidate
                foreach ($record in $snapshot.Manifest.Files) {
                    if (-not(Test-CcStoreFileHash -Path (Join-Path $snapshot.PayloadRoot $record.RelativePath) -ExpectedLength $record.Length -ExpectedHash $record.Sha256)) { throw 'Legacy snapshot integrity check failed.' }
                }
                $source = Join-Path $localRoot ('source-' + $revision)
                Copy-CcMigrationSnapshot -SourceRoot $snapshot.PayloadRoot -DestinationRoot $source
                $sources.Add($source)
            }
            # Existing exported files must agree with the authoritative current snapshot.
            if ((Test-Path -LiteralPath (Join-Path $stick 'harness\cc-switch')) -or (Test-Path -LiteralPath (Join-Path $stick 'config\cc-switch\home\.cc-switch'))) {
                $direct = Get-CcStoreInventory -SourceRoot $stick
                foreach ($file in $direct.Files) {
                    $authoritative = Join-Path $sources[$sources.Count-1] $file.RelativePath
                    $isTombstone = $file.RelativePath.Replace('\','/') -eq 'harness/cc-switch/claude/settings.json' -and -not(Test-Path -LiteralPath $authoritative) -and $file.Length -le 64 -and ([IO.File]::ReadAllText($file.FullPath).Trim() -ceq '{"env":{}}')
                    if (-not $isTombstone -and -not (Test-CcStoreFileHash -Path $authoritative -ExpectedLength $file.Length -ExpectedHash ((Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash))) { throw 'Standalone legacy configuration differs from the snapshot; originals were retained.' }
                }
            }
        } else {
            $source = Join-Path $localRoot 'source-standalone'
            Copy-CcMigrationSnapshot -SourceRoot $stick -DestinationRoot $source
            $sources.Add($source)
        }
        # Never delete a legacy backup or extra file merely because the snapshot filter skipped it.
        Assert-CcMigrationCoverage -StickRoot $stick -Legacy $legacy -Sources $sources.ToArray() -OldPaths $oldPaths -Pointer $pointer
        # This small marker contains no credentials. Any interrupted migration blocks automatic launch.
        [IO.File]::WriteAllText($pendingPath,'{"version":1,"state":"MigrationInProgress"}',(New-Object Text.UTF8Encoding($false)))
        $pendingWritten = $true
        foreach ($source in $sources) {
            $null = Save-CcEncryptedSnapshot -Session $Session -SourceRoot $source -StoppedOnly -MigrationAuthorized
            $verify = Join-Path $localRoot ('verify-' + [guid]::NewGuid().ToString('N'))
            $null = Restore-CcEncryptedSnapshot -Session $Session -DestinationRoot $verify -StoppedOnly
            Assert-CcMigrationRoundtrip -SourceRoot $source -RestoredRoot $verify
        }
        Assert-CcMigrationFilesUnchanged -StickRoot $stick -Before $legacy
        [IO.File]::WriteAllText($pendingPath,'{"version":1,"state":"EncryptedVerifiedCleanupPending"}',(New-Object Text.UTF8Encoding($false)))
        # Remove only captured, unchanged files in the three fixed legacy trees; never recurse over the USB root.
        foreach ($file in $legacy) {
            Assert-CcStoreNoReparse $file.Path
            if (-not(Test-CcStoreFileHash -Path $file.Path -ExpectedLength $file.Length -ExpectedHash $file.Hash)) { throw 'A legacy file changed before cleanup; migration remains incomplete.' }
            Remove-Item -LiteralPath $file.Path -Force -ErrorAction Stop
        }
        Remove-Item -LiteralPath $pendingPath -Force
        $pendingWritten = $false
        return [pscustomobject]@{Status='Migrated';Migrated=$true;EncryptedRevisions=$sources.Count;PlaintextFilesRemoved=$legacy.Count}
    } finally {
        foreach ($handle in $locks) { $handle.Dispose() }
        if ($localRoot -and (Test-Path -LiteralPath $localRoot)) {
            $full = [IO.Path]::GetFullPath($localRoot).TrimEnd('\')
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
            if ((Split-Path -Parent $full) -ne $temp -or (Split-Path -Leaf $full) -notmatch '^aistick-cc-migration-[0-9a-f]{32}$') { throw 'Refusing migration temporary cleanup outside its owned root.' }
            Assert-CcStoreNoReparse $full
            $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($full)
            while($pending.Count) { foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) { Assert-CcStoreNoReparse $entry; if([IO.Directory]::Exists($entry)){$pending.Push($entry)} } }
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
    }
}

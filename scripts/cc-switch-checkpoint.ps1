Set-StrictMode -Version 2

function Get-CcCheckpointFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Only absolute drive paths are supported.' }
    return [IO.Path]::GetFullPath($Path)
}

function Test-CcCheckpointWithin {
    param([string]$Path,[string]$Root)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    return $p.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith(($r+'\'),[StringComparison]::OrdinalIgnoreCase)
}

function Assert-CcCheckpointNoReparse {
    param([string]$Path,[string]$Boundary)
    $p = [IO.Path]::GetFullPath($Path)
    $b = [IO.Path]::GetFullPath($Boundary)
    if (-not (Test-CcCheckpointWithin $p $b)) { throw 'Path escaped its approved root.' }
    $cur = $p
    while ($true) {
        if (Test-Path -LiteralPath $cur) {
            $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not allowed in checkpoint paths.' }
        }
        if ($cur.Equals($b,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Directory]::GetParent($cur)
        if ($null -eq $parent) { throw 'Could not validate path ancestry.' }
        $cur = $parent.FullName
    }
}

function Test-CcCheckpointExcluded {
    param([string]$RelativePath)
    $parts = $RelativePath -split '[\\/]'
    foreach ($part in $parts) {
        if ($part -match '^(?i:logs?|history|histories|backups?|cache|sessions|runtime-locks?)$') { return $true }
        if ($part -match '(?i)(\.bak|\.backup|\.old|\.orig|\.tmp|\.lock|\.wal|\.shm|\.journal|-wal|-shm|-journal)$') { return $true }
    }
    return $false
}

function Get-CcCheckpointInventory {
    param([string]$SourceRoot)
    $items = @{}
    [int64]$totalBytes = 0
    foreach ($relTop in @('config\cc-switch\home\.cc-switch','harness\cc-switch')) {
        $top = Join-Path $SourceRoot $relTop
        if (-not (Test-Path -LiteralPath $top)) { continue }
        Assert-CcCheckpointNoReparse $top $SourceRoot
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($top)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($entry in [IO.Directory]::GetFileSystemEntries($dir)) {
                Assert-CcCheckpointNoReparse $entry $SourceRoot
                $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                $relative = $entry.Substring($SourceRoot.Length).TrimStart('\','/')
                if (Test-CcCheckpointExcluded $relative) { continue }
                if ($item.PSIsContainer) { $stack.Push($entry); continue }
                if (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo]) { throw 'Unexpected source item type.' }
                if ($relative -ieq 'config\cc-switch\home\.cc-switch\cc-switch.db') { continue }
                $hash = (Get-FileHash -LiteralPath $entry -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($item.Length -gt 20MB) { throw 'A source file exceeds the checkpoint size limit.' }
                $totalBytes += [int64]$item.Length
                if ($totalBytes -gt 100MB -or $items.Count -ge 1000) { throw 'Checkpoint input exceeds the bounded file count or size.' }
                $items[$relative] = [pscustomobject]@{ Path=$entry; Length=[int64]$item.Length; Hash=$hash }
            }
        }
    }
    return ,$items
}

function New-CcSwitchOnlineCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [Parameter(Mandatory=$true)][string]$DestinationRoot,
        [Parameter(Mandatory=$true)][string]$PythonExe,
        [ValidateRange(1,5)][int]$TimeoutSeconds = 5
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $stage = $null
    try {
        $source = Get-CcCheckpointFullPath $SourceRoot
        $dest = Get-CcCheckpointFullPath $DestinationRoot
        $python = Get-CcCheckpointFullPath $PythonExe
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'SourceRoot does not exist.' }
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'PythonExe does not exist.' }
        if (Test-Path -LiteralPath $dest) { throw 'DestinationRoot must not already exist.' }
        if ((Test-CcCheckpointWithin $dest $source) -or (Test-CcCheckpointWithin $source $dest)) { throw 'SourceRoot and DestinationRoot must not overlap.' }
        $parent = [IO.Directory]::GetParent($dest).FullName
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination parent must already exist.' }
        $drive = Get-PSDrive -Name $dest.Substring(0,1) -PSProvider FileSystem -ErrorAction Stop
        $root = [IO.Path]::GetPathRoot($dest)
        $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='"+$root.TrimEnd('\')+"'") -ErrorAction Stop
        if ($volume.DriveType -ne 3 -or $volume.FileSystem -ne 'NTFS') { throw 'Destination must be on a fixed NTFS volume.' }
        Assert-CcCheckpointNoReparse $source ([IO.Path]::GetPathRoot($source))
        Assert-CcCheckpointNoReparse $parent ([IO.Path]::GetPathRoot($parent))
        $stage = Join-Path $parent ('.cc-switch-checkpoint-stage-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($stage)
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        $adminsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        foreach ($sid in @($currentSid,$systemSid,$adminsSid)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            [void]$acl.AddAccessRule($rule)
        }
        [IO.Directory]::SetAccessControl($stage,$acl)
        foreach ($rel in @('config\cc-switch\home','harness\cc-switch')) { [void][IO.Directory]::CreateDirectory((Join-Path $stage $rel)) }

        $before = Get-CcCheckpointInventory $source
        foreach ($rel in $before.Keys) {
            $srcPath = $before[$rel].Path
            Assert-CcCheckpointNoReparse $srcPath $source
            $target = Join-Path $stage $rel
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.File]::Copy($srcPath,$target,$false)
            $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($targetHash -ne $before[$rel].Hash) { throw 'A copied file failed validation.' }
        }

        $dbRel = 'config\cc-switch\home\.cc-switch\cc-switch.db'
        $dbSource = Join-Path $source $dbRel
        $dbStage = Join-Path $stage $dbRel
        $dbIntegrity = 'not-present'
        if (Test-Path -LiteralPath $dbSource) {
            Assert-CcCheckpointNoReparse $dbSource $source
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dbStage))
            $helper = Join-Path $PSScriptRoot 'cc-switch-sqlite-backup.py'
            if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'SQLite backup helper is missing.' }
            if ((Test-CcCheckpointWithin $python $source) -or (Test-CcCheckpointWithin $helper $source)) { throw 'Checkpoint executable and helper must be outside the source root.' }
            $result = & $python -I $helper backup $source $stage $TimeoutSeconds 2>$null
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0 -or $result -notmatch '"ok":true.*"integrity":"ok"') { throw 'SQLite online backup or integrity check failed.' }
            $dbIntegrity = 'ok'
        }
        $after = Get-CcCheckpointInventory $source
        if ($before.Count -ne $after.Count) { throw 'Source changed while checkpoint was being created.' }
        foreach ($rel in $before.Keys) {
            if (-not $after.ContainsKey($rel) -or $before[$rel].Length -ne $after[$rel].Length -or $before[$rel].Hash -ne $after[$rel].Hash) {
                throw 'Source changed while checkpoint was being created.'
            }
        }
        if ($dbIntegrity -eq 'ok' -and -not (Test-Path -LiteralPath $dbStage -PathType Leaf)) { throw 'SQLite backup output is missing.' }
        if (Test-Path -LiteralPath $dest) { throw 'DestinationRoot appeared during checkpoint.' }
        [IO.Directory]::Move($stage,$dest)
        $stage = $null
        return [pscustomobject]@{
            Status='Complete'; CheckpointRoot=$dest; FilesCopied=$before.Count
            DatabaseBackedUp=($dbIntegrity -eq 'ok'); DatabaseIntegrity=$dbIntegrity
            FileStabilityVerified=$true; MultiFileConsistencyGuaranteed=$false; GuiValidated=$false
        }
    } catch {
        throw ('Checkpoint failed safely; no checkpoint was published (' + $_.Exception.GetType().Name + ').')
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            try {
                if ((Split-Path -Leaf $stage) -match '^\.cc-switch-checkpoint-stage-[0-9a-f]{32}$' -and (Test-CcCheckpointWithin $stage ([IO.Directory]::GetParent($stage).FullName))) {
                    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
                }
            } catch { }
        }
        $ErrorActionPreference = $oldEap
    }
}

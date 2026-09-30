[CmdletBinding()]
param()

$script:CcStoreVersion = 1
$script:CcStoreMaxFiles = 4096
$script:CcStoreMaxEntries = 8192
$script:CcStoreMaxBytes = [long]1073741824
$script:CcStoreMaxDepth = 64
$script:CcStoreMaxManifestBytes = 8388608

function ConvertTo-CcStoreFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A filesystem path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-CcStorePathWithin {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $pathFull = ConvertTo-CcStoreFullPath $Path
    $rootFull = ConvertTo-CcStoreFullPath $Root
    if ([string]::Equals($pathFull, $rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootFull.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-CcStoreOverlap {
    param([string]$First, [string]$Second)
    return (Test-CcStorePathWithin -Path $First -Root $Second) -or (Test-CcStorePathWithin -Path $Second -Root $First)
}

function Assert-CcStoreNoReparse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = ConvertTo-CcStoreFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length)
    $parts = $relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    $cursor = $root
    foreach ($part in $parts) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'CC Switch store paths cannot contain reparse points.' }
        }
    }
}

function Get-CcStorePaths {
    param([string]$StickRoot)
    $stick = ConvertTo-CcStoreFullPath $StickRoot
    $store = Join-Path $stick 'config\cc-switch\store'
    return [pscustomobject]@{
        StickRoot = $stick
        StoreRoot = $store
        GenerationsRoot = (Join-Path $store 'generations')
        CurrentPath = (Join-Path $store 'current.json')
        CurrentBackupPath = (Join-Path $store 'current.json.bak')
        LockPath = (Join-Path $store 'store.lock')
        ExportPath = (Join-Path $stick 'harness\cc-switch\claude\settings.json')
    }
}

function Assert-CcStoreSafeRootPair {
    param([string]$StickRoot, [string]$OtherRoot)
    $stick = ConvertTo-CcStoreFullPath $StickRoot
    $other = ConvertTo-CcStoreFullPath $OtherRoot
    if ([string]::Equals($stick, [IO.Path]::GetPathRoot($stick), [StringComparison]::OrdinalIgnoreCase)) { $stick = [IO.Path]::GetPathRoot($stick) }
    if ([string]::Equals($other, [IO.Path]::GetPathRoot($other), [StringComparison]::OrdinalIgnoreCase)) { throw 'The managed runtime root cannot be a volume root.' }
    Assert-CcStoreNoReparse -Path $stick
    Assert-CcStoreNoReparse -Path $other
    $paths = Get-CcStorePaths $stick
    if (Test-CcStoreOverlap -First $other -Second $paths.StoreRoot) { throw 'The source/destination root must not overlap the USB store.' }
    return $paths
}

function Assert-CcStoreRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Length -gt 240 -or $RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\') -or $RelativePath -match ':|\\|[\x00-\x1f]') {
        throw 'Snapshot contains an invalid relative path.'
    }
    $parts = $RelativePath.Split('/')
    foreach ($part in $parts) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.Length -gt 255 -or $part -match '[<>"|?*]' -or $part -match '[ .]$') {
            throw 'Snapshot contains an invalid path component.'
        }
        $base = ($part -split '\.')[0]
        if ($base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Snapshot contains a reserved Windows filename.' }
    }
    $normalized = $RelativePath.ToLowerInvariant()
    if (-not ($normalized.StartsWith('config/cc-switch/home/.cc-switch/', [StringComparison]::Ordinal) -or $normalized -eq 'config/cc-switch/home/.cc-switch' -or $normalized.StartsWith('harness/cc-switch/', [StringComparison]::Ordinal) -or $normalized -eq 'harness/cc-switch')) {
        throw 'Snapshot path is outside the two supported CC Switch data trees.'
    }
    if ($parts.Count -gt $script:CcStoreMaxDepth) { throw 'Snapshot path exceeds the directory depth limit.' }
}

function Test-CcStoreExcludedEntry {
    param([string]$Name, [bool]$IsDirectory)
    if ($IsDirectory) { return @('log', 'logs', 'history', 'backup', 'backups', 'cache', 'caches', 'sessions', 'session', 'tmp', 'temp') -contains $Name.ToLowerInvariant() }
    $lower = $Name.ToLowerInvariant()
    return ($lower -match '(?:\.log(?:\..*)?|\.bak|\.backup|\.tmp|\.temp|\.lock|-(?:wal|shm|journal)|\.(?:wal|shm|journal))$')
}

function Get-CcStoreRelativePath {
    param([string]$Root, [string]$Path)
    $fullRoot = ConvertTo-CcStoreFullPath $Root
    $fullPath = ConvertTo-CcStoreFullPath $Path
    if (-not (Test-CcStorePathWithin -Path $fullPath -Root $fullRoot) -or [string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A scanned path is not a child of its declared source root.'
    }
    return $fullPath.Substring($fullRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

function Add-CcStoreTreeInventory {
    param(
        [string]$SourceRoot,
        [string]$TreePath,
        [System.Collections.Generic.List[object]]$Directories,
        [System.Collections.Generic.List[object]]$Files,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [ref]$TotalBytes,
        [ref]$EntryCount
    )
    if (-not (Test-Path -LiteralPath $TreePath)) { return }
    if (-not (Test-Path -LiteralPath $TreePath -PathType Container)) { throw 'A supported CC Switch data root is not a directory.' }
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $rootRelative = Get-CcStoreRelativePath -Root $SourceRoot -Path $TreePath
    Assert-CcStoreRelativePath $rootRelative
    $rootDepth = $rootRelative.Split('/').Count
    $Directories.Add([pscustomobject]@{ RelativePath = $rootRelative; FullPath = $TreePath; Depth = $rootDepth })
    $stack.Push([pscustomobject]@{ FullPath = $TreePath; RelativePath = $rootRelative; Depth = $rootDepth })
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries([string]$current.FullPath, '*', [IO.SearchOption]::TopDirectoryOnly)) {
            $EntryCount.Value++
            if ($EntryCount.Value -gt $script:CcStoreMaxEntries) { throw 'The CC Switch tree exceeds the directory entry limit.' }
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'CC Switch data trees cannot contain reparse points.' }
            if (Test-CcStoreExcludedEntry -Name $item.Name -IsDirectory ([bool]$item.PSIsContainer)) { continue }
            $relative = ([string]$current.RelativePath) + '/' + $item.Name
            Assert-CcStoreRelativePath $relative
            if (-not $Seen.Add($relative)) { throw 'CC Switch tree contains duplicate or case-conflicting paths.' }
            if ($item.PSIsContainer) {
                $depth = [int]$current.Depth + 1
                if ($depth -gt $script:CcStoreMaxDepth) { throw 'CC Switch tree exceeds the directory depth limit.' }
                $Directories.Add([pscustomobject]@{ RelativePath = $relative; FullPath = $entry; Depth = $depth })
                $stack.Push([pscustomobject]@{ FullPath = $entry; RelativePath = $relative; Depth = $depth })
            } else {
                $length = [long]$item.Length
                if ($length -lt 0 -or $length -gt $script:CcStoreMaxBytes - $TotalBytes.Value) { throw 'CC Switch data exceeds the snapshot byte limit.' }
                $TotalBytes.Value += $length
                $Files.Add([pscustomobject]@{ RelativePath = $relative; FullPath = $entry; Length = $length })
                if ($Files.Count -gt $script:CcStoreMaxFiles) { throw 'CC Switch data exceeds the file count limit.' }
            }
        }
    }
}

function Get-CcStoreInventory {
    param([string]$SourceRoot)
    $dirs = New-Object 'System.Collections.Generic.List[object]'
    $files = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    $entries = [long]0
    Add-CcStoreTreeInventory -SourceRoot $SourceRoot -TreePath (Join-Path $SourceRoot 'config\cc-switch\home\.cc-switch') -Directories $dirs -Files $files -Seen $seen -TotalBytes ([ref]$total) -EntryCount ([ref]$entries)
    Add-CcStoreTreeInventory -SourceRoot $SourceRoot -TreePath (Join-Path $SourceRoot 'harness\cc-switch') -Directories $dirs -Files $files -Seen $seen -TotalBytes ([ref]$total) -EntryCount ([ref]$entries)
    if ($dirs.Count -eq 0) { throw 'The source has neither supported CC Switch data tree.' }
    return [pscustomobject]@{ Directories = $dirs; Files = $files; TotalBytes = $total; EntryCount = $entries }
}

function Copy-CcStoreFileAndHash {
    param([string]$Source, [string]$Destination, [long]$ExpectedLength)
    $input = $null; $output = $null; $sha = $null
    try {
        $input = New-Object IO.FileStream($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
        if ($input.Length -ne $ExpectedLength -or $input.Length -gt $script:CcStoreMaxBytes) { throw 'A source file changed size after the stopped-tree scan.' }
        $output = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::SequentialScan)
        $sha = [Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 65536
        $readTotal = [long]0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $readTotal += $read
            if ($readTotal -gt $ExpectedLength -or $readTotal -gt $script:CcStoreMaxBytes) { throw 'A source file exceeded the stopped-tree byte budget.' }
            $sha.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
            $output.Write($buffer, 0, $read)
        }
        $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
        if ($readTotal -ne $ExpectedLength -or $input.Length -ne $ExpectedLength) { throw 'A source file changed while being read.' }
        $output.Flush($true)
        return ([pscustomobject]@{ Length = $readTotal; Sha256 = [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant() })
    } finally { if ($input) { $input.Dispose() }; if ($output) { $output.Dispose() }; if ($sha) { $sha.Dispose() } }
}

function Assert-CcStoreManifest {
    param([object]$Manifest)
    if ($null -eq $Manifest -or $Manifest -isnot [pscustomobject] -or $Manifest.Format -ne $script:CcStoreVersion -or [string]$Manifest.Revision -notmatch '^[0-9a-f]{32}$') {
        throw 'The current CC Switch snapshot manifest is invalid.'
    }
    if ($null -eq $Manifest.Directories -or $null -eq $Manifest.Files) { throw 'The current CC Switch snapshot manifest is incomplete.' }
    if (@($Manifest.Files).Count -gt $script:CcStoreMaxFiles -or (@($Manifest.Files).Count + @($Manifest.Directories).Count) -gt $script:CcStoreMaxEntries) { throw 'The snapshot exceeds supported inventory limits.' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in @($Manifest.Directories)) {
        $rel = [string]$relative
        Assert-CcStoreRelativePath $rel
        if (Test-CcStoreExcludedEntry -Name (Split-Path -Leaf $rel) -IsDirectory $true) { throw 'Snapshot includes an excluded transient directory.' }
        if (-not $seen.Add($rel)) { throw 'Snapshot contains duplicate or case-conflicting paths.' }
        $dirs.Add($rel) | Out-Null
    }
    $sum = [long]0
    foreach ($file in @($Manifest.Files)) {
        if ($null -eq $file -or $file -isnot [pscustomobject]) { throw 'Snapshot contains an invalid file record.' }
        $rel = [string]$file.RelativePath
        Assert-CcStoreRelativePath $rel
        if (Test-CcStoreExcludedEntry -Name (Split-Path -Leaf $rel) -IsDirectory $false) { throw 'Snapshot includes an excluded transient file.' }
        if (-not $seen.Add($rel)) { throw 'Snapshot contains duplicate or case-conflicting paths.' }
        $length = 0L
        if (-not [long]::TryParse([string]$file.Length, [ref]$length) -or $length -lt 0 -or $length -gt $script:CcStoreMaxBytes - $sum) { throw 'Snapshot exceeds the byte limit.' }
        if ([string]$file.Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Snapshot contains an invalid file hash.' }
        $sum += $length
        $parent = [IO.Path]::GetDirectoryName($rel.Replace('/', '\')).Replace('\', '/')
        if ($parent -notin @('config/cc-switch/home/.cc-switch', 'harness/cc-switch') -and -not $dirs.Contains($parent)) { throw 'Snapshot file parent directory is missing from its manifest.' }
    }
    foreach ($rel in @($Manifest.Directories)) {
        $parent = [IO.Path]::GetDirectoryName(([string]$rel).Replace('/', '\')).Replace('\', '/')
        if ($parent -notin @('config/cc-switch/home', 'harness', 'config/cc-switch/home/.cc-switch', 'harness/cc-switch') -and -not $dirs.Contains($parent)) { throw 'Snapshot directory parent is missing from its manifest.' }
    }
    return [pscustomobject]@{ FileCount = @($Manifest.Files).Count; DirectoryCount = @($Manifest.Directories).Count; TotalBytes = $sum }
}

function Read-CcStoreCurrent {
    param([object]$Paths, [switch]$AllowTransactionBackup)
    Assert-CcStoreNoReparse $Paths.StoreRoot
    if ((Test-Path -LiteralPath $Paths.CurrentBackupPath) -and -not $AllowTransactionBackup) { throw 'CC Switch store has an unfinished current-pointer transaction; manual recovery is required.' }
    if (-not (Test-Path -LiteralPath $Paths.CurrentPath -PathType Leaf)) { return $null }
    Assert-CcStoreNoReparse $Paths.CurrentPath
    $pointerBytes = Read-CcStoreFileBytesLimited -Path $Paths.CurrentPath -Limit 65536
    $raw = [Text.Encoding]::UTF8.GetString($pointerBytes)
    if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'CC Switch store pointer must be a JSON object.' }
    $pointer = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $pointer -or $pointer -isnot [pscustomobject] -or $pointer.Format -ne $script:CcStoreVersion -or [string]$pointer.CurrentRevision -notmatch '^[0-9a-f]{32}$' -or [string]$pointer.ManifestSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'CC Switch store pointer is invalid.'
    }
    if ($pointer.PreviousRevision -and [string]$pointer.PreviousRevision -notmatch '^[0-9a-f]{32}$') { throw 'CC Switch store previous revision is invalid.' }
    return $pointer
}

function Get-CcStoreGeneration {
    param([object]$Paths, [object]$Pointer)
    if ($null -eq $Pointer) { throw 'No successful CC Switch snapshot exists.' }
    $generation = Join-Path $Paths.GenerationsRoot ([string]$Pointer.CurrentRevision)
    Assert-CcStoreNoReparse $generation
    $manifestPath = Join-Path $generation 'manifest.json'
    Assert-CcStoreNoReparse $manifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The current CC Switch snapshot manifest is missing.' }
    $item = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($item.Length -gt $script:CcStoreMaxManifestBytes) { throw 'The CC Switch manifest exceeds the safety limit.' }
    $bytes = Read-CcStoreFileBytesLimited -Path $manifestPath -Limit $script:CcStoreMaxManifestBytes
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($hash -ne [string]$Pointer.ManifestSha256) { throw 'The current CC Switch snapshot manifest checksum is invalid.' }
    $manifest = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.Revision -ne [string]$Pointer.CurrentRevision) { throw 'Snapshot revision does not match the current pointer.' }
    $limits = Assert-CcStoreManifest $manifest
    foreach ($relative in @($manifest.Directories)) {
        $path = Join-Path (Join-Path $generation 'payload') ([string]$relative.Replace('/', '\'))
        Assert-CcStoreNoReparse $path
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'A directory listed in the snapshot is missing.' }
    }
    $actualSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in @($manifest.Directories)) { $actualSet.Add('D:' + [string]$dir) | Out-Null }
    foreach ($file in @($manifest.Files)) {
        $path = Join-Path (Join-Path $generation 'payload') ([string]$file.RelativePath.Replace('/', '\'))
        Assert-CcStoreNoReparse $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A file listed in the snapshot is missing.' }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.Length -ne [long]$file.Length) { throw 'Snapshot file length does not match its manifest.' }
        $actualSet.Add('F:' + [string]$file.RelativePath) | Out-Null
    }
    $payloadRoot = Join-Path $generation 'payload'
    foreach ($top in @('config\cc-switch\home\.cc-switch', 'harness\cc-switch')) {
        $tree = Join-Path $payloadRoot $top
        if (Test-Path -LiteralPath $tree -PathType Container) {
            $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($tree)
            while ($pending.Count -gt 0) {
                $current = $pending.Pop()
                foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current, '*', [IO.SearchOption]::TopDirectoryOnly)) {
                    Assert-CcStoreNoReparse $child
                    $relative = Get-CcStoreRelativePath -Root $payloadRoot -Path $child
                    $childItem = Get-Item -LiteralPath $child -Force -ErrorAction Stop
                    $key = $(if ($childItem.PSIsContainer) { 'D:' } else { 'F:' }) + $relative
                    if (-not $actualSet.Contains($key)) { throw 'Snapshot contains an unlisted payload path.' }
                    if ($childItem.PSIsContainer) { $pending.Push($child) }
                }
            }
        }
    }
    return [pscustomobject]@{ GenerationRoot = $generation; PayloadRoot = $payloadRoot; Manifest = $manifest; Limits = $limits }
}

function Test-CcStoreFileHash {
    param([string]$Path, [long]$ExpectedLength, [string]$ExpectedHash)
    $input = $null; $sha = $null
    try {
        $input = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
        if ($input.Length -ne $ExpectedLength) { return $false }
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash($input)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant() -eq $ExpectedHash)
    } finally { if ($input) { $input.Dispose() }; if ($sha) { $sha.Dispose() } }
}

function Read-CcStoreFileBytesLimited {
    param([string]$Path, [long]$Limit)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
        if ($stream.Length -lt 0 -or $stream.Length -gt $Limit -or $stream.Length -gt [int]::MaxValue) { throw 'A CC Switch metadata file exceeds its size limit.' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'A CC Switch metadata file changed while it was read.' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'A CC Switch metadata file grew while it was read.' }
        return ,$bytes
    } finally { if ($stream) { $stream.Dispose() } }
}

function Copy-CcStoreFileVerified {
    param([string]$Source, [string]$Destination, [long]$Length, [string]$Hash, [System.Collections.Generic.List[string]]$CreatedFiles)
    $input = $null; $output = $null; $sha = $null
    try {
        $input = New-Object IO.FileStream($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
        if ($input.Length -ne $Length) { throw 'A snapshot file changed before restore.' }
        $output = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::SequentialScan)
        if ($CreatedFiles) { $CreatedFiles.Add($Destination) }
        $sha = [Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 65536; $total = [long]0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $Length -or $total -gt $script:CcStoreMaxBytes) { throw 'A snapshot file exceeded its declared length.' }
            $sha.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
            $output.Write($buffer, 0, $read)
        }
        $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
        $actual = [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
        if ($total -ne $Length -or $input.Length -ne $Length -or $actual -ne $Hash) { throw 'A snapshot file failed integrity validation during restore.' }
        $output.Flush($true)
    } finally { if ($input) { $input.Dispose() }; if ($output) { $output.Dispose() }; if ($sha) { $sha.Dispose() } }
}

function Remove-CcStoreOwnedTree {
    param([string]$Path, [string]$ParentRoot)
    if (-not (Test-CcStorePathWithin -Path $Path -Root $ParentRoot) -or [string]::Equals((ConvertTo-CcStoreFullPath $Path), (ConvertTo-CcStoreFullPath $ParentRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clean outside an owned temporary root.' }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-CcStoreNoReparse $Path
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ Path = $Path; Visited = $false })
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $current = [string]$node.Path
        if (-not (Test-CcStorePathWithin -Path $current -Root $ParentRoot)) { throw 'An owned cleanup node escaped its parent.' }
        Assert-CcStoreNoReparse $current
        if (-not $node.Visited) {
            $stack.Push([pscustomobject]@{ Path = $current; Visited = $true })
            $children = New-Object 'System.Collections.Generic.List[object]'
            $enumerator = [IO.Directory]::EnumerateFileSystemEntries($current, '*', [IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
            try { while ($enumerator.MoveNext()) { $children.Add([string]$enumerator.Current) } }
            finally { if ($enumerator -is [IDisposable]) { $enumerator.Dispose() } }
            foreach ($child in $children) {
                if (-not (Test-CcStorePathWithin -Path $child -Root $Path)) { throw 'An owned cleanup child escaped its root.' }
                Assert-CcStoreNoReparse $child
                $item = Get-Item -LiteralPath $child -Force -ErrorAction Stop
                if ($item.PSIsContainer) { $stack.Push([pscustomobject]@{ Path = $child; Visited = $false }) }
                else { [IO.File]::Delete($child) }
            }
        } else { [IO.Directory]::Delete($current, $false) }
    }
}

function Remove-CcStoreOldGenerations {
    param([object]$Paths, [string]$CurrentRevision, [string]$PreviousRevision)
    $removed = 0
    if (-not (Test-Path -LiteralPath $Paths.GenerationsRoot -PathType Container)) { return $removed }
    foreach ($generation in [IO.Directory]::EnumerateDirectories($Paths.GenerationsRoot, '*', [IO.SearchOption]::TopDirectoryOnly)) {
        $name = [IO.Path]::GetFileName($generation)
        if ($name -notmatch '^[0-9a-f]{32}$' -or $name -eq $CurrentRevision -or ($PreviousRevision -and $name -eq $PreviousRevision)) { continue }
        try { Remove-CcStoreOwnedTree -Path $generation -ParentRoot $Paths.GenerationsRoot; $removed++ } catch { }
    }
    return $removed
}

function Test-CcStoreRecoveryArtifacts {
    param([object]$Paths)
    if (Test-Path -LiteralPath $Paths.CurrentBackupPath) { return $true }
    if (Test-Path -LiteralPath $Paths.StoreRoot -PathType Container) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Paths.StoreRoot, '*', [IO.SearchOption]::TopDirectoryOnly)) {
            $name = [IO.Path]::GetFileName($entry)
            if ($name -like 'current.*.tmp' -or $name -like '.cc-switch-checkpoint-*') { return $true }
        }
    }
    if (Test-Path -LiteralPath $Paths.GenerationsRoot -PathType Container) {
        foreach ($entry in [IO.Directory]::EnumerateDirectories($Paths.GenerationsRoot, '.staging-*', [IO.SearchOption]::TopDirectoryOnly)) { return $true }
    }
    return $false
}

function Ensure-CcStoreDirectoryTracked {
    param([string]$Path, [string]$OwnedRoot, [System.Collections.Generic.List[string]]$CreatedDirectories, [System.Collections.Generic.HashSet[string]]$CreatedDirectorySet)
    $full = ConvertTo-CcStoreFullPath $Path
    $root = ConvertTo-CcStoreFullPath $OwnedRoot
    if (-not (Test-CcStorePathWithin -Path $full -Root $root)) { throw 'A restore directory escaped its owned root.' }
    $missing = New-Object 'System.Collections.Generic.Stack[string]'
    $cursor = $full
    while (-not [string]::Equals($cursor, $root, [StringComparison]::OrdinalIgnoreCase) -and -not $CreatedDirectorySet.Contains($cursor)) {
        if (Test-Path -LiteralPath $cursor) { throw 'A restore path was occupied during the write; existing content was preserved.' }
        if (-not (Test-CcStorePathWithin -Path $cursor -Root $root)) { throw 'A restore parent escaped its owned root.' }
        $missing.Push($cursor)
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { throw 'Restore directory parent is missing.' }
        $cursor = $parent
    }
    Assert-CcStoreNoReparse $cursor
    while ($missing.Count -gt 0) {
        $next = $missing.Pop()
        if (Test-Path -LiteralPath $next) { throw 'A restore path was concurrently occupied.' }
        [IO.Directory]::CreateDirectory($next) | Out-Null
        $CreatedDirectories.Add($next)
        $CreatedDirectorySet.Add($next) | Out-Null
        Assert-CcStoreNoReparse $next
    }
}

function Write-CcStoreMarker {
    param([string]$Path, [object]$Marker, [System.Collections.Generic.List[string]]$CreatedFiles)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($CreatedFiles) { $CreatedFiles.Add($Path) }
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Marker -Depth 3))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { if ($stream) { $stream.Dispose() } }
}

function Export-CcStoreProfile {
    param([object]$Paths, [object]$Snapshot)
    $profileRel = 'harness/cc-switch/claude/settings.json'
    $target = $Paths.ExportPath
    $parent = Split-Path -Parent $target
    Assert-CcStoreNoReparse $parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Assert-CcStoreNoReparse $parent
    Assert-CcStoreNoReparse $target
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($parent, '*', [IO.SearchOption]::TopDirectoryOnly)) {
        $name = [IO.Path]::GetFileName($entry)
        if ($name -like 'settings.json.*.tmp' -or $name -like 'settings.json.*.bak') { throw 'An unfinished Claude profile export transaction exists; manual recovery is required.' }
    }
    $record = @($Snapshot.Manifest.Files | Where-Object { $_.RelativePath -eq $profileRel }) | Select-Object -First 1
    if (-not $record) {
        # This fixed path is the toolbox-owned bridge projection. An invalid
        # empty-env JSON makes an older profile fail closed when the latest
        # saved snapshot intentionally has no Claude profile.
        $tempInvalid = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $backupInvalid = $null
        try {
            [IO.File]::WriteAllText($tempInvalid, '{"env":{}}', (New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $target -PathType Leaf) { $backupInvalid = $target + '.' + [guid]::NewGuid().ToString('N') + '.bak'; [IO.File]::Move($target, $backupInvalid) }
            elseif (Test-Path -LiteralPath $target) { throw 'The fixed Claude profile export path is occupied by a non-file.' }
            [IO.File]::Move($tempInvalid, $target)
            if ($backupInvalid) { Remove-Item -LiteralPath $backupInvalid -Force -ErrorAction Stop }
            return $false
        } catch {
            if ($backupInvalid -and (Test-Path -LiteralPath $backupInvalid -PathType Leaf)) {
                if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
                [IO.File]::Move($backupInvalid, $target)
            }
            throw
        } finally { if (Test-Path -LiteralPath $tempInvalid) { Remove-Item -LiteralPath $tempInvalid -Force -ErrorAction SilentlyContinue } }
    }
    $source = Join-Path $Snapshot.PayloadRoot 'harness\cc-switch\claude\settings.json'
    $temp = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $null
    try {
        $null = Copy-CcStoreFileVerified -Source $source -Destination $temp -Length ([long]$record.Length) -Hash ([string]$record.Sha256)
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backup = $target + '.' + [guid]::NewGuid().ToString('N') + '.bak'
            [IO.File]::Move($target, $backup)
        } elseif (Test-Path -LiteralPath $target) { throw 'The fixed Claude profile export path is occupied by a non-file.' }
        try {
            [IO.File]::Move($temp, $target)
            if (-not (Test-CcStoreFileHash -Path $target -ExpectedLength ([long]$record.Length) -ExpectedHash ([string]$record.Sha256))) { throw 'The exported Claude settings failed checksum verification.' }
            if ($backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop; $backup = $null }
        } catch {
            Assert-CcStoreNoReparse $target
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                if (Test-CcStoreFileHash -Path $target -ExpectedLength ([long]$record.Length) -ExpectedHash ([string]$record.Sha256)) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
                else { throw 'Profile export failed; an unrelated target appeared and was preserved.' }
            }
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) { [IO.File]::Move($backup, $target); $backup = $null }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

function Save-CcSwitchStoreSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][switch]$StoppedOnly
    )
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    if (-not $StoppedOnly) { throw 'Only an explicitly stopped CC Switch data tree can be saved; online SQLite copies are unsupported.' }
    $paths = Assert-CcStoreSafeRootPair -StickRoot $StickRoot -OtherRoot $SourceRoot
    if (-not (Test-Path -LiteralPath $paths.StickRoot -PathType Container) -or -not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw 'StickRoot and SourceRoot must exist as directories.' }
    Assert-CcStoreNoReparse $SourceRoot
    $inventory = Get-CcStoreInventory -SourceRoot $SourceRoot
    $store = $paths.StoreRoot
    Assert-CcStoreNoReparse $store
    if (-not (Test-Path -LiteralPath $store -PathType Container)) { [IO.Directory]::CreateDirectory($store) | Out-Null }
    Assert-CcStoreNoReparse $store
    if (-not (Test-Path -LiteralPath $paths.GenerationsRoot -PathType Container)) { [IO.Directory]::CreateDirectory($paths.GenerationsRoot) | Out-Null }
    Assert-CcStoreNoReparse $paths.GenerationsRoot
    $lock = $null; $stage = $null; $currentBackup = $null; $tempPointer = $null
    $newRevision = [guid]::NewGuid().ToString('N')
    try {
        $lock = New-Object IO.FileStream($paths.LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (Test-CcStoreRecoveryArtifacts -Paths $paths) { throw 'An unfinished CC Switch store transaction exists; manual recovery is required.' }
        $previous = Read-CcStoreCurrent -Paths $paths
        $stage = Join-Path $paths.GenerationsRoot ('.staging-' + $newRevision)
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $payload = Join-Path $stage 'payload'
        [IO.Directory]::CreateDirectory($payload) | Out-Null
        foreach ($directory in @($inventory.Directories | Sort-Object Depth, RelativePath)) {
            $dest = Join-Path $payload ([string]$directory.RelativePath.Replace('/', '\'))
            [IO.Directory]::CreateDirectory($dest) | Out-Null
        }
        $fileRecords = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in $inventory.Files) {
            $dest = Join-Path $payload ([string]$file.RelativePath.Replace('/', '\'))
            $result = Copy-CcStoreFileAndHash -Source $file.FullPath -Destination $dest -ExpectedLength ([long]$file.Length)
            $fileRecords.Add([pscustomobject]@{ RelativePath = $file.RelativePath; Length = $result.Length; Sha256 = $result.Sha256 })
        }
        $manifest = [ordered]@{
            Format = $script:CcStoreVersion
            Revision = $newRevision
            CreatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            Directories = @($inventory.Directories | ForEach-Object { $_.RelativePath } | Sort-Object)
            Files = @($fileRecords.ToArray())
        }
        $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 8
        $manifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($manifestJson)
        if ($manifestBytes.Length -gt $script:CcStoreMaxManifestBytes) { throw 'The CC Switch manifest exceeds the safety limit.' }
        $manifestPath = Join-Path $stage 'manifest.json'
        [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        $stageRead = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
        $manifestLimits = Assert-CcStoreManifest $stageRead
        foreach ($record in @($stageRead.Files)) {
            $stagedFile = Join-Path $payload ([string]$record.RelativePath.Replace('/', '\'))
            if (-not (Test-CcStoreFileHash -Path $stagedFile -ExpectedLength ([long]$record.Length) -ExpectedHash ([string]$record.Sha256))) { throw 'A staged file failed checksum verification.' }
        }
        $manifestSha = [Security.Cryptography.SHA256]::Create()
        try { $manifestHash = [BitConverter]::ToString($manifestSha.ComputeHash($manifestBytes)).Replace('-', '').ToLowerInvariant() } finally { $manifestSha.Dispose() }
        $generation = Join-Path $paths.GenerationsRoot $newRevision
        [IO.Directory]::Move($stage, $generation)
        $stage = $null
        $pointer = [ordered]@{
            Format = $script:CcStoreVersion
            CurrentRevision = $newRevision
            PreviousRevision = $(if ($previous) { [string]$previous.CurrentRevision } else { $null })
            ManifestSha256 = $manifestHash
            UpdatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $tempPointer = $paths.CurrentPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tempPointer, (ConvertTo-Json -InputObject $pointer -Depth 4), (New-Object Text.UTF8Encoding($false)))
        if ($previous) {
            $currentBackup = $paths.CurrentBackupPath
            [IO.File]::Move($paths.CurrentPath, $currentBackup)
        }
        try {
            [IO.File]::Move($tempPointer, $paths.CurrentPath)
            $tempPointer = $null
            $checkPointer = Read-CcStoreCurrent -Paths $paths -AllowTransactionBackup
            if ($checkPointer.CurrentRevision -ne $newRevision) { throw 'CC Switch current pointer verification failed.' }
            $committed = Get-CcStoreGeneration -Paths $paths -Pointer $checkPointer
            $profileExported = Export-CcStoreProfile -Paths $paths -Snapshot $committed
            if ($currentBackup) { Remove-Item -LiteralPath $currentBackup -Force -ErrorAction Stop; $currentBackup = $null }
            $null = Remove-CcStoreOldGenerations -Paths $paths -CurrentRevision $newRevision -PreviousRevision ([string]$pointer.PreviousRevision)
        } catch {
            if ($currentBackup -and (Test-Path -LiteralPath $currentBackup -PathType Leaf)) {
                Assert-CcStoreNoReparse $paths.CurrentPath
                if (Test-Path -LiteralPath $paths.CurrentPath -PathType Leaf) {
                    $rollbackCandidate = Read-CcStoreCurrent -Paths $paths -AllowTransactionBackup
                    if (-not $rollbackCandidate -or $rollbackCandidate.CurrentRevision -ne $newRevision) { throw 'Current pointer changed externally; the transaction backup was retained.' }
                    Remove-Item -LiteralPath $paths.CurrentPath -Force -ErrorAction Stop
                }
                [IO.File]::Move($currentBackup, $paths.CurrentPath)
                $currentBackup = $null
            } elseif (-not $previous -and (Test-Path -LiteralPath $paths.CurrentPath -PathType Leaf)) {
                $checkPointer = Read-CcStoreCurrent -Paths $paths -AllowTransactionBackup
                if ($checkPointer.CurrentRevision -eq $newRevision) { Remove-Item -LiteralPath $paths.CurrentPath -Force -ErrorAction Stop }
            }
            throw
        }
        return [pscustomobject]@{
            Revision = $newRevision
            PreviousRevision = $pointer.PreviousRevision
            FileCount = $manifestLimits.FileCount
            DirectoryCount = $manifestLimits.DirectoryCount
            TotalBytes = $manifestLimits.TotalBytes
            ProfileExported = [bool]$profileExported
            ProfileExportStatus = $(if ($profileExported) { 'Exported' } else { 'AbsentInSnapshot_Invalidated' })
            ExportPath = $paths.ExportPath
            Consistency = 'StoppedOnly'
        }
    } finally {
        if ($tempPointer -and (Test-Path -LiteralPath $tempPointer)) { Remove-Item -LiteralPath $tempPointer -Force -ErrorAction SilentlyContinue }
        if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-CcStoreOwnedTree -Path $stage -ParentRoot $paths.GenerationsRoot }
        if ($lock) { $lock.Dispose() }
    }
}

function Restore-CcSwitchStoreSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][switch]$StoppedOnly
    )
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    if (-not $StoppedOnly) { throw 'Only a saved stopped-tree snapshot can be restored; online SQLite copies are unsupported.' }
    $paths = Assert-CcStoreSafeRootPair -StickRoot $StickRoot -OtherRoot $DestinationRoot
    if (Test-CcStoreOverlap -First $paths.StickRoot -Second $DestinationRoot) { throw 'The runtime destination must be disjoint from the USB root.' }
    $pointer = Read-CcStoreCurrent -Paths $paths
    $snapshot = Get-CcStoreGeneration -Paths $paths -Pointer $pointer
    foreach ($file in @($snapshot.Manifest.Files)) {
        $path = Join-Path $snapshot.PayloadRoot ([string]$file.RelativePath.Replace('/', '\'))
        if (-not (Test-CcStoreFileHash -Path $path -ExpectedLength ([long]$file.Length) -ExpectedHash ([string]$file.Sha256))) { throw 'Snapshot contents failed integrity validation; destination was not touched.' }
    }
    $destination = ConvertTo-CcStoreFullPath $DestinationRoot
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination parent must already exist.' }
    Assert-CcStoreNoReparse $parent
    Assert-CcStoreNoReparse $destination
    $exists = Test-Path -LiteralPath $destination
    if ($exists -and -not (Test-Path -LiteralPath $destination -PathType Container)) { throw 'Destination must be a directory or absent.' }
    if ($exists) {
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($destination, '*', [IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
        try { if ($enumerator.MoveNext()) { throw 'Destination must be empty; existing contents are never overwritten.' } } finally { if ($enumerator -is [IDisposable]) { $enumerator.Dispose() } }
    }
    $stage = Join-Path $parent ('.cc-switch-restore-' + [guid]::NewGuid().ToString('N'))
    $createdDirs = New-Object 'System.Collections.Generic.List[string]'
    $createdDirSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $createdFiles = New-Object 'System.Collections.Generic.List[string]'
    if ($exists) { $createdDirSet.Add($destination) | Out-Null }
    $destinationCreated = $false
    try {
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $payloadStage = $stage
        foreach ($relative in @($snapshot.Manifest.Directories | Sort-Object { ([string]$_).Split('/').Count }, { [string]$_ })) {
            $target = Join-Path $payloadStage ([string]$relative.Replace('/', '\'))
            [IO.Directory]::CreateDirectory($target) | Out-Null
        }
        foreach ($file in @($snapshot.Manifest.Files)) {
            $target = Join-Path $payloadStage ([string]$file.RelativePath.Replace('/', '\'))
            $parentPath = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) { [IO.Directory]::CreateDirectory($parentPath) | Out-Null }
            Copy-CcStoreFileVerified -Source (Join-Path $snapshot.PayloadRoot ([string]$file.RelativePath.Replace('/', '\'))) -Destination $target -Length ([long]$file.Length) -Hash ([string]$file.Sha256)
        }
        foreach ($file in @($snapshot.Manifest.Files)) {
            $path = Join-Path $payloadStage ([string]$file.RelativePath.Replace('/', '\'))
            if (-not (Test-CcStoreFileHash -Path $path -ExpectedLength ([long]$file.Length) -ExpectedHash ([string]$file.Sha256))) { throw 'Restored staging file failed checksum validation.' }
        }
        $marker = [ordered]@{ Format = $script:CcStoreVersion; Revision = [string]$pointer.CurrentRevision; Owned = $true }
        Assert-CcStoreNoReparse $destination
        $nowExists = Test-Path -LiteralPath $destination
        if ($exists) {
            if (-not $nowExists -or -not (Test-Path -LiteralPath $destination -PathType Container)) { throw 'Destination changed while snapshot validation was running.' }
            $check = [IO.Directory]::EnumerateFileSystemEntries($destination, '*', [IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
            try { if ($check.MoveNext()) { throw 'Destination became non-empty during restore; no existing item was replaced.' } } finally { if ($check -is [IDisposable]) { $check.Dispose() } }
            Remove-CcStoreOwnedTree -Path $stage -ParentRoot $parent
            $stage = $null
            foreach ($relative in @($snapshot.Manifest.Directories | Sort-Object { ([string]$_).Split('/').Count }, { [string]$_ })) {
                $target = Join-Path $destination ([string]$relative.Replace('/', '\'))
                Ensure-CcStoreDirectoryTracked -Path $target -OwnedRoot $destination -CreatedDirectories $createdDirs -CreatedDirectorySet $createdDirSet
            }
            foreach ($file in @($snapshot.Manifest.Files)) {
                $target = Join-Path $destination ([string]$file.RelativePath.Replace('/', '\'))
                Assert-CcStoreNoReparse $target
                Copy-CcStoreFileVerified -Source (Join-Path $snapshot.PayloadRoot ([string]$file.RelativePath.Replace('/', '\'))) -Destination $target -Length ([long]$file.Length) -Hash ([string]$file.Sha256) -CreatedFiles $createdFiles
            }
            Write-CcStoreMarker -Path (Join-Path $destination '.cc-switch-store-owned.json') -Marker $marker -CreatedFiles $createdFiles
        } else {
            Write-CcStoreMarker -Path (Join-Path $stage '.cc-switch-store-owned.json') -Marker $marker
            [IO.Directory]::Move($stage, $destination)
            $stage = $null
            $destinationCreated = $true
        }
        return [pscustomobject]@{
            Revision = [string]$pointer.CurrentRevision
            FileCount = $snapshot.Limits.FileCount
            DirectoryCount = $snapshot.Limits.DirectoryCount
            TotalBytes = $snapshot.Limits.TotalBytes
            DestinationRoot = $destination
            RequiresContextPathRegeneration = $true
            Consistency = 'StoppedOnly'
        }
    } catch {
        for ($i = $createdFiles.Count - 1; $i -ge 0; $i--) {
            $file = $createdFiles[$i]
            if (Test-Path -LiteralPath $file) { Assert-CcStoreNoReparse $file; if (Test-CcStorePathWithin -Path $file -Root $destination) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } }
        }
        foreach ($dir in @($createdDirs.ToArray()) | Sort-Object Length -Descending) {
            if (Test-Path -LiteralPath $dir -PathType Container) {
                Assert-CcStoreNoReparse $dir
                if (Test-CcStorePathWithin -Path $dir -Root $destination) { try { [IO.Directory]::Delete($dir, $false) } catch { } }
            }
        }
        if ($destinationCreated -and (Test-Path -LiteralPath $destination)) { Remove-CcStoreOwnedTree -Path $destination -ParentRoot $parent }
        throw
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-CcStoreOwnedTree -Path $stage -ParentRoot $parent }
    }
}

function Get-CcSwitchStoreStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $paths = Get-CcStorePaths $StickRoot
    Assert-CcStoreNoReparse $paths.StoreRoot
    if (Test-CcStoreRecoveryArtifacts -Paths $paths) {
        return [pscustomobject]@{ Status = 'RecoveryRequired'; CurrentRevision = $null; PreviousRevision = $null; GenerationCount = 0; Consistency = 'StoppedOnly' }
    }
    $pointer = Read-CcStoreCurrent -Paths $paths
    $count = 0
    if (Test-Path -LiteralPath $paths.GenerationsRoot -PathType Container) { foreach ($nullEntry in [IO.Directory]::EnumerateDirectories($paths.GenerationsRoot, '*', [IO.SearchOption]::TopDirectoryOnly)) { $count++ } }
    if (-not $pointer) { return [pscustomobject]@{ Status = 'Absent'; CurrentRevision = $null; PreviousRevision = $null; GenerationCount = $count; Consistency = 'StoppedOnly' } }
    $snapshot = Get-CcStoreGeneration -Paths $paths -Pointer $pointer
    return [pscustomobject]@{
        Status = 'Present'
        CurrentRevision = [string]$pointer.CurrentRevision
        PreviousRevision = $pointer.PreviousRevision
        FileCount = $snapshot.Limits.FileCount
        DirectoryCount = $snapshot.Limits.DirectoryCount
        TotalBytes = $snapshot.Limits.TotalBytes
        GenerationCount = $count
        ExportPath = $paths.ExportPath
        Consistency = 'StoppedOnly'
    }
}

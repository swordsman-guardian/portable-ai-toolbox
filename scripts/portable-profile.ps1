# Encrypted, opt-in snapshots of stopped application configuration directories.
# Windows PowerShell 5.1 / .NET Framework 4.7.2+. Dot-source this file.
# SQLite databases must be closed and stopped before snapshotting; copying a live
# SQLite directory is unsupported and can produce an inconsistent snapshot.
Set-StrictMode -Version Latest

$script:PortableProfileFormat = 'portable-application-profile'
$script:PortableProfileVersion = 1
$script:PortableProfileMaxBytes = 16MB
$script:PortableProfileMaxFiles = 512
$script:PortableProfileMaxTreeEntries = 2048
$script:PortableProfileMaxDepth = 32
$script:PortableProfileVaultKey = 'portable-profile-payload'

if (-not (Get-Command Write-PortableVault -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'vault.ps1')
}

function Get-PortableProfileFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '路径不能为空。' }
    return [IO.Path]::GetFullPath($Path.Trim())
}

function Test-PortableProfilePathWithin {
    param([string]$Path, [string]$Root)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $r = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    return $p.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}

function Test-PortableProfileDirectoryEmpty {
    param([Parameter(Mandatory)][string]$Path)
    $enumerator = ([IO.Directory]::EnumerateFileSystemEntries($Path)).GetEnumerator()
    try { return (-not $enumerator.MoveNext()) }
    finally { if ($enumerator -is [IDisposable]) { $enumerator.Dispose() } }
}

function Assert-PortableProfileNoReparse {
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeChildren)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $a = [IO.File]::GetAttributes($current)
            if (($a -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '路径中包含重解析点，已拒绝访问。' }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    if ($IncludeChildren -and [IO.Directory]::Exists($full)) {
        $stack = New-Object 'System.Collections.Generic.Stack[object]'; $stack.Push([pscustomobject]@{Path=$full;Depth=0})
        $count = 0
        while ($stack.Count -gt 0) {
            $node = $stack.Pop(); $dir=$node.Path
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $count++
                if ($count -gt $script:PortableProfileMaxTreeEntries) { throw '配置目录超过 2048 个目录项的扫描限制。' }
                $a = [IO.File]::GetAttributes($entry)
                if (($a -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '目录子项包含重解析点，已拒绝访问。' }
                if (($a -band [IO.FileAttributes]::Directory) -ne 0) {
                    if (($node.Depth + 1) -gt $script:PortableProfileMaxDepth) { throw '配置目录超过 32 层深度限制。' }
                    $stack.Push([pscustomobject]@{Path=$entry;Depth=$node.Depth+1})
                }
            }
        }
    }
}

function Test-PortableProfileRoot {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    return [string]::Equals([IO.Path]::GetFullPath($Path).TrimEnd('\'),$root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
}

function Get-PortableProfileRelativeFiles {
    param([Parameter(Mandatory)][string]$Root)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $total = [int64]0
    $stack = New-Object 'System.Collections.Generic.Stack[object]'; $stack.Push([pscustomobject]@{Path=$Root;Depth=0})
    $treeEntries = 0
    while ($stack.Count -gt 0) {
        $node = $stack.Pop(); $dir=$node.Path
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $treeEntries++
            if ($treeEntries -gt $script:PortableProfileMaxTreeEntries) { throw '配置目录超过 2048 个目录项的扫描限制。' }
            $a = [IO.File]::GetAttributes($entry)
            if (($a -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '配置目录包含重解析点，已拒绝快照。' }
            if (($a -band [IO.FileAttributes]::Directory) -ne 0) {
                if (($node.Depth + 1) -gt $script:PortableProfileMaxDepth) { throw '配置目录超过 32 层深度限制。' }
                $stack.Push([pscustomobject]@{Path=$entry;Depth=$node.Depth+1}); continue
            }
            $info = New-Object IO.FileInfo($entry)
            $relative = $entry.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\','/')
            Assert-PortableProfileRelativePath -Path $relative
            $total += $info.Length
            if ($files.Count -ge $script:PortableProfileMaxFiles -or $total -gt $script:PortableProfileMaxBytes) { throw '配置快照超过 512 个文件或 16 MiB 原始数据的限制。' }
            $files.Add([pscustomobject]@{ Path=$relative; FullPath=$entry; Length=$info.Length })
        }
    }
    return ,@{ Files=$files; TotalBytes=$total }
}

function ConvertTo-PortableProfilePayload {
    param([Parameter(Mandatory)][string]$SourceRoot)
    $scan = Get-PortableProfileRelativeFiles -Root $SourceRoot
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $total = [int64]0
    $buffer = New-Object byte[] 65536
    foreach ($file in $scan.Files) {
        Assert-PortableProfileNoReparse -Path $file.FullPath
        $fs = [IO.File]::Open($file.FullPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $bytes = $null
        try {
            $length = $fs.Length
            if ($length -gt $script:PortableProfileMaxBytes -or ($total + $length) -gt $script:PortableProfileMaxBytes) { throw '配置快照超过 16 MiB 原始数据限制。' }
            $bytes = New-Object byte[] ([int]$length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $want = [Math]::Min($buffer.Length,$bytes.Length-$offset)
                $read = $fs.Read($buffer,0,$want)
                if ($read -le 0) { throw '读取配置文件时文件大小发生变化；请停止应用写入后重试。' }
                [Array]::Copy($buffer,0,$bytes,$offset,$read); $offset += $read
            }
            if ($fs.ReadByte() -ne -1) { throw '读取配置文件时文件大小发生变化；请停止应用写入后重试。' }
            $total += $bytes.LongLength
            $entries.Add([pscustomobject]@{ path=$file.Path; data=[Convert]::ToBase64String($bytes) })
        } finally {
            $fs.Dispose()
            if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
        }
    }
    [Array]::Clear($buffer,0,$buffer.Length)
    $payload = [ordered]@{ format=$script:PortableProfileFormat; version=$script:PortableProfileVersion; files=@($entries.ToArray()) }
    return (ConvertTo-Json -InputObject $payload -Depth 5 -Compress)
}

function Save-PortableProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$SourceRoot,
        [AllowNull()][string]$ExpectedRevision
    )
    $vaultPath = Get-PortableProfileFullPath $Path
    $source = Get-PortableProfileFullPath $SourceRoot
    if (Test-PortableProfileRoot $source) { throw '不能将磁盘根目录作为配置源。' }
    if (Test-PortableProfileRoot $vaultPath) { throw '快照路径不能是磁盘根目录。' }
    Assert-PortableProfileNoReparse -Path $vaultPath
    Assert-PortableProfileNoReparse -Path $source -IncludeChildren
    if (-not [IO.Directory]::Exists($source)) { throw '配置源目录不存在。' }
    if ((Test-PortableProfilePathWithin $source $vaultPath) -or (Test-PortableProfilePathWithin $vaultPath $source)) { throw '配置源目录与快照文件不能重叠。' }
    if (-not [IO.Directory]::Exists((Split-Path -Parent $vaultPath))) { throw '快照所在目录不存在。' }
    if ([IO.File]::Exists($vaultPath)) {
        $current = Read-PortableVault -Path $vaultPath -Password $Password
        try {
            if ([string]::IsNullOrWhiteSpace($ExpectedRevision)) { throw '更新配置快照必须提供已读取的 Revision。' }
            if ($current.Revision -cne $ExpectedRevision.ToLowerInvariant()) { throw '配置快照已由其他操作更新；请重新读取后再保存。' }
        } finally { $current.Secrets.Clear() }
    }
    $payloadText = ConvertTo-PortableProfilePayload -SourceRoot $source
    $payloadObject = $payloadText | ConvertFrom-Json -ErrorAction Stop
    $fileCount = @($payloadObject.files).Count
    $payloadObject = $null
    $payloadBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payloadText)
    if ($payloadBytes.Length -gt 36MB) { [Array]::Clear($payloadBytes,0,$payloadBytes.Length); throw '序列化快照超过保险箱容量。' }
    $secrets = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $secrets.Add($script:PortableProfileVaultKey,[Convert]::ToBase64String($payloadBytes))
    [Array]::Clear($payloadBytes,0,$payloadBytes.Length); $payloadText = $null
    try {
        $revision = Write-PortableVault -Path $vaultPath -Password $Password -Secrets $secrets -ExpectedRevision $ExpectedRevision
        return [pscustomobject]@{ Path=$vaultPath; Revision=$revision; FileCount=$fileCount }
    } finally { $secrets.Clear() }
}

function Assert-PortableProfileRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1024 -or $Path.Contains('\') -or $Path.StartsWith('/') -or $Path.Contains(':')) { throw '快照包含无效相对路径。' }
    $parts = $Path.Split('/')
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '[<>"|?*]' -or $part -match '[\x00-\x1f]') { throw '快照包含无效相对路径。' }
        $stem = ($part -split '\.',2)[0]
        if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw '快照包含 Windows 保留文件名。' }
    }
}

function Write-PortableProfileStreamBytes {
    param([Parameter(Mandatory)][IO.FileStream]$Stream,[Parameter(Mandatory)][byte[]]$Bytes)
    $Stream.Write($Bytes,0,$Bytes.Length)
    $Stream.Flush($true)
}

function Read-PortableProfilePayload {
    param([string]$Path,[Security.SecureString]$Password)
    $read = Read-PortableVault -Path $Path -Password $Password
    $encoded = $null; $bytes = $null; $text = $null
    $files = New-Object 'System.Collections.Generic.List[object]'
    try {
        if (-not $read.Secrets.ContainsKey($script:PortableProfileVaultKey)) { throw '加密文件不是受支持的配置快照。' }
        $encoded = $read.Secrets[$script:PortableProfileVaultKey]
        $bytes = [Convert]::FromBase64String($encoded)
        $text = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
        $obj = $text | ConvertFrom-Json -ErrorAction Stop
        if ($obj.format -cne $script:PortableProfileFormat -or [int]$obj.version -ne $script:PortableProfileVersion) { throw '配置快照格式或版本无效。' }
        $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total = [int64]0
        foreach ($entry in @($obj.files)) {
            if ($files.Count -ge $script:PortableProfileMaxFiles) { throw '配置快照超过文件数量限制。' }
            $rel = [string]$entry.path; Assert-PortableProfileRelativePath $rel
            if (($rel.Split('/').Length - 1) -gt $script:PortableProfileMaxDepth) { throw '快照目录超过 32 层深度限制。' }
            if (-not $names.Add($rel)) { throw '配置快照包含重复或大小写冲突的路径。' }
            $data = [Convert]::FromBase64String([string]$entry.data)
            $total += $data.LongLength
            if ($total -gt $script:PortableProfileMaxBytes) { throw '配置快照超过原始数据大小限制。' }
            $files.Add([pscustomobject]@{ Path=$rel; Bytes=$data })
        }
        $directoryNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $files) {
            $parents = @(); $p = $entry.Path
            while ($p.Contains('/')) { $p = $p.Substring(0,$p.LastIndexOf('/')); $parents += $p }
            foreach ($parent in $parents) {
                if ($names.Contains($parent)) { throw '配置快照文件与目录路径冲突。' }
                [void]$directoryNames.Add($parent)
            }
        }
        if (($files.Count + $directoryNames.Count) -gt $script:PortableProfileMaxTreeEntries) { throw '快照超过 2048 个目录项的恢复限制。' }
        return [pscustomobject]@{ Files=$files; TotalBytes=$total; Revision=$read.Revision; Secrets=$read.Secrets; Text=$text; Encoded=$encoded; Bytes=$bytes }
    } catch {
        foreach ($entry in $files) { if ($entry.Bytes) { [Array]::Clear($entry.Bytes,0,$entry.Bytes.Length) } }
        if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
        $read.Secrets.Clear()
        throw
    }
}

function Restore-PortableProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][Security.SecureString]$Password,[Parameter(Mandatory)][string]$DestinationRoot)
    $vaultPath = Get-PortableProfileFullPath $Path
    $destination = Get-PortableProfileFullPath $DestinationRoot
    if (Test-PortableProfileRoot $destination) { throw '不能恢复到磁盘根目录。' }
    Assert-PortableProfileNoReparse -Path $vaultPath
    Assert-PortableProfileNoReparse -Path $destination
    if ((Test-PortableProfilePathWithin $destination $vaultPath) -or (Test-PortableProfilePathWithin $vaultPath $destination)) { throw '目标目录与快照文件不能重叠。' }
    if ([IO.File]::Exists($destination)) { throw '恢复目标已存在同名文件。' }
    if ([IO.Directory]::Exists($destination) -and -not (Test-PortableProfileDirectoryEmpty -Path $destination)) { throw '恢复目标目录必须不存在或为空。' }
    $verified = Read-PortableProfilePayload -Path $vaultPath -Password $Password
    $createdRoot = $false; $createdDirs = New-Object 'System.Collections.Generic.List[string]'; $createdFiles = New-Object 'System.Collections.Generic.List[string]'
    try {
        Assert-PortableProfileNoReparse -Path $destination
        if ([IO.File]::Exists($destination)) { throw '解密期间恢复目标被其他程序创建，已停止。' }
        if ([IO.Directory]::Exists($destination) -and -not (Test-PortableProfileDirectoryEmpty -Path $destination)) { throw '解密期间恢复目标已变为非空目录，已停止。' }
        if (-not [IO.Directory]::Exists($destination)) { [IO.Directory]::CreateDirectory($destination) | Out-Null; $createdRoot = $true }
        foreach ($entry in $verified.Files) {
            $target = [IO.Path]::GetFullPath((Join-Path $destination ($entry.Path.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if (-not (Test-PortableProfilePathWithin $target $destination) -or $target.Equals($destination,[StringComparison]::OrdinalIgnoreCase)) { throw '快照路径越出恢复目录。' }
            $parent = Split-Path -Parent $target
            $missing = New-Object 'System.Collections.Generic.Stack[string]'; $walk=$parent
            while (-not [IO.Directory]::Exists($walk)) { $missing.Push($walk); $walk=Split-Path -Parent $walk; if (-not $walk) { throw '恢复目录父路径无效。' } }
            while ($missing.Count -gt 0) { $d=$missing.Pop(); Assert-PortableProfileNoReparse -Path $d; [IO.Directory]::CreateDirectory($d) | Out-Null; $createdDirs.Add($d) }
            Assert-PortableProfileNoReparse -Path $parent
            if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw '恢复期间目标路径已被创建，已停止。' }
            $fs = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $createdFiles.Add($target)
            try { Write-PortableProfileStreamBytes -Stream $fs -Bytes $entry.Bytes } finally { $fs.Dispose() }
        }
        return [pscustomobject]@{ DestinationRoot=$destination; Revision=$verified.Revision; FileCount=$verified.Files.Count; PlainBytes=$verified.TotalBytes }
    } catch {
        foreach ($f in $createdFiles) {
            try {
                if ((Test-PortableProfilePathWithin $f $destination) -and -not $f.Equals($destination,[StringComparison]::OrdinalIgnoreCase)) {
                    Assert-PortableProfileNoReparse -Path $destination
                    Assert-PortableProfileNoReparse -Path $f
                    if ([IO.File]::Exists($f) -and -not [IO.Directory]::Exists($f)) { [IO.File]::Delete($f) }
                }
            } catch {}
        }
        for ($i=$createdDirs.Count-1; $i -ge 0; $i--) { try { $d=$createdDirs[$i]; Assert-PortableProfileNoReparse -Path $d; if ([IO.Directory]::Exists($d) -and (Test-PortableProfileDirectoryEmpty -Path $d)) { [IO.Directory]::Delete($d) } } catch {} }
        if ($createdRoot) { try { Assert-PortableProfileNoReparse -Path $destination; if ([IO.Directory]::Exists($destination) -and (Test-PortableProfileDirectoryEmpty -Path $destination)) { [IO.Directory]::Delete($destination) } } catch {} }
        throw
    } finally {
        foreach ($entry in $verified.Files) { if ($entry.Bytes) { [Array]::Clear($entry.Bytes,0,$entry.Bytes.Length) } }
        if ($verified.Bytes) { [Array]::Clear($verified.Bytes,0,$verified.Bytes.Length) }
        $verified.Secrets.Clear(); $verified.Text=$null; $verified.Encoded=$null
    }
}

function Get-PortableProfileStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full=Get-PortableProfileFullPath $Path
    Assert-PortableProfileNoReparse -Path $full
    if (-not [IO.File]::Exists($full)) {
        $missing=Get-VaultStatus -Path $full
        return [pscustomobject]@{ Path=$full; State=$missing.State; Revision=$null; Metadata=$missing.Metadata }
    }
    $status=Get-VaultStatus -Path $full
    $bytes=Get-VaultBytes -Path $full
    return [pscustomobject]@{ Path=$full; State=$status.State; Revision=(Get-VaultRevision -Bytes $bytes); Metadata=$status.Metadata }
}

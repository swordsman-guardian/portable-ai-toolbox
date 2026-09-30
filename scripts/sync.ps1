# ============================================================
#  sync.ps1 —— 持久化搬运引擎
#
#  为什么不用 robocopy /MIR：会踩四个坑
#    ① Claude 正在追加时复制 → 读到半截文件
#    ② 文件被占用读不到
#    ③ 一轮同步里不同文件来自不同时刻，跨文件不一致
#    ④ 活跃 transcript 每轮都变 → 整个重拷（1.7MB 白搬）
#
#  分层策略（按实测的写入模式）：
#    追加型   projects/**/*.jsonl, history.jsonl  → 按字节偏移增量追加，且不收最后一行
#    重写型   .claude.json, config.json           → 写 .tmp、校验，并保留旧代到 manifest 提交
#    小文件   file-history/, plans/, tasks/ ...   → 按 mtime+size+hash 过滤；失败计入 failed
#    替换协议通过旧副本与事务标记恢复；不宣称 FAT32/断电下绝对原子
#
#  打开方式统一用 FILE_SHARE_READ|WRITE|DELETE（已实测：Claude 运行中也能读，
#  不需要管理员权限、不需要卷影副本）
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,      # Push: 本机会话目录   Pull: (未用)
    [Parameter(Mandatory)][string]$SessionsDir,    # U 盘 sessions\<主机标识>
    [ValidateSet('Push', 'Pull')][string]$Direction = 'Push',
    [string]$TargetDir,                            # Pull 时的目标目录（$S\config\claude）
    [string]$ProjectName,                          # Pull 时只拉这个项目（Claude 的路径转义名）
    [switch]$Full,                                 # Pull 时拉全部项目（慢，但绝不会漏）
    [switch]$ArchiveSet,                            # Pull: SessionsDir 是 sessions/<host> 根
    [string]$LegacySessionsDir,                     # 可选旧 sessions/<host> 单目录
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not $Quiet) { Set-ConsoleUtf8 }

# ---------- 分层清单 ----------
# 第一类：必须搬（真正的持久化）
$AppendGlobs = @( 'history.jsonl', 'projects\*\*.jsonl', 'projects\*\*\*.jsonl' )
$RewriteGlobal = @( '.claude.json', 'claude.json', 'config.json' )
$SmallDirs = @( 'file-history', 'plans', 'tasks', 'teams', 'backups' )
$SmallFiles = @( 'settings.local.json' )

# 第二类：明确不搬（缓存 / 进程级临时）—— 这里显式列出来是为了可读，
# 实际逻辑是"只搬上面第一类"，所以这些天然不会被搬
#   sessions/(按PID命名)  cache/  paste-cache/  shell-snapshots/  session-env/  ide/  debug/
#   .last-cleanup  .last-update-result.json

function Write-SyncLog {
    param([string]$Msg, [string]$Level = 'INFO')
    if ($Quiet) { return }
    Write-Log -Message $Msg -Level $Level
}

# ---------- 冷启动提示（首次全量很慢，别让人以为卡死） ----------
function Show-BulkHint {
    param([long]$TotalBytes)
    if ($TotalBytes -gt 50MB) {
        Write-SyncLog ("首次要搬 {0:N0} MB，USB 2.0 盘上可能要 1-2 分钟，请稍等..." -f ($TotalBytes/1MB)) 'WARN'
    }
}

# ---------- 找出"安全追加长度"：不复制最后一行 ----------
# jsonl 是行分隔的，只复制到最后一个 \n 为止，U 盘上就永远没有残缺行
function Get-SafeAppendLength {
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][long]$Length)
    if ($Length -le 0) { return 0 }
    # Scan backwards in bounded chunks. A file with a >64KB final line has no
    # safe bytes unless a newline is found; never return an arbitrary chunk edge.
    $buf = New-Object byte[] 65536
    $pos = $Length
    while ($pos -gt 0) {
        $n = [int][Math]::Min(65536L, $pos)
        $pos -= $n
        $Stream.Seek($pos, [IO.SeekOrigin]::Begin) | Out-Null
        $read = $Stream.Read($buf, 0, $n)
        for ($i = $read - 1; $i -ge 0; $i--) {
            if ($buf[$i] -eq 10) { return ($pos + $i + 1) }
        }
    }
    return 0L
}

# ---------- 头部指纹：检测源文件是否被整体重写 ----------
function Get-HeadHash {
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][long]$Length)
    $n = [Math]::Min(4096L, $Length)
    if ($n -le 0) { return '' }
    $Stream.Seek(0, [IO.SeekOrigin]::Begin) | Out-Null
    $buf = New-Object byte[] $n
    $read = $Stream.Read($buf, 0, $n)
    $md5 = [Security.Cryptography.MD5]::Create()
    try { return ([BitConverter]::ToString($md5.ComputeHash($buf, 0, $read))).Replace('-', '') }
    finally { $md5.Dispose() }
}

function Ensure-Dir {
    param([string]$Path)
    $d = Split-Path -Parent $Path
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Get-FileHashHex {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() }
        finally { $fs.Close() }
    } finally { $sha.Dispose() }
}

function Get-FileHashPrefixHex {
    param([string]$Path,[long]$Length)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            if ($Length -lt 0 -or $Length -gt $fs.Length) { throw "哈希长度超出文件: $Length" }
            $buf = New-Object byte[] (1MB)
            $remaining = $Length
            while ($remaining -gt 0) {
                $n = $fs.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $remaining))
                if ($n -le 0) { throw '计算哈希时文件读取不完整' }
                $sha.TransformBlock($buf, 0, $n, $buf, 0) | Out-Null
                $remaining -= $n
            }
            $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
            return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        } finally { $fs.Close() }
    } finally { $sha.Dispose() }
}

function Get-EntryContentHash {
    param($Entry)
    if ($null -eq $Entry) { return '' }
    $property = $Entry.PSObject.Properties['contentHash']
    if ($property -and $property.Value) { return [string]$property.Value }
    return ''
}

function Write-JsonDurable {
    param([string]$Path, $Value)
    Ensure-Dir $Path
    $tmp = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Copy($tmp, $Path, $true); Remove-Item -LiteralPath $tmp -Force }
    else { Move-Item -LiteralPath $tmp -Destination $Path }
}

# Recoverable replace protocol. A verified old copy and a transaction marker
# remain until the installed file verifies. This is recoverable, not a claim
# of power-loss atomicity (especially on FAT32).
function Resolve-TransactionBackupPath {
    param([string]$Path,$Transaction)
    $backup = [string]$Transaction.backup
    if (-not $backup) { return '' }
    if (-not [IO.Path]::IsPathRooted($backup)) { $backup = Join-Path (Split-Path -Parent $Path) $backup }
    $prefix = [IO.Path]::GetFullPath("$Path.sync-bak.")
    $backupFull = [IO.Path]::GetFullPath($backup)
    if (-not $backupFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "替换事务备份路径非法: $backup" }
    if (-not (Test-Path -LiteralPath $backup) -or (Get-FileHashHex $backup) -ne [string]$Transaction.oldHash) { throw "替换事务旧副本缺失或校验失败: $backup" }
    return $backup
}

function Get-ReadableTransactionPath {
    param([string]$Path,$Entry=$null)
    $marker = "$Path.sync-txn.json"
    if (-not (Test-Path -LiteralPath $marker)) { return $Path }
    try { $tx = Read-JsonFile -Path $marker } catch { throw "损坏的替换事务标记: $marker" }
    $backup = Resolve-TransactionBackupPath -Path $Path -Transaction $tx
    $expectedHash = Get-EntryContentHash $Entry
    $expectedLength = -1L
    if ($Entry) {
        $expectedLength = if ($Entry.mode -eq 'append' -and $null -ne $Entry.offset) { [long]$Entry.offset } else { [long]$Entry.size }
    }
    if ($expectedHash) {
        if ($Entry.mode -eq 'append') {
            if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge $expectedLength -and
                (Get-FileHashPrefixHex -Path $Path -Length $expectedLength) -eq $expectedHash) { return $Path }
            if ($backup -and (Get-Item -LiteralPath $backup).Length -ge $expectedLength -and
                (Get-FileHashPrefixHex -Path $backup -Length $expectedLength) -eq $expectedHash) { return $backup }
        } else {
            if ((Test-Path -LiteralPath $Path) -and (Get-FileHashHex $Path) -eq $expectedHash) { return $Path }
            if ($backup -and (Get-FileHashHex $backup) -eq $expectedHash) { return $backup }
        }
        throw "事务中没有与 committed contentHash 匹配的副本: $Path"
    } elseif ($Entry) {
        # Legacy manifests have no content hash. The transaction's old-size
        # metadata identifies the committed generation. For append files a
        # backup may include an uncommitted tail, so validate its prefix rather
        # than requiring the backup's whole length to equal the old offset.
        foreach ($candidate in @($backup, $Path)) {
            if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
            $candidateLength = (Get-Item -LiteralPath $candidate).Length
            if ($Entry.mode -eq 'append') {
                if ($candidateLength -lt $expectedLength) { continue }
                $candidateStream = Open-SharedRead -Path $candidate
                try { $safePrefix = Get-SafeAppendLength -Stream $candidateStream -Length $expectedLength } finally { $candidateStream.Close() }
                if ($safePrefix -eq $expectedLength) { return $candidate }
            } elseif ($candidateLength -eq $expectedLength) { return $candidate }
        }
        throw "事务中没有与 legacy manifest committed size 匹配的旧副本: $Path"
    }
    if ((Test-Path -LiteralPath $Path) -and (Get-FileHashHex $Path) -eq [string]$tx.newHash) { return $Path }
    if ((Test-Path -LiteralPath $Path) -and $tx.oldHash -and (Get-FileHashHex $Path) -eq [string]$tx.oldHash) { return $Path }
    if ($backup) { return $backup }
    throw "替换事务没有可验证的旧/新副本: $Path"
}

function Recover-FileReplace {
    param([string]$Dst,$CommittedEntry=$null)
    $marker = "$Dst.sync-txn.json"
    if (-not (Test-Path -LiteralPath $marker)) { return }
    try { $tx = Read-JsonFile -Path $marker } catch { throw "损坏的替换事务标记: $marker; 保留现场，未覆盖目标" }
    $backup = Resolve-TransactionBackupPath -Path $Dst -Transaction $tx
    $readPath = Get-ReadableTransactionPath -Path $Dst -Entry $CommittedEntry
    if ($readPath -ne $Dst) {
        [IO.File]::Copy($readPath, $Dst, $true)
        if ((Get-FileHashHex $Dst) -ne (Get-FileHashHex $readPath)) { throw "替换事务恢复校验失败: $Dst" }
    }
    Remove-Item -LiteralPath $marker -Force
    if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force }
}

function Install-FileRecoverable {
    param([string]$Tmp, [string]$Dst,$CommittedEntry=$null,[switch]$KeepUntilManifest)
    Ensure-Dir $Dst
    Recover-FileReplace $Dst $CommittedEntry
    $newHash = Get-FileHashHex $Tmp
    $newSize = (Get-Item -LiteralPath $Tmp).Length
    $backup = ''; $oldHash = ''; $oldSize = 0L
    if (Test-Path -LiteralPath $Dst) {
        $oldHash = Get-FileHashHex $Dst
        $oldSize = (Get-Item -LiteralPath $Dst).Length
        $backup = "$Dst.sync-bak.$([Guid]::NewGuid().ToString('N'))"
        [IO.File]::Copy($Dst, $backup, $false)
        if ((Get-FileHashHex $backup) -ne $oldHash) { throw "旧文件备份校验失败: $Dst" }
    }
    $marker = "$Dst.sync-txn.json"
    $backupName = if ($backup) { Split-Path -Leaf $backup } else { '' }
    Write-JsonDurable $marker ([pscustomobject]@{ backup=$backupName; oldHash=$oldHash; oldSize=$oldSize; newHash=$newHash; newSize=$newSize })
    if ($env:AISYNC_TEST_INTERRUPT_AFTER_MARKER -eq '1') { throw '测试注入：替换事务标记已写入' }
    [IO.File]::Copy($Tmp, $Dst, $true)
    if ((Get-FileHashHex $Dst) -ne $newHash) { throw "新文件安装校验失败: $Dst" }
    if ($KeepUntilManifest -and $env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL -eq '1') { throw '测试注入：新文件已安装，manifest 尚未提交' }
    if (-not $KeepUntilManifest) {
        Remove-Item -LiteralPath $marker -Force
        if ($backup) { Remove-Item -LiteralPath $backup -Force }
    }
    Remove-Item -LiteralPath $Tmp -Force -EA SilentlyContinue
}

function Assert-NoReparseTraversal {
    param([string]$Root,[string]$RelativePath)
    $rootFull = [IO.Path]::GetFullPath($Root)
    # Check every existing ancestor as well as descendants: TargetDir itself
    # may not exist yet while one of its parents is a junction.
    $ancestor = $rootFull
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $rootItem = Get-Item -LiteralPath $ancestor -Force
            if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "根路径含 reparse point，拒绝路径遍历: $ancestor" }
        }
        $parent = [IO.Path]::GetDirectoryName($ancestor.TrimEnd('\'))
        if (-not $parent -or $parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    $current = $rootFull
    foreach ($part in ($RelativePath -split '[\\/]')) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $it = Get-Item -LiteralPath $current -Force
            if (($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "路径包含 junction/reparse point，拒绝读写: $current" }
        }
    }
}

function Test-JsonPayload {
    param([string]$Path,[string]$RelativePath)
    $ext = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($ext -ne '.json' -and $ext -ne '.jsonl') { return }
    if ($ext -eq '.json') {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "JSON 文件为空: $RelativePath" }
        try { $null = $raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "JSON 内容无效: $RelativePath" }
        return
    }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line) { continue }
        try { $null = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw "JSONL 行内容无效: $RelativePath" }
    }
}

function Test-SafeRelativePath {
    param([string]$Rel)
    if ([string]::IsNullOrWhiteSpace($Rel) -or [IO.Path]::IsPathRooted($Rel) -or $Rel -match '[:*?"<>|]' -or $Rel -match '^[A-Za-z]:') { return $false }
    $parts = $Rel -split '[\\/]'
    if ($parts.Count -eq 0) { return $false }
    foreach ($part in $parts) { if (-not $part -or $part -eq '.' -or $part -eq '..') { return $false } }
    return $true
}

function Get-ManifestFilesValidated {
    param($Manifest, [string]$Path)
    if (-not $Manifest -or -not $Manifest.files) { throw "manifest 缺少 files: $Path" }
    foreach ($p in $Manifest.files.PSObject.Properties) {
        if (-not (Test-SafeRelativePath ([string]$p.Name))) { throw "manifest 含非法相对路径，拒绝访问: $($p.Name) ($Path)" }
        if ($null -eq $p.Value.size -or [long]$p.Value.size -lt 0) { throw "manifest 文件长度无效: $($p.Name) ($Path)" }
        $entryHash = Get-EntryContentHash $p.Value
        if ($entryHash -and $entryHash -notmatch '^[0-9a-fA-F]{64}$') { throw "manifest contentHash 无效: $($p.Name) ($Path)" }
    }
    return $Manifest.files
}

function Copy-FileShared {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst,
        [long]$Offset = 0,
        [long]$Length = -1
    )
    Ensure-Dir -Path $Dst
    $in = Open-SharedRead -Path $Src
    try {
        if ($Offset -gt 0) {
            $out = [IO.File]::Open($Dst, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        } else {
            $out = [IO.File]::Create($Dst)
        }
        try {
            if ($Offset -gt $in.Length) { throw "复制偏移超出源长度: $Offset > $($in.Length)" }
            $in.Seek($Offset, [IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] (1MB)
            $remaining = if ($Length -lt 0) { $in.Length - $Offset } else { [Math]::Min($Length, $in.Length - $Offset) }
            while ($remaining -gt 0) {
                $want = [int][Math]::Min([long]$buf.Length, $remaining)
                $n = $in.Read($buf, 0, $want)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n); $remaining -= $n
            }
            if ($remaining -ne 0) { throw '源文件在复制期间缩短或读取不完整' }
        } finally { $out.Close() }
    } finally { $in.Close() }
}

# ---------- 重写型：tmp → 校验 → 原子改名 ----------
function Sync-RewriteFile {
    param([string]$Src, [string]$Dst,$Entry=$null)
    if (-not (Test-Path -LiteralPath $Src)) { return $false }
    $raw = $null
    try {
        $fs = Open-SharedRead -Path $Src
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            try { $raw = $sr.ReadToEnd() } finally { $sr.Close() }
        } finally { try { $fs.Close() } catch { } }
    } catch {
        Write-SyncLog "重写文件读取失败: $(Split-Path $Src -Leaf)  $($_.Exception.Message)" 'WARN'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-SyncLog "重写文件为空或只有空白: $(Split-Path $Src -Leaf)" 'WARN'
        return $null
    }

    # 校验：必须是可解析的 JSON，否则这轮跳过（下轮再来）
    if ($Src -match '\.json$') {
        try { $null = $raw | ConvertFrom-Json -ErrorAction Stop } catch {
            Write-SyncLog "跳过（JSON 不完整，下轮再试）: $(Split-Path $Src -Leaf)" 'WARN'
            return $null
        }
    }

    Ensure-Dir -Path $Dst
    $tmp = "$Dst.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp, $raw, (New-Object Text.UTF8Encoding($false)))
    try {
        Install-FileRecoverable -Tmp $tmp -Dst $Dst -CommittedEntry $Entry -KeepUntilManifest
        return $true
    } catch {
        if ($env:AISYNC_TEST_INTERRUPT_AFTER_MARKER -eq '1' -or $env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL -eq '1') { throw }
        Write-SyncLog "重写文件安装失败: $(Split-Path $Src -Leaf)  $($_.Exception.Message)" 'WARN'
        return $null
    }
}

# ---------- 小文件：按 mtime+size 过滤 ----------
function Sync-SmallFile {
    param([string]$Src, [string]$Dst, $Entry)
    try {
        $si = Get-Item -LiteralPath $Src -Force
        if ($Entry -and [long]$Entry.size -eq $si.Length -and
            [string]$Entry.mtime -eq $si.LastWriteTimeUtc.ToString('o') -and (Test-Path -LiteralPath $Dst)) {
            $same = $false
            $entryHash = Get-EntryContentHash $Entry
            if ($entryHash) { $same = ((Get-FileHashHex $Dst) -eq $entryHash) }
            else { $same = ((Get-FileHashHex $Dst) -eq (Get-FileHashHex $Src)) }
            if ($same) { return $false }
        }
        $tmp = "$Dst.tmp.$([Guid]::NewGuid().ToString('N'))"
        Copy-FileShared -Src $Src -Dst $tmp -Offset 0
        Install-FileRecoverable -Tmp $tmp -Dst $Dst -CommittedEntry $Entry -KeepUntilManifest
        return $true
    } catch {
        if ($env:AISYNC_TEST_INTERRUPT_AFTER_MARKER -eq '1' -or $env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL -eq '1') { throw }
        # 单个小文件失败只跳过，不中断整轮
        Write-SyncLog "小文件失败（跳过）: $(Split-Path $Src -Leaf)  $($_.Exception.Message)" 'WARN'
        return $null
    }
}

# ---------- Claude 的项目目录名转义 ----------
# 实测规则：仅保留 [a-zA-Z0-9]，其余每个字符都变成单个 '-'
#   C:\Users\Example            -> C--Users-Example
#   C:\Users\Example\.claude\skills\math -> C--Users-Example--claude-skills-math
#   D:\新建文件夹\123          -> D--------123
# ⚠️ 中文会被压成横线，不同中文路径可能撞名 —— 所以 Pull 时若算出的目录不存在，
#    或 -Full 时，退回全量拉取。正确性优先于速度。
function Get-ProjectDirName {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -replace '[^a-zA-Z0-9]', '-')
}

function Get-ArchiveIdentity {
    param([string]$Path)
    $leaf = Split-Path -Leaf $Path
    $parent = Split-Path -Leaf (Split-Path -Parent $Path)
    if ($parent -ieq 'runs') {
        $harnessDir = Split-Path -Parent (Split-Path -Parent $Path)
        $hostDir = Split-Path -Parent $harnessDir
        return [pscustomobject]@{
            hostId = (Split-Path -Leaf $hostDir)
            harnessId = (Split-Path -Leaf $harnessDir)
            sessionId = $leaf
        }
    }
    return [pscustomobject]@{ hostId=$leaf; harnessId=''; sessionId='' }
}

function Complete-PushTransactions {
    param([string]$Root,$Files)
    foreach ($rel in $Files.Keys) {
        $entry = $Files[$rel]
        $dst = Join-Path $Root ($rel -replace '/', '\')
        $marker = "$dst.sync-txn.json"
        $entryHash = Get-EntryContentHash $entry
        if (-not (Test-Path -LiteralPath $marker) -or -not $entryHash -or -not (Test-Path -LiteralPath $dst)) { continue }
        try {
            $tx = Read-JsonFile -Path $marker
            if ($entryHash -ne [string]$tx.newHash -or (Get-FileHashHex $dst) -ne [string]$tx.newHash) { continue }
            $backup = Resolve-TransactionBackupPath -Path $dst -Transaction $tx
            Remove-Item -LiteralPath $marker -Force
            if ($backup) { Remove-Item -LiteralPath $backup -Force }
        } catch { Write-SyncLog "已提交文件的旧代副本暂未清理（保留供恢复）: $rel  $($_.Exception.Message)" 'WARN' }
    }
}

# ============================================================
#  PUSH：本机 → U 盘
# ============================================================
function Invoke-Push {
    $manifestPath = Join-Path $SessionsDir 'manifest.json'
    Recover-FileReplace $manifestPath
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try { $manifest = Read-JsonFile -Path $manifestPath } catch {
            $corruptCopy = "$manifestPath.corrupt.$(Get-Date -Format 'yyyyMMddHHmmssfff')"
            try {
                [IO.File]::Copy($manifestPath, $corruptCopy, $false)
                if ((Get-FileHashHex $manifestPath) -ne (Get-FileHashHex $corruptCopy)) { throw '备份校验失败' }
                Write-SyncLog "manifest 损坏；已校验保留副本 $corruptCopy，本轮全量重建" 'WARN'
            } catch { throw "manifest 损坏且备份失败，拒绝继续: $($_.Exception.Message)" }
        }
        if ($manifest) {
            try { $null = Get-ManifestFilesValidated -Manifest $manifest -Path $manifestPath } catch {
                $corruptCopy = "$manifestPath.invalid.$(Get-Date -Format 'yyyyMMddHHmmssfff')"
                [IO.File]::Copy($manifestPath, $corruptCopy, $false)
                if ((Get-FileHashHex $manifestPath) -ne (Get-FileHashHex $corruptCopy)) { throw "manifest 路径非法且备份校验失败: $($_.Exception.Message)" }
                Write-SyncLog "manifest 路径非法；已保留校验副本 $corruptCopy，本轮全量重建" 'WARN'
                $manifest = $null
            }
        }
    }

    $files = @{}
    if ($manifest -and $manifest.files) {
        foreach ($p in $manifest.files.PSObject.Properties) { $files[$p.Name] = $p.Value }
    }

    $stat = [ordered]@{ appended = 0; copied = 0; skipped = 0; bytes = 0L; failed = 0 }
    $bulk = 0L

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        Write-SyncLog "源目录还不存在，本轮无事可做: $SourceDir"
        return $stat
    }

    # --- 1) 追加型 ---
    $appendTargets = @()
    foreach ($g in $AppendGlobs) {
        $appendTargets += Get-ChildItem -Path (Join-Path $SourceDir $g) -File -Force -EA SilentlyContinue
    }
    foreach ($f in ($appendTargets | Sort-Object FullName -Unique)) {
        $rel = $f.FullName.Substring($SourceDir.Length).TrimStart('\')
        $dst = Join-Path $SessionsDir $rel
        $entry = if ($files.ContainsKey($rel)) { $files[$rel] } else { $null }

        $fs = $null
        try {
            Recover-FileReplace $dst $entry
            $fs = Open-SharedRead -Path $f.FullName
            $len  = $fs.Length
            $safe = Get-SafeAppendLength -Stream $fs -Length $len
            $head = Get-HeadHash -Stream $fs -Length $len

            $offset = 0L
            $needFull = $true
            if ($entry -and $entry.mode -eq 'append' -and (Test-Path -LiteralPath $dst)) {
                $offset = [long]$entry.offset
                # 源被整体重写（变短 / 头部变了）→ 从头来
                $actualLength = (Get-Item -LiteralPath $dst).Length
                if ($offset -le $safe -and $actualLength -eq $offset -and [string]$entry.headHash -eq $head) { $needFull = $false }
            }

            if ($safe -le 0) { $stat.skipped++; continue }
            if (-not $needFull -and $safe -le $offset) {
                $stat.skipped++
                $files[$rel] = [pscustomobject]@{
                    mode='append'; size=$offset; offset=$offset
                    mtime=$f.LastWriteTimeUtc.ToString('o'); headHash=$head
                    contentHash=(Get-FileHashHex $dst)
                }
                continue
            }

            if ($needFull) {
                $tmp = "$dst.tmp.$([Guid]::NewGuid().ToString('N'))"
                Copy-FileShared -Src $f.FullName -Dst $tmp -Offset 0 -Length $safe
                Install-FileRecoverable -Tmp $tmp -Dst $dst -CommittedEntry $entry -KeepUntilManifest
                $stat.copied++
                $stat.bytes += $safe
            } else {
                try {
                    Copy-FileShared -Src $f.FullName -Dst $dst -Offset $offset -Length ($safe - $offset)
                    if ((Get-Item -LiteralPath $dst).Length -ne $safe) { throw '追加后目标长度与安全偏移不一致' }
                    $stat.appended++; $stat.bytes += ($safe - $offset)
                } catch {
                    # A partial append is repaired from the source on this run.
                    $tmp = "$dst.tmp.$([Guid]::NewGuid().ToString('N'))"
                    Copy-FileShared -Src $f.FullName -Dst $tmp -Offset 0 -Length $safe
                    Install-FileRecoverable -Tmp $tmp -Dst $dst -CommittedEntry $entry -KeepUntilManifest
                    $stat.copied++; $stat.bytes += $safe
                }
            }

            $files[$rel] = [pscustomobject]@{
                mode = 'append'; size = $safe; offset = $safe
                mtime = $f.LastWriteTimeUtc.ToString('o'); headHash = $head
                contentHash = (Get-FileHashHex $dst)
            }
        } catch {
            if ($env:AISYNC_TEST_INTERRUPT_AFTER_MARKER -eq '1' -or $env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL -eq '1') { throw }
            $stat.failed++
            Write-SyncLog "追加文件失败: $rel  $($_.Exception.Message)" 'WARN'
        } finally { if ($fs) { try { $fs.Close() } catch { } } }
    }

    # --- 2) 重写型 ---
    foreach ($g in $RewriteGlobal) {
        $src = Join-Path $SourceDir $g
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $SessionsDir $g
        $entry = if ($files.ContainsKey($g)) { $files[$g] } else { $null }
        try { Recover-FileReplace $dst $entry } catch {
            $stat.failed++; Write-SyncLog "重写文件事务恢复失败: $g  $($_.Exception.Message)" 'WARN'; continue
        }
        $rewriteResult = Sync-RewriteFile -Src $src -Dst $dst -Entry $entry
        if ($null -eq $rewriteResult) { $stat.failed++; continue }
        if ($rewriteResult) {
            $stat.copied++
            $si = Get-Item -LiteralPath $src
            $archiveSize = (Get-Item -LiteralPath $dst).Length
            $stat.bytes += $archiveSize
            $files[$g] = [pscustomobject]@{
                mode = 'rewrite'; size = $archiveSize
                mtime = $si.LastWriteTimeUtc.ToString('o'); headHash = ''
                contentHash = (Get-FileHashHex $dst)
            }
        }
    }

    # --- 3) 小文件 ---
    foreach ($d in $SmallDirs) {
        $srcDir = Join-Path $SourceDir $d
        if (-not (Test-Path -LiteralPath $srcDir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force -EA SilentlyContinue)) {
            $rel = $f.FullName.Substring($SourceDir.Length).TrimStart('\')
            $dst = Join-Path $SessionsDir $rel
            $entry = if ($files.ContainsKey($rel)) { $files[$rel] } else { $null }
            try { Recover-FileReplace $dst $entry } catch {
                $stat.failed++; Write-SyncLog "小文件事务恢复失败: $rel  $($_.Exception.Message)" 'WARN'; continue
            }
            $before = $bulk
            $bulk += $f.Length
            $changed = Sync-SmallFile -Src $f.FullName -Dst $dst -Entry $entry
            if ($null -eq $changed) { $stat.failed++; continue }
            if ($changed) {
                $stat.copied++
                $stat.bytes += (Get-Item -LiteralPath $dst).Length
            } else { $stat.skipped++ }
            if (Test-Path -LiteralPath $dst) {
                $files[$rel] = [pscustomobject]@{
                    mode = 'small'; size = (Get-Item -LiteralPath $dst).Length
                    mtime = $f.LastWriteTimeUtc.ToString('o'); headHash = ''
                    contentHash = (Get-FileHashHex $dst)
                }
            }
        }
    }
    foreach ($g in $SmallFiles) {
        $src = Join-Path $SourceDir $g
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $SessionsDir $g
        $entry = if ($files.ContainsKey($g)) { $files[$g] } else { $null }
        try { Recover-FileReplace $dst $entry } catch {
            $stat.failed++; Write-SyncLog "小文件事务恢复失败: $g  $($_.Exception.Message)" 'WARN'; continue
        }
        $changed = Sync-SmallFile -Src $src -Dst $dst -Entry $entry
        if ($null -eq $changed) { $stat.failed++; continue }
        if ($changed) { $stat.copied++; $stat.bytes += (Get-Item -LiteralPath $dst).Length } else { $stat.skipped++ }
        if (Test-Path -LiteralPath $dst) { $files[$g] = [pscustomobject]@{ mode='small'; size=(Get-Item -LiteralPath $dst).Length; mtime=(Get-Item $src).LastWriteTimeUtc.ToString('o'); headHash=''; contentHash=(Get-FileHashHex $dst) } }
    }

    if ($stat.copied -gt 0 -and $stat.bytes -gt 50MB) { Show-BulkHint -TotalBytes $stat.bytes }

    # --- 写 manifest ---
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $machinePath = Join-Path $SessionsDir 'machine.json'
    $identity = Get-ArchiveIdentity -Path $SessionsDir
    $first = $now
    if (Test-Path -LiteralPath $machinePath) {
        try { $first = (Read-JsonFile -Path $machinePath).firstSeen } catch { }
    }
    $machine = [pscustomobject]@{
        computerName = $env:COMPUTERNAME
        hostId       = $identity.hostId
        harnessId    = $identity.harnessId
        sessionId    = $identity.sessionId
        firstSeen    = $first
        lastUsed     = $now
    }
    [IO.File]::WriteAllText($machinePath, ($machine | ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false)))

    $out = [pscustomobject]@{
        hostId = $identity.hostId
        harnessId = $identity.harnessId
        sessionId = $identity.sessionId
        updated = $now
        files = $files
    }
    # 先写 tmp 再改名，避免 manifest 自己坏掉
    $mpTmp = "$manifestPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($mpTmp, ($out | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Install-FileRecoverable -Tmp $mpTmp -Dst $manifestPath
    Complete-PushTransactions -Root $SessionsDir -Files $files

    return $stat
}

# ============================================================
#  PULL：U 盘 → 本机（只拉本机自己的）
# ============================================================
function Invoke-Pull {
    $stat = [ordered]@{ pulled = 0; bytes = 0L; sources = 0; conflicts = 0; failed = 0 }
    $archiveDirs = @()
    if ($ArchiveSet) {
        if (Test-Path -LiteralPath (Join-Path $SessionsDir 'manifest.json')) { $archiveDirs += $SessionsDir }
        $runs = Join-Path $SessionsDir 'runs'
        if (Test-Path -LiteralPath $runs) {
            $archiveDirs += @(Get-ChildItem -LiteralPath $runs -Directory -Force | ForEach-Object { $_.FullName })
        }
        if ($LegacySessionsDir -and (Test-Path -LiteralPath $LegacySessionsDir)) { $archiveDirs += $LegacySessionsDir }
        $archiveDirs = @($archiveDirs | Sort-Object -Unique)
    } else { $archiveDirs = @($SessionsDir) }

    $archives = @()
    foreach ($dir in $archiveDirs) {
        $manifestPath = Join-Path $dir 'manifest.json'
        $manifestCandidates = @()
        if (Test-Path -LiteralPath $manifestPath) {
            try { $manifestCandidates += (Get-ReadableTransactionPath $manifestPath) }
            catch { Write-SyncLog "manifest 替换事务无法恢复: $manifestPath ($($_.Exception.Message))" 'WARN'; $stat.failed++ }
        }
        $manifestCandidates += @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^manifest\.json\.(corrupt|invalid)\.' } | ForEach-Object { $_.FullName })
        $validCandidates = @()
        $candidateErrors = @()
        foreach ($candidatePath in @($manifestCandidates | Sort-Object -Unique)) {
            try {
                $manifest = Read-JsonFile -Path $candidatePath
                $files = Get-ManifestFilesValidated -Manifest $manifest -Path $candidatePath
                if (-not $manifest.updated) { throw '缺少 updated 时间' }
                $stamp = [DateTime]::Parse([string]$manifest.updated).ToUniversalTime()
                $validCandidates += [pscustomobject]@{ dir=$dir; path=$candidatePath; files=$files; stamp=$stamp }
            } catch { $candidateErrors += "$candidatePath ($($_.Exception.Message))" }
        }
        if ($candidateErrors.Count) { Write-SyncLog ("发现无效 manifest 候选: " + ($candidateErrors -join ' | ')) 'WARN' }
        if ($validCandidates.Count) {
            $archives += ($validCandidates | Sort-Object @{Expression={$_.stamp}}, @{Expression={$_.path}})[-1]
        } elseif ($manifestCandidates.Count -or $candidateErrors.Count) {
            $stat.failed++
            Write-SyncLog "该归档没有可验证 manifest，已跳过: $dir" 'WARN'
        } elseif ($ArchiveSet -and (($dir -eq $LegacySessionsDir) -or $dir.StartsWith(((Join-Path $SessionsDir 'runs').TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase))) {
            $stat.failed++
            Write-SyncLog "归档目录缺少 manifest，已跳过: $dir" 'WARN'
        }
    }
    $stat.sources = $archives.Count
    if (-not $archives.Count) {
        Write-SyncLog '没有有效归档 manifest，跳过反向拉取'
        return $stat
    }

    $candidates = @{}
    foreach ($arc in $archives) {
        foreach ($p in $arc.files.PSObject.Properties) {
            $rel = [string]$p.Name
            $ok = $Full -or ($rel -notmatch '^projects[\\/]')
            if (-not $Full -and $rel -match '^projects[\\/]') {
                $ok = $false
                if ($ProjectName) { $ok = $rel.StartsWith("projects\$ProjectName\", [StringComparison]::OrdinalIgnoreCase) }
            }
            if (-not $ok) { continue }
            $src = Join-Path $arc.dir ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $src -PathType Leaf) -and -not (Test-Path -LiteralPath "$src.sync-txn.json")) {
                $stat.failed++; Write-SyncLog "manifest 引用的归档文件缺失: $rel ($($arc.dir))" 'WARN'; continue
            }
            try {
                Assert-NoReparseTraversal -Root $arc.dir -RelativePath $rel
                $entry = $p.Value
                $readPath = Get-ReadableTransactionPath -Path $src -Entry $entry
                $committed = [long]$entry.size
                if ($entry.mode -eq 'append' -and $null -ne $entry.offset) {
                    $offset = [long]$entry.offset
                    if ($offset -lt 0 -or $offset -gt $committed) { throw 'manifest append offset 超出 committed size' }
                    $committed = $offset
                }
                $sourceLength = (Get-Item -LiteralPath $readPath).Length
                if ($sourceLength -lt $committed) { throw "归档文件短于 committed size ($sourceLength < $committed)" }
                if ($entry.mode -eq 'append') {
                    $fs = Open-SharedRead -Path $readPath
                    try { $committed = Get-SafeAppendLength -Stream $fs -Length $committed } finally { $fs.Close() }
                }
                $entryHash = Get-EntryContentHash $entry
                if ($entryHash -and (Get-FileHashPrefixHex -Path $readPath -Length $committed) -ne $entryHash) {
                    throw '归档文件 committed contentHash 不匹配'
                }
                $validateTemp = Join-Path $env:TEMP ("aisync-validate-" + [Guid]::NewGuid().ToString('N'))
                Copy-FileShared -Src $readPath -Dst $validateTemp -Offset 0 -Length $committed
                try { Test-JsonPayload -Path $validateTemp -RelativePath $rel }
                finally { Remove-Item -LiteralPath $validateTemp -Force -EA SilentlyContinue }
                $fileStamp = $arc.stamp
                try { if ($entry.mtime) { $fileStamp = [DateTime]::Parse([string]$entry.mtime).ToUniversalTime() } } catch { throw 'manifest entry mtime 无效' }
            } catch {
                $stat.failed++; Write-SyncLog "归档文件校验失败（跳过）: $rel ($($_.Exception.Message))" 'WARN'; continue
            }
            if (-not $candidates.ContainsKey($rel)) { $candidates[$rel] = @() }
            $candidates[$rel] += [pscustomobject]@{ arc=$arc; src=$readPath; entry=$entry; length=$committed; stamp=$fileStamp }
        }
    }

    $targetRoot = [IO.Path]::GetFullPath($TargetDir).TrimEnd('\') + '\'
    foreach ($rel in @($candidates.Keys | Sort-Object)) {
        $items = @($candidates[$rel])
        if ($items.Count -gt 1) { $stat.conflicts++ }
        $dst = [IO.Path]::GetFullPath((Join-Path $TargetDir ($rel -replace '/', '\')))
        if (-not $dst.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝写出 TargetDir: $rel" }
        try {
            Assert-NoReparseTraversal -Root $TargetDir -RelativePath $rel
            if ($ArchiveSet -and $rel -ieq 'history.jsonl') {
                $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                $merged = New-Object 'System.Collections.Generic.List[string]'
                foreach ($item in $items) {
                    $readTemp = Join-Path $env:TEMP ("aisync-read-" + [Guid]::NewGuid().ToString('N'))
                    Copy-FileShared -Src $item.src -Dst $readTemp -Offset 0 -Length $item.length
                    $readLines = [IO.File]::ReadAllLines($readTemp, [Text.Encoding]::UTF8)
                    Remove-Item -LiteralPath $readTemp -Force -EA SilentlyContinue
                    foreach ($line in $readLines) {
                        if ($line -and $seen.Add($line)) { [void]$merged.Add($line) }
                    }
                }
                $tmp = "$dst.tmp.$([Guid]::NewGuid().ToString('N'))"
                Ensure-Dir $tmp
                [IO.File]::WriteAllText($tmp, (($merged -join "`n") + $(if ($merged.Count) { "`n" } else { '' })), (New-Object Text.UTF8Encoding($false)))
                Test-JsonPayload -Path $tmp -RelativePath $rel
                $mergedBytes = (Get-Item -LiteralPath $tmp).Length
                Install-FileRecoverable -Tmp $tmp -Dst $dst
                $stat.pulled++; $stat.bytes += $mergedBytes
                continue
            }
            # Since archives are ordered oldest-to-newest, the final available
            # entry.mtime decides which complete version wins. A transcript
            # conflict is deliberately resolved by selection, never concatenation.
            $item = @($items | Sort-Object @{Expression={$_.stamp}}, @{Expression={$_.arc.dir}})[-1]
            $need = $true
            if (Test-Path -LiteralPath $dst) {
                if ((Get-Item -LiteralPath $dst).Length -eq $item.length) {
                    $existingHash = Get-FileHashHex $dst
                    $tmpCompare = Join-Path $env:TEMP ("aisync-compare-" + [Guid]::NewGuid().ToString('N'))
                    Copy-FileShared -Src $item.src -Dst $tmpCompare -Offset 0 -Length $item.length
                    $same = ($existingHash -eq (Get-FileHashHex $tmpCompare))
                    Remove-Item -LiteralPath $tmpCompare -Force -EA SilentlyContinue
                    if ($same) { $need = $false }
                }
            }
            if ($need) {
                $tmp = "$dst.tmp.$([Guid]::NewGuid().ToString('N'))"
                Copy-FileShared -Src $item.src -Dst $tmp -Offset 0 -Length $item.length
                Test-JsonPayload -Path $tmp -RelativePath $rel
                $n = (Get-Item -LiteralPath $tmp).Length
                Install-FileRecoverable -Tmp $tmp -Dst $dst
                $stat.pulled++; $stat.bytes += $n
            }
        } catch { $stat.failed++; Write-SyncLog "拉取失败（跳过）: $rel  $($_.Exception.Message)" 'WARN' }
    }
    return $stat
}

# ============================================================
#  入口
# ============================================================
if ($Direction -eq 'Push' -and -not (Test-Path -LiteralPath $SessionsDir)) {
    New-Item -ItemType Directory -Path $SessionsDir -Force | Out-Null
}

if ($Direction -eq 'Push') {
    $r = Invoke-Push
    if (-not $Quiet) {
        Write-SyncLog ("同步完成：新增 {0} / 追加 {1} / 跳过 {2} / 失败 {3}，传输 {4:N0} KB" -f `
            $r.copied, $r.appended, $r.skipped, $r.failed, ($r.bytes/1KB)) 'OK'
    }
    # ★ 把统计结果输出到管道，让调用方（守护进程）能记下每轮的痕迹。
    #   否则 -Quiet 下成功的同步完全无声，日志里看不出"到底跑了没、跑成什么样"。
    [pscustomobject]@{
        copied = $r.copied; appended = $r.appended; skipped = $r.skipped; bytes = $r.bytes; failed = $r.failed
    }
} else {
    if (-not $TargetDir) { throw 'Pull 模式必须指定 -TargetDir' }
    $r = Invoke-Pull
    if (-not $Quiet) {
        Write-SyncLog ("反向拉取完成：{0} 个文件 {1:N0} KB" -f $r.pulled, ($r.bytes/1KB)) 'OK'
    }
    [pscustomobject]@{
        pulled = $r.pulled; bytes = $r.bytes; failed = $r.failed
        sources = $r.sources; conflicts = $r.conflicts
    }
}

# Portable encrypted credential vault for Windows PowerShell 5.1 / .NET Framework 4.7.2+.
# Dot-source this file; functions never log passwords, keys, or decrypted values.
Set-StrictMode -Version Latest

$script:VaultFormat = 'portable-credential-vault'
$script:VaultVersion = 1
$script:VaultIterations = 600000
$script:VaultMaxFileBytes = 50331648
$script:VaultMaxPlainBytes = 36700160
$script:VaultMaxIterations = 1000000

function Get-VaultStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    Assert-VaultSafePath -Path $full
    $backup = $full + '.bak'
    $temp = $full + '.tmp'
    $restoreTemp = $full + '.restore.tmp'
    $exists = [IO.File]::Exists($full)
    $backupExists = [IO.File]::Exists($backup)
    $tempExists = [IO.File]::Exists($temp)
    $restoreTempExists = [IO.File]::Exists($restoreTemp)
    $state = if ($tempExists -or $restoreTempExists -or (-not $exists -and $backupExists)) { 'RecoveryRequired' } elseif ($exists) { 'Present' } else { 'Absent' }
    $metadata = $null
    if ($exists -and (New-Object IO.FileInfo($full)).Length -le $script:VaultMaxFileBytes) {
        try {
            $raw = [IO.File]::ReadAllText($full, (New-Object Text.UTF8Encoding($false, $true)))
            $o = $raw | ConvertFrom-Json -ErrorAction Stop
            $valid = $o.format -ceq $script:VaultFormat -and [int]$o.version -eq $script:VaultVersion -and
                $o.kdf -ceq 'PBKDF2-HMAC-SHA256' -and [int]$o.iterations -ge 600000 -and
                [int]$o.iterations -le $script:VaultMaxIterations -and $o.cipher -ceq 'AES-256-CBC-PKCS7'
            if ($valid) {
                $metadata = [pscustomobject]@{
                    Format = $o.format; Version = $o.version; Kdf = $o.kdf
                    Iterations = $o.iterations; Cipher = $o.cipher
                }
            } else { $state = 'InvalidMetadata' }
        } catch { $state = 'InvalidMetadata' }
    } elseif ($exists) { $state = 'InvalidMetadata' }
    return [pscustomobject]@{
        Path = $full; State = $state; Exists = $exists; BackupExists = $backupExists
        TemporaryExists = $tempExists; RestoreTempExists = $restoreTempExists; Metadata = $metadata
    }
}

function Assert-VaultSafePath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $inspect = New-Object 'System.Collections.Generic.List[string]'
    $inspect.Add($full)
    foreach ($suffix in @('.lock','.bak','.tmp','.restore.tmp')) { $inspect.Add($full + $suffix) }
    $parent = Split-Path -Parent $full
    while ($parent) {
        $inspect.Add($parent)
        $next = [IO.Directory]::GetParent($parent)
        if ($null -eq $next) { break }
        $parent = $next.FullName
    }
    foreach ($candidate in $inspect) {
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            try {
                $attributes = [IO.File]::GetAttributes($candidate)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw '保险箱路径、父目录或恢复文件包含重解析点，已拒绝访问。'
                }
                if ([string]::Equals($candidate, $full, [StringComparison]::OrdinalIgnoreCase) -and ($attributes -band [IO.FileAttributes]::Directory)) {
                    throw '保险箱路径必须指向文件，不能指向目录。'
                }
            } catch [IO.FileNotFoundException] { }
              catch [IO.DirectoryNotFoundException] { }
        }
    }
}

function Enter-VaultFileLock {
    param([Parameter(Mandatory)][string]$Path)
    Assert-VaultSafePath -Path $Path
    $lockPath = $Path + '.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try { return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw '保险箱正被另一个操作占用，请稍后重试。' }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Get-VaultBytes {
    param([Parameter(Mandatory)][string]$Path)
    $info = New-Object IO.FileInfo($Path)
    if ($info.Length -gt $script:VaultMaxFileBytes) { throw '保险箱文件超过大小限制。' }
    return [IO.File]::ReadAllBytes($Path)
}

function Get-VaultRevision {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-VaultPasswordText {
    param([Parameter(Mandatory)][Security.SecureString]$Password)
    if ($Password.Length -lt 1 -or $Password.Length -gt 1024) { throw '主密码长度必须为 1 到 1024 个字符。' }
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
    }
}

function Get-VaultDerivedKeys {
    param([Parameter(Mandatory)][Security.SecureString]$Password, [Parameter(Mandatory)][byte[]]$Salt, [Parameter(Mandatory)][int]$Iterations)
    $text = Get-VaultPasswordText -Password $Password
    $derive = $null
    try {
        $hashName = [Security.Cryptography.HashAlgorithmName]::SHA256
        $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($text, $Salt, $Iterations, $hashName)
        return ,$derive.GetBytes(64)
    } catch {
        throw '当前 .NET Framework 不支持 PBKDF2-HMAC-SHA256；需要 .NET Framework 4.7.2 或更新版本。'
    } finally {
        if ($derive) { $derive.Dispose() }
        $text = $null
    }
}

function Get-VaultMacInput {
    param([Parameter(Mandatory)][byte[]]$Salt, [Parameter(Mandatory)][int]$Iterations, [Parameter(Mandatory)][byte[]]$InitializationVector, [Parameter(Mandatory)][byte[]]$Ciphertext)
    $prefix = [Text.Encoding]::ASCII.GetBytes("portable-credential-vault`n1`nPBKDF2-HMAC-SHA256`n$Iterations`nAES-256-CBC-PKCS7`n")
    $stream = New-Object IO.MemoryStream
    try {
        $stream.Write($prefix, 0, $prefix.Length)
        $stream.Write($Salt, 0, $Salt.Length); $stream.Write($InitializationVector, 0, $InitializationVector.Length); $stream.Write($Ciphertext, 0, $Ciphertext.Length)
        return ,$stream.ToArray()
    } finally { $stream.Dispose() }
}

function Get-VaultHmac {
    param([Parameter(Mandatory)][byte[]]$Key, [Parameter(Mandatory)][byte[]]$Data)
    $hmac = New-Object Security.Cryptography.HMACSHA256(,$Key)
    try { return ,$hmac.ComputeHash($Data) } finally { $hmac.Dispose() }
}

function Test-VaultBytesEqual {
    param([Parameter(Mandatory)][byte[]]$A, [Parameter(Mandatory)][byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function ConvertTo-VaultPayload {
    param([Parameter(Mandatory)][Collections.IDictionary]$Secrets)
    if ($Secrets.Count -gt 256) { throw '保险箱最多支持 256 个凭据条目。' }
    $map = [ordered]@{}
    foreach ($key in $Secrets.Keys) {
        if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $key.Length -gt 128) { throw '凭据名称必须是 1 到 128 个字符的字符串。' }
        $value = $Secrets[$key]
        if ($value -isnot [string] -or $value.Length -gt $script:VaultMaxPlainBytes) { throw '凭据值必须是字符串且不超过保险箱明文大小限制。' }
        $map[$key] = $value
    }
    $json = ConvertTo-Json -InputObject $map -Depth 4 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -gt $script:VaultMaxPlainBytes) { throw '凭据映射超过保险箱明文大小限制。' }
    return ,$bytes
}

function Read-VaultEnvelope {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][Security.SecureString]$Password)
    if ($Bytes.Length -gt $script:VaultMaxFileBytes) { throw '保险箱文件超过大小限制。' }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $obj = ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json -ErrorAction Stop)
        if ($obj.format -cne $script:VaultFormat -or [int]$obj.version -ne $script:VaultVersion -or $obj.kdf -cne 'PBKDF2-HMAC-SHA256' -or $obj.cipher -cne 'AES-256-CBC-PKCS7') { throw '不支持的保险箱格式或版本。' }
        $iterations = [int]$obj.iterations
        if ($iterations -lt 600000 -or $iterations -gt $script:VaultMaxIterations) { throw '保险箱 PBKDF2 参数超出允许范围。' }
        $salt = [Convert]::FromBase64String([string]$obj.salt)
        $iv = [Convert]::FromBase64String([string]$obj.iv)
        $cipher = [Convert]::FromBase64String([string]$obj.ciphertext)
        $mac = [Convert]::FromBase64String([string]$obj.mac)
        if ($salt.Length -ne 16 -or $iv.Length -ne 16 -or $mac.Length -ne 32 -or $cipher.Length -lt 16 -or $cipher.Length -gt $script:VaultMaxPlainBytes + 16 -or ($cipher.Length % 16) -ne 0) { throw '保险箱字段长度无效。' }
    } catch { throw '保险箱文件格式无效或已损坏。' }

    $keys = Get-VaultDerivedKeys -Password $Password -Salt $salt -Iterations $iterations
    $macInput = $null
    $plain = $null
    $payloadText = $null
    try {
        $macInput = Get-VaultMacInput -Salt $salt -Iterations $iterations -InitializationVector $iv -Ciphertext $cipher
        $expected = Get-VaultHmac -Key ([byte[]]$keys[32..63]) -Data $macInput
        if (-not (Test-VaultBytesEqual -A $expected -B $mac)) { throw '主密码错误，或保险箱认证失败；原文件未修改。' }
        $aes = [Security.Cryptography.Aes]::Create()
        try {
            $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $aes.KeySize = 256; $aes.BlockSize = 128
            $decryptor = $aes.CreateDecryptor([byte[]]$keys[0..31], $iv)
            try { $plain = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length) } finally { $decryptor.Dispose() }
        } finally { $aes.Dispose() }
        if ($plain.Length -gt $script:VaultMaxPlainBytes) { throw '保险箱明文超过大小限制。' }
        try {
            $payloadText = $utf8.GetString($plain)
            $parsed = $payloadText | ConvertFrom-Json -ErrorAction Stop
            $secrets = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            foreach ($p in $parsed.PSObject.Properties) {
                if ($p.Name.Length -lt 1 -or $p.Name.Length -gt 128 -or $p.Value -isnot [string] -or $p.Value.Length -gt $script:VaultMaxPlainBytes -or $secrets.Count -ge 256) { throw '凭据映射格式无效。' }
                $secrets.Add($p.Name, [string]$p.Value)
            }
            return $secrets
        } catch { throw '保险箱认证通过，但凭据映射格式无效。' }
    } finally {
        [Array]::Clear($keys, 0, $keys.Length)
        if ($macInput) { [Array]::Clear($macInput, 0, $macInput.Length) }
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        $payloadText = $null
    }
}

function Read-PortableVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][Security.SecureString]$Password)
    $full = [IO.Path]::GetFullPath($Path)
    Assert-VaultSafePath -Path $full
    $parent = Split-Path -Parent $full
    if (-not [IO.Directory]::Exists($parent)) { throw '保险箱目录不存在。' }
    $lock = Enter-VaultFileLock -Path $full
    try {
        if (-not [IO.File]::Exists($full)) {
            if ([IO.File]::Exists($full + '.bak') -or [IO.File]::Exists($full + '.tmp')) { throw '主保险箱缺失且发现恢复文件；请明确选择 Backup 或 Temp 并执行 Restore-PortableVault。' }
            throw '找不到保险箱文件。'
        }
        $bytes = Get-VaultBytes -Path $full
        $secrets = Read-VaultEnvelope -Bytes $bytes -Password $Password
        return [pscustomobject]@{ Secrets = $secrets; Revision = (Get-VaultRevision -Bytes $bytes) }
    } finally { $lock.Dispose() }
}

function Restore-PortableVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][ValidateSet('Backup','Temp')][string]$Source
    )
    $full = [IO.Path]::GetFullPath($Path)
    Assert-VaultSafePath -Path $full
    $parent = Split-Path -Parent $full
    if (-not [IO.Directory]::Exists($parent)) { throw '保险箱目录不存在。' }
    $sourcePath = if ($Source -eq 'Backup') { $full + '.bak' } else { $full + '.tmp' }
    $lock = Enter-VaultFileLock -Path $full
    $stage = $full + '.restore.tmp'
    try {
        if (-not [IO.File]::Exists($sourcePath)) { throw "指定的 $Source 恢复文件不存在。" }
        $candidate = Get-VaultBytes -Path $sourcePath
        $verified = $null
        try { $verified = Read-VaultEnvelope -Bytes $candidate -Password $Password }
        finally { if ($verified) { $verified.Clear() } }
        if ([IO.File]::Exists($stage)) { throw '发现上次恢复留下的暂存文件；请先人工检查现场文件。' }
        $fs = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $fs.Write($candidate, 0, $candidate.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        $preserved = $null
        if ([IO.File]::Exists($full)) {
            $currentHash = Get-VaultRevision -Bytes (Get-VaultBytes -Path $full)
            $preserved = $full + '.pre-restore-' + $currentHash.Substring(0, 12)
            if ([IO.File]::Exists($preserved)) { $preserved += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
            [IO.File]::Move($full, $preserved)
        }
        try { [IO.File]::Move($stage, $full) }
        catch {
            if ($preserved -and -not [IO.File]::Exists($full) -and [IO.File]::Exists($preserved)) { [IO.File]::Move($preserved, $full) }
            throw '恢复安装失败；原有保险箱已保留。'
        }
        $preservedSource = $null
        if ([IO.File]::Exists($full + '.tmp')) {
            $sourceHash = Get-VaultRevision -Bytes (Get-VaultBytes -Path ($full + '.tmp'))
            $preservedSource = $full + '.recovered-temp-' + $sourceHash.Substring(0, 12)
            if ([IO.File]::Exists($preservedSource)) { $preservedSource += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
            try { [IO.File]::Move(($full + '.tmp'), $preservedSource) }
            catch { throw '主保险箱已恢复，但原临时副本仍在原位置；请检查后再写入。' }
        }
        return [pscustomobject]@{ Path = $full; Revision = (Get-VaultRevision -Bytes (Get-VaultBytes -Path $full)); Source = $Source; PreservedCurrent = $preserved; PreservedSource = $preservedSource }
    } finally { $lock.Dispose() }
}

function Write-PortableVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][Collections.IDictionary]$Secrets,
        [AllowNull()][string]$ExpectedRevision
    )
    $full = [IO.Path]::GetFullPath($Path)
    Assert-VaultSafePath -Path $full
    $parent = Split-Path -Parent $full
    if (-not [IO.Directory]::Exists($parent)) { throw '保险箱目录不存在。' }
    $lock = Enter-VaultFileLock -Path $full
    $temp = $full + '.tmp'; $backup = $full + '.bak'
    $macInput = $null
    try {
        $exists = [IO.File]::Exists($full)
        if ([IO.File]::Exists($full + '.tmp') -or [IO.File]::Exists($full + '.restore.tmp')) { throw '发现未处理的保险箱暂存文件；请先检查恢复现场。' }
        if ($exists) {
            if ([string]::IsNullOrWhiteSpace($ExpectedRevision)) { throw '更新保险箱必须提供已读取的 Revision。' }
            $current = Get-VaultBytes -Path $full
            if ((Get-VaultRevision -Bytes $current) -cne $ExpectedRevision.ToLowerInvariant()) { throw '保险箱已由其他窗口更新；请重新读取后再修改。' }
        } else {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRevision)) { throw '保险箱不存在，拒绝使用旧 Revision 创建。' }
            if ([IO.File]::Exists($backup) -or [IO.File]::Exists($temp)) { throw '发现保险箱恢复文件；请先恢复或检查，拒绝覆盖。' }
        }
        $plain = ConvertTo-VaultPayload -Secrets $Secrets
        $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($salt); $rng.GetBytes($iv) } finally { $rng.Dispose() }
        $keys = Get-VaultDerivedKeys -Password $Password -Salt $salt -Iterations $script:VaultIterations
        try {
            $aes = [Security.Cryptography.Aes]::Create()
            try {
                $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
                $aes.KeySize = 256; $aes.BlockSize = 128
                $encryptor = $aes.CreateEncryptor([byte[]]$keys[0..31], $iv)
                try { $cipher = $encryptor.TransformFinalBlock($plain, 0, $plain.Length) } finally { $encryptor.Dispose() }
            } finally { $aes.Dispose() }
            $macInput = Get-VaultMacInput -Salt $salt -Iterations $script:VaultIterations -InitializationVector $iv -Ciphertext $cipher
            $mac = Get-VaultHmac -Key ([byte[]]$keys[32..63]) -Data $macInput
            $envelope = [ordered]@{ format=$script:VaultFormat; version=$script:VaultVersion; kdf='PBKDF2-HMAC-SHA256'; iterations=$script:VaultIterations; salt=[Convert]::ToBase64String($salt); cipher='AES-256-CBC-PKCS7'; iv=[Convert]::ToBase64String($iv); ciphertext=[Convert]::ToBase64String($cipher); mac=[Convert]::ToBase64String($mac) }
            $out = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $envelope -Depth 4 -Compress))
            if ($out.Length -gt $script:VaultMaxFileBytes) { throw '加密后的保险箱超过文件大小限制。' }
            $fs = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $fs.Write($out, 0, $out.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        } finally {
            [Array]::Clear($keys, 0, $keys.Length); [Array]::Clear($plain, 0, $plain.Length)
            if ($macInput) { [Array]::Clear($macInput, 0, $macInput.Length) }
        }
        if ($exists) {
            [IO.File]::Copy($full, $backup, $true)
            [IO.File]::Delete($full)
        }
        [IO.File]::Move($temp, $full)
        $newBytes = Get-VaultBytes -Path $full
        return (Get-VaultRevision -Bytes $newBytes)
    } finally { $lock.Dispose() }
}

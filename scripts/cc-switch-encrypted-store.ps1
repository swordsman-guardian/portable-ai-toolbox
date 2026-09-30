# Encrypted stopped-snapshot store for Windows PowerShell 5.1 / .NET Framework 4.7.2+.
# Dot-source this file. USB content is ciphertext only; plaintext ZIP is memory-only.
Set-StrictMode -Version 2.0
$script:CcEncMaxPlainBytes = 32MB
$script:CcEncMaxCipherBytes = 48MB
$script:CcEncMaxFiles = 2048
$script:CcEncMaxEntries = 4096
$script:CcEncMaxDepth = 64
$script:CcEncFormat = 'cc-switch-encrypted-generation-v1'
if (-not (Get-Command Write-PortableVault -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'vault.ps1') }
if (-not (Get-Command ConvertFrom-CcSwitchClaudeDocument -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cc-switch-profile.ps1') }

function Get-CcEncPaths([string]$StickRoot) {
    $root=[IO.Path]::GetFullPath($StickRoot); $vol=[IO.Path]::GetPathRoot($root)
    if (-not $root.Equals($vol,[StringComparison]::OrdinalIgnoreCase)) { $root=$root.TrimEnd('\','/') }
    [pscustomobject]@{ StickRoot=$root; Store=(Join-Path $root 'config\cc-switch\secure-store') }
}
function Assert-CcEncNoReparse([string]$Path,[switch]$Children) {
    $full=[IO.Path]::GetFullPath($Path); $cursor=$full
    while ($cursor) { if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) { if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Encrypted store paths cannot contain reparse points.' } }; $p=[IO.Directory]::GetParent($cursor); if (!$p) { break }; $cursor=$p.FullName }
    if ($Children -and [IO.Directory]::Exists($full)) { $s=New-Object 'System.Collections.Generic.Stack[string]';$s.Push($full);$n=0;while($s.Count){$d=$s.Pop();foreach($x in [IO.Directory]::EnumerateFileSystemEntries($d)){if(++$n -gt $script:CcEncMaxEntries){throw 'Snapshot exceeds 4096 tree entries.'};if(([IO.File]::GetAttributes($x)-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Snapshot trees cannot contain reparse points.'};if(([IO.File]::GetAttributes($x)-band [IO.FileAttributes]::Directory)-ne 0){$s.Push($x)}}} }
}
function Enter-CcEncLock([string]$Store) {
    Assert-CcEncNoReparse $Store
    [void][IO.Directory]::CreateDirectory($Store)
    Assert-CcEncNoReparse $Store
    $lockPath=Join-Path $Store 'store.lock'
    Assert-CcEncNoReparse $lockPath
    try { return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { throw 'Encrypted store is busy in another process.' }
}
function Read-CcEncBytesLimited([string]$Path,[long]$Maximum) {
    Assert-CcEncNoReparse $Path
    if(-not [IO.File]::Exists($Path)){throw 'Encrypted store file is missing.'}
    $info=New-Object IO.FileInfo($Path)
    if($info.Length -lt 1 -or $info.Length -gt $Maximum){throw 'Encrypted store file exceeds its permitted size.'}
    return ,([IO.File]::ReadAllBytes($Path))
}
function Write-CcEncBytes([string]$Path,[byte[]]$Bytes) { $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$bak=$Path+'.'+[guid]::NewGuid().ToString('N')+'.bak';$f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes,0,$Bytes.Length);$f.Flush($true)}finally{$f.Dispose()};$had=[IO.File]::Exists($Path);try{if($had){[IO.File]::Move($Path,$bak)};[IO.File]::Move($tmp,$Path);if($had){[IO.File]::Delete($bak)}}catch{if(-not [IO.File]::Exists($Path) -and [IO.File]::Exists($bak)){[IO.File]::Move($bak,$Path)};throw}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}} }
function Get-CcEncKeyring([string]$Store){Join-Path $Store 'keyring.vault.json'}
function Open-CcEncryptedStoreSession {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StickRoot,[Parameter(Mandatory)][Security.SecureString]$Password,[switch]$Create)
    $p=Get-CcEncPaths $StickRoot
    Assert-CcEncNoReparse $p.StickRoot
    Assert-CcEncNoReparse $p.Store
    [void][IO.Directory]::CreateDirectory($p.Store)
    Assert-CcEncNoReparse $p.Store
    $lock=Enter-CcEncLock $p.Store
    $key=$null
    $keyringBytes=$null
    $createdKey=$false
    try {
        $keyPath=Get-CcEncKeyring $p.Store
        Assert-CcEncNoReparse $keyPath
        if(-not [IO.File]::Exists($keyPath)) {
            if(-not $Create){throw 'Encrypted store is absent; use -Create to initialize it.'}
            $currentPath=Join-Path $p.Store 'current.json'
            $previousPath=Join-Path $p.Store 'previous.json'
            $generationsPath=Join-Path $p.Store 'generations'
            if([IO.File]::Exists($currentPath) -or [IO.File]::Exists($previousPath) -or
                ([IO.Directory]::Exists($generationsPath) -and [IO.Directory]::EnumerateFileSystemEntries($generationsPath).GetEnumerator().MoveNext())) {
                throw 'Encrypted data exists without its wrapped key; refusing to initialize a new store.'
            }
            $key=New-Object byte[] 32
            $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
            try {$rng.GetBytes($key)} finally {$rng.Dispose()}
            $dictionary=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            $dictionary.Add('data-key',[Convert]::ToBase64String($key))
            try {$null=Write-PortableVault -Path $keyPath -Password $Password -Secrets $dictionary}
            finally {$dictionary.Clear()}
            $createdKey=$true
        }
        $keyringBytes=Read-CcEncBytesLimited $keyPath 50331648
        if(-not $createdKey) {
            $opened=Read-PortableVault -Path $keyPath -Password $Password
            try {
                if(-not $opened.Secrets.ContainsKey('data-key')){throw 'Wrapped data key is missing.'}
                $unwrapped=[Convert]::FromBase64String($opened.Secrets['data-key'])
                if($unwrapped.Length -ne 32){[Array]::Clear($unwrapped,0,$unwrapped.Length);throw 'Wrapped data key is invalid.'}
                $key=$unwrapped
            } finally {$opened.Secrets.Clear()}
        }
        $status=Get-CcEncryptedStoreStatus -StickRoot $p.StickRoot
        if($status.State -eq 'Corrupt'){throw 'Encrypted store metadata is corrupt.'}
        return [pscustomobject]@{StickRoot=$p.StickRoot;DataKey=$key;KeyringBytes=$keyringBytes;Revision=$status.CurrentRevision;Locked=$false;Format=$script:CcEncFormat}
    } catch {
        if($key){[Array]::Clear($key,0,$key.Length)}
        if($keyringBytes){[Array]::Clear($keyringBytes,0,$keyringBytes.Length)}
        throw
    } finally {$lock.Dispose()}
}
function Close-CcEncryptedStoreSession {
    param([Parameter(Mandatory)]$Session)
    if($Session.DataKey){[Array]::Clear([byte[]]$Session.DataKey,0,$Session.DataKey.Length)}
    if($Session.KeyringBytes){[Array]::Clear([byte[]]$Session.KeyringBytes,0,$Session.KeyringBytes.Length)}
    $Session.DataKey=$null
    $Session.KeyringBytes=$null
    $Session.Locked=$true
    $Session.Revision=$null
}
function Get-CcEncryptedStoreStatus {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StickRoot)
    $p=Get-CcEncPaths $StickRoot
    $key=Get-CcEncKeyring $p.Store
    $cur=Join-Path $p.Store 'current.json'
    $prev=Join-Path $p.Store 'previous.json'
    $state='Absent';$cr=$null;$pr=$null;$recovery=$false
    if([IO.Directory]::Exists($p.Store)) {
        try {
            Assert-CcEncNoReparse $p.Store -Children
            foreach($item in [IO.Directory]::EnumerateFileSystemEntries($p.Store)) {
                $leaf=Split-Path -Leaf $item
                if($leaf -in @('keyring.vault.json','keyring.vault.json.lock','current.json','previous.json','generations','migration.pending.json','store.lock')){continue}
                if($leaf -match '^(current|previous)\.json\..*\.(tmp|bak)$'){$recovery=$true;continue}
                if($leaf -match '^keyring\.vault\.json\.(bak|tmp|restore\.tmp)$'){$recovery=$true;continue}
                $state='Corrupt'
            }
        } catch {$state='Corrupt'}
    }
    if([IO.File]::Exists((Join-Path $p.Store 'migration.pending.json'))){$recovery=$true}
    $gens=Join-Path $p.Store 'generations'
    if([IO.Directory]::Exists($gens)){try{foreach($item in [IO.Directory]::EnumerateFileSystemEntries($gens)){Assert-CcEncNoReparse $item;$leaf=Split-Path -Leaf $item;if([IO.Directory]::Exists($item)){throw 'Unexpected directory in encrypted generations.'};if($leaf -match '^[0-9a-f]{32}\.bin$'){continue};if($leaf -match '\.(tmp|bak)$'){$recovery=$true}else{throw 'Unexpected file in encrypted generations.'}}}catch{$state='Corrupt'}}
    if([IO.File]::Exists($key) -and $state -ne 'Corrupt'){
        $state='Locked'
        try {
            $null=Read-CcEncBytesLimited $key 50331648
            foreach($entry in @(@{path=$cur;name='Current'},@{path=$prev;name='Previous'})) {
                if(-not [IO.File]::Exists($entry.path)){continue}
                $pointerBytes=Read-CcEncBytesLimited $entry.path 4096
                $o=(New-Object Text.UTF8Encoding($false,$true)).GetString($pointerBytes)|ConvertFrom-Json -ErrorAction Stop
                if($o.format -cne $script:CcEncFormat -or $o.revision -notmatch '^[0-9a-f]{32}$'){throw 'Invalid pointer.'}
                if($entry.name -eq 'Current'){$cr=$o.revision}else{$pr=$o.revision}
                $gen=Join-Path $gens ($o.revision+'.bin')
                $null=Read-CcEncBytesLimited $gen $script:CcEncMaxCipherBytes
            }
            if(-not $cr -and $pr){$recovery=$true}
            if(-not $cr -and -not $pr){$state='Ready'}
        } catch {$state='Corrupt'}
    }
    if(-not [IO.File]::Exists($key) -and $state -ne 'Corrupt') {
        if([IO.File]::Exists($cur) -or [IO.File]::Exists($prev) -or
            ([IO.Directory]::Exists($gens) -and [IO.Directory]::EnumerateFileSystemEntries($gens).GetEnumerator().MoveNext())) {
            $recovery=$true
        }
    }
    if($state -ne 'Corrupt' -and [IO.Directory]::Exists($gens)) { foreach($item in [IO.Directory]::EnumerateFiles($gens,'*.bin')) { $r=[IO.Path]::GetFileNameWithoutExtension($item); if($r -notmatch '^[0-9a-f]{32}$' -or ($r -ne $cr -and $r -ne $pr)){$recovery=$true} } }
    if($state -ne 'Corrupt' -and $recovery){$state='RecoveryRequired'}
    [pscustomobject]@{StickRoot=$p.StickRoot;State=$state;CurrentRevision=$cr;PreviousRevision=$pr;MaxPlainBytes=$script:CcEncMaxPlainBytes;MaxCipherBytes=$script:CcEncMaxCipherBytes;MaxFiles=$script:CcEncMaxFiles;MaxEntries=$script:CcEncMaxEntries;KdfIterations=600000}
}
function Get-CcEncInventory([string]$SourceRoot) {
    $files=New-Object 'System.Collections.Generic.List[object]';$total=[long]0;$entries=0
    foreach($relroot in @('config\cc-switch\home\.cc-switch','harness\cc-switch')){$dir=Join-Path $SourceRoot $relroot;if(-not [IO.Directory]::Exists($dir)){continue};$stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($dir);while($stack.Count){$d=$stack.Pop();foreach($f in [IO.Directory]::EnumerateFileSystemEntries($d)){if(++$entries -gt $script:CcEncMaxEntries){throw 'Source exceeds 4096 directory entries.'};$attr=[IO.File]::GetAttributes($f);if(($attr-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Source trees cannot contain reparse points.'};$name=[IO.Path]::GetFileName($f);if(($attr-band [IO.FileAttributes]::Directory)-ne 0){if($name -match '^(?i:logs?|history|backups?|cache|sessions?|tmp|temp)$'){continue};$stack.Push($f)}else{if($name -match '(?i)(\.log(\..*)?|\.bak|\.backup|\.tmp|\.temp|\.lock|-(wal|shm|journal)|\.(wal|shm|journal))$'){continue};$len=(New-Object IO.FileInfo($f)).Length;$total += $len;if($total -gt $script:CcEncMaxPlainBytes){throw 'Snapshot exceeds 32 MiB of file data.'};$relative=$f.Substring($SourceRoot.TrimEnd('\').Length+1).Replace('\','/');Assert-CcEncRelativePath $relative;$files.Add([pscustomobject]@{Full=$f;Relative=$relative;Length=$len});if($files.Count -gt $script:CcEncMaxFiles){throw 'Snapshot exceeds 2048 files.'}}}}}
    if($files.Count -eq 0){throw 'No files found in the two supported CC Switch trees.'};[pscustomobject]@{Files=$files;Bytes=$total;Entries=$entries}
}
function Get-CcEncSubkey([byte[]]$Key,[string]$Label) { $h=New-Object Security.Cryptography.HMACSHA256(,$Key);try{return ,$h.ComputeHash([Text.Encoding]::ASCII.GetBytes('CC-Switch encrypted store v1/'+$Label))}finally{$h.Dispose()} }
function Protect-CcEncBytes([byte[]]$Plain,[byte[]]$Key) {
    $encryptionKey=Get-CcEncSubkey $Key 'AES-256-CBC'
    $authenticationKey=Get-CcEncSubkey $Key 'HMAC-SHA256'
    try {
        $iv=New-Object byte[] 16
        $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try {$rng.GetBytes($iv)} finally {$rng.Dispose()}

        $aes=[Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize=256
            $aes.Mode=[Security.Cryptography.CipherMode]::CBC
            $aes.Padding=[Security.Cryptography.PaddingMode]::PKCS7
            $encryptor=$aes.CreateEncryptor($encryptionKey,$iv)
            try {$ciphertext=$encryptor.TransformFinalBlock($Plain,0,$Plain.Length)}
            finally {$encryptor.Dispose()}
        } finally {$aes.Dispose()}

        $authenticatedData=New-Object byte[] ($iv.Length+$ciphertext.Length)
        [Array]::Copy($iv,0,$authenticatedData,0,$iv.Length)
        [Array]::Copy($ciphertext,0,$authenticatedData,$iv.Length,$ciphertext.Length)
        $hmac=New-Object Security.Cryptography.HMACSHA256(,$authenticationKey)
        try {$mac=$hmac.ComputeHash($authenticatedData)} finally {$hmac.Dispose()}

        $envelope=[ordered]@{
            format=$script:CcEncFormat
            iv=[Convert]::ToBase64String($iv)
            ciphertext=[Convert]::ToBase64String($ciphertext)
            mac=[Convert]::ToBase64String($mac)
        }
        $json=ConvertTo-Json -InputObject $envelope -Compress
        return ,((New-Object Text.UTF8Encoding($false)).GetBytes($json))
    } finally {
        [Array]::Clear($encryptionKey,0,$encryptionKey.Length)
        [Array]::Clear($authenticationKey,0,$authenticationKey.Length)
    }
}
function Unprotect-CcEncBytes([byte[]]$Envelope,[byte[]]$Key) {
    if($Envelope.Length -gt $script:CcEncMaxCipherBytes){throw 'Encrypted generation exceeds 48 MiB.'}
    try {
        $object=[Text.Encoding]::UTF8.GetString($Envelope)|ConvertFrom-Json -ErrorAction Stop
        $iv=[Convert]::FromBase64String([string]$object.iv)
        $ciphertext=[Convert]::FromBase64String([string]$object.ciphertext)
        $mac=[Convert]::FromBase64String([string]$object.mac)
        if($object.format -cne $script:CcEncFormat -or $iv.Length -ne 16 -or
            $mac.Length -ne 32 -or $ciphertext.Length -lt 16 -or ($ciphertext.Length % 16) -ne 0) {
            throw 'Invalid encrypted generation envelope.'
        }
    } catch {throw 'Encrypted generation is malformed or corrupted.'}

    $authenticatedData=New-Object byte[] ($iv.Length+$ciphertext.Length)
    [Array]::Copy($iv,0,$authenticatedData,0,$iv.Length)
    [Array]::Copy($ciphertext,0,$authenticatedData,$iv.Length,$ciphertext.Length)
    $encryptionKey=Get-CcEncSubkey $Key 'AES-256-CBC'
    $authenticationKey=Get-CcEncSubkey $Key 'HMAC-SHA256'
    try {
        $hmac=New-Object Security.Cryptography.HMACSHA256(,$authenticationKey)
        try {$expectedMac=$hmac.ComputeHash($authenticatedData)} finally {$hmac.Dispose()}
        if(-not (Test-VaultBytesEqual -A $expectedMac -B $mac)){throw 'Encrypted generation authentication failed.'}

        $aes=[Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize=256
            $aes.Mode=[Security.Cryptography.CipherMode]::CBC
            $aes.Padding=[Security.Cryptography.PaddingMode]::PKCS7
            $decryptor=$aes.CreateDecryptor($encryptionKey,$iv)
            try {$plain=$decryptor.TransformFinalBlock($ciphertext,0,$ciphertext.Length)}
            finally {$decryptor.Dispose()}
        } finally {$aes.Dispose()}
    } finally {
        [Array]::Clear($encryptionKey,0,$encryptionKey.Length)
        [Array]::Clear($authenticationKey,0,$authenticationKey.Length)
    }
    if($plain.Length -gt $script:CcEncMaxPlainBytes){[Array]::Clear($plain,0,$plain.Length);throw 'Decrypted generation exceeds 32 MiB.'}
    return ,$plain
}
function Assert-CcEncRelativePath([string]$RelativePath) {
    if([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Length -gt 240 -or $RelativePath.StartsWith('/') -or $RelativePath.Contains('\') -or $RelativePath.Contains(':') -or $RelativePath -match '[\x00-\x1f]') { throw 'Encrypted snapshot contains an invalid relative path.' }
    $parts=$RelativePath.Split('/')
    if($parts.Count -gt $script:CcEncMaxDepth){throw 'Encrypted snapshot path exceeds depth limit.'}
    foreach($part in $parts) {
        if([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>"|?*]' -or $part.EndsWith('.') -or $part.EndsWith(' ')) { throw 'Encrypted snapshot contains an invalid path component.' }
        $stem=($part -split '\.',2)[0]
        if($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'){throw 'Encrypted snapshot contains a reserved Windows filename.'}
    }
    $lower=$RelativePath.ToLowerInvariant()
    if(-not ($lower.StartsWith('config/cc-switch/home/.cc-switch/',[StringComparison]::Ordinal) -or $lower.StartsWith('harness/cc-switch/',[StringComparison]::Ordinal))){throw 'Encrypted snapshot path is outside supported trees.'}
}
function Test-CcEncOnlyMigrationPending([string]$Store,[object]$Status) {
    if($Status.State -eq 'Corrupt'){return $false}
    foreach($item in [IO.Directory]::EnumerateFileSystemEntries($Store)) {
        $leaf=Split-Path -Leaf $item
        if($leaf -match '^(current|previous)\.json\..*\.(tmp|bak)$' -or $leaf -match '^keyring\.vault\.json\.(bak|tmp|restore\.tmp)$'){return $false}
    }
    $generations=Join-Path $Store 'generations'
    if([IO.Directory]::Exists($generations)) {
        foreach($item in [IO.Directory]::EnumerateFileSystemEntries($generations)) {
            $leaf=Split-Path -Leaf $item
            if([IO.Directory]::Exists($item) -or $leaf -notmatch '^[0-9a-f]{32}\.bin$'){return $false}
            $revision=[IO.Path]::GetFileNameWithoutExtension($leaf)
            if($revision -cne [string]$Status.CurrentRevision -and $revision -cne [string]$Status.PreviousRevision){return $false}
        }
    }
    return $true
}
function Save-CcEncryptedSnapshotCore {
    [CmdletBinding()]param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][switch]$StoppedOnly,[switch]$MigrationAuthorized)
    if(-not $StoppedOnly){throw 'Snapshot requires explicit -StoppedOnly confirmation.'}
    if($Session.Locked -or -not $Session.DataKey){throw 'Encrypted store session is locked.'}
    $p=Get-CcEncPaths $Session.StickRoot
    Assert-CcEncNoReparse $p.Store
    Assert-CcEncNoReparse (Join-Path $p.Store 'generations')
    $pre=Get-CcEncryptedStoreStatus $p.StickRoot
    $migrationPath=Join-Path $p.Store 'migration.pending.json'
    if($pre.State -eq 'RecoveryRequired') {
        $authorized=$false
        if($MigrationAuthorized -and [IO.File]::Exists($migrationPath)) {
            Assert-CcEncNoReparse $migrationPath
            $pending=Read-CcEncBytesLimited $migrationPath 1024
            $pendingText=(New-Object Text.UTF8Encoding($false,$true)).GetString($pending)
            $markerValid=$pendingText -ceq '{"version":1,"state":"MigrationInProgress"}' -or $pendingText -ceq '{"version":1,"state":"EncryptedVerifiedCleanupPending"}'
            $authorized=$markerValid -and (Test-CcEncOnlyMigrationPending -Store $p.Store -Status $pre)
        }
        if(-not $authorized){throw 'Encrypted store requires recovery before a new snapshot can be saved.'}
    }
    if($pre.State -eq 'Corrupt'){throw 'Encrypted store metadata is corrupt; refusing to save.'}
    if([string]$Session.Revision -cne [string]$pre.CurrentRevision){throw 'Encrypted store revision changed in another session; reopen before saving.'}
    $source=[IO.Path]::GetFullPath($SourceRoot)
    if($source.StartsWith($p.Store,[StringComparison]::OrdinalIgnoreCase)-or $p.Store.StartsWith($source,[StringComparison]::OrdinalIgnoreCase)){throw 'Source cannot overlap encrypted USB store.'}
    Assert-CcEncNoReparse $source -Children
    $inv=Get-CcEncInventory $source
    Add-Type -AssemblyName System.IO.Compression
    $memory=New-Object IO.MemoryStream
    $archive=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
    $manifest=[ordered]@{version=1;files=@()}
    try {
        foreach($file in $inv.Files) {
            $entry=$archive.CreateEntry($file.Relative,[IO.Compression.CompressionLevel]::Optimal)
            $archiveStream=$entry.Open()
            $sourceStream=[IO.File]::Open($file.Full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                if($sourceStream.Length -ne $file.Length){throw 'A source file changed after the stopped-tree scan.'}
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$hash=$sha.ComputeHash($sourceStream)} finally {$sha.Dispose()}
                $sourceStream.Position=0
                $sourceStream.CopyTo($archiveStream)
                if($sourceStream.Length -ne $file.Length){throw 'A source file changed while snapshotting.'}
            } finally {$sourceStream.Dispose();$archiveStream.Dispose()}
            $manifest.files+=@([pscustomobject]@{
                path=$file.Relative
                length=$file.Length
                sha256=([BitConverter]::ToString($hash).Replace('-','').ToLowerInvariant())
            })
        }
        $manifestEntry=$archive.CreateEntry('_ccenc_manifest.json')
        $manifestStream=$manifestEntry.Open()
        try {
            $manifestBytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $manifest -Depth 6 -Compress))
            if($manifestBytes.Length -gt 1MB){throw 'Snapshot manifest exceeds 1 MiB.'}
            $manifestStream.Write($manifestBytes,0,$manifestBytes.Length)
        } finally {$manifestStream.Dispose()}
    } finally {$archive.Dispose()}
    $plain=$memory.ToArray()
    $memory.Dispose()
    if($plain.Length -gt $script:CcEncMaxPlainBytes){[Array]::Clear($plain,0,$plain.Length);throw 'Compressed snapshot exceeds 32 MiB capacity.'}
    $revision=[guid]::NewGuid().ToString('N')
    $cipher=Protect-CcEncBytes $plain $Session.DataKey
    [Array]::Clear($plain,0,$plain.Length)
    if($cipher.Length -gt $script:CcEncMaxCipherBytes){throw 'Encrypted snapshot exceeds 48 MiB capacity.'}
    $store=$p.Store
    $gens=Join-Path $store 'generations'
    [void][IO.Directory]::CreateDirectory($gens)
    Assert-CcEncNoReparse $gens
    $genPath=Join-Path $gens ($revision+'.bin')
    Write-CcEncBytes $genPath $cipher
    $verified=Get-CcEncVerifiedZip -Store $store -Revision $revision -Key $Session.DataKey
    $verified.Zip.Dispose();$verified.Stream.Dispose();[Array]::Clear($verified.Plain,0,$verified.Plain.Length)
    $old=Join-Path $store 'current.json'
    $prev=Join-Path $store 'previous.json'
    if([IO.File]::Exists($old)) {
        $oldPointer=Read-CcEncBytesLimited $old 4096
        Write-CcEncBytes $prev $oldPointer
    }
    $pointer=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json ([ordered]@{format=$script:CcEncFormat;revision=$revision}) -Compress))
    Write-CcEncBytes $old $pointer
    $Session.Revision=$revision
    # Commit is complete. Retain exactly the committed pair; cleanup failure is a warning.
    try{$keep=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$keep.Add($revision)|Out-Null;$st=Get-CcEncryptedStoreStatus $Session.StickRoot;if($st.PreviousRevision){$keep.Add($st.PreviousRevision)|Out-Null};foreach($item in [IO.Directory]::EnumerateFiles($gens)){Assert-CcEncNoReparse $item;$leaf=[IO.Path]::GetFileName($item);if($leaf -notmatch '^[0-9a-f]{32}\.bin$'){throw 'Unexpected file encountered during encrypted generation cleanup.'};if(-not $keep.Contains([IO.Path]::GetFileNameWithoutExtension($leaf))){[IO.File]::Delete($item)}}}catch{Write-Warning 'Snapshot committed successfully, but stale encrypted generations could not all be cleaned up.'}
    [pscustomobject]@{Revision=$revision;Files=$inv.Files.Count;SourceBytes=$inv.Bytes;EncryptedBytes=$cipher.Length}
}
function Save-CcEncryptedSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][switch]$StoppedOnly,[switch]$MigrationAuthorized)
    if($Session.Locked -or -not $Session.DataKey){throw 'Encrypted store session is locked.'}
    $paths=Get-CcEncPaths $Session.StickRoot
    $lock=Enter-CcEncLock $paths.Store
    try { Save-CcEncryptedSnapshotCore -Session $Session -SourceRoot $SourceRoot -StoppedOnly:$StoppedOnly -MigrationAuthorized:$MigrationAuthorized }
    finally {$lock.Dispose()}
}
function Save-CcEncryptedRecoverySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][switch]$StoppedOnly
    )
    if(-not $StoppedOnly){throw 'Recovery snapshot requires explicit -StoppedOnly confirmation.'}
    if($Session.Locked -or -not $Session.DataKey -or $Session.DataKey.Length -ne 32 -or -not $Session.KeyringBytes){throw 'Encrypted store session is locked or lacks its wrapped keyring.'}
    if($Session.KeyringBytes.Length -lt 1 -or $Session.KeyringBytes.Length -gt 50331648){throw 'Cached wrapped keyring exceeds its supported size.'}

    $paths=Get-CcEncPaths $Session.StickRoot
    $source=[IO.Path]::GetFullPath($SourceRoot)
    $destination=[IO.Path]::GetFullPath($DestinationRoot)
    if($destination.Equals([IO.Path]::GetPathRoot($destination),[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery destination cannot be a volume root.'}
    if($destination.StartsWith($paths.Store,[StringComparison]::OrdinalIgnoreCase) -or $paths.Store.StartsWith($destination,[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery destination cannot overlap the USB encrypted store.'}
    if($source.StartsWith($destination,[StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($source,[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery destination cannot overlap the snapshot source.'}
    Assert-CcEncNoReparse $destination
    Assert-CcEncNoReparse $source -Children
    if(-not [IO.Directory]::Exists((Split-Path -Parent $destination))){throw 'Recovery destination parent directory must already exist.'}
    if([IO.File]::Exists($destination)){throw 'Recovery destination is an existing file.'}
    if([IO.Directory]::Exists($destination) -and [IO.Directory]::EnumerateFileSystemEntries($destination).GetEnumerator().MoveNext()){throw 'Recovery destination directory must be empty.'}

    $inventory=Get-CcEncInventory $source
    Add-Type -AssemblyName System.IO.Compression
    $memory=New-Object IO.MemoryStream
    $archive=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
    $manifest=[ordered]@{version=1;files=@()}
    try {
        foreach($file in $inventory.Files) {
            $entry=$archive.CreateEntry($file.Relative,[IO.Compression.CompressionLevel]::Optimal)
            $archiveStream=$entry.Open()
            $sourceStream=[IO.File]::Open($file.Full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                if($sourceStream.Length -ne $file.Length){throw 'A source file changed after the stopped-tree scan.'}
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$hash=$sha.ComputeHash($sourceStream)} finally {$sha.Dispose()}
                $sourceStream.Position=0
                $sourceStream.CopyTo($archiveStream)
                if($sourceStream.Length -ne $file.Length){throw 'A source file changed while creating recovery snapshot.'}
            } finally {$sourceStream.Dispose();$archiveStream.Dispose()}
            $manifest.files+=@([pscustomobject]@{
                path=$file.Relative
                length=$file.Length
                sha256=([BitConverter]::ToString($hash).Replace('-','').ToLowerInvariant())
            })
        }
        $manifestEntry=$archive.CreateEntry('_ccenc_manifest.json')
        $manifestStream=$manifestEntry.Open()
        try {
            $manifestBytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $manifest -Depth 6 -Compress))
            if($manifestBytes.Length -gt 1MB){throw 'Recovery manifest exceeds 1 MiB.'}
            $manifestStream.Write($manifestBytes,0,$manifestBytes.Length)
        } finally {$manifestStream.Dispose()}
    } finally {$archive.Dispose()}
    $plain=$memory.ToArray();$memory.Dispose()
    if($plain.Length -gt $script:CcEncMaxPlainBytes){[Array]::Clear($plain,0,$plain.Length);throw 'Recovery snapshot exceeds 32 MiB capacity.'}
    $revision=[guid]::NewGuid().ToString('N')
    $generation=Protect-CcEncBytes $plain $Session.DataKey
    [Array]::Clear($plain,0,$plain.Length)
    if($generation.Length -gt $script:CcEncMaxCipherBytes){throw 'Encrypted recovery snapshot exceeds 48 MiB capacity.'}

    $createdFiles=New-Object 'System.Collections.Generic.List[string]'
    $createdDirectories=New-Object 'System.Collections.Generic.List[string]'
    $rootCreated=$false
    $storeRoot=Join-Path $destination 'config\cc-switch\secure-store'
    $generationsRoot=Join-Path $storeRoot 'generations'
    $keyPath=Join-Path $storeRoot 'keyring.vault.json'
    $generationPath=Join-Path $generationsRoot ($revision+'.bin')
    $pointerPath=Join-Path $storeRoot 'current.json'
    try {
        Assert-CcEncNoReparse $destination
        if([IO.Directory]::Exists($destination) -and [IO.Directory]::EnumerateFileSystemEntries($destination).GetEnumerator().MoveNext()){throw 'Recovery destination changed and is no longer empty.'}
        if(-not [IO.Directory]::Exists($destination)){[void][IO.Directory]::CreateDirectory($destination);$rootCreated=$true}
        foreach($directory in @((Join-Path $destination 'config'),(Join-Path $destination 'config\cc-switch'),$storeRoot,$generationsRoot)) {
            Assert-CcEncNoReparse $directory
            if([IO.File]::Exists($directory) -or [IO.Directory]::Exists($directory)){throw 'Recovery output directory appeared concurrently.'}
            [void][IO.Directory]::CreateDirectory($directory)
            $createdDirectories.Add($directory)
        }
        Assert-CcEncNoReparse $keyPath
        $keyFile=[IO.File]::Open($keyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$keyFile.Write($Session.KeyringBytes,0,$Session.KeyringBytes.Length);$keyFile.Flush($true)} finally {$keyFile.Dispose()}
        $createdFiles.Add($keyPath)
        Write-CcEncBytes $generationPath $generation
        $createdFiles.Add($generationPath)
        $verified=Get-CcEncVerifiedZip -Store $storeRoot -Revision $revision -Key $Session.DataKey
        $verified.Zip.Dispose();$verified.Stream.Dispose();[Array]::Clear($verified.Plain,0,$verified.Plain.Length)
        $pointerBytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json ([ordered]@{format=$script:CcEncFormat;revision=$revision}) -Compress))
        Write-CcEncBytes $pointerPath $pointerBytes
        $createdFiles.Add($pointerPath)
        return [pscustomobject]@{DestinationRoot=$destination;Revision=$revision;Files=$inventory.Files.Count;SourceBytes=$inventory.Bytes;EncryptedBytes=$generation.Length;SessionRevision=$Session.Revision}
    } catch {
        foreach($file in $createdFiles){try{Assert-CcEncNoReparse $file;if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}catch{}}
        for($i=$createdDirectories.Count-1;$i -ge 0;$i--){try{$directory=$createdDirectories[$i];Assert-CcEncNoReparse $directory;if([IO.Directory]::Exists($directory) -and -not [IO.Directory]::EnumerateFileSystemEntries($directory).GetEnumerator().MoveNext()){[IO.Directory]::Delete($directory)}}catch{}}
        if($rootCreated){try{Assert-CcEncNoReparse $destination;if([IO.Directory]::Exists($destination) -and -not [IO.Directory]::EnumerateFileSystemEntries($destination).GetEnumerator().MoveNext()){[IO.Directory]::Delete($destination)}}catch{}}
        throw
    }
}
function Get-CcEncVerifiedZip([string]$Store,[string]$Revision,[byte[]]$Key) {
    if($Revision -notmatch '^[0-9a-f]{32}$'){throw 'Invalid generation revision.'}
    $generationRoot=Join-Path $Store 'generations'
    Assert-CcEncNoReparse $Store
    Assert-CcEncNoReparse $generationRoot
    $path=Join-Path $generationRoot ($Revision+'.bin')
    $envelope=Read-CcEncBytesLimited $path $script:CcEncMaxCipherBytes
    $plain=Unprotect-CcEncBytes $envelope $Key
    Add-Type -AssemblyName System.IO.Compression
    $ms=New-Object IO.MemoryStream(,$plain)
    $zip=New-Object IO.Compression.ZipArchive($ms,[IO.Compression.ZipArchiveMode]::Read,$false)
    try {
        if($zip.Entries.Count -gt ($script:CcEncMaxEntries+1)){throw 'Encrypted snapshot ZIP exceeds entry count limit.'}
        $m=$zip.GetEntry('_ccenc_manifest.json')
        if(-not $m -or $m.Length -gt 1MB){throw 'Encrypted snapshot manifest is absent or exceeds 1 MiB.'}
        $sr=New-Object IO.StreamReader($m.Open(),(New-Object Text.UTF8Encoding($false,$true)))
        try {$manifestText=$sr.ReadToEnd();$manifest=$manifestText|ConvertFrom-Json -ErrorAction Stop}
        finally {$sr.Dispose()}
        if($manifest.version -ne 1 -or @($manifest.files).Count -gt $script:CcEncMaxFiles){throw 'Encrypted snapshot manifest is invalid.'}
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $listed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $zipNames=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total=[long]0
        foreach($file in @($manifest.files)) {
            $relative=[string]$file.path
            Assert-CcEncRelativePath $relative
            if(-not $seen.Add($relative)){throw 'Encrypted snapshot contains duplicate or case-conflicting paths.'}
            $length=[long]$file.length
            if($length -lt 0 -or $length -gt $script:CcEncMaxPlainBytes - $total){throw 'Encrypted snapshot exceeds total uncompressed size limit.'}
            $total += $length
            if([string]$file.sha256 -notmatch '^[0-9a-f]{64}$'){throw 'Encrypted snapshot manifest hash is invalid.'}
            $entry=$zip.GetEntry($relative)
            if(-not $entry -or $entry.Length -ne $length){throw 'Encrypted snapshot file inventory mismatch.'}
            [void]$listed.Add($relative)
            $stream=$entry.Open()
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=$sha.ComputeHash($stream)} finally {$stream.Dispose();$sha.Dispose()}
            if(([BitConverter]::ToString($hash).Replace('-','').ToLowerInvariant()) -cne [string]$file.sha256){throw 'Encrypted snapshot file hash mismatch.'}
        }
        foreach($entry in $zip.Entries) {
            if(-not $zipNames.Add($entry.FullName)){throw 'Encrypted ZIP contains duplicate or case-conflicting entries.'}
            if($entry.FullName -ceq '_ccenc_manifest.json'){continue}
            Assert-CcEncRelativePath ([string]$entry.FullName)
            if(-not $listed.Contains($entry.FullName)){throw 'Encrypted ZIP contains an entry not listed in its manifest.'}
        }
        if($zipNames.Count -ne (@($manifest.files).Count+1)){throw 'Encrypted ZIP inventory does not match its manifest.'}
        return [pscustomobject]@{Zip=$zip;Stream=$ms;Plain=$plain;Manifest=$manifest}
    } catch {
        $zip.Dispose();$ms.Dispose();[Array]::Clear($plain,0,$plain.Length)
        throw
    }
}
function Restore-CcEncryptedSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$DestinationRoot,[Parameter(Mandatory)][switch]$StoppedOnly,[switch]$Previous)
    if(-not $StoppedOnly){throw 'Restore requires explicit -StoppedOnly confirmation.'}
    if($Session.Locked -or -not $Session.DataKey){throw 'Encrypted store session is locked.'}
    $p=Get-CcEncPaths $Session.StickRoot
    $dest=[IO.Path]::GetFullPath($DestinationRoot)
    if($dest.Equals([IO.Path]::GetPathRoot($dest),[StringComparison]::OrdinalIgnoreCase)){throw 'Destination cannot be a volume root.'}
    if($dest.StartsWith($p.Store,[StringComparison]::OrdinalIgnoreCase)-or $p.Store.StartsWith($dest,[StringComparison]::OrdinalIgnoreCase)){throw 'Destination cannot overlap encrypted USB store.'}
    Assert-CcEncNoReparse $dest
    if([IO.Directory]::Exists($dest) -and [IO.Directory]::EnumerateFileSystemEntries($dest).GetEnumerator().MoveNext()){throw 'Restore destination must be missing or empty.'}
    $status=Get-CcEncryptedStoreStatus $p.StickRoot
    $revision=if($Previous){$status.PreviousRevision}else{$status.CurrentRevision}
    if(-not $revision){throw 'Requested encrypted snapshot generation does not exist.'}
    $verified=Get-CcEncVerifiedZip $p.Store $revision $Session.DataKey
    $createdFiles=New-Object 'System.Collections.Generic.List[string]'
    $createdDirs=New-Object 'System.Collections.Generic.List[string]'
    $madeRoot=$false
    try {
        # Recheck after decryption and before creating any path.
        Assert-CcEncNoReparse $dest
        if([IO.Directory]::Exists($dest) -and [IO.Directory]::EnumerateFileSystemEntries($dest).GetEnumerator().MoveNext()){throw 'Restore destination changed during verification.'}
        if(-not [IO.Directory]::Exists($dest)){[void][IO.Directory]::CreateDirectory($dest);$madeRoot=$true}
        foreach($file in @($verified.Manifest.files)) {
            $relative=[string]$file.path
            Assert-CcEncRelativePath $relative
            $target=[IO.Path]::GetFullPath((Join-Path $dest ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            $prefix=$dest.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Snapshot path escapes destination.'}
            $parent=Split-Path -Parent $target
            $missing=New-Object 'System.Collections.Generic.Stack[string]'
            $walk=$parent
            while(-not [IO.Directory]::Exists($walk)) {
                if([IO.File]::Exists($walk)){throw 'Restore parent path is occupied by a file.'}
                $missing.Push($walk);$walk=Split-Path -Parent $walk
                if(-not $walk){throw 'Restore destination parent is invalid.'}
            }
            while($missing.Count) {
                $directory=$missing.Pop()
                Assert-CcEncNoReparse $directory
                if([IO.File]::Exists($directory) -or [IO.Directory]::Exists($directory)){throw 'Restore directory appeared concurrently.'}
                [void][IO.Directory]::CreateDirectory($directory)
                $createdDirs.Add($directory)
            }
            Assert-CcEncNoReparse $parent
            Assert-CcEncNoReparse $target
            $input=$verified.Zip.GetEntry($relative).Open()
            $output=$null
            try {
                $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $createdFiles.Add($target)
                $input.CopyTo($output)
                $output.Flush($true)
            } finally {$input.Dispose();if($output){$output.Dispose()}}
        }
        $restoredBytes=([long]0)
        foreach($file in @($verified.Manifest.files)){$restoredBytes += [long]$file.length}
        return [pscustomobject]@{Revision=$revision;DestinationRoot=$dest;Files=$createdFiles.Count;RestoredBytes=$restoredBytes}
    } catch {
        foreach($file in $createdFiles) {
            try {Assert-CcEncNoReparse $file;if([IO.File]::Exists($file)){[IO.File]::Delete($file)}} catch {}
        }
        for($i=$createdDirs.Count-1;$i -ge 0;$i--) {
            try {$directory=$createdDirs[$i];Assert-CcEncNoReparse $directory;if([IO.Directory]::Exists($directory) -and -not [IO.Directory]::EnumerateFileSystemEntries($directory).GetEnumerator().MoveNext()){[IO.Directory]::Delete($directory)}} catch {}
        }
        if($madeRoot) {
            try {Assert-CcEncNoReparse $dest;if([IO.Directory]::Exists($dest) -and -not [IO.Directory]::EnumerateFileSystemEntries($dest).GetEnumerator().MoveNext()){[IO.Directory]::Delete($dest)}} catch {}
        }
        throw
    } finally {$verified.Zip.Dispose();$verified.Stream.Dispose();[Array]::Clear($verified.Plain,0,$verified.Plain.Length)}
}
function Get-CcEncryptedClaudeProvider {
    [CmdletBinding()]param([Parameter(Mandatory)]$Session)
    if($Session.Locked -or -not $Session.DataKey){throw 'Encrypted store session is locked.'}
    $p=Get-CcEncPaths $Session.StickRoot
    $status=Get-CcEncryptedStoreStatus $p.StickRoot
    if(-not $status.CurrentRevision){throw 'No encrypted configuration snapshot is committed.'}
    $verified=Get-CcEncVerifiedZip $p.Store $status.CurrentRevision $Session.DataKey
    try {
        $entry=$verified.Zip.GetEntry('harness/cc-switch/claude/settings.json')
        if(-not $entry){throw 'Fixed Claude provider settings are absent from encrypted snapshot.'}
        if($entry.Length -gt 1MB){throw 'Encrypted Claude provider settings exceed 1 MiB.'}
        $reader=New-Object IO.StreamReader($entry.Open(),(New-Object Text.UTF8Encoding($false,$true)))
        try {$document=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}
        catch {throw 'Encrypted Claude provider settings are invalid JSON.'}
        finally {$reader.Dispose()}
        $name='CC Switch current Claude provider'
        $nameProperty=$document.PSObject.Properties['name']
        if($nameProperty -and $nameProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($nameProperty.Value)){$name=[string]$nameProperty.Value}
        return (ConvertFrom-CcSwitchClaudeDocument -Document $document -Name $name)
    } finally {
        $verified.Zip.Dispose()
        $verified.Stream.Dispose()
        [Array]::Clear($verified.Plain,0,$verified.Plain.Length)
    }
}

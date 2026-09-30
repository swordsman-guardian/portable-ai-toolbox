[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CcClaudeLaunchFilePrefix = 'harness/cc-switch/claude/'
$script:CcClaudeLaunchFileLimit = 8MB
$script:CcClaudeLaunchFileCountLimit = 512
if (-not (Get-Command Get-CcEncVerifiedZip -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
}

function ConvertTo-CcClaudeLaunchFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'A rooted path is required for Claude launch configuration.' }
    $full = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $volume, [StringComparison]::OrdinalIgnoreCase)) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Assert-CcClaudeLaunchNoReparse([string]$Path, [switch]$RequireLeaf) {
    $full = ConvertTo-CcClaudeLaunchFullPath $Path
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Claude launch configuration path contains a reparse point.' }
        } elseif ($RequireLeaf) {
            throw 'A required Claude launch configuration path does not exist.'
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if (-not $parent) { break }
        $cursor = $parent.FullName
    }
}

function ConvertTo-CcClaudeLaunchRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 240 -or $Path.StartsWith('/') -or $Path.StartsWith('\') -or
        $Path.Contains('\') -or $Path -match '[:\x00-\x1f]' -or $Path.Contains('//') -or $Path.EndsWith('/')) {
        throw 'Claude launch file path is invalid.'
    }
    $parts = $Path.Split('/')
    foreach ($part in $parts) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part.Length -gt 255 -or $part -match '[<>"|?*]' -or $part -match '[ .]$') {
            throw 'Claude launch file path contains an invalid component.'
        }
        $base = ($part -split '\.')[0]
        if ($base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Claude launch file path contains a reserved Windows name.' }
    }
    return ($parts -join '/')
}

function Get-CcEncryptedClaudeLaunchBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Session)
    if (-not $Session -or $Session.Locked -or -not $Session.DataKey -or $Session.DataKey.Length -ne 32) {
        throw 'CC Switch encrypted session is locked or has no usable data key.'
    }
    $paths = Get-CcEncPaths ([string]$Session.StickRoot)
    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    $storeLock = $null
    $verified = $null
    $provider = $null
    $settingsFound = $false
    try {
        # Hold the encrypted-store writer lock while capturing the revision and
        # reading both the complete settings tree and its provider projection.
        $storeLock = Enter-CcEncLock $paths.Store
        $capturedRevision = [string]$Session.Revision
        $status = Get-CcEncryptedStoreStatus $paths.StickRoot
        if (-not $status.CurrentRevision) { throw 'No committed CC Switch configuration snapshot is available.' }
        if ($capturedRevision -cne [string]$status.CurrentRevision) { throw 'Encrypted session revision is stale; reopen it before launching Claude.' }
        $verified = Get-CcEncVerifiedZip -Store $paths.Store -Revision $capturedRevision -Key ([byte[]]$Session.DataKey)
        foreach ($file in @($verified.Manifest.files)) {
            $storedPath = [string]$file.path
            if (-not $storedPath.StartsWith($script:CcClaudeLaunchFilePrefix, [StringComparison]::Ordinal)) { continue }
            $relative = ConvertTo-CcClaudeLaunchRelativePath $storedPath.Substring($script:CcClaudeLaunchFilePrefix.Length)
            if (-not $seen.Add($relative)) { throw 'Encrypted Claude launch files contain duplicate or case-conflicting paths.' }
            $length = [long]$file.length
            if ($length -lt 0 -or $length -gt $script:CcClaudeLaunchFileLimit - $total) { throw 'Claude launch files exceed the 8 MiB total limit.' }
            if ($result.Count -ge $script:CcClaudeLaunchFileCountLimit) { throw 'Claude launch file count exceeds the fixed limit.' }
            $entry = $verified.Zip.GetEntry($storedPath)
            if (-not $entry -or $entry.Length -ne $length) { throw 'Verified Claude launch file inventory changed unexpectedly.' }
            $memory = New-Object IO.MemoryStream
            $stream = $entry.Open()
            try {
                $stream.CopyTo($memory)
                if ($memory.Length -ne $length) { throw 'Claude launch file length did not match the verified inventory.' }
                $bytes = $memory.ToArray()
            } finally { $stream.Dispose(); $memory.Dispose() }
            $total += $length
            if ($relative -ceq 'settings.json') {
                $settingsFound = $true
                $jsonText = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
                try { $document = $jsonText | ConvertFrom-Json -ErrorAction Stop }
                catch { throw 'Encrypted Claude provider settings are invalid JSON.' }
                finally { $jsonText = $null }
                $name = 'CC Switch current Claude provider'
                $nameProperty = $document.PSObject.Properties['name']
                if ($nameProperty -and $nameProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($nameProperty.Value)) { $name = [string]$nameProperty.Value }
                $provider = ConvertFrom-CcSwitchClaudeDocument -Document $document -Name $name
                $document = $null
            }
            $result.Add([pscustomobject]@{ Path = $relative; ContentBase64 = [Convert]::ToBase64String($bytes) })
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        if (-not $settingsFound -or -not $provider) { throw 'The committed Claude launch configuration does not contain a usable settings.json provider.' }
        $bundle = [pscustomobject]@{ Revision = $capturedRevision; Provider = $provider; LaunchFiles = $result.ToArray() }
        $provider = $null
        return $bundle
    } finally {
        if ($verified) {
            $verified.Zip.Dispose()
            $verified.Stream.Dispose()
            [Array]::Clear([byte[]]$verified.Plain, 0, $verified.Plain.Length)
        }
        if ($storeLock) { $storeLock.Dispose() }
        if ($provider -and $provider.Secret) { $provider.Secret.Dispose() }
    }
}

function Get-CcEncryptedClaudeLaunchFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Session)
    $bundle = Get-CcEncryptedClaudeLaunchBundle -Session $Session
    try { return $bundle.LaunchFiles }
    finally { if ($bundle.Provider -and $bundle.Provider.Secret) { $bundle.Provider.Secret.Dispose() } }
}

function Assert-CcClaudeLaunchSessionRegistration([string]$SessionRoot, [string]$ConfigDir) {
    $root = ConvertTo-CcClaudeLaunchFullPath $SessionRoot
    $tempRoot = [IO.Directory]::GetParent($root).FullName
    if (-not $tempRoot -or (Split-Path -Leaf $root) -notmatch '^aistick-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
        throw 'Session root is not a registered AIStick launch session.'
    }
    $sessionId = $Matches[1]
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($sessionId, [ref]$guid) -or $guid.ToString() -cne $sessionId) { throw 'Session directory does not contain a canonical registration GUID.' }
    Assert-CcClaudeLaunchNoReparse -Path $root -RequireLeaf
    $work = Join-Path $root 'work'
    $guard = Join-Path $root 'guard'
    $markerPath = Join-Path $root '.session-owner.json'
    foreach ($required in @($work, $guard, $markerPath)) { Assert-CcClaudeLaunchNoReparse -Path $required -RequireLeaf }
    if (-not (Test-Path -LiteralPath $work -PathType Container) -or -not (Test-Path -LiteralPath $guard -PathType Container)) { throw 'Registered session work/guard directories are missing.' }
    $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $recoveryProperty = $marker.PSObject.Properties['recoveryRequired']
    if ([int]$marker.schema -ne 1 -or [string]$marker.sessionId -cne $sessionId -or
        [string]$marker.sessionRoot -cne $root -or [string]$marker.tempRoot -cne $tempRoot -or
        ($recoveryProperty -and $recoveryProperty.Value -eq $true)) { throw 'Session ownership marker does not match the requested launch session.' }
    $pidProperty = $marker.PSObject.Properties['ownerProcessId']
    $startProperty = $marker.PSObject.Properties['ownerStartTimeUtc']
    if (-not $pidProperty -or -not $startProperty) { throw 'Session registration lacks a process identity.' }
    try {
        $owner = Get-Process -Id ([int]$pidProperty.Value) -ErrorAction Stop
        $ownerStart = $owner.StartTime.ToUniversalTime()
        $registeredStart = [DateTime]::Parse([string]$startProperty.Value).ToUniversalTime()
        if ($ownerStart -ne $registeredStart) { throw 'Registered launch session owner is not the same live process.' }
    } catch { throw 'Registered launch session owner is not the same live process.' }
    $expectedConfig = [IO.Path]::GetFullPath((Join-Path $work 'config\claude')).TrimEnd('\', '/')
    $config = ConvertTo-CcClaudeLaunchFullPath $ConfigDir
    if (-not [string]::Equals($config, $expectedConfig, [StringComparison]::OrdinalIgnoreCase)) { throw 'Claude ConfigDir must be the registered session WorkPath config\claude directory.' }
    Assert-CcClaudeLaunchNoReparse -Path $config -RequireLeaf
    if (-not (Test-Path -LiteralPath $config -PathType Container)) { throw 'Registered Claude ConfigDir is missing.' }
    return [pscustomobject]@{ SessionRoot = $root; TempRoot = $tempRoot; WorkPath = $work; ConfigDir = $config; SessionId = $sessionId }
}

function Remove-CcClaudeConfigResidue([string]$ConfigDir) {
    $historyRoots = @('projects','history.jsonl','file-history','plans','tasks','teams')
    $root = ConvertTo-CcClaudeLaunchFullPath $ConfigDir
    Assert-CcClaudeLaunchNoReparse -Path $root -RequireLeaf
    $prefix = $root.TrimEnd('\') + '\'
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($root)) {
        $full = [IO.Path]::GetFullPath($entry)
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Claude config cleanup entry escaped its registered root.' }
        $leaf = [IO.Path]::GetFileName($full)
        $keepHistory = $historyRoots -contains $leaf
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($full)
        $visited = 0
        while ($pending.Count) {
            $current = $pending.Pop()
            if (++$visited -gt 20000) { throw 'Claude config cleanup subtree exceeds the fixed scan limit.' }
            $attributes = [IO.File]::GetAttributes($current)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Claude config cleanup refuses a reparse point in session residue.' }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current)) { $pending.Push($child) }
            }
        }
        if (-not $keepHistory) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
    }
}

function Set-CcClaudeLaunchFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$ConfigDir,
        [Parameter(Mandatory = $true)][string]$SessionRoot
    )
    $registration = Assert-CcClaudeLaunchSessionRegistration -SessionRoot $SessionRoot -ConfigDir $ConfigDir
    if ($Files.Count -gt $script:CcClaudeLaunchFileCountLimit) { throw 'Claude launch file count exceeds the fixed limit.' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $validated = New-Object 'System.Collections.Generic.List[object]'
    $filePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $destinationPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    try {
    foreach ($file in $Files) {
        if (-not $file -or $file.Path -isnot [string] -or $file.ContentBase64 -isnot [string]) { throw 'Claude launch file record is malformed.' }
        $relative = ConvertTo-CcClaudeLaunchRelativePath ([string]$file.Path)
        if (-not $seen.Add($relative)) { throw 'Claude launch files contain duplicate or case-conflicting paths.' }
        [void]$filePaths.Add($relative)
        $encoded = [string]$file.ContentBase64
        if ($encoded.Length -gt 11184816 -or $encoded -notmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') {
            throw 'Claude launch file content is not bounded canonical Base64.'
        }
        try { $bytes = [Convert]::FromBase64String($encoded) } catch { throw 'Claude launch file content is invalid Base64.' }
        if ($bytes.Length -gt $script:CcClaudeLaunchFileLimit - $total) { [Array]::Clear($bytes,0,$bytes.Length); throw 'Claude launch files exceed the 8 MiB total limit.' }
        $total += $bytes.Length
        $destination = [IO.Path]::GetFullPath((Join-Path $registration.ConfigDir ($relative.Replace('/', '\'))))
        $prefix = $registration.ConfigDir.TrimEnd('\') + '\'
        if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { [Array]::Clear($bytes,0,$bytes.Length); throw 'Claude launch destination escaped the registered ConfigDir.' }
        if (-not $destinationPaths.Add($destination)) { [Array]::Clear($bytes,0,$bytes.Length); throw 'Claude launch files resolve to duplicate destination paths.' }
        $validated.Add([pscustomobject]@{ Relative = $relative; Destination = $destination; Bytes = $bytes })
    }

    foreach ($item in $validated) {
        $parent = Split-Path -Path $item.Relative -Parent
        while ($parent) {
            $normalizedParent = $parent.Replace('\', '/')
            if ($filePaths.Contains($normalizedParent)) { throw 'Claude launch files contain a file/directory path collision.' }
            $parent = Split-Path -Path $parent -Parent
        }
    }

        # Validate every target and parent before writing any content.
        foreach ($item in $validated) {
            $parent = [IO.Path]::GetDirectoryName($item.Destination)
            $chain = New-Object 'System.Collections.Generic.Stack[string]'
            $cursor = $parent
            while (-not (Test-Path -LiteralPath $cursor)) {
                $chain.Push($cursor)
                $next = [IO.Directory]::GetParent($cursor)
                if (-not $next -or -not $cursor.StartsWith($registration.ConfigDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Claude launch file parent escaped ConfigDir.' }
                $cursor = $next.FullName
            }
            Assert-CcClaudeLaunchNoReparse -Path $cursor -RequireLeaf
            if (-not (Test-Path -LiteralPath $cursor -PathType Container)) { throw 'Claude launch file parent is not a directory.' }
            if (Test-Path -LiteralPath $item.Destination) {
                Assert-CcClaudeLaunchNoReparse -Path $item.Destination -RequireLeaf
                if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf)) { throw 'Claude launch file destination is not a regular file.' }
            }
        }
        Remove-CcClaudeConfigResidue -ConfigDir $registration.ConfigDir
        foreach ($item in $validated) {
            $parent = [IO.Path]::GetDirectoryName($item.Destination)
            [void][IO.Directory]::CreateDirectory($parent)
            Assert-CcClaudeLaunchNoReparse -Path $parent -RequireLeaf
            Assert-CcClaudeLaunchNoReparse -Path $item.Destination
            [IO.File]::WriteAllBytes($item.Destination, [byte[]]$item.Bytes)
        }
        return $validated.Count
    } finally {
        foreach ($item in $validated) { if ($item.Bytes) { [Array]::Clear([byte[]]$item.Bytes, 0, $item.Bytes.Length) } }
    }
}

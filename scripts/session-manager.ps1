# Session ownership and cleanup helpers. Compatible with Windows PowerShell 5.1.
Set-StrictMode -Version Latest

function ConvertTo-SessionFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "Session path must be absolute: $Path" }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-SessionProcessIdentity {
    param([int]$ProcessId = $PID)
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    return [pscustomobject]@{ ProcessId = $ProcessId; StartTimeUtc = $p.StartTime.ToUniversalTime().ToString('o') }
}

function New-SessionRegistration {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$TempRoot,
        [int]$ProcessId = $PID
    )
    $root = ConvertTo-SessionFullPath $SessionRoot
    $base = ConvertTo-SessionFullPath $TempRoot
    if (-not $root.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Session root is outside approved temp root: $root"
    }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($SessionId, [ref]$guid) -or $guid.ToString() -ne $SessionId.ToLowerInvariant()) {
        throw "Invalid session GUID: $SessionId"
    }
    if ((Split-Path -Leaf $root) -ne "aistick-$($guid.ToString())") { throw 'Session folder name does not match its GUID' }
    $identity = Get-SessionProcessIdentity -ProcessId $ProcessId
    $marker = [pscustomobject]@{
        schema = 1
        sessionId = $guid.ToString()
        sessionRoot = $root
        tempRoot = $base
        ownerProcessId = $identity.ProcessId
        ownerStartTimeUtc = $identity.StartTimeUtc
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $path = Join-Path $root '.session-owner.json'
    [IO.File]::WriteAllText($path, ($marker | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    return $marker
}

function Open-SessionLock {
    param([Parameter(Mandatory)][string]$SessionRoot)
    $root = ConvertTo-SessionFullPath $SessionRoot
    $path = Join-Path $root '.session.lock'
    return New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Set-SessionRecoveryRequired {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$TempRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$ArchiveDir,
        [Parameter(Mandatory)][string]$SourceDir
    )
    $root = ConvertTo-SessionFullPath $SessionRoot
    $base = ConvertTo-SessionFullPath $TempRoot
    $archive = ConvertTo-SessionFullPath $ArchiveDir
    $source = ConvertTo-SessionFullPath $SourceDir
    if (-not $root.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $root) -ne "aistick-$($SessionId.ToLowerInvariant())") {
        throw 'Recovery registration path is outside the matching session sandbox'
    }
    $markerPath = Join-Path $root '.session-owner.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([string]$marker.sessionRoot -ne $root -or [string]$marker.tempRoot -ne $base -or
        [string]$marker.sessionId -ne $SessionId.ToLowerInvariant()) {
        throw 'Recovery registration does not match the session ownership marker'
    }
    $cleanReason = ($Reason -replace '[\r\n\t]+', ' ').Trim()
    if ($cleanReason.Length -gt 400) { $cleanReason = $cleanReason.Substring(0, 400) }
    $marker | Add-Member -NotePropertyName recoveryRequired -NotePropertyValue $true -Force
    $marker | Add-Member -NotePropertyName recoveryReason -NotePropertyValue $cleanReason -Force
    $marker | Add-Member -NotePropertyName recoveryArchiveDir -NotePropertyValue $archive -Force
    $marker | Add-Member -NotePropertyName recoverySourceDir -NotePropertyValue $source -Force
    $marker | Add-Member -NotePropertyName recoveryUpdatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $tempPath = $markerPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, ($marker | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $markerPath -Force
    } finally { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } }
    return $marker
}

function Test-SessionProcessAlive {
    param($Marker)
    if (-not $Marker) { return $null }
    $pidProperty = $Marker.PSObject.Properties['ownerProcessId']
    $timeProperty = $Marker.PSObject.Properties['ownerStartTimeUtc']
    if (-not $pidProperty -or -not $timeProperty -or -not $pidProperty.Value -or -not $timeProperty.Value) { return $null }
    try {
        $p = Get-Process -Id ([int]$Marker.ownerProcessId) -ErrorAction Stop
        $actual = $p.StartTime.ToUniversalTime().ToString('o')
        return ([DateTime]::Parse($actual).ToUniversalTime() -eq [DateTime]::Parse([string]$Marker.ownerStartTimeUtc).ToUniversalTime())
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoProcessFoundForGivenId|ProcessNotFound') { return $false }
        return $null
    }
}

function Test-SessionPathHasNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Boundary)
    $current = ConvertTo-SessionFullPath $Path
    $base = ConvertTo-SessionFullPath $Boundary
    while ($true) {
        if (-not (Test-Path -LiteralPath $current)) { return $false }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($current -eq $base) { return $true }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current -or -not $current.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current = $parent
    }
}

function Remove-OwnedSessionDirectory {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$TempRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$AllowActiveOwner
    )
    $root = ConvertTo-SessionFullPath $SessionRoot
    $base = ConvertTo-SessionFullPath $TempRoot
    if (-not $root.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ((Split-Path -Leaf $root) -ne "aistick-$($SessionId.ToLowerInvariant())") { return $false }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $true }
    if (-not (Test-SessionPathHasNoReparsePoint -Path $root -Boundary $base)) { return $false }
    $markerPath = Join-Path $root '.session-owner.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try { $m = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if ([string]$m.sessionRoot -ne $root -or [string]$m.tempRoot -ne $base -or [string]$m.sessionId -ne $SessionId.ToLowerInvariant()) { return $false }
    $alive = Test-SessionProcessAlive $m
    if ($alive -ne $false -and -not $AllowActiveOwner) { return $false }
    # A successful exclusive open proves no other process currently holds the live lock.
    $lock = $null
    try { $lock = Open-SessionLock -SessionRoot $root } catch { return $false }
    try {
        $again = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([string]$again.sessionId -ne $SessionId.ToLowerInvariant() -or [string]$again.sessionRoot -ne $root) { return $false }
        # Recheck immediately before deletion. Unknown/reused PIDs are treated as active.
        $alive = Test-SessionProcessAlive $again
        if ($alive -ne $false -and -not $AllowActiveOwner) { return $false }
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        # Windows will not recursively remove a directory while its lock file is open.
        # The owner PID/start-time check above remains authoritative across this final close.
        $lock.Dispose(); $lock = $null
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        return $true
    } catch { return $false }
    finally { if ($lock) { $lock.Dispose() } }
}

function Remove-StaleOwnedSessions {
    param([Parameter(Mandatory)][string]$TempRoot, [Parameter(Mandatory)][string]$CurrentSessionRoot)
    $base = ConvertTo-SessionFullPath $TempRoot
    $current = ConvertTo-SessionFullPath $CurrentSessionRoot
    $removed = 0
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return 0 }
    foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'aistick-*' -Force -ErrorAction SilentlyContinue)) {
        $candidate = ConvertTo-SessionFullPath $dir.FullName
        if ($candidate -eq $current -or -not $candidate.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $markerPath = Join-Path $candidate '.session-owner.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
        try { $m = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        # Any missing/invalid identity is unknown and therefore preserved.
        $idProp = $m.PSObject.Properties['sessionId']
        $rootProp = $m.PSObject.Properties['sessionRoot']
        $baseProp = $m.PSObject.Properties['tempRoot']
        if (-not $idProp -or -not $rootProp -or -not $baseProp) { continue }
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([string]$idProp.Value, [ref]$guid)) { continue }
        if ((Split-Path -Leaf $candidate) -ne "aistick-$($guid.ToString())") { continue }
        if ([string]$rootProp.Value -ne $candidate -or [string]$baseProp.Value -ne $base) { continue }
        if (-not (Test-SessionPathHasNoReparsePoint -Path $candidate -Boundary $base)) { continue }
        $recoveryProp = $m.PSObject.Properties['recoveryRequired']
        if ($recoveryProp) {
            $recoveryValue = [string]$recoveryProp.Value
            if ($recoveryValue -notin @('', 'false', 'False', '0')) { continue }
        }
        if ((Test-SessionProcessAlive $m) -ne $false) { continue }
        if (Remove-OwnedSessionDirectory -SessionRoot $candidate -TempRoot $base -SessionId $guid.ToString()) { $removed++ }
    }
    return $removed
}

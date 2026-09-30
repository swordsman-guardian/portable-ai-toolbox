[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session-manager.ps1')

$sandboxId = [guid]::NewGuid().ToString()
$sandbox = [IO.Path]::GetFullPath((Join-Path $env:TEMP "aistick-session-test-$sandboxId"))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$passed = 0
$failed = 0
function Assert-Test([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}

try {
    $activeId = [guid]::NewGuid().ToString()
    $active = Join-Path $sandbox "aistick-$activeId"
    New-Item -ItemType Directory -Path $active -Force | Out-Null
    New-SessionRegistration -SessionRoot $active -SessionId $activeId -TempRoot $sandbox | Out-Null
    $activeLock = Open-SessionLock -SessionRoot $active
    $secondLockFailed = $false
    try { $second = Open-SessionLock -SessionRoot $active; $second.Dispose() } catch { $secondLockFailed = $true }
    Assert-Test $secondLockFailed 'exclusive live-session lock rejects another opener'
    $removedWhileHeld = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot (Join-Path $sandbox 'aistick-current')
    Assert-Test ($removedWhileHeld -eq 0 -and (Test-Path -LiteralPath $active)) 'active owner and locked directory survive orphan scan'
    $activeLock.Dispose()

    $staleId = [guid]::NewGuid().ToString()
    $stale = Join-Path $sandbox "aistick-$staleId"
    New-Item -ItemType Directory -Path $stale -Force | Out-Null
    $marker = New-SessionRegistration -SessionRoot $stale -SessionId $staleId -TempRoot $sandbox
    $marker.ownerProcessId = 2147483000
    $marker.ownerStartTimeUtc = [DateTime]::UtcNow.AddDays(-10).ToString('o')
    [IO.File]::WriteAllText((Join-Path $stale '.session-owner.json'), ($marker | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $staleLock = Open-SessionLock -SessionRoot $stale
    $removedLocked = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot $active
    Assert-Test ($removedLocked -eq 0 -and (Test-Path -LiteralPath $stale)) 'stale marker is preserved while another process holds its lock'
    $staleLock.Dispose()
    $removed = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot $active
    Assert-Test ($removed -eq 1 -and -not (Test-Path -LiteralPath $stale)) 'confirmed dead owner with matching GUID marker is removed'

    $unknownId = [guid]::NewGuid().ToString()
    $unknown = Join-Path $sandbox "aistick-$unknownId"
    New-Item -ItemType Directory -Path $unknown -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unknown 'work') -Value 'untrusted'
    $removedUnknown = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot $active
    Assert-Test ($removedUnknown -eq 0 -and (Test-Path -LiteralPath $unknown)) 'unknown legacy directory without ownership marker is preserved'

    $outsideRejected = $false
    try { New-SessionRegistration -SessionRoot (Join-Path $env:TEMP "aistick-$([guid]::NewGuid())") -SessionId ([guid]::NewGuid().ToString()) -TempRoot $sandbox | Out-Null }
    catch { $outsideRejected = $true }
    Assert-Test $outsideRejected 'registration outside the generated sandbox is rejected'

    $missingFields = [pscustomobject]@{ sessionId = $activeId; sessionRoot = $active; tempRoot = $sandbox }
    Assert-Test ($null -eq (Test-SessionProcessAlive $missingFields)) 'incomplete owner identity is unknown, not treated as dead'
    $unverifiable = [pscustomobject]@{ ownerProcessId = 0; ownerStartTimeUtc = [DateTime]::UtcNow.ToString('o') }
    Assert-Test ($null -eq (Test-SessionProcessAlive $unverifiable)) 'process identity that cannot be verified is preserved as unknown'

    $recoveryId = [guid]::NewGuid().ToString()
    $recovery = Join-Path $sandbox "aistick-$recoveryId"
    New-Item -ItemType Directory -Path $recovery -Force | Out-Null
    $recoveryMarker = New-SessionRegistration -SessionRoot $recovery -SessionId $recoveryId -TempRoot $sandbox
    $recoveryMarker.ownerProcessId = 2147483000
    $recoveryMarker.ownerStartTimeUtc = [DateTime]::UtcNow.AddDays(-10).ToString('o')
    [IO.File]::WriteAllText((Join-Path $recovery '.session-owner.json'), ($recoveryMarker | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $recoveryArchive = Join-Path $sandbox 'archives\runs\recovery-test'
    $recoverySource = Join-Path $recovery 'work\config'
    New-Item -ItemType Directory -Path $recoveryArchive -Force | Out-Null
    Set-SessionRecoveryRequired -SessionRoot $recovery -TempRoot $sandbox -SessionId $recoveryId `
        -Reason 'synthetic final push failure' -ArchiveDir $recoveryArchive -SourceDir $recoverySource | Out-Null
    $recoverySweep = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot $active
    $savedRecoveryMarker = Get-Content -LiteralPath (Join-Path $recovery '.session-owner.json') -Raw | ConvertFrom-Json
    Assert-Test ($recoverySweep -eq 0 -and (Test-Path -LiteralPath $recovery)) 'recovery-required directory survives future orphan cleanup'
    Assert-Test ([bool]$savedRecoveryMarker.recoveryRequired -and $savedRecoveryMarker.recoveryArchiveDir -eq [IO.Path]::GetFullPath($recoveryArchive) -and $savedRecoveryMarker.recoverySourceDir -eq [IO.Path]::GetFullPath($recoverySource)) 'recovery marker retains the retry source and target'
} finally {
    $full = [IO.Path]::GetFullPath($sandbox)
    if ($full.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $full -PathType Container)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Write-Host "Session manager: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0

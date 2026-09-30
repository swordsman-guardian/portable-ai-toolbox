[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session-manager.ps1')

$testId = [guid]::NewGuid().ToString()
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$sandbox = Join-Path $tempBase "aistick-portable-lifecycle-$testId"
$drive = (Split-Path -Qualifier $sandbox).TrimEnd(':')
$pass = 0
$fail = 0
$guardianProcess = $null
$unrelatedLock = $null

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

function Wait-For([scriptblock]$Condition, [int]$TimeoutSeconds = 15) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return [bool](& $Condition)
}

function Write-Text([string]$Path, [string]$Text, [bool]$Bom = $false) {
    $encoding = New-Object Text.UTF8Encoding($Bom)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

try {
    $sessionId = [guid]::NewGuid().ToString()
    $sessionRoot = Join-Path $sandbox "aistick-$sessionId"
    $guardDir = Join-Path $sessionRoot 'guard'
    $workDir = Join-Path $sessionRoot 'work'
    $sourceDir = Join-Path $workDir 'config'
    $stickRoot = Join-Path $sandbox 'synthetic-stick'
    $archiveDir = Join-Path $stickRoot 'sessions\host\harness'
    $unrelatedId = [guid]::NewGuid().ToString()
    $unrelatedRoot = Join-Path $sandbox "aistick-$unrelatedId"
    $unknownRoot = Join-Path $sandbox "aistick-$([guid]::NewGuid().ToString())"
    $identityFile = Join-Path $sandbox 'volume-identity.json'
    $childPidFile = Join-Path $sandbox 'child.pid'
    $guardianOut = Join-Path $sandbox 'guardian.stdout.txt'
    $guardianErr = Join-Path $sandbox 'guardian.stderr.txt'
    $fakeHarness = Join-Path $workDir 'fake-harness.ps1'

    New-Item -ItemType Directory -Path $guardDir, $workDir, $sourceDir, $stickRoot, $archiveDir, $unrelatedRoot, $unknownRoot -Force | Out-Null
    foreach ($name in @('guardian.ps1', 'session-manager.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $guardDir $name) -Force
    }

    # The guardian runs the real lifecycle script against a copied lib whose volume query
    # reads this synthetic identity file. The host drive itself is never modified.
    $libText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib.ps1'))
    $identityLiteral = $identityFile.Replace("'", "''")
    $libText += @"
function Get-VolumeIdentity {
    param([Parameter(Mandatory)][string]`$StickRoot)
    return (Get-Content -LiteralPath '$identityLiteral' -Raw | ConvertFrom-Json)
}
"@
    Write-Text (Join-Path $guardDir 'lib.ps1') $libText $true

    $syncText = @'
[CmdletBinding()]
param([string]$SourceDir,[string]$SessionsDir,[string]$Direction='Push',[switch]$Quiet)
if ($Direction -eq 'Push') { [pscustomobject]@{ copied=0; appended=0; skipped=0; bytes=0; failed=0 } }
'@
    Write-Text (Join-Path $guardDir 'sync.ps1') $syncText $true

    $childScript = Join-Path $workDir 'fake-child.ps1'
    Write-Text $childScript "while (`$true) { Start-Sleep -Seconds 1 }`n" $true
    $pidLiteral = $childPidFile.Replace("'", "''")
    $childLiteral = $childScript.Replace("'", "''")
    $harnessText = @"
`$child = Start-Process -FilePath '$PSHOME\powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$childLiteral') -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText('$pidLiteral', (`$child.Id.ToString() + '|' + `$child.StartTime.ToUniversalTime().ToString('o')))
while (`$true) { Start-Sleep -Seconds 1 }
"@
    Write-Text $fakeHarness $harnessText $true

    New-SessionRegistration -SessionRoot $sessionRoot -SessionId $sessionId -TempRoot $sandbox | Out-Null
    New-SessionRegistration -SessionRoot $unrelatedRoot -SessionId $unrelatedId -TempRoot $sandbox | Out-Null
    $unrelatedLock = Open-SessionLock -SessionRoot $unrelatedRoot
    $unknownSentinel = Join-Path $unknownRoot 'keep.txt'
    Write-Text $unknownSentinel 'unowned fixture'

    $expected = [pscustomobject]@{ DriveLetter = $drive; VolumeGuid = 'synthetic-volume-A'; Serial = 'synthetic-serial-A'; Label = 'fixture' }
    Write-Text $identityFile ($expected | ConvertTo-Json -Depth 3)
    $guardianArgs = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $guardDir 'guardian.ps1'),
        '-StickRoot',$stickRoot,'-SessionRoot',$sessionRoot,'-GuardDir',$guardDir,
        '-DriveLetter',$drive,'-VolumeGuid',$expected.VolumeGuid,'-Serial',$expected.Serial,
        '-HarnessExe',"$PSHOME\powershell.exe",'-WorkingDir',$workDir,'-HarnessArgs',$fakeHarness,
        '-SessionsDir',$archiveDir,'-SourceDir',$sourceDir,'-SyncSeconds','600','-SessionId',$sessionId
    )
    $guardianProcess = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $guardianArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $guardianOut -RedirectStandardError $guardianErr
    $childStarted = Wait-For { Test-Path -LiteralPath $childPidFile } 20
    Check 'guardian started its owned harness and descendant' $childStarted
    if (-not $childStarted) {
        if (Test-Path $guardianOut) { Get-Content $guardianOut | Write-Host }
        if (Test-Path $guardianErr) { Get-Content $guardianErr | Write-Host }
        throw 'Fixture child process did not start.'
    }
    $childRecord = [IO.File]::ReadAllText($childPidFile).Split('|')
    $childPid = [int]$childRecord[0]
    $childStart = [DateTime]::Parse($childRecord[1]).ToUniversalTime()
    $childWasRunning = $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
    Check 'synthetic descendant is alive before removal signal' $childWasRunning

    $replacement = [pscustomobject]@{ DriveLetter = $drive; VolumeGuid = 'replacement-volume-B'; Serial = 'replacement-serial-B'; Label = 'fixture replacement' }
    Write-Text $identityFile ($replacement | ConvertTo-Json -Depth 3)

    $guardianExited = Wait-For { $guardianProcess.Refresh(); $guardianProcess.HasExited } 25
    Check 'changed volume identity signals removal and exits guardian' $guardianExited
    $childGone = Wait-For { $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue) } 10
    Check 'removal terminates the guardian-owned descendant process' $childGone
    Check 'removal deletes the temporary session directory' (-not (Test-Path -LiteralPath $sessionRoot))
    Check 'independent owned instance remains untouched' (Test-Path -LiteralPath $unrelatedRoot)
    Check 'unknown same-prefix directory remains untouched' ((Test-Path -LiteralPath $unknownRoot) -and (Test-Path -LiteralPath $unknownSentinel))

    # The existing retention policy preserves failed-save recovery folders and sweeps only
    # stale, valid, non-recovery session markers on a later launcher startup.
    $recoveryId = [guid]::NewGuid().ToString()
    $recoveryRoot = Join-Path $sandbox "aistick-$recoveryId"
    New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
    $recoveryMarker = New-SessionRegistration -SessionRoot $recoveryRoot -SessionId $recoveryId -TempRoot $sandbox
    $recoveryMarker.ownerProcessId = 2147483000
    $recoveryMarker.ownerStartTimeUtc = [DateTime]::UtcNow.AddDays(-2).ToString('o')
    Write-Text (Join-Path $recoveryRoot '.session-owner.json') ($recoveryMarker | ConvertTo-Json -Depth 4)
    Set-SessionRecoveryRequired -SessionRoot $recoveryRoot -TempRoot $sandbox -SessionId $recoveryId `
        -Reason 'synthetic save failure' -ArchiveDir $archiveDir -SourceDir $sourceDir | Out-Null
    $sweptId = [guid]::NewGuid().ToString()
    $sweptRoot = Join-Path $sandbox "aistick-$sweptId"
    New-Item -ItemType Directory -Path $sweptRoot -Force | Out-Null
    $sweptMarker = New-SessionRegistration -SessionRoot $sweptRoot -SessionId $sweptId -TempRoot $sandbox
    $sweptMarker.ownerProcessId = 2147483000
    $sweptMarker.ownerStartTimeUtc = [DateTime]::UtcNow.AddDays(-2).ToString('o')
    Write-Text (Join-Path $sweptRoot '.session-owner.json') ($sweptMarker | ConvertTo-Json -Depth 4)
    $swept = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot (Join-Path $sandbox 'aistick-current')
    $recoveryStillExists = Test-Path -LiteralPath $recoveryRoot
    Check 'orphan sweep retains a recovery-required session' ($recoveryStillExists -and $swept -eq 1)
    Check 'orphan sweep removes only the stale valid owned session' (-not (Test-Path -LiteralPath $sweptRoot) -and (Test-Path -LiteralPath $unrelatedRoot) -and $recoveryStillExists)
    Check 'unknown directory still survives the orphan sweep' (Test-Path -LiteralPath $unknownSentinel)
} finally {
    if ($unrelatedLock) { $unrelatedLock.Dispose() }
    if ($guardianProcess) {
        try { $guardianProcess.Refresh(); if (-not $guardianProcess.HasExited) { Stop-Process -Id $guardianProcess.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    if (Test-Path -LiteralPath $childPidFile) {
        try {
            $leftRecord = [IO.File]::ReadAllText($childPidFile).Split('|')
            $leftPid = [int]$leftRecord[0]
            $left = Get-Process -Id $leftPid -ErrorAction SilentlyContinue
            if ($left -and [DateTime]::Parse($left.StartTime.ToUniversalTime().ToString('o')).ToUniversalTime() -eq [DateTime]::Parse($leftRecord[1]).ToUniversalTime()) {
                Stop-Process -Id $leftPid -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    $fullSandbox = [IO.Path]::GetFullPath($sandbox)
    if ($fullSandbox.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $fullSandbox) -eq "aistick-portable-lifecycle-$testId" -and
        (Test-Path -LiteralPath $fullSandbox -PathType Container)) {
        Remove-Item -LiteralPath $fullSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Portable lifecycle: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0

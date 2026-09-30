[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'session-manager.ps1')

$testId = [guid]::NewGuid().ToString()
$sandbox = [IO.Path]::GetFullPath((Join-Path $env:TEMP "ai-guardian-sync-$testId"))
$sessionId = [guid]::NewGuid().ToString()
$sessionRoot = Join-Path $sandbox "aistick-$sessionId"
$guardDir = Join-Path $sessionRoot 'guard'
$workDir = Join-Path $sessionRoot 'work'
$stickRoot = Join-Path $sandbox 'stick'
$sourceDir = Join-Path $workDir 'config'
$archiveDir = Join-Path $sandbox 'archives\runs\test-run'
$eventsFile = Join-Path $archiveDir 'sync-events.txt'
$nodeExe = Join-Path (Get-StickRoot -ScriptDir $PSScriptRoot) 'runtime\node\node.exe'
$pass = 0
$fail = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}

try {
    if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) { throw "Missing fake harness runtime: $nodeExe" }
    New-Item -ItemType Directory -Path $guardDir, $workDir, $stickRoot, $sourceDir, $archiveDir -Force | Out-Null
    foreach ($name in @('lib.ps1', 'guardian.ps1', 'session-manager.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $guardDir $name) -Force
    }
    New-SessionRegistration -SessionRoot $sessionRoot -SessionId $sessionId -TempRoot $sandbox | Out-Null

    $fakeSync = @'
[CmdletBinding()]
param([string]$SourceDir,[string]$SessionsDir,[string]$Direction='Push',[switch]$Quiet)
$ErrorActionPreference='Stop'
if ($Direction -eq 'Push') {
    $eventPath = Join-Path $SessionsDir 'sync-events.txt'
    $lockPath = Join-Path $SessionsDir 'sync-exclusive.lock'
    $lease = $null
    try { $lease = New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { Add-Content -LiteralPath $eventPath -Value 'OVERLAP' -Encoding UTF8; throw }
    try {
        Add-Content -LiteralPath $eventPath -Value 'START' -Encoding UTF8
        Start-Sleep -Milliseconds 4500
        Add-Content -LiteralPath $eventPath -Value 'END' -Encoding UTF8
    } finally { $lease.Dispose() }
    [pscustomobject]@{ copied=1; appended=0; skipped=0; bytes=1; failed=0; conflicts=0 }
}
'@
    [IO.File]::WriteAllText((Join-Path $guardDir 'sync.ps1'), $fakeSync, (New-Object Text.UTF8Encoding($true)))
    $harnessJs = Join-Path $workDir 'fake-harness.js'
    [IO.File]::WriteAllText($harnessJs, 'setTimeout(()=>{}, 4000);', (New-Object Text.UTF8Encoding($false)))
    $vol = Get-VolumeIdentity -StickRoot ([IO.Path]::GetPathRoot($sandbox))
    $harnessArgs = @($harnessJs)
    $guardian = Join-Path $guardDir 'guardian.ps1'
    $args = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$guardian,
        '-StickRoot',$stickRoot,'-SessionRoot',$sessionRoot,'-GuardDir',$guardDir,
        '-DriveLetter',$vol.DriveLetter,'-VolumeGuid',$vol.VolumeGuid,'-Serial',$vol.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$workDir,'-HarnessArgs',$harnessArgs,
        '-SessionsDir',$archiveDir,'-SourceDir',$sourceDir,'-SyncSeconds','1',
        '-SyncDrainTimeoutSeconds','12','-SyncStopTimeoutSeconds','3'
    )
    & (Join-Path $PSHOME 'powershell.exe') @args
    $guardianExit = $LASTEXITCODE
    Check 'guardian exits successfully' ($guardianExit -eq 0) "exit=$guardianExit"
    Check 'owned session directory is cleaned' (-not (Test-Path -LiteralPath $sessionRoot))

    $events = @()
    if (Test-Path -LiteralPath $eventsFile) { $events = @(Get-Content -LiteralPath $eventsFile) }
    Check 'a background Push and final Push both completed' (@($events | Where-Object { $_ -eq 'START' }).Count -eq 2 -and @($events | Where-Object { $_ -eq 'END' }).Count -eq 2)
    Check 'the long background Push did not overlap final Push' (($events -join ',') -eq 'START,END,START,END') ($events -join ',')
    Check 'no overlapping writer was detected' (-not ($events -contains 'OVERLAP'))

    # Final-Push failure must preserve a recovery copy and make orphan cleanup skip it.
    $failedId = [guid]::NewGuid().ToString()
    $failedRoot = Join-Path $sandbox "aistick-$failedId"
    $failedGuard = Join-Path $failedRoot 'guard'
    $failedWork = Join-Path $failedRoot 'work'
    $failedStick = Join-Path $sandbox 'stick-failure'
    $failedSource = Join-Path $failedWork 'config'
    $failedArchive = Join-Path $sandbox 'archives\runs\failed-test'
    New-Item -ItemType Directory -Path $failedGuard, $failedWork, $failedSource, $failedStick, $failedArchive `
        -Force | Out-Null
    foreach ($name in @('lib.ps1', 'guardian.ps1', 'session-manager.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $failedGuard $name) -Force
    }
    New-SessionRegistration -SessionRoot $failedRoot -SessionId $failedId -TempRoot $sandbox | Out-Null
    $failureSync = @'
[CmdletBinding()]
param([string]$SourceDir,[string]$SessionsDir,[string]$Direction='Push',[switch]$Quiet)
throw 'intentional synthetic Push failure'
'@
    $failedSyncPath = Join-Path $failedGuard 'sync.ps1'
    [IO.File]::WriteAllText($failedSyncPath, $failureSync, (New-Object Text.UTF8Encoding($true)))
    New-Item -ItemType Directory -Path (Join-Path $failedStick 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $failedSyncPath -Destination (Join-Path $failedStick 'scripts\sync.ps1') -Force
    $failedJs = Join-Path $failedWork 'fake-harness.js'
    [IO.File]::WriteAllText($failedJs, 'setTimeout(()=>{}, 2500);', (New-Object Text.UTF8Encoding($false)))
    $failedArgs = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $failedGuard 'guardian.ps1'),
        '-StickRoot',$failedStick,'-SessionRoot',$failedRoot,'-GuardDir',$failedGuard,
        '-DriveLetter',$vol.DriveLetter,'-VolumeGuid',$vol.VolumeGuid,'-Serial',$vol.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$failedWork,'-HarnessArgs',$failedJs,
        '-SessionsDir',$failedArchive,'-SourceDir',$failedSource,'-SyncSeconds','1'
    )
    & (Join-Path $PSHOME 'powershell.exe') @failedArgs
    $failedExit = $LASTEXITCODE
    $failedMarker = Get-Content -LiteralPath (Join-Path $failedRoot '.session-owner.json') -Raw | ConvertFrom-Json
    Check 'failed final Push returns non-zero' ($failedExit -ne 0) "exit=$failedExit"
    Check 'failed final Push retains a recovery directory and retry target' `
        ([bool]$failedMarker.recoveryRequired -and [string]$failedMarker.recoveryArchiveDir -eq [IO.Path]::GetFullPath($failedArchive) -and
         [string]$failedMarker.recoverySourceDir -eq [IO.Path]::GetFullPath($failedSource) -and (Test-Path -LiteralPath $failedRoot))
    $preserved = Remove-StaleOwnedSessions -TempRoot $sandbox -CurrentSessionRoot $sessionRoot
    Check 'next orphan scan preserves recovery-required data' ($preserved -eq 0 -and (Test-Path -LiteralPath $failedRoot))

    # Replace only the test copy's Job limit readback to force the pre-launch failure branch.
    $jobId = [guid]::NewGuid().ToString()
    $jobRoot = Join-Path $sandbox "aistick-$jobId"
    $jobGuard = Join-Path $jobRoot 'guard'
    $jobWork = Join-Path $jobRoot 'work'
    $jobStick = Join-Path $sandbox 'stick-job-failure'
    $jobSource = Join-Path $jobWork 'config'
    $jobArchive = Join-Path $sandbox 'archives\runs\job-failure'
    $sentinel = Join-Path $sandbox 'job-harness-started.txt'
    New-Item -ItemType Directory -Path $jobGuard, $jobWork, $jobSource, $jobStick, $jobArchive `
        -Force | Out-Null
    foreach ($name in @('lib.ps1', 'session-manager.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $jobGuard $name) -Force
    }
    $guardianText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'guardian.ps1'))
    $needle = '$effective = [JobObj]::GetLimitFlags($hJob)'
    if (-not $guardianText.Contains($needle)) { throw 'Job readback statement not found for fixture-only failure injection' }
    $guardianText = $guardianText.Replace($needle, '$effective = [uint32]0')
    [IO.File]::WriteAllText((Join-Path $jobGuard 'guardian.ps1'), $guardianText, (New-Object Text.UTF8Encoding($true)))
    New-SessionRegistration -SessionRoot $jobRoot -SessionId $jobId -TempRoot $sandbox | Out-Null
    $jobJs = Join-Path $jobWork 'sentinel.js'
    $sentinelForJs = $sentinel.Replace('\', '/')
    [IO.File]::WriteAllText($jobJs, "require('fs').writeFileSync('$sentinelForJs','started');", (New-Object Text.UTF8Encoding($false)))
    $jobArgs = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $jobGuard 'guardian.ps1'),
        '-StickRoot',$jobStick,'-SessionRoot',$jobRoot,'-GuardDir',$jobGuard,
        '-DriveLetter',$vol.DriveLetter,'-VolumeGuid',$vol.VolumeGuid,'-Serial',$vol.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$jobWork,'-HarnessArgs',$jobJs,
        '-SessionsDir',$jobArchive,'-SourceDir',$jobSource,'-SyncSeconds','1'
    )
    & (Join-Path $PSHOME 'powershell.exe') @jobArgs
    $jobExit = $LASTEXITCODE
    Check 'failed Job limit readback returns non-zero' ($jobExit -ne 0) "exit=$jobExit"
    Check 'failed Job limit readback cleans only its registered session' (-not (Test-Path -LiteralPath $jobRoot))
    Check 'fake harness is not started when Job protection is missing' (-not (Test-Path -LiteralPath $sentinel))
} finally {
    $full = [IO.Path]::GetFullPath($sandbox)
    $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($full.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -eq "ai-guardian-sync-$testId" -and
        (Test-Path -LiteralPath $full -PathType Container)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Host "Guardian sync drain: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0

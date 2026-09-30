[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session-manager.ps1')

$testId = [guid]::NewGuid().ToString()
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$sandbox = Join-Path $tempBase "ai-guardian-direct-usb-$testId"
$drive = (Split-Path -Qualifier $sandbox).TrimEnd(':')
$nodeExe = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node\node.exe'
$childToken = 'fixture-child-' + $testId
$pass = 0
$fail = 0
$normalGuardian = $null
$removeGuardian = $null
$independentLock = $null
$childPidFile = $null

function Check([string]$Name,[bool]$Ok,[string]$Detail='') {
    if ($Ok) { $script:pass++; Write-Host "PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}
function Wait-For([scriptblock]$Condition,[int]$TimeoutSeconds=20) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    return [bool](& $Condition)
}
function Write-Text([string]$Path,[string]$Text,[bool]$Bom=$false) {
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($Bom)))
}
function Show-LogIfAvailable([string]$Path) {
    for ($i=0; $i -lt 10; $i++) {
        try { if ([IO.File]::Exists($Path)) { [IO.File]::ReadAllText($Path) | Write-Host }; return } catch { Start-Sleep -Milliseconds 150 }
    }
}
function Quote-Arg([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $b=New-Object Text.StringBuilder; [void]$b.Append('"'); $slashes=0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$b.Append(('\' * (2*$slashes+1))); [void]$b.Append('"'); $slashes=0; continue }
        if ($slashes) { [void]$b.Append(('\' * $slashes)); $slashes=0 }
        [void]$b.Append($ch)
    }
    if ($slashes) { [void]$b.Append(('\' * (2*$slashes))) }
    [void]$b.Append('"'); return $b.ToString()
}
function New-DirectFixture([string]$Name) {
    $id=[guid]::NewGuid().ToString()
    $session=Join-Path $sandbox "aistick-$id"
    $guard=Join-Path $session 'guard'; $work=Join-Path $session 'work'
    $stick=Join-Path $sandbox "$Name-stick"
    $source=Join-Path $stick 'harness\cc-config'
    $sessions=Join-Path $stick 'sessions\compat'
    $archive=Join-Path $stick 'sessions\compat'
    New-Item -ItemType Directory -Path $guard,$work,$source,$sessions -Force | Out-Null
    foreach ($file in @('guardian.ps1','session-manager.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $guard $file) -Force }
    $lib=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib.ps1'))
    $identityPath=(Join-Path $sandbox 'volume-identity.json').Replace("'","''")
    $lib += @"
function Get-VolumeIdentity {
    param([Parameter(Mandatory)][string]`$StickRoot)
    return (Get-Content -LiteralPath '$identityPath' -Raw | ConvertFrom-Json)
}
"@
    Write-Text (Join-Path $guard 'lib.ps1') $lib $true
    $fixture=[pscustomobject]@{ Id=$id; Session=$session; Guard=$guard; Work=$work; Stick=$stick; Source=$source; Sessions=$sessions; Archive=$archive }
    New-SessionRegistration -SessionRoot $session -SessionId $id -TempRoot $sandbox | Out-Null
    return $fixture
}
function Start-DirectGuardian($Fixture,[string[]]$HarnessArgs,[string]$OutputPath,[string]$ErrorPath) {
    $a=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Fixture.Guard 'guardian.ps1'),
        '-StickRoot',$Fixture.Stick,'-SessionRoot',$Fixture.Session,'-GuardDir',$Fixture.Guard,
        '-DriveLetter',$drive,'-VolumeGuid','directusb-volume-A','-Serial','directusb-serial-A',
        '-HarnessExe',$nodeExe,'-WorkingDir',$Fixture.Source,'-HarnessArgs') + $HarnessArgs + @(
        '-SessionsDir',$Fixture.Sessions,'-SourceDir',$Fixture.Source,'-StorageMode','DirectUsb','-SessionId',$Fixture.Id,'-SyncSeconds','1')
    $quoted=@($a | ForEach-Object { Quote-Arg ([string]$_) })
    return Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $quoted -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $identityFile=Join-Path $sandbox 'volume-identity.json'
    $expected=[pscustomobject]@{ DriveLetter=$drive; VolumeGuid='directusb-volume-A'; Serial='directusb-serial-A'; Label='synthetic A' }
    Write-Text $identityFile ($expected | ConvertTo-Json -Depth 3)

    if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) { throw "Missing synthetic harness runtime: $nodeExe" }
    $harnessPath=Join-Path $sandbox 'fake-harness.js'
    $configMarker=Join-Path $sandbox 'child.pid'
    $harnessText=@'
const fs=require('fs'), path=require('path'), cp=require('child_process');
const config=process.cwd(), stick=path.basename(path.resolve(config,'../..'));
if(stick==='normal-stick') { fs.writeFileSync(path.join(config,'settings.json'),'synthetic usb direct write'); setTimeout(()=>process.exit(0),1500); }
else {
  const child=cp.spawn(process.execPath,['-e','setInterval(()=>{},1000)','__CHILD_TOKEN__'],{stdio:'ignore'});
  fs.writeFileSync(path.resolve(config,'../../..','child.pid'),String(child.pid));
  fs.writeFileSync(path.join(config,'settings.json'),'synthetic usb direct write before removal');
  setInterval(()=>{},1000);
}
'@
    $harnessText=$harnessText.Replace('__CHILD_TOKEN__',$childToken)
    Write-Text $harnessPath $harnessText $false

    $normal=New-DirectFixture 'normal'
    $syncSentinel=Join-Path $normal.Guard 'sync-called.txt'
    $syncPath=Join-Path $normal.Guard 'sync.ps1'
    Write-Text $syncPath "[IO.File]::WriteAllText('$($syncSentinel.Replace("'","''"))','called'); throw 'sync must not run in DirectUsb'" $true
    $normalOut=Join-Path $sandbox 'normal.stdout.txt'; $normalErr=Join-Path $sandbox 'normal.stderr.txt'
    $normalArgs=@($harnessPath)
    $normalGuardian=Start-DirectGuardian $normal $normalArgs $normalOut $normalErr
    $normalExited=Wait-For { $normalGuardian.Refresh(); $normalGuardian.HasExited } 35
    Check 'DirectUsb normal session exits' $normalExited
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path -LiteralPath (Join-Path $normal.Source 'settings.json'))) { Show-LogIfAvailable $normalOut; Show-LogIfAvailable $normalErr }
    $normalConfig=Join-Path $normal.Source 'settings.json'
    Check 'application-written USB config is retained' ((Test-Path -LiteralPath $normalConfig) -and [IO.File]::ReadAllText($normalConfig) -eq 'synthetic usb direct write')
    Check 'normal DirectUsb exit removes its owned local session' (-not (Test-Path -LiteralPath $normal.Session))
    Check 'DirectUsb never invokes sync.ps1' (-not (Test-Path -LiteralPath $syncSentinel))
    $normalSummary=''
    if (Test-Path -LiteralPath $normalOut) { $normalSummary=[IO.File]::ReadAllText($normalOut) }
    Check 'summary says application writes USB and archive was not verified' ($normalSummary.Contains('应用配置直接写入 U 盘') -and $normalSummary.Contains('guardian 只检查该路径') -and $normalSummary.Contains('未验证归档或数据库提交') -and $normalSummary.Contains('不适用（DirectUsb）'))

    $remove=New-DirectFixture 'remove'
    $removeSyncSentinel=Join-Path $remove.Guard 'sync-called.txt'
    $removeSyncPath=Join-Path $remove.Guard 'sync.ps1'
    Write-Text $removeSyncPath "[IO.File]::WriteAllText('$($removeSyncSentinel.Replace("'","''"))','called'); throw 'sync must not run in DirectUsb'" $true
    $independentId=[guid]::NewGuid().ToString(); $independentRoot=Join-Path $sandbox "aistick-$independentId"
    New-Item -ItemType Directory -Path $independentRoot -Force | Out-Null
    New-SessionRegistration -SessionRoot $independentRoot -SessionId $independentId -TempRoot $sandbox | Out-Null
    $independentLock=Open-SessionLock -SessionRoot $independentRoot
    $removeOut=Join-Path $sandbox 'remove.stdout.txt'; $removeErr=Join-Path $sandbox 'remove.stderr.txt'
    $childPidFile=Join-Path $sandbox 'child.pid'
    $removeArgs=@($harnessPath)
    $removeGuardian=Start-DirectGuardian $remove $removeArgs $removeOut $removeErr
    $childStarted=Wait-For { Test-Path -LiteralPath $childPidFile } 20
    Check 'removal fixture starts a Job descendant' $childStarted
    if (-not $childStarted) { Start-Sleep -Milliseconds 300; Show-LogIfAvailable $removeOut; Show-LogIfAvailable $removeErr; throw 'Owned fixture descendant did not start.' }
    $childPid=[int][IO.File]::ReadAllText($childPidFile)
    $replacement=[pscustomobject]@{ DriveLetter=$drive; VolumeGuid='directusb-volume-B'; Serial='directusb-serial-B'; Label='synthetic replacement' }
    Write-Text $identityFile ($replacement | ConvertTo-Json -Depth 3)
    $removeExited=Wait-For { $removeGuardian.Refresh(); $removeGuardian.HasExited } 30
    Check 'replacement volume triggers guardian removal handling' $removeExited
    $childGone=Wait-For { $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue) } 10
    Check 'removal terminates only the guardian Job descendant' $childGone
    Check 'removal deletes this local session directory' (-not (Test-Path -LiteralPath $remove.Session))
    Check 'removal preserves another active owned instance' (Test-Path -LiteralPath $independentRoot)
    Check 'DirectUsb removal does not invoke sync.ps1' (-not (Test-Path -LiteralPath $removeSyncSentinel))
    Check 'USB config written before removal remains on the synthetic stick' ((Test-Path -LiteralPath (Join-Path $remove.Source 'settings.json')) -and [IO.File]::ReadAllText((Join-Path $remove.Source 'settings.json')) -eq 'synthetic usb direct write before removal')

    $outside=New-DirectFixture 'outside'
    $outsidePath=Join-Path $sandbox 'outside-config'; New-Item -ItemType Directory -Path $outsidePath -Force | Out-Null
    $startSentinel=Join-Path $outside.Work 'harness-started.txt'
    $startScript=Join-Path $sandbox 'must-not-start.js'
    Write-Text $startScript "require('fs').writeFileSync('$($startSentinel.Replace('\','/'))','started');" $false
    $outsideOut=Join-Path $sandbox 'outside.stdout.txt'; $outsideErr=Join-Path $sandbox 'outside.stderr.txt'
    $badArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $outside.Guard 'guardian.ps1'),
        '-StickRoot',$outside.Stick,'-SessionRoot',$outside.Session,'-GuardDir',$outside.Guard,
        '-DriveLetter',$drive,'-VolumeGuid',$expected.VolumeGuid,'-Serial',$expected.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$outside.Work,'-HarnessArgs',$startScript,
        '-SessionsDir',$outside.Sessions,'-SourceDir',$outsidePath,'-StorageMode','DirectUsb','-SessionId',$outside.Id)
    $badQuoted=@($badArgs | ForEach-Object { Quote-Arg ([string]$_) })
    $badProcess=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $badQuoted -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $outsideOut -RedirectStandardError $outsideErr
    Check 'configuration path outside StickRoot is rejected' ($badProcess.ExitCode -ne 0)
    Check 'outside path rejection happens before harness startup' (-not (Test-Path -LiteralPath $startSentinel))
    $outsideLock=$null
    try { $outsideLock=Open-SessionLock -SessionRoot $outside.Session } catch { }
    if ($outsideLock) { $outsideLock.Dispose() }
    Remove-OwnedSessionDirectory -SessionRoot $outside.Session -TempRoot $sandbox -SessionId $outside.Id -AllowActiveOwner | Out-Null

    $overlap=New-DirectFixture 'overlap'
    $overlapConfig=Join-Path $overlap.Source 'settings.json'
    Write-Text $overlapConfig 'keep overlap fixture data' $false
    $overlapStart=Join-Path $overlap.Work 'harness-started.txt'
    $overlapScript=Join-Path $sandbox 'overlap-must-not-start.js'
    Write-Text $overlapScript "require('fs').writeFileSync('$($overlapStart.Replace('\','/'))','started');" $false
    $overlapArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $overlap.Guard 'guardian.ps1'),
        '-StickRoot',$sandbox,'-SessionRoot',$overlap.Session,'-GuardDir',$overlap.Guard,
        '-DriveLetter',$drive,'-VolumeGuid',$expected.VolumeGuid,'-Serial',$expected.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$overlap.Work,'-HarnessArgs',$overlapScript,
        '-SessionsDir',$overlap.Sessions,'-SourceDir',$overlap.Source,'-StorageMode','DirectUsb','-SessionId',$overlap.Id)
    $overlapQuoted=@($overlapArgs | ForEach-Object { Quote-Arg ([string]$_) })
    $overlapProcess=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $overlapQuoted -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $sandbox 'overlap.stdout.txt') -RedirectStandardError (Join-Path $sandbox 'overlap.stderr.txt')
    Check 'SessionRoot overlapping StickRoot is rejected' ($overlapProcess.ExitCode -ne 0)
    Check 'overlap rejection happens before harness startup' (-not (Test-Path -LiteralPath $overlapStart))
    Check 'overlap rejection leaves synthetic USB data untouched' ((Test-Path -LiteralPath $overlapConfig) -and [IO.File]::ReadAllText($overlapConfig) -eq 'keep overlap fixture data')
    $overlapLock=$null
    try { $overlapLock=Open-SessionLock -SessionRoot $overlap.Session } catch { }
    if ($overlapLock) { $overlapLock.Dispose() }
    Remove-OwnedSessionDirectory -SessionRoot $overlap.Session -TempRoot $sandbox -SessionId $overlap.Id -AllowActiveOwner | Out-Null

    $guardianAstTokens=$null; $guardianAstErrors=$null
    $guardianAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'guardian.ps1'),[ref]$guardianAstTokens,[ref]$guardianAstErrors)
    if ($guardianAstErrors.Count -gt 0) { throw 'Unable to parse guardian AST for root-boundary helper test.' }
    $helperAst=$guardianAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-DirectUsbDirectory' },$true)
    if (-not $helperAst) { throw 'Assert-DirectUsbDirectory was not found in guardian AST.' }
    Invoke-Expression $helperAst.Extent.Text
    $systemRoot=$env:SystemDrive + '\'
    $rootBoundaryRejected=$false
    try { Assert-DirectUsbDirectory -Path $systemRoot -Root $systemRoot -Label 'root boundary fixture' | Out-Null }
    catch { $rootBoundaryRejected=$_.Exception.Message.Contains('不能直接使用盘根目录') }
    Check 'volume root is rejected before any filesystem write' $rootBoundaryRejected

    $reparse=New-DirectFixture 'reparse'
    $reparseTarget=Join-Path $sandbox 'reparse-target'; New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    $junction=Join-Path $reparse.Stick 'harness\linked-config'
    New-Item -ItemType Junction -Path $junction -Target $reparseTarget | Out-Null
    $linkSource=Join-Path $junction 'nested-config'; New-Item -ItemType Directory -Path $linkSource -Force | Out-Null
    $linkArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $reparse.Guard 'guardian.ps1'),
        '-StickRoot',$reparse.Stick,'-SessionRoot',$reparse.Session,'-GuardDir',$reparse.Guard,
        '-DriveLetter',$drive,'-VolumeGuid',$expected.VolumeGuid,'-Serial',$expected.Serial,
        '-HarnessExe',$nodeExe,'-WorkingDir',$reparse.Work,'-HarnessArgs',$startScript,
        '-SessionsDir',$reparse.Sessions,'-SourceDir',$linkSource,'-StorageMode','DirectUsb','-SessionId',$reparse.Id)
    $linkQuoted=@($linkArgs | ForEach-Object { Quote-Arg ([string]$_) })
    $linkProcess=Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $linkQuoted -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $sandbox 'reparse.stdout.txt') -RedirectStandardError (Join-Path $sandbox 'reparse.stderr.txt')
    Check 'SourceDir through a USB junction is rejected' ($linkProcess.ExitCode -ne 0)
    Check 'junction rejection happens before harness startup' (-not (Test-Path -LiteralPath $startSentinel))
    [IO.Directory]::Delete($junction)
    $linkLock=$null
    try { $linkLock=Open-SessionLock -SessionRoot $reparse.Session } catch { }
    if ($linkLock) { $linkLock.Dispose() }
    Remove-OwnedSessionDirectory -SessionRoot $reparse.Session -TempRoot $sandbox -SessionId $reparse.Id -AllowActiveOwner | Out-Null
} finally {
    foreach ($p in @($normalGuardian,$removeGuardian)) {
        if ($p) { try { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    }
    if ($childPidFile -and (Test-Path -LiteralPath $childPidFile)) {
        try {
            $pidValue=[int][IO.File]::ReadAllText($childPidFile)
            $owned=Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
            if ($owned -and $owned.ExecutablePath -eq $nodeExe -and $owned.CommandLine.Contains($childToken)) { Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    if ($independentLock) { $independentLock.Dispose() }
    $full=[IO.Path]::GetFullPath($sandbox)
    if ($full.StartsWith($tempBase+'\',[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -eq "ai-guardian-direct-usb-$testId" -and (Test-Path -LiteralPath $full -PathType Container)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Guardian DirectUsb: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0

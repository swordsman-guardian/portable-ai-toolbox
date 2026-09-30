[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Test-AppContainerMarkerReady([string]$Path) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt 3000) {
        try { if([IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path,[Text.Encoding]::ASCII) -ceq "hook-v1`n") { return $true } } catch {}
        Start-Sleep -Milliseconds 20
    }
    return $false
}
$vsRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community'
$devCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) { throw 'Visual Studio x64 build environment is unavailable.' }
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccsu-ac-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildRoot | Out-Null
Set-Content -LiteralPath (Join-Path $buildRoot '.ccsu-test-owned') -Value 'synthetic appcontainer test output' -Encoding ASCII
$state = $null
$fixtureRoot = $null
try {
    $shimSource = Join-Path $PSScriptRoot 'cc-switch-portable-updater-shim.cpp'
    $noopSource = Join-Path $PSScriptRoot 'cc-switch-portable-update-noop.cpp'
    $hostSource = Join-Path $PSScriptRoot 'test-cc-switch-portable-updater-appcontainer.cpp'
    $bat = Join-Path $buildRoot 'build.cmd'
    $batText = @"
@echo off
cd /d "$buildRoot"
if errorlevel 1 exit /b 19
call "$devCmd" -no_logo -arch=x64
if errorlevel 1 exit /b 20
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD "$shimSource" /link /OUT:"$buildRoot\cc-switch-portable-updater-shim.dll" shell32.lib
if errorlevel 1 exit /b 21
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT "$noopSource" /link /OUT:"$buildRoot\cc-switch-portable-update-noop.exe"
if errorlevel 1 exit /b 22
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT "$hostSource" /link /OUT:"$buildRoot\cc-switch.exe" shell32.lib
exit /b %errorlevel%
"@
    [IO.File]::WriteAllText($bat,$batText,[Text.Encoding]::ASCII)
    & $env:ComSpec /d /c $bat
    if ($LASTEXITCODE -ne 0) { throw "Synthetic AppContainer build failed with exit code $LASTEXITCODE." }

    . (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
    . (Join-Path $PSScriptRoot 'cc-switch-portable-updater-injection.ps1')
    . (Join-Path $PSScriptRoot 'cc-switch-portable-updater-request.ps1')
    $fixtureRoot = New-AppContainerProbeFixtureRoot
    $appRoot = Join-Path $fixtureRoot 'app'
    $stickRoot = Join-Path $fixtureRoot 'stick'
    $runtimeRoot = Join-Path $fixtureRoot 'runtime'
    $updatesRoot = Join-Path $runtimeRoot 'updates'
    foreach ($dir in @($appRoot,$stickRoot,$runtimeRoot,$updatesRoot)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $buildRoot 'cc-switch.exe') -Destination (Join-Path $appRoot 'cc-switch.exe')
    Copy-Item -LiteralPath (Join-Path $buildRoot 'cc-switch-portable-update-noop.exe') -Destination (Join-Path $appRoot 'cc-switch-portable-update-noop.exe')
    $mailbox = Join-Path $updatesRoot 'portable-update.request'
    $nonce = [guid]::NewGuid().ToString('N')
    $gate = Join-Path $runtimeRoot 'shim-test-go'
    $fixture = [ordered]@{
        Root=$fixtureRoot; Exe=(Join-Path $appRoot 'cc-switch.exe'); StickRoot=$stickRoot; RuntimeRoot=$runtimeRoot
        Environment=[ordered]@{HOME=$stickRoot;USERPROFILE=$stickRoot;APPDATA=$stickRoot;LOCALAPPDATA=$stickRoot;CC_SWITCH_TEST_HOME=$stickRoot;TEMP=$stickRoot;TMP=$stickRoot}
        Arguments=@($gate)
    }
    $fixturePath = Join-Path $fixtureRoot 'fixture.json'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $loaded = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $loaded -NetworkMode None -DeferResume
    $startTicks = (Get-Process -Id ([int]$state.ProcessId) -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    $exeHash = (Get-FileHash -LiteralPath (Join-Path $appRoot 'cc-switch.exe') -Algorithm SHA256).Hash
    $shimHash = (Get-FileHash -LiteralPath (Join-Path $buildRoot 'cc-switch-portable-updater-shim.dll') -Algorithm SHA256).Hash
    $noopHash = (Get-FileHash -LiteralPath (Join-Path $buildRoot 'cc-switch-portable-update-noop.exe') -Algorithm SHA256).Hash
    $result = Install-CcSwitchPortableUpdaterShim -State $state -OwnedAppRoot $appRoot -ShimSource (Join-Path $buildRoot 'cc-switch-portable-updater-shim.dll') -ExpectedShimSha256 $shimHash -NoopSource (Join-Path $buildRoot 'cc-switch-portable-update-noop.exe') -ExpectedNoopSha256 $noopHash -ExpectedExeSha256 $exeHash -MailboxPath $mailbox -Nonce $nonce -ExpectedProcessStartTicks $startTicks
    if (-not $result.Ready) { throw 'Injector did not report hook ready.' }
    Resume-AppContainerProbeProcess -State $state | Out-Null
    [IO.File]::WriteAllText($gate,'go',(New-Object Text.UTF8Encoding($false)))
    $request=$null
    $requestWatch=[Diagnostics.Stopwatch]::StartNew()
    while (-not $request -and $requestWatch.Elapsed.TotalSeconds -lt 10) {
        $request=Read-CcSwitchPortableUpdaterRequestFromMetadata -FixtureRoot $fixtureRoot -ProcessId ([uint32]$state.ProcessId) -AppContainerSid ([string]$state.AppContainerSid) -NetworkMode None -ExpectedNonce $nonce -ExpectedExeSha256 $exeHash -ExpectedProcessStartTicks $startTicks -Consume
        if (-not $request) { Start-Sleep -Milliseconds 50 }
    }
    if (-not $request) {
        $waitStatus=Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 1
        $markers=@(Get-ChildItem -LiteralPath $updatesRoot -Filter '*.hit' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if($waitStatus.Completed){throw ('Synthetic process exited before request (code {0}; markers {1}).' -f $waitStatus.ExitCode,($markers -join ','))}
        throw ('Owner did not validate a native update request before timeout (markers {0}).' -f ($markers -join ','))
    }
    if (-not $request.Requested) { throw 'Owner did not validate a native update request before timeout.' }
    $finalPathHit=Join-Path $updatesRoot 'finalpath-owned-fallback.hit'
    if (-not (Test-AppContainerMarkerReady $finalPathHit)) { throw 'The AppContainer executable handle did not use the owned NT-to-DOS final-path fallback.' }
    [IO.File]::Delete($finalPathHit)
    $lifecycleHit=Join-Path $updatesRoot 'native-lifecycle-call.hit'
    if (-not (Test-AppContainerMarkerReady $lifecycleHit)) { throw 'The AppContainer fixed PID-owned lifecycle batch was not routed through cmd call.' }
    [IO.File]::Delete($lifecycleHit)
    $hookHit=Join-Path $updatesRoot 'native-opener-command.hit'
    if (-not (Test-AppContainerMarkerReady $hookHit)) { throw 'The CreateProcessW diagnostic marker did not match the fixed native opener command.' }
    [IO.File]::Delete($hookHit)
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 20
    if (-not $wait.Completed -or $wait.ExitCode -ne 0) { throw 'Synthetic AppContainer native opener call did not complete successfully.' }
    if ([IO.File]::Exists($mailbox)) { throw 'Owner did not consume the one-shot native update request.' }
    Write-Output 'PASS: pre-entry shim injection enabled the exact owned executable final-path fallback, then intercepted the fixed native opener and the owner validated/consumed its one-shot event.'
} catch {
    if ($_.Exception -is [ComponentModel.Win32Exception]) { Write-Output ('Native operation error code: ' + $_.Exception.NativeErrorCode) }
    throw
}
finally {
    if ($state) {
        try { Complete-AppContainerProbeProcess -State $state } catch { Write-Warning 'Synthetic AppContainer cleanup could not be fully verified.' }
    }
    foreach ($path in @($fixtureRoot,$buildRoot)) {
        if (-not $path) { continue }
        $full=[IO.Path]::GetFullPath($path).TrimEnd('\')
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $item=Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            [string]::Equals((Split-Path -Parent $full),$temp,[StringComparison]::OrdinalIgnoreCase) -and
            ((Split-Path -Leaf $full) -match '^(aistick-ac-probe|ccsu-ac-test)-[0-9a-f]{32}$')) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

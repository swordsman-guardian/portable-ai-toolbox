[CmdletBinding()]
param(
    [int]$MaximumWaitMinutes = 45,
    [ValidateSet('None','InternetClient')][string]$NetworkMode = 'InternetClient',
    [switch]$InjectPortableUpdateShim,
    [switch]$CheckUpdateOnly,
    [string]$PackageStickRoot = 'E:\'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-native-update-session.ps1')

if ($CheckUpdateOnly -and $NetworkMode -ne 'InternetClient') { throw 'Native Check for updates validation requires an InternetClient fixture.' }

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$root = New-AppContainerProbeFixtureRoot
$guid = [guid]::ParseExact((Split-Path -Leaf $root).Substring('aistick-ac-probe-'.Length),'N')
$app = Join-Path $root 'app'
$stick = Join-Path $root 'stick'
$runtime = Join-Path $root 'runtime'
$harness = Join-Path $root 'harness'
$browser = Join-Path $root 'browser'
$session = Join-Path $runtime 'session'
$slotId = 'synthetic-v1'
$slot = Join-Path $harness ('slots\' + $slotId)
$stopPath = Join-Path $root '.stop-synthetic-native-gui'
$logPath = Join-Path $root 'fake-cli-invocations.log'
$state = $null
$fixturePath = Join-Path $root 'fixture.json'
$fixturePid = $null
$nativeUpdateSession = $null
$nativeUpdateRequest = $null
$nativeUpdateRequestError = $null
$verifiedPackage = $null
$useNativeAdapter = [bool]($InjectPortableUpdateShim -or $CheckUpdateOnly)

function Copy-PlainTree {
    param([string]$Source,[string]$Destination)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Source)) {
        $item = Get-Item -LiteralPath $entry -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Synthetic source contains a reparse point.' }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-PlainTree -Source $entry -Destination $target }
        else { [IO.File]::Copy($entry,$target,$false) }
    }
}

function Assert-PlainFixtureTree {
    param([string]$Path)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push([IO.Path]::GetFullPath($Path))
    while ($stack.Count) {
        $current = $stack.Pop()
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing recursive fixture cleanup because a reparse point appeared.' }
        if ($item.PSIsContainer) { foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current,'*',[IO.SearchOption]::TopDirectoryOnly)) { $stack.Push($child) } }
    }
}

try {
    foreach ($path in @($app,$stick,$runtime,$harness,$browser,$session,$slot)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    if ($useNativeAdapter) {
        if ($NetworkMode -ne 'InternetClient') { throw 'Portable updater shim validation requires an InternetClient fixture.' }
    }
    $verifiedPackage = Resolve-CcPortableUpdatePackage -StickRoot $PackageStickRoot
    [IO.File]::Copy((Join-Path $verifiedPackage.AppDirectory 'cc-switch.exe'),(Join-Path $app 'cc-switch.exe'),$false)
    [IO.File]::Copy((Join-Path $verifiedPackage.AppDirectory 'portable.ini'),(Join-Path $app 'portable.ini'),$false)
    Copy-PlainTree -Source (Join-Path $projectRoot 'runtime\node') -Destination (Join-Path $runtime 'node')
    $fixedBrowser = Join-Path $projectRoot 'tools\webview2\verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    Copy-PlainTree -Source $fixedBrowser -Destination $browser
    $browserExe = Join-Path $browser 'msedgewebview2.exe'
    $signature = Get-AuthenticodeSignature -LiteralPath $browserExe
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'The copied fixed WebView runtime failed its Microsoft signature check.' }

    $packageRoot = Join-Path $slot 'node_modules\@anthropic-ai\claude-code'
    [IO.Directory]::CreateDirectory((Join-Path $packageRoot 'bin')) | Out-Null
    $fakeCli = @'
@echo off
setlocal
>> "@FIXTURE_LOG@" echo CLI path="%~f0" args="%*"
if /i "%~1"=="--version" (echo 0.0.0-synthetic & exit /b 0)
if /i "%~1"=="update" (
  >> "@FIXTURE_LOG@" echo prefix="%npm_config_prefix%"
  call npm.cmd install --global --prefix "%npm_config_prefix%" @anthropic-ai/claude-code@latest
  exit /b %errorlevel%
)
exit /b 0
'@
    $fakeCli = $fakeCli.Replace('@FIXTURE_LOG@',$logPath)
    $fakeNpm = @'
@echo off
>> "@FIXTURE_LOG@" echo NPM path="%~f0" args="%*"
if /i "%~1"=="view" goto checkOfficial
if /i "%~1"=="info" goto checkOfficial
if /i "%~1"=="show" goto checkOfficial
goto blocked
:checkOfficial
if /i "%~2"=="@anthropic-ai/claude-code" goto metadata
if /i "%~2"=="@anthropic-ai/claude-code@latest" goto metadata
goto blocked
:metadata
"%~dp0node.exe" "%~dp0node_modules\npm\bin\npm-cli.js" %*
set rc=%errorlevel%
>> "@FIXTURE_LOG@" echo OFFICIAL_METADATA_EXIT=%rc%
exit /b %rc%
:blocked
>> "@FIXTURE_LOG@" echo BLOCKED_NON_METADATA_NPM_OPERATION
exit /b 0
'@
    $fakeNpm = $fakeNpm.Replace('@FIXTURE_LOG@',$logPath)
    [IO.File]::WriteAllText((Join-Path $slot 'claude.cmd'),$fakeCli,(New-Object Text.ASCIIEncoding))
    [IO.File]::WriteAllText((Join-Path $runtime 'node\npm.cmd'),$fakeNpm,(New-Object Text.ASCIIEncoding))
    $package = [ordered]@{name='@anthropic-ai/claude-code';version='0.0.0-synthetic';description='Synthetic test package only'}
    [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'),(ConvertTo-Json -InputObject $package -Depth 3),(New-Object Text.UTF8Encoding($false)))
    $fakePe = New-Object byte[] 1000000
    $fakePe[0]=0x4d;$fakePe[1]=0x5a;$fakePe[0x3c]=0x80;$fakePe[0x80]=0x50;$fakePe[0x81]=0x45;$fakePe[0x84]=0x64;$fakePe[0x85]=0x86;$fakePe[0x98]=0x0b;$fakePe[0x99]=0x02
    [IO.File]::WriteAllBytes((Join-Path $packageRoot 'bin\claude.exe'),$fakePe)

    $context = New-CcSwitchPortableContext -StickRoot $stick -SessionRoot $session -RuntimeRoot $runtime -ManagedHarnessRoot $harness -ManagedHarnessSlotId $slotId
    $initialized = Initialize-CcSwitchPortableContext -Context $context
    $environment = Get-CcSwitchPortableEnvironment -Context $context
    $environment['WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'] = $browser
    $fixture = [ordered]@{Root=$root;Exe=(Join-Path $app 'cc-switch.exe');StickRoot=$stick;RuntimeRoot=$runtime;ManagedHarnessRoot=$harness;Environment=$environment;Arguments=@()}
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $fresh = Read-AppContainerFixture -Path $fixturePath
    if ($useNativeAdapter) {
        $nativeUpdateSession = Start-CcSwitchNativeUpdateSession -Fixture $fresh -Package $verifiedPackage -NetworkMode $NetworkMode
        $state = $nativeUpdateSession.State
    } else { $state = Start-AppContainerProbeProcess -Fixture $fresh -NetworkMode $NetworkMode }
    $fixturePid = [int]$state.ProcessId
    Write-Output ([pscustomobject]@{
        Status='Synthetic CC Switch GUI ready for manual native-button check'
        ProcessId=$state.ProcessId
        FixtureRoot=$root
        HarnessRoot=$harness
        ActiveFakeCli=(Join-Path $slot 'claude.cmd')
        LogPath=$logPath
        StopFile=$stopPath
        NetworkMode=$NetworkMode
        PackageVersion=$verifiedPackage.Version
        NativeAdapterReady=[bool]($nativeUpdateSession -and $nativeUpdateSession.State -and $nativeUpdateSession.State.IsResumed)
        CheckUpdateOnly=[bool]$CheckUpdateOnly
        RealProvidersOrSecrets='None; fresh HOME and StickRoot'
        RealHarnessInstallOrModelRequest='None'
    })
    if ($CheckUpdateOnly) { Write-Output 'Open About in the synthetic CC Switch GUI and click Check for updates. UI success must be confirmed by the user; the harness records the authenticated local updater request but cannot attest toast/modal rendering.' }
    $deadline = [DateTime]::UtcNow.AddMinutes($MaximumWaitMinutes)
    while (-not (Test-Path -LiteralPath $stopPath) -and [DateTime]::UtcNow -lt $deadline) {
        $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 1
        if ($wait.Completed) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($CheckUpdateOnly -and $nativeUpdateSession) {
        try { $nativeUpdateRequest = Read-CcSwitchNativeUpdateRequest -Session $nativeUpdateSession -Consume }
        catch { $nativeUpdateRequestError = $_.Exception.Message }
    }
    Complete-AppContainerProbeProcess -State $state
    $state = $null
    $log = if ([IO.File]::Exists($logPath)) { [IO.File]::ReadAllText($logPath) } else { '' }
    $expectedPath = (Join-Path $slot 'claude.cmd')
    $nativeCliHit = $log.Contains($expectedPath) -and $log -match 'args=""?update""?'
    Write-Output ([pscustomobject]@{CheckUpdateOnly=[bool]$CheckUpdateOnly;NativeUpdateRequestObserved=[bool]$nativeUpdateRequest;NativeUpdateRequestConsumed=[bool]($nativeUpdateRequest -and $nativeUpdateRequest.Consumed);NativeUpdateRequestError=$nativeUpdateRequestError;NativeUpdateUiObservedByHarness=$false;UserUiConfirmationRequired=[bool]$CheckUpdateOnly;NativeUpdateReachedFakeManagedCli=$nativeCliHit;InvocationLog=$log;TestScope=('Verified CC Switch {0} GUI in {1} AppContainer; synthetic CLI/npm only.' -f $verifiedPackage.Version,$NetworkMode)})
    if (-not $CheckUpdateOnly -and $InjectPortableUpdateShim -and -not $nativeCliHit) { throw 'The synthetic Claude update button did not invoke the managed fake CLI; a redacted summary is saved under E:\logs.' }
} finally {
    if ($state) {
        try { Complete-AppContainerProbeProcess -State $state } catch { throw ('Synthetic GUI cleanup failed; fixture retained: ' + $root + '. ' + $_.Exception.Message) }
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [string]::Equals($_.Path,(Join-Path $app 'cc-switch.exe'),[StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -gt 0) { throw ('Synthetic GUI process remains; retained fixture: ' + $root) }
        if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))).TrimEnd('\','/') -ine [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or
            (Split-Path -Leaf $root) -cne ('aistick-ac-probe-' + $guid.ToString('N'))) { throw 'Refusing to remove a fixture outside its exact unique temp boundary.' }
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        Assert-PlainFixtureTree -Path $root
        $summaryPath = Join-Path 'E:\logs' ('managed-harness-ui-' + $guid.ToString('N') + '.json')
        [IO.Directory]::CreateDirectory((Split-Path -Parent $summaryPath)) | Out-Null
        $reached = $false
        if ([IO.File]::Exists($logPath)) { $safeLog = [IO.File]::ReadAllText($logPath); $reached = $safeLog.Contains((Join-Path $slot 'claude.cmd')) -and $safeLog -match 'args=""?update""?' }
        $summary = [ordered]@{FixtureRoot=$root;ProcessId=$fixturePid;NativeUpdateReachedFakeManagedCli=$reached;CheckUpdateOnly=[bool]$CheckUpdateOnly;NativeUpdateRequestObserved=[bool]$nativeUpdateRequest;NativeUpdateRequestError=$nativeUpdateRequestError;NetworkMode=$NetworkMode;ShimRequested=[bool]$useNativeAdapter;PackageVersion=if($verifiedPackage){$verifiedPackage.Version}else{$null};InvocationLogPresent=[IO.File]::Exists($logPath);RealProvidersOrSecrets='None'}
        [IO.File]::WriteAllText($summaryPath,(ConvertTo-Json -InputObject $summary -Depth 4),(New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }
}

[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:PackageChoice=$null;$script:ManagedReturn=$null;$script:ContextReturn=$null;$script:SaveCall=$null;$script:PresentBeforeAndAfter=$true;$script:RemoveAfterSave=$false;$script:NativeLaunchMismatch=$false;$script:NativeCleanupState=$null
$script:ProbeRoot=$null
function Assert-IsolatedOwnerTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Resolve-CcPortableUpdatePackage([string]$StickRoot){return $script:PackageChoice}
function Assert-CcPortableUpdateNoReparse([string]$Path){$full=[IO.Path]::GetFullPath($Path);if(-not (Test-Path -LiteralPath $full)){throw 'Synthetic path is missing.'};$item=Get-Item -LiteralPath $full -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Synthetic reparse point.'}}
function Initialize-CcManagedHarnessSession([string]$UsbRoot,[string]$OwnedRoot,[string]$SlotId){$script:ManagedCall=[pscustomobject]@{UsbRoot=$UsbRoot;OwnedRoot=$OwnedRoot;SlotId=$SlotId};return $script:ManagedReturn}
function New-CcSwitchPortableContext([string]$StickRoot,[string]$SessionRoot,[string[]]$HarnessIds=@('claude','codex','gemini','grok','opencode','openclaw','hermes','pi'),[string]$RuntimeRoot,[string]$ManagedHarnessRoot,[string]$ManagedHarnessSlotId){$script:ContextCall=[pscustomobject]@{StickRoot=$StickRoot;SessionRoot=$SessionRoot;HarnessIds=$HarnessIds;RuntimeRoot=$RuntimeRoot;ManagedHarnessRoot=$ManagedHarnessRoot;ManagedHarnessSlotId=$ManagedHarnessSlotId};return $script:ContextCall}
function Initialize-CcSwitchPortableContext($Context){$script:InitializedContext=$Context;return [pscustomobject]@{Version='synthetic';PersistentRoot=(Join-Path $Context.StickRoot 'config\cc-switch');SettingsCreatedOrUpdated=$true;EnvironmentBlockComplete=$false;GuiValidated=$false}}
function Get-CcSwitchPortableEnvironment($Context){return [ordered]@{CLAUDE_CONFIG_DIR=(Join-Path $Context.StickRoot 'harness\cc-switch\claude');PATH=(Join-Path $Context.ManagedHarnessRoot ('slots\'+$Context.ManagedHarnessSlotId))}}
function Start-CcSwitchNativeUpdateSession($Fixture,$Package,[string]$NetworkMode){$script:NativeLaunchCall=[pscustomobject]@{Fixture=$Fixture;Package=$Package;NetworkMode=$NetworkMode};$state=[pscustomobject]@{ProcessId=321;ProcessStartTicks=123456;FixtureRoot=$Fixture.Root};$mailbox=Join-Path $Fixture.Root 'runtime\updates\portable-update.request';$nonce='b'*32;$sha='a'*64;$requestRoot=if($script:NativeLaunchMismatch){Join-Path $Fixture.Root 'wrong'}else{$Fixture.Root};$context=[pscustomobject]@{FixtureRoot=$requestRoot;PackageVersion=$Package.Version;ProcessId=321;ExpectedNonce=$nonce;ExpectedExeSha256=$sha;ExpectedProcessStartTicks=123456;MailboxPath=$mailbox};return [pscustomobject]@{State=$state;PackageVersion=$Package.Version;ExpectedExeSha256=$sha;MailboxPath=$mailbox;Nonce=$nonce;RequestContext=$context}}
function Complete-AppContainerProbeProcess($State){$script:NativeCleanupState=$State;return [pscustomobject]@{Completed=$true}}
function Test-StickPresent($Expected){if($script:RemoveAfterSave -and $script:SaveCall){return $false};return $script:PresentBeforeAndAfter}
function Save-CcManagedClaudeVersionSlot([string]$StagedSlotPath,[string]$UsbRoot,$ExpectedVolume){$script:SaveCall=[pscustomobject]@{StagedSlotPath=$StagedSlotPath;UsbRoot=$UsbRoot;ExpectedVolume=$ExpectedVolume};return [pscustomobject]@{Saved=$true;AlreadyPresent=$false;Version='2.1.281';Path=(Join-Path $UsbRoot 'tools\harness\claude\slots\2.1.281')}}
function New-IsolatedOwnerClaudePeFixture([string]$Directory,[string]$Version='2.1.281') {
    [IO.Directory]::CreateDirectory($Directory)|Out-Null
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(-not [IO.File]::Exists($vswhere)){throw 'Synthetic owner fixture requires the installed Visual Studio compiler tools.'}
    $install=(& $vswhere -latest -products '*' -property installationPath|Select-Object -First 1).Trim()
    if(-not $install){throw 'Visual Studio compiler installation was not found.'}
    $devCmd=Join-Path $install 'Common7\Tools\VsDevCmd.bat'
    $source=Join-Path $Directory 'fixture.cpp';$resource=Join-Path $Directory 'fixture.rc';$padding=Join-Path $Directory 'padding.bin';$res=Join-Path $Directory 'fixture.res';$exe=Join-Path $Directory 'claude.exe';$batch=Join-Path $Directory 'build.cmd'
    [IO.File]::WriteAllText($source,'int main(){return 0;}',(New-Object Text.ASCIIEncoding));[IO.File]::WriteAllBytes($padding,(New-Object byte[] 1100000))
    $numeric=$Version.Replace('.',',')+',0';$string=$Version+'.0'
    $rc=@'
#include <windows.h>
1 RCDATA "padding.bin"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION __NUMERIC__
 PRODUCTVERSION __NUMERIC__
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
 FILESUBTYPE VFT2_UNKNOWN
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "FileVersion", "__STRING__\0"
   VALUE "ProductVersion", "__STRING__\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
'@
    [IO.File]::WriteAllText($resource,$rc.Replace('__NUMERIC__',$numeric).Replace('__STRING__',$string),(New-Object Text.ASCIIEncoding))
    $batchText="@echo off`r`ncall `"$devCmd`" -arch=x64 -host_arch=x64 >nul`r`nif errorlevel 1 exit /b 10`r`nrc /nologo /fo `"$res`" `"$resource`"`r`nif errorlevel 1 exit /b 11`r`ncl /nologo /MT /O1 `"$source`" `"$res`" /link /out:`"$exe`"`r`nexit /b %errorlevel%`r`n"
    [IO.File]::WriteAllText($batch,$batchText,(New-Object Text.ASCIIEncoding));& $env:ComSpec /d /s /c ('"'+$batch+'"')|Out-Null
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($exe)){throw 'Could not build synthetic versioned PE fixture.'}
    $info=(Get-Item -LiteralPath $exe).VersionInfo
    if([string]$info.FileVersion -cne $string -or [string]$info.ProductVersion -cne $string){throw 'Synthetic PE version metadata does not match its package version.'}
    return $exe
}
. (Join-Path $PSScriptRoot 'cc-switch-isolated-managed-owner.ps1')

$root=Join-Path $env:TEMP ('cc-owner-adapter-'+[guid]::NewGuid().ToString('N'))
try{
    $stick=Join-Path $root 'stick';$pinned=Join-Path $stick 'tools\cc-switch\app';$managed=Join-Path $stick 'tools\cc-switch\managed\slots\v3.20.5'
    [IO.Directory]::CreateDirectory($pinned)|Out-Null;[IO.Directory]::CreateDirectory($managed)|Out-Null
    foreach($dir in @($pinned,$managed)){[IO.File]::WriteAllBytes((Join-Path $dir 'cc-switch.exe'),[byte[]]@(1,2,3));[IO.File]::WriteAllText((Join-Path $dir 'portable.ini'),'portable=true')}
    $script:PackageChoice=[pscustomobject]@{Version='v3.20.4';AppDirectory=$pinned;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Pinned'}
    $selection=Get-CcSwitchIsolatedPackageSelection -StickRoot $stick
    Assert-IsolatedOwnerTest ($selection.Source -eq 'Pinned' -and $selection.AppDirectory -eq [IO.Path]::GetFullPath($pinned)) 'Initial pinned package selection failed.'
    $script:PackageChoice=[pscustomobject]@{Version='v3.20.5';AppDirectory=$managed;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Managed'}
    $selection=Get-CcSwitchIsolatedPackageSelection -StickRoot $stick
    Assert-IsolatedOwnerTest ($selection.Source -eq 'Managed' -and $selection.AppDirectory -eq [IO.Path]::GetFullPath($managed)) 'Verified managed package selection failed.'
    $script:PackageChoice=[pscustomobject]@{Version='v3.20.5';AppDirectory=$pinned;ArchiveVerified=$false;ExtractedFilesVerified=$true;Source='Managed'};$failed=$false
    try{Get-CcSwitchIsolatedPackageSelection -StickRoot $stick|Out-Null}catch{$failed=$true}
    Assert-IsolatedOwnerTest $failed 'Unverified package candidate was accepted.'
    $outside=Join-Path $root 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;[IO.File]::WriteAllBytes((Join-Path $outside 'cc-switch.exe'),[byte[]]@(1));[IO.File]::WriteAllText((Join-Path $outside 'portable.ini'),'x')
    $script:PackageChoice=[pscustomobject]@{Version='v3.20.5';AppDirectory=$outside;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Managed'};$failed=$false
    try{Get-CcSwitchIsolatedPackageSelection -StickRoot $stick|Out-Null}catch{$failed=$true}
    Assert-IsolatedOwnerTest $failed 'Managed slot path outside the exact package boundary was accepted.'
    $nativeFixture=[pscustomobject]@{Root=(Join-Path $root 'native-fixture')};$nativePackage=[pscustomobject]@{Version='v3.20.4';AppDirectory=$pinned;ArchiveVerified=$true;ExtractedFilesVerified=$true}
    $nativeLaunch=Start-CcSwitchIsolatedNativeUpdateOwner -Fixture $nativeFixture -Package $nativePackage -NetworkMode InternetClient
    Assert-IsolatedOwnerTest ($script:NativeLaunchCall.Fixture -eq $nativeFixture -and $script:NativeLaunchCall.Package -eq $nativePackage -and $script:NativeLaunchCall.NetworkMode -eq 'InternetClient' -and $nativeLaunch.State.ProcessStartTicks -eq 123456) 'Native update owner startup did not receive the verified fixture/package/network contract.'
    $script:NativeLaunchMismatch=$true;$script:NativeCleanupState=$null;$startupRejected=$false
    try{Start-CcSwitchIsolatedNativeUpdateOwner -Fixture $nativeFixture -Package $nativePackage -NetworkMode InternetClient|Out-Null}catch{$startupRejected=$_.Exception.Message -like '*identity does not match*'}
    Assert-IsolatedOwnerTest ($startupRejected -and $script:NativeCleanupState.ProcessId -eq 321) 'Rejected native owner startup did not clean its already-running process/job.'
    $script:NativeLaunchMismatch=$false
    Assert-IsolatedOwnerTest ((Test-CcSwitchNativeUpdateNetworkAllowed 'InternetClient') -and -not (Test-CcSwitchNativeUpdateNetworkAllowed 'None')) 'Offline session is allowed to issue an owner-side network update check.'

    $owned=Join-Path $root 'owner';$runtime=Join-Path $owned 'runtime';$session=Join-Path $runtime 'session';$ownerStick=Join-Path $owned 'stick';$harness=Join-Path $owned 'harness'
    foreach($dir in @($owned,$runtime,$session,$ownerStick,$harness)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    $script:ManagedReturn=[pscustomobject]@{OwnedRoot=$owned;RuntimeRoot=$runtime;StickRoot=$ownerStick;ManagedHarnessRoot=$harness;SlotId='2.1.281';PackageVersion='2.1.281';Ready=$true}
    [IO.Directory]::CreateDirectory((Join-Path $harness 'slots\2.1.281'))|Out-Null
    $owner=Initialize-CcSwitchIsolatedManagedHarness -UsbRoot $stick -OwnedRoot $owned -StickRoot $ownerStick -SessionRoot $session -RuntimeRoot $runtime
    Assert-IsolatedOwnerTest ($script:ContextCall.HarnessIds.Count -eq 8 -and $script:ContextCall.HarnessIds -contains 'claude' -and $script:ContextCall.HarnessIds -contains 'codex' -and $script:ContextCall.ManagedHarnessSlotId -eq '2.1.281') 'Managed Claude runtime adapter did not preserve all isolated context directories.'
    Assert-IsolatedOwnerTest ($owner.Environment.PATH -like '*\harness\slots\2.1.281') 'Owner adapter environment did not point to the temporary versioned Claude slot.'
    Assert-IsolatedOwnerTest (-not $owner.Context.PSObject.Properties['StickRoot'] -and $script:ContextCall.StickRoot -eq $ownerStick) 'Owner adapter did not keep the initialized receipt separate from its reusable context.'

    # Exercise real context routines against synthetic USB/runtime/package files.
    foreach($name in @('New-CcSwitchPortableContext','Initialize-CcSwitchPortableContext','Get-CcSwitchPortableEnvironment')){Remove-Item -LiteralPath ('Function:\'+$name) -ErrorAction SilentlyContinue}
    foreach($name in @('Initialize-CcManagedHarnessSession','Get-CcSwitchManagedClaudeEnvironment','Test-CcSwitchManagedClaudeSlot','Get-CcSwitchHarnessRuntimeFullPath','Assert-CcSwitchHarnessRuntimePlainPath','Copy-CcSwitchManagedHarnessTree','Get-CcSwitchManagedHarnessTreeInventory','Test-CcSwitchManagedClaudePeFile')){Remove-Item -LiteralPath ('Function:\'+$name) -ErrorAction SilentlyContinue}
    . (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
    . (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
    . (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
    function Save-CcManagedClaudeVersionSlot([string]$StagedSlotPath,[string]$UsbRoot,$ExpectedVolume){$script:SaveCall=[pscustomobject]@{StagedSlotPath=$StagedSlotPath;UsbRoot=$UsbRoot;ExpectedVolume=$ExpectedVolume};return [pscustomobject]@{Saved=$true;AlreadyPresent=$false;Version='2.1.281';Path=(Join-Path $UsbRoot 'tools\harness\claude\slots\2.1.281')}}
    $actualRoot=New-AppContainerProbeFixtureRoot;$script:ProbeRoot=$actualRoot
    $actualRuntime=Join-Path $actualRoot 'runtime';$actualSession=Join-Path $actualRuntime 'session';$actualStick=Join-Path $actualRoot 'stick';$actualHarness=Join-Path $actualRoot 'harness'
    $actualUsb=Join-Path $root 'actual-usb';$nodeSource=Join-Path $actualUsb 'runtime\node';$npmSource=Join-Path $nodeSource 'node_modules\npm\bin';$claudeSource=Join-Path $actualUsb 'npm-global';$pkgRoot=Join-Path $claudeSource 'node_modules\@anthropic-ai\claude-code';$platformRoot=Join-Path $pkgRoot 'node_modules\@anthropic-ai\claude-code-win32-x64';$pePath=Join-Path $platformRoot 'claude.exe'
    foreach($dir in @($actualRuntime,$actualSession,$actualStick,$actualHarness,(Join-Path $actualRoot 'app'),(Join-Path $actualRuntime 'browser'),$actualUsb,$npmSource,$platformRoot)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    [IO.File]::WriteAllBytes((Join-Path $nodeSource 'node.exe'),[byte[]]@(1,2,3));[IO.File]::WriteAllText((Join-Path $npmSource 'npm-cli.js'),'synthetic npm')
    $claudeCmd=@'
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0
"%dp0%\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe"   %*
'@
    [IO.File]::WriteAllText((Join-Path $claudeSource 'claude.cmd'),$claudeCmd,(New-Object Text.ASCIIEncoding))
    [IO.File]::WriteAllText((Join-Path $pkgRoot 'package.json'),'{"name":"@anthropic-ai/claude-code","version":"2.1.281"}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $platformRoot 'package.json'),'{"name":"@anthropic-ai/claude-code-win32-x64","version":"2.1.281"}',(New-Object Text.UTF8Encoding($false)))
    $builtExe=New-IsolatedOwnerClaudePeFixture -Directory (Join-Path $actualRoot 'pe-fixture') -Version '2.1.281';[IO.File]::Copy($builtExe,$pePath)
    $actualOwner=Initialize-CcSwitchIsolatedManagedHarness -UsbRoot $actualUsb -OwnedRoot $actualRoot -StickRoot $actualStick -SessionRoot $actualSession -RuntimeRoot $actualRuntime
    $actualSlotPath=Join-Path $actualHarness 'slots\2.1.281'
    Assert-IsolatedOwnerTest ((Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $actualHarness -SlotId '2.1.281').Valid -and (Test-Path -LiteralPath (Join-Path $actualSlotPath 'npm.cmd')) -and (Test-Path -LiteralPath (Join-Path $actualRuntime 'updates\cc-switch-portable-claude-install.cjs'))) 'Managed owner did not install the strict sibling fallback adapter and portable installer.'
    $actualExpectedVolume=Get-CcSwitchHarnessVolumeIdentity -Path $actualUsb
    $script:SaveCall=$null
    $actualSaved=Save-CcSwitchIsolatedManagedHarness -ManagedSession $actualOwner.ManagedSession -UsbRoot $actualUsb -ExpectedVolume $actualExpectedVolume
    Assert-IsolatedOwnerTest ($actualSaved.Saved -and $script:SaveCall.StagedSlotPath -eq $actualSlotPath -and -not (Test-Path -LiteralPath (Join-Path $actualSlotPath 'npm.cmd'))) 'Managed owner did not remove the sibling adapter before invoking persistent save.'
    Assert-IsolatedOwnerTest ($actualOwner.Context.SettingsPath -eq (Join-Path $actualStick 'config\cc-switch\home\.cc-switch\settings.json') -and ([string]$actualOwner.Environment.PATH).Contains((Join-Path $actualHarness 'slots\2.1.281'))) 'Real context New/Initialize/GetEnvironment integration failed with Initialize receipt contract.'
    $fixtureExe=Join-Path $actualRoot 'app\cc-switch.exe';[IO.File]::WriteAllText($fixtureExe,'synthetic non-executable fixture')
    $fixtureRecord=New-CcSwitchIsolatedFixtureRecord -Root $actualRoot -Exe $fixtureExe -StickRoot $actualStick -RuntimeRoot $actualRuntime -ManagedHarnessRoot $actualOwner.ManagedSession.ManagedHarnessRoot -Environment $actualOwner.Environment -Arguments @()
    $fixturePath=Join-Path $actualRoot 'fixture.json';[IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixtureRecord -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $loadedFixture=Read-AppContainerFixture -Path $fixturePath
    Assert-IsolatedOwnerTest ($loadedFixture.ManagedHarnessRoot -eq $actualHarness -and $loadedFixture.Environment.PATH.Contains((Join-Path $actualHarness 'slots\2.1.281'))) 'Production fixture builder did not retain the owned harness root through real fixture validation.'
    $fixtureWithoutHarness=ConvertFrom-Json ([IO.File]::ReadAllText($fixturePath,[Text.Encoding]::UTF8));$fixtureWithoutHarness.PSObject.Properties.Remove('ManagedHarnessRoot');[IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixtureWithoutHarness -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $missingHarnessRejected=$false;try{Read-AppContainerFixture -Path $fixturePath|Out-Null}catch{$missingHarnessRejected=$_.Exception.Message -like '*ManagedHarnessRoot*'}
    Assert-IsolatedOwnerTest $missingHarnessRejected 'Fixture validation accepted managed PATH without ManagedHarnessRoot.'
    $fixtureOutsideHarness=ConvertTo-Json -InputObject $fixtureRecord -Depth 12|ConvertFrom-Json;$fixtureOutsideHarness.ManagedHarnessRoot=$actualStick;[IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixtureOutsideHarness -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $outsideHarnessRejected=$false;try{Read-AppContainerFixture -Path $fixturePath|Out-Null}catch{$outsideHarnessRejected=$_.Exception.Message -like '*ManagedHarnessRoot*'}
    Assert-IsolatedOwnerTest $outsideHarnessRejected 'Fixture validation accepted a USB persistent path as ManagedHarnessRoot.'

    $volume=[pscustomobject]@{DriveLetter='E';Serial='synthetic'};$script:PresentBeforeAndAfter=$true;$script:RemoveAfterSave=$false;$script:SaveCall=$null
    $saved=Save-CcSwitchIsolatedManagedHarness -ManagedSession $script:ManagedReturn -UsbRoot $stick -ExpectedVolume $volume
    Assert-IsolatedOwnerTest ($saved.Saved -and $script:SaveCall.StagedSlotPath -eq (Join-Path $harness 'slots\2.1.281')) 'Owner adapter did not save the versioned runtime after stop.'
    $script:SaveCall=$null;$script:RemoveAfterSave=$true;$failed=$false
    try{Save-CcSwitchIsolatedManagedHarness -ManagedSession $script:ManagedReturn -UsbRoot $stick -ExpectedVolume $volume|Out-Null}catch{$failed=$true}
    Assert-IsolatedOwnerTest $failed 'Owner adapter accepted a USB removal during managed Claude save.'
    'PASS: synthetic isolated owner package selection, managed Claude initialization and stopped-save adapters'
}finally{
    if($script:ProbeRoot -and (Test-Path -LiteralPath $script:ProbeRoot)){$fullProbe=[IO.Path]::GetFullPath($script:ProbeRoot);$tempProbe=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';if(-not $fullProbe.StartsWith($tempProbe,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Parent $fullProbe).TrimEnd('\') -ine $tempProbe.TrimEnd('\') -or (Get-Item -LiteralPath $fullProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing cleanup of synthetic AppContainer fixture outside direct TEMP.'};Remove-Item -LiteralPath $fullProbe -Recurse -Force}
    if(Test-Path -LiteralPath $root){$full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing cleanup outside TEMP.'};$item=Get-Item -LiteralPath $full -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing cleanup through reparse point.'};Remove-Item -LiteralPath $full -Recurse -Force}
}

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Start-CcSwitchNativeUpdateSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)]$Package,
        [ValidateSet('None','InternetClient')][string]$NetworkMode='None',
        [string]$AdapterDirectory
    )
    if(-not (Get-Command Start-AppContainerProbeProcess -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')}
    if(-not (Get-Command Install-CcSwitchPortableUpdaterShim -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-portable-updater-injection.ps1')}
    if(-not $Package.PSObject.Properties['ArchiveVerified'] -or -not $Package.PSObject.Properties['ExtractedFilesVerified'] -or
       -not [bool]$Package.ArchiveVerified -or -not [bool]$Package.ExtractedFilesVerified -or
       [string]$Package.Version -notmatch '^v?\d+\.\d+\.\d+$' -or -not $Package.AppDirectory){throw 'The selected CC Switch package is not a verified release slot.'}
    if($Fixture -isnot [System.Collections.IDictionary] -and -not $Fixture.PSObject.Properties['Root']){throw 'Pass the validated AppContainer fixture record.'}
    $root=[IO.Path]::GetFullPath([string]$Fixture.Root).TrimEnd('\')
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if(-not [string]::Equals((Split-Path -Parent $root),$tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $root) -notmatch '^aistick-ac-probe-[0-9a-f]{32}$'){throw 'Native update session root is not an owned temporary AppContainer fixture.'}
    $appRoot=[IO.Path]::GetFullPath((Join-Path $root 'app'))
    $runtimeRoot=[IO.Path]::GetFullPath((Join-Path $root 'runtime'))
    $updatesRoot=[IO.Path]::GetFullPath((Join-Path $runtimeRoot 'updates'))
    $targetExe=[IO.Path]::GetFullPath((Join-Path $appRoot 'cc-switch.exe'))
    $targetIni=[IO.Path]::GetFullPath((Join-Path $appRoot 'portable.ini'))
    if(-not [string]::Equals([IO.Path]::GetFullPath([string]$Fixture.Exe),$targetExe,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture executable is not the fixed owned app copy.'}
    $packageRoot=[IO.Path]::GetFullPath([string]$Package.AppDirectory)
    $sourceExe=Join-Path $packageRoot 'cc-switch.exe';$sourceIni=Join-Path $packageRoot 'portable.ini'
    foreach($p in @($sourceExe,$sourceIni,$targetExe,$targetIni)){
        $item=Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or ($item.Attributes -band [IO.FileAttributes]::Directory)){throw 'A verified package or app-copy file is not an ordinary file.'}
    }
    $exeHash=(Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if($exeHash -cne (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant() -or
       (Get-FileHash -LiteralPath $sourceIni -Algorithm SHA256).Hash.ToLowerInvariant() -cne (Get-FileHash -LiteralPath $targetIni -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'The running app copy does not match the selected verified package.'}
    if(-not $AdapterDirectory){$AdapterDirectory=Join-Path $PSScriptRoot '..\tools\cc-switch-adapter'}
    $adapter=[IO.Path]::GetFullPath($AdapterDirectory)
    $manifestPath=Join-Path $adapter 'cc-switch-portable-updater-shim.manifest.json'
    $shim=Join-Path $adapter 'cc-switch-portable-updater-shim.dll'
    $noop=Join-Path $adapter 'cc-switch-portable-update-noop.exe'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $shimSource=[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$manifest.source)))
    $noopSource=[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$manifest.noopSource)))
    if($manifest.schema -ne 1 -or [string]$manifest.architecture -cne 'x64' -or [string]$manifest.runtime -cne 'static-msvc-vcruntime' -or
       [string]$manifest.export -cne 'CCSU_InstallOpenerHook' -or [string]$manifest.source -cne 'scripts/cc-switch-portable-updater-shim.cpp' -or
       [string]$manifest.noopSource -cne 'scripts/cc-switch-portable-update-noop.cpp' -or
       -not [IO.File]::Exists($shimSource) -or -not [IO.File]::Exists($noopSource) -or -not [IO.File]::Exists($shim) -or -not [IO.File]::Exists($noop)){throw 'Portable updater adapter package is incomplete or has an unsupported contract.'}
    if((Get-FileHash -LiteralPath $shimSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.sourceSha256 -or
       (Get-FileHash -LiteralPath $shim -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.dllSha256 -or
       (Get-FileHash -LiteralPath $noopSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.noopSourceSha256 -or
       (Get-FileHash -LiteralPath $noop -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$manifest.noopExeSha256){throw 'Portable updater adapter failed its generated source/binary manifest checks.'}
    foreach($p in @($root,$appRoot,$runtimeRoot)){
        $item=Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned AppContainer runtime path may not be a reparse point.'}
    }
    [IO.Directory]::CreateDirectory($updatesRoot)|Out-Null
    $updatesItem=Get-Item -LiteralPath $updatesRoot -Force -ErrorAction Stop
    if($updatesItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned update request directory may not be a reparse point.'}
    $mailbox=Join-Path $updatesRoot 'portable-update.request'
    if([IO.File]::Exists($mailbox)){throw 'A native update request already exists for this launch.'}
    $nonce=[guid]::NewGuid().ToString('N')
    $state=$null
    try {
        $state=Start-AppContainerProbeProcess -Fixture $Fixture -NetworkMode $NetworkMode -DeferResume
        $exeAfterStart=(Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if($exeAfterStart -cne $exeHash){throw 'Selected CC Switch app copy changed before process injection.'}
        $installed=Install-CcSwitchPortableUpdaterShim -State $state -OwnedAppRoot $appRoot -ShimSource $shim -ExpectedShimSha256 ([string]$manifest.dllSha256) -NoopSource $noop -ExpectedNoopSha256 ([string]$manifest.noopExeSha256) -ExpectedExeSha256 $exeHash -MailboxPath $mailbox -Nonce $nonce -ExpectedProcessStartTicks ([long]$state.ProcessStartTicks)
        if(-not $installed.Ready){throw 'Portable native update adapter did not reach its verified ready state.'}
        Resume-AppContainerProbeProcess -State $state | Out-Null
        $requestContext=[pscustomobject]@{FixtureRoot=$root;ProcessId=[uint32]$state.ProcessId;AppContainerSid=[string]$state.AppContainerSid;NetworkMode=$NetworkMode;ExpectedNonce=$nonce;ExpectedExeSha256=$exeHash;ExpectedProcessStartTicks=[long]$state.ProcessStartTicks;MailboxPath=$mailbox;PackageVersion=([string]$Package.Version)}
        return [pscustomobject]@{State=$state;PackageVersion=[string]$Package.Version;ExpectedExeSha256=$exeHash;MailboxPath=$mailbox;Nonce=$nonce;RequestContext=$requestContext;AdapterManifest=$manifest}
    } catch {
        if($state){try{Complete-AppContainerProbeProcess -State $state}catch{if([IntPtr]$state.JobHandle -ne [IntPtr]::Zero){[AiStickAppContainerNative]::TerminateJobObject([IntPtr]$state.JobHandle,1)|Out-Null}}}
        throw
    }
}

function Read-CcSwitchNativeUpdateRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[switch]$Consume)
    . (Join-Path $PSScriptRoot 'cc-switch-portable-updater-request.ps1')
    $c=$Session.RequestContext
    return Read-CcSwitchPortableUpdaterRequestFromMetadata -FixtureRoot $c.FixtureRoot -ProcessId $c.ProcessId -AppContainerSid $c.AppContainerSid -NetworkMode $c.NetworkMode -ExpectedNonce $c.ExpectedNonce -ExpectedExeSha256 $c.ExpectedExeSha256 -ExpectedProcessStartTicks $c.ExpectedProcessStartTicks -Consume:$Consume
}

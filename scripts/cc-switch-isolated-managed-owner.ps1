[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-CcSwitchIsolatedPackageSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StickRoot)
    if(-not(Get-Command Resolve-CcPortableUpdatePackage -ErrorAction SilentlyContinue)){
        . (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')
    }
    $usb=[IO.Path]::GetFullPath($StickRoot)
    $package=Resolve-CcPortableUpdatePackage -StickRoot $usb
    foreach($field in @('Version','AppDirectory','ArchiveVerified','ExtractedFilesVerified','Source')){
        if(-not $package.PSObject.Properties[$field]){throw 'Resolved CC Switch package metadata is incomplete.'}
    }
    if(-not $package.ArchiveVerified -or -not $package.ExtractedFilesVerified -or
       [string]$package.Version -notmatch '^v\d+\.\d+\.\d+$' -or [string]$package.Source -notin @('Pinned','Managed')){throw 'Resolved CC Switch package did not pass its trust contract.'}
    $packageRoot=[IO.Path]::GetFullPath((Join-Path $usb 'tools\cc-switch')).TrimEnd('\')+'\'
    $app=[IO.Path]::GetFullPath([string]$package.AppDirectory)
    if($package.Source -ceq 'Pinned'){$expected=[IO.Path]::GetFullPath((Join-Path $packageRoot 'app'))}
    else{$expectedBase=[IO.Path]::GetFullPath((Join-Path $packageRoot 'managed\slots')).TrimEnd('\')+'\';if(-not $app.StartsWith($expectedBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $app) -cne [string]$package.Version){throw 'Managed CC Switch slot escaped its fixed USB package boundary.'};$expected=$app}
    if(-not [string]::Equals($app,$expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Resolved CC Switch package path does not match its declared source.'}
    if(-not(Get-Command Assert-CcPortableUpdateNoReparse -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')}
    Assert-CcPortableUpdateNoReparse $app
    foreach($leaf in @('cc-switch.exe','portable.ini')){
        $path=Join-Path $app $leaf;Assert-CcPortableUpdateNoReparse $path
        if(-not [IO.File]::Exists($path)){throw ('Verified CC Switch package is missing '+$leaf+'.')}
    }
    return [pscustomobject]@{Version=[string]$package.Version;AppDirectory=$app;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source=[string]$package.Source}
}

function Initialize-CcSwitchIsolatedManagedHarness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UsbRoot,
        [Parameter(Mandatory=$true)][string]$OwnedRoot,
        [Parameter(Mandatory=$true)][string]$StickRoot,
        [Parameter(Mandatory=$true)][string]$SessionRoot,
        [Parameter(Mandatory=$true)][string]$RuntimeRoot
    )
    if(-not(Get-Command Initialize-CcManagedHarnessSession -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')}
    if(-not(Get-Command New-CcSwitchPortableContext -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')}
    $managed=Initialize-CcManagedHarnessSession -UsbRoot $UsbRoot -OwnedRoot $OwnedRoot
    if(-not $managed -or -not $managed.Ready -or [string]$managed.OwnedRoot -cne [IO.Path]::GetFullPath($OwnedRoot)){throw 'Managed Claude session runtime did not initialize in this owner workspace.'}
    if(-not [string]::Equals([IO.Path]::GetFullPath([string]$managed.RuntimeRoot),[IO.Path]::GetFullPath($RuntimeRoot),[StringComparison]::OrdinalIgnoreCase) -or
       -not [string]::Equals([IO.Path]::GetFullPath([string]$managed.StickRoot),[IO.Path]::GetFullPath($StickRoot),[StringComparison]::OrdinalIgnoreCase) -or
       -not [string]::Equals([IO.Path]::GetFullPath([string]$SessionRoot),[IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'session')),[StringComparison]::OrdinalIgnoreCase)){throw 'Managed Claude session paths do not match the exact owner workspace layout.'}
    $context=New-CcSwitchPortableContext -StickRoot $StickRoot -SessionRoot $SessionRoot -RuntimeRoot $managed.RuntimeRoot -ManagedHarnessRoot $managed.ManagedHarnessRoot -ManagedHarnessSlotId $managed.SlotId
    $initialized=Initialize-CcSwitchPortableContext -Context $context
    # Initialize returns a write receipt, not a reusable context. Environment
    # derivation needs the original canonical context fields.
    $environment=Get-CcSwitchPortableEnvironment -Context $context
    return [pscustomobject]@{ManagedSession=$managed;Context=$initialized;Environment=$environment}
}

function New-CcSwitchIsolatedFixtureRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string]$StickRoot,
        [Parameter(Mandatory=$true)][string]$RuntimeRoot,
        [Parameter(Mandatory=$true)][string]$ManagedHarnessRoot,
        [Parameter(Mandatory=$true)]$Environment,
        [string[]]$Arguments=@()
    )
    $rootFull=[IO.Path]::GetFullPath($Root)
    $managedFull=[IO.Path]::GetFullPath($ManagedHarnessRoot)
    if(-not [string]::Equals($managedFull,(Join-Path $rootFull 'harness'),[StringComparison]::OrdinalIgnoreCase)) { throw 'ManagedHarnessRoot must be the exact owned NTFS workspace harness directory.' }
    return [ordered]@{
        Root=$rootFull
        Exe=[IO.Path]::GetFullPath($Exe)
        StickRoot=[IO.Path]::GetFullPath($StickRoot)
        RuntimeRoot=[IO.Path]::GetFullPath($RuntimeRoot)
        ManagedHarnessRoot=$managedFull
        Environment=$Environment
        Arguments=@($Arguments)
    }
}

function Start-CcSwitchIsolatedNativeUpdateOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Fixture,[Parameter(Mandatory=$true)]$Package,[ValidateSet('None','InternetClient')][string]$NetworkMode='None')
    if(-not (Get-Command Start-CcSwitchNativeUpdateSession -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cc-switch-native-update-session.ps1') }
    $launch=$null
    try {
        $launch=Start-CcSwitchNativeUpdateSession -Fixture $Fixture -Package $Package -NetworkMode $NetworkMode
        foreach($field in @('State','PackageVersion','ExpectedExeSha256','MailboxPath','Nonce','RequestContext')) {
            if(-not $launch -or -not $launch.PSObject.Properties[$field]) { throw 'Native update startup returned incomplete owner state.' }
        }
        foreach($field in @('FixtureRoot','ProcessId','ExpectedNonce','ExpectedExeSha256','ExpectedProcessStartTicks','MailboxPath','PackageVersion')) {
            if(-not $launch.RequestContext.PSObject.Properties[$field]) { throw 'Native update request identity is incomplete.' }
        }
        if(-not $launch.State.ProcessId -or -not $launch.State.ProcessStartTicks -or
           [string]$launch.RequestContext.FixtureRoot -cne [string]$Fixture.Root -or
           [string]$launch.RequestContext.PackageVersion -cne [string]$Package.Version -or
           [uint32]$launch.RequestContext.ProcessId -ne [uint32]$launch.State.ProcessId -or
           [long]$launch.RequestContext.ExpectedProcessStartTicks -ne [long]$launch.State.ProcessStartTicks -or
           [string]$launch.RequestContext.ExpectedExeSha256 -cne [string]$launch.ExpectedExeSha256 -or
           [string]$launch.RequestContext.ExpectedNonce -cne [string]$launch.Nonce -or
           [string]$launch.RequestContext.MailboxPath -cne [string]$launch.MailboxPath) { throw 'Native update startup identity does not match the validated fixture and package.' }
        return $launch
    } catch {
        $startupError=$_.Exception.Message
        if($launch -and $launch.PSObject.Properties['State'] -and $launch.State) {
            try { Complete-AppContainerProbeProcess -State $launch.State }
            catch {
                if($launch.State.PSObject.Properties['JobHandle'] -and [IntPtr]$launch.State.JobHandle -ne [IntPtr]::Zero -and 'AiStickAppContainerNative' -as [type]) {
                    try { [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$launch.State.JobHandle,1)|Out-Null } catch {}
                }
                throw ('Native update startup validation failed and AppContainer cleanup was incomplete; its owned workspace must be retained. '+$startupError)
            }
        }
        throw $startupError
    }
}
function Test-CcSwitchNativeUpdateNetworkAllowed([string]$NetworkMode) {
    return ($NetworkMode -ceq 'InternetClient')
}

function Save-CcSwitchIsolatedManagedHarness {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$ManagedSession,[Parameter(Mandatory=$true)][string]$UsbRoot,[Parameter(Mandatory=$true)]$ExpectedVolume,[switch]$AllowOnlineVerification)
    if(-not(Get-Command Save-CcManagedClaudeVersionSlot -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')}
    if(-not(Test-StickPresent -Expected $ExpectedVolume)){throw 'USB volume was removed or replaced before managed Claude save.'}
    Remove-CcSwitchManagedClaudeNpmAdapter -ManagedHarnessRoot ([string]$ManagedSession.ManagedHarnessRoot) -RuntimeRoot ([string]$ManagedSession.RuntimeRoot) -SlotId ([string]$ManagedSession.SlotId) | Out-Null
    $slotPath=Join-Path ([string]$ManagedSession.ManagedHarnessRoot) ('slots\'+[string]$ManagedSession.SlotId)
    $saved=Save-CcManagedClaudeVersionSlot -StagedSlotPath $slotPath -UsbRoot $UsbRoot -ExpectedVolume $ExpectedVolume -AllowOnlineVerification:$AllowOnlineVerification
    if(-not(Test-StickPresent -Expected $ExpectedVolume)){throw 'USB volume was removed or replaced after managed Claude save.'}
    if(-not $saved -or -not $saved.PSObject.Properties['Version'] -or [string]$saved.Version -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$'){throw 'Managed Claude save did not return a verified version result.'}
    return $saved
}

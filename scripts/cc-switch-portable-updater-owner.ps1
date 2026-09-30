Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Set-CcSwitchPortableUpdateOwnerStatus {
    param($SessionControl,[string]$Status,[string]$Version)
    if(-not $SessionControl){return}
    if($SessionControl -is [System.Collections.IDictionary]){
        $SessionControl['PortableUpdateStatus']=$Status
        if($Version){$SessionControl['PortableUpdateVersion']=$Version}
        return
    }
    foreach($name in @('PortableUpdateStatus','PortableUpdateVersion')){
        if(-not $SessionControl.PSObject.Properties[$name]){Add-Member -InputObject $SessionControl -MemberType NoteProperty -Name $name -Value $null}
    }
    $SessionControl.PortableUpdateStatus=$Status
    if($Version){$SessionControl.PortableUpdateVersion=$Version}
}

function Remove-CcSwitchPortableRejectedRequest {
    param($Launch)
    try{
        $ctx=$Launch.RequestContext
        $root=[IO.Path]::GetFullPath([string]$ctx.FixtureRoot).TrimEnd('\')
        $expected=[IO.Path]::GetFullPath((Join-Path $root 'runtime\updates\portable-update.request'))
        if(-not [string]::Equals([IO.Path]::GetFullPath([string]$Launch.MailboxPath),$expected,[StringComparison]::OrdinalIgnoreCase)){return}
        foreach($path in @($root,(Join-Path $root 'runtime'),(Join-Path $root 'runtime\updates'))){
            if(-not [IO.Directory]::Exists($path)){return}
            if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return}
        }
        if([IO.File]::Exists($expected) -and -not ((Get-Item -LiteralPath $expected -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
            [IO.File]::Delete($expected)
        }
    }catch{}
}

function Invoke-CcSwitchPortableUpdateOwnerRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Launch,
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)]$ExpectedVolume,
        [Parameter(Mandatory)][scriptblock]$CheckpointAction,
        $SessionControl
    )
    if(-not $Launch.PSObject.Properties['RequestContext'] -or -not $Launch.PSObject.Properties['RequestContext'].Value -or
       -not $Launch.PSObject.Properties['State'] -or -not $Launch.PSObject.Properties['ExpectedExeSha256']){throw 'Native update owner context is incomplete.'}
    $launchRoot=[IO.Path]::GetFullPath([string]$Launch.RequestContext.FixtureRoot)
    $root=[IO.Path]::GetFullPath([string]$Launch.State.FixtureRoot)
    if(-not [string]::Equals($launchRoot,$root,[StringComparison]::OrdinalIgnoreCase) -or
       [string]$Launch.RequestContext.PackageVersion -cne [string]$Launch.PackageVersion -or
       [string]$Launch.RequestContext.ExpectedExeSha256 -cne [string]$Launch.ExpectedExeSha256){throw 'Native update request context differs from the running owner process.'}
    if(-not (Get-Command Read-CcSwitchNativeUpdateRequest -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-native-update-session.ps1')}
    $observed=$null
    try{$observed=Read-CcSwitchNativeUpdateRequest -Session $Launch}catch{
        Remove-CcSwitchPortableRejectedRequest -Launch $Launch
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'RequestRejected'
        return [pscustomobject]@{Requested=$false;Rejected=$true;Candidate=$null;FatalVolumeChange=$false;Status='RequestRejected'}
    }
    if(-not $observed){return [pscustomobject]@{Requested=$false;Rejected=$false;Candidate=$null;FatalVolumeChange=$false;Status='NoRequest'}}

    # Do not consume a valid one-shot request until the current state has been
    # checkpointed. The callback is local to this owner runspace and does not
    # perform broker IPC.
    & $CheckpointAction
    $consumed=$null
    try{$consumed=Read-CcSwitchNativeUpdateRequest -Session $Launch -Consume}catch{
        Remove-CcSwitchPortableRejectedRequest -Launch $Launch
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'RequestRejected'
        return [pscustomobject]@{Requested=$false;Rejected=$true;Candidate=$null;FatalVolumeChange=$false;Status='RequestRejected'}
    }
    if(-not $consumed){Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'RequestRejected';return [pscustomobject]@{Requested=$false;Rejected=$true;Candidate=$null;FatalVolumeChange=$false;Status='RequestRejected'}}

    Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'Checking'
    try{
    if(-not (Get-Command Invoke-CcPortableUpdateCheck -ErrorAction SilentlyContinue)){throw 'Portable updater owner functions were not preloaded in this owner runspace.'}
        $checked=Invoke-CcPortableUpdateCheck -StickRoot $StickRoot -CurrentVersion $CurrentVersion -ExpectedVolume $ExpectedVolume
        if(-not (Test-StickPresent -Expected $ExpectedVolume)){
            return [pscustomobject]@{Requested=$true;Rejected=$false;Candidate=$null;FatalVolumeChange=$true;Status='VolumeChanged'}
        }
        if($checked.Current){
            Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'UpToDate' -Version ([string]$checked.LatestVersion)
            return [pscustomobject]@{Requested=$true;Rejected=$false;Candidate=$null;FatalVolumeChange=$false;Status='UpToDate';Version=[string]$checked.LatestVersion}
        }
        if(-not $checked.Prepared){throw 'Verified update check returned neither Current nor a prepared candidate.'}
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'PreparedForNormalExit' -Version ([string]$checked.Prepared.Version)
        return [pscustomobject]@{Requested=$true;Rejected=$false;Candidate=$checked.Prepared;FatalVolumeChange=$false;Status='PreparedForNormalExit';Version=[string]$checked.Prepared.Version}
    }catch{
        if(-not (Test-StickPresent -Expected $ExpectedVolume)){
            return [pscustomobject]@{Requested=$true;Rejected=$false;Candidate=$null;FatalVolumeChange=$true;Status='VolumeChanged'}
        }
        # An official API, download, or compatibility failure must leave the
        # current running app untouched and must not stop the user's session.
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'CheckFailed'
        return [pscustomobject]@{Requested=$true;Rejected=$false;Candidate=$null;FatalVolumeChange=$false;Status='CheckFailed'}
    }
}

function Complete-CcSwitchPortableUpdateOwnerSession {
    [CmdletBinding()]
    param(
        $Candidate,
        [Parameter(Mandatory)][bool]$AllowActivation,
        [Parameter(Mandatory)]$CompletedGuiState,
        [Parameter(Mandatory)]$EncryptedSession,
        [Parameter(Mandatory)]$SaveResult,
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)]$ExpectedVolume,
        $SessionControl
    )
    if(-not $Candidate){return [pscustomobject]@{Activated=$false;Status='NoPreparedUpdate';Version=$null}}
    if(-not (Get-Command Commit-CcPortableUpdateCandidate -ErrorAction SilentlyContinue) -or -not (Get-Command Discard-CcPortableUpdateCandidate -ErrorAction SilentlyContinue)){throw 'Portable updater owner functions were not preloaded in this owner runspace.'}
    if(-not $AllowActivation -or -not $SaveResult.Revision){
        try{Discard-CcPortableUpdateCandidate -Candidate $Candidate -Confirm:$false|Out-Null}catch{}
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'SavedUpdateNotActivated' -Version ([string]$Candidate.Version)
        return [pscustomobject]@{Activated=$false;Status='SavedUpdateNotActivated';Version=[string]$Candidate.Version}
    }
    try{
        # The CompletedGuiState receipt path is intentionally local: Commit
        # validates the owner-held process/job handles and encrypted revision
        # without calling back into the secure-session broker.
        $result=Commit-CcPortableUpdateCandidate -StickRoot $StickRoot -Candidate $Candidate -CompletedGuiState $CompletedGuiState -EncryptedSession $EncryptedSession -SavedRevision ([string]$SaveResult.Revision) -ExpectedVolume $ExpectedVolume -Confirm:$false
        if(-not $result.Activated){throw 'Prepared update was not activated.'}
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'Activated' -Version ([string]$result.Version)
        return [pscustomobject]@{Activated=$true;Status='Activated';Version=[string]$result.Version}
    }catch{
        try{Discard-CcPortableUpdateCandidate -Candidate $Candidate -Confirm:$false|Out-Null}catch{}
        Set-CcSwitchPortableUpdateOwnerStatus -SessionControl $SessionControl -Status 'SavedUpdateNotActivated' -Version ([string]$Candidate.Version)
        return [pscustomobject]@{Activated=$false;Status='SavedUpdateNotActivated';Version=[string]$Candidate.Version}
    }
}

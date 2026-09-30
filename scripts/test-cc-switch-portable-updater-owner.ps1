[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater-owner.ps1')
function Assert-OwnerUpdateTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$script:events=New-Object 'System.Collections.Generic.List[string]'
$script:requestCount=0;$script:requestPresent=$true;$script:checkMode='Prepared';$script:volumePresent=$true
$script:commitMode='Success';$script:commitCount=0;$script:discardCount=0
function Read-CcSwitchNativeUpdateRequest($Session,[switch]$Consume){
    if($Consume){$script:events.Add('consume')}else{$script:events.Add('peek')}
    $script:requestCount++
    if(-not $script:requestPresent){return $null}
    if($Consume){return [pscustomobject]@{Requested=$true;Consumed=$true;ProcessId=101}}
    return [pscustomobject]@{Requested=$true;Consumed=$false;ProcessId=101}
}
function Invoke-CcPortableUpdateCheck([string]$StickRoot,[string]$CurrentVersion,$ExpectedVolume){
    $script:events.Add('check')
    if($script:checkMode -eq 'Throw'){throw 'synthetic network timeout'}
    if($script:checkMode -eq 'Current'){return [pscustomobject]@{Current=$true;LatestVersion='v3.20.4';Prepared=$null}}
    if($script:checkMode -eq 'LostVolume'){$script:volumePresent=$false;throw 'synthetic USB removal'}
    return [pscustomobject]@{Current=$false;LatestVersion='v3.20.5';Prepared=[pscustomobject]@{Version='v3.20.5';CandidateId='synthetic'}}
}
function Test-StickPresent($Expected){return $script:volumePresent}
function Commit-CcPortableUpdateCandidate($StickRoot,$Candidate,$CompletedGuiState,$EncryptedSession,$SavedRevision,$ExpectedVolume,[switch]$Confirm){
    $script:commitCount++
    if($script:commitMode -eq 'Throw'){throw 'synthetic pointer activation failure'}
    if($SavedRevision -cne 'revision-2' -or -not $CompletedGuiState.Completed -or $CompletedGuiState.JobHandle -ne [IntPtr]::Zero){throw 'commit did not receive final stopped-save receipt'}
    return [pscustomobject]@{Activated=$true;Version=$Candidate.Version}
}
function Discard-CcPortableUpdateCandidate($Candidate,[switch]$Confirm){$script:discardCount++;return [pscustomobject]@{Discarded=$true}}

$launch=[pscustomobject]@{
    PackageVersion='v3.20.4';ExpectedExeSha256=('A'*64)
    State=[pscustomobject]@{FixtureRoot=(Join-Path $env:TEMP 'aistick-ac-probe-00000000000000000000000000000000')}
    RequestContext=[pscustomobject]@{FixtureRoot=(Join-Path $env:TEMP 'aistick-ac-probe-00000000000000000000000000000000');PackageVersion='v3.20.4';ExpectedExeSha256=('A'*64)}
}
$volume=[pscustomobject]@{DriveLetter='E';Serial='synthetic'}
$control=[hashtable]::Synchronized(@{})
$checkpoint={ $script:events.Add('checkpoint') }
$script:events.Clear();$script:requestCount=0;$script:checkMode='Prepared';$script:volumePresent=$true
$requestResult=Invoke-CcSwitchPortableUpdateOwnerRequest -Launch $launch -StickRoot 'E:\' -CurrentVersion 'v3.20.4' -ExpectedVolume $volume -CheckpointAction $checkpoint -SessionControl $control
Assert-OwnerUpdateTest ($requestResult.Status -eq 'PreparedForNormalExit' -and $requestResult.Candidate.Version -eq 'v3.20.5') 'Explicit native request did not prepare a candidate.'
Assert-OwnerUpdateTest (($script:events -join ',') -eq 'peek,checkpoint,consume,check') 'The updater did not checkpoint before consuming and checking the request.'
Assert-OwnerUpdateTest ($control.PortableUpdateStatus -eq 'PreparedForNormalExit' -and $control.PortableUpdateVersion -eq 'v3.20.5') 'The owner did not publish a short update status.'

$script:events.Clear();$script:requestPresent=$false
$none=Invoke-CcSwitchPortableUpdateOwnerRequest -Launch $launch -StickRoot 'E:\' -CurrentVersion 'v3.20.4' -ExpectedVolume $volume -CheckpointAction $checkpoint -SessionControl $control
Assert-OwnerUpdateTest ($none.Status -eq 'NoRequest' -and $script:events.Count -eq 1 -and $script:events[0] -eq 'peek') 'An ordinary no-request interval triggered checkpoint or update check.'

$script:requestPresent=$true;$script:checkMode='Throw';$script:volumePresent=$true;$script:events.Clear()
$timeout=Invoke-CcSwitchPortableUpdateOwnerRequest -Launch $launch -StickRoot 'E:\' -CurrentVersion 'v3.20.4' -ExpectedVolume $volume -CheckpointAction $checkpoint -SessionControl $control
Assert-OwnerUpdateTest ($timeout.Status -eq 'CheckFailed' -and -not $timeout.FatalVolumeChange -and $control.PortableUpdateStatus -eq 'CheckFailed') 'A bounded update-check failure escaped or blocked the running-session outcome.'

$script:checkMode='LostVolume';$script:volumePresent=$true
$lost=Invoke-CcSwitchPortableUpdateOwnerRequest -Launch $launch -StickRoot 'E:\' -CurrentVersion 'v3.20.4' -ExpectedVolume $volume -CheckpointAction $checkpoint -SessionControl $control
Assert-OwnerUpdateTest ($lost.FatalVolumeChange -and $lost.Status -eq 'VolumeChanged') 'A volume identity failure was treated as an ordinary network timeout.'

$completed=[pscustomobject]@{Completed=$true;ProcessId=101;ProcessStartTicks=1;ProcessHandle=[IntPtr]::Zero;JobHandle=[IntPtr]::Zero;FixtureRoot=$launch.State.FixtureRoot}
$encrypted=[pscustomobject]@{Locked=$false;Revision='revision-2';DataKey=(New-Object byte[] 32);StickRoot='E:\'}
$save=[pscustomobject]@{Revision='revision-2'}
$script:commitCount=0;$script:discardCount=0;$script:commitMode='Success'
$commit=Complete-CcSwitchPortableUpdateOwnerSession -Candidate $requestResult.Candidate -AllowActivation $true -CompletedGuiState $completed -EncryptedSession $encrypted -SaveResult $save -StickRoot 'E:\' -ExpectedVolume $volume -SessionControl $control
Assert-OwnerUpdateTest ($commit.Activated -and $script:commitCount -eq 1 -and $script:discardCount -eq 0) 'A normally stopped and saved GUI did not activate its candidate.'

$script:commitMode='Throw';$script:discardCount=0
$failedCommit=Complete-CcSwitchPortableUpdateOwnerSession -Candidate $requestResult.Candidate -AllowActivation $true -CompletedGuiState $completed -EncryptedSession $encrypted -SaveResult $save -StickRoot 'E:\' -ExpectedVolume $volume -SessionControl $control
Assert-OwnerUpdateTest (-not $failedCommit.Activated -and $failedCommit.Status -eq 'SavedUpdateNotActivated' -and $script:discardCount -eq 1 -and $control.PortableUpdateStatus -eq 'SavedUpdateNotActivated') 'Activation failure was not reported separately from the successful encrypted save.'

$script:discardCount=0
$notEligible=Complete-CcSwitchPortableUpdateOwnerSession -Candidate $requestResult.Candidate -AllowActivation $false -CompletedGuiState $completed -EncryptedSession $encrypted -SaveResult $save -StickRoot 'E:\' -ExpectedVolume $volume -SessionControl $control
Assert-OwnerUpdateTest (-not $notEligible.Activated -and $script:discardCount -eq 1 -and $script:commitCount -eq 2) 'A non-normal exit attempted candidate activation.'

Write-Output 'PASS: synthetic owner mailbox/checkpoint/check/commit gating and failure handling'

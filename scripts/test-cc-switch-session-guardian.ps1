[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$script:pass=0;$script:fail=0;$script:testRoot=$null;$script:oldLocalAppData=$env:LOCALAPPDATA
$script:children=New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'

function Check([string]$Name,[bool]$Condition) {
    if($Condition){$script:pass++;Write-Host "PASS $Name" -ForegroundColor Green}
    else{$script:fail++;Write-Host "FAIL $Name" -ForegroundColor Red}
}
function Quote-TestArg([string]$Value) {
    if($Value -notmatch '[\s"]'){return $Value}
    return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}
function Quote-PsLiteral([string]$Value) { return "'" + ($Value -replace "'","''") + "'" }
function Set-TestAcl([string]$Path,[bool]$Directory) {
    $acl=if($Directory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $acl.SetAccessRuleProtection($true,$false)
    $rights=if($Directory){[Security.AccessControl.FileSystemRights]::FullControl}else{[Security.AccessControl.FileSystemRights]::FullControl}
    $inherit=if($Directory){[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit}else{[Security.AccessControl.InheritanceFlags]::None}
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    if($Directory){[IO.Directory]::SetAccessControl($Path,$acl)}else{[IO.File]::SetAccessControl($Path,$acl)}
}
function New-Case([string]$State,[bool]$WrongSerial=$false,[bool]$EscapedRoot=$false) {
    $sid=[guid]::NewGuid().ToString('N')
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $root=Join-Path $temp ('aistick-ac-probe-'+$sid)
    $checkpoint=Join-Path $temp ('aistick-cc-switch-checkpoints-'+$sid)
    if($EscapedRoot){$root=Join-Path (Join-Path $script:testRoot 'nested') ('aistick-ac-probe-'+$sid)}
    [IO.Directory]::CreateDirectory($root)|Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.aistick-ac-probe'),'aistick appcontainer workspace v1',(New-Object Text.UTF8Encoding($false)))
    [IO.Directory]::CreateDirectory($checkpoint)|Out-Null
    [IO.File]::WriteAllText((Join-Path $checkpoint '.aistick-cc-switch-checkpoints'),$sid,(New-Object Text.UTF8Encoding($false)))
    if($State -eq 'Complete'){Remove-Item -LiteralPath $root,$checkpoint -Recurse -Force}
    $local=Join-Path (Join-Path $script:testRoot ('local-'+$sid)) 'AiStick\SecureSessions'
    [IO.Directory]::CreateDirectory($local)|Out-Null
    Set-TestAcl $local $true
    $metadataPath=Join-Path $local ($sid+'.json')
    $copyPath=Join-Path $local ('cc-switch-session-guardian-'+$sid+'.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cc-switch-session-guardian.ps1') -Destination $copyPath
    Set-TestAcl $copyPath $false
    $ownerScript=Join-Path $script:testRoot 'cc-switch-secure-session.ps1'
    [IO.File]::WriteAllText($ownerScript,'param([string]$Action,[string]$StickRoot); while($true){Start-Sleep -Seconds 1}',(New-Object Text.UTF8Encoding($false)))
    $volume=Get-VolumeIdentity -StickRoot $PSScriptRoot
    $serial=if($WrongSerial){'SYNTHETIC-WRONG-SERIAL'}else{[string]$volume.Serial}
    $metadata=[ordered]@{Version=1;SessionId=$sid;State=$State;StickRoot=[IO.Path]::GetFullPath($PSScriptRoot);OwnedRoot=$root;TrustedCheckpointRoot=$checkpoint;TempRoot=$temp;DriveLetter=$volume.DriveLetter;VolumeGuid=[string]$volume.VolumeGuid;Serial=$serial;OwnerPid=0;OwnerStartTicks=0;ProcessId=$null;ProcessStartTicks=$null;ProfileName='';AppContainerSid='';OriginalAccessSddl='';AppExePath=(Join-Path $root 'app\cc-switch.exe');RuntimeRoot=(Join-Path $root 'runtime')}
    if($State -eq 'Running'){$metadata.ProfileName='AiStick.Probe.'+$sid;$metadata.AppContainerSid='S-1-15-2-111-222';$metadata.OriginalAccessSddl=[IO.Directory]::GetAccessControl($root).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)}
    $ownerArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ownerScript,'-StickRoot',[string]$metadata.StickRoot)
    $owner=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @($ownerArgs|ForEach-Object{Quote-TestArg ([string]$_)}) -WindowStyle Hidden -PassThru
    $script:children.Add($owner)
    Start-Sleep -Milliseconds 250
    $metadata.OwnerPid=$owner.Id;$metadata.OwnerStartTicks=(Get-Process -Id $owner.Id).StartTime.ToUniversalTime().Ticks
    if($State -eq 'Running'){$metadata.ProcessId=$owner.Id;$metadata.ProcessStartTicks=$metadata.OwnerStartTicks}
    [IO.File]::WriteAllText($metadataPath,(ConvertTo-Json $metadata -Compress),(New-Object Text.UTF8Encoding($false)))
    Set-TestAcl $metadataPath $false
    $runner=Join-Path $script:testRoot ('run-'+$sid+'.ps1')
    $runText='$env:LOCALAPPDATA='+ (Quote-PsLiteral (Split-Path -Parent (Split-Path -Parent $local))) + '; & '+(Quote-TestArg $copyPath)+' -MetadataPath '+(Quote-TestArg $metadataPath)+' -GuardianCopy '+(Quote-TestArg $copyPath)
    [IO.File]::WriteAllText($runner,$runText,(New-Object Text.UTF8Encoding($false)))
    $guardian=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-TestArg $runner)) -RedirectStandardOutput (Join-Path $local 'stdout.log') -RedirectStandardError (Join-Path $local 'stderr.log') -WindowStyle Hidden -PassThru
    $script:children.Add($guardian)
    return [pscustomobject]@{Id=$sid;Root=$root;Checkpoint=$checkpoint;LocalRoot=(Split-Path -Parent (Split-Path -Parent $local));MetadataPath=$metadataPath;CopyPath=$copyPath;Owner=$owner;Guardian=$guardian;Runner=$runner;EscapedRoot=$EscapedRoot}
}
function Stop-GuardianCase($Case) {
    if(-not $Case.Owner.HasExited){$Case.Owner.Kill();$Case.Owner.WaitForExit(5000)|Out-Null}
    if(-not $Case.Guardian.HasExited){$Case.Guardian.WaitForExit(15000)|Out-Null}
}

try {
    $script:testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cc-switch-session-guardian-test-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:testRoot)|Out-Null

    $isolatedSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'cc-switch-isolated.ps1'))
    $retainRule='(?s)elseif\s*\(\s*\$failure\s*-and\s*-not\s*\$removeLocalAfterUnplug\s*-and\s*-not\s*\$state\s*-and\s*\$root\s*-and\s*\(Test-Path\s+-LiteralPath\s+\$root\s+-PathType\s+Container\)\s*-and\s*-not\s*\$rootRemoved\s*\)\s*\{\s*\$metadata\.State\s*=\s*''Preserve'''
    Check 'launcher retains stopped failed-recovery plaintext for manual recovery, excluding unplug and unknown process state' ([regex]::IsMatch($isolatedSource,$retainRule))

    $normal=New-Case -State Planned
    Start-Sleep -Milliseconds 800
    Check 'guardian waits while its exact owner is alive' ((Test-Path -LiteralPath $normal.Root -PathType Container) -and -not $normal.Guardian.HasExited)
    Stop-GuardianCase $normal
    Check 'owner exit cleans owned root, registered plaintext checkpoint, and only its own protected metadata' (-not (Test-Path -LiteralPath $normal.Root) -and -not (Test-Path -LiteralPath $normal.Checkpoint) -and -not (Test-Path -LiteralPath $normal.MetadataPath) -and -not (Test-Path -LiteralPath $normal.CopyPath))

    $running=New-Case -State Running
    Start-Sleep -Milliseconds 800
    Check 'Running metadata remains guardian-managed while the exact owner and tracked GUI process are alive' ((Test-Path -LiteralPath $running.Root -PathType Container) -and (Test-Path -LiteralPath $running.Checkpoint -PathType Container) -and -not $running.Guardian.HasExited)
    Stop-GuardianCase $running
    Check 'Running metadata is cleaned only after its tracked owner/process exits' (-not (Test-Path -LiteralPath $running.Root) -and -not (Test-Path -LiteralPath $running.Checkpoint))

    $recovered=New-Case -State Running
    Remove-Item -LiteralPath $recovered.Root -Recurse -Force
    Stop-GuardianCase $recovered
    Check 'interrupted finalization treats an already-removed plaintext root as complete and clears the checkpoint' (-not (Test-Path -LiteralPath $recovered.Root) -and -not (Test-Path -LiteralPath $recovered.Checkpoint) -and -not (Test-Path -LiteralPath $recovered.MetadataPath) -and -not (Test-Path -LiteralPath $recovered.CopyPath))

    $unplug=New-Case -State Planned -WrongSerial $true
    $unplug.Guardian.WaitForExit(15000)|Out-Null
    Check 'volume identity mismatch kills only its verified synthetic secure-session owner and cleans owned root plus plaintext checkpoint' ($unplug.Guardian.HasExited -and $unplug.Owner.HasExited -and -not (Test-Path -LiteralPath $unplug.Root) -and -not (Test-Path -LiteralPath $unplug.Checkpoint))

    $preserve=New-Case -State Preserve
    Stop-GuardianCase $preserve
    Check 'explicit recovery preservation retains roots and metadata' ((Test-Path -LiteralPath $preserve.Root) -and (Test-Path -LiteralPath $preserve.Checkpoint) -and (Test-Path -LiteralPath $preserve.MetadataPath) -and -not (Test-Path -LiteralPath $preserve.CopyPath))

    $complete=New-Case -State Complete
    $complete.Guardian.WaitForExit(10000)|Out-Null
    Check 'Complete cleans per-session guardian files without killing manager or requiring already-cleaned roots' ($complete.Guardian.HasExited -and -not $complete.Owner.HasExited -and -not (Test-Path -LiteralPath $complete.Root) -and -not (Test-Path -LiteralPath $complete.Checkpoint) -and -not (Test-Path -LiteralPath $complete.MetadataPath) -and -not (Test-Path -LiteralPath $complete.CopyPath))


    $escaped=New-Case -State Planned -EscapedRoot $true
    Stop-GuardianCase $escaped
    Check 'path outside the direct temp child boundary is retained' ((Test-Path -LiteralPath $escaped.Root) -and (Test-Path -LiteralPath $escaped.MetadataPath))
} catch {
    $script:fail++;Write-Host ("FAIL guardian synthetic setup - {0}" -f $_.Exception.Message) -ForegroundColor Red
} finally {
    foreach($child in $script:children){try{if(-not $child.HasExited){$child.Kill();$child.WaitForExit(3000)|Out-Null}}catch{}}
    if($script:oldLocalAppData){$env:LOCALAPPDATA=$script:oldLocalAppData}
    if($script:testRoot){$full=[IO.Path]::GetFullPath($script:testRoot).TrimEnd('\','/');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if([string]::Equals((Split-Path -Parent $full),$temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -match '^cc-switch-session-guardian-test-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $full -PathType Container)){try{if(@(Get-ChildItem -LiteralPath $full -Force -Recurse|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -eq 0){Remove-Item -LiteralPath $full -Recurse -Force}}catch{Write-Warning 'Synthetic guardian test tree retained for safe inspection.'}}}
}
Write-Host "Secure session guardian checks: $script:pass passed, $script:fail failed"
if($script:fail){exit 1};exit 0

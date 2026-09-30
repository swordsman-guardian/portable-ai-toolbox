[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater-owner.ps1')
function Assert-UpdateTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$script:MockRelease=$null;$script:MockArchive=$null;$script:GuiRunning=$false;$script:SessionUnlocked=$true;$script:SaveState='Saved'
$script:ExpectedVolume=$null;$script:Present=$true;$script:BlockBroker=$false
function Test-StickPresent($Expected){return $script:Present}
function Test-VolumeIdentityMatch($Expected,$Actual){return ([string]$Expected.Serial -ceq [string]$Actual.Serial -and [string]$Expected.DriveLetter -ceq [string]$Actual.DriveLetter)}
function Get-CcEncryptedStoreStatus([string]$StickRoot){[pscustomobject]@{CurrentRevision='synthetic-r1'}}
function Get-CcPortableUpdateReleaseInfo{return $script:MockRelease}
function Save-CcPortableUpdateAsset([string]$Url,[string]$Path,[long]$ExpectedLength){[IO.File]::Copy($script:MockArchive,$Path,$true);if((Get-Item -LiteralPath $Path).Length -ne $ExpectedLength){throw 'mock size mismatch'}}
function Get-CcSecureSessionStatus([string]$StickRoot){if($script:BlockBroker){throw 'Synthetic broker IPC deadlock detector.'};[pscustomobject]@{GuiRunning=$script:GuiRunning;Unlocked=$script:SessionUnlocked;LastSaveStatus=$script:SaveState}}
$realResolve=(Get-Command Resolve-CcPortableUpdatePackage).ScriptBlock
function Resolve-CcPortableUpdatePackage([string]$StickRoot){
 $d=Get-CcPortableUpdateDirectories $StickRoot
 if(-not(Test-Path -LiteralPath $d.Current) -and -not(Test-Path -LiteralPath $d.Recovery) -and -not(Test-Path -LiteralPath $d.Previous)){return [pscustomobject]@{Version='v3.20.4';AppDirectory=(Join-Path $d.PackageRoot 'app');ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Pinned'}}
 & $script:realResolve -StickRoot $StickRoot
}
function New-SyntheticRelease([string]$Version,[string]$ArchivePath){
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $temp=Join-Path $env:TEMP ('cc-updater-zip-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
 try{
  $exe=New-Object byte[] (1MB);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($exe);$rng.Dispose()
  $exe[0]=0x4d;$exe[1]=0x5a;[Array]::Copy([BitConverter]::GetBytes([uint32]0x80),0,$exe,0x3c,4)
  [Array]::Copy([BitConverter]::GetBytes([uint32]0x00004550),0,$exe,0x80,4)
  [Array]::Copy([BitConverter]::GetBytes([uint16]0x8664),0,$exe,0x84,2);[Array]::Copy([BitConverter]::GetBytes([uint16]1),0,$exe,0x86,2);[Array]::Copy([BitConverter]::GetBytes([uint16]240),0,$exe,0x94,2)
  $optional=0x98;[Array]::Copy([BitConverter]::GetBytes([uint16]0x20b),0,$exe,$optional,2);[Array]::Copy([BitConverter]::GetBytes([uint32]16),0,$exe,$optional+108,4)
  [Array]::Copy([BitConverter]::GetBytes([uint32]0x1000),0,$exe,$optional+120,4);[Array]::Copy([BitConverter]::GetBytes([uint32]60),0,$exe,$optional+124,4)
  $section=$optional+240;[Array]::Copy([Text.Encoding]::ASCII.GetBytes('.rdata'),0,$exe,$section,6)
  [Array]::Copy([BitConverter]::GetBytes([uint32]0x400),0,$exe,$section+8,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x1000),0,$exe,$section+12,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x400),0,$exe,$section+16,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x200),0,$exe,$section+20,4)
  $raw=0x200
  [Array]::Copy([BitConverter]::GetBytes([uint32]0x1080),0,$exe,$raw,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x1040),0,$exe,$raw+12,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x10a0),0,$exe,$raw+16,4)
  [Array]::Copy([BitConverter]::GetBytes([uint32]0x10b0),0,$exe,$raw+20,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x1050),0,$exe,$raw+32,4);[Array]::Copy([BitConverter]::GetBytes([uint32]0x10d0),0,$exe,$raw+36,4)
  [Array]::Clear($exe,$raw+40,20)
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes("KERNEL32.dll`0"),0,$exe,$raw+0x40,13);[Array]::Copy([Text.Encoding]::ASCII.GetBytes("SHELL32.dll`0"),0,$exe,$raw+0x50,12)
  [Array]::Copy([BitConverter]::GetBytes([uint64]0x10c0),0,$exe,$raw+0x80,8);[Array]::Copy([BitConverter]::GetBytes([uint64]0x10d0),0,$exe,$raw+0x88,8);[Array]::Copy([BitConverter]::GetBytes([uint64]0),0,$exe,$raw+0x90,8);[Array]::Copy([BitConverter]::GetBytes([uint64]0x1120),0,$exe,$raw+0xb0,8);[Array]::Copy([BitConverter]::GetBytes([uint64]0),0,$exe,$raw+0xb8,8)
  [Array]::Copy([BitConverter]::GetBytes([uint16]0),0,$exe,$raw+0xc0,2);$kernelName=[Text.Encoding]::ASCII.GetBytes("CreateProcessW`0");[Array]::Copy($kernelName,0,$exe,$raw+0xc2,$kernelName.Length)
  [Array]::Copy([BitConverter]::GetBytes([uint16]0),0,$exe,$raw+0xd0,2);$finalPathName=[Text.Encoding]::ASCII.GetBytes("GetFinalPathNameByHandleW`0");[Array]::Copy($finalPathName,0,$exe,$raw+0xd2,$finalPathName.Length)
  [Array]::Copy([BitConverter]::GetBytes([uint16]0),0,$exe,$raw+0x120,2);$shellName=[Text.Encoding]::ASCII.GetBytes("ShellExecuteW`0");[Array]::Copy($shellName,0,$exe,$raw+0x122,$shellName.Length)
  [IO.File]::WriteAllBytes((Join-Path $temp 'cc-switch.exe'),$exe)
  [IO.File]::WriteAllText((Join-Path $temp 'portable.ini'),'portable=true',(New-Object Text.UTF8Encoding($false)))
  [IO.Compression.ZipFile]::CreateFromDirectory($temp,$ArchivePath)
 }finally{Remove-Item -LiteralPath $temp -Recurse -Force}
 $hash=(Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant();$size=(Get-Item -LiteralPath $ArchivePath).Length
 $script:MockArchive=$ArchivePath;$script:MockRelease=[pscustomobject]@{Version=$Version;AssetName=('CC-Switch-'+$Version+'-Windows-Portable.zip');AssetUrl='https://github.com/farion1231/cc-switch/releases/download/'+$Version+'/CC-Switch-'+$Version+'-Windows-Portable.zip';Size=$size;Sha256=$hash}
}
$releaseFixture=[pscustomobject]@{tag_name='v3.20.5';html_url='https://github.com/farion1231/cc-switch/releases/tag/v3.20.5';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name='CC-Switch-v3.20.5-Windows-Portable.zip';size=1024;digest=('sha256:'+'a'*64);browser_download_url='https://github.com/farion1231/cc-switch/releases/download/v3.20.5/CC-Switch-v3.20.5-Windows-Portable.zip'})}
$parsedRelease=ConvertFrom-CcPortableUpdateRelease $releaseFixture
Assert-UpdateTest ($parsedRelease.Version -eq 'v3.20.5' -and $parsedRelease.Sha256 -eq ('a'*64)) 'Official release metadata parser rejected a valid stable x64 asset.'
$invalidRelease=$releaseFixture.PSObject.Copy();$invalidRelease.prerelease=$true;$failed=$false;try{ConvertFrom-CcPortableUpdateRelease $invalidRelease|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Release metadata parser accepted a prerelease.'
$invalidRelease=$releaseFixture.PSObject.Copy();$invalidRelease.assets=@($releaseFixture.assets)+@($releaseFixture.assets);$failed=$false;try{ConvertFrom-CcPortableUpdateRelease $invalidRelease|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Release metadata parser accepted duplicate matching assets.'
$invalidRelease=$releaseFixture.PSObject.Copy();$invalidRelease.assets=@([pscustomobject]@{name='CC-Switch-v3.20.5-Windows-Portable-ARM64.zip';size=1024;digest=('sha256:'+'a'*64);browser_download_url='https://github.com/farion1231/cc-switch/releases/download/v3.20.5/CC-Switch-v3.20.5-Windows-Portable-ARM64.zip'});$failed=$false;try{ConvertFrom-CcPortableUpdateRelease $invalidRelease|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Release metadata parser accepted a non-x64 asset.'
$root=Join-Path $env:TEMP ('cc-updater-test-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($root);$archive1=Join-Path $root 'release1.zip';New-SyntheticRelease 'v3.20.5' $archive1
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $zipPath=Join-Path $root 'escape.zip';$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
 try{$entry=$zip.CreateEntry('../escape.exe');$stream=$entry.Open();try{$stream.WriteByte(65)}finally{$stream.Dispose()};$entry=$zip.CreateEntry('portable.ini');$stream=$entry.Open();try{$stream.WriteByte(66)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
 $failed=$false;try{Get-CcPortableArchiveEntries -Path $zipPath -Version 'v3.20.5' -ExpectedLength (Get-Item -LiteralPath $zipPath).Length -ExpectedHash (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Archive validator accepted a path-escaping ZIP entry.'
 $script:ExpectedVolume=[pscustomobject]@{DriveLetter=([IO.Path]::GetPathRoot($root).TrimEnd('\').TrimEnd(':'));Serial='synthetic-volume';VolumeGuid='synthetic-guid'}
 $check1=Invoke-CcPortableUpdateCheck -StickRoot $root -CurrentVersion '3.20.4' -ExpectedVolume $script:ExpectedVolume
 Assert-UpdateTest (-not $check1.Current -and $check1.Prepared.ArchiveVerified -and $check1.Prepared.ExtractedFilesVerified -and $check1.Prepared.Source -eq 'Managed') 'Candidate was not fully verified and staged.'
 $slot1=$check1.Prepared.AppDirectory;Assert-UpdateTest (Test-Path -LiteralPath (Join-Path $slot1 'slot-manifest.json')) 'Staged slot has no manifest.'
 $slotManifest=Get-CcPortableSlotManifest -SlotPath $slot1 -ExpectedVersion 'v3.20.5' -ExpectedArchiveHash $script:MockRelease.Sha256
 $exeRow=@($slotManifest.Files|Where-Object{$_.Name -ceq 'cc-switch.exe'})[0];$slotExe=Join-Path $slot1 'cc-switch.exe'
 $compat=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $slotExe -ExpectedSha256 $exeRow.Sha256
 Assert-UpdateTest ($compat.Compatible -and $compat.Machine -eq 'x64' -and $compat.ImportsCreateProcessW -and $compat.ImportsGetFinalPathNameByHandleW -and $compat.ImportsShellExecute) 'x64 candidate with pinned hook imports was not accepted.'
 $badExe=Join-Path $root 'wrong-arch.exe';$badBytes=[IO.File]::ReadAllBytes($slotExe);[Array]::Copy([BitConverter]::GetBytes([uint16]0x14c),0,$badBytes,0x84,2);[IO.File]::WriteAllBytes($badExe,$badBytes)
 $compat=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $badExe -ExpectedSha256 (Get-FileHash -LiteralPath $badExe -Algorithm SHA256).Hash
 Assert-UpdateTest (-not $compat.Compatible -and $compat.Reason -match 'x64') 'PE preflight accepted a non-x64 candidate.'
 $badBytes=[IO.File]::ReadAllBytes($slotExe);$badBytes[0x2c2]=[byte][char]'X';[IO.File]::WriteAllBytes($badExe,$badBytes)
 $compat=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $badExe -ExpectedSha256 (Get-FileHash -LiteralPath $badExe -Algorithm SHA256).Hash
 Assert-UpdateTest (-not $compat.Compatible -and $compat.Reason -match 'CreateProcessW') 'PE preflight accepted a candidate without the required CreateProcessW IAT import.'
 $badBytes=[IO.File]::ReadAllBytes($slotExe);$badBytes[0x2d2]=[byte][char]'X';[IO.File]::WriteAllBytes($badExe,$badBytes)
 $compat=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $badExe -ExpectedSha256 (Get-FileHash -LiteralPath $badExe -Algorithm SHA256).Hash
 Assert-UpdateTest (-not $compat.Compatible -and $compat.Reason -match 'GetFinalPathNameByHandleW') 'PE preflight accepted a candidate without the required GetFinalPathNameByHandleW IAT import.'
 $compat=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $slotExe -ExpectedSha256 ('0'*64)
 Assert-UpdateTest (-not $compat.Compatible -and $compat.Reason -match 'hash') 'PE preflight accepted an executable whose hash differs from its manifest.'
 $candidateState=$script:CcPortableUpdateCandidateCache[$check1.Prepared.CandidateId]
 $wrongVolume=[pscustomobject]@{DriveLetter=$script:ExpectedVolume.DriveLetter;Serial='replaced-volume';VolumeGuid='replaced-guid'}
 $failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check1.Prepared -SavedRevision 'synthetic-r1' -ExpectedVolume $wrongVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted an identity mismatch with the prepared USB volume.'
 $slotExe=Join-Path $slot1 'cc-switch.exe';Set-Content -LiteralPath $slotExe -Value 'tampered' -Encoding ASCII
 $failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check1.Prepared -SavedRevision 'synthetic-r1' -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a changed staged executable.'
 [IO.File]::Copy((Join-Path $candidateState.LocalStage 'slot\cc-switch.exe'),$slotExe,$true)
 $script:Present=$false;$failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check1.Prepared -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a replaced/missing USB volume.';$script:Present=$true
 $script:GuiRunning=$true;$failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check1.Prepared -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a running GUI.'
 $script:GuiRunning=$false
 $commit1=Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check1.Prepared -SavedRevision 'synthetic-r1' -ExpectedVolume $script:ExpectedVolume -Confirm:$false
 Assert-UpdateTest ($commit1.Activated -and $commit1.Version -eq 'v3.20.5') 'First managed slot did not activate.'
 $resolved=Resolve-CcPortableUpdatePackage -StickRoot $root
 Assert-UpdateTest ($resolved.Source -eq 'Managed' -and $resolved.Version -eq 'v3.20.5' -and $resolved.ExtractedFilesVerified) 'Managed current pointer did not resolve.'
 $same=Invoke-CcPortableUpdateCheck -StickRoot $root -CurrentVersion 'v3.20.5'
 Assert-UpdateTest ($same.Current -and -not $same.Prepared) 'Current latest release was not reported as current.'

 $archive2=Join-Path $root 'release2.zip';New-SyntheticRelease 'v3.20.6' $archive2
 $check2=Invoke-CcPortableUpdateCheck -StickRoot $root -CurrentVersion 'v3.20.5' -ExpectedVolume $script:ExpectedVolume
 $script:SaveState='SaveFailed';$failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check2.Prepared -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a failed config save.'
 $script:SaveState='Saved';$script:GuiRunning=$true
 $fixture=Join-Path $root 'gui-fixture';[void][IO.Directory]::CreateDirectory($fixture);[IO.File]::WriteAllText((Join-Path $fixture '.aistick-ac-probe'),'aistick appcontainer workspace v1')
 $completed=[pscustomobject]@{Completed=$true;ProcessId=2147483647;ProcessStartTicks=1;ProcessHandle=[IntPtr]::Zero;JobHandle=[IntPtr]::Zero;FixtureRoot=$fixture}
 $encSession=[pscustomobject]@{StickRoot=$root;DataKey=(New-Object byte[] 32);Revision='synthetic-r1';Locked=$false}
 $live=[pscustomobject]@{Completed=$true;ProcessId=$PID;ProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;ProcessHandle=[IntPtr]::Zero;JobHandle=[IntPtr]::Zero;FixtureRoot=$fixture}
 $failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check2.Prepared -CompletedGuiState $live -EncryptedSession $encSession -SavedRevision 'synthetic-r1' -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a GUI process that is still alive.'
 $failed=$false;try{Commit-CcPortableUpdateCandidate -StickRoot $root -Candidate $check2.Prepared -CompletedGuiState $completed -EncryptedSession $encSession -SavedRevision 'wrong-revision' -ExpectedVolume $script:ExpectedVolume -Confirm:$false|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Commit accepted a save receipt that differs from the current encrypted revision.'
 $script:BlockBroker=$true
 $ownerCommit=Complete-CcSwitchPortableUpdateOwnerSession -Candidate $check2.Prepared -AllowActivation $true -CompletedGuiState $completed -EncryptedSession $encSession -SaveResult ([pscustomobject]@{Revision='synthetic-r1'}) -StickRoot $root -ExpectedVolume $script:ExpectedVolume
 $commit2=[pscustomobject]@{Activated=$ownerCommit.Activated;Version=$ownerCommit.Version}
 $script:BlockBroker=$false
 Assert-UpdateTest ($commit2.Activated -and $commit2.Version -eq 'v3.20.6') 'Second managed slot did not activate.'
 $currentPath=Join-Path $root 'tools\cc-switch\managed\current.json'
 Remove-Item -LiteralPath $currentPath -Force
 Set-Content -LiteralPath ($currentPath+'.next.crash-fixture') -Value '{incomplete' -Encoding UTF8
 $fallback=Resolve-CcPortableUpdatePackage -StickRoot $root
 Assert-UpdateTest ($fallback.Version -eq 'v3.20.5' -and $fallback.Source -eq 'Managed') 'Resolver did not recover the prior verified slot.'
 Remove-Item -LiteralPath ($currentPath+'.next.crash-fixture') -Force

 $badSlot=Join-Path $root 'tools\cc-switch\managed\slots\v3.20.5'
 Set-Content -LiteralPath (Join-Path $badSlot 'cc-switch.exe') -Value 'tampered' -Encoding ASCII
 $failed=$false;try{Resolve-CcPortableUpdatePackage -StickRoot $root|Out-Null}catch{$failed=$true};Assert-UpdateTest $failed 'Resolver silently fell through to pinned base after managed slots were damaged.'
 'PASS: synthetic updater stage, verification, readiness gate, pointer commit, rollback and damaged-slot refusal'
}finally{
 if(Test-Path -LiteralPath $root){$full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\';if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing recursive cleanup outside TEMP.'};$item=Get-Item -LiteralPath $full -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Refusing recursive cleanup through reparse point.'};Remove-Item -LiteralPath $full -Recurse -Force}
}

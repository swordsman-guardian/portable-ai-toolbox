[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CcPortableUpdateRepo = 'farion1231/cc-switch'
$script:CcPortableUpdateApi = 'https://api.github.com/repos/farion1231/cc-switch/releases/latest'
$script:CcPortableUpdateCandidateCache = @{}
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater-compatibility.ps1')

function Get-CcPortableUpdateFullPath([string]$Path) { [IO.Path]::GetFullPath($Path) }

function Assert-CcPortableUpdateNoReparse([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        $item=$null
        try{$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}catch [System.Management.Automation.ItemNotFoundException]{$item=$null}
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'Portable update paths may not contain reparse points.'}
        $parent=[IO.Directory]::GetParent($cursor);if(-not $parent){break};$cursor=$parent.FullName
    }
}

function Get-CcPortableUpdateDirectories([string]$StickRoot) {
    $package=Join-Path ([IO.Path]::GetFullPath($StickRoot)) 'tools\cc-switch'
    [pscustomobject]@{PackageRoot=$package;ManagedRoot=(Join-Path $package 'managed');Slots=(Join-Path $package 'managed\slots');Archives=(Join-Path $package 'managed\archives');Lock=(Join-Path $package 'managed\.updater.lock');Current=(Join-Path $package 'managed\current.json');Recovery=(Join-Path $package 'managed\current.recovery.json');Previous=(Join-Path $package 'managed\previous.json');PreviousRecovery=(Join-Path $package 'managed\previous.recovery.json')}
}

function Assert-CcPortableUpdateVolume($ExpectedVolume) {
    if(-not (Get-Command Test-StickPresent -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'lib.ps1') }
    if(-not $ExpectedVolume -or -not (Test-StickPresent -Expected $ExpectedVolume)){throw 'The expected USB volume is absent or has been replaced; portable update stopped.'}
}

function Assert-CcPortableUpdateRootVolume([string]$StickRoot,$ExpectedVolume) {
    $rootVolume=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($StickRoot)).TrimEnd('\').TrimEnd(':')
    if([string]$ExpectedVolume.DriveLetter -cne $rootVolume){throw 'Expected USB identity does not match the configured stick root drive.'}
    Assert-CcPortableUpdateVolume $ExpectedVolume
}

function Test-CcPortableUpdateVolumeIdentityMatch($Expected,$Actual) {
    if(-not $Expected -or -not $Actual -or [string]$Expected.DriveLetter -cne [string]$Actual.DriveLetter){return $false}
    $compared=0
    foreach($field in @('VolumeGuid','Serial')){
        $left=$Expected.PSObject.Properties[$field];$right=$Actual.PSObject.Properties[$field]
        if($left -and $right -and $left.Value -and $right.Value){$compared++;if(-not [string]::Equals([string]$left.Value,[string]$right.Value,[StringComparison]::OrdinalIgnoreCase)){return $false}}
    }
    return ($compared -gt 0)
}

function Enter-CcPortableUpdateLock([string]$Path,[string]$StickRoot,$ExpectedVolume) {
    $parent=Split-Path -Parent $Path
    Assert-CcPortableUpdateRootVolume $StickRoot $ExpectedVolume
    [void][IO.Directory]::CreateDirectory($parent);Assert-CcPortableUpdateNoReparse $parent
    $deadline=(Get-Date).AddSeconds(15);$lock=$null
    while(-not $lock -and (Get-Date) -lt $deadline){
        Assert-CcPortableUpdateRootVolume $StickRoot $ExpectedVolume
        try{$lock=New-Object IO.FileStream($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{Start-Sleep -Milliseconds 100}
    }
    if(-not $lock){throw 'Unable to acquire the portable update transaction lock.'}
    return $lock
}

function New-CcPortableLocalStage {
    $base=Join-Path $env:LOCALAPPDATA 'AiStick\CCSwitchUpdater'
    [void][IO.Directory]::CreateDirectory($base);Assert-CcPortableUpdateNoReparse $base
    $path=Join-Path $base ('stage-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))){[void]$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
    [IO.Directory]::SetAccessControl($path,$acl);Assert-CcPortableUpdateNoReparse $path
    [IO.File]::WriteAllText((Join-Path $path '.aistick-cc-update-stage'),'verified public package staging v1',(New-Object Text.UTF8Encoding($false)))
    return $path
}

function Remove-CcPortableLocalStage([string]$Path) {
    if(-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)){return}
    $base=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'AiStick\CCSwitchUpdater')).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove a local package stage outside its exact owned root.'}
    Assert-CcPortableUpdateNoReparse $full
    $marker=Join-Path $full '.aistick-cc-update-stage'
    if(-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne 'verified public package staging v1'){throw 'Local update stage ownership marker is missing.'}
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Get-CcPortableSlotPath([string]$Slots,[string]$Version) {
    if($Version -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Managed CC Switch pointer contains an invalid stable version.'}
    Join-Path $Slots $Version
}

function Read-CcPortableJson([string]$Path,[int]$MaxBytes=65536) {
    Assert-CcPortableUpdateNoReparse $Path
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.Length -gt $MaxBytes){throw 'Portable update metadata exceeds its fixed size limit.'}
    $enc=New-Object Text.UTF8Encoding($false,$true)
    $text=[IO.File]::ReadAllText($Path,$enc)
    try{$value=$text|ConvertFrom-Json -ErrorAction Stop;if(-not $value -or $value -isnot [pscustomobject]){throw 'Portable update metadata must be a JSON object.'};return $value}finally{$text=$null}
}

function Write-CcPortableAtomicBytes([string]$Path,[byte[]]$Bytes) {
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){[void][IO.Directory]::CreateDirectory($parent)}
    Assert-CcPortableUpdateNoReparse $parent
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        Assert-CcPortableUpdateNoReparse $temp
        if([IO.File]::Exists($Path)){throw 'Atomic target already exists; use an explicit rotation transaction.'}
        [IO.File]::Move($temp,$Path)
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Write-CcPortableJsonNew([string]$Path,$Value) {
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))
    Write-CcPortableAtomicBytes $Path $bytes
}

function Get-CcPortableSlotManifest([string]$SlotPath,[string]$ExpectedVersion,[string]$ExpectedArchiveHash) {
    Assert-CcPortableUpdateNoReparse $SlotPath
    $manifestPath=Join-Path $SlotPath 'slot-manifest.json'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Managed CC Switch slot has no verification manifest.'}
    $manifest=Read-CcPortableJson $manifestPath 16384
    if([string]$manifest.Version -cne $ExpectedVersion -or [string]$manifest.ArchiveSha256 -cne $ExpectedArchiveHash -or
       $manifest.ArchiveSha256 -notmatch '^[0-9a-f]{64}$' -or $manifest.Files -isnot [System.Array] -or @($manifest.Files).Count -ne 2){throw 'Managed CC Switch slot manifest does not match the release pointer.'}
    $expected=@('cc-switch.exe','portable.ini')
    $actual=@(Get-ChildItem -LiteralPath $SlotPath -Force | Select-Object -ExpandProperty Name | Sort-Object -CaseSensitive)
    $expectedNames=@('cc-switch.exe','portable.ini','slot-manifest.json')|Sort-Object -CaseSensitive
    if(($actual -join "`n") -cne ($expectedNames -join "`n")){throw 'Managed CC Switch slot contains unexpected files.'}
    foreach($name in $expected){
        $rows=@($manifest.Files|Where-Object{[string]$_.Name -ceq $name})
        if($rows.Count -ne 1 -or [long]$rows[0].Length -lt 0 -or [string]$rows[0].Sha256 -notmatch '^[0-9a-f]{64}$'){throw 'Managed CC Switch slot manifest file list is invalid.'}
        $file=Join-Path $SlotPath $name;Assert-CcPortableUpdateNoReparse $file
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw 'Managed CC Switch slot is incomplete.'}
        $info=Get-Item -LiteralPath $file -Force
        if($info.Length -ne [long]$rows[0].Length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$rows[0].Sha256){throw 'Managed CC Switch slot verification failed.'}
    }
    return $manifest
}

function Test-CcPortablePointer([string]$Path,[string]$Slots) {
    $pointer=Read-CcPortableJson $Path 4096
    if($pointer.Schema -ne 1 -or [string]$pointer.Version -notmatch '^v\d+\.\d+\.\d+$'){throw 'Managed CC Switch pointer is malformed.'}
    if([string]$pointer.Source -ceq 'Pinned'){
        $statusScript=Join-Path $PSScriptRoot 'cc-switch.ps1'
        $pinned=& $statusScript -Action Status -PackageRoot (Split-Path -Parent (Split-Path -Parent $Slots))
        if(('v'+[string]$pinned.Version) -cne [string]$pointer.Version -or -not $pinned.ArchiveVerified -or -not $pinned.ExtractedFilesVerified){throw 'Pinned previous CC Switch package is no longer verified.'}
        return [pscustomobject]@{Version=[string]$pointer.Version;AppDirectory=(Join-Path (Split-Path -Parent (Split-Path -Parent $Slots)) 'app');ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Pinned'}
    }
    if([string]$pointer.Source -cne 'Managed'){throw 'Managed CC Switch pointer source is invalid.'}
    if([string]$pointer.ManifestSha256 -notmatch '^[0-9a-f]{64}$'){throw 'Managed CC Switch pointer manifest digest is malformed.'}
    $slot=Get-CcPortableSlotPath $Slots ([string]$pointer.Version)
    $manifestPath=Join-Path $slot 'slot-manifest.json'
    Assert-CcPortableUpdateNoReparse $manifestPath
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pointer.ManifestSha256){throw 'Managed CC Switch pointer references an unverified slot.'}
    $manifest=Read-CcPortableJson $manifestPath 16384
    [void](Get-CcPortableSlotManifest -SlotPath $slot -ExpectedVersion ([string]$pointer.Version) -ExpectedArchiveHash ([string]$manifest.ArchiveSha256))
    return [pscustomobject]@{Version=[string]$pointer.Version;AppDirectory=$slot;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Managed'}
}

function Resolve-CcPortableUpdatePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot)
    $dirs=Get-CcPortableUpdateDirectories $StickRoot
    $pointers=@($dirs.Current,$dirs.Recovery,$dirs.Previous,$dirs.PreviousRecovery)
    $pointerExists=$false
    foreach($path in $pointers){if(Test-Path -LiteralPath $path -PathType Leaf){$pointerExists=$true;break}}
    if($pointerExists){
        $errors=New-Object 'System.Collections.Generic.List[string]'
        foreach($path in $pointers){
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
            try{return (Test-CcPortablePointer -Path $path -Slots $dirs.Slots)}catch{$errors.Add([IO.Path]::GetFileName($path)+' failed validation')}
        }
        throw ('Managed CC Switch slots are damaged; restore/update is required. '+($errors -join '; '))
    }
    $statusScript=Join-Path $PSScriptRoot 'cc-switch.ps1'
    if(-not(Test-Path -LiteralPath $statusScript -PathType Leaf)){throw 'Pinned CC Switch status script is missing.'}
    $pinned=& $statusScript -Action Status -PackageRoot $dirs.PackageRoot
    if(-not $pinned -or [string]$pinned.Version -notmatch '^\d+\.\d+\.\d+$' -or -not $pinned.ArchiveVerified -or -not $pinned.ExtractedFilesVerified){throw 'Pinned CC Switch installation is not verified and no managed slot is available.'}
    return [pscustomobject]@{Version=('v'+[string]$pinned.Version);AppDirectory=(Join-Path $dirs.PackageRoot 'app');ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Pinned'}
}

function Get-CcPortableUpdateReleaseInfo {
    [CmdletBinding()]
    param()
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $headers=@{Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='CC-Switch-Portable-Updater'}
    $response=Invoke-WebRequest -Uri $script:CcPortableUpdateApi -Headers $headers -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 2
    if($response.BaseResponse.ResponseUri.Host -cne 'api.github.com' -or $response.BaseResponse.ResponseUri.AbsolutePath -cne '/repos/farion1231/cc-switch/releases/latest'){throw 'GitHub release API redirected outside the pinned official endpoint.'}
    $release=$response.Content|ConvertFrom-Json -ErrorAction Stop
    return (ConvertFrom-CcPortableUpdateRelease $release)
}

function ConvertFrom-CcPortableUpdateRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release)
    $release=$Release
    if([string]$release.html_url -notmatch '^https://github\.com/farion1231/cc-switch/releases/tag/v\d+\.\d+\.\d+$' -or
       $release.draft -ne $false -or $release.prerelease -ne $false -or [string]$release.tag_name -notmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Latest GitHub release is not a stable CC Switch release.'}
    $expected='CC-Switch-'+[string]$release.tag_name+'-Windows-Portable.zip'
    $assets=@($release.assets|Where-Object{[string]$_.name -ceq $expected})
    if($assets.Count -ne 1 -or [long]$assets[0].size -lt 1024 -or [long]$assets[0].size -gt 100MB -or
       [string]$assets[0].digest -notmatch '^sha256:[0-9a-fA-F]{64}$' -or
       [string]$assets[0].browser_download_url -cne ('https://github.com/farion1231/cc-switch/releases/download/'+[string]$release.tag_name+'/'+$expected)){
        throw 'Official release does not have one exact x64 portable ZIP with a SHA-256 digest.'
    }
    return [pscustomobject]@{Version=[string]$release.tag_name;AssetName=$expected;AssetUrl=[string]$assets[0].browser_download_url;Size=[long]$assets[0].size;Sha256=([string]$assets[0].digest).Substring(7).ToLowerInvariant()}
}

function Save-CcPortableUpdateAsset([string]$Url,[string]$Path,[long]$ExpectedLength) {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $headers=@{'User-Agent'='CC-Switch-Portable-Updater';Accept='application/octet-stream'}
    $response=Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 90 -MaximumRedirection 5 -OutFile $Path -PassThru
    $hostName=$response.BaseResponse.ResponseUri.Host.ToLowerInvariant()
    if($hostName -notin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')){throw 'Portable update download redirected outside approved GitHub asset hosts.'}
    $info=Get-Item -LiteralPath $Path -Force
    if($info.Length -ne $ExpectedLength -or $info.Length -gt 100MB){throw 'Downloaded CC Switch asset has an unexpected length.'}
}

function Get-CcPortableArchiveEntries([string]$Path,[string]$Version,[long]$ExpectedLength,[string]$ExpectedHash) {
    if((Get-Item -LiteralPath $Path -Force).Length -ne $ExpectedLength -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'Downloaded CC Switch archive does not match GitHub SHA-256 digest.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{
        $entries=@($zip.Entries)
        if($entries.Count -ne 2){throw 'Official portable archive must contain exactly two files.'}
        $expected=@('cc-switch.exe','portable.ini')
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $rows=New-Object 'System.Collections.Generic.List[object]'
        foreach($entry in $entries){
            $name=$entry.FullName
            if($name -notin $expected -or $name.Contains('\') -or $name.Contains('/') -or $name.Contains(':') -or $name -match '[\x00-\x1f]' -or -not $seen.Add($name)){throw 'Official portable archive contains an unexpected or duplicate path.'}
            if(($name -ceq 'cc-switch.exe' -and ($entry.Length -lt 1MB -or $entry.Length -gt 200MB)) -or ($name -ceq 'portable.ini' -and $entry.Length -gt 4096)){throw 'Official portable archive member exceeds its fixed size limits.'}
            if($entry.CompressedLength -eq 0 -and $entry.Length -gt 0 -or $entry.CompressedLength -gt 0 -and $entry.Length -gt $entry.CompressedLength * 200){throw 'Official portable archive has a suspicious compression ratio.'}
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
            $rows.Add([pscustomobject]@{Name=$name;Length=[long]$entry.Length;Sha256=$hash})
        }
        if($seen.Count -ne 2 -or -not $seen.Contains('cc-switch.exe') -or -not $seen.Contains('portable.ini')){throw 'Official portable archive file list is incomplete.'}
        return ,$rows.ToArray()
    }finally{$zip.Dispose()}
}

function Expand-CcPortableUpdateArchive([string]$ArchivePath,[string]$SlotPath,[string]$Version,[long]$ExpectedLength,[string]$ExpectedHash) {
    $rows=Get-CcPortableArchiveEntries $ArchivePath $Version $ExpectedLength $ExpectedHash
    if(Test-Path -LiteralPath $SlotPath){throw 'CC Switch version slot already exists; refusing to overwrite it.'}
    [void][IO.Directory]::CreateDirectory($SlotPath);Assert-CcPortableUpdateNoReparse $SlotPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try{
        foreach($row in $rows){$entry=@($zip.Entries|Where-Object{$_.FullName -ceq $row.Name})[0];$target=Join-Path $SlotPath $row.Name;$source=$entry.Open();$dest=New-Object IO.FileStream($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$source.CopyTo($dest);$dest.Flush($true)}finally{$source.Dispose();$dest.Dispose()}}
    }finally{$zip.Dispose()}
    foreach($row in $rows){$file=Join-Path $SlotPath $row.Name;Assert-CcPortableUpdateNoReparse $file;if((Get-Item -LiteralPath $file).Length -ne $row.Length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $row.Sha256){throw 'Expanded CC Switch file did not match its verified archive member.'}}
    $manifest=[ordered]@{Schema=1;Version=$Version;ArchiveSha256=$ExpectedHash;Files=@($rows)}
    Write-CcPortableJsonNew (Join-Path $SlotPath 'slot-manifest.json') $manifest
    $manifestHash=(Get-FileHash -LiteralPath (Join-Path $SlotPath 'slot-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    [void](Get-CcPortableSlotManifest -SlotPath $SlotPath -ExpectedVersion $Version -ExpectedArchiveHash $ExpectedHash)
    return $manifestHash
}

function Invoke-CcPortableUpdateCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot,[Parameter(Mandatory)][string]$CurrentVersion,$ExpectedVolume)
    if($CurrentVersion -notmatch '^v?\d+\.\d+\.\d+$'){throw 'Current version must be a stable semantic version.'}
    $current='v'+$CurrentVersion.TrimStart('v')
    $release=Get-CcPortableUpdateReleaseInfo
    $currentParts=[version]$current.Substring(1);$latestParts=[version]$release.Version.Substring(1)
    if($latestParts -le $currentParts){return [pscustomobject]@{Current=$true;CurrentVersion=$current;LatestVersion=$release.Version;Prepared=$null}}
    $dirs=Get-CcPortableUpdateDirectories $StickRoot
    Assert-CcPortableUpdateNoReparse $dirs.PackageRoot
    if(-not $ExpectedVolume){if(-not (Get-Command Get-VolumeIdentity -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'lib.ps1')};$ExpectedVolume=Get-VolumeIdentity -StickRoot ([IO.Path]::GetFullPath($StickRoot))}
    Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
    $lock=Enter-CcPortableUpdateLock $dirs.Lock $dirs.PackageRoot $ExpectedVolume
    $localStage=$null
    try{
    [void][IO.Directory]::CreateDirectory($dirs.Slots);[void][IO.Directory]::CreateDirectory($dirs.Archives)
    $slot=Get-CcPortableSlotPath $dirs.Slots $release.Version
    $id=[guid]::NewGuid().ToString('N')
    $localStage=New-CcPortableLocalStage
    $archive=Join-Path $localStage 'release.zip'
    try{
        Save-CcPortableUpdateAsset $release.AssetUrl $archive $release.Size
        $localSlot=Join-Path $localStage 'slot'
        $manifestHash=Expand-CcPortableUpdateArchive $archive $localSlot $release.Version $release.Size $release.Sha256
        $localExe=Join-Path $localSlot 'cc-switch.exe'
        $localExeHash=(Get-FileHash -LiteralPath $localExe -Algorithm SHA256).Hash
        $compatibility=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath $localExe -ExpectedSha256 $localExeHash
        if(-not $compatibility.Compatible){throw ('Official CC Switch candidate is incompatible with the current isolated updater hook: '+$compatibility.Reason)}
        Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
        if(Test-Path -LiteralPath $slot -PathType Container){
            $existingManifest=Join-Path $slot 'slot-manifest.json'
            if(-not(Test-Path -LiteralPath $existingManifest -PathType Leaf)){throw 'A pre-existing CC Switch version slot is incomplete; refusing to overwrite it.'}
            $existing=Read-CcPortableJson $existingManifest 16384
            if([string]$existing.ArchiveSha256 -cne $release.Sha256){throw 'A pre-existing CC Switch version slot has different release content.'}
            [void](Get-CcPortableSlotManifest -SlotPath $slot -ExpectedVersion $release.Version -ExpectedArchiveHash $release.Sha256)
            if((Get-FileHash -LiteralPath $existingManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifestHash){throw 'Pre-existing CC Switch slot differs from the newly verified official package.'}
        }else{
            $usbStage=Join-Path $dirs.Slots ('.stage-'+$id)
            [void][IO.Directory]::CreateDirectory($usbStage)
            try{
                foreach($name in @('cc-switch.exe','portable.ini','slot-manifest.json')){
                    Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
                    $source=Join-Path $localSlot $name;$destination=Join-Path $usbStage $name
                    Assert-CcPortableUpdateNoReparse $destination;[IO.File]::Copy($source,$destination,$false)
                }
                [void](Get-CcPortableSlotManifest -SlotPath $usbStage -ExpectedVersion $release.Version -ExpectedArchiveHash $release.Sha256)
                Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
                [IO.Directory]::Move($usbStage,$slot)
            }catch{if(Test-Path -LiteralPath $usbStage){Assert-CcPortableUpdateNoReparse $usbStage;Remove-Item -LiteralPath $usbStage -Recurse -Force -ErrorAction SilentlyContinue};throw}
        }
        $usbArchive=Join-Path $dirs.Archives ($release.Version+'.zip')
        Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
        Assert-CcPortableUpdateNoReparse $usbArchive
        if(Test-Path -LiteralPath $usbArchive -PathType Leaf){if((Get-FileHash -LiteralPath $usbArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.Sha256){throw 'Existing official archive copy does not match the current GitHub digest.'}}else{
            $archiveTemp=$usbArchive+'.'+$id+'.tmp';[IO.File]::Copy($archive,$archiveTemp,$false);Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
            if((Get-FileHash -LiteralPath $archiveTemp -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.Sha256){throw 'Copied release archive failed verification.'};[IO.File]::Move($archiveTemp,$usbArchive)
        }
        Assert-CcPortableUpdateRootVolume $dirs.PackageRoot $ExpectedVolume
        $candidateId=[guid]::NewGuid().ToString('N')
        $script:CcPortableUpdateCandidateCache[$candidateId]=[pscustomobject]@{Version=$release.Version;Slot=$slot;ArchivePath=$usbArchive;ArchiveHash=$release.Sha256;ArchiveLength=$release.Size;ManifestHash=$manifestHash;StickRoot=[IO.Path]::GetFullPath($StickRoot);ExpectedVolume=$ExpectedVolume;LocalStage=$localStage}
        $prepared=[pscustomobject]@{CandidateId=$candidateId;Version=$release.Version;AppDirectory=$slot;ArchiveVerified=$true;ExtractedFilesVerified=$true;Source='Managed'}
        $localStage=$null # retain the protected local copy until activation/explicit cancellation
        return [pscustomobject]@{Current=$false;CurrentVersion=$current;LatestVersion=$release.Version;Prepared=$prepared}
    }finally{if($localStage){Remove-CcPortableLocalStage $localStage}}
    }finally{$lock.Dispose()}
}

function Commit-CcPortableUpdateCandidate {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$StickRoot,[Parameter(Mandatory)]$Candidate,$CompletedGuiState,$EncryptedSession,[string]$SavedRevision,$ExpectedVolume)
    $id=[string]$Candidate.CandidateId
    if(-not $script:CcPortableUpdateCandidateCache.ContainsKey($id)){throw 'A live in-process update candidate is required.'}
    $item=$script:CcPortableUpdateCandidateCache[$id]
    if(-not [string]::Equals([IO.Path]::GetFullPath($StickRoot),$item.StickRoot,[StringComparison]::OrdinalIgnoreCase) -or [string]$Candidate.Version -cne $item.Version){throw 'Update candidate root/version changed.'}
    if(-not $ExpectedVolume){$ExpectedVolume=$item.ExpectedVolume}
    if(-not (Test-CcPortableUpdateVolumeIdentityMatch -Expected $item.ExpectedVolume -Actual $ExpectedVolume)){throw 'Update activation volume identity differs from the prepared candidate.'}
    Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
    if([string]::IsNullOrWhiteSpace($SavedRevision)){throw 'Update activation requires the revision returned by the stopped encrypted save.'}
    $status=$null
    if($CompletedGuiState){
        if(-not $EncryptedSession -or $EncryptedSession.Locked -or $EncryptedSession.DataKey -isnot [byte[]] -or $EncryptedSession.DataKey.Length -ne 32 -or
           -not [string]::Equals([IO.Path]::GetFullPath([string]$EncryptedSession.StickRoot),$item.StickRoot,[StringComparison]::OrdinalIgnoreCase) -or
           [string]$EncryptedSession.Revision -cne $SavedRevision){throw 'Completed GUI activation requires the same unlocked encrypted session and saved revision.'}
        foreach($required in @('Completed','ProcessId','ProcessStartTicks','ProcessHandle','JobHandle','FixtureRoot')){if(-not $CompletedGuiState.PSObject.Properties[$required]){throw 'Completed GUI state receipt is incomplete.'}}
        if(-not $CompletedGuiState.Completed -or [int]$CompletedGuiState.ProcessId -le 0 -or [long]$CompletedGuiState.ProcessStartTicks -le 0 -or
           [IntPtr]$CompletedGuiState.ProcessHandle -ne [IntPtr]::Zero -or [IntPtr]$CompletedGuiState.JobHandle -ne [IntPtr]::Zero){throw 'Completed GUI state receipt does not confirm owned process cleanup.'}
        $fixture=[IO.Path]::GetFullPath([string]$CompletedGuiState.FixtureRoot)
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $fixture.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Completed GUI state fixture is outside the owned local temporary boundary.'}
        Assert-CcPortableUpdateNoReparse $fixture
        $ownedMarker=Join-Path $fixture '.aistick-ac-probe'
        if(-not [IO.File]::Exists($ownedMarker) -or [IO.File]::ReadAllText($ownedMarker) -cne 'aistick appcontainer workspace v1'){throw 'Completed GUI state fixture ownership marker is missing or invalid.'}
        $running=$null;try{$running=Get-Process -Id ([int]$CompletedGuiState.ProcessId) -ErrorAction Stop}catch{}
        if($running -and $running.StartTime.ToUniversalTime().Ticks -eq [long]$CompletedGuiState.ProcessStartTicks){throw 'The owned GUI process is still running.'}
    }else{
        if(-not(Get-Command Get-CcSecureSessionStatus -ErrorAction SilentlyContinue)){throw 'The secure-session manager must provide its current saved status before package activation.'}
        $status=Get-CcSecureSessionStatus -StickRoot $item.StickRoot
        if(-not $status.Unlocked -or $status.GuiRunning -or [string]$status.LastSaveStatus -cne 'Saved'){throw 'Update activation requires an unlocked broker, stopped GUI, and saved encrypted configuration.'}
    }
    if(-not(Get-Command Get-CcEncryptedStoreStatus -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')}
    $encryptedStatus=Get-CcEncryptedStoreStatus -StickRoot $item.StickRoot
    if([string]$encryptedStatus.CurrentRevision -cne [string]$SavedRevision){throw 'The encrypted current revision differs from the completed save receipt.'}
    Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
    $dirs=Get-CcPortableUpdateDirectories $item.StickRoot
    $manifestHash=(Get-FileHash -LiteralPath (Join-Path $item.Slot 'slot-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if($manifestHash -cne $item.ManifestHash){throw 'Prepared update candidate changed after verification.'}
    $slotManifest=Get-CcPortableSlotManifest -SlotPath $item.Slot -ExpectedVersion $item.Version -ExpectedArchiveHash $item.ArchiveHash
    $exeRows=@($slotManifest.Files|Where-Object{[string]$_.Name -ceq 'cc-switch.exe'})
    if($exeRows.Count -ne 1){throw 'Prepared slot manifest does not identify exactly one CC Switch executable.'}
    $compatibility=Test-CcPortableUpdaterCandidateCompatibility -ExecutablePath (Join-Path $item.Slot 'cc-switch.exe') -ExpectedSha256 ([string]$exeRows[0].Sha256)
    if(-not $compatibility.Compatible){throw ('Prepared CC Switch candidate is incompatible with the current isolated updater hook: '+$compatibility.Reason)}
    if(-not [IO.File]::Exists($item.ArchivePath) -or (Get-Item -LiteralPath $item.ArchivePath).Length -ne $item.ArchiveLength){throw 'Prepared official release archive is missing or changed.'}
    Assert-CcPortableUpdateNoReparse $item.ArchivePath
    Assert-CcPortableUpdateNoReparse (Join-Path $item.LocalStage 'release.zip')
    Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
    [void](Get-CcPortableArchiveEntries -Path $item.ArchivePath -Version $item.Version -ExpectedLength $item.ArchiveLength -ExpectedHash $item.ArchiveHash)
    if((Get-FileHash -LiteralPath (Join-Path $item.LocalStage 'release.zip') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.ArchiveHash){throw 'Protected local update staging archive changed after verification.'}
    if(-not $PSCmdlet.ShouldProcess($item.Version,'Activate verified CC Switch managed version slot')){return [pscustomobject]@{Activated=$false;Prepared=$true;Version=$item.Version}}
    $lock=Enter-CcPortableUpdateLock $dirs.Lock $item.StickRoot $ExpectedVolume
    $next=$dirs.Current+'.next.'+[guid]::NewGuid().ToString('N')
    $pointer=[ordered]@{Schema=1;Source='Managed';Version=$item.Version;ManifestSha256=$item.ManifestHash;Generation=[guid]::NewGuid().ToString('N')}
    try{
        Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
        $lockedEncrypted=Get-CcEncryptedStoreStatus -StickRoot $item.StickRoot
        if([string]$lockedEncrypted.CurrentRevision -cne [string]$SavedRevision){throw 'Encrypted save state changed while waiting for the updater lock.'}
        if(-not $CompletedGuiState){$lockedSession=Get-CcSecureSessionStatus -StickRoot $item.StickRoot;if(-not $lockedSession.Unlocked -or $lockedSession.GuiRunning -or [string]$lockedSession.LastSaveStatus -cne 'Saved'){throw 'GUI or save state changed while waiting for the updater lock.'}}
        Write-CcPortableJsonNew $next $pointer
        Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
        if(Test-Path -LiteralPath $dirs.Current -PathType Leaf){
            Assert-CcPortableUpdateNoReparse $dirs.Current
            $old=Read-CcPortableJson $dirs.Current 4096
            $oldCopy=$dirs.Previous+'.next.'+[guid]::NewGuid().ToString('N')
            Write-CcPortableJsonNew $oldCopy $old
            if(Test-Path -LiteralPath $dirs.Previous){Assert-CcPortableUpdateNoReparse $dirs.Previous;if(Test-Path -LiteralPath $dirs.PreviousRecovery){Assert-CcPortableUpdateNoReparse $dirs.PreviousRecovery;Remove-Item -LiteralPath $dirs.PreviousRecovery -Force};[IO.File]::Move($dirs.Previous,$dirs.PreviousRecovery)}
            Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
            [IO.File]::Move($oldCopy,$dirs.Previous)
            if(Test-Path -LiteralPath $dirs.Recovery){Assert-CcPortableUpdateNoReparse $dirs.Recovery;Remove-Item -LiteralPath $dirs.Recovery -Force}
            Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
            [IO.File]::Move($dirs.Current,$dirs.Recovery)
        }elseif(-not(Test-Path -LiteralPath $dirs.Previous -PathType Leaf)){
            $pinned=Resolve-CcPortableUpdatePackage -StickRoot $item.StickRoot
            if($pinned.Source -cne 'Pinned'){throw 'Initial managed activation has no verified pinned rollback package.'}
            $old=[ordered]@{Schema=1;Source='Pinned';Version=$pinned.Version;Generation=[guid]::NewGuid().ToString('N')}
            Write-CcPortableJsonNew $dirs.Previous $old
        }
        Assert-CcPortableUpdateRootVolume $item.StickRoot $ExpectedVolume
        [IO.File]::Move($next,$dirs.Current)
        $resolved=Resolve-CcPortableUpdatePackage -StickRoot $item.StickRoot
        if($resolved.Version -cne $item.Version -or $resolved.AppDirectory -cne $item.Slot){throw 'Managed update pointer verification failed after activation.'}
        $script:CcPortableUpdateCandidateCache.Remove($id)
        Remove-CcPortableLocalStage $item.LocalStage
        return [pscustomobject]@{Activated=$true;Version=$item.Version;AppDirectory=$item.Slot;Source='Managed';PreviousPointerAvailable=(Test-Path -LiteralPath $dirs.Previous -PathType Leaf)}
    }finally{if(Test-Path -LiteralPath $next){Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue};$lock.Dispose()}
}

function Discard-CcPortableUpdateCandidate {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)]$Candidate)
    $id=[string]$Candidate.CandidateId
    if(-not $script:CcPortableUpdateCandidateCache.ContainsKey($id)){throw 'A live in-process update candidate is required.'}
    $item=$script:CcPortableUpdateCandidateCache[$id]
    if($PSCmdlet.ShouldProcess($item.Version,'Discard protected local update staging data')){
        Remove-CcPortableLocalStage $item.LocalStage
        $script:CcPortableUpdateCandidateCache.Remove($id)
        return [pscustomobject]@{Discarded=$true;Version=$item.Version}
    }
}


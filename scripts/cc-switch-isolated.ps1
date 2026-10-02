[CmdletBinding()]
param(
    [ValidateSet('Status','Launch','SecureManager')][string]$Action = 'Status',
    [string]$StickRoot,
    [object]$EncryptedSession,
    [object]$SessionControl,
    [ValidateSet('None','InternetClient')][string]$NetworkMode = 'None',
    [switch]$ImportToolboxBeforeLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'This product candidate requires Windows PowerShell 5.1.' }
. (Join-Path $PSScriptRoot 'cc-switch-isolated-managed-owner.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater-owner.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $StickRoot) { $StickRoot = $projectRoot }

function Quote-SecureManagerArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder; [void]$builder.Append('"'); $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$builder.Append(('\' * (2 * $slashes + 1))); [void]$builder.Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"'); return $builder.ToString()
}

if ($Action -eq 'SecureManager') {
    $manager = Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1'
    . $manager -StickRoot $StickRoot -NetworkMode $NetworkMode -ImportToolboxBeforeLaunch:$ImportToolboxBeforeLaunch
    $pipeName = Get-CcSecurePipeName $StickRoot
    $locatorPath = Get-CcSecureLocatorPath $pipeName
    $pipeAvailable = Test-CcSecureSessionPipeAvailable -StickRoot $StickRoot -PipeName $pipeName
    $locatorAvailable = [IO.File]::Exists($locatorPath)
    # Host startup binds the first pipe before atomically publishing its locator.
    # Retry this tiny publication window; never send an unauthenticated request.
    if ($pipeAvailable -and -not $locatorAvailable) {
        for ($attempt = 0; $attempt -lt 4 -and -not $locatorAvailable; $attempt++) {
            Start-Sleep -Milliseconds 100
            $locatorAvailable = [IO.File]::Exists($locatorPath)
            if (-not $locatorAvailable) { $pipeAvailable = Test-CcSecureSessionPipeAvailable -StickRoot $StickRoot -PipeName $pipeName }
            if (-not $pipeAvailable) { break }
        }
    }
    $sessionDisposition = Get-CcSecureManagerSessionDisposition -PipeAvailable $pipeAvailable -LocatorAvailable $locatorAvailable
    if ($sessionDisposition -eq 'Reuse') {
        if ($ImportToolboxBeforeLaunch) { throw '请先保存并锁定当前 CC Switch 会话，再执行一次性配置迁移。' }
        $status=$null
        try { $status = Get-CcSecureSessionStatus -StickRoot $StickRoot }
        catch {
            if($_.Exception.Message -cne 'No secure session locator is registered for this volume root.'){throw}
            # Locator may have been removed after our presence check. Re-evaluate
            # once; only an actually absent server may proceed to password unlock.
            Start-Sleep -Milliseconds 100
            $locatorAvailable=[IO.File]::Exists($locatorPath)
            $pipeAvailable=Test-CcSecureSessionPipeAvailable -StickRoot $StickRoot -PipeName $pipeName
            if($pipeAvailable -and -not $locatorAvailable){throw '加密会话管道仍在运行，但安全定位文件缺失；为避免连接到未经验证的会话，请关闭该会话窗口后重试。'}
            if($pipeAvailable -and $locatorAvailable){$status=Get-CcSecureSessionStatus -StickRoot $StickRoot}
            else{$sessionDisposition='Start'}
        }
        if($sessionDisposition -eq 'Start') { }
        else {
        if (-not $status.Unlocked) { throw 'Secure session manager is running but locked or unavailable; refusing a duplicate host.' }
        if (-not $status.PSObject.Properties['NetworkMode'] -or $status.NetworkMode -cne $NetworkMode) { throw '请先锁定当前 CC Switch 会话，再切换联网 / 离线模式。' }
        $null = Request-CcSecureSessionGui -StickRoot $StickRoot
        return
        }
    }
    if ($sessionDisposition -eq 'FailClosed') {
        throw '加密会话管道仍在运行，但安全定位文件缺失；为避免连接到未经验证的会话，请关闭该会话窗口后重试。'
    }
    # No live server: starting the existing host reuses the protected vault and
    # prompts for its master password. The host safely handles stale locators.
    if ($locatorAvailable) { Assert-CcSecureSessionStaleLocator -StickRoot $StickRoot -PipeName $pipeName -LocatorPath $locatorPath | Out-Null }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $windowWrapper = Join-Path $PSScriptRoot 'cc-switch-secure-manager-window.ps1'
    if (-not (Test-Path -LiteralPath $windowWrapper -PathType Leaf)) { throw 'Secure manager window wrapper is missing.' }
    $managerArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$windowWrapper,'-StickRoot',$StickRoot,'-NetworkMode',$NetworkMode)
    if ($ImportToolboxBeforeLaunch) { $managerArgs += '-ImportToolboxBeforeLaunch' }
    $quoted = @($managerArgs | ForEach-Object { Quote-SecureManagerArgument ([string]$_) })
    Start-Process -FilePath $powershell -ArgumentList $quoted -WindowStyle Normal -ErrorAction Stop | Out-Null
    return
}

function Get-IsolatedFileInventory {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $files = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($rootFull)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current,'*',[IO.SearchOption]::TopDirectoryOnly)) {
            $attr = [IO.File]::GetAttributes($entry)
            if ($attr -band [IO.FileAttributes]::ReparsePoint) { throw 'The fixed runtime tree may not contain reparse points.' }
            if ($attr -band [IO.FileAttributes]::Directory) { $pending.Push($entry) }
            else {
                $files.Add($entry.Substring($rootFull.Length + 1))
                if ($files.Count -gt 10000) { throw 'The fixed runtime contains too many files.' }
            }
        }
    }
    return ,$files.ToArray()
}

function Get-IsolatedUnplugCleanupDecision {
    param([Parameter(Mandatory=$true)][bool]$VolumePresent)
    return (-not $VolumePresent)
}

function Test-IsolatedUnplugCleanupDecision {
    if (-not (Get-IsolatedUnplugCleanupDecision -VolumePresent $false)) { throw 'Synthetic removed-volume case did not request owned-root cleanup.' }
    if (Get-IsolatedUnplugCleanupDecision -VolumePresent $true) { throw 'Synthetic present-volume case incorrectly requested unplug cleanup.' }
    return 'Synthetic unplug cleanup decision passed.'
}

function Set-CcSwitchGuardianMetadata {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Record)
    $dir=Split-Path -Parent $Path
    if(-not [IO.Directory]::Exists($dir)){throw 'Protected guardian metadata directory is missing.'}
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Record -Depth 6 -Compress),(New-Object Text.UTF8Encoding($false)))
    $acl=New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){[void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','None','None','Allow')))}
    [IO.File]::SetAccessControl($temp,$acl)
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        while($true) {
            try {
                if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
                break
            } catch [IO.IOException] {
                if([DateTime]::UtcNow -ge $deadline){throw}
                Start-Sleep -Milliseconds 100
            }
        }
    } finally { if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)} }
}

function Get-IsolatedStatus {
    param([string]$UsbRoot)
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $packageStatus = $null
    $storeStatus = $null
    $storeScript = Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1'
    $checkpointScript = Join-Path $PSScriptRoot 'cc-switch-checkpoint.ps1'
    $contextScript = Join-Path $PSScriptRoot 'cc-switch-context.ps1'
    $probeScript = Join-Path $PSScriptRoot 'appcontainer-probe.ps1'
    $packageRoot = Join-Path $projectRoot 'tools\cc-switch'
    $runtimeRoot = Join-Path $projectRoot 'tools\webview2'

    try { $packageStatus = Get-CcSwitchIsolatedPackageSelection -StickRoot $UsbRoot }
    catch { [void]$reasons.Add('Official CC Switch package verification failed.') }
    if (-not $packageStatus -or -not $packageStatus.ArchiveVerified -or -not $packageStatus.ExtractedFilesVerified) {
        [void]$reasons.Add('The pinned official CC Switch package or extracted executable did not pass verification.')
    }

    $manifestPath = Join-Path $runtimeRoot 'runtime-manifest.json'
    $runtimeArchive = $null
    $manifestValid = $false
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            if ((Get-Item -LiteralPath $manifestPath -Force).Length -gt 65536) { throw 'manifest too large' }
            $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$manifest.version -cne '153.0.4234.48' -or [string]$manifest.architecture -cne 'x64' -or
                [string]$manifest.archive -cne 'Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64.cab' -or
                [string]$manifest.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
                [string]$manifest.sourceUrl -notmatch '^https://(developer\.microsoft\.com|www\.microsoft\.com|learn\.microsoft\.com|msedge\.sf\.dl\.delivery\.mp\.microsoft\.com)/') { throw 'manifest values invalid' }
            $runtimeArchive = Join-Path $runtimeRoot ([string]$manifest.archive)
            if (-not (Test-Path -LiteralPath $runtimeArchive -PathType Leaf)) { throw 'runtime CAB missing' }
            if ((Get-Item -LiteralPath $runtimeArchive -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'runtime CAB is a reparse point' }
            $actual = (Get-FileHash -LiteralPath $runtimeArchive -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not [string]::Equals($actual, [string]$manifest.sha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'runtime CAB hash mismatch' }
            $manifestValid = $true
        } catch { [void]$reasons.Add('The fixed WebView2 runtime manifest or CAB failed validation.') }
    } else { [void]$reasons.Add('The fixed WebView2 runtime manifest is missing.') }

    foreach ($required in @($storeScript,$checkpointScript,$contextScript,$probeScript)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -le 0) {
            [void]$reasons.Add(('Required isolation component is missing: ' + [IO.Path]::GetFileName($required)))
        }
    }
    if ((Test-Path -LiteralPath $storeScript -PathType Leaf) -and (Get-Item -LiteralPath $storeScript).Length -gt 0) {
        try {
            . $storeScript
            $storeStatus = Get-CcEncryptedStoreStatus -StickRoot $UsbRoot
        } catch { [void]$reasons.Add('USB profile store is unavailable or requires recovery.') }
    }
    if ($storeStatus -and $storeStatus.State -eq 'Corrupt') { [void]$reasons.Add('USB encrypted store requires recovery before launch.') }
    if ($storeStatus -and $storeStatus.State -eq 'RecoveryRequired') { [void]$reasons.Add('USB encrypted store has an incomplete transaction and needs explicit recovery.') }

    $python = Join-Path $projectRoot 'runtime\python\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { [void]$reasons.Add('The bundled trusted checkpoint Python runtime is missing.') }
    $runtimeDir = Join-Path $runtimeRoot 'verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    $runtimeExe = Join-Path $runtimeDir 'msedgewebview2.exe'
    $runtimeReady = $false
    $runtimeFilesManifest = Join-Path $runtimeRoot 'runtime-files.json'
    if (-not (Test-Path -LiteralPath $runtimeFilesManifest -PathType Leaf)) { [void]$reasons.Add('The fixed runtime extracted-file hash manifest is missing.') }
    if ($manifestValid -and (Test-Path -LiteralPath $runtimeFilesManifest -PathType Leaf) -and (Test-Path -LiteralPath $runtimeExe -PathType Leaf)) {
        try {
            $fileMap = [IO.File]::ReadAllText($runtimeFilesManifest,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$fileMap.version -cne '153.0.4234.48' -or [string]$fileMap.root -cne 'verified-runtime/Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64' -or
                -not $fileMap.Files -or $fileMap.Files.Count -lt 1 -or $fileMap.Files.Count -gt 10000) { throw 'runtime files manifest invalid' }
            $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($record in @($fileMap.Files)) {
                $relative = [string]$record.Path
                if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$|:)' -or $relative.Contains(':') -or [string]$record.Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'runtime file manifest entry invalid' }
                if (-not $expectedFiles.Add($relative.Replace('/','\'))) { throw 'runtime file manifest contains duplicate paths' }
                $candidate = [IO.Path]::GetFullPath((Join-Path $runtimeDir $relative))
                $prefix = $runtimeDir.TrimEnd('\') + '\'
                if (-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'runtime manifest file missing or escaped' }
                if ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'runtime file is a reparse point' }
                if ($record.PSObject.Properties['length'] -and (Get-Item -LiteralPath $candidate).Length -ne [long]$record.length) { throw 'runtime file length mismatch' }
                if (-not [string]::Equals((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash,[string]$record.Sha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'runtime file hash mismatch' }
            }
            $actualFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($relative in (Get-IsolatedFileInventory -Root $runtimeDir)) { [void]$actualFiles.Add($relative) }
            if ($actualFiles.Count -ne $expectedFiles.Count -or -not $expectedFiles.SetEquals($actualFiles)) { throw 'runtime extracted tree differs from its file manifest' }
            $sig = Get-AuthenticodeSignature -LiteralPath $runtimeExe
            $item = Get-Item -LiteralPath $runtimeExe
            $runtimeReady = ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Microsoft' -and
                ([string]$item.VersionInfo.ProductVersion -like '153.0.4234.48*' -or [string]$item.VersionInfo.FileVersion -like '153.0.4234.48*'))
        } catch { $runtimeReady = $false; [void]$reasons.Add(('Fixed runtime validation could not complete: ' + $_.Exception.Message)) }
    }
    if (-not $runtimeReady) { [void]$reasons.Add('The fixed WebView2 runtime has not been safely extracted and verified; host runtime fallback is disabled.') }

    $ready = ($reasons.Count -eq 0)
    return [pscustomobject]@{
        Status = if ($ready) { if ($storeStatus.State -eq 'Locked') { 'Ready' } else { 'ReadyFirstUse' } } else { 'StatusBlocked' }
        LaunchAllowed = [bool]$ready
        PackageVerified = [bool]($packageStatus -and $packageStatus.ArchiveVerified -and $packageStatus.ExtractedFilesVerified)
        FixedRuntimeVerified = [bool]$runtimeReady
        StoreStatus = if ($storeStatus) { [string]$storeStatus.State } else { 'Unavailable' }
        Isolation = 'AppContainer; real token, SID and requested network capability are checked before process resume'
        Network = if ($NetworkMode -eq 'InternetClient') { 'InternetClient requested; endpoint connectivity depends on this computer' } else { 'Disabled' }
        Reasons = [string[]]$reasons.ToArray()
    }
}

if ($Action -eq 'Status') {
    Get-IsolatedStatus -UsbRoot $StickRoot
    return
}

$preflight = Get-IsolatedStatus -UsbRoot $StickRoot
if (-not $preflight.LaunchAllowed) {
    throw ('Launch is blocked: ' + ($preflight.Reasons -join ' '))
}

function Assert-IsolatedPlainTree {
    param([string]$Path,[string]$Boundary)
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Boundary).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($full.TrimEnd('\'),$base.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'A path escaped its managed boundary.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A reparse point is not allowed in a managed tree.' }
    if ($item.PSIsContainer) {
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($full,'*',[IO.SearchOption]::TopDirectoryOnly)) { Assert-IsolatedPlainTree -Path $child -Boundary $Boundary }
    }
}

function Remove-IsolatedOwnedRoot {
    param([string]$Root)
    if (-not $Root) { return }
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::Equals((Split-Path -Parent $full),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notmatch '^aistick-ac-probe-[0-9a-f]{32}$') { throw 'Refusing to remove a path that is not this invocation unique owned root.' }
    Assert-IsolatedPlainTree -Path $full -Boundary $temp
    $marker = Join-Path $full '.aistick-ac-probe'
    if ([IO.File]::ReadAllText($marker).Trim() -cne 'aistick appcontainer workspace v1') { throw 'Owned root marker changed; leaving local data for inspection.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Remove-IsolatedCheckpointClone {
    param([string]$Path,[string]$TrustedParent)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Path]::GetFullPath($TrustedParent).TrimEnd('\')
    if (-not [string]::Equals((Split-Path -Parent $full),$parent,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notmatch '^snapshot-[0-9a-f]{32}$') { throw 'Refusing to remove a non-owned checkpoint clone.' }
    Assert-IsolatedPlainTree -Path $full -Boundary $parent
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Remove-IsolatedTrustedParent {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::Equals((Split-Path -Parent $full),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $full) -notmatch '^aistick-cc-switch-checkpoints-[0-9a-f]{32}$') { throw 'Refusing to remove a non-owned checkpoint parent.' }
    Assert-IsolatedPlainTree -Path $full -Boundary $temp
    $sessionId=(Split-Path -Leaf $full).Substring('aistick-cc-switch-checkpoints-'.Length)
    $marker=Join-Path $full '.aistick-cc-switch-checkpoints'
    if(-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker).Trim() -cne $sessionId){throw 'Checkpoint parent marker did not match its exact session identity.'}
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function New-IsolatedCheckpoint {
    param([string]$SourceRoot,[string]$UsbRoot,[string]$PythonExe,[string]$TrustedParent,$ExpectedVolume,[switch]$Save)
    $clone = Join-Path $TrustedParent ('snapshot-' + [guid]::NewGuid().ToString('N'))
    $result = New-CcSwitchOnlineCheckpoint -SourceRoot $SourceRoot -DestinationRoot $clone -PythonExe $PythonExe -TimeoutSeconds 5
    if (-not $result -or $result.Status -cne 'Complete' -or -not $result.FileStabilityVerified -or $result.MultiFileConsistencyGuaranteed) {
        throw 'The trusted checkpoint did not satisfy the required integrity contract.'
    }
    if ($Save) {
        if (-not (Test-StickPresent -Expected $ExpectedVolume)) { throw 'USB volume was removed or replaced before snapshot save.' }
        $saved = Save-CcEncryptedSnapshot -Session $storeSession -SourceRoot $clone -StoppedOnly
        if ($SessionControl) { $SessionControl.LastSaveUtc=[DateTime]::UtcNow.ToString('o') }
        if (-not (Test-StickPresent -Expected $ExpectedVolume)) { throw 'USB volume was removed or replaced during snapshot save.' }
    }
    return $clone
}

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-checkpoint.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')

$usbRoot = [IO.Path]::GetFullPath($StickRoot)
$activePackage = Get-CcSwitchIsolatedPackageSelection -StickRoot $usbRoot
$portableUpdaterLaunch = $null # Assigned after verified package/fixture validation and owned shim startup below.
$portableUpdateCandidate = $null
$portableUpdateExitEligible = $false
$portableUpdateOutcome = [pscustomobject]@{Activated=$false;Status='NoPreparedUpdate';Version=$null}
$root = $null
$state = $null
$writerLock = $null
$trustedParent = $null
$storeSession = $null
$ownsStoreSession = $true
$lastCheckpoint = [DateTime]::UtcNow
$savedAtLeastOnce = $false
$normalExit = $false
$failure = $null
$removeLocalAfterUnplug = $false
$removeLocalAfterRecovery = $false
$recoveryRoot = $null
$recoverySaved = $false
$metadataPath = $null
$metadata = $null
$stick = $null
$pythonExe = Join-Path $projectRoot 'runtime\python\python.exe'
$expectedVolume = Get-VolumeIdentity -StickRoot $usbRoot
try {
    if (-not (Test-Path -LiteralPath $usbRoot -PathType Container)) { throw 'USB StickRoot is unavailable.' }
    if ($EncryptedSession) {
        if ($EncryptedSession.Locked -or -not $EncryptedSession.DataKey) { throw 'Passed secure session is locked.' }
        $storeSession = $EncryptedSession
        $ownsStoreSession = $false
    } else {
        $encryptedStatus = Get-CcEncryptedStoreStatus -StickRoot $usbRoot
        if ($encryptedStatus.State -eq 'RecoveryRequired' -or $encryptedStatus.State -eq 'Corrupt') { throw 'Encrypted store requires explicit recovery before launch.' }
        $createStore = ($encryptedStatus.State -eq 'Absent')
        $masterPassword = Read-Host $(if ($createStore) { '首次设置 U 盘主密码' } else { '输入 U 盘配置主密码' }) -AsSecureString
        try {
            if ($createStore) {
                $passwordAgain = Read-Host '再次输入主密码确认' -AsSecureString
                try {
                    $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($masterPassword)
                    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordAgain)
                    try { if (-not [string]::Equals([Runtime.InteropServices.Marshal]::PtrToStringBSTR($a),[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b),[StringComparison]::Ordinal)) { throw '两次密码不一致。' } }
                    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
                } finally { $passwordAgain.Dispose() }
            }
            $storeSession = Open-CcEncryptedStoreSession -StickRoot $usbRoot -Password $masterPassword -Create:$createStore
        } finally { $masterPassword.Dispose() }
        $migrationModule = Join-Path $PSScriptRoot 'cc-switch-migration.ps1'
        if (Test-Path -LiteralPath $migrationModule -PathType Leaf) { . $migrationModule; $null = Initialize-CcEncryptedStoreFromLegacy -StickRoot $usbRoot -Session $storeSession }
    }

    $root = New-AppContainerProbeFixtureRoot
    $marker = Join-Path $root '.aistick-ac-probe'
    [IO.File]::WriteAllText($marker,'aistick appcontainer workspace v1',(New-Object Text.UTF8Encoding($false)))
    $guardianSource = Join-Path $PSScriptRoot 'cc-switch-session-guardian.ps1'
    if (-not (Test-Path -LiteralPath $guardianSource -PathType Leaf)) { throw 'Independent secure-session guardian is missing.' }
    $metadataDir = Join-Path $env:LOCALAPPDATA 'AiStick\SecureSessions'
    [IO.Directory]::CreateDirectory($metadataDir) | Out-Null
    $metadataDirAcl=New-Object System.Security.AccessControl.DirectorySecurity;$metadataDirAcl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){[void]$metadataDirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
    [IO.Directory]::SetAccessControl($metadataDir,$metadataDirAcl)
    $sessionId=[IO.Path]::GetFileName($root).Substring('aistick-ac-probe-'.Length)
    $metadataPath=Join-Path $metadataDir ($sessionId+'.json')
    $guardianCopy=Join-Path $metadataDir ('cc-switch-session-guardian-'+$sessionId+'.ps1')
    if([IO.File]::Exists($metadataPath) -or [IO.File]::Exists($guardianCopy)){throw 'Secure guardian metadata identity already exists.'}
    Copy-Item -LiteralPath $guardianSource -Destination $guardianCopy -ErrorAction Stop
    $guardianFileAcl=New-Object System.Security.AccessControl.FileSecurity;$guardianFileAcl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){[void]$guardianFileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','None','None','Allow')))}
    [IO.File]::SetAccessControl($guardianCopy,$guardianFileAcl)
    $trustedCheckpointRoot=Join-Path ([IO.Path]::GetTempPath()) ('aistick-cc-switch-checkpoints-'+$sessionId)
    $metadata=[ordered]@{Version=1;SessionId=$sessionId;State='Planned';StickRoot=$usbRoot;OwnedRoot=$root;TempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');DriveLetter=[string]$expectedVolume.DriveLetter;VolumeGuid=[string]$expectedVolume.VolumeGuid;Serial=[string]$expectedVolume.Serial;OwnerPid=$PID;OwnerStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;ProfileName=$null;AppContainerSid=$null;OriginalAccessSddl=$null;AppExePath=(Join-Path $root 'app\cc-switch.exe');RuntimeRoot=(Join-Path $root 'runtime');TrustedCheckpointRoot=$trustedCheckpointRoot;ProcessId=$null;ProcessStartTicks=$null}
    Set-CcSwitchGuardianMetadata -Path $metadataPath -Record $metadata
    $guardianArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$guardianCopy,'-MetadataPath',$metadataPath,'-GuardianCopy',$guardianCopy)
    $guardianQuoted = @($guardianArgs | ForEach-Object { Quote-AppContainerArgument ([string]$_) })
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $guardianQuoted -PassThru -WindowStyle Hidden -ErrorAction Stop | Out-Null
    $appDir = Join-Path $root 'app'
    $stick = Join-Path $root 'stick'
    $runtime = Join-Path $root 'runtime'
    $browser = Join-Path $runtime 'browser'
    $session = Join-Path $runtime 'session'
    foreach ($dir in @($appDir,$stick,$runtime,$browser,$session)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }

    $packageApp = [string]$activePackage.AppDirectory
    $sourceExe = Join-Path $packageApp 'cc-switch.exe'
    $sourceIni = Join-Path $packageApp 'portable.ini'
    Copy-Item -LiteralPath $sourceExe -Destination (Join-Path $appDir 'cc-switch.exe') -ErrorAction Stop
    Copy-Item -LiteralPath $sourceIni -Destination (Join-Path $appDir 'portable.ini') -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $appDir 'cc-switch.exe') -Algorithm SHA256).Hash) { throw 'Verified application copy did not match its source hash.' }
    if ((Get-FileHash -LiteralPath $sourceIni -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $appDir 'portable.ini') -Algorithm SHA256).Hash) { throw 'Verified portable application settings copy did not match its source hash.' }
    $packageAfterCopy = Get-CcSwitchIsolatedPackageSelection -StickRoot $usbRoot
    if (-not [string]::Equals([string]$packageAfterCopy.Version,[string]$activePackage.Version,[StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$packageAfterCopy.AppDirectory,[string]$activePackage.AppDirectory,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-FileHash -LiteralPath (Join-Path $appDir 'cc-switch.exe') -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-FileHash -LiteralPath (Join-Path $appDir 'portable.ini') -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $sourceIni -Algorithm SHA256).Hash,[StringComparison]::OrdinalIgnoreCase)) { throw 'Selected verified CC Switch package changed during the temporary copy.' }

    $runtimeSource = Join-Path $projectRoot 'tools\webview2\verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    $runtimeFileMap = [IO.File]::ReadAllText((Join-Path $projectRoot 'tools\webview2\runtime-files.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $sourceInventory = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in (Get-IsolatedFileInventory -Root $runtimeSource)) { [void]$sourceInventory.Add($relative) }
    if ($sourceInventory.Count -ne $runtimeFileMap.Files.Count) { throw 'Fixed runtime tree changed after preflight.' }
    foreach ($record in @($runtimeFileMap.Files)) {
        $relative = [string]$record.Path
        $src = [IO.Path]::GetFullPath((Join-Path $runtimeSource $relative))
        $dest = [IO.Path]::GetFullPath((Join-Path $browser $relative))
        if (-not $src.StartsWith(([IO.Path]::GetFullPath($runtimeSource).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or
            -not $dest.StartsWith(([IO.Path]::GetFullPath($browser).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime manifest path escaped its fixed root.' }
        $srcItem = Get-Item -LiteralPath $src -Force -ErrorAction Stop
        if ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint -or $srcItem.Length -ne [long]$record.length -or
            -not [string]::Equals((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash,[string]$record.sha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'A fixed runtime file failed trusted manifest verification.' }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        [IO.File]::Copy($src,$dest,$false)
        if (-not [string]::Equals((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash,[string]$record.sha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'A copied runtime file failed verification.' }
    }
    $browserExe = Join-Path $browser 'msedgewebview2.exe'
    $browserSignature = Get-AuthenticodeSignature -LiteralPath $browserExe
    if ($browserSignature.Status -ne 'Valid' -or $browserSignature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'The isolated fixed runtime signature check failed.' }

    if (-not (Test-StickPresent -Expected $expectedVolume)) { throw 'USB volume was removed before encrypted restore.' }
    if ($storeSession.Revision) { [void](Restore-CcEncryptedSnapshot -Session $storeSession -DestinationRoot $stick -StoppedOnly) }
    $managedOwner = Initialize-CcSwitchIsolatedManagedHarness -UsbRoot $usbRoot -OwnedRoot $root -StickRoot $stick -SessionRoot $session -RuntimeRoot $runtime
    $envMap = $managedOwner.Environment
    $envMap['WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'] = $browser
    $fixture = New-CcSwitchIsolatedFixtureRecord -Root $root -Exe (Join-Path $appDir 'cc-switch.exe') -StickRoot $stick -RuntimeRoot $runtime -ManagedHarnessRoot $managedOwner.ManagedSession.ManagedHarnessRoot -Environment $envMap -Arguments @()
    $fixturePath = Join-Path $root 'fixture.json'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $fixtureObject = Read-AppContainerFixture -Path $fixturePath
    $portableUpdaterLaunch = Start-CcSwitchIsolatedNativeUpdateOwner -Fixture $fixtureObject -Package $activePackage -NetworkMode $NetworkMode
    $state = $portableUpdaterLaunch.State
    $metadata.State='Running'
    $metadata.ProfileName=[string]$state.ProfileName
    $metadata.AppContainerSid=[string]$state.AppContainerSid
    $metadata.OriginalAccessSddl=[string]$state.OriginalAccessSddl
    if($state.ProcessId){
        if(-not $state.ProcessStartTicks -or [long]$state.ProcessStartTicks -le 0){throw 'Owned AppContainer process start time from its process handle is missing or invalid.'}
        $metadata.ProcessId=[int]$state.ProcessId
        $metadata.ProcessStartTicks=[long]$state.ProcessStartTicks
    }
    Set-CcSwitchGuardianMetadata -Path $metadataPath -Record $metadata
    Write-Host $(if ($NetworkMode -eq 'InternetClient') { '独立联网窗口已打开；可检测供应商连通性，原生代理尚未接通。' } else { '独立离线窗口已打开；本机版可同时使用，可管理本盘配置。' })

    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $trustedParent = $trustedCheckpointRoot
    [IO.Directory]::CreateDirectory($trustedParent) | Out-Null
    [IO.File]::WriteAllText((Join-Path $trustedParent '.aistick-cc-switch-checkpoints'),$sessionId,(New-Object Text.UTF8Encoding($false)))
    $trustedAcl = New-Object System.Security.AccessControl.DirectorySecurity
    $trustedAcl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        [void]$trustedAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    [IO.Directory]::SetAccessControl($trustedParent,$trustedAcl)

    while ($true) {
        $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 1
        if (-not (Test-StickPresent -Expected $expectedVolume)) { $failure = 'USB volume removed or replaced; the AppContainer Job will be terminated and no final save will be attempted.'; $removeLocalAfterUnplug = $true; break }
        $stopRequested = [bool]($SessionControl -and $SessionControl.StopRequested)
        if ($portableUpdaterLaunch -and (Test-CcSwitchNativeUpdateNetworkAllowed -NetworkMode $NetworkMode) -and -not $wait.Completed -and -not $stopRequested) {
            $checkpointForUpdate = {
                $clone = New-IsolatedCheckpoint -SourceRoot $stick -UsbRoot $usbRoot -PythonExe $pythonExe -TrustedParent $trustedParent -ExpectedVolume $expectedVolume -Save
                Remove-IsolatedCheckpointClone -Path $clone -TrustedParent $trustedParent
                $lastCheckpoint = [DateTime]::UtcNow
            }
            $updateRequest = Invoke-CcSwitchPortableUpdateOwnerRequest -Launch $portableUpdaterLaunch -StickRoot $usbRoot -CurrentVersion ([string]$portableUpdaterLaunch.PackageVersion) -ExpectedVolume $expectedVolume -CheckpointAction $checkpointForUpdate -SessionControl $SessionControl
            if ($updateRequest.FatalVolumeChange) { $failure='U盘在处理更新请求期间移除或被替换；隔离 Job 将终止且不会继续写入。';$removeLocalAfterUnplug=$true;break }
            if ($updateRequest.Candidate) {
                if($portableUpdateCandidate -and [string]$portableUpdateCandidate.CandidateId -cne [string]$updateRequest.Candidate.CandidateId){try{Discard-CcPortableUpdateCandidate -Candidate $portableUpdateCandidate -Confirm:$false|Out-Null}catch{}}
                $portableUpdateCandidate=$updateRequest.Candidate
            }
        }
        if ($stopRequested) { $normalExit = $true; $portableUpdateExitEligible = $true; break }
        if ($wait.Completed) { $normalExit = $true; break }
        if ((([DateTime]::UtcNow - $lastCheckpoint).TotalSeconds) -ge 15) {
            try {
                $clone = New-IsolatedCheckpoint -SourceRoot $stick -UsbRoot $usbRoot -PythonExe $pythonExe -TrustedParent $trustedParent -ExpectedVolume $expectedVolume -Save
                $lastCheckpoint = [DateTime]::UtcNow
                Remove-IsolatedCheckpointClone -Path $clone -TrustedParent $trustedParent
                Write-Host ('USB加密快照已保存：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            } catch {
                $lastCheckpoint = [DateTime]::UtcNow
                if (-not (Test-StickPresent -Expected $expectedVolume)) { $failure='U盘在加密快照期间移除；隔离 Job 将终止且不会写回U盘。';$removeLocalAfterUnplug=$true;break }
                $failure='加密快照未能提交；最后一次成功的密文代保留，本次本机恢复数据将尝试加密保留。'
                break
            }
        }
    }
    if ($failure) { throw $failure }
    if ($normalExit) {
        $completedGuiState = $state
        Complete-AppContainerProbeProcess -State $state
        $state = $null
        if (-not (Test-StickPresent -Expected $expectedVolume)) { throw 'USB volume was removed before stopped snapshot.' }
        $saveResult = Save-CcEncryptedSnapshot -Session $storeSession -SourceRoot $stick -StoppedOnly
        if (-not (Test-StickPresent -Expected $expectedVolume)) { throw 'USB volume was removed after stopped snapshot.' }
        $savedAtLeastOnce = $true
        if ($SessionControl) { $SessionControl.LastSaveUtc=[DateTime]::UtcNow.ToString('o') }
        $managedClaudeSave = Save-CcSwitchIsolatedManagedHarness -ManagedSession $managedOwner.ManagedSession -UsbRoot $usbRoot -ExpectedVolume $expectedVolume -AllowOnlineVerification:([bool](Test-CcSwitchNativeUpdateNetworkAllowed -NetworkMode $NetworkMode))
        if($portableUpdaterLaunch -and $wait -and $wait.Completed -and $null -ne $wait.ExitCode -and [int64]$wait.ExitCode -eq 0){$portableUpdateExitEligible=$true}
        $portableUpdateOutcome = Complete-CcSwitchPortableUpdateOwnerSession -Candidate $portableUpdateCandidate -AllowActivation ([bool]$portableUpdateExitEligible) -CompletedGuiState $completedGuiState -EncryptedSession $storeSession -SaveResult $saveResult -StickRoot $usbRoot -ExpectedVolume $expectedVolume -SessionControl $SessionControl
        $portableUpdateCandidate=$null
        Write-Host 'CC Switch已正常退出，停止后加密快照已保存；本次本机临时数据正在清理。'
        [IO.File]::WriteAllText((Join-Path $root '.session-outcome'),'complete',(New-Object Text.UTF8Encoding($false)))
        Write-Output ([pscustomobject]@{ Status='ExitedAndSaved'; ExitCode=$wait.ExitCode; EncryptedRevision=$saveResult.Revision; ClaudePackageVersion=[string]$managedClaudeSave.Version; ClaudePackageSlotSaved=[bool]$managedClaudeSave.Saved; PortableUpdateStatus=[string]$portableUpdateOutcome.Status; PortableUpdateVersion=[string]$portableUpdateOutcome.Version; CheckpointPolicy='Stopped encrypted snapshot'; Network=$NetworkMode })
    }
} catch {
    $failure = $_.Exception.Message
    if ($expectedVolume -and (Get-IsolatedUnplugCleanupDecision -VolumePresent ([bool](Test-StickPresent -Expected $expectedVolume)))) {
        $removeLocalAfterUnplug = $true
    }
    if ($state) {
        try { Complete-AppContainerProbeProcess -State $state; $state = $null } catch { $failure += ' AppContainer cleanup is incomplete; owned root retained.' }
    }
    if (-not $removeLocalAfterUnplug -and -not $state -and $storeSession -and $stick -and (Test-Path -LiteralPath $stick -PathType Container)) {
        try {
            $recoveryParent=Join-Path $env:LOCALAPPDATA 'AiStick\Recovery'
            [IO.Directory]::CreateDirectory($recoveryParent) | Out-Null
            $recoveryRoot=Join-Path $recoveryParent ('cc-switch-'+[guid]::NewGuid().ToString('N'))
            $null=Save-CcEncryptedRecoverySnapshot -Session $storeSession -SourceRoot $stick -DestinationRoot $recoveryRoot -StoppedOnly
            $recoverySaved=$true;$removeLocalAfterRecovery=$true
            $failure += (' Encrypted recovery package saved locally: ' + $recoveryRoot)
        } catch { $failure += ' Local encrypted recovery also failed; sensitive local root was retained and requires manual recovery.' }
    }
    Write-Error -Message ('Isolated CC Switch session failed safely: ' + $failure)
} finally {
    if($portableUpdateCandidate){try{Discard-CcPortableUpdateCandidate -Candidate $portableUpdateCandidate -Confirm:$false|Out-Null}catch{}}
    if ($root -and $removeLocalAfterUnplug -and (Test-Path -LiteralPath $root -PathType Container)) { try { [IO.File]::WriteAllText((Join-Path $root '.session-outcome'),'unplug-cleanup',(New-Object Text.UTF8Encoding($false))) } catch { } }
    if ($storeSession -and $ownsStoreSession) { try { Close-CcEncryptedStoreSession -Session $storeSession } catch { } }
    if ($writerLock) { try { $writerLock.Dispose() } catch { } }
    if ($trustedParent -and (Test-Path -LiteralPath $trustedParent -PathType Container)) {
        try { Remove-IsolatedTrustedParent -Path $trustedParent } catch { Write-Warning 'Trusted checkpoint cleanup failed; retained for inspection.' }
    }
    $rootRemoved=$false
    if ($root -and -not $state -and (-not $failure -or $removeLocalAfterUnplug -or $removeLocalAfterRecovery)) {
        try {
            Remove-IsolatedOwnedRoot -Root $root
            $rootRemoved=$true
            if ($removeLocalAfterUnplug) { Write-Warning 'U盘已拔出，本次临时目录已清理；未执行USB写回。' }
            elseif($recoverySaved){Write-Warning ('保存失败的明文工作区已清理；同密码加密的本机恢复包为：'+$recoveryRoot)}
        } catch { Write-Warning ('本机临时目录清理未完成，保留路径：' + $root) }
    } elseif ($root -and $failure) {
        Write-Warning ('保存未确认或进程清理未完成，本次恢复数据保留在：' + $root)
    }
    if($metadataPath -and $metadata -and $metadata.State -eq 'Running'){
        $checkpointRemoved=(-not $trustedParent -or -not (Test-Path -LiteralPath $trustedParent -PathType Container))
        if($rootRemoved -and $checkpointRemoved -and (-not $failure -or $removeLocalAfterUnplug -or $removeLocalAfterRecovery)){
            $metadata.State='Complete';Set-CcSwitchGuardianMetadata -Path $metadataPath -Record $metadata
        }elseif($failure -and -not $removeLocalAfterUnplug -and -not $state -and $root -and (Test-Path -LiteralPath $root -PathType Container) -and -not $rootRemoved){
            $metadata.State='Preserve';Set-CcSwitchGuardianMetadata -Path $metadataPath -Record $metadata
        }
    }
    if ($SessionControl) {
        $cleanupComplete = ((-not $root -or -not (Test-Path -LiteralPath $root)) -and (-not $trustedParent -or -not (Test-Path -LiteralPath $trustedParent)))
        $SessionControl.CleanupComplete = $cleanupComplete
        $SessionControl.Saved = [bool]($normalExit -and $savedAtLeastOnce -and -not $failure -and $cleanupComplete)
        if (-not $failure -and -not $cleanupComplete) { throw ('Encrypted configuration was saved, but local cleanup is incomplete. Retained session root: ' + $root) }
    }
}

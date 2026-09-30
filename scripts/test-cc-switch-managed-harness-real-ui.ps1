[CmdletBinding()]
param(
    [string]$UsbRoot = 'E:\',
    [ValidateSet('None','InternetClient')][string]$NetworkMode = 'InternetClient',
    [ValidateRange(1,180)][int]$MaximumWaitMinutes = 45,
    [ValidateRange(15,600)][int]$ChildExitWaitSeconds = 120,
    [switch]$ProgressWriterTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-portable-updater.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-isolated-managed-owner.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-native-update-session.ps1')

if ($NetworkMode -ne 'InternetClient') { throw 'The real managed-harness update test requires InternetClient.' }
$usb = [IO.Path]::GetFullPath($UsbRoot)
$package = Get-CcSwitchIsolatedPackageSelection -StickRoot $usb
$expectedVolume = Get-CcSwitchHarnessVolumeIdentity -Path $usb
$root = New-AppContainerProbeFixtureRoot
$guidText = (Split-Path -Leaf $root).Substring('aistick-ac-probe-'.Length)
$runtime = Join-Path $root 'runtime'
$stick = Join-Path $root 'stick'
$session = Join-Path $runtime 'session'
$harness = Join-Path $root 'harness'
$app = Join-Path $root 'app'
$browser = Join-Path $root 'browser'
$fixturePath = Join-Path $root 'fixture.json'
$progressPath = Join-Path $root 'managed-harness-update-status.json'
$stopPath = Join-Path $root '.stop-managed-harness-real-ui'
$state = $null
$nativeUpdateSession = $null
$managedOwner = $null
$initialVersion = $null
$finalVersion = $null
$initialExeVersion = $null
$finalExeVersion = $null
$savedSlot = $null
$saveError = $null
$normalExit = $false
$retained = $false
$processExitCode = $null
$abortReason = $null

function Copy-PlainManagedUiTree {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)
    $sourceFull = [IO.Path]::GetFullPath($Source)
    if (-not [IO.Directory]::Exists($sourceFull)) { throw 'A required trusted fixture source directory is missing.' }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($sourceFull,'*',[IO.SearchOption]::TopDirectoryOnly)) {
        $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A trusted fixture source contains a reparse point.' }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-PlainManagedUiTree -Source $entry -Destination $target }
        else { [IO.File]::Copy($entry,$target,$false) }
    }
}

function Assert-RealManagedUiFixtureTree {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push([IO.Path]::GetFullPath($Path))
    while ($stack.Count) {
        $current = $stack.Pop()
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing fixture cleanup because a reparse point appeared.' }
        if ($item.PSIsContainer) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current,'*',[IO.SearchOption]::TopDirectoryOnly)) { $stack.Push($child) }
        }
    }
}

function Test-RealManagedUiUsbPresent {
    try {
        $actual = Get-CcSwitchHarnessVolumeIdentity -Path $usb
        return (Test-CcSwitchHarnessVolumeIdentity -Expected $expectedVolume -Actual $actual)
    } catch { return $false }
}

function Get-RealManagedUiFileInventory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $base = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $files = New-Object 'System.Collections.Generic.List[string]'
    $pending.Push($base)
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory,'*',[IO.SearchOption]::TopDirectoryOnly)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Pinned WebView source tree contains a reparse point.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else {
                $files.Add($item.FullName.Substring($base.Length + 1))
                if ($files.Count -gt 10000) { throw 'Pinned WebView runtime exceeds its file-count bound.' }
            }
        }
    }
    return ,$files.ToArray()
}

function Get-RealManagedUiClaudeExeVersion {
    param([Parameter(Mandatory=$true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Claude executable version source is a reparse point.' }
    $info = $item.VersionInfo
    $value = [string]$info.ProductVersion
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [string]$info.FileVersion }
    return $value
}

function Get-RealManagedUiCmdExeTarget {
    param([Parameter(Mandatory=$true)][string]$SlotPath,[Parameter(Mandatory=$true)][string]$ExpectedExecutable)
    $slot = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\','/')
    $cmd = Join-Path $slot 'claude.cmd'
    $item = Get-Item -LiteralPath $cmd -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536) { throw 'Claude command shim is a reparse point or exceeds its bounded size.' }
    $text = [IO.File]::ReadAllText($cmd,[Text.Encoding]::ASCII)
    $matches = [regex]::Matches($text,'(?im)^\s*"%dp0%\\(?<relative>[^"\r\n]+\.exe)"\s+%\*\s*$')
    if ($matches.Count -ne 1) { throw 'Claude command shim does not contain exactly one recognized relative executable target.' }
    $relative = [string]$matches[0].Groups['relative'].Value
    if ($relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative.StartsWith('\') -or $relative -match '^[A-Za-z]:') { throw 'Claude command shim executable target is not a relative path.' }
    $target = [IO.Path]::GetFullPath((Join-Path $slot $relative))
    if (-not $target.StartsWith(($slot+'\'),[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($target,[IO.Path]::GetFullPath($ExpectedExecutable),[StringComparison]::OrdinalIgnoreCase)) { throw 'Claude command shim does not target the validated platform executable.' }
    $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-CcSwitchManagedClaudePeFile -Path $target)) { throw 'Claude command shim target is not a plain validated Windows executable.' }
    return $target
}

function Write-RealManagedUiSummary {
    param([string]$Status,[string]$Message)
    [pscustomobject]@{
        Status = $Status
        Message = $Message
        FixtureRoot = $root
        ProcessId = if ($state) { [int]$state.ProcessId } else { $null }
        ProcessExitCode = $processExitCode
        NetworkMode = $NetworkMode
        CcSwitchVersion = $package.Version
        InitialClaudeVersion = $initialVersion
        FinalClaudeVersion = $finalVersion
        InitialClaudeExeVersion = $initialExeVersion
        FinalClaudeExeVersion = $finalExeVersion
        VersionSlotSaved = [bool]$savedSlot
        SavedVersion = if ($savedSlot) { [string]$savedSlot.Version } else { $null }
        SavedPath = if ($savedSlot) { [string]$savedSlot.Path } else { $null }
        SaveError = $saveError
        StopFile = $stopPath
        ProvidersOrSecretsCopied = $false
        ModelRequestSent = $false
    }
}

function Write-RealManagedUiProgress {
    param([string]$Phase)
    $observedVersion = $null
    $manifestPath = Join-Path $harness ('slots\'+[string]$managedOwner.ManagedSession.SlotId+'\node_modules\@anthropic-ai\claude-code\package.json')
    try {
        $item = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 1048576) {
            $candidate = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$candidate.name -ceq '@anthropic-ai/claude-code' -and [string]$candidate.version -match '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { $observedVersion = [string]$candidate.version }
        }
    } catch { }
    $record = [ordered]@{
        Phase = $Phase
        FixtureRoot = $root
        ProcessId = if ($state) { [int]$state.ProcessId } else { $null }
        ProcessExitCode = $processExitCode
        CcSwitchVersion = $package.Version
        InitialClaudeVersion = $initialVersion
        CurrentlyObservedClaudeVersion = $observedVersion
        ManagedClaudeSlotPath = Join-Path $harness ('slots\'+[string]$managedOwner.ManagedSession.SlotId)
        StopFile = $stopPath
        NetworkMode = $NetworkMode
        ProvidersOrSecretsCopied = $false
        ModelRequestSent = $false
        UsbVersionSlotCommitted = [bool]$savedSlot
    }
    $text = ConvertTo-Json -InputObject $record -Depth 4
    $tempPath = $progressPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $progressPath + '.backup'
    try {
        if ([IO.File]::Exists($tempPath) -or [IO.Directory]::Exists($tempPath)) { throw 'Unique progress temp path is unexpectedly occupied.' }
        if ([IO.File]::Exists($progressPath)) {
            $target = Get-Item -LiteralPath $progressPath -Force -ErrorAction Stop
            if ($target.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Progress report path became a reparse point.' }
            if ([IO.File]::Exists($backupPath)) {
                $backupItem = Get-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                if ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Progress report backup became a reparse point.' }
                [IO.File]::Delete($backupPath)
            }
        }
        [IO.File]::WriteAllText($tempPath,$text,(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($progressPath)) {
            [IO.File]::Replace($tempPath,$progressPath,$backupPath)
            if ([IO.File]::Exists($backupPath)) {
                $backupItem = Get-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                if ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Progress backup unexpectedly became a reparse point.' }
                [IO.File]::Delete($backupPath)
            }
        } else { [IO.File]::Move($tempPath,$progressPath) }
    } catch { Write-Warning ('Non-critical progress report write failed: ' + $_.Exception.Message) }
    finally {
        if ([IO.File]::Exists($tempPath)) {
            try { $tempItem = Get-Item -LiteralPath $tempPath -Force -ErrorAction Stop; if (-not ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.File]::Delete($tempPath) } } catch { }
        }
    }
}

if ($ProgressWriterTest) {
    $managedOwner = [pscustomobject]@{ManagedSession=[pscustomobject]@{SlotId='2.1.281'}}
    $package = [pscustomobject]@{Version='v3.20.4'}
    $initialVersion = '2.1.281'
    $state = [pscustomobject]@{ProcessId=12345}
    $processExitCode = $null
    $savedSlot = $null
    $manifestDirectory = Join-Path $harness 'slots\2.1.281\node_modules\@anthropic-ai\claude-code'
    [IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $manifestDirectory 'package.json'),' {"name":"@anthropic-ai/claude-code","version":"2.1.281"} ',(New-Object Text.UTF8Encoding($false)))
    try {
        Write-RealManagedUiProgress -Phase 'First'
        Write-RealManagedUiProgress -Phase 'Second'
        Write-RealManagedUiProgress -Phase 'Third'
        $record = [IO.File]::ReadAllText($progressPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($record.Phase -cne 'Third' -or $record.CurrentlyObservedClaudeVersion -cne '2.1.281') { throw 'Progress writer readback did not return the latest state.' }
        if ([IO.File]::Exists($progressPath+'.backup') -or @(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -Force).Count) { throw 'Progress writer left a backup or temporary file.' }
        Write-Output 'PS5.1 progress writer: three consecutive updates and final readback passed.'
    } finally {
        Assert-RealManagedUiFixtureTree -Path $root
        $tempBoundary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))).TrimEnd('\','/') -ine $tempBoundary -or (Split-Path -Leaf $root) -cne ('aistick-ac-probe-'+$guidText)) { throw 'Refusing progress-test cleanup outside its unique temporary fixture.' }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }
    exit 0
}

try {
    foreach ($path in @($app,$browser,$runtime,$stick,$session,$harness)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    if (-not (Test-RealManagedUiUsbPresent)) { throw 'USB volume identity changed before managed harness initialization.' }
    [IO.File]::Copy((Join-Path $package.AppDirectory 'cc-switch.exe'),(Join-Path $app 'cc-switch.exe'),$false)
    [IO.File]::Copy((Join-Path $package.AppDirectory 'portable.ini'),(Join-Path $app 'portable.ini'),$false)

    $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $runtimeSource = Join-Path $projectRoot 'tools\webview2\verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    $runtimeMapPath = Join-Path $projectRoot 'tools\webview2\runtime-files.json'
    $runtimeMap = [IO.File]::ReadAllText($runtimeMapPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $sourceFiles = Get-RealManagedUiFileInventory -Path $runtimeSource
    if ($sourceFiles.Count -ne $runtimeMap.Files.Count) { throw 'Fixed WebView runtime inventory differs from its pinned manifest.' }
    $runtimeFileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $sourceFiles) { [void]$runtimeFileSet.Add([string]$relative) }
    foreach ($record in @($runtimeMap.Files)) {
        $relative = ([string]$record.Path).Replace('/','\')
        if (-not $runtimeFileSet.Contains($relative)) { throw 'Pinned WebView manifest file is missing from the trusted runtime source.' }
        $source = [IO.Path]::GetFullPath((Join-Path $runtimeSource $relative))
        $destination = [IO.Path]::GetFullPath((Join-Path $browser $relative))
        if (-not $source.StartsWith(([IO.Path]::GetFullPath($runtimeSource).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or
            -not $destination.StartsWith(([IO.Path]::GetFullPath($browser).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixed WebView runtime manifest escaped its fixture root.' }
        $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $sourceItem.Length -ne [long]$record.length -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine [string]$record.sha256) { throw 'A WebView runtime file failed pinned inventory validation.' }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::Copy($source,$destination,$false)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine [string]$record.sha256) { throw 'A copied WebView runtime file failed hash validation.' }
    }
    $browserExe = Join-Path $browser 'msedgewebview2.exe'
    $signature = Get-AuthenticodeSignature -LiteralPath $browserExe
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Copied fixed WebView runtime is not Microsoft-signed.' }

    $managedOwner = Initialize-CcSwitchIsolatedManagedHarness -UsbRoot $usb -OwnedRoot $root -StickRoot $stick -SessionRoot $session -RuntimeRoot $runtime
    $initialVersion = [string]$managedOwner.ManagedSession.PackageVersion
    $activeSlot = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId ([string]$managedOwner.ManagedSession.SlotId)
    if (-not $activeSlot.Valid -or $activeSlot.PackageVersion -cne $initialVersion) { throw 'Copied managed Claude package failed validation before launch.' }
    if (-not [IO.File]::Exists((Join-Path $activeSlot.SlotPath 'npm.cmd'))) { throw 'Temporary sibling npm adapter is missing before the real GUI test launch.' }
    $publicSlotPath = Join-Path $usb ('tools\harness\claude\slots\'+[string]$managedOwner.ManagedSession.SlotId)
    $immutablePublicSlot = [IO.Directory]::Exists($publicSlotPath)
    if (-not $immutablePublicSlot) { $publicSlotPath = Join-Path $usb 'npm-global' }
    if (-not [IO.Directory]::Exists($publicSlotPath)) { throw 'Original public Claude slot is missing for staged-copy verification.' }
    if ($immutablePublicSlot -and (Test-Path -LiteralPath (Join-Path $publicSlotPath 'npm.cmd'))) { throw 'Immutable public Claude slot already contains a temporary npm adapter.' }
    $publicInventory = Get-CcSwitchManagedHarnessTreeInventory -Path $publicSlotPath
    $stagedInventory = Get-CcSwitchManagedHarnessTreeInventory -Path $activeSlot.SlotPath
    $stagedContent = @($stagedInventory.Entries | Where-Object { -not [string]::Equals([string]$_.Path,'npm.cmd',[StringComparison]::Ordinal) })
    $publicContent = @($publicInventory.Entries)
    if ($stagedInventory.FileCount -ne ($publicInventory.FileCount + 1) -or $publicContent.Count -ne $stagedContent.Count) { throw 'Owned Claude slot inventory differs from the immutable public slot beyond the single temporary npm adapter.' }
    $publicEntryMap = @{}
    foreach ($entry in $publicContent) { $publicEntryMap[[string]$entry.Path] = if ($entry.Directory) { 'D' } else { 'F'+[string]$entry.Hash+':'+[string]$entry.Length } }
    foreach ($entry in $stagedContent) {
        $value = if ($entry.Directory) { 'D' } else { 'F'+[string]$entry.Hash+':'+[string]$entry.Length }
        if (-not $publicEntryMap.ContainsKey([string]$entry.Path) -or $publicEntryMap[[string]$entry.Path] -cne $value) { throw 'Owned Claude slot content differs from the immutable public slot after excluding only npm.cmd.' }
    }
    $activeCmdTarget = Get-RealManagedUiCmdExeTarget -SlotPath $activeSlot.SlotPath -ExpectedExecutable $activeSlot.ExecutablePath
    $initialExeVersion = Get-RealManagedUiClaudeExeVersion -Path $activeSlot.ExecutablePath
    if ($initialVersion -notmatch '^\d+\.\d+\.\d+$' -or $initialExeVersion -notmatch ('^' + [regex]::Escape($initialVersion) + '(?:\.0)?$')) { throw 'Initial Claude executable product version does not match its package manifest.' }
    $managedEnvironment = $managedOwner.Environment
    $managedEnvironment['WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'] = $browser
    $managedEnvironment['WEBVIEW2_USER_DATA_FOLDER'] = Join-Path $session 'webview2'
    $claudeConfigDir = [string]$managedEnvironment['CLAUDE_CONFIG_DIR']
    if (@([IO.Directory]::EnumerateFileSystemEntries($claudeConfigDir)).Count -ne 0) { throw 'Fresh Claude config directory is not empty; refusing to launch.' }
    $fixture = New-CcSwitchIsolatedFixtureRecord -Root $root -Exe (Join-Path $app 'cc-switch.exe') -StickRoot $stick -RuntimeRoot $runtime -ManagedHarnessRoot $harness -Environment $managedEnvironment -Arguments @()
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $validatedFixture = Read-AppContainerFixture -Path $fixturePath
    if (-not (Test-RealManagedUiUsbPresent)) { throw 'USB volume identity changed before AppContainer launch.' }
    $nativeUpdateSession = Start-CcSwitchNativeUpdateSession -Fixture $validatedFixture -Package $package -NetworkMode $NetworkMode
    $state = $nativeUpdateSession.State

    Write-Output ([pscustomobject]@{
        Status='Real managed-harness GUI ready; waiting for user-driven Claude update and GUI exit'
        ProcessId=[int]$state.ProcessId
        FixtureRoot=$root
        StopFile=$stopPath
        StatusPath=$progressPath
        NetworkMode=$NetworkMode
        CcSwitchVersion=$package.Version
        ClaudeVersionBefore=$initialVersion
        ClaudeExeVersionBefore=$initialExeVersion
        ClaudeCmdTarget=$activeCmdTarget
        NodeVersion=(Get-CcSwitchHarnessRuntimeStatus -StickRoot $usb).NodeVersion
        NpmVersion=(Get-CcSwitchHarnessRuntimeStatus -StickRoot $usb).NpmVersion
        ManagedNodePath=(Join-Path $runtime 'node\node.exe')
        ManagedClaudePath=(Join-Path $harness ('slots\'+[string]$managedOwner.ManagedSession.SlotId))
        ProvidersOrSecretsCopied=$false
        ModelRequestSent=$false
        NativeAdapterReady=[bool]$state.IsResumed
        UserAction='Open About → Claude update. After observing completion, close this real Claude harness test GUI; the harness saves only a validated higher package version.'
    })
    Write-RealManagedUiProgress -Phase 'GuiRunning'

    $deadline = [DateTime]::UtcNow.AddMinutes($MaximumWaitMinutes)
    $lastProgressWrite = [DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-RealManagedUiUsbPresent)) { $abortReason = 'USB volume identity changed while the GUI was running.'; break }
        if (Test-Path -LiteralPath $stopPath) { $abortReason = 'Owner requested abort; the owned AppContainer Job will be stopped without saving.'; break }
        $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 1
        if ($wait.Completed) {
            $processExitCode = $wait.ExitCode
            $normalExit = ($null -ne $processExitCode -and [long]$processExitCode -eq 0)
            if (-not $normalExit) { $abortReason = 'GUI exited without a confirmed zero exit code; no USB version slot will be saved.' }
            break
        }
        if (([DateTime]::UtcNow - $lastProgressWrite).TotalSeconds -ge 3) { Write-RealManagedUiProgress -Phase 'GuiRunning'; $lastProgressWrite = [DateTime]::UtcNow }
        Start-Sleep -Milliseconds 250
    }

    if ($normalExit) {
        $childrenExited = Wait-AppContainerProbeJobEmpty -JobHandle ([IntPtr]$state.JobHandle) -TimeoutMilliseconds ($ChildExitWaitSeconds * 1000)
        if (-not $childrenExited) { $normalExit = $false; $abortReason = 'Updater child processes did not exit; refusing to save a potentially partial package.' }
    }
    Complete-AppContainerProbeProcess -State $state
    $state = $null

    if ($normalExit) {
        try {
            $after = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId ([string]$managedOwner.ManagedSession.SlotId)
            if ($after.Valid -and $after.PackageVersion -match '^\d+\.\d+\.\d+$') {
                $finalVersion = [string]$after.PackageVersion
                $null = Get-RealManagedUiCmdExeTarget -SlotPath $after.SlotPath -ExpectedExecutable $after.ExecutablePath
                $finalExeVersion = Get-RealManagedUiClaudeExeVersion -Path $after.ExecutablePath
                if ($finalExeVersion -notmatch ('^' + [regex]::Escape($finalVersion) + '(?:\.0)?$')) { throw 'Claude executable product version does not match the updated package manifest.' }
            }
            if ($finalVersion -and $finalVersion -cne $initialVersion) {
                $oldParsed = [version]::new(); $newParsed = [version]::new()
                if ([version]::TryParse($initialVersion,[ref]$oldParsed) -and [version]::TryParse($finalVersion,[ref]$newParsed) -and $newParsed -gt $oldParsed) {
                    if (-not (Test-RealManagedUiUsbPresent)) { throw 'USB volume identity changed before version-slot save.' }
                    Remove-CcSwitchManagedClaudeNpmAdapter -ManagedHarnessRoot $harness -RuntimeRoot $runtime -SlotId ([string]$managedOwner.ManagedSession.SlotId) | Out-Null
                    $savedSlot = Save-CcManagedClaudeVersionSlot -StagedSlotPath (Join-Path $harness ('slots\'+[string]$managedOwner.ManagedSession.SlotId)) -UsbRoot $usb -ExpectedVolume $expectedVolume -AllowOnlineVerification:($NetworkMode -eq 'InternetClient')
                }
            }
        } catch { $saveError = $_.Exception.Message }
    }

    if ($savedSlot) { Write-Output (Write-RealManagedUiSummary -Status 'UpdatedAndSaved' -Message 'A higher validated Claude package version was copied to an immutable USB version slot.') }
    elseif (-not $normalExit) { Write-Output (Write-RealManagedUiSummary -Status 'NoCommit' -Message $(if ($abortReason) { $abortReason } else { 'The GUI did not exit normally before timeout; no USB version slot was saved.' })) }
    elseif ($saveError) { Write-Output (Write-RealManagedUiSummary -Status 'SaveRejected' -Message 'Update result was not committed to USB.') }
    elseif ($finalVersion -and $finalVersion -ceq $initialVersion) { Write-Output (Write-RealManagedUiSummary -Status 'NoVersionChange' -Message 'The validated package version did not change; USB was left unchanged.') }
    else { Write-Output (Write-RealManagedUiSummary -Status 'NoVerifiedUpdate' -Message 'No higher valid Claude package version was observed; USB was left unchanged.') }
    $finalPhase = if ($savedSlot) { 'UpdatedAndSaved' } elseif ($normalExit) { 'GuiExitedNoCommit' } else { 'NoNormalExit' }
    Write-RealManagedUiProgress -Phase $finalPhase
    if (-not $savedSlot) { $retained = $true }
} catch {
    $retained = $true
    if (-not $saveError) { $saveError = $_.Exception.Message }
    try { Write-RealManagedUiProgress -Phase 'FailedRetained' } catch { }
    Write-Output (Write-RealManagedUiSummary -Status 'FailedRetained' -Message 'The owned fixture was retained for diagnosis; no further USB write was attempted.')
    throw
} finally {
    if ($state) {
        try { Complete-AppContainerProbeProcess -State $state; $state = $null } catch { $retained = $true; Write-Warning ('Owned AppContainer cleanup failed; fixture retained at ' + $root) }
    }
    if ($savedSlot -and -not $retained -and (Test-Path -LiteralPath $root -PathType Container)) {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [string]::Equals($_.Path,(Join-Path $app 'cc-switch.exe'),[StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -gt 0) { $retained = $true; Write-Warning ('Owned GUI remains; fixture retained at ' + $root) }
        else {
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
            if ((Split-Path -Parent ([IO.Path]::GetFullPath($root))).TrimEnd('\','/') -ine $temp -or (Split-Path -Leaf $root) -cne ('aistick-ac-probe-'+$guidText)) { throw 'Refusing cleanup outside the exact owned temporary fixture.' }
            Assert-RealManagedUiFixtureTree -Path $root
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        }
    } elseif (Test-Path -LiteralPath $root -PathType Container) {
        Write-Output ('Fixture retained for review: ' + $root)
    }
}

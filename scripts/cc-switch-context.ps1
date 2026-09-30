[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$script:CcSwitchPortableIds = @('claude', 'codex', 'gemini', 'grok', 'opencode', 'openclaw', 'hermes', 'pi')
# Settings keys and supported defaults are pinned to farion1231/cc-switch v3.20.4 src-tauri/src/settings.rs.
$script:CcSwitchPortableSettingsFields = [ordered]@{
    claude = 'claudeConfigDir'
    codex = 'codexConfigDir'
    gemini = 'geminiConfigDir'
    grok = 'grokConfigDir'
    opencode = 'opencodeConfigDir'
    openclaw = 'openclawConfigDir'
    hermes = 'hermesConfigDir'
    pi = 'piConfigDir'
}

function Get-CcSwitchContextFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Context paths must be drive-absolute local filesystem paths.' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { return $full }
    return $full.TrimEnd('\', '/')
}

function Test-CcSwitchContextPathWithin {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $p = Get-CcSwitchContextFullPath $Path
    $r = Get-CcSwitchContextFullPath $Root
    if (-not [string]::Equals($p, [IO.Path]::GetPathRoot($p), [StringComparison]::OrdinalIgnoreCase)) { $p = $p.TrimEnd('\', '/') }
    if (-not [string]::Equals($r, [IO.Path]::GetPathRoot($r), [StringComparison]::OrdinalIgnoreCase)) { $r = $r.TrimEnd('\', '/') }
        if ([string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefixRoot = $r.TrimEnd('\', '/') + '\'
    return $p.StartsWith($prefixRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Copy-CcSwitchContextDictionary {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Dictionary)
    $copy = [ordered]@{}
    foreach ($key in $Dictionary.Keys) { $copy[$key] = $Dictionary[$key] }
    return $copy
}

function Test-CcSwitchContextPathsOverlap {
    param([string]$First, [string]$Second)
    return (Test-CcSwitchContextPathWithin -Path $First -Root $Second) -or (Test-CcSwitchContextPathWithin -Path $Second -Root $First)
}

function Assert-CcSwitchContextPlainPath {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$MustExist)
    $full = Get-CcSwitchContextFullPath $Path
    if ($MustExist -and -not (Test-Path -LiteralPath $full -PathType Container)) { throw 'A required context root is missing.' }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Context paths cannot pass through a reparse point.' }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-CcSwitchContextRoot {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    try { $full = Get-CcSwitchContextFullPath $Path }
    catch { throw "$Label must be an absolute filesystem path." }
    Assert-CcSwitchContextPlainPath -Path $full -MustExist
    return $full
}

function New-CcSwitchPortableContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$SessionRoot,
        [string[]]$HarnessIds = @('claude'),
        [string]$RuntimeRoot,
        [string]$ManagedHarnessRoot,
        [string]$ManagedHarnessSlotId
    )

    $stick = Assert-CcSwitchContextRoot -Path $StickRoot -Label 'StickRoot'
    $session = Assert-CcSwitchContextRoot -Path $SessionRoot -Label 'SessionRoot'
    if ([string]::Equals($session, [IO.Path]::GetPathRoot($session), [StringComparison]::OrdinalIgnoreCase)) { throw 'SessionRoot cannot be a volume root.' }
    if (Test-CcSwitchContextPathsOverlap -First $stick -Second $session) { throw 'StickRoot and SessionRoot must be disjoint directories.' }
    if (-not $HarnessIds -or $HarnessIds.Count -eq 0) { throw 'At least one supported harness must be enabled.' }
    $enabled = @($HarnessIds | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($id in $enabled) {
        if ($script:CcSwitchPortableIds -notcontains $id) { throw 'HarnessIds contains an unsupported or desktop target.' }
    }

    $persistentRoot = Join-Path $stick 'config\cc-switch'
    $portableHome = Join-Path $persistentRoot 'home'
    $harnessRoot = Join-Path $stick 'harness\cc-switch'
    $profile = Join-Path $session 'profile'
    $roaming = Join-Path $profile 'AppData\Roaming'
    $local = Join-Path $profile 'AppData\Local'
    $temp = Join-Path $session 'temp'
    $webview = Join-Path $session 'webview2'
    $runtime = $null
    $managedEnabled = -not [string]::IsNullOrWhiteSpace($ManagedHarnessSlotId)
    $managedHarness = $null
    if ($managedEnabled) {
        if ($enabled -notcontains 'claude') { throw 'Managed native harness updates currently support Claude only.' }
        if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or [string]::IsNullOrWhiteSpace($ManagedHarnessRoot)) { throw 'Managed native harness updates require copied session runtime and staging roots.' }
        $runtime = Assert-CcSwitchContextRoot -Path $RuntimeRoot -Label 'RuntimeRoot'
        $managedHarness = Assert-CcSwitchContextRoot -Path $ManagedHarnessRoot -Label 'ManagedHarnessRoot'
        if (-not [string]::Equals($session, (Join-Path $runtime 'session'), [StringComparison]::OrdinalIgnoreCase)) { throw 'SessionRoot must be the exact session child of RuntimeRoot.' }
        $ownedRoot = Split-Path -Parent $runtime
        if (-not [string]::Equals($runtime, (Join-Path $ownedRoot 'runtime'), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($stick, (Join-Path $ownedRoot 'stick'), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($managedHarness, (Join-Path $ownedRoot 'harness'), [StringComparison]::OrdinalIgnoreCase)) { throw 'RuntimeRoot and ManagedHarnessRoot must be the exact NTFS-owned workspace children.' }
        . (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
    } elseif (-not [string]::IsNullOrWhiteSpace($RuntimeRoot) -or -not [string]::IsNullOrWhiteSpace($ManagedHarnessRoot)) { throw 'RuntimeRoot and ManagedHarnessRoot are accepted only with a managed Claude slot.' }

    $geminiHome = Join-Path $harnessRoot 'gemini'
    $dirs = [ordered]@{}
    foreach ($id in $script:CcSwitchPortableIds) {
        $dirs[$id] = if ($id -eq 'gemini') { Join-Path $geminiHome '.gemini' } else { Join-Path $harnessRoot $id }
    }
    $settings = [ordered]@{
        launchOnStartup = $false
        minimizeToTrayOnClose = $false
        silentStartup = $false
        enableLocalProxy = $false
        enableClaudePluginIntegration = $false
        sessionAutoSyncEnabled = $false
        visibleApps = [pscustomobject][ordered]@{
            claude = ($enabled -contains 'claude')
            'claude-desktop' = $false
            codex = ($enabled -contains 'codex')
            gemini = ($enabled -contains 'gemini')
            grokbuild = ($enabled -contains 'grok')
            opencode = ($enabled -contains 'opencode')
            openclaw = ($enabled -contains 'openclaw')
            hermes = ($enabled -contains 'hermes')
            pi = ($enabled -contains 'pi')
            mcode = $false
        }
    }
    foreach ($id in $script:CcSwitchPortableIds) { $settings[$script:CcSwitchPortableSettingsFields[$id]] = $dirs[$id] }
    $settingsPath = Join-Path $portableHome '.cc-switch\settings.json'
    $ownedDirectories = @($persistentRoot, $portableHome, (Join-Path $portableHome '.cc-switch'), $harnessRoot, $geminiHome) + @($dirs.Values) + @($profile, (Join-Path $profile 'AppData'), $roaming, $local, $temp, $webview)
    $environment = [ordered]@{
        HOME = $portableHome
        USERPROFILE = $profile
        APPDATA = $roaming
        LOCALAPPDATA = $local
        CC_SWITCH_TEST_HOME = $portableHome
        WEBVIEW2_USER_DATA_FOLDER = $webview
        TEMP = $temp
        TMP = $temp
        CLAUDE_CONFIG_DIR = $dirs.claude
        CODEX_HOME = $dirs.codex
        GEMINI_CLI_HOME = $geminiHome
    }
    if ($managedHarness) {
        $harnessEnvironment = Get-CcSwitchManagedClaudeEnvironment -StickRoot $stick -RuntimeRoot $runtime -SlotId $ManagedHarnessSlotId -ManagedHarnessRoot $managedHarness
        foreach ($key in $harnessEnvironment.Keys) { $environment[$key] = [string]$harnessEnvironment[$key] }
        $npmData = Join-Path $managedHarness 'state\npm-data'
        $ownedDirectories += @((Join-Path $managedHarness 'state'),$npmData,(Join-Path $npmData 'cache'),(Join-Path $npmData 'config'))
    }

    foreach ($path in @($persistentRoot, $portableHome, (Join-Path $portableHome '.cc-switch'), $harnessRoot, $geminiHome) + @($dirs.Values)) {
        if (-not (Test-CcSwitchContextPathWithin -Path $path -Root $stick)) { throw 'A persistent context path escaped StickRoot.' }
    }
    foreach ($path in @($profile, (Join-Path $profile 'AppData'), $roaming, $local, $temp, $webview)) {
        if (-not (Test-CcSwitchContextPathWithin -Path $path -Root $session)) { throw 'A runtime context path escaped SessionRoot.' }
    }
    if ($managedHarness) {
        foreach ($path in @($managedHarness, (Join-Path $managedHarness 'state'), (Join-Path $managedHarness 'state\npm-data'), (Join-Path $managedHarness 'state\npm-data\cache'), (Join-Path $managedHarness 'state\npm-data\config'))) {
            if (-not (Test-CcSwitchContextPathWithin -Path $path -Root $ownedRoot)) { throw 'A managed harness staging path escaped the owned NTFS workspace.' }
        }
    }

    return [pscustomobject]@{
        Version = '3.20.4'
        StickRoot = $stick
        SessionRoot = $session
        RuntimeRoot = $runtime
        ManagedHarnessRoot = if ($managedEnabled) { $managedHarness } else { $null }
        ManagedHarnessSlotId = if ($managedEnabled) { $ManagedHarnessSlotId } else { $null }
        ManagedHarnessUpdates = $managedEnabled
        HarnessIds = [string[]]$enabled
        PersistentRoot = $persistentRoot
        Home = $portableHome
        HarnessDirectories = $dirs
        SettingsPath = $settingsPath
        Settings = $settings
        OwnedDirectories = [string[]]$ownedDirectories
        Environment = $environment
        EnvironmentOverrides = $environment
        EnvironmentBlockComplete = $false
        # v3.20.4 src-tauri/src/mcode_config.rs gives these inherited overrides
        # precedence over get_home_dir(); keep MCode hidden and remove them in
        # the child process so they cannot redirect a write to a host path.
        InheritedEnvironmentVariablesToRemove = @('MINIMAX_DATA_DIR', 'MAVIS_DATA_DIR')
        GuiValidated = $false
        RequiresExclusiveStickSettingsWriter = $true
        RequiresExclusiveSessionRoot = $true
    }
}

function Get-CcSwitchPortableContextPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    # Recompute from public inputs so caller mutation cannot make the returned plan authoritative.
    $fresh = New-CcSwitchPortableContext -StickRoot ([string]$Context.StickRoot) -SessionRoot ([string]$Context.SessionRoot) -HarnessIds ([string[]]$Context.HarnessIds) -RuntimeRoot ([string]$Context.RuntimeRoot) -ManagedHarnessRoot ([string]$Context.ManagedHarnessRoot) -ManagedHarnessSlotId ([string]$Context.ManagedHarnessSlotId)
    return [pscustomobject]@{
        Version = $fresh.Version
        StickRoot = $fresh.StickRoot
        SessionRoot = $fresh.SessionRoot
        RuntimeRoot = $fresh.RuntimeRoot
        ManagedHarnessRoot = $fresh.ManagedHarnessRoot
        ManagedHarnessUpdates = $fresh.ManagedHarnessUpdates
        ManagedHarnessSlotId = $fresh.ManagedHarnessSlotId
        PersistentRoot = $fresh.PersistentRoot
        Home = $fresh.Home
        SettingsPath = $fresh.SettingsPath
        HarnessDirectories = Copy-CcSwitchContextDictionary -Dictionary $fresh.HarnessDirectories
        OwnedDirectories = [string[]]$fresh.OwnedDirectories.Clone()
        SettingsFields = @($fresh.Settings.Keys)
        EnvironmentKeys = @($fresh.Environment.Keys)
        InheritedEnvironmentVariablesToRemove = [string[]]$fresh.InheritedEnvironmentVariablesToRemove.Clone()
        EnvironmentBlockComplete = $false
        GuiValidated = $false
    }
}

function Get-CcSwitchPortableEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    $fresh = New-CcSwitchPortableContext -StickRoot ([string]$Context.StickRoot) -SessionRoot ([string]$Context.SessionRoot) -HarnessIds ([string[]]$Context.HarnessIds) -RuntimeRoot ([string]$Context.RuntimeRoot) -ManagedHarnessRoot ([string]$Context.ManagedHarnessRoot) -ManagedHarnessSlotId ([string]$Context.ManagedHarnessSlotId)
    $copy = [ordered]@{}
    foreach ($key in $fresh.Environment.Keys) { $copy[$key] = [string]$fresh.Environment[$key] }
    return $copy
}

function Assert-CcSwitchContextDirectorySafe {
    param([string]$Path, [string]$Root)
    if (-not (Test-CcSwitchContextPathWithin -Path $Path -Root $Root)) { throw 'A requested write is outside its managed root.' }
    Assert-CcSwitchContextPlainPath -Path $Path
}

function Set-CcSwitchContextJsonProperty {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value }
    else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function Initialize-CcSwitchPortableContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    $ErrorActionPreference = 'Stop'
    # Never trust mutable fields supplied in Context; recompute all paths and settings from roots/IDs.
    $fresh = New-CcSwitchPortableContext -StickRoot ([string]$Context.StickRoot) -SessionRoot ([string]$Context.SessionRoot) -HarnessIds ([string[]]$Context.HarnessIds) -RuntimeRoot ([string]$Context.RuntimeRoot) -ManagedHarnessRoot ([string]$Context.ManagedHarnessRoot) -ManagedHarnessSlotId ([string]$Context.ManagedHarnessSlotId)
    $dirsToCreate = @($fresh.OwnedDirectories)
    foreach ($path in $dirsToCreate) {
        $boundary = if (Test-CcSwitchContextPathWithin -Path $path -Root $fresh.StickRoot) { $fresh.StickRoot } elseif (Test-CcSwitchContextPathWithin -Path $path -Root $fresh.SessionRoot) { $fresh.SessionRoot } else { $fresh.ManagedHarnessRoot }
        Assert-CcSwitchContextDirectorySafe -Path $path -Root $boundary
    }

    foreach ($path in $dirsToCreate) {
        if (-not (Test-Path -LiteralPath $path)) {
            [IO.Directory]::CreateDirectory($path) | Out-Null
            $boundary = if (Test-CcSwitchContextPathWithin -Path $path -Root $fresh.StickRoot) { $fresh.StickRoot } elseif (Test-CcSwitchContextPathWithin -Path $path -Root $fresh.SessionRoot) { $fresh.SessionRoot } else { $fresh.ManagedHarnessRoot }
            Assert-CcSwitchContextDirectorySafe -Path $path -Root $boundary
        } elseif (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'A managed directory path is occupied by a non-directory item.' }
    }
    if ($fresh.ManagedHarnessUpdates) {
        $npmConfig = Join-Path $fresh.ManagedHarnessRoot 'state\npm-data\config'
        foreach ($name in @('user.npmrc','global.npmrc')) {
            $configPath = Join-Path $npmConfig $name
            Assert-CcSwitchContextDirectorySafe -Path $configPath -Root $fresh.ManagedHarnessRoot
            if (Test-Path -LiteralPath $configPath) {
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or (Get-Item -LiteralPath $configPath -Force).Length -ne 0) { throw 'Managed npm configuration must be an empty regular file; host npm configuration is never reused.' }
            } else {
                $stream = New-Object IO.FileStream($configPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $stream.Dispose()
            }
        }
    }

    $root = $fresh.PersistentRoot
    $lockPath = Join-Path $root '.settings-write.lock'
    Assert-CcSwitchContextDirectorySafe -Path $lockPath -Root $fresh.StickRoot
    $lock = $null
    try {
        try { $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw 'Could not acquire the portable settings writer lock; another writer may be active.' }

        $path = $fresh.SettingsPath
        Assert-CcSwitchContextDirectorySafe -Path $path -Root $fresh.StickRoot
        $tempPath = $path + '.cc-switch.tmp'
        $backupPath = $path + '.cc-switch.bak'
        $rollbackPath = $path + '.cc-switch.rollback.tmp'
        if ((Test-Path -LiteralPath $tempPath) -or (Test-Path -LiteralPath $rollbackPath)) { throw 'An unresolved settings transaction temp exists; refusing to overwrite it.' }

        $settingsObject = $null
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if ((Test-Path -LiteralPath $path) -and -not $exists) { throw 'Settings path is occupied by a non-file item.' }
        if (-not $exists -and (Test-Path -LiteralPath $backupPath)) { throw 'Settings is missing while a backup exists; manual recovery is required.' }
        if (Test-Path -LiteralPath $backupPath) {
            Assert-CcSwitchContextDirectorySafe -Path $backupPath -Root $fresh.StickRoot
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw 'Settings backup path is occupied by a non-file item.' }
        }
        if ($exists) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Settings file cannot be a reparse point.' }
            if ($item.Length -gt 2097152) { throw 'Existing settings file is larger than the supported safety limit.' }
            try {
                $existingText = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
                $settingsObject = ConvertFrom-Json -InputObject $existingText -ErrorAction Stop
                if ($null -eq $settingsObject -or $settingsObject -isnot [System.Management.Automation.PSCustomObject]) { throw 'Invalid settings root.' }
            } catch { throw 'Existing settings file is not valid supported JSON; it was left unchanged.' }
        } else { $settingsObject = [pscustomobject]@{} }

        $needsWrite = -not $exists
        foreach ($name in $fresh.Settings.Keys) {
            $property = $settingsObject.PSObject.Properties[$name]
            if (-not $property) { $needsWrite = $true }
            else {
                $currentValue = ConvertTo-Json -InputObject $property.Value -Depth 100 -Compress
                $expectedValue = ConvertTo-Json -InputObject $fresh.Settings[$name] -Depth 100 -Compress
                if ($currentValue -cne $expectedValue) { $needsWrite = $true }
            }
            Set-CcSwitchContextJsonProperty -Object $settingsObject -Name $name -Value $fresh.Settings[$name]
        }

        if ($needsWrite) {
            $json = ConvertTo-Json -InputObject $settingsObject -Depth 100
            $encoding = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($tempPath, $json, $encoding)
            Assert-CcSwitchContextDirectorySafe -Path $tempPath -Root $fresh.StickRoot

            if ($exists) {
                $stagedPath = if (Test-Path -LiteralPath $backupPath) { $rollbackPath } else { $backupPath }
                Assert-CcSwitchContextDirectorySafe -Path $stagedPath -Root $fresh.StickRoot
                try {
                    [IO.File]::Move($path, $stagedPath)
                    [IO.File]::Move($tempPath, $path)
                } catch {
                    if (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $stagedPath)) {
                        try { [IO.File]::Move($stagedPath, $path) } catch { throw 'Settings transaction failed and automatic restoration failed; manual recovery is required.' }
                    }
                    throw 'Could not safely commit the settings transaction; existing settings were restored.'
                }
                if ($stagedPath -eq $rollbackPath) {
                    Assert-CcSwitchContextDirectorySafe -Path $rollbackPath -Root $fresh.StickRoot
                    Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
                }
            } else {
                [IO.File]::Move($tempPath, $path)
            }
        }
        Assert-CcSwitchContextDirectorySafe -Path $path -Root $fresh.StickRoot
    } finally {
        if ($lock) { $lock.Dispose() }
    }

    return [pscustomobject]@{
        Version = $fresh.Version
        PersistentRoot = $fresh.PersistentRoot
        Home = $fresh.Home
        SettingsPath = $fresh.SettingsPath
        HarnessDirectories = Copy-CcSwitchContextDictionary -Dictionary $fresh.HarnessDirectories
        Environment = Get-CcSwitchPortableEnvironment -Context $fresh
        InheritedEnvironmentVariablesToRemove = [string[]]$fresh.InheritedEnvironmentVariablesToRemove.Clone()
        EnvironmentBlockComplete = $false
        GuiValidated = $false
        SettingsCreatedOrUpdated = $needsWrite
    }
}

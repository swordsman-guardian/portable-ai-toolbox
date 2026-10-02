[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

function Get-CcSwitchHarnessRuntimeFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Harness runtime paths must be absolute local-drive paths.' }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($full, [IO.Path]::GetPathRoot($full), [StringComparison]::OrdinalIgnoreCase)) { $full = $full.TrimEnd('\','/') }
    return $full
}

function Get-CcSwitchHarnessRuntimeSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToUpperInvariant()) }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Test-CcSwitchHarnessRuntimeWithin {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $p = Get-CcSwitchHarnessRuntimeFullPath $Path
    $r = Get-CcSwitchHarnessRuntimeFullPath $Root
    if ([string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith(($r.TrimEnd('\','/') + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CcSwitchHarnessRuntimePlainPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Boundary)
    $full = Get-CcSwitchHarnessRuntimeFullPath $Path
    if (-not (Test-CcSwitchHarnessRuntimeWithin -Path $full -Root $Boundary)) { throw 'Harness runtime path escaped its managed StickRoot.' }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Harness runtime paths cannot pass through a reparse point.' }
        }
        if ([string]::Equals($current, $Boundary, [StringComparison]::OrdinalIgnoreCase)) {
            $ancestor = Split-Path -Parent $current
            while ($ancestor) {
                if (Test-Path -LiteralPath $ancestor) {
                    $parentItem = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
                    if ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'StickRoot ancestry cannot pass through a reparse point.' }
                }
                $next = Split-Path -Parent $ancestor
                if (-not $next -or $next -eq $ancestor) { break }
                $ancestor = $next
            }
            break
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { throw 'Harness runtime path ancestry is invalid.' }
        $current = $parent
    }
}

function Get-CcSwitchHarnessRuntimeStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $stick = Get-CcSwitchHarnessRuntimeFullPath $StickRoot
    if (-not (Test-Path -LiteralPath $stick -PathType Container)) { throw 'StickRoot does not exist.' }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $stick -Boundary $stick

    $nodeRoot = Join-Path $stick 'runtime\node'
    $nodeExe = Join-Path $nodeRoot 'node.exe'
    $npmCmd = Join-Path $nodeRoot 'npm.cmd'
    $npmCli = Join-Path $nodeRoot 'node_modules\npm\bin\npm-cli.js'
    $prefix = Join-Path $stick 'npm-global'
    $cache = Join-Path $stick 'cache\npm'
    foreach ($path in @($nodeRoot, $nodeExe, $npmCmd, $npmCli, $prefix, $cache)) {
        Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $stick
    }
    $requiredFiles = @($nodeExe, $npmCmd, $npmCli)
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    $ready = ($missing.Count -eq 0)
    $versions = [ordered]@{ Node = $null; Npm = $null }
    if ($ready) {
        $versions.Node = (Get-Item -LiteralPath $nodeExe -Force).VersionInfo.ProductVersion
        $npmPackagePath = Join-Path $nodeRoot 'node_modules\npm\package.json'
        Assert-CcSwitchHarnessRuntimePlainPath -Path $npmPackagePath -Boundary $stick
        if (Test-Path -LiteralPath $npmPackagePath -PathType Leaf) {
            $packageInfo = [IO.File]::ReadAllText($npmPackagePath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $versions.Npm = [string]$packageInfo.version
        }
    }
    return [pscustomobject]@{
        StickRoot = $stick
        RuntimeRoot = $nodeRoot
        NodeExe = $nodeExe
        NpmCmd = $npmCmd
        NpmCli = $npmCli
        InstallPrefix = $prefix
        Cache = $cache
        Ready = $ready
        Missing = [string[]]$missing
        NodeVersion = $versions.Node
        NpmVersion = $versions.Npm
        DiscoveryConfinement = 'Subprocess PATH only; unmodified CC Switch v3.20.4 also searches registry PATH and fixed host locations.'
        NativeLifecycleConfinement = 'Unsupported by unmodified CC Switch v3.20.4; do not use native install/update actions as USB-confined.'
    }
}

function Get-CcSwitchHarnessRuntimeEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $status = Get-CcSwitchHarnessRuntimeStatus -StickRoot $StickRoot
    if (-not $status.Ready) { throw 'Managed Node/npm runtime is incomplete.' }
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or -not [IO.Directory]::Exists($systemRoot)) { throw 'SystemRoot is unavailable.' }
    $envMap = [ordered]@{
        PATH = (@($status.RuntimeRoot, (Join-Path $status.InstallPrefix 'bin'), (Join-Path $systemRoot 'System32')) -join ';')
        USERPROFILE = $status.StickRoot
        APPDATA = (Join-Path $status.StickRoot 'config\npm\roaming')
        LOCALAPPDATA = (Join-Path $status.StickRoot 'config\npm\local')
        TEMP = (Join-Path $status.StickRoot 'cache\temp')
        TMP = (Join-Path $status.StickRoot 'cache\temp')
        npm_config_prefix = $status.InstallPrefix
        npm_config_cache = $status.Cache
        npm_config_userconfig = (Join-Path $status.StickRoot 'config\npm\user.npmrc')
        npm_config_globalconfig = (Join-Path $status.StickRoot 'config\npm\global.npmrc')
        HOME = $status.StickRoot
        NO_PROXY = '*'
    }
    foreach ($key in @('USERPROFILE','APPDATA','LOCALAPPDATA','TEMP','TMP','npm_config_userconfig','npm_config_globalconfig')) {
        Assert-CcSwitchHarnessRuntimePlainPath -Path ([string]$envMap[$key]) -Boundary $status.StickRoot
    }
    return $envMap
}

function Get-CcSwitchHarnessNpmInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot, [Parameter(Mandatory = $true)][string]$Package)
    if ([string]::IsNullOrWhiteSpace($Package) -or $Package -notmatch '^(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+(?:@[A-Za-z0-9._+*-]+)?$') { throw 'Only a registry package specifier may be planned; local paths and URLs are not accepted.' }
    $status = Get-CcSwitchHarnessRuntimeStatus -StickRoot $StickRoot
    if (-not $status.Ready) { throw 'Managed Node/npm runtime is incomplete.' }
    return [pscustomobject]@{
        Executable = $status.NpmCmd
        Arguments = [string[]]@('install','--global','--prefix',$status.InstallPrefix,'--cache',$status.Cache,'--no-fund','--no-audit',$Package)
        InstallPrefix = $status.InstallPrefix
        Cache = $status.Cache
        RuntimeRoot = $status.RuntimeRoot
        Executes = $false
    }
}

function Get-CcSwitchManagedClaudeEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$ManagedHarnessRoot
    )
    $stick = Get-CcSwitchHarnessRuntimeFullPath $StickRoot
    $runtime = Get-CcSwitchHarnessRuntimeFullPath $RuntimeRoot
    $expectedRuntime = Join-Path $runtime 'node'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $stick -Boundary $stick
    Assert-CcSwitchHarnessRuntimePlainPath -Path $runtime -Boundary $runtime
    $node = Join-Path $expectedRuntime 'node.exe'
    $npmCli = Join-Path $expectedRuntime 'node_modules\npm\bin\npm-cli.js'
    foreach ($path in @($expectedRuntime, $node, $npmCli)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $runtime }
    if (-not [IO.File]::Exists($node) -or -not [IO.File]::Exists($npmCli)) { throw 'Managed Node/npm runtime is incomplete.' }
    $harness = Get-CcSwitchHarnessRuntimeFullPath $ManagedHarnessRoot
    $ownedRoot = Split-Path -Parent $runtime
    if (-not [string]::Equals($stick,(Join-Path $ownedRoot 'stick'),[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($harness,(Join-Path $ownedRoot 'harness'),[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($runtime,(Join-Path $ownedRoot 'runtime'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Stick, harness, and runtime roots must be sibling children of one owned staging root.' }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $harness -Boundary $harness
    if ($SlotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $SlotId -in @('.', '..')) { throw 'Managed Claude slot id is invalid.' }
    $slot = Join-Path $harness ('slots\' + $SlotId)
    Assert-CcSwitchHarnessRuntimePlainPath -Path $slot -Boundary $harness
    if (-not [IO.Directory]::Exists($slot)) { throw 'Managed Claude slot is missing.' }
    $cli = Join-Path $slot 'claude.cmd'
    if (-not [IO.File]::Exists($cli)) { throw 'Managed Claude slot does not contain its Windows CLI shim.' }
    $slotStatus = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $SlotId
    if (-not $slotStatus.Valid) { throw 'Managed Claude slot did not pass package and tree validation.' }
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or -not [IO.Directory]::Exists($systemRoot)) { throw 'SystemRoot is unavailable.' }
    $system32 = Join-Path $systemRoot 'System32'
    $npmData = Join-Path $harness 'state\npm-data'
    $cache = Join-Path $npmData 'cache'
    $config = Join-Path $npmData 'config'
    foreach ($path in @($npmData,$cache,$config)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $harness }
    return [ordered]@{
        PATH = (@($slot,$expectedRuntime,$system32) -join ';')
        npm_config_prefix = $slot
        npm_config_cache = $cache
        npm_config_userconfig = (Join-Path $config 'user.npmrc')
        npm_config_globalconfig = (Join-Path $config 'global.npmrc')
        npm_config_registry = 'https://registry.npmjs.org/'
        NODE_OPTIONS = '--preserve-symlinks --preserve-symlinks-main'
    }
}

function Test-CcSwitchManagedClaudeSlot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManagedHarnessRoot,[Parameter(Mandatory = $true)][string]$SlotId)
    if ($SlotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Managed Claude slot id is invalid.' }
    $harness = Get-CcSwitchHarnessRuntimeFullPath $ManagedHarnessRoot
    $slot = Join-Path $harness ('slots\' + $SlotId)
    Assert-CcSwitchHarnessRuntimePlainPath -Path $slot -Boundary $harness
    if (-not [IO.Directory]::Exists($slot)) { return [pscustomobject]@{Valid=$false;Reason='missing-slot';PackageVersion=$null;FileCount=0} }
    $allowedTop = @('claude','claude.cmd','claude.ps1','claude.bash','node_modules','npm.cmd')
    $adapterEntryPresent = $false
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($slot,'*',[IO.SearchOption]::TopDirectoryOnly)) {
        $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Managed Claude slot cannot contain reparse points.' }
        if ($allowedTop -notcontains $item.Name) { throw 'Managed Claude slot contains an unexpected top-level item.' }
        if ([string]::Equals($item.Name,'npm.cmd',[StringComparison]::OrdinalIgnoreCase)) {
            if ($item.PSIsContainer -or $item.Name -cne 'npm.cmd') { throw 'Temporary npm adapter must be the exact npm.cmd leaf file.' }
            $adapterEntryPresent = $true
        }
    }
    $adapterPath = Join-Path $slot 'npm.cmd'
    if ($adapterEntryPresent) { Assert-CcSwitchManagedClaudeNpmAdapter -SlotPath $slot -RuntimeRoot (Join-Path (Split-Path -Parent $harness) 'runtime') }
    $packagePath = Join-Path $slot 'node_modules\@anthropic-ai\claude-code\package.json'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $packagePath -Boundary $harness
    if (-not [IO.File]::Exists($packagePath)) { return [pscustomobject]@{Valid=$false;Reason='missing-package-manifest';PackageVersion=$null;FileCount=0} }
    $manifest = [IO.File]::ReadAllText($packagePath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.name -cne '@anthropic-ai/claude-code' -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Managed slot package manifest is not a stable versioned official Claude Code package.' }
    $packageRoot = Split-Path -Parent $packagePath
    $verifiedExe = Resolve-CcSwitchManagedClaudeCommandTarget -SlotPath $slot -PackageRoot $packageRoot -Manifest $manifest -Boundary $harness
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($slot)
    $fileCount = 0
    [long]$byteCount = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory,'*',[IO.SearchOption]::TopDirectoryOnly)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Managed Claude package tree cannot contain reparse points.' }
            if ($item.PSIsContainer) { $pending.Push([string]$item.FullName) }
            else {
                $fileCount++
                $byteCount += [long]$item.Length
                if ($fileCount -gt 200000 -or $byteCount -gt 4294967296) { throw 'Managed Claude package tree exceeds the bounded inventory limit.' }
            }
        }
    }
    return [pscustomobject]@{Valid=$true;Reason='verified';PackageVersion=[string]$manifest.version;FileCount=$fileCount;ByteCount=$byteCount;SlotPath=$slot;ExecutablePath=$verifiedExe}
}

function Get-CcSwitchManagedClaudeNpmAdapterText {
    return "@ECHO off`r`n`"%~dp0..\..\..\runtime\node\node.exe`" --preserve-symlinks --preserve-symlinks-main `"%~dp0..\..\..\runtime\updates\cc-switch-portable-claude-install.cjs`" %*`r`n@exit /b %errorlevel%`r`n"
}

function Assert-CcSwitchManagedClaudeNpmAdapter {
    param([Parameter(Mandatory=$true)][string]$SlotPath,[Parameter(Mandatory=$true)][string]$RuntimeRoot)
    $slot = Get-CcSwitchHarnessRuntimeFullPath $SlotPath
    $runtime = Get-CcSwitchHarnessRuntimeFullPath $RuntimeRoot
    $owned = Split-Path -Parent $runtime
    $slotsRoot = Join-Path $owned 'harness\slots'
    if (-not [string]::Equals($runtime,(Join-Path $owned 'runtime'),[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Parent $slot),$slotsRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $slot) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Temporary npm adapter is accepted only inside one direct slot of the exact owned harness/runtime layout.' }
    $adapter = Join-Path $slot 'npm.cmd'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $slot -Boundary (Split-Path -Parent $slot)
    Assert-CcSwitchHarnessRuntimePlainPath -Path $adapter -Boundary $slot
    $item = Get-Item -LiteralPath $adapter -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 4096) { throw 'Temporary npm adapter is a reparse point or exceeds its size limit.' }
    $expected = Get-CcSwitchManagedClaudeNpmAdapterText
    if ([IO.File]::ReadAllText($adapter,[Text.Encoding]::ASCII) -cne $expected) { throw 'Temporary npm adapter does not match the fixed portable-installer template.' }
    $node = Join-Path $runtime 'node\node.exe'
    $installer = Join-Path $runtime 'updates\cc-switch-portable-claude-install.cjs'
    foreach ($path in @($node,$installer)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $runtime }
    if (-not [IO.File]::Exists($node) -or -not [IO.File]::Exists($installer)) { throw 'Portable Claude installer runtime is incomplete.' }
}

function Add-CcSwitchManagedClaudeNpmAdapter {
    param([Parameter(Mandatory=$true)][string]$ManagedHarnessRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$SlotId)
    if ($SlotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $SlotId -in @('.','..')) { throw 'Managed Claude slot id is invalid.' }
    $harness = Get-CcSwitchHarnessRuntimeFullPath $ManagedHarnessRoot
    $slot = Join-Path $harness ('slots\'+$SlotId)
    $runtime = Get-CcSwitchHarnessRuntimeFullPath $RuntimeRoot
    if (-not (Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harness -SlotId $SlotId).Valid) { throw 'Cannot add an adapter to an invalid managed Claude slot.' }
    $updates = Join-Path $runtime 'updates'
    $moduleNames = @('cc-switch-portable-claude-install.cjs')
    foreach ($path in @($runtime,$updates)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $runtime }
    foreach ($moduleName in $moduleNames) { Assert-CcSwitchHarnessRuntimePlainPath -Path (Join-Path $PSScriptRoot $moduleName) -Boundary $PSScriptRoot }
    foreach ($moduleName in $moduleNames) { if (-not [IO.File]::Exists((Join-Path $PSScriptRoot $moduleName))) { throw ('Portable Claude runtime module is missing: '+$moduleName) } }
    [IO.Directory]::CreateDirectory($updates) | Out-Null
    foreach ($moduleName in $moduleNames) {
        $source = Join-Path $PSScriptRoot $moduleName
        $destination = Join-Path $updates $moduleName
        if ([IO.File]::Exists($destination)) { throw ('Refusing to replace an existing portable Claude module: '+$moduleName) }
        $sourceHash = Get-CcSwitchHarnessRuntimeSha256 -Path $source
        [IO.File]::Copy($source,$destination,$false)
        if (-not [string]::Equals($sourceHash,(Get-CcSwitchHarnessRuntimeSha256 -Path $destination),[StringComparison]::OrdinalIgnoreCase)) { throw ('Copied portable Claude module failed SHA-256 verification: '+$moduleName) }
    }
    $adapter = Join-Path $slot 'npm.cmd'
    if ([IO.File]::Exists($adapter)) { throw 'Refusing to replace an existing slot npm adapter.' }
    [IO.File]::WriteAllText($adapter,(Get-CcSwitchManagedClaudeNpmAdapterText),(New-Object Text.ASCIIEncoding))
    Assert-CcSwitchManagedClaudeNpmAdapter -SlotPath $slot -RuntimeRoot $runtime
}

function Remove-CcSwitchManagedClaudeNpmAdapter {
    param([Parameter(Mandatory=$true)][string]$ManagedHarnessRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$SlotId)
    if ($SlotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $SlotId -in @('.','..')) { throw 'Managed Claude slot id is invalid.' }
    $harness = Get-CcSwitchHarnessRuntimeFullPath $ManagedHarnessRoot
    $runtime = Get-CcSwitchHarnessRuntimeFullPath $RuntimeRoot
    $owned = Split-Path -Parent $runtime
    if (-not [string]::Equals($harness,(Join-Path $owned 'harness'),[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($runtime,(Join-Path $owned 'runtime'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary npm adapter removal requires the exact owned harness/runtime layout.' }
    $slot = Join-Path $harness ('slots\'+$SlotId)
    $adapter = Join-Path $slot 'npm.cmd'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $slot -Boundary $harness
    if (-not [IO.Directory]::Exists($slot)) { throw 'Managed Claude version slot is missing.' }
    $entry = @([IO.Directory]::EnumerateFileSystemEntries($slot,'*',[IO.SearchOption]::TopDirectoryOnly) | Where-Object { [string]::Equals((Split-Path -Leaf $_),'npm.cmd',[StringComparison]::OrdinalIgnoreCase) })
    if (-not $entry.Count) { return $false }
    if ($entry.Count -ne 1 -or [string]::Equals((Split-Path -Leaf $entry[0]),'npm.cmd',[StringComparison]::Ordinal) -eq $false) { throw 'Temporary npm adapter entry has an unexpected name or duplicate form.' }
    Assert-CcSwitchManagedClaudeNpmAdapter -SlotPath $slot -RuntimeRoot $RuntimeRoot
    [IO.File]::Delete($adapter)
    return $true
}

function Resolve-CcSwitchManagedClaudeCommandTarget {
    param([Parameter(Mandatory=$true)][string]$SlotPath,[Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)]$Manifest,[Parameter(Mandatory=$true)][string]$Boundary)
    $slot = Get-CcSwitchHarnessRuntimeFullPath $SlotPath
    $package = Get-CcSwitchHarnessRuntimeFullPath $PackageRoot
    $shim = Join-Path $slot 'claude.cmd'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $shim -Boundary $Boundary
    $shimItem = Get-Item -LiteralPath $shim -Force -ErrorAction Stop
    if (($shimItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $shimItem.Length -gt 65536) { throw 'Managed Claude command shim is a reparse point or exceeds its size limit.' }
    $text = [IO.File]::ReadAllText($shim,[Text.Encoding]::ASCII)
    $lines = @($text -split "`r?`n")
    $allowedControl = @('','@ECHO off','@echo off','GOTO start','goto start',':find_dp0',':start','SET dp0=%~dp0','set dp0=%~dp0','EXIT /b','exit /b','SETLOCAL','setlocal','CALL :find_dp0','call :find_dp0')
    $targets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        if ($allowedControl -ccontains $line.Trim()) { continue }
        $match = [regex]::Match($line,'^\s*"(?:%dp0%|%~dp0)(?<relative>\\node_modules\\@anthropic-ai\\claude-code(?:\\bin\\claude\.exe|\\node_modules\\@anthropic-ai\\claude-code-win32-x64\\claude\.exe))"\s+%\*\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { throw 'Managed Claude command shim contains an unsupported or ambiguous command.' }
        $targets.Add($match.Groups['relative'].Value)
    }
    if ($targets.Count -ne 1) { throw 'Managed Claude command shim must contain exactly one supported executable target.' }
    $relative = $targets[0].TrimStart('\')
    $target = Get-CcSwitchHarnessRuntimeFullPath (Join-Path $slot $relative)
    if (-not (Test-CcSwitchHarnessRuntimeWithin -Path $target -Root $slot)) { throw 'Managed Claude command target escaped its version slot.' }
    $expectedBin = Get-CcSwitchHarnessRuntimeFullPath (Join-Path $package 'bin\claude.exe')
    $expectedNested = Get-CcSwitchHarnessRuntimeFullPath (Join-Path $package 'node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe')
    if (-not [string]::Equals($target,$expectedBin,[StringComparison]::OrdinalIgnoreCase) -and -not [string]::Equals($target,$expectedNested,[StringComparison]::OrdinalIgnoreCase)) { throw 'Managed Claude command target is not one of the two supported package-relative executables.' }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $target -Boundary $Boundary
    if (-not [IO.File]::Exists($target)) { throw 'Managed Claude command target is missing.' }
    $exeItem = Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if (($exeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $exeItem.Length -lt 1000000 -or -not (Test-CcSwitchManagedClaudePeFile -Path $target)) { throw 'Managed Claude command target is not a real Windows x64 executable.' }
    $platformManifest = Join-Path (Split-Path -Parent $expectedNested) 'package.json'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $platformManifest -Boundary $Boundary
    if ([IO.File]::Exists($platformManifest)) {
        $platform = [IO.File]::ReadAllText($platformManifest,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$platform.name -cne '@anthropic-ai/claude-code-win32-x64' -or [string]$platform.version -cne [string]$Manifest.version) { throw 'Managed Claude Windows platform package does not match the wrapper package version.' }
    } elseif ([string]::Equals($target,$expectedNested,[StringComparison]::OrdinalIgnoreCase)) { throw 'Managed Claude nested executable has no matching Windows platform package manifest.' }
    $expectedVersion = [string]$Manifest.version
    $versionInfo = $exeItem.VersionInfo
    foreach ($field in @('ProductVersion','FileVersion')) {
        $value = [string]$versionInfo.$field
        if ($value -notmatch '^(\d+\.\d+\.\d+)(?:\.0)?$' -or $Matches[1] -cne $expectedVersion) { throw ("Managed Claude executable {0} does not match its package manifest version." -f $field) }
    }
    return $target
}

function Get-CcSwitchManagedClaudeUpdatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$ManagedHarnessRoot,
        [string]$Package = '@anthropic-ai/claude-code@latest'
    )
    if ($Package -cnotmatch '^@anthropic-ai/claude-code(?:@[A-Za-z0-9._+*-]+)?$') { throw 'Only the official Claude Code package may be planned.' }
    $environment = Get-CcSwitchManagedClaudeEnvironment -StickRoot $StickRoot -RuntimeRoot $RuntimeRoot -SlotId $SlotId -ManagedHarnessRoot $ManagedHarnessRoot
    return [pscustomobject]@{
        Executable = Join-Path (Join-Path (Get-CcSwitchHarnessRuntimeFullPath $RuntimeRoot) 'node') 'npm.cmd'
        Arguments = [string[]]@('install','--global','--prefix',[string]$environment.npm_config_prefix,'--cache',[string]$environment.npm_config_cache,'--no-fund','--no-audit',$Package)
        CliPath = Join-Path ([string]$environment.npm_config_prefix) 'claude.cmd'
        Environment = $environment
        Executes = $false
        WritesToRealUsb = $false
    }
}

function Get-CcSwitchManagedHarnessTreeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $root = Get-CcSwitchHarnessRuntimeFullPath $Path
    if (-not [IO.Directory]::Exists($root)) { throw 'Managed harness tree is missing.' }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $root -Boundary $root
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    [long]$bytes = 0
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir,'*',[IO.SearchOption]::TopDirectoryOnly)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Managed harness trees cannot contain reparse points.' }
            $relative = $item.FullName.Substring($root.Length).TrimStart('\')
            if ($item.PSIsContainer) { $stack.Push($item.FullName); $entries.Add([pscustomobject]@{Path=$relative;Directory=$true;Length=0;Hash=$null}) }
            else {
                $bytes += [long]$item.Length
                if ($bytes -gt 4294967296 -or $entries.Count -gt 200000) { throw 'Managed harness tree exceeds inventory limits.' }
                $entries.Add([pscustomobject]@{Path=$relative;Directory=$false;Length=[long]$item.Length;Hash=(Get-CcSwitchHarnessRuntimeSha256 -Path $item.FullName)})
            }
        }
    }
    return [pscustomobject]@{Root=$root;Entries=@($entries | Sort-Object Path);ByteCount=$bytes;FileCount=@($entries | Where-Object { -not $_.Directory }).Count}
}

function Get-CcSwitchHarnessVolumeIdentity {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=Get-CcSwitchHarnessRuntimeFullPath $Path
    $drive=(Split-Path -Qualifier $full).TrimEnd(':')
    $id=[ordered]@{DriveLetter=$drive;VolumeGuid=$null;Serial=$null}
    try{$volume=Get-Volume -DriveLetter $drive -ErrorAction Stop;$id.VolumeGuid=[string]$volume.UniqueId}catch{}
    try{$disk=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $drive) -ErrorAction Stop;if($disk){$id.Serial=[string]$disk.VolumeSerialNumber}}catch{}
    if(-not $id.VolumeGuid -and -not $id.Serial){throw 'Cannot identify the USB volume for a safe version-slot commit.'}
    return [pscustomobject]$id
}

function Test-CcSwitchHarnessVolumeIdentity {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)]$Actual)
    $compared=0
    foreach($name in @('VolumeGuid','Serial')){$e=$Expected.PSObject.Properties[$name];$a=$Actual.PSObject.Properties[$name];if($e -and $a -and $e.Value -and $a.Value){$compared++;if(-not [string]::Equals([string]$e.Value,[string]$a.Value,[StringComparison]::OrdinalIgnoreCase)){return $false}}}
    return ($compared -gt 0)
}

function Test-CcSwitchManagedClaudePeFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$reader=New-Object IO.BinaryReader($stream);if($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D){return $false};$stream.Position=0x3c;$offset=$reader.ReadInt32();if($offset -lt 64 -or $offset -gt ($stream.Length-26)){return $false};$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x00004550){return $false};$machine=$reader.ReadUInt16();$stream.Position=$offset+24;$magic=$reader.ReadUInt16();return ($machine -eq 0x8664 -and $magic -eq 0x20b)}finally{$stream.Dispose()}
}

function Test-CcSwitchManagedClaudeHashManifest {
    param([Parameter(Mandatory=$true)][string]$SlotPath,[Parameter(Mandatory=$true)][string]$ManifestPath)
    if(-not [IO.File]::Exists($ManifestPath)){return $false}
    $manifestDirectory=Split-Path -Parent $ManifestPath
    Assert-CcSwitchHarnessRuntimePlainPath -Path $manifestDirectory -Boundary $manifestDirectory
    Assert-CcSwitchHarnessRuntimePlainPath -Path $ManifestPath -Boundary $manifestDirectory
    if((Split-Path -Leaf $ManifestPath) -cne ((Split-Path -Leaf $SlotPath)+'.manifest.json')){throw 'Public slot hash manifest name does not match the version slot.'}
    $manifestItem=Get-Item -LiteralPath $ManifestPath -Force -ErrorAction Stop
    if(($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $manifestItem.Length -gt 33554432){throw 'Public slot hash manifest is a reparse point or exceeds 32 MiB.'}
    $record=[IO.File]::ReadAllText($ManifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    if([int]$record.schema -ne 1 -or [string]$record.package -cne '@anthropic-ai/claude-code' -or [int]$record.fileCount -ne @($record.files).Count){return $false}
    $packageManifestPath=Join-Path $SlotPath 'node_modules\@anthropic-ai\claude-code\package.json'
    if(-not [IO.File]::Exists($packageManifestPath)){return $false}
    $packageManifest=[IO.File]::ReadAllText($packageManifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    if([string]$record.version -cne [string]$packageManifest.version -or [string]$record.version -cne (Split-Path -Leaf $SlotPath) -or (Split-Path -Leaf $ManifestPath) -cne ([string]$record.version+'.manifest.json')){return $false}
    $inventory=Get-CcSwitchManagedHarnessTreeInventory -Path $SlotPath;if([long]$record.byteCount -ne $inventory.ByteCount -or [int]$record.fileCount -ne $inventory.FileCount){return $false};$expected=@{};$actual=@{}
    foreach($file in @($record.files)){$expected[[string]$file.path]=[string]$file.sha256+':'+[string]$file.length}
    foreach($entry in $inventory.Entries){if(-not $entry.Directory){$actual[$entry.Path]=[string]$entry.Hash+':'+[string]$entry.Length}}
    if($expected.Count -ne $actual.Count -or $actual.Count -ne $inventory.FileCount){return $false};foreach($path in $actual.Keys){if(-not $expected.ContainsKey($path) -or $expected[$path] -cne $actual[$path]){return $false}};return $true
}

function Write-CcSwitchManagedClaudeHashManifest {
    param([Parameter(Mandatory=$true)][string]$SlotPath,[Parameter(Mandatory=$true)][string]$ManifestPath,[Parameter(Mandatory=$true)][string]$Version)
    if([IO.File]::Exists($ManifestPath)){throw 'Refusing to replace an existing immutable version manifest.'}
    $inventory=Get-CcSwitchManagedHarnessTreeInventory -Path $SlotPath
    $files=@($inventory.Entries|Where-Object{ -not $_.Directory }|ForEach-Object{[pscustomobject]@{path=$_.Path;length=[long]$_.Length;sha256=[string]$_.Hash}})
    $record=[ordered]@{schema=1;package='@anthropic-ai/claude-code';version=$Version;fileCount=$inventory.FileCount;byteCount=$inventory.ByteCount;files=$files}
    $temporary=$ManifestPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{$json=ConvertTo-Json -InputObject $record -Depth 6;if($json.Length -gt 33554432){throw 'Public slot hash manifest would exceed 32 MiB.'};[IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)));[IO.File]::Move($temporary,$ManifestPath)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Resolve-CcManagedClaudeVersionSlot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$UsbRoot)
    $base = Join-Path (Get-CcSwitchHarnessRuntimeFullPath $UsbRoot) 'tools\harness\claude\slots'
    if (-not [IO.Directory]::Exists($base)) { throw 'No saved public Claude version slots exist.' }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $base -Boundary (Get-CcSwitchHarnessRuntimeFullPath $UsbRoot)
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dir in [IO.Directory]::EnumerateDirectories($base)) {
        $name = Split-Path -Leaf $dir
        if ($name -notmatch '^\d+\.\d+\.\d+$') { continue }
        $parsed = [version]::new()
        if (-not [version]::TryParse($name,[ref]$parsed)) { continue }
        $hashManifest = Join-Path $base ($name + '.manifest.json')
        if (-not [IO.File]::Exists($hashManifest)) { continue }
        $harnessRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $base)) 'claude'
        $check = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harnessRoot -SlotId $name
        if ($check.Valid -and $check.PackageVersion -ceq $name -and (Test-CcSwitchManagedClaudeHashManifest -SlotPath $dir -ManifestPath $hashManifest)) { $candidates.Add([pscustomobject]@{Version=$parsed;Text=$name;Path=$dir}) }
    }
    if (-not $candidates.Count) { throw 'No valid stable Claude version slots exist.' }
    $chosen = @($candidates | Sort-Object Version -Descending)[0]
    return [pscustomobject]@{SlotId=$chosen.Text;Version=$chosen.Text;Path=$chosen.Path;Ready=$true}
}

function Initialize-CcManagedHarnessSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UsbRoot,
        [Parameter(Mandatory=$true)][string]$OwnedRoot,
        [string]$SlotId
    )
    $usb = Get-CcSwitchHarnessRuntimeFullPath $UsbRoot
    $owned = Get-CcSwitchHarnessRuntimeFullPath $OwnedRoot
    $nodeSource = Join-Path $usb 'runtime\node'
    foreach ($source in @($nodeSource)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $source -Boundary $usb }
    if (-not [IO.File]::Exists((Join-Path $nodeSource 'node.exe')) -or -not [IO.File]::Exists((Join-Path $nodeSource 'node_modules\npm\bin\npm-cli.js'))) { throw 'USB Node/npm runtime is incomplete.' }
    $slotsBase=Join-Path $usb 'tools\harness\claude\slots'
    $publishedSlotDirectories=@()
    if([IO.Directory]::Exists($slotsBase)){
        foreach($candidateDirectory in [IO.Directory]::EnumerateDirectories($slotsBase)){
            $candidateName=Split-Path -Leaf $candidateDirectory
            if($candidateName -match '^\d+\.\d+\.\d+$' -and [IO.File]::Exists((Join-Path $slotsBase ($candidateName+'.manifest.json')))){$publishedSlotDirectories+=,$candidateDirectory}
        }
    }
    if($publishedSlotDirectories.Count){$active=Resolve-CcManagedClaudeVersionSlot -UsbRoot $usb;$claudeSource=$active.Path;$SlotId=$active.SlotId}
    else{$claudeSource=Join-Path $usb 'npm-global'}
    Assert-CcSwitchHarnessRuntimePlainPath -Path $claudeSource -Boundary $usb
    $sourceManifest = Join-Path $claudeSource 'node_modules\@anthropic-ai\claude-code\package.json'
    if (-not [IO.File]::Exists($sourceManifest) -or -not [IO.File]::Exists((Join-Path $claudeSource 'claude.cmd'))) { throw 'USB Claude installation is incomplete.' }
    $manifest = [IO.File]::ReadAllText($sourceManifest,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.name -cne '@anthropic-ai/claude-code' -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw 'USB Claude package manifest is not valid.' }
    if ([string]::IsNullOrWhiteSpace($SlotId)) { $SlotId=[string]$manifest.version }
    if ($SlotId -cne [string]$manifest.version) { throw 'Initial slot id must equal the active package version.' }
    $runtimeRoot = Join-Path $owned 'runtime'
    $harnessRoot = Join-Path $owned 'harness'
    $stickRoot = Join-Path $owned 'stick'
    foreach ($path in @($owned,$runtimeRoot,$harnessRoot,$stickRoot)) { Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $owned }
    [IO.Directory]::CreateDirectory((Join-Path $runtimeRoot 'node')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $runtimeRoot 'updates')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $harnessRoot 'updates')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $harnessRoot ('slots\' + $SlotId))) | Out-Null
    [IO.Directory]::CreateDirectory($stickRoot) | Out-Null
    Copy-CcSwitchManagedHarnessTree -Source $nodeSource -Destination (Join-Path $runtimeRoot 'node')
    Copy-CcSwitchManagedHarnessTree -Source $claudeSource -Destination (Join-Path $harnessRoot ('slots\' + $SlotId))
    $null = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $harnessRoot -SlotId $SlotId
    Add-CcSwitchManagedClaudeNpmAdapter -ManagedHarnessRoot $harnessRoot -RuntimeRoot $runtimeRoot -SlotId $SlotId
    return [pscustomobject]@{OwnedRoot=$owned;StickRoot=$stickRoot;RuntimeRoot=$runtimeRoot;ManagedHarnessRoot=$harnessRoot;SlotId=$SlotId;PackageVersion=[string]$manifest.version;Ready=$true}
}

function Copy-CcSwitchManagedHarnessTree {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)
    $sourceFull = Get-CcSwitchHarnessRuntimeFullPath $Source
    $destinationFull = Get-CcSwitchHarnessRuntimeFullPath $Destination
    $sourceInventory = Get-CcSwitchManagedHarnessTreeInventory -Path $sourceFull
    if (Test-Path -LiteralPath $destinationFull) {
        if (@(Get-ChildItem -LiteralPath $destinationFull -Force).Count) { throw 'Refusing to copy over a non-empty managed destination.' }
    } else { [IO.Directory]::CreateDirectory($destinationFull) | Out-Null }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($sourceFull,'*',[IO.SearchOption]::TopDirectoryOnly)) {
        $item = Get-Item -LiteralPath $entry -Force
        $target = Join-Path $destinationFull $item.Name
        if ($item.PSIsContainer) { [IO.Directory]::CreateDirectory($target) | Out-Null; Copy-CcSwitchManagedHarnessTree -Source $item.FullName -Destination $target }
        else { [IO.File]::Copy($item.FullName,$target,$false) }
    }
    $destinationInventory=Get-CcSwitchManagedHarnessTreeInventory -Path $destinationFull
    if($sourceInventory.FileCount -ne $destinationInventory.FileCount -or $sourceInventory.ByteCount -ne $destinationInventory.ByteCount){throw 'Managed harness copy inventory does not match its source.'}
    $expected=@{};foreach($entry in $sourceInventory.Entries){$expected[$entry.Path]=if($entry.Directory){'D'}else{'F'+[string]$entry.Hash+':'+[string]$entry.Length}}
    if($expected.Count -ne $destinationInventory.Entries.Count){throw 'Managed harness copy entry inventory does not match its source.'}
    foreach($entry in $destinationInventory.Entries){$value=if($entry.Directory){'D'}else{'F'+[string]$entry.Hash+':'+[string]$entry.Length};if(-not $expected.ContainsKey($entry.Path) -or $expected[$entry.Path] -cne $value){throw 'Managed harness copy failed path/hash verification.'}}
}

function Get-CcSwitchClaudeSaveBaseline {
    param([Parameter(Mandatory=$true)][string]$UsbRoot)
    $usb = Get-CcSwitchHarnessRuntimeFullPath $UsbRoot
    $slotsBase = Join-Path $usb 'tools\harness\claude\slots'
    $published = $false
    if ([IO.Directory]::Exists($slotsBase)) {
        foreach ($directory in [IO.Directory]::EnumerateDirectories($slotsBase)) {
            $name = Split-Path -Leaf $directory
            if ($name -match '^\d+\.\d+\.\d+$' -and [IO.File]::Exists((Join-Path $slotsBase ($name+'.manifest.json')))) { $published=$true; break }
        }
    }
    if ($published) { $slot=Resolve-CcManagedClaudeVersionSlot -UsbRoot $usb; $path=[string]$slot.Path; $version=[string]$slot.Version }
    else {
        $path=Join-Path $usb 'npm-global'
        $manifestPath=Join-Path $path 'node_modules\@anthropic-ai\claude-code\package.json'
        if (-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists((Join-Path $path 'claude.cmd'))) { throw 'No trusted public Claude baseline is available for save verification.' }
        $manifest=[IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
        if ([string]$manifest.name -cne '@anthropic-ai/claude-code' -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Legacy Claude baseline is not a stable official package.' }
        $version=[string]$manifest.version
    }
    Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $usb
    return [pscustomobject]@{Path=$path;Version=$version}
}

function Test-CcSwitchManagedClaudeTreesIdentical {
    param([Parameter(Mandatory=$true)][string]$Candidate,[Parameter(Mandatory=$true)][string]$Baseline)
    $candidateInfo=Get-CcSwitchManagedHarnessTreeInventory -Path $Candidate
    $baselineInfo=Get-CcSwitchManagedHarnessTreeInventory -Path $Baseline
    if ($candidateInfo.FileCount -ne $baselineInfo.FileCount -or $candidateInfo.ByteCount -ne $baselineInfo.ByteCount -or $candidateInfo.Entries.Count -ne $baselineInfo.Entries.Count) { return $false }
    $expected=@{}
    foreach($entry in $baselineInfo.Entries){$expected[[string]$entry.Path]=if($entry.Directory){'D'}else{'F'+[string]$entry.Hash+':'+[string]$entry.Length}}
    foreach($entry in $candidateInfo.Entries){$value=if($entry.Directory){'D'}else{'F'+[string]$entry.Hash+':'+[string]$entry.Length};if(-not $expected.ContainsKey([string]$entry.Path) -or $expected[[string]$entry.Path] -cne $value){return $false}}
    return $true
}

function Quote-CcSwitchSaveProcessArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value.Contains('"')) { throw 'Save verifier arguments cannot contain quote characters.' }
    return '"'+$Value+'"'
}

function Invoke-CcSwitchPortableClaudeSaveVerifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UsbRoot,
        [Parameter(Mandatory=$true)][string]$OwnedRuntimeRoot,
        [Parameter(Mandatory=$true)][string]$Candidate,
        [Parameter(Mandatory=$true)][string]$Baseline,
        [Parameter(Mandatory=$true)][string]$ExpectedVersion,
        [Parameter(Mandatory=$true)]$ExpectedVolume
    )
    $usb=Get-CcSwitchHarnessRuntimeFullPath $UsbRoot
    $runtime=Get-CcSwitchHarnessRuntimeFullPath $OwnedRuntimeRoot
    $owned=Split-Path -Parent $runtime
    if (-not [string]::Equals($runtime,(Join-Path $owned 'runtime'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Save verifier runtime is outside the exact owned workspace layout.' }
    $node=Join-Path $usb 'runtime\node\node.exe'
    $script=Join-Path $usb 'scripts\cc-switch-verify-claude-save.cjs'
    $installer=Join-Path $usb 'scripts\cc-switch-portable-claude-install.cjs'
    foreach($path in @($node,$script,$installer)){Assert-CcSwitchHarnessRuntimePlainPath -Path $path -Boundary $usb}
    foreach($path in @($node,$script,$installer)){if(-not [IO.File]::Exists($path)){throw 'Save verifier trusted USB runtime file is missing.'}}
    if(-not [IO.Directory]::Exists($Candidate) -or -not [IO.Directory]::Exists($Baseline)){throw 'Save verifier candidate or baseline directory is missing.'}
    if (-not (Test-CcSwitchHarnessRuntimeWithin -Path $Candidate -Root $owned) -or -not (Test-CcSwitchHarnessRuntimeWithin -Path $Baseline -Root $usb)) { throw 'Save verifier candidate or baseline escaped its owned root.' }
    $process=New-Object Diagnostics.Process
    $psi=$process.StartInfo
    $psi.FileName=$node
    $quotedScript=Quote-CcSwitchSaveProcessArgument $script
    $quotedCandidate=Quote-CcSwitchSaveProcessArgument ([IO.Path]::GetFullPath($Candidate))
    $quotedBaseline=Quote-CcSwitchSaveProcessArgument ([IO.Path]::GetFullPath($Baseline))
    $psi.Arguments='--preserve-symlinks --preserve-symlinks-main {0} --candidate {1} --baseline {2}' -f $quotedScript,$quotedCandidate,$quotedBaseline
    $psi.WorkingDirectory=Join-Path $usb 'scripts'
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables.Clear()
    $systemRoot=[string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or -not [IO.Directory]::Exists($systemRoot)) { throw 'SystemRoot is unavailable for save verification.' }
    $psi.EnvironmentVariables['SystemRoot']=$systemRoot
    $psi.EnvironmentVariables['WINDIR']=$systemRoot
    $psi.EnvironmentVariables['PATH']=((Join-Path $usb 'runtime\node')+';'+(Join-Path $systemRoot 'System32'))
    try {
        $volumeAtStart=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if (-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeAtStart)) { throw 'USB volume identity changed before official save verification.' }
        if (-not $process.Start()) { throw 'Save verifier process did not start.' }
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $verifierWaitMilliseconds = 660000
        if (-not $process.WaitForExit($verifierWaitMilliseconds)) {
            try { $process.Kill() } catch { }
            $verifierExitedAfterKill = $false
            try { $verifierExitedAfterKill = $process.WaitForExit(10000) } catch { }
            if (-not $verifierExitedAfterKill) { throw 'Official Claude save verification exceeded 660 seconds and the worker did not exit after termination.' }
            throw 'Official Claude save verification exceeded 660 seconds.'
        }
        $process.WaitForExit()
        $output=[string]$stdoutTask.Result
        $errorOutput=[string]$stderrTask.Result
        if($output.Length -gt 8192){$output=$output.Substring(0,8192)}
        if($errorOutput.Length -gt 8192){$errorOutput=$errorOutput.Substring(0,8192)}
        $output=$output.Trim();$errorOutput=$errorOutput.Trim()
        if ($process.ExitCode -ne 0) { throw ('Official Claude save verification failed: '+$errorOutput) }
        if ($output -cne ('Claude Code '+$ExpectedVersion+' verified for save.')) { throw 'Official Claude save verifier returned an unexpected or incomplete success record.' }
        $volumeAtEnd=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if (-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeAtEnd)) { throw 'USB volume identity changed during official save verification.' }
        return [pscustomobject]@{Verified=$true;Version=$ExpectedVersion;Output=$output}
    } finally { $process.Dispose() }
}

function Save-CcManagedClaudeVersionSlot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$StagedSlotPath,[Parameter(Mandatory=$true)][string]$UsbRoot,[Parameter(Mandatory=$true)]$ExpectedVolume,[switch]$AllowOnlineVerification)
    $staged = Get-CcSwitchHarnessRuntimeFullPath $StagedSlotPath
    $adapterEntries = @([IO.Directory]::EnumerateFileSystemEntries($staged,'*',[IO.SearchOption]::TopDirectoryOnly) | Where-Object { [string]::Equals((Split-Path -Leaf $_),'npm.cmd',[StringComparison]::OrdinalIgnoreCase) })
    if ($adapterEntries.Count) { throw 'Refusing to persist a staging slot while any temporary npm adapter entry is present.' }
    $sourceInfo = Get-CcSwitchManagedHarnessTreeInventory -Path $staged
    $manifestPath = Join-Path $staged 'node_modules\@anthropic-ai\claude-code\package.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'Staged Claude package manifest is missing.' }
    $manifest = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.name -cne '@anthropic-ai/claude-code' -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Staged package is not a stable official Claude Code package.' }
    $version = [string]$manifest.version
    $stageValidationRoot = Split-Path -Parent (Split-Path -Parent $staged)
    $stagedSlotId = Split-Path -Leaf $staged
    $stagedCheck = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $stageValidationRoot -SlotId $stagedSlotId
    if (-not $stagedCheck.Valid -or $stagedCheck.PackageVersion -cne $version -or -not [string]::Equals([IO.Path]::GetFullPath($stagedCheck.SlotPath),$staged,[StringComparison]::OrdinalIgnoreCase)) { throw 'Staged Claude package failed executable/shim/version validation before USB writes.' }
    $usb = Get-CcSwitchHarnessRuntimeFullPath $UsbRoot
    if (-not (Test-Path -LiteralPath $usb -PathType Container)) { throw 'USB root is unavailable.' }
    $volumeAtStart=Get-CcSwitchHarnessVolumeIdentity -Path $usb
    if (-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeAtStart)) { throw 'USB volume identity changed before version-slot commit.' }
    $baseline=Get-CcSwitchClaudeSaveBaseline -UsbRoot $usb
    $treesIdentical=Test-CcSwitchManagedClaudeTreesIdentical -Candidate $staged -Baseline $baseline.Path
    if (-not $treesIdentical) {
        if (-not $AllowOnlineVerification) { throw 'Claude package changed while online official save verification is disabled.' }
        $runtimeRoot=Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $staged))) 'runtime'
        $verification=Invoke-CcSwitchPortableClaudeSaveVerifier -UsbRoot $usb -OwnedRuntimeRoot $runtimeRoot -Candidate $staged -Baseline $baseline.Path -ExpectedVersion $version -ExpectedVolume $ExpectedVolume
        if (-not $verification.Verified -or $verification.Version -cne $version) { throw 'Official Claude save verifier did not validate the staged version.' }
    }
    $publicRoot = Join-Path $usb 'tools\harness\claude\slots'
    Assert-CcSwitchHarnessRuntimePlainPath -Path $publicRoot -Boundary $usb
    [IO.Directory]::CreateDirectory($publicRoot) | Out-Null
    $final = Join-Path $publicRoot $version
    $sidecar = Join-Path $publicRoot ($version + '.manifest.json')
    if (Test-Path -LiteralPath $final) {
        $existing = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot (Split-Path -Parent $publicRoot) -SlotId $version
        if (-not $existing.Valid -or $existing.PackageVersion -cne $version) { throw 'A conflicting version slot already exists; it will not be overwritten.' }
        $existingInfo=Get-CcSwitchManagedHarnessTreeInventory -Path $final
        $same=$existingInfo.FileCount -eq $sourceInfo.FileCount -and $existingInfo.ByteCount -eq $sourceInfo.ByteCount
        $sourceHashes=@{};foreach($item in $sourceInfo.Entries){if(-not $item.Directory){$sourceHashes[$item.Path]=[string]$item.Hash+':'+[string]$item.Length}}
        foreach($item in $existingInfo.Entries){if(-not $item.Directory -and (-not $sourceHashes.ContainsKey($item.Path) -or $sourceHashes[$item.Path] -cne ([string]$item.Hash+':'+[string]$item.Length))){$same=$false}}
        if(-not $same){throw 'The same version already exists with different content; refusing overwrite.'}
        if([IO.File]::Exists($sidecar)) { if(-not (Test-CcSwitchManagedClaudeHashManifest -SlotPath $final -ManifestPath $sidecar)){throw 'Existing version hash manifest conflicts with its files.'} }
        else { Write-CcSwitchManagedClaudeHashManifest -SlotPath $final -ManifestPath $sidecar -Version $version }
        $volumeAtEnd=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if(-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeAtEnd)){throw 'USB volume identity changed during idempotent slot verification.'}
        return [pscustomobject]@{Saved=$false;AlreadyPresent=$true;Version=$version;Path=$final;FileCount=$sourceInfo.FileCount;ByteCount=$sourceInfo.ByteCount;ManifestPath=$sidecar}
    }
    $tempRoot = Join-Path $publicRoot ('.incoming-' + [guid]::NewGuid().ToString('N'))
    $temp = Join-Path $tempRoot ('slots\' + $version)
    try {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $temp)) | Out-Null
        Copy-CcSwitchManagedHarnessTree -Source $staged -Destination $temp
        $copied = Get-CcSwitchManagedHarnessTreeInventory -Path $temp
        if ($copied.FileCount -ne $sourceInfo.FileCount -or $copied.ByteCount -ne $sourceInfo.ByteCount -or $copied.Entries.Count -ne $sourceInfo.Entries.Count) { throw 'USB copy inventory differs from the staged package.' }
        $sourceEntries = @{}; foreach ($item in $sourceInfo.Entries) { $sourceEntries[[string]$item.Path] = if ($item.Directory) { 'D' } else { 'F'+[string]$item.Hash+':'+[string]$item.Length } }
        foreach ($item in $copied.Entries) { $value = if ($item.Directory) { 'D' } else { 'F'+[string]$item.Hash+':'+[string]$item.Length }; if (-not $sourceEntries.ContainsKey([string]$item.Path) -or $sourceEntries[[string]$item.Path] -cne $value) { throw 'USB copy path/hash inventory differs from the staged package.' } }
        $verified = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $tempRoot -SlotId $version
        if (-not $verified.Valid -or $verified.PackageVersion -cne $version) { throw 'Copied incoming slot failed package validation.' }

        $volumeBeforeManifest=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if(-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeBeforeManifest)){throw 'USB volume identity changed before version manifest preparation.'}
        if([IO.File]::Exists($sidecar)) {
            if(-not (Test-CcSwitchManagedClaudeHashManifest -SlotPath $temp -ManifestPath $sidecar)){throw 'An orphan or existing version manifest conflicts with the staged package; it will not be replaced.'}
        } else {
            try { Write-CcSwitchManagedClaudeHashManifest -SlotPath $temp -ManifestPath $sidecar -Version $version }
            catch {
                if (-not [IO.File]::Exists($sidecar) -or -not (Test-CcSwitchManagedClaudeHashManifest -SlotPath $temp -ManifestPath $sidecar)) { throw }
            }
        }
        if(-not (Test-CcSwitchManagedClaudeHashManifest -SlotPath $temp -ManifestPath $sidecar)){throw 'Prepared version manifest does not verify the incoming package.'}

        $volumeBeforeCommit=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if(-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeBeforeCommit)){throw 'USB volume identity changed before public slot publish.'}
        if (Test-Path -LiteralPath $final) { throw 'A version slot appeared during commit; retry after verifying the existing publication.' }
        [IO.Directory]::Move($temp,$final)
        $volumeAfterCommit=Get-CcSwitchHarnessVolumeIdentity -Path $usb
        if(-not (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeAfterCommit)){throw 'USB volume identity changed during public slot commit.'}
        try {
            $cleanupVolume=Get-CcSwitchHarnessVolumeIdentity -Path $usb
            if (Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $cleanupVolume) {
                $incomingSlots=Join-Path $tempRoot 'slots'
                if ([IO.Directory]::Exists($incomingSlots) -and @([IO.Directory]::EnumerateFileSystemEntries($incomingSlots)).Count -eq 0) { [IO.Directory]::Delete($incomingSlots,$false) }
                if ([IO.Directory]::Exists($tempRoot) -and @([IO.Directory]::EnumerateFileSystemEntries($tempRoot)).Count -eq 0) { [IO.Directory]::Delete($tempRoot,$false) }
            }
        } catch { }
        return [pscustomobject]@{Saved=$true;AlreadyPresent=$false;Version=$version;Path=$final;FileCount=$copied.FileCount;ByteCount=$copied.ByteCount;ManifestPath=$sidecar}
    } catch {
        $cleanupSafe=$false
        try { $volumeForCleanup=Get-CcSwitchHarnessVolumeIdentity -Path $usb; $cleanupSafe=Test-CcSwitchHarnessVolumeIdentity -Expected $ExpectedVolume -Actual $volumeForCleanup } catch { $cleanupSafe=$false }
        if ($cleanupSafe -and (Test-Path -LiteralPath $tempRoot)) { $null = Get-CcSwitchManagedHarnessTreeInventory -Path $tempRoot; Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop }
        throw
    }
}

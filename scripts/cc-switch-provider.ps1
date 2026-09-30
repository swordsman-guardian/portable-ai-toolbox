[CmdletBinding()]
param()

function Get-ToolboxSettingsPath {
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $root = [IO.Path]::GetFullPath($StickRoot)
    if (-not [string]::Equals($root, [IO.Path]::GetPathRoot($root), [StringComparison]::OrdinalIgnoreCase)) { $root = $root.TrimEnd('\', '/') }
    return Join-Path $root 'config\settings.json'
}

function Assert-ToolboxProviderPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $cursor = $root
    $tail = $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($part in $tail) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'CC Switch Claude settings path contains a reparse point.' }
        }
    }
}

function Get-ToolboxCcSwitchClaudeMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $path = Get-ToolboxSettingsPath -StickRoot $StickRoot
    Assert-ToolboxProviderPath -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'settings.json root must be a JSON object.' }
    $document = $raw | ConvertFrom-Json -ErrorAction Stop
    $raw = $null
    if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'settings.json root must be a JSON object.' }
    $property = $document.PSObject.Properties['ccSwitchClaudeProvider']
    if (-not $property) { return $false }
    if ($property.Value -isnot [bool]) { throw 'settings.json ccSwitchClaudeProvider must be a JSON boolean.' }
    return [bool]$property.Value
}

function Set-ToolboxCcSwitchClaudeMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $path = Get-ToolboxSettingsPath -StickRoot $StickRoot
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The toolbox config directory must exist before changing provider mode.' }
    Assert-ToolboxProviderPath -Path $parent
    $lockPath = $path + '.lock'
    Assert-ToolboxProviderPath -Path $lockPath
    $lock = $null
    $temp = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $lock -and (Get-Date) -lt $deadline) {
        try { $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if (-not $lock) { throw 'Unable to acquire settings.json write lock.' }
    try {
        Assert-ToolboxProviderPath -Path $path
        $document = [pscustomobject]@{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'settings.json root must be a JSON object.' }
            $document = $raw | ConvertFrom-Json -ErrorAction Stop
            $raw = $null
            if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'settings.json root must be a JSON object.' }
        }
        $unifiedProperty=$document.PSObject.Properties['ccSwitchUnifiedConfig']
        if ($unifiedProperty -and $unifiedProperty.Value -isnot [bool]) { throw 'settings.json ccSwitchUnifiedConfig must be a JSON boolean.' }
        if ($unifiedProperty -and $unifiedProperty.Value -and -not $Enabled) { throw 'Unified configuration mode cannot switch back to a legacy provider source.' }
        $document | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue ([bool]$Enabled) -Force
        $strays = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop | Where-Object { $_.Name -like 'settings.json.*.tmp' -or $_.Name -like 'settings.json.*.bak' })
        if ($strays.Count -gt 0) { throw 'Unfinished settings transaction files were found; inspect them before changing provider mode.' }
        $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, ($document | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($false)))
        Assert-ToolboxProviderPath -Path $temp
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $backup = $path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
            Assert-ToolboxProviderPath -Path $backup
            $newHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256 -ErrorAction Stop).Hash
            [IO.File]::Move($path, $backup)
            try {
                [IO.File]::Move($temp, $path)
                $verify = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $verify -or $verify.ccSwitchClaudeProvider -isnot [bool] -or $verify.ccSwitchClaudeProvider -ne $Enabled) { throw 'settings.json transaction verification failed.' }
                Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
            } catch {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Assert-ToolboxProviderPath -Path $path
                    $currentHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($currentHash -ne $newHash) { throw 'Settings update failed and the current file was not created by this operation; original backup was retained.' }
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
                if ((Test-Path -LiteralPath $backup -PathType Leaf) -and -not (Test-Path -LiteralPath $path)) {
                    Assert-ToolboxProviderPath -Path $backup
                    Assert-ToolboxProviderPath -Path $path
                    [IO.File]::Move($backup, $path)
                }
                throw
            }
        } else {
            $newHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256 -ErrorAction Stop).Hash
            [IO.File]::Move($temp, $path)
            try {
                $verify = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $verify -or $verify.ccSwitchClaudeProvider -isnot [bool] -or $verify.ccSwitchClaudeProvider -ne $Enabled) { throw 'settings.json transaction verification failed.' }
            } catch {
                Assert-ToolboxProviderPath -Path $path
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -eq $newHash) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                } else { throw 'Settings creation failed; the current file was not created by this operation and was retained.' }
                throw
            }
        }
        $temp = $null
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        $lock.Dispose()
    }
}

function Test-ToolboxCcEncryptedStorePresent {
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    $path = Join-Path ([IO.Path]::GetFullPath($StickRoot)) 'config\cc-switch\secure-store'
    Assert-ToolboxProviderPath -Path $path
    # Even a partial or damaged store blocks the old plaintext fallback.
    return [bool](Test-Path -LiteralPath $path)
}

function Get-ToolboxCcSwitchClaudeProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StickRoot)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $root = [IO.Path]::GetFullPath($StickRoot)
    if (-not [string]::Equals($root, [IO.Path]::GetPathRoot($root), [StringComparison]::OrdinalIgnoreCase)) { $root = $root.TrimEnd('\', '/') }
    $path = Join-Path $root 'harness\cc-switch\claude\settings.json'
    Assert-ToolboxProviderPath -Path $root
    if (Test-ToolboxCcEncryptedStorePresent -StickRoot $root) {
        try {
            . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $root
            return Get-CcSecureSessionClaudeProvider -StickRoot $root
        }
        catch { throw 'CC Switch encrypted session is locked or unavailable. Open and unlock it from the CC Switch menu; plaintext fallback is disabled.' }
    }
    Assert-ToolboxProviderPath -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'CC Switch Claude settings.json is missing from the fixed USB profile path.' }
    $reader = Join-Path $PSScriptRoot 'cc-switch.ps1'
    return & $reader -Action ReadClaudeProfile -ProfilePath $path -ProfileName 'CC Switch current Claude provider'
}

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-CcSwitchUnifiedMode -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cc-switch-unified-mode.ps1') }
if (-not (Get-Command Get-CcSecureSessionStatus -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') }
if (-not (Get-Command Get-CcEncryptedStoreStatus -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1') }

$cleanupCacheVariable = Get-Variable -Name CcSwitchLegacyCleanupPlanCache -Scope Script -ErrorAction SilentlyContinue
if (-not $cleanupCacheVariable) { Set-Variable -Name CcSwitchLegacyCleanupPlanCache -Scope Script -Value @{} }

function Get-CcLegacyCleanupHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Assert-CcLegacyCleanupPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string[]]$AllowedPaths
    )
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($StickRoot)
    $rootVolume = [IO.Path]::GetPathRoot($root)
    $isAllowed = $false
    foreach ($allowedPath in $AllowedPaths) {
        if ([string]::Equals([IO.Path]::GetFullPath($allowedPath),$full,[StringComparison]::OrdinalIgnoreCase)) { $isAllowed = $true; break }
    }
    if (-not $isAllowed) {
        throw 'Cleanup target is outside the exact allowlist.'
    }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cleanup paths may not contain reparse points.' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if (-not $parent) { break }
        $cursor = $parent.FullName
    }
    if (-not [string]::Equals([IO.Path]::GetPathRoot($full),$rootVolume,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup target resolved to a different volume.'
    }
    return $full
}

function Test-CcLegacyCleanupJsonEqual {
    param($Left,$Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left -is [pscustomobject] -or $Right -is [pscustomobject]) {
        if ($Left -isnot [pscustomobject] -or $Right -isnot [pscustomobject]) { return $false }
        $leftNames = @($Left.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $rightNames = @($Right.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        if ($leftNames.Count -ne $rightNames.Count) { return $false }
        for ($i = 0; $i -lt $leftNames.Count; $i++) {
            if ($leftNames[$i] -cne $rightNames[$i]) { return $false }
            if (-not (Test-CcLegacyCleanupJsonEqual $Left.PSObject.Properties[$leftNames[$i]].Value $Right.PSObject.Properties[$rightNames[$i]].Value)) { return $false }
        }
        return $true
    }
    if ($Left -is [System.Collections.IDictionary] -or $Right -is [System.Collections.IDictionary]) {
        if ($Left -isnot [System.Collections.IDictionary] -or $Right -isnot [System.Collections.IDictionary]) { return $false }
        if ($Left.Count -ne $Right.Count) { return $false }
        foreach ($key in $Left.Keys) { if (-not $Right.Contains($key) -or -not (Test-CcLegacyCleanupJsonEqual $Left[$key] $Right[$key])) { return $false } }
        return $true
    }
    if ($Left -is [System.Array] -or $Right -is [System.Array]) {
        if ($Left -isnot [System.Array] -or $Right -isnot [System.Array] -or $Left.Length -ne $Right.Length) { return $false }
        for ($i = 0; $i -lt $Left.Length; $i++) { if (-not (Test-CcLegacyCleanupJsonEqual $Left[$i] $Right[$i])) { return $false } }
        return $true
    }
    if ($Left -is [string] -or $Right -is [string]) { return ($Left -is [string] -and $Right -is [string] -and [string]::Equals($Left,$Right,[StringComparison]::Ordinal)) }
    if ($Left -is [bool] -or $Right -is [bool]) { return ($Left -is [bool] -and $Right -is [bool] -and $Left -eq $Right) }
    if ($Left -is [ValueType] -or $Right -is [ValueType]) { return ($Left.GetType() -eq $Right.GetType() -and $Left -eq $Right) }
    return $false
}

function Read-CcLegacyCleanupKeys {
    param([Parameter(Mandatory)][string]$Path)
    $info = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($info.Length -gt 1MB) { throw 'Legacy keys file exceeds the fixed size limit.' }
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    $reader = New-Object IO.StreamReader($Path,$encoding,$true)
    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $text = $line.Trim()
            if (-not $text -or $text.StartsWith('#',[StringComparison]::Ordinal)) { continue }
            $equals = $text.IndexOf('=')
            if ($equals -lt 1) { throw 'Legacy keys file has an unsupported line.' }
            $name = $text.Substring(0,$equals).Trim()
            $value = $text.Substring($equals+1).Trim()
            if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x1f]' -or $values.ContainsKey($name)) {
                throw 'Legacy keys file has an invalid or duplicate credential entry.'
            }
            $values.Add($name,$value)
        }
    } finally { $reader.Dispose() }
    return $values
}

function Get-CcLegacyCleanupJsonFile {
    param([Parameter(Mandatory)][string]$Path,[long]$MaximumBytes=1048576)
    $info = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($info.Length -gt $MaximumBytes) { throw 'Legacy configuration exceeds the fixed size limit.' }
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    $text = [IO.File]::ReadAllText($Path,$encoding)
    try {
        $document = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'Legacy JSON must be an object.' }
        return $document
    } finally { $text = $null }
}

function Get-CcLegacyCleanupSettingsFromBundle {
    param([Parameter(Mandatory)]$Bundle)
    $files = @($Bundle.LaunchFiles | Where-Object { [string]$_.Path -ceq 'settings.json' })
    if ($files.Count -ne 1) { throw 'The encrypted snapshot has no unique Claude settings.json.' }
    $bytes = $null
    $text = $null
    try {
        $bytes = [Convert]::FromBase64String([string]$files[0].ContentBase64)
        if ($bytes.Length -gt 1MB) { throw 'Encrypted Claude settings exceed the fixed size limit.' }
        $encoding = New-Object Text.UTF8Encoding($false,$true)
        $text = $encoding.GetString($bytes)
        $settings = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $settings -or $settings -isnot [pscustomobject] -or -not $settings.env -or $settings.env -isnot [pscustomobject]) { throw 'Encrypted Claude settings have an unsupported shape.' }
        return $settings
    } finally {
        $text = $null
        if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
    }
}

function New-CcSwitchLegacyPlaintextCleanupInternalPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot)
    $root = [IO.Path]::GetFullPath($StickRoot)
    $paths = [ordered]@{
        'keys.env'=(Join-Path $root 'config\keys.env')
        'providers.json'=(Join-Path $root 'harness\providers.json')
        'claude/settings.json'=(Join-Path $root 'config\claude\settings.json')
    }
    $sourceHashes = @{}
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $provider = $null
    $bundle = $null
    $secretPointer = [IntPtr]::Zero
    $plainSecret = $null
    $keys = $null
    try {
        if (-not (Get-CcSwitchUnifiedMode -StickRoot $root)) { throw 'Legacy cleanup requires unified CC Switch mode to be active.' }
        $sessionStatus = Get-CcSecureSessionStatus -StickRoot $root
        if (-not $sessionStatus.Unlocked -or [string]$sessionStatus.LastSaveStatus -cne 'Saved') { throw 'Legacy cleanup requires an unlocked broker with a saved snapshot.' }
        $storeStatus = Get-CcEncryptedStoreStatus -StickRoot $root
        if (-not $storeStatus.CurrentRevision) { throw 'Legacy cleanup requires a committed encrypted snapshot.' }
        foreach ($label in $paths.Keys) {
            $full = Assert-CcLegacyCleanupPath -Path $paths[$label] -StickRoot $root -AllowedPaths @($paths.Values)
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'A required legacy source file is missing; cleanup is blocked.' }
            $sourceHashes[$label] = Get-CcLegacyCleanupHash -Path $full
            $targets.Add([pscustomobject]@{Path=$full;Label=$label;Length=[long](Get-Item -LiteralPath $full -Force).Length;Hash=$sourceHashes[$label];Kind='LegacySource'})
        }

        $keys = Read-CcLegacyCleanupKeys -Path $paths['keys.env']
        if ($keys.Count -ne 1) { throw 'Legacy keys file contains more than the single expected credential; cleanup is blocked.' }
        $providerDocument = Get-CcLegacyCleanupJsonFile -Path $paths['providers.json'] -MaximumBytes 2MB
        $toolSettings = Get-CcLegacyCleanupJsonFile -Path (Join-Path $root 'config\settings.json') -MaximumBytes 1MB
        if ($providerDocument.providers -isnot [System.Array] -or $null -eq $providerDocument.providers) { throw 'Legacy provider list has an unsupported shape.' }
        $enabled = @($providerDocument.providers | Where-Object { $_.enabled -eq $true })
        if ($providerDocument.providers.Count -ne 1 -or $enabled.Count -ne 1) { throw 'Legacy cleanup currently requires exactly one provider record, and it must be enabled.' }
        $legacyProvider = $enabled[0]
        $provider = $legacyProvider
        $allowedFields = @('id','name','enabled','baseUrl','apikeyEnv','models','extraEnv','verified','notes')
        foreach ($property in $provider.PSObject.Properties) { if ($property.Name -notin $allowedFields) { throw 'The enabled legacy provider has an unknown field; cleanup is blocked.' } }
        foreach ($required in @('id','name','enabled','baseUrl','apikeyEnv','models','extraEnv')) { if (-not $provider.PSObject.Properties[$required]) { throw 'The enabled legacy provider is incomplete.' } }
        if ($provider.id -isnot [string] -or [string]::IsNullOrWhiteSpace($provider.id) -or $provider.name -isnot [string] -or [string]::IsNullOrWhiteSpace($provider.name) -or $provider.enabled -isnot [bool]) { throw 'The enabled legacy provider has invalid identity fields.' }
        if ($provider.models -isnot [pscustomobject] -or $provider.extraEnv -isnot [pscustomobject]) { throw 'The enabled provider model maps have unsupported shapes.' }
        if ($providerDocument.default -isnot [string] -or $toolSettings.provider -isnot [string] -or $providerDocument.default -cne $provider.id -or $toolSettings.provider -cne $provider.id) { throw 'Legacy default/current provider selection does not uniquely match the enabled provider.' }
        if ($provider.apikeyEnv -isnot [string] -or -not $keys.ContainsKey([string]$provider.apikeyEnv)) { throw 'The enabled provider credential is not the sole legacy key.' }
        $legacySecret = [string]$keys[[string]$provider.apikeyEnv]
        if ([string]::IsNullOrWhiteSpace($legacySecret) -or $legacySecret -match '[\x00-\x1f]' -or $legacySecret -match '(?i)placeholder|your.?key|在这里填|<.*>' -or $legacySecret -match '^(?i:PROXY_MANAGED)$') { throw 'The sole legacy credential is not a valid direct secret.' }
        foreach ($field in @('verified','notes')) {
            if ($provider.PSObject.Properties[$field] -and $provider.$field -isnot [string]) { throw 'Enabled provider metadata has an unsupported type.' }
        }
        $registryPath = Join-Path $root 'harness\registry.json'
        if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'The harness registry is missing.' }
        $registry = Get-CcLegacyCleanupJsonFile -Path $registryPath -MaximumBytes 1MB
        $claudeRows = @($registry.harnesses | Where-Object { $_.id -ceq 'claude' -and $_.enabled -eq $true })
        if ($claudeRows.Count -ne 1 -or -not $claudeRows[0].providerEnv) { throw 'The Claude environment mapping is missing or ambiguous.' }
        $baseEnvName = [string]$claudeRows[0].providerEnv.baseUrl
        $authEnvName = [string]$claudeRows[0].providerEnv.apiKey
        if ($baseEnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or $authEnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') { throw 'The Claude environment mapping is invalid.' }

        $oldClaudeSettings = Get-CcLegacyCleanupJsonFile -Path $paths['claude/settings.json'] -MaximumBytes 1MB
        if ($oldClaudeSettings.env -isnot [pscustomobject]) { throw 'Legacy Claude settings has no valid env object.' }
        if (-not (Get-CcSwitchUnifiedMode -StickRoot $root)) { throw 'Unified mode changed during cleanup validation.' }
        $bundle = Get-CcSecureSessionClaudeLaunchBundle -StickRoot $root
        if ([string]$bundle.Revision -cne [string]$storeStatus.CurrentRevision) { throw 'The broker bundle revision differs from the encrypted current snapshot.' }
        $afterStatus = Get-CcSecureSessionStatus -StickRoot $root
        if (-not $afterStatus.Unlocked -or [string]$afterStatus.LastSaveStatus -cne 'Saved' -or -not (Get-CcSwitchUnifiedMode -StickRoot $root)) { throw 'The broker is no longer in a saved unified state.' }
        $provider = $bundle.Provider
        if (-not $provider -or
            [string]$provider.AuthEnvironmentName -cne $authEnvName -or
            [string]::IsNullOrWhiteSpace([string]$provider.BaseUrl) -or
            -not ($provider.Secret -is [Security.SecureString]) -or $provider.Secret.Length -eq 0) {
            throw 'The encrypted current Claude provider does not exactly identify the sole enabled legacy provider.'
        }
        $sourceUri=$null;$currentUri=$null
        if (-not [Uri]::TryCreate([string]$enabled[0].baseUrl,[UriKind]::Absolute,[ref]$sourceUri) -or
            -not [Uri]::TryCreate([string]$provider.BaseUrl,[UriKind]::Absolute,[ref]$currentUri) -or
            -not [string]::Equals($sourceUri.GetLeftPart([UriPartial]::Path).TrimEnd('/'),$currentUri.GetLeftPart([UriPartial]::Path).TrimEnd('/'),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'The encrypted current Claude URL does not match the sole enabled legacy provider.'
        }
        $secretPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($provider.Secret)
        $plainSecret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        if (-not [string]::Equals($plainSecret,$keys[[string]$legacyProvider.apikeyEnv],[StringComparison]::Ordinal)) { throw 'The encrypted Claude credential does not match the only legacy key.' }

        $launchSettings = Get-CcLegacyCleanupSettingsFromBundle -Bundle $bundle
        $launchEnv = $launchSettings.env
        if (-not $launchEnv.PSObject.Properties[$baseEnvName] -or -not $launchEnv.PSObject.Properties[$authEnvName] -or
            [string]$launchEnv.PSObject.Properties[$baseEnvName].Value -cne [string]$enabled[0].baseUrl -or
            -not [string]::Equals([string]$launchEnv.PSObject.Properties[$authEnvName].Value,$plainSecret,[StringComparison]::Ordinal)) {
            throw 'The encrypted launch settings do not contain the selected provider URL and credential.'
        }
        $owned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        [void]$owned.Add($baseEnvName);[void]$owned.Add($authEnvName)
        $providerModels = $provider.Models
        if ($providerModels -isnot [System.Collections.IDictionary]) { throw 'The encrypted current provider models map has an unsupported shape.' }
        if ($providerModels.Count -ne @($enabled[0].models.PSObject.Properties).Count) { throw 'Not every legacy model entry is present in the encrypted current provider.' }
        foreach ($entry in $enabled[0].models.PSObject.Properties) {
            [void]$owned.Add($entry.Name)
            if (-not $providerModels.Contains($entry.Name) -or $providerModels[$entry.Name] -isnot [string] -or $providerModels[$entry.Name] -cne [string]$entry.Value -or
                -not $launchEnv.PSObject.Properties[$entry.Name] -or $launchEnv.PSObject.Properties[$entry.Name].Value -cne [string]$entry.Value) { throw 'A legacy provider model setting is not fully covered by the encrypted snapshot.' }
        }
        foreach ($entry in $enabled[0].extraEnv.PSObject.Properties) {
            [void]$owned.Add($entry.Name)
            if ($entry.Value -isnot [string] -or -not $launchEnv.PSObject.Properties[$entry.Name] -or $launchEnv.PSObject.Properties[$entry.Name].Value -cne [string]$entry.Value) { throw 'A legacy provider extraEnv setting is not fully covered by the encrypted launch settings.' }
        }
        foreach ($oldEntry in $oldClaudeSettings.env.PSObject.Properties) {
            if ($owned.Contains($oldEntry.Name)) { continue }
            if (-not $launchEnv.PSObject.Properties[$oldEntry.Name] -or -not (Test-CcLegacyCleanupJsonEqual $oldEntry.Value $launchEnv.PSObject.Properties[$oldEntry.Name].Value)) { throw 'A non-provider Claude setting is not covered by the encrypted launch configuration.' }
        }
        foreach ($oldEntry in $oldClaudeSettings.PSObject.Properties) {
            if ($oldEntry.Name -ceq 'env') { continue }
            if (-not $launchSettings.PSObject.Properties[$oldEntry.Name] -or -not (Test-CcLegacyCleanupJsonEqual $oldEntry.Value $launchSettings.PSObject.Properties[$oldEntry.Name].Value)) { throw 'A Claude settings field is not covered by the encrypted launch configuration.' }
        }

        $allowedPaths = @($paths.Values)
        foreach ($label in $paths.Keys) {
            $basePath = [IO.Path]::GetFullPath($paths[$label])
            foreach ($suffix in @('.bak','.backup')) {
                $backupPath = $basePath + $suffix
                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { continue }
                $backupFull = Assert-CcLegacyCleanupPath -Path $backupPath -StickRoot $root -AllowedPaths (@($allowedPaths) + @($backupPath))
                $backupHash = Get-CcLegacyCleanupHash $backupFull
                if ($backupHash -cne $sourceHashes[$label]) { throw 'A sibling backup is not byte-identical to its source; cleanup is blocked.' }
                $targets.Add([pscustomobject]@{Path=$backupFull;Label=$label;Length=[long](Get-Item -LiteralPath $backupFull -Force).Length;Hash=$backupHash;Kind='ExactSiblingBackup'})
            }
        }
        # Hash the complete allowlisted input set again after parsing and broker validation.
        foreach ($label in $paths.Keys) { if ((Get-CcLegacyCleanupHash $paths[$label]) -cne $sourceHashes[$label]) { throw 'A legacy source changed during cleanup validation.' } }
        foreach ($target in $targets) {
            $allowed = @($paths.Values) + @($targets | ForEach-Object { $_.Path })
            $target.Path = Assert-CcLegacyCleanupPath -Path $target.Path -StickRoot $root -AllowedPaths $allowed
            if ((Get-CcLegacyCleanupHash $target.Path) -cne $target.Hash) { throw 'A cleanup target changed during validation.' }
        }
        return [pscustomobject]@{StickRoot=$root;Revision=[string]$bundle.Revision;Targets=$targets.ToArray();SourceHashes=$sourceHashes}
    } finally {
        if ($secretPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer) }
        $plainSecret = $null
        if ($keys) { $keys.Clear() }
        if ($bundle -and $bundle.Provider -and $bundle.Provider.Secret) { $bundle.Provider.Secret.Dispose() }
    }
}

function Get-CcSwitchLegacyPlaintextCleanupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot)
    $internal = New-CcSwitchLegacyPlaintextCleanupInternalPlan -StickRoot $StickRoot
    $id = [guid]::NewGuid().ToString('N')
    $visibleTargets = @($internal.Targets | ForEach-Object { [pscustomobject]@{Path=$_.Path;Length=$_.Length;Kind=$_.Kind} })
    $script:CcSwitchLegacyCleanupPlanCache[$id] = $internal
    return [pscustomobject]@{Version=1;PlanId=$id;StickRoot=$internal.StickRoot;Revision=$internal.Revision;Targets=$visibleTargets;ProviderCoverageVerified=$true;CredentialCoverageVerified=$true;ClaudeSettingsCoverageVerified=$true;UnifiedModeVerified=$true;BrokerSavedVerified=$true}
}

function Remove-CcSwitchLegacyPlaintextFiles {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Plan)
    if ($Plan.Version -ne 1 -or -not $script:CcSwitchLegacyCleanupPlanCache.ContainsKey([string]$Plan.PlanId)) { throw 'A live in-process cleanup plan is required.' }
    $original = $script:CcSwitchLegacyCleanupPlanCache[[string]$Plan.PlanId]
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Plan.StickRoot),[string]$original.StickRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup plan root changed.' }
    $fresh = New-CcSwitchLegacyPlaintextCleanupInternalPlan -StickRoot $original.StickRoot
    $preservePlan = $false
    try {
        if ([string]$fresh.Revision -cne [string]$original.Revision -or $fresh.Targets.Count -ne $original.Targets.Count) { throw 'Cleanup plan is stale; review a new plan.' }
        foreach ($label in $original.SourceHashes.Keys) { if ($fresh.SourceHashes[$label] -cne $original.SourceHashes[$label]) { throw 'A legacy source changed after planning; no files were removed.' } }
        $originalByPath=@{};foreach($item in $original.Targets){$originalByPath[[IO.Path]::GetFullPath($item.Path)]=$item}
        foreach ($item in $fresh.Targets) {
            $key=[IO.Path]::GetFullPath($item.Path)
            if (-not $originalByPath.ContainsKey($key) -or $originalByPath[$key].Length -ne $item.Length -or $originalByPath[$key].Hash -cne $item.Hash) { throw 'Cleanup target set changed after planning; no files were removed.' }
        }
        # Delete byte-identical copies first, then the three primary files.
        $ordered = @($fresh.Targets | Sort-Object @{Expression={if($_.Kind -eq 'LegacySource'){1}else{0}}},Path)
        $removed = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $ordered) {
            $full = Assert-CcLegacyCleanupPath -Path $item.Path -StickRoot $original.StickRoot -AllowedPaths (@($fresh.Targets | ForEach-Object {$_.Path}))
            if (-not [IO.File]::Exists($full) -or (Get-CcLegacyCleanupHash $full) -cne $item.Hash) { throw 'A cleanup target changed immediately before deletion; remaining files were kept.' }
        }
        foreach ($item in $ordered) {
            $full = Assert-CcLegacyCleanupPath -Path $item.Path -StickRoot $original.StickRoot -AllowedPaths (@($fresh.Targets | ForEach-Object {$_.Path}))
            if ((Get-CcLegacyCleanupHash $full) -cne $item.Hash) { throw 'A cleanup target changed immediately before deletion; remaining files were kept.' }
            if ($PSCmdlet.ShouldProcess($full,'Delete exact verified legacy plaintext file')) {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                if ([IO.File]::Exists($full)) { throw 'A verified cleanup target could not be removed.' }
                $removed.Add($full)
            } else {
                $preservePlan = $true
            }
        }
        if (-not $preservePlan) { $script:CcSwitchLegacyCleanupPlanCache.Remove([string]$Plan.PlanId) }
        return [pscustomobject]@{RemovedCount=$removed.Count;RemovedPaths=$removed.ToArray();Revision=$fresh.Revision;WhatIfOnly=($WhatIfPreference -or $removed.Count -eq 0)}
    } finally {
        $fresh.SourceHashes.Clear()
        if (-not $preservePlan) { $original.SourceHashes.Clear();$script:CcSwitchLegacyCleanupPlanCache.Remove([string]$Plan.PlanId) }
    }
}

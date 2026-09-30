# One-time stopped-session import of the currently selected toolbox Claude
# providers into the authenticated CC Switch v19 database snapshot.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')

function Get-CcToolboxMigrationFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-CcToolboxMigrationNoReparse {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Migration paths may not contain reparse points.' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if (-not $parent) { break }
        $cursor = $parent.FullName
    }
}

function New-CcToolboxMigrationStage {
    param([Parameter(Mandatory)][string]$Prefix)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    Assert-CcToolboxMigrationNoReparse $tempRoot
    $driveRoot = [IO.Path]::GetPathRoot($tempRoot)
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $driveRoot.TrimEnd('\') + "'") -ErrorAction Stop
    if ($volume.DriveType -ne 3 -or $volume.FileSystem -ne 'NTFS') { throw 'Migration staging requires a fixed NTFS temporary directory.' }
    $path = Join-Path $tempRoot ($Prefix + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    [IO.Directory]::SetAccessControl($path,$acl)
    Assert-CcToolboxMigrationNoReparse $path
    return $path
}

function Quote-CcToolboxMigrationArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-CcToolboxMigrationHelper {
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][ValidateSet('inspect','apply','verify')][string]$Action,
        [Parameter(Mandatory)][string]$DatabasePath,
        [string]$InputJson
    )
    Assert-CcToolboxMigrationNoReparse $PythonExe
    Assert-CcToolboxMigrationNoReparse $HelperPath
    Assert-CcToolboxMigrationNoReparse $DatabasePath
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonExe
    $psi.Arguments = (@('-I',$HelperPath,$Action,$DatabasePath) | ForEach-Object { Quote-CcToolboxMigrationArgument ([string]$_) }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'Could not start the bundled SQLite helper.' }
        if ($null -ne $InputJson) {
            $payloadBytes = [Text.Encoding]::UTF8.GetBytes($InputJson)
            try { $process.StandardInput.WriteLine([Convert]::ToBase64String($payloadBytes)) }
            finally { [Array]::Clear($payloadBytes,0,$payloadBytes.Length) }
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { try { $process.Kill() } catch {}; throw 'SQLite helper timed out.' }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            $safeCode = 'helper-failed'
            try { $safeCode = ([string]($stdout -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1 | ConvertFrom-Json -ErrorAction Stop).code) } catch { }
            throw ('SQLite helper failed safely (' + $Action + '/' + $safeCode + ').')
        }
        $lines = @($stdout -split "`r?`n" | Where-Object { $_ })
        if ($lines.Count -lt 1) { throw 'SQLite helper returned no result.' }
        $result = $lines[0] | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.ok) { throw ('SQLite helper refused migration (' + [string]$result.code + ').') }
        if ($Action -eq 'inspect') {
            if ($lines.Count -lt 2) { throw 'SQLite helper returned an incomplete inspection result.' }
            $result | Add-Member -NotePropertyName EnvKeys -NotePropertyValue (@(($lines[1] | ConvertFrom-Json -ErrorAction Stop).envKeys)) -Force
        }
        return $result
    } finally { $process.Dispose() }
}

function Get-CcToolboxProviderEnvironment {
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][string]$KeysFile,
        [Security.SecureString]$VaultPassword,
        [Parameter(Mandatory)][string]$BaseUrlName,
        [Parameter(Mandatory)][string]$ApiKeyName
    )
    $allowed = @('id','name','enabled','baseUrl','apikeyEnv','models','extraEnv','verified','notes')
    foreach ($property in $Provider.PSObject.Properties) {
        if ($property.Name -notin $allowed) { throw ('Enabled toolbox provider has an unsupported field: ' + $property.Name) }
    }
    foreach ($required in @('id','name','enabled','baseUrl','apikeyEnv','models','extraEnv')) {
        if (-not $Provider.PSObject.Properties[$required]) { throw ('Enabled toolbox provider lacks a required field: ' + $required) }
    }
    if ($Provider.id -isnot [string] -or [string]::IsNullOrWhiteSpace($Provider.id) -or $Provider.id.Length -gt 160) { throw 'Enabled toolbox provider has an invalid ID.' }
    if ($Provider.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Provider.name) -or $Provider.name.Length -gt 160) { throw 'Enabled toolbox provider has an invalid name.' }
    if ($Provider.PSObject.Properties['verified'] -and ($Provider.verified -isnot [string] -or $Provider.verified.Length -gt 4096)) { throw 'Enabled toolbox provider has invalid verification metadata.' }
    if ($Provider.PSObject.Properties['notes'] -and ($Provider.notes -isnot [string] -or $Provider.notes.Length -gt 8192)) { throw 'Enabled toolbox provider has invalid notes metadata.' }
    if ($Provider.baseUrl -isnot [string] -or [string]::IsNullOrWhiteSpace($Provider.baseUrl) -or $Provider.baseUrl.Length -gt 2048 -or $Provider.baseUrl -match '[\x00-\x1f]') { throw 'Enabled toolbox provider has no valid base URL.' }
    $baseUri = $null
    if (-not [Uri]::TryCreate([string]$Provider.baseUrl,[UriKind]::Absolute,[ref]$baseUri) -or @('http','https') -notcontains $baseUri.Scheme -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) { throw 'Enabled toolbox provider has an invalid HTTP(S) base URL.' }
    if ($baseUri.IsLoopback -or $baseUri.DnsSafeHost -match '^(?i:localhost)(\.|$)') { throw 'Loopback toolbox endpoints cannot be imported.' }
    if ($Provider.apikeyEnv -isnot [string] -or $Provider.apikeyEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') { throw 'Enabled toolbox provider has an invalid credential reference.' }
    foreach ($mapName in @('models','extraEnv')) {
        if ($null -eq $Provider.$mapName -or $Provider.$mapName -isnot [pscustomobject]) { throw ('Enabled toolbox provider ' + $mapName + ' must be an object; refusing to drop fields.') }
    }
    $secret = Get-ProviderSecret -KeysFile $KeysFile -Name ([string]$Provider.apikeyEnv) -VaultPassword $VaultPassword
    if ([string]::IsNullOrWhiteSpace($secret) -or $secret -match '[\x00-\x1f]' -or (Test-SecretIsPlaceholder -Value $secret)) { $secret = $null; throw 'An enabled toolbox provider has no usable credential in the configured keys source.' }
    $env = [ordered]@{}
    $env[$BaseUrlName] = [string]$Provider.baseUrl
    $env[$ApiKeyName] = $secret
    $secret = $null
    foreach ($property in $Provider.models.PSObject.Properties) {
        if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or $property.Value -isnot [string]) { throw 'A model environment entry has an unsupported name or value.' }
        if ($env.Contains($property.Name) -and $env[$property.Name] -cne [string]$property.Value) { throw 'Conflicting model/environment entries require manual review.' }
        $env[$property.Name] = [string]$property.Value
    }
    foreach ($property in $Provider.extraEnv.PSObject.Properties) {
        if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or $property.Value -isnot [string]) { throw 'An extraEnv entry has an unsupported name or value; migration will not discard it.' }
        if ($env.Contains($property.Name) -and $env[$property.Name] -cne [string]$property.Value) { throw 'Conflicting extraEnv/model entries require manual review.' }
        $env[$property.Name] = [string]$property.Value
    }
    return ,$env
}

function Get-CcToolboxMigrationStableId {
    param([Parameter(Mandatory)][string]$SourceId)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ('toolbox-' + [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SourceId))).Replace('-','').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Import-CcToolboxProviders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)]$Session,
        [Security.SecureString]$VaultPassword,
        [string]$PythonExe
    )
    if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'This migration requires Windows PowerShell 5.1.' }
    if ($Session.Locked -or -not $Session.DataKey -or -not $Session.Revision) { throw 'An already unlocked CC Switch encrypted snapshot is required.' }
    $stick = Get-CcToolboxMigrationFullPath $StickRoot
    if ((Get-CcToolboxMigrationFullPath ([string]$Session.StickRoot)) -ne $stick) { throw 'The unlocked encrypted snapshot belongs to another USB root.' }
    if (-not $PythonExe) { $PythonExe = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\python\python.exe' }
    $PythonExe = Get-CcToolboxMigrationFullPath $PythonExe
    $helper = Join-Path $PSScriptRoot 'cc-switch-toolbox-migration.py'
    $providerPath = Join-Path $stick 'harness\providers.json'
    $keysFile = Join-Path $stick 'config\keys.env'
    $legacyVaultPath = Join-Path (Split-Path -Parent $keysFile) 'credentials.vault.json'
    $toolSettingsPath = Join-Path $stick 'config\settings.json'
    $userClaudeSettings = Join-Path $stick 'config\claude\settings.json'
    foreach ($path in @($stick,$providerPath,$keysFile,$legacyVaultPath,$toolSettingsPath,$userClaudeSettings,$PythonExe,$helper)) { Assert-CcToolboxMigrationNoReparse $path }
    foreach ($path in @($providerPath,$toolSettingsPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Required toolbox migration input is missing: ' + (Split-Path -Leaf $path)) } }
    if (-not (Test-Path -LiteralPath $keysFile -PathType Leaf) -and -not (Test-Path -LiteralPath $legacyVaultPath -PathType Leaf)) { throw 'No toolbox credential source exists.' }
    if ((Get-Item -LiteralPath $providerPath).Length -gt 2MB -or (Get-Item -LiteralPath $toolSettingsPath).Length -gt 1MB -or ((Test-Path -LiteralPath $userClaudeSettings -PathType Leaf) -and (Get-Item -LiteralPath $userClaudeSettings).Length -gt 1MB)) { throw 'Toolbox migration metadata exceeds its size limit.' }
    $providerHash = (Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash
    $settingsHash = (Get-FileHash -LiteralPath $toolSettingsPath -Algorithm SHA256).Hash
    $keysHash = if (Test-Path -LiteralPath $keysFile -PathType Leaf) { (Get-FileHash -LiteralPath $keysFile -Algorithm SHA256).Hash } else { $null }
    $vaultHash = if (Test-Path -LiteralPath $legacyVaultPath -PathType Leaf) { (Get-FileHash -LiteralPath $legacyVaultPath -Algorithm SHA256).Hash } else { $null }
    $userClaudeSettingsHash = if (Test-Path -LiteralPath $userClaudeSettings -PathType Leaf) { (Get-FileHash -LiteralPath $userClaudeSettings -Algorithm SHA256).Hash } else { $null }
    $providersDocument = [IO.File]::ReadAllText($providerPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $toolSettings = [IO.File]::ReadAllText($toolSettingsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $providersDocument.providers -or $providersDocument.providers -isnot [System.Array] -or $providersDocument.default -isnot [string]) { throw 'Toolbox provider document has an unsupported shape.' }
    foreach ($candidate in $providersDocument.providers) {
        if ($candidate -isnot [pscustomobject] -or -not $candidate.PSObject.Properties['enabled'] -or $candidate.enabled -isnot [bool]) { throw 'Toolbox provider list contains an unsupported record.' }
    }
    if ($null -ne $toolSettings.provider -and $toolSettings.provider -isnot [string]) { throw 'Toolbox selected provider setting is invalid.' }
    $selectedSourceId = if ([string]::IsNullOrWhiteSpace([string]$toolSettings.provider)) { [string]$providersDocument.default } else { [string]$toolSettings.provider }
    $sourceCurrent = @($providersDocument.providers | Where-Object { $_.id -ceq $selectedSourceId -and $_.enabled -eq $true })
    if ($sourceCurrent.Count -ne 1) { throw 'Toolbox current provider is missing, disabled, or ambiguous.' }

    $registryPath = Join-Path $stick 'harness\registry.json'
    Assert-CcToolboxMigrationNoReparse $registryPath
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Claude harness registry is missing.' }
    $registry = [IO.File]::ReadAllText($registryPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $claudeHarnesses = @($registry.harnesses | Where-Object { $_.id -ceq 'claude' -and $_.enabled -eq $true })
    if ($claudeHarnesses.Count -ne 1 -or -not $claudeHarnesses[0].providerEnv) { throw 'Claude provider environment mapping is missing or ambiguous.' }
    $baseUrlName = [string]$claudeHarnesses[0].providerEnv.baseUrl
    $apiKeyName = [string]$claudeHarnesses[0].providerEnv.apiKey
    if ($baseUrlName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -or $apiKeyName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') { throw 'Claude provider environment mapping is invalid.' }

    $paths = Get-CcEncPaths $stick
    $storeLock = $null
    $stage = $null
    $committedRevision = $null
    $commitAttempted = $false
    $rollbackFailed = $false
    $oldRevision = [string]$Session.Revision
    $oldCurrentPointer = $null
    $oldPreviousPointer = $null
    $oldGenerationFiles = @{}
    $result = $null
    $payloadJson = $null
    $applyData = $null
    $verifyInput = $null
    $expectedClaudeSettings = $null
    $records = New-Object 'System.Collections.Generic.List[object]'
    try {
        # Keep cooperating encrypted-store writers out for restore, edit, commit and verify.
        $storeLock = Enter-CcEncLock $paths.Store
        if ((Get-CcEncryptedStoreStatus -StickRoot $stick).CurrentRevision -cne $oldRevision) { throw 'Encrypted store revision changed; reopen the unlocked session before importing.' }
        $stage = New-CcToolboxMigrationStage -Prefix 'aistick-cc-toolbox-import-'
        $payloadRoot = Join-Path $stage 'payload'
        $userSettingsStagePath = $null
        if (Test-Path -LiteralPath $userClaudeSettings -PathType Leaf) {
            $userSettingsStageDir = Join-Path $stage 'toolbox-inputs'
            [void][IO.Directory]::CreateDirectory($userSettingsStageDir)
            $userSettingsStagePath = Join-Path $userSettingsStageDir 'claude-settings.json'
            [IO.File]::Copy($userClaudeSettings,$userSettingsStagePath,$false)
            if ((Get-FileHash -LiteralPath $userSettingsStagePath -Algorithm SHA256).Hash -cne $userClaudeSettingsHash) { throw 'Claude settings staging copy did not match its source.' }
        }
        $null = Restore-CcEncryptedSnapshot -Session $Session -DestinationRoot $payloadRoot -StoppedOnly
        $dbPath = Join-Path $payloadRoot 'config\cc-switch\home\.cc-switch\cc-switch.db'
        if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { throw 'The encrypted snapshot has no CC Switch database.' }
        $inspect = Invoke-CcToolboxMigrationHelper -PythonExe $PythonExe -HelperPath $helper -Action inspect -DatabasePath $dbPath

        $seenSource = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $seenTarget = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($provider in $providersDocument.providers) {
            if ($provider.enabled -ne $true) { continue }
            if (-not $seenSource.Add([string]$provider.id)) { throw 'Duplicate enabled toolbox provider IDs are not supported.' }
            $env = Get-CcToolboxProviderEnvironment -Provider $provider -KeysFile $keysFile -VaultPassword $VaultPassword -BaseUrlName $baseUrlName -ApiKeyName $apiKeyName
            $targetId = Get-CcToolboxMigrationStableId -SourceId ([string]$provider.id)
            if (-not $seenTarget.Add($targetId)) { throw 'Deterministic target provider ID collision.' }
            $providerNotes = $null
            if ($provider.PSObject.Properties['notes']) { $providerNotes = [string]$provider.notes }
            $providerMeta = [ordered]@{}
            if ($provider.PSObject.Properties['verified']) { $providerMeta.toolboxMigration = [ordered]@{verified=[string]$provider.verified} }
            $records.Add([ordered]@{
                id = $targetId
                name = [string]$provider.name
                settings_config = [ordered]@{ env = $env }
                notes = $providerNotes
                meta = $providerMeta
                createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                sortIndex = $records.Count
            })
        }
        if ($records.Count -eq 0) { throw 'There are no enabled toolbox providers to import.' }
        $currentId = Get-CcToolboxMigrationStableId -SourceId ([string]$sourceCurrent[0].id)
        $applyData = [ordered]@{providers=@($records.ToArray());currentId=$currentId;existingEnvKeys=@($inspect.EnvKeys);userSettingsPath=$userSettingsStagePath}
        $payloadJson = ConvertTo-Json -InputObject $applyData -Depth 20 -Compress
        $null = Invoke-CcToolboxMigrationHelper -PythonExe $PythonExe -HelperPath $helper -Action apply -DatabasePath $dbPath -InputJson $payloadJson
        $payloadJson = $null
        $applyData = $null
        $expectedClaudeSettingsPath = Join-Path $payloadRoot 'harness\cc-switch\claude\settings.json'
        $expectedClaudeSettings = [IO.File]::ReadAllText($expectedClaudeSettingsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $verifyInput = [ordered]@{providers=@($records.ToArray());currentId=$currentId;expectedClaudeSettings=$expectedClaudeSettings}
        $payloadJson = ConvertTo-Json -InputObject $verifyInput -Depth 20 -Compress

        if ((Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash -cne $providerHash -or
            (Get-FileHash -LiteralPath $toolSettingsPath -Algorithm SHA256).Hash -cne $settingsHash) { throw 'Toolbox configuration changed during import; no encrypted commit was made.' }
        if ((Test-Path -LiteralPath $keysFile -PathType Leaf) -ne ($null -ne $keysHash) -or
            ((Test-Path -LiteralPath $keysFile -PathType Leaf) -and (Get-FileHash -LiteralPath $keysFile -Algorithm SHA256).Hash -cne $keysHash) -or
            (Test-Path -LiteralPath $legacyVaultPath -PathType Leaf) -ne ($null -ne $vaultHash) -or
            ((Test-Path -LiteralPath $legacyVaultPath -PathType Leaf) -and (Get-FileHash -LiteralPath $legacyVaultPath -Algorithm SHA256).Hash -cne $vaultHash) -or
            (Test-Path -LiteralPath $userClaudeSettings -PathType Leaf) -ne ($null -ne $userClaudeSettingsHash) -or
            ((Test-Path -LiteralPath $userClaudeSettings -PathType Leaf) -and (Get-FileHash -LiteralPath $userClaudeSettings -Algorithm SHA256).Hash -cne $userClaudeSettingsHash)) { throw 'Credential or Claude settings changed during import; no encrypted commit was made.' }

        # Save-CcEncryptedSnapshotCore is called under the lock held above so the
        # restore/commit/roundtrip check observes one exclusive generation pair.
        $storeRoot = $paths.Store
        $currentPointerPath = Join-Path $storeRoot 'current.json'
        $previousPointerPath = Join-Path $storeRoot 'previous.json'
        $generationsPath = Join-Path $storeRoot 'generations'
        $oldCurrentPointer = [IO.File]::ReadAllBytes($currentPointerPath)
        if ([IO.File]::Exists($previousPointerPath)) { $oldPreviousPointer = [IO.File]::ReadAllBytes($previousPointerPath) }
        foreach ($generationFile in [IO.Directory]::EnumerateFiles($generationsPath)) {
            $leaf = [IO.Path]::GetFileName($generationFile)
            if ($leaf -notmatch '^[0-9a-f]{32}\.bin$') { throw 'Unexpected encrypted generation before import.' }
            $oldGenerationFiles[$leaf] = [IO.File]::ReadAllBytes($generationFile)
        }
        if ($oldGenerationFiles.Count -lt 1 -or $oldGenerationFiles.Count -gt 2) { throw 'Encrypted generation set is not the expected recoverable pair.' }

        $commitAttempted = $true
        $save = Save-CcEncryptedSnapshotCore -Session $Session -SourceRoot $payloadRoot -StoppedOnly
        $committedRevision = [string]$save.Revision
        $verifyRoot = Join-Path $stage 'verify'
        $null = Restore-CcEncryptedSnapshot -Session $Session -DestinationRoot $verifyRoot -StoppedOnly
        $verifyDb = Join-Path $verifyRoot 'config\cc-switch\home\.cc-switch\cc-switch.db'
        $null = Invoke-CcToolboxMigrationHelper -PythonExe $PythonExe -HelperPath $helper -Action verify -DatabasePath $verifyDb -InputJson $payloadJson
        $payloadJson = $null
        return [pscustomobject]@{Status='Imported';ImportedProviders=$records.Count;CurrentProviderId=$currentId;Revision=$Session.Revision;SecretsWrittenToStdout=$false}
    } catch {
        if ($commitAttempted) {
            try {
                $storeRoot = $paths.Store
                $generationsPath = Join-Path $storeRoot 'generations'
                $currentPointerPath = Join-Path $storeRoot 'current.json'
                $previousPointerPath = Join-Path $storeRoot 'previous.json'
                foreach ($file in [IO.Directory]::EnumerateFiles($generationsPath)) {
                    if ([IO.Path]::GetFileName($file) -notin @($oldGenerationFiles.Keys)) { [IO.File]::Delete($file) }
                }
                foreach ($entry in $oldGenerationFiles.GetEnumerator()) {
                    $generationPath = Join-Path $generationsPath $entry.Key
                    if ([IO.File]::Exists($generationPath)) { [IO.File]::Delete($generationPath) }
                    Write-CcEncBytes $generationPath ([byte[]]$entry.Value)
                }
                Write-CcEncBytes $currentPointerPath ([byte[]]$oldCurrentPointer)
                if ($null -ne $oldPreviousPointer) { Write-CcEncBytes $previousPointerPath ([byte[]]$oldPreviousPointer) }
                elseif ([IO.File]::Exists($previousPointerPath)) { [IO.File]::Delete($previousPointerPath) }
                $Session.Revision = $oldRevision
            } catch { $rollbackFailed = $true }
        }
        if ($rollbackFailed) {
            throw ('Import failed after encrypted commit and automatic rollback could not complete. Protected recovery stage retained at: ' + $stage)
        }
        throw
    } finally {
        $payloadJson = $null
        $applyData = $null
        $verifyInput = $null
        $expectedClaudeSettings = $null
        foreach ($record in $records) { if ($record.settings_config -and $record.settings_config.env) { $record.settings_config.env.Clear() } }
        $records.Clear()
        if ($storeLock) { $storeLock.Dispose() }
        if ($stage -and -not $rollbackFailed -and (Test-Path -LiteralPath $stage -PathType Container)) {
            $resolvedStage = [IO.Path]::GetFullPath($stage).TrimEnd('\','/')
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
            if ((Split-Path -Parent $resolvedStage) -eq $tempRoot -and (Split-Path -Leaf $resolvedStage) -match '^aistick-cc-toolbox-import-[0-9a-f]{32}$') {
                Assert-CcToolboxMigrationNoReparse $resolvedStage
                Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction Stop
            }
        }
    }
}

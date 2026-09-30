# Read-only status summary for the portable toolbox. Windows PowerShell 5.1.
Set-StrictMode -Version Latest

$vaultModulePath = Join-Path $PSScriptRoot 'vault.ps1'
if (Test-Path -LiteralPath $vaultModulePath -PathType Leaf) {
    try { . $vaultModulePath } catch { }
}

function ConvertTo-ToolboxStatusPath {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $pathRoot.Length) { return $fullPath.TrimEnd('\') }
    return $pathRoot
}

function Get-ToolboxStatusField {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-ToolboxStatusNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    try { $current = ConvertTo-ToolboxStatusPath $Path } catch { return $false }
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $pathRoot = [IO.Path]::GetPathRoot($current)
        if ($current -eq $pathRoot) { return $true }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { return $false }
        $current = $parent
    }
}

function ConvertTo-ToolboxStatusLabel {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -isnot [string] -and $Value -isnot [char] -and
        $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [bool] -and
        $Value -isnot [decimal]) { return '' }
    $label = ([string]$Value -replace '[\r\n\t]+', ' ').Trim()
    if ($label.Length -gt 120) { $label = $label.Substring(0, 120) }
    return $label
}

function Get-ToolboxStatus {
    [CmdletBinding()]
    param(
        [string]$StickRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$TempRoot = [IO.Path]::GetTempPath(),
        $ProjectContext
    )

    $root = ConvertTo-ToolboxStatusPath $StickRoot
    $temp = ConvertTo-ToolboxStatusPath $TempRoot

    $vaultPath = Join-Path $root 'config\credentials.vault.json'
    $keysPath = Join-Path $root 'config\keys.env'
    $vaultBackup = $vaultPath + '.bak'
    $vaultTemp = $vaultPath + '.tmp'
    $vaultRestoreTemp = $vaultPath + '.restore.tmp'
    $hasVault = Test-Path -LiteralPath $vaultPath -PathType Leaf
    $hasVaultSidecar = (Test-Path -LiteralPath $vaultBackup -PathType Leaf) -or
        (Test-Path -LiteralPath $vaultTemp -PathType Leaf) -or
        (Test-Path -LiteralPath $vaultRestoreTemp -PathType Leaf)
    $vaultState = $null
    $vaultMetadataValidated = $false
    $vaultStatusCommand = Get-Command Get-VaultStatus -ErrorAction SilentlyContinue
    $vaultParentSafe = Test-ToolboxStatusNoReparsePath -Path (Split-Path -Parent $vaultPath)
    $vaultFileSafe = (-not $hasVault) -or (Test-ToolboxStatusNoReparsePath -Path $vaultPath)
    $vaultPathSafe = $vaultParentSafe -and $vaultFileSafe
    if (-not $vaultPathSafe -and $hasVault) {
        $vaultState = 'InvalidMetadata'
    } elseif ($vaultStatusCommand -and $vaultPathSafe) {
        try {
            $vaultResult = Get-VaultStatus -Path $vaultPath
            $reportedState = [string](Get-ToolboxStatusField $vaultResult 'State')
            if ($reportedState -in @('Absent', 'Present', 'RecoveryRequired', 'InvalidMetadata')) {
                $vaultState = $reportedState
                $vaultMetadataValidated = $true
            }
            if ($hasVault) {
                $metadata = Get-ToolboxStatusField $vaultResult 'Metadata'
                $format = [string](Get-ToolboxStatusField $metadata 'Format')
                $version = Get-ToolboxStatusField $metadata 'Version'
                $kdf = [string](Get-ToolboxStatusField $metadata 'Kdf')
                $iterations = 0
                $iterationsOk = [int]::TryParse([string](Get-ToolboxStatusField $metadata 'Iterations'), [ref]$iterations)
                $cipher = [string](Get-ToolboxStatusField $metadata 'Cipher')
                if ($format -cne 'portable-credential-vault' -or [int]$version -ne 1 -or
                    $kdf -cne 'PBKDF2-HMAC-SHA256' -or -not $iterationsOk -or
                    $iterations -lt 600000 -or $iterations -gt 1000000 -or
                    $cipher -cne 'AES-256-CBC-PKCS7') { $vaultState = 'InvalidMetadata' }
            }
        } catch { $vaultState = 'InvalidMetadata'; $vaultMetadataValidated = $true }
    }
    if (-not $vaultState) {
        if ($hasVault) { $vaultState = 'Present' }
        elseif ($hasVaultSidecar) { $vaultState = 'RecoveryRequired' }
        else { $vaultState = 'Absent' }
    }
    $credentialSource = if ($vaultState -eq 'Absent') {
        if (Test-Path -LiteralPath $keysPath -PathType Leaf) { 'KeysEnv' } else { 'Missing' }
    } else { 'Vault' }

    $uvPath = Join-Path $root 'runtime\uv\uv.exe'
    $pythonPaths = New-Object System.Collections.ArrayList
    $defaultPython = Join-Path $root 'runtime\python\python.exe'
    if (Test-Path -LiteralPath $defaultPython -PathType Leaf) { [void]$pythonPaths.Add($defaultPython) }
    $runtimeRoot = Join-Path $root 'runtime'
    $runtimeItem = Get-Item -LiteralPath $runtimeRoot -Force -ErrorAction SilentlyContinue
    if ($runtimeItem -and $runtimeItem.PSIsContainer -and (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'python-*' -Force -ErrorAction SilentlyContinue)) {
            $pythonExe = Join-Path $dir.FullName 'python.exe'
            if (Test-Path -LiteralPath $pythonExe -PathType Leaf) { [void]$pythonPaths.Add($pythonExe) }
        }
    }

    $pendingPaths = New-Object System.Collections.ArrayList
    $unknownPaths = New-Object System.Collections.ArrayList
    if ((Test-Path -LiteralPath $temp -PathType Container) -and (Test-ToolboxStatusNoReparsePath -Path $temp)) {
        $tempItem = Get-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        if ($tempItem -and (($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $temp -Directory -Filter 'aistick-*' -Force -ErrorAction SilentlyContinue)) {
                $candidate = $null
                try { $candidate = ConvertTo-ToolboxStatusPath $dir.FullName } catch { continue }
                if (-not $candidate.StartsWith($temp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [void]$unknownPaths.Add($candidate)
                    continue
                }
                $markerPath = Join-Path $candidate '.session-owner.json'
                if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
                try {
                    $markerFile = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
                    if ($markerFile.Length -gt 65536 -or (($markerFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'invalid marker' }
                    $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -ErrorAction Stop
                    $id = [guid]::Empty
                    $idText = [string](Get-ToolboxStatusField $marker 'sessionId')
                    $recordedRoot = [string](Get-ToolboxStatusField $marker 'sessionRoot')
                    $recordedTemp = [string](Get-ToolboxStatusField $marker 'tempRoot')
                    $recoveryValue = Get-ToolboxStatusField $marker 'recoveryRequired'
                    if (-not [guid]::TryParse($idText, [ref]$id) -or
                        (Split-Path -Leaf $candidate) -ne "aistick-$($id.ToString())" -or
                        (ConvertTo-ToolboxStatusPath $recordedRoot) -ne $candidate -or
                        (ConvertTo-ToolboxStatusPath $recordedTemp) -ne $temp -or
                        $null -eq $recoveryValue) { throw 'unknown marker' }
                    if ($recoveryValue -is [bool]) { $isRecovery = $recoveryValue }
                    elseif ([string]$recoveryValue -match '^(?i:true|1)$') { $isRecovery = $true }
                    elseif ([string]$recoveryValue -match '^(?i:false|0)$') { $isRecovery = $false }
                    else { throw 'unknown marker' }
                    if ($isRecovery) { [void]$pendingPaths.Add($candidate) }
                } catch {
                    [void]$unknownPaths.Add($candidate)
                }
            }
        }
    }

    $context = [pscustomobject]@{
        Project = ConvertTo-ToolboxStatusLabel (Get-ToolboxStatusField $ProjectContext 'Project')
        Supplier = ConvertTo-ToolboxStatusLabel (Get-ToolboxStatusField $ProjectContext 'Supplier')
        Tool = ConvertTo-ToolboxStatusLabel (Get-ToolboxStatusField $ProjectContext 'Tool')
    }
    return [pscustomobject]@{
        Vault = [pscustomobject]@{ State = $(switch ($vaultState) {
            'Absent' { 'Missing' }
            'Present' { 'Locked' }
            'InvalidMetadata' { 'InvalidFormat' }
            default { $vaultState }
        }); Path = $vaultPath; MetadataValidated = $vaultMetadataValidated }
        Credentials = [pscustomobject]@{
            Source = $credentialSource
            SourceExists = ($credentialSource -ne 'Missing')
            NeedsUnlockValidation = ($credentialSource -eq 'Vault' -and $hasVault -and $vaultState -ne 'InvalidMetadata')
            ContentValidated = $false
        }
        Context = $context
        Runtime = [pscustomobject]@{
            UvInstalled = (Test-Path -LiteralPath $uvPath -PathType Leaf)
            UvPath = $uvPath
            PythonInstalled = ($pythonPaths.Count -gt 0)
            PythonPaths = @($pythonPaths.ToArray())
        }
        Recovery = [pscustomobject]@{
            PendingCount = $pendingPaths.Count
            PendingPaths = @($pendingPaths.ToArray())
            UnknownCount = $unknownPaths.Count
            UnknownPaths = @($unknownPaths.ToArray())
        }
    }
}

function Show-ToolboxStatus {
    [CmdletBinding()]
    param(
        [string]$StickRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$TempRoot = [IO.Path]::GetTempPath(),
        $ProjectContext
    )
    $status = Get-ToolboxStatus -StickRoot $StickRoot -TempRoot $TempRoot -ProjectContext $ProjectContext
    $validationText = if ($status.Credentials.NeedsUnlockValidation) { '（解锁后验证内容）' } else { '' }
    $uvText = if ($status.Runtime.UvInstalled) { '已安装' } else { '未安装' }
    Write-Host '工具箱状态' -ForegroundColor Cyan
    Write-Host ("  保险箱: {0}" -f $status.Vault.State)
    Write-Host ("  凭据来源: {0}{1}" -f $status.Credentials.Source, $validationText)
    if ($status.Context.Project) { Write-Host ("  项目: {0}" -f $status.Context.Project) }
    if ($status.Context.Supplier) { Write-Host ("  供应商: {0}" -f $status.Context.Supplier) }
    if ($status.Context.Tool) { Write-Host ("  工具: {0}" -f $status.Context.Tool) }
    Write-Host ("  盘内 Python: {0} 个；uv: {1}" -f $status.Runtime.PythonPaths.Count, $uvText)
    Write-Host ("  待恢复本机目录: {0}" -f $status.Recovery.PendingCount)
    foreach ($path in $status.Recovery.PendingPaths) { Write-Host ("    {0}" -f $path) }
    if ($status.Recovery.UnknownCount) { Write-Host ("  未确认的会话标记: {0}（保留，需人工查看）" -f $status.Recovery.UnknownCount) -ForegroundColor Yellow }
    return $status
}

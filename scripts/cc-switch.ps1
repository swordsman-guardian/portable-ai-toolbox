[CmdletBinding()]
param(
    [ValidateSet('Status', 'Prepare', 'Launch', 'ReadClaudeProfile')]
    [string]$Action = 'Status',
    [string]$SessionRoot,
    [string]$DataRoot,
    [string]$PackageRoot,
    [string]$ArchivePath,
    [string]$ProfilePath,
    [string]$ProfileName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CcSwitchVersion = '3.20.4'
$script:CcSwitchAsset = 'CC-Switch-v3.20.4-Windows-Portable.zip'
$script:CcSwitchSha256 = '227288532bfd4f3894d7d9916a8cf340d49957618d8e520229d30bdcc9f5b5d3'
$script:CcSwitchDownloadUrl = 'https://github.com/farion1231/cc-switch/releases/download/v3.20.4/CC-Switch-v3.20.4-Windows-Portable.zip'
$script:CcSwitchAssetsUrl = 'https://github.com/farion1231/cc-switch/releases/expanded_assets/v3.20.4'
$script:CcSwitchLicenseUrl = 'https://github.com/farion1231/cc-switch/blob/main/LICENSE'
. (Join-Path $PSScriptRoot 'cc-switch-profile.ps1')

if (-not $PackageRoot) { $PackageRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\cc-switch' }
if (-not $ArchivePath) { $ArchivePath = Join-Path $PackageRoot $script:CcSwitchAsset }

function Get-CcSwitchIsolationBlockReason {
    return 'The native GUI has not passed validation that its normal configuration writes stay inside the USB harness scope. Environment/context preparation alone is not GUI isolation verification.'
}

function Test-CcSwitchArchive {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if (Test-CcSwitchPathHasReparseComponent -Path $Path) { return $false }
        $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        return [string]::Equals($actualHash, $script:CcSwitchSha256, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-CcSwitchPreparedFiles {
    param([Parameter(Mandatory = $true)][string]$AppDirectory)
    try {
        if (Test-CcSwitchPathHasReparseComponent -Path $AppDirectory) { return $false }
        if (-not (Test-CcSwitchArchive -Path $ArchivePath)) { return $false }
        Assert-CcSwitchArchiveLayout -Path $ArchivePath
        if (-not (Test-Path -LiteralPath $AppDirectory -PathType Container)) { return $false }
        $members = @(Get-ChildItem -LiteralPath $AppDirectory -Force | Select-Object -ExpandProperty Name | Sort-Object)
        if (($members -join "`n") -ne (@('cc-switch.exe', 'portable.ini') -join "`n")) { return $false }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $zip.Entries) {
                $target = Join-Path $AppDirectory $entry.FullName
                if ((Test-CcSwitchPathHasReparseComponent -Path $target) -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { return $false }
                if ((Get-Item -LiteralPath $target -Force).Length -ne $entry.Length) { return $false }
                $stream = $entry.Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $expected = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
                finally { $stream.Dispose(); $sha.Dispose() }
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $expected) { return $false }
            }
        } finally { $zip.Dispose() }
        return $true
    } catch { return $false }
}

function Get-CcSwitchStatus {
    param([string]$RequestedSessionRoot, [string]$RequestedDataRoot)
    $archiveVerified = Test-CcSwitchArchive -Path $ArchivePath
    $appDir = Join-Path $PackageRoot 'app'
    $exePath = Join-Path $appDir 'cc-switch.exe'
    $portableMarker = Join-Path $appDir 'portable.ini'
    $appPrepared = Test-CcSwitchPreparedFiles -AppDirectory $appDir
    $isolationReason = Get-CcSwitchIsolationBlockReason
    return [pscustomobject]@{
        Status = 'BlockedPortableIsolation'
        Version = $script:CcSwitchVersion
        Architecture = 'x64'
        ArchiveVerified = $archiveVerified
        AppPrepared = $appPrepared
        ExtractedFilesVerified = $appPrepared
        PortableMarkerPresent = (Test-Path -LiteralPath $portableMarker -PathType Leaf)
        LaunchAllowed = $false
        SessionRoot = $RequestedSessionRoot
        DataRoot = $RequestedDataRoot
        Reason = $isolationReason
    }
}

function Assert-CcSwitchArchiveLayout {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        $expected = @('cc-switch.exe', 'portable.ini')
        if (($entries -join "`n") -ne ($expected -join "`n")) {
            throw 'Official archive contents did not match the expected v3.20.4 Windows x64 portable package.'
        }
    } finally { $zip.Dispose() }
}

function New-CcSwitchMetadata {
    param([Parameter(Mandatory = $true)][string]$VerifiedHash)
    return [ordered]@{
        project = 'farion1231/cc-switch'
        version = $script:CcSwitchVersion
        architecture = 'x64'
        asset = $script:CcSwitchAsset
        upstreamUrl = $script:CcSwitchDownloadUrl
        releaseAssetsUrl = $script:CcSwitchAssetsUrl
        license = 'MIT'
        licenseUrl = $script:CcSwitchLicenseUrl
        sha256 = $VerifiedHash
        verifiedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        isolationStatus = 'portable.ini marks the build, but upstream v3.20.4 does not guarantee isolated application/config data paths'
    }
}

function Invoke-CcSwitchPrepare {
    $resolvedPackage = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    if ($resolvedPackage -eq [IO.Path]::GetPathRoot($resolvedPackage).TrimEnd('\', '/')) { throw 'The package directory must not be a drive root.' }
    foreach ($path in @($PackageRoot, $ArchivePath, (Join-Path $PackageRoot 'app'), (Join-Path $PackageRoot 'metadata.json'))) {
        if (Test-CcSwitchPathHasReparseComponent -Path $path) { throw 'Package paths must not contain reparse points.' }
    }
    if (-not (Test-CcSwitchArchive -Path $ArchivePath)) {
        throw "The local archive is missing or its SHA-256 does not match the official v3.20.4 release: $ArchivePath"
    }
    Assert-CcSwitchArchiveLayout -Path $ArchivePath

    $appDir = Join-Path $PackageRoot 'app'
    if (Test-Path -LiteralPath $appDir) {
        $existing = @(Get-ChildItem -LiteralPath $appDir -Force | Select-Object -ExpandProperty Name | Sort-Object)
        if (($existing -join "`n") -ne (@('cc-switch.exe', 'portable.ini') -join "`n")) {
            throw "Refusing to overwrite or reuse an app directory with unknown contents: $appDir"
        }
        if (-not (Test-CcSwitchPreparedFiles -AppDirectory $appDir)) {
            throw 'Prepared files do not match the verified official archive; existing files were left unchanged.'
        }
    } else {
        New-Item -ItemType Directory -Path $appDir -ErrorAction Stop | Out-Null
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $appDir -ErrorAction Stop
        } catch {
            # Only remove a directory this invocation created; never clean a pre-existing path.
            $resolvedApp = [IO.Path]::GetFullPath($appDir)
            if ($resolvedApp.StartsWith(($resolvedPackage + '\'), [StringComparison]::OrdinalIgnoreCase) -and -not (Test-CcSwitchPathHasReparseComponent -Path $resolvedApp)) {
                $reparseChildren = @(Get-ChildItem -LiteralPath $resolvedApp -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
                if ($reparseChildren.Count -eq 0) { Remove-Item -LiteralPath $resolvedApp -Recurse -Force -ErrorAction SilentlyContinue }
            }
            throw
        }
    }

    if (-not (Test-CcSwitchPreparedFiles -AppDirectory $appDir)) { throw 'Extracted files did not match the verified official archive.' }

    $exePath = Join-Path $appDir 'cc-switch.exe'
    $portableMarker = Join-Path $appDir 'portable.ini'
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf) -or -not (Test-Path -LiteralPath $portableMarker -PathType Leaf)) {
        throw 'Prepared files do not include the expected executable and portable marker.'
    }

    $metadataPath = Join-Path $PackageRoot 'metadata.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try { $oldMetadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "Refusing to overwrite unrecognized package metadata: $metadataPath" }
        if ($oldMetadata.version -ne $script:CcSwitchVersion -or $oldMetadata.sha256 -ne $script:CcSwitchSha256 -or $oldMetadata.asset -ne $script:CcSwitchAsset) {
            throw "Refusing to overwrite metadata for a different package: $metadataPath"
        }
    } else {
        $metadataJson = New-CcSwitchMetadata -VerifiedHash $script:CcSwitchSha256 | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($metadataPath, $metadataJson, (New-Object Text.UTF8Encoding($false)))
    }

    return (Get-CcSwitchStatus -RequestedSessionRoot $SessionRoot -RequestedDataRoot $DataRoot)
}

function Test-CcSwitchPathHasReparseComponent {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $false
}

function Get-CcSwitchClaudeProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Trim().Length -gt 80) { throw 'Profile name must contain 1 to 80 characters.' }
    if ($Name -match '[\x00-\x1f]') { throw 'Profile name contains unsupported control characters.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The selected Claude JSON file does not exist.' }
    if (Test-CcSwitchPathHasReparseComponent -Path $Path) { throw 'The selected JSON path must not include reparse points.' }
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($info.Length -gt 1048576) { throw 'The selected JSON file exceeds the 1 MiB safety limit.' }

    $rawJson = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::UTF8)
    try { $document = $rawJson | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The selected file is not valid JSON.' }
    finally { $rawJson = $null }
    return ConvertFrom-CcSwitchClaudeDocument -Document $document -Name $Name
}

switch ($Action) {
    'Status' { Get-CcSwitchStatus -RequestedSessionRoot $SessionRoot -RequestedDataRoot $DataRoot }
    'Prepare' { Invoke-CcSwitchPrepare }
    'Launch' {
        $status = Get-CcSwitchStatus -RequestedSessionRoot $SessionRoot -RequestedDataRoot $DataRoot
        throw $status.Reason
    }
    'ReadClaudeProfile' {
        if (-not $ProfilePath -or -not $ProfileName) { throw 'ReadClaudeProfile requires -ProfilePath and -ProfileName.' }
        Get-CcSwitchClaudeProfile -Path $ProfilePath -Name $ProfileName
    }
}

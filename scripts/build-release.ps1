[CmdletBinding()]
param(
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$')][string]$Version = '0.1.0',
    [switch]$StageOnly,
    [switch]$ArchiveOnly,
    [switch]$IncludeLinux
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
if ($StageOnly -and $ArchiveOnly) { throw 'StageOnly and ArchiveOnly are mutually exclusive.' }
$source = [IO.Path]::GetFullPath($SourceRoot)
if ($source -ne [IO.Path]::GetPathRoot($source)) { $source = $source.TrimEnd('\') }
$sourcePrefix = $source.TrimEnd('\')+'\'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output -eq [IO.Path]::GetPathRoot($output)) { throw 'Use a dedicated output subdirectory, not a drive root.' }
$output = $output.TrimEnd('\')
if ($output -eq $source.TrimEnd('\') -or $output.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Release output must be outside the source tree.' }
$platform = if ($IncludeLinux) { 'windows-linux-x64' } else { 'windows-x64' }
$name = 'portable-ai-toolbox-v'+$Version+'-'+$platform
$stage = Join-Path $output $name
$manifestPath = Join-Path $stage 'release-manifest.json'
$zipPath = Join-Path $output ($name+'.zip')
$checksumPath = Join-Path $output 'SHA256SUMS.txt'
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert-PlainPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point rejected.' }
        }
        $next = Split-Path -Parent $cursor
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
}
function Get-PlainFiles([string]$Root) {
    Assert-PlainPath $Root
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in release input.' }
        if ($item.PSIsContainer) { Get-PlainFiles $item.FullName } else { $item }
    }
}
function Copy-ReleaseFile([string]$From,[string]$Relative) {
    Assert-PlainPath $From
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Unsafe release path.' }
    $to = [IO.Path]::GetFullPath((Join-Path $stage $Relative))
    if (-not $to.StartsWith($stage+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Release path escaped.' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to))
    [IO.File]::Copy($From,$to,$false)
}
Assert-PlainPath $source
Assert-PlainPath $output
if (Test-Path -LiteralPath $checksumPath) { throw 'Checksum output already exists.' }
if (-not $ArchiveOnly) {
    if (Test-Path -LiteralPath $stage) { throw 'Staging directory already exists; use a fresh output directory.' }
    [void][IO.Directory]::CreateDirectory($stage)
    $dirty = @(& git -c ('safe.directory='+$source.Replace('\','/')) -C $source status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'Commit all tracked changes before building a release.' }
    $tracked = @(& git -c ('safe.directory='+$source.Replace('\','/')) -c core.quotepath=false -C $source ls-files)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate tracked source files.' }
    foreach ($relative in $tracked) {
        if ($relative -match '^(README\.md|AI\.cmd|AI设置\.cmd|AI诊断\.cmd|使用说明\.txt|harness/registry\.json)$' -or
            $relative -match '^scripts/[^/]+\.(ps1|py|cpp|cjs)$' -or $relative -match '^docs/[^/]+\.md$' -or
            ($IncludeLinux -and ($relative -match '^(AI|AI\.sh|AI设置\.sh|AI诊断\.sh)$' -or $relative -match '^scripts/[^/]+\.sh$'))) {
            Copy-ReleaseFile (Join-Path $source $relative) $relative
        }
    }
    # Exact program inventory from the verified, published Windows baseline.
    # Ignore all unlisted files, even if a user left them in a runtime directory.
    $programInventoryRelative = 'release-templates/windows-program-files.json'
    if ($programInventoryRelative -notin $tracked) { throw 'Windows program inventory must be tracked.' }
    $programInventoryPath = Join-Path $source $programInventoryRelative
    Assert-PlainPath $programInventoryPath
    $programInventory = [IO.File]::ReadAllText($programInventoryPath) | ConvertFrom-Json
    if ($programInventory.schema -ne 1 -or $programInventory.files.Count -lt 1 -or $programInventory.files.Count -gt 50000) { throw 'Invalid Windows program inventory.' }
    $programPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $programInventory.files) {
        $rel = [string]$entry.path
        if ($rel -notmatch '^(runtime/(node|git|python|uv)/|tools/(cc-switch/|cc-switch-adapter/|webview2/|harness/claude/slots/2\.1\.285(?:/|\.manifest\.json$)))' -or
            $rel -match '(^|/)\.\.(/|$)|[\\:]' -or -not $programPaths.Add($rel) -or
            [string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $entry.bytes -lt 0 -or $entry.bytes -ge 4GB) { throw 'Unsafe Windows program inventory entry.' }
        $inputFile = Join-Path $source $rel
        Assert-PlainPath $inputFile
        if ((Get-Item -LiteralPath $inputFile).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -ine $entry.sha256) { throw ('Windows program verification failed: '+$rel) }
        Copy-ReleaseFile $inputFile $rel
        if ((Get-FileHash -LiteralPath (Join-Path $stage $rel) -Algorithm SHA256).Hash -ine $entry.sha256) { throw ('Windows program changed while staging: '+$rel) }
    }
    if ($IncludeLinux) {
        # Only verified program archives enter a release. Never copy Linux sessions,
        # host caches, credentials or the user's encrypted configuration.
        $linuxManifestRelative = 'runtime/linux-x64/manifest.json'
        $linuxManifestInput = Join-Path $source $linuxManifestRelative
        Assert-PlainPath $linuxManifestInput
        $linuxManifest = [IO.File]::ReadAllText($linuxManifestInput) | ConvertFrom-Json
        if ($linuxManifest.platform -cne 'linux' -or $linuxManifest.arch -cne 'x64' -or
            $linuxManifest.versions.node -cne '22.23.3' -or $linuxManifest.versions.uv -cne '0.8.22' -or
            $linuxManifest.versions.ccSwitch -cne '3.20.4') { throw 'Linux runtime identity or pinned versions mismatch.' }
        $linuxAllowed = @(
            'runtime/linux-x64/node-runtime.tar.xz',
            'runtime/linux-x64/uv-runtime.tar.gz',
            'runtime/linux-x64/bwrap-runtime.tar.gz',
            'runtime/linux-x64/cc-switch.AppImage',
            'tools/linux-x64/python312-runtime.tar.gz',
            'tools/linux-x64/python312-manifest.json',
            'tools/linux-x64/git-runtime.tar.gz'
        )
        $inventory = @($linuxManifest.sha256.PSObject.Properties)
        if ($inventory.Count -ne $linuxAllowed.Count) { throw 'Linux runtime manifest inventory is incomplete.' }
        foreach ($entry in $inventory) {
            if ($entry.Name -cnotin $linuxAllowed -or [string]$entry.Value -notmatch '^[a-f0-9]{64}$') { throw 'Unexpected Linux release asset.' }
            $inputFile = Join-Path $source $entry.Name
            Assert-PlainPath $inputFile
            if ((Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -ine $entry.Value) { throw ('Linux asset verification failed: '+$entry.Name) }
            if ((Get-Item -LiteralPath $inputFile).Length -ge 4GB) { throw 'Linux asset exceeds the FAT32 file limit.' }
            Copy-ReleaseFile $inputFile $entry.Name
            if ((Get-FileHash -LiteralPath (Join-Path $stage $entry.Name) -Algorithm SHA256).Hash -ine $entry.Value) { throw ('Linux asset changed while staging: '+$entry.Name) }
        }
        Copy-ReleaseFile $linuxManifestInput $linuxManifestRelative
        $activeRelative = 'npm-global/linux-x64/active.json'
        $activeInput = Join-Path $source $activeRelative
        Assert-PlainPath $activeInput
        $activeHash = (Get-FileHash -LiteralPath $activeInput -Algorithm SHA256).Hash
        $active = [IO.File]::ReadAllText($activeInput) | ConvertFrom-Json
        if ([string]$active.slot -notmatch '^slots/\d+\.\d+\.\d+-[a-f0-9]{12}$' -or
            [string]$active.version -notmatch '^\d+\.\d+\.\d+$' -or
            [string]$active.archiveSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid active Linux Claude slot.' }
        if ($active.slot -cne ('slots/'+$active.version+'-'+$active.archiveSha256.Substring(0,12))) { throw 'Linux Claude slot identity mismatch.' }
        $slotRelative = 'npm-global/linux-x64/'+$active.slot
        $slotManifestInput = Join-Path $source ($slotRelative+'/manifest.json')
        Assert-PlainPath $slotManifestInput
        $slotManifest = [IO.File]::ReadAllText($slotManifestInput) | ConvertFrom-Json
        $slotArchiveInput = Join-Path $source ($slotRelative+'/claude-package.tar.gz')
        Assert-PlainPath $slotArchiveInput
        if ($slotManifest.name -cne '@anthropic-ai/claude-code' -or $slotManifest.version -cne $active.version -or
            $slotManifest.archiveSha256 -cne $active.archiveSha256 -or
            (Get-FileHash -LiteralPath $slotArchiveInput -Algorithm SHA256).Hash -ine $active.archiveSha256) { throw 'Linux Claude slot failed verification.' }
        Copy-ReleaseFile $slotArchiveInput ($slotRelative+'/claude-package.tar.gz')
        if ((Get-FileHash -LiteralPath (Join-Path $stage ($slotRelative+'/claude-package.tar.gz')) -Algorithm SHA256).Hash -ine $active.archiveSha256) { throw 'Linux Claude archive changed while staging.' }
        Copy-ReleaseFile $slotManifestInput ($slotRelative+'/manifest.json')
        Copy-ReleaseFile $activeInput $activeRelative
        if ((Get-FileHash -LiteralPath $activeInput -Algorithm SHA256).Hash -ine $activeHash) { throw 'Linux Claude active slot changed during release staging.' }
    }
    # Fresh defaults are explicit tracked templates, never the user's config tree.
    foreach ($file in @('config\settings.json','README-FIRST.txt','THIRD-PARTY-NOTICES.txt','licenses\CC-Switch-LICENSE','licenses\uv-LICENSE-APACHE','licenses\uv-LICENSE-MIT')) {
        $inputRelative = 'release-templates/'+$file.Replace('\','/')
        if ($inputRelative -notin $tracked) { throw 'Release template must be tracked.' }
        Copy-ReleaseFile (Join-Path $source $inputRelative) $file
    }
    $entries = @(Get-PlainFiles $stage | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $commit = & git -c ('safe.directory='+$source.Replace('\','/')) -C $source rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine source commit.' }
    $manifest = [ordered]@{schema=1;version=$Version;platform=$platform;sourceCommit=[string]$commit;files=$entries}
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),$utf8)
}
if ($StageOnly) { Write-Output ([pscustomobject]@{Stage=$stage;Files=$entries.Count}); return }
if (Test-Path -LiteralPath $zipPath) { throw 'Archive already exists.' }
Assert-PlainPath $stage
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($manifest.version -cne $Version -or $manifest.schema -ne 1 -or $manifest.platform -cne $platform -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Manifest identity mismatch.' }
$expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.files) {
    $rel = [string]$entry.path
    if ([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|[\\/])\.\.([\\/]|$)|:' -or -not $expected.Add($rel)) { throw 'Unsafe or duplicate manifest entry.' }
    $file = Join-Path $stage $rel
    Assert-PlainPath $file
    if ((Get-Item -LiteralPath $file).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.sha256) { throw ('Manifest mismatch: '+$rel) }
}
$actual = @(Get-PlainFiles $stage | Where-Object {$_.FullName -ine $manifestPath})
if ($actual.Count -ne $expected.Count) { throw 'Unexpected staging files.' }
foreach ($file in $actual) { if (-not $expected.Contains($file.FullName.Substring($stage.Length+1).Replace('\','/'))) { throw 'Unexpected staging path.' } }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in @($actual)+@(Get-Item -LiteralPath $manifestPath)) {
        $entryName=$name+'/'+$file.FullName.Substring($stage.Length+1).Replace('\','/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$entryName,[IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumPath,($hash+'  '+[IO.Path]::GetFileName($zipPath)+"`n"),$utf8)
Write-Output ([pscustomobject]@{Archive=$zipPath;Bytes=(Get-Item -LiteralPath $zipPath).Length;Sha256=$hash;Files=$actual.Count+1})

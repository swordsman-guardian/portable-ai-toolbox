[CmdletBinding()]
param(
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$')][string]$Version = '0.1.0',
    [switch]$StageOnly,
    [switch]$ArchiveOnly
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
$name = 'portable-ai-toolbox-v'+$Version+'-windows-x64'
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
function Copy-ReleaseTree([string]$Relative,[switch]$Runtime) {
    $root = Join-Path $source $Relative
    foreach ($file in Get-PlainFiles $root) {
        $inside = $file.FullName.Substring($root.TrimEnd('\').Length+1)
        if ($file.Name -match '^(\.env(?:\..*)?|\.gitconfig|\.git-credentials|\.netrc|_netrc|id_rsa|id_ed25519|credentials\.json|auth\.json)$' -or
            ($file.Name -eq '.npmrc' -and $file.Length -gt 0)) { throw 'Potential private runtime data rejected.' }
        if ($Runtime -and ($inside -match '(^|\\)__pycache__(\\|$)|\.(pyc|pyo|pdb)$')) { continue }
        Copy-ReleaseFile $file.FullName ($Relative+'\'+$inside)
    }
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
            $relative -match '^scripts/[^/]+\.(ps1|py|cpp|cjs)$' -or $relative -match '^docs/[^/]+\.md$') {
            Copy-ReleaseFile (Join-Path $source $relative) $relative
        }
    }
    foreach ($dir in @('runtime\node','runtime\git','runtime\python','runtime\uv')) { Copy-ReleaseTree $dir -Runtime }
    foreach ($dir in @('tools\cc-switch\app','tools\webview2\verified-runtime','tools\harness\claude\slots\2.1.285')) { Copy-ReleaseTree $dir }
    foreach ($file in @(
        'tools\cc-switch\CC-Switch-v3.20.4-Windows-Portable.zip',
        'tools\cc-switch-adapter\cc-switch-portable-updater-shim.dll',
        'tools\cc-switch-adapter\cc-switch-portable-update-noop.exe',
        'tools\cc-switch-adapter\cc-switch-portable-updater-shim.manifest.json',
        'tools\webview2\runtime-files.json','tools\webview2\runtime-manifest.json',
        'tools\webview2\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64.cab',
        'tools\harness\claude\slots\2.1.285.manifest.json'
    )) { Copy-ReleaseFile (Join-Path $source $file) $file }
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
    $manifest = [ordered]@{schema=1;version=$Version;platform='windows-x64';sourceCommit=[string]$commit;files=$entries}
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),$utf8)
}
if ($StageOnly) { Write-Output ([pscustomobject]@{Stage=$stage;Files=$entries.Count}); return }
if (Test-Path -LiteralPath $zipPath) { throw 'Archive already exists.' }
Assert-PlainPath $stage
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($manifest.version -cne $Version -or $manifest.schema -ne 1 -or $manifest.platform -cne 'windows-x64' -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Manifest identity mismatch.' }
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

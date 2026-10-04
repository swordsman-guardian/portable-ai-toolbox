[CmdletBinding()]
param(
    [string]$SourceRoot = '',
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$')][string]$Version = '0.2.0-alpha.1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$source = [IO.Path]::GetFullPath($SourceRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if (-not $output -or $output -eq [IO.Path]::GetPathRoot($output).TrimEnd('\') -or
    $output -eq $source.TrimEnd('\') -or $output.StartsWith($source.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use a new output directory outside the source checkout.'
}
if (Test-Path -LiteralPath $output) { throw 'Output already exists; use a fresh directory.' }
foreach ($target in @($source, (Split-Path -Parent $output))) {
    $cursor = [IO.Path]::GetFullPath($target)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse-point source/output rejected.' }
        $next = Split-Path -Parent $cursor
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
}
$gitOptions = @('-c', ('safe.directory='+$source.Replace('\','/')), '-c', 'core.quotepath=false', '-C', $source)
$dirty = @(& git @gitOptions status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'Commit tracked changes before creating a public archive.' }
$commit = [string](& git @gitOptions rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve source revision.' }
$paths = @(& git @gitOptions ls-tree -r --name-only $commit)
if ($LASTEXITCODE -ne 0) { throw 'Cannot list committed sources.' }
foreach ($required in @('LICENSE','README.md','SECURITY.md','CONTRIBUTING.md','docs/首次使用.md','docs/Release-v0.2.0.md','docs/第三方许可与公开发布.md','AI.cmd','AI.sh','准备Windows.cmd','scripts/prepare-windows.ps1','scripts/bootstrap-linux.sh')) {
    if ($required -cnotin $paths) { throw ('Missing public source requirement: '+$required) }
}
foreach ($relative in $paths) {
    if ($relative -match '^(config|sessions|logs|cache|workspace|runtime|tools|npm-global)/' -or
        $relative -match '(?i)\.(exe|dll|cab|zip|7z|tar|gz|xz|db|db3|sqlite|dpapi|env)$' -or
        [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)|[\\:]') {
        throw ('Non-source or personal-data path in committed public content: '+$relative)
    }
    $approvedRoot = @('.gitignore','.gitattributes','.gitleaks.toml','LICENSE','README.md','SECURITY.md','CONTRIBUTING.md','AI.cmd','AI.sh','AI设置.cmd','AI设置.sh','AI诊断.cmd','AI诊断.sh','准备Windows.cmd','使用说明.txt')
    $approvedTemplate = @('release-templates/README-FIRST.txt','release-templates/THIRD-PARTY-NOTICES.txt','release-templates/windows-program-files.json','release-templates/config/settings.json','release-templates/licenses/CC-Switch-LICENSE','release-templates/licenses/uv-LICENSE-APACHE','release-templates/licenses/uv-LICENSE-MIT')
    if ($relative -cnotin $approvedRoot -and $relative -cnotin $approvedTemplate -and
        $relative -cnotmatch '^scripts/[^/]+\.(ps1|cjs|cpp|py|sh)$' -and
        $relative -cnotmatch '^docs/[^/]+\.md$' -and
        $relative -cnotmatch '^\.github/workflows/[^/]+\.yml$' -and $relative -cne 'harness/registry.json') {
        throw ('Unreviewed source path: '+$relative)
    }
}
$tree = @(& git @gitOptions ls-tree -r $commit)
if ($LASTEXITCODE -ne 0 -or @($tree | Where-Object { $_ -match '^(120000|160000) ' }).Count) { throw 'Symlink/submodule archive input rejected.' }
[void][IO.Directory]::CreateDirectory($output)
$name = 'portable-ai-toolbox-v'+$Version+'-source'
$zipPath = Join-Path $output ($name+'.zip')
& git @gitOptions archive --format=zip ('--prefix='+$name+'/') ('--output='+$zipPath) $commit
if ($LASTEXITCODE -ne 0) { throw 'Committed-source export failed.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
$entries = New-Object System.Collections.Generic.List[object]
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        if (-not $entry.FullName.StartsWith($name+'/', [StringComparison]::Ordinal) -or $entry.Length -gt 64MB) { throw 'Unexpected source archive entry.' }
        $relative = $entry.FullName.Substring($name.Length+1)
        if ($relative -cnotin $paths) { throw ('Uncommitted archive entry: '+$relative) }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create(); $buffer = New-Object IO.MemoryStream
        try {
            $stream.CopyTo($buffer)
            $bytes = $buffer.ToArray()
            $strictUtf8 = New-Object Text.UTF8Encoding($false,$true)
            $sourceText = $strictUtf8.GetString($bytes)
            if ($sourceText.IndexOf([char]0) -ge 0) { throw ('Binary content in source archive: '+$relative) }
            $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
        }
        finally { $stream.Dispose(); $sha.Dispose(); $buffer.Dispose() }
        $entries.Add([ordered]@{path=$relative;bytes=$entry.Length;sha256=$hash})
    }
} finally { $zip.Dispose() }
if ($entries.Count -ne $paths.Count) { throw 'Committed-source archive file count mismatch.' }
$manifestPath = Join-Path $output 'release-manifest.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$manifest = [ordered]@{schema=1;version=$Version;artifactType='source';sourceCommit=$commit;containsThirdPartyBinaries=$false;files=$entries.ToArray()}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), $utf8)
$checksum = foreach ($file in @($zipPath,$manifestPath)) {
    (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+(Split-Path -Leaf $file)
}
[IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'), (($checksum -join "`n")+"`n"), $utf8)
[pscustomobject]@{Archive=$zipPath;SourceCommit=$commit;Files=$entries.Count;ThirdPartyBinaries=$false}

[CmdletBinding()]
param([switch]$PreflightOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\','/')
$script:OwnerPath = Join-Path $script:ProjectRoot '.aistick-open-source-preparation.json'
$script:OwnerKind = 'aistick-windows-preparation'
$script:BaseRuntimeReady = $false
$script:PreparationWriteStarted = $false
$script:WebViewVersion = '153.0.4234.48'
$script:WebViewArchive = 'Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64.cab'
$script:WebViewUrl = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/08cd33ee-d109-49b8-9301-9f0bea43c575/Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64.cab'
$script:WebViewSha256 = '11E8240CB0BC56DCD3E4498907203C251346F65107FE35A3A13E152C7D51C79E'
$script:WebViewBytes = [long]308509880
$script:CcSwitchVersion = '3.20.4'
$script:CcSwitchAsset = 'CC-Switch-v3.20.4-Windows-Portable.zip'
$script:CcSwitchUrl = 'https://github.com/farion1231/cc-switch/releases/download/v3.20.4/CC-Switch-v3.20.4-Windows-Portable.zip'
$script:CcSwitchSha256 = '227288532bfd4f3894d7d9916a8cf340d49957618d8e520229d30bdcc9f5b5d3'

function Write-OwnerRecord {
    param([Parameter(Mandatory=$true)][string]$State,[string]$ErrorText='',[object]$Receipt=$null)
    $record = [ordered]@{
        schema = 1
        kind = $script:OwnerKind
        state = $State
        sourceRoot = $script:ProjectRoot
        updatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        lastError = $ErrorText
        receipt = $Receipt
    }
    $tmp = $script:OwnerPath + '.tmp'
    [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $record -Depth 6),(New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($script:OwnerPath)) {
        try { [IO.File]::Replace($tmp,$script:OwnerPath,$null) }
        catch {
            $backup = $script:OwnerPath + '.replace-backup'
            if ([IO.File]::Exists($backup)) { throw '准备标记更新备份已存在，拒绝覆盖。' }
            [IO.File]::Move($script:OwnerPath,$backup)
            try { [IO.File]::Move($tmp,$script:OwnerPath) }
            catch {
                if (-not [IO.File]::Exists($script:OwnerPath) -and [IO.File]::Exists($backup)) { [IO.File]::Move($backup,$script:OwnerPath) }
                throw
            }
            [IO.File]::Delete($backup)
        }
    } else { [IO.File]::Move($tmp,$script:OwnerPath) }
}

function Assert-PlainPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            $attributes = [IO.File]::GetAttributes($cursor)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "拒绝经过联接点或符号链接：$cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if (-not $parent) { break }
        $cursor = $parent.FullName
    }
}

function Assert-NoReparseTree {
    param([Parameter(Mandatory=$true)][string]$Path)
    Assert-PlainPath $Path
    if (-not [IO.Directory]::Exists($Path)) { return }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $attrs = [IO.File]::GetAttributes($entry)
            if ($attrs -band [IO.FileAttributes]::ReparsePoint) { throw "准备目录中包含链接，已停止：$entry" }
            if ($attrs -band [IO.FileAttributes]::Directory) { $pending.Push($entry) }
        }
    }
}

function Test-ExactChildren {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Allowed)
    if (-not [IO.Directory]::Exists($Path)) { return }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
        if ($Allowed -notcontains [IO.Path]::GetFileName($entry)) { throw "发现非本入口管理的项目，拒绝覆盖：$entry" }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Invoke-VerifiedDownload {
    param([Parameter(Mandatory=$true)][string]$Url,[string[]]$FallbackUrls=@(),[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$ExpectedHash,[long]$ExpectedBytes=0,[int]$TimeoutSeconds=240,[int]$FirstSourceTimeoutSeconds=0,[string]$Accept)
    Assert-PlainPath $Destination
    if ([IO.File]::Exists($Destination)) {
        $existing = Get-Item -LiteralPath $Destination -Force
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($ExpectedBytes -gt 0 -and $existing.Length -ne $ExpectedBytes) -or
            (Get-Sha256 $Destination) -cne $ExpectedHash.ToUpperInvariant()) {
            throw "已存在的下载文件不符合固定校验值，未覆盖：$Destination"
        }
        return
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not [IO.File]::Exists($curl)) { throw 'Windows 自带的 curl.exe 缺失，无法下载固定校验的 WebView2 CAB。' }
    $parent = Split-Path -Parent $Destination
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $sources = @($Url) + @($FallbackUrls)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    for ($index=0; $index -lt $sources.Count; $index++) {
        $sourceUrl = [string]$sources[$index]
        $partial = $Destination + '.download-' + [guid]::NewGuid().ToString('N')
        try {
            Write-Host ('下载固定校验的依赖：' + $sourceUrl)
            $sourceTimeout = $TimeoutSeconds
            if ($index -eq 0 -and $FirstSourceTimeoutSeconds -gt 0) { $sourceTimeout = $FirstSourceTimeoutSeconds }
            $curlArgs = @('--fail','--location','--proto','=https','--proto-redir','=https','--noproxy','*','--connect-timeout','30','--max-time',([string]$sourceTimeout),'--silent','--show-error')
            if ($Accept) { $curlArgs += @('--header',('Accept: ' + $Accept)) }
            $curlArgs += @('--output',$partial,'--url',$sourceUrl)
            & $curl @curlArgs
            $curlExit = $LASTEXITCODE
            if ($curlExit -ne 0) { throw "HTTPS传输失败（curl $curlExit）。" }
            $count = (Get-Item -LiteralPath $partial).Length
            if ($ExpectedBytes -gt 0 -and $count -ne $ExpectedBytes) { throw '下载文件长度不符；拒绝尝试其他来源。' }
            if ((Get-Sha256 $partial) -cne $ExpectedHash.ToUpperInvariant()) { throw '下载文件 SHA-256 与固定校验值不符；拒绝尝试其他来源。' }
            [IO.File]::Move($partial,$Destination)
            return
        } catch {
            $failures.Add(($sourceUrl + ' -> ' + $_.Exception.Message))
            if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
            if ($_.Exception.Message -match '长度不符|SHA-256') { throw }
            if ($index -ge ($sources.Count - 1)) { throw ("所有已允许来源都失败：`n  " + ($failures -join "`n  ")) }
            Write-Warning '官方源传输失败，将尝试下一个固定校验来源。'
        }
    }
}

function Find-VsDevCmd {
    $vswhereCandidates = @()
    if (${env:ProgramFiles(x86)}) { $vswhereCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe') }
    if ($env:ProgramFiles) { $vswhereCandidates += (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe') }
    foreach ($vswhere in $vswhereCandidates) {
        if (-not [IO.File]::Exists($vswhere)) { continue }
        $installLines = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
        $vswhereExitCode = $LASTEXITCODE
        $install = @($installLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
        if ($vswhereExitCode -eq 0 -and $install.Count -gt 0) {
            $candidate = Join-Path ([string]$install) 'Common7\Tools\VsDevCmd.bat'
            if ([IO.File]::Exists($candidate)) { return $candidate }
        }
    }
    throw '这台准备机缺少 Visual Studio C++ x64 构建工具。安装“使用 C++ 的桌面开发”后重试；日常使用的电脑不需要安装 Visual Studio。'
}

function Get-PreparationReceipt {
    $relativePaths = @(
        'runtime\node\node.exe','runtime\uv\uv.exe','runtime\git\cmd\git.exe','runtime\git\bin\bash.exe','runtime\python\python.exe',
        'tools\cc-switch\CC-Switch-v3.20.4-Windows-Portable.zip','tools\cc-switch\metadata.json','tools\cc-switch\app\cc-switch.exe','tools\cc-switch\app\portable.ini',
        'tools\webview2\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64.cab','tools\webview2\runtime-manifest.json','tools\webview2\runtime-files.json',
        'tools\webview2\verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64\msedgewebview2.exe',
        'tools\cc-switch-adapter\cc-switch-portable-updater-shim.dll','tools\cc-switch-adapter\cc-switch-portable-update-noop.exe','tools\cc-switch-adapter\cc-switch-portable-updater-shim.manifest.json',
        'scripts\cc-switch-portable-updater-shim.cpp','scripts\cc-switch-portable-update-noop.cpp',
        'npm-global\claude.cmd','npm-global\node_modules\@anthropic-ai\claude-code\package.json',
        'npm-global\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
    )
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in $relativePaths) {
        $full = Join-Path $script:ProjectRoot $relative
        if (-not [IO.File]::Exists($full)) { throw "准备回执所需文件缺失：$relative" }
        Assert-PlainPath $full
        $files.Add([pscustomobject]@{path=$relative.Replace('\','/');sha256=(Get-Sha256 $full)})
    }
    return [ordered]@{files=$files.ToArray()}
}

function Test-CompletedReceipt {
    param([Parameter(Mandatory=$true)]$Record)
    if (-not $Record.receipt -or -not $Record.receipt.files -or $Record.receipt.files.Count -lt 15) { throw '完成标记缺少依赖文件校验回执。' }
    foreach ($item in @($Record.receipt.files)) {
        $relative = [string]$item.path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or [string]$item.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw '完成回执包含无效路径或哈希。' }
        $full = [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $relative.Replace('/','\')))
        if (-not $full.StartsWith($script:ProjectRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($full)) { throw "准备完成后的文件缺失：$relative" }
        Assert-PlainPath $full
        if ((Get-Sha256 $full) -cne ([string]$item.sha256).ToUpperInvariant()) { throw "准备完成后的文件校验失败：$relative" }
    }
    $packageRoot = Join-Path $script:ProjectRoot 'tools\cc-switch'
    $ccStatus = & (Join-Path $PSScriptRoot 'cc-switch.ps1') -Action Status -PackageRoot $packageRoot -ArchivePath (Join-Path $packageRoot $script:CcSwitchAsset)
    if (-not $ccStatus.ArchiveVerified -or -not $ccStatus.AppPrepared -or $ccStatus.Version -ne $script:CcSwitchVersion) { throw 'CC Switch 完成状态校验失败。' }
    if (-not (Test-WebViewManifest -RuntimeRoot (Join-Path $script:ProjectRoot 'tools\webview2'))) { throw 'WebView2 完成状态校验失败。' }
    $isolatedStatus = & (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action Status -StickRoot $script:ProjectRoot
    if (-not $isolatedStatus.PackageVerified -or -not $isolatedStatus.FixedRuntimeVerified) { throw 'CC Switch 隔离启动依赖复核失败。' }
}

function Test-WebViewManifest {
    param([Parameter(Mandatory=$true)][string]$RuntimeRoot)
    $archivePath = Join-Path $RuntimeRoot $script:WebViewArchive
    $manifestPath = Join-Path $RuntimeRoot 'runtime-manifest.json'
    $mapPath = Join-Path $RuntimeRoot 'runtime-files.json'
    $destination = Join-Path $RuntimeRoot 'verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    foreach ($path in @($archivePath,$manifestPath,$mapPath)) { if (-not [IO.File]::Exists($path)) { return $false } }
    if ((Get-Sha256 $archivePath) -cne $script:WebViewSha256 -or (Get-Item -LiteralPath $archivePath).Length -ne $script:WebViewBytes) { return $false }
    $meta = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($meta.version -cne $script:WebViewVersion -or $meta.architecture -cne 'x64' -or $meta.archive -cne $script:WebViewArchive -or $meta.sha256 -cne $script:WebViewSha256 -or $meta.sourceUrl -cne $script:WebViewUrl) { return $false }
    $map = [IO.File]::ReadAllText($mapPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($map.version -cne $script:WebViewVersion -or $map.root -cne 'verified-runtime/Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64' -or -not $map.files -or $map.files.Count -lt 1 -or $map.files.Count -gt 10000) { return $false }
    Assert-NoReparseTree $destination
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($map.files)) {
        $relative = [string]$record.path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$|:)' -or $relative.Contains(':') -or [string]$record.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { return $false }
        if (-not $expected.Add($relative.Replace('/','\'))) { return $false }
        $full = [IO.Path]::GetFullPath((Join-Path $destination $relative))
        if (-not $full.StartsWith($destination.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($full)) { return $false }
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne [long]$record.length -or (Get-Sha256 $full) -cne ([string]$record.sha256).ToUpperInvariant()) { return $false }
    }
    $actual = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($destination.TrimEnd('\'))
    while ($pending.Count) { $dir=$pending.Pop(); foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) { $attrs=[IO.File]::GetAttributes($entry); if ($attrs -band [IO.FileAttributes]::ReparsePoint) { return $false }; if ($attrs -band [IO.FileAttributes]::Directory) { $pending.Push($entry) } else { [void]$actual.Add($entry.Substring($destination.TrimEnd('\').Length+1)) } } }
    if ($actual.Count -ne $expected.Count -or -not $actual.SetEquals($expected)) { return $false }
    $exe = Join-Path $destination 'msedgewebview2.exe'
    if (-not [IO.File]::Exists($exe)) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $exe
    $item = Get-Item -LiteralPath $exe
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Microsoft' -and ([string]$item.VersionInfo.ProductVersion -like ($script:WebViewVersion+'*') -or [string]$item.VersionInfo.FileVersion -like ($script:WebViewVersion+'*')))
}

function Prepare-WebViewRuntime {
    $runtimeRoot = Join-Path $script:ProjectRoot 'tools\webview2'
    [IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
    Assert-NoReparseTree $runtimeRoot
    $marker = Join-Path $runtimeRoot '.aistick-preparation-owned'
    if ([IO.File]::Exists($marker) -and [IO.File]::ReadAllText($marker) -cne 'webview2-fixed-runtime-v1') { throw 'WebView2 目录的准备标记不匹配，未覆盖已有数据。' }
    if (-not [IO.File]::Exists($marker)) { [IO.File]::WriteAllText($marker,'webview2-fixed-runtime-v1',[Text.Encoding]::ASCII) }
    $cab = Join-Path $runtimeRoot $script:WebViewArchive
    Invoke-VerifiedDownload -Url $script:WebViewUrl -Destination $cab -ExpectedHash $script:WebViewSha256 -ExpectedBytes $script:WebViewBytes
    $manifestPath = Join-Path $runtimeRoot 'runtime-manifest.json'
    $manifest = [ordered]@{version=$script:WebViewVersion;architecture='x64';archive=$script:WebViewArchive;sha256=$script:WebViewSha256;sourceUrl=$script:WebViewUrl;documentationUrl='https://developer.microsoft.com/en-us/microsoft-edge/webview2/';extractedDirectory='verified-runtime/Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64';archiveBytes=$script:WebViewBytes;hashProvenance='SHA256 pin copied from the reviewed source manifest; bytes are verified before extraction'}
    if ([IO.File]::Exists($manifestPath)) {
        $existingManifest = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($existingManifest.version -cne $manifest.version -or $existingManifest.architecture -cne $manifest.architecture -or
            $existingManifest.archive -cne $manifest.archive -or $existingManifest.sha256 -cne $manifest.sha256 -or
            $existingManifest.sourceUrl -cne $manifest.sourceUrl -or $existingManifest.archiveBytes -ne $manifest.archiveBytes) {
            throw 'WebView2 release manifest exists but does not match the reviewed version and hash pin.'
        }
    } else {
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 4),(New-Object Text.UTF8Encoding($false)))
    }
    $destination = Join-Path $runtimeRoot 'verified-runtime\Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64'
    $mapPath = Join-Path $runtimeRoot 'runtime-files.json'
    if (Test-WebViewManifest $runtimeRoot) { return }
    if ([IO.File]::Exists($mapPath) -and [IO.File]::ReadAllText($mapPath,[Text.Encoding]::UTF8).Length -gt 0) { throw 'WebView2 文件清单已有内容但未通过验证；拒绝覆盖。' }
    if ([IO.Directory]::Exists($destination)) { Assert-NoReparseTree $destination; Remove-Item -LiteralPath $destination -Recurse -Force }
    $staging = Join-Path $runtimeRoot ('.extract-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
        if (-not [IO.File]::Exists($expand)) { throw 'Windows 系统缺少 expand.exe，无法提取 WebView2 CAB。' }
        & $expand '-F:*' $cab $staging
        if ($LASTEXITCODE -ne 0) { throw "WebView2 CAB 提取失败，expand 返回 $LASTEXITCODE。" }
        Assert-NoReparseTree $staging
        $browserCandidates = @(Get-ChildItem -LiteralPath $staging -Filter 'msedgewebview2.exe' -File -Recurse -ErrorAction Stop)
        if ($browserCandidates.Count -ne 1) { throw 'CAB 提取结果中没有唯一的 WebView2 主程序。' }
        $extractRoot = $browserCandidates[0].Directory.FullName
        $signature = Get-AuthenticodeSignature -LiteralPath $browserCandidates[0].FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'CAB 中的 WebView2 主程序没有通过 Microsoft 签名验证。' }
        $versionInfo = Get-Item -LiteralPath $browserCandidates[0].FullName
        if (([string]$versionInfo.VersionInfo.ProductVersion -notlike ($script:WebViewVersion+'*')) -and ([string]$versionInfo.VersionInfo.FileVersion -notlike ($script:WebViewVersion+'*'))) { throw 'CAB 中的 WebView2 主程序版本不符合 pin。' }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        if ([IO.Directory]::Exists($destination)) { throw 'WebView2 目标目录已出现，停止覆盖。' }
        [IO.Directory]::Move($extractRoot,$destination)
        $files = New-Object 'System.Collections.Generic.List[object]'
        $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($destination.TrimEnd('\'))
        while ($pending.Count) {
            $dir=$pending.Pop()
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
                $attrs=[IO.File]::GetAttributes($entry)
                if ($attrs -band [IO.FileAttributes]::ReparsePoint) { throw 'CAB 提取目录包含链接，已停止。' }
                if ($attrs -band [IO.FileAttributes]::Directory) { $pending.Push($entry) }
                else {
                    $full=Get-Item -LiteralPath $entry -Force
                    $files.Add([pscustomobject]@{path=$entry.Substring($destination.TrimEnd('\').Length+1).Replace('\','/');length=[long]$full.Length;sha256=(Get-Sha256 $entry)})
                    if ($files.Count -gt 10000) { throw 'WebView2 文件数量超过安全上限。' }
                }
            }
        }
        $fileMap = [ordered]@{version=$script:WebViewVersion;root='verified-runtime/Microsoft.WebView2.FixedVersionRuntime.153.0.4234.48.x64';files=@($files | Sort-Object path)}
        [IO.File]::WriteAllText($mapPath,(ConvertTo-Json -InputObject $fileMap -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if (-not (Test-WebViewManifest $runtimeRoot)) { throw '提取后的 WebView2 文件清单或签名校验失败。' }
    } finally {
        if ([IO.Directory]::Exists($staging)) { Assert-NoReparseTree $staging; Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Prepare-CcSwitch {
    $packageRoot = Join-Path $script:ProjectRoot 'tools\cc-switch'
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    Assert-NoReparseTree $packageRoot
    $archive = Join-Path $packageRoot $script:CcSwitchAsset
    Invoke-VerifiedDownload -Url 'https://api.github.com/repos/farion1231/cc-switch/releases/assets/581597612' -FallbackUrls @($script:CcSwitchUrl,('https://gh-proxy.com/' + $script:CcSwitchUrl)) -Accept 'application/octet-stream' -TimeoutSeconds 240 -FirstSourceTimeoutSeconds 1200 -Destination $archive -ExpectedHash $script:CcSwitchSha256 -ExpectedBytes 13750343
    $result = & (Join-Path $PSScriptRoot 'cc-switch.ps1') -Action Prepare -PackageRoot $packageRoot -ArchivePath $archive
    if (-not $result.ArchiveVerified -or -not $result.ExtractedFilesVerified) { throw 'CC Switch 官方 ZIP 或解压文件校验未通过。' }
    return $result
}

function Prepare-PortableUpdater {
    $vsDevCmd = $script:VsDevCmd
    $output = Join-Path $script:ProjectRoot 'tools\cc-switch-adapter'
    if ([IO.Directory]::Exists($output)) {
        Assert-NoReparseTree $output
        $expected = @('cc-switch-portable-update-noop.exe','cc-switch-portable-updater-shim.manifest.json','cc-switch-portable-updater-shim.dll','.aistick-preparation-owned')
        Test-ExactChildren -Path $output -Allowed $expected
        $marker = Join-Path $output '.aistick-preparation-owned'
        if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker,[Text.Encoding]::ASCII) -cne 'cc-switch-adapter-v1') { throw 'adapter 目录不是本准备入口创建的，未覆盖。' }
    } else {
        [IO.Directory]::CreateDirectory($output) | Out-Null
        [IO.File]::WriteAllText((Join-Path $output '.aistick-preparation-owned'),'cc-switch-adapter-v1',[Text.Encoding]::ASCII)
    }
    $dll = Join-Path $output 'cc-switch-portable-updater-shim.dll'
    $noop = Join-Path $output 'cc-switch-portable-update-noop.exe'
    $manifest = Join-Path $output 'cc-switch-portable-updater-shim.manifest.json'
    if ((Test-Path -LiteralPath $dll -PathType Leaf) -and (Test-Path -LiteralPath $noop -PathType Leaf) -and (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        $record = [IO.File]::ReadAllText($manifest,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $shimSource = Join-Path $script:ProjectRoot 'scripts\cc-switch-portable-updater-shim.cpp'
        $noopSource = Join-Path $script:ProjectRoot 'scripts\cc-switch-portable-update-noop.cpp'
        if ($record.sourceSha256 -ceq (Get-Sha256 $shimSource).ToLowerInvariant() -and $record.noopSourceSha256 -ceq (Get-Sha256 $noopSource).ToLowerInvariant() -and $record.dllSha256 -ceq (Get-Sha256 $dll).ToLowerInvariant() -and $record.noopExeSha256 -ceq (Get-Sha256 $noop).ToLowerInvariant()) { return $record }
        foreach ($path in @($dll,$noop,$manifest)) { Remove-Item -LiteralPath $path -Force }
    }
    & (Join-Path $PSScriptRoot 'build-cc-switch-portable-updater-shim.ps1') -OutputDirectory $output -VsDevCmd $vsDevCmd | Out-Null
    $record = [IO.File]::ReadAllText($manifest,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($record.dllSha256 -cne (Get-Sha256 $dll).ToLowerInvariant() -or $record.noopExeSha256 -cne (Get-Sha256 $noop).ToLowerInvariant()) { throw '已编译的更新适配器未通过清单校验。' }
    return $record
}

function Install-InitialClaude {
    $node = Join-Path $script:ProjectRoot 'runtime\node\node.exe'
    $installer = Join-Path $PSScriptRoot 'cc-switch-portable-claude-install.cjs'
    foreach ($path in @($node,$installer)) { if (-not [IO.File]::Exists($path)) { throw "首装 Claude Code 所需文件缺失：$path" } }
    $output = & $node $installer initial --root $script:ProjectRoot 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Claude Code 官方 registry 安装失败：' + ($output -join ' ')) }
    Write-Host ($output -join ' ')
    $pkg = Join-Path $script:ProjectRoot 'npm-global\node_modules\@anthropic-ai\claude-code\package.json'
    $manifest = [IO.File]::ReadAllText($pkg,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $exe = Join-Path $script:ProjectRoot 'npm-global\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
    if (-not [IO.File]::Exists($exe)) { throw 'Claude Code Windows x64 官方可执行文件缺失。' }
    $session = Join-Path $script:ProjectRoot 'runtime\session'
    foreach ($dir in @($session,(Join-Path $session 'profile'),(Join-Path $session 'temp'),(Join-Path $session 'appdata'),(Join-Path $session 'localappdata'),(Join-Path $session 'claude-config'))) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $process = New-Object Diagnostics.Process
    $psi = $process.StartInfo
    $psi.FileName = $exe
    $psi.Arguments = '--version'
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables.Clear()
    $psi.EnvironmentVariables['SystemRoot'] = $env:SystemRoot
    $psi.EnvironmentVariables['WINDIR'] = $env:SystemRoot
    $psi.EnvironmentVariables['PATH'] = (Join-Path $script:ProjectRoot 'runtime\node') + ';' + (Join-Path $env:SystemRoot 'System32')
    $psi.EnvironmentVariables['USERPROFILE'] = Join-Path $session 'profile'
    $psi.EnvironmentVariables['HOME'] = Join-Path $session 'profile'
    $psi.EnvironmentVariables['APPDATA'] = Join-Path $session 'appdata'
    $psi.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $session 'localappdata'
    $psi.EnvironmentVariables['TEMP'] = Join-Path $session 'temp'
    $psi.EnvironmentVariables['TMP'] = Join-Path $session 'temp'
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = Join-Path $session 'claude-config'
    try {
        if (-not $process.Start()) { throw 'Claude Code version check could not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            $null = $process.WaitForExit(10000)
            throw 'Claude Code version check exceeded 30 seconds.'
        }
        $stdout = [string]$stdoutTask.Result; $stderr = [string]$stderrTask.Result
        if ($process.ExitCode -ne 0 -or $stdout -notmatch [regex]::Escape([string]$manifest.version)) { throw ('Claude Code --version failed: ' + ($stderr.Trim())) }
        Write-Host ('Claude Code ' + $stdout.Trim() + ' 已安装并能在隔离的空配置目录下启动。') -ForegroundColor Green
    } finally { $process.Dispose() }
}

function Assert-FreshOrOwnedPreparation {
    $managedTop = @('runtime','tools','npm-global','logs','cache')
    if (-not [IO.File]::Exists($script:OwnerPath)) {
        foreach ($rel in @('config','sessions') + $managedTop) {
            $path = Join-Path $script:ProjectRoot $rel
            if (Test-Path -LiteralPath $path) { throw "目录不是全新源码目录（发现 $rel）；为保护现有设置、保险箱和会话，已停止。请在新 clone 的空源码目录运行。" }
        }
        return $false
    }
    Assert-PlainPath $script:OwnerPath
    $record = [IO.File]::ReadAllText($script:OwnerPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($record.schema -ne 1 -or $record.kind -cne $script:OwnerKind) { throw '准备归属标记不匹配，拒绝续跑。' }
    if ($record.state -ceq 'complete') {
        Test-CompletedReceipt -Record $record
        Write-Host 'Windows 依赖已准备完成并通过文件回执复核。首次配置供应商：双击 AI设置.cmd → 10 CC Switch → 8 联网。' -ForegroundColor Green
        return $true
    }
    if ([IO.Path]::GetFullPath([string]$record.sourceRoot) -ine $script:ProjectRoot) { throw '未完成的准备目录移动过位置，需回到原源码路径继续，未改动任何文件。' }
    if ($record.state -notin @('running','failed')) { throw '准备状态标记未知，拒绝续跑。' }
    if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'sessions')) { throw '发现 sessions 目录；为保护已有会话数据，拒绝续跑。' }
    $configRoot = Join-Path $script:ProjectRoot 'config'
    if (Test-Path -LiteralPath $configRoot) {
        Assert-NoReparseTree $configRoot
        $allowedSettings = Join-Path $configRoot 'settings.json'
        foreach ($file in [IO.Directory]::EnumerateFiles($configRoot,'*',[IO.SearchOption]::AllDirectories)) {
            if (-not [string]::Equals([IO.Path]::GetFullPath($file),[IO.Path]::GetFullPath($allowedSettings),[StringComparison]::OrdinalIgnoreCase)) { throw "准备重试时发现空模板以外的配置文件，已拒绝读取或覆盖：$file" }
        }
        Test-ExactChildren -Path $configRoot -Allowed @('settings.json')
        if ([IO.File]::Exists($allowedSettings)) {
            $template = [IO.File]::ReadAllBytes((Join-Path $script:ProjectRoot 'release-templates\config\settings.json'))
            $existing = [IO.File]::ReadAllBytes($allowedSettings)
            if ($existing.Length -ne $template.Length -or [Convert]::ToBase64String($existing) -cne [Convert]::ToBase64String($template)) { throw '准备重试时 config\settings.json 已偏离内置空模板，拒绝覆盖。' }
        }
    }
    foreach ($rel in @('runtime','tools','npm-global','logs','cache')) { Assert-NoReparseTree (Join-Path $script:ProjectRoot $rel) }
    Test-ExactChildren -Path (Join-Path $script:ProjectRoot 'runtime') -Allowed @('node','uv','git','python','updates','session')
    Test-ExactChildren -Path (Join-Path $script:ProjectRoot 'tools') -Allowed @('cc-switch','cc-switch-adapter','webview2','harness')
    return $false
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5) { throw '请在 Windows PowerShell 5.1 中运行本入口。' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw '当前准备流程仅支持 Windows x64。' }
    Assert-PlainPath $script:ProjectRoot
    $done = Assert-FreshOrOwnedPreparation
    if ($done) { return }
    if ($PreflightOnly) { Write-Host '预检查通过：目标目录为空，或只包含本入口标记的失败准备内容。没有创建或修改文件。'; return }
    # 在任何大文件下载之前确认准备机有 C++ 编译工具。
    $script:VsDevCmd = Find-VsDevCmd
    $script:PreparationWriteStarted = $true
    if (-not [IO.File]::Exists($script:OwnerPath)) {
        Write-OwnerRecord -State 'running'
        foreach ($rel in @('runtime','tools','npm-global')) { [IO.Directory]::CreateDirectory((Join-Path $script:ProjectRoot $rel)) | Out-Null }
    } else {
        Write-OwnerRecord -State 'running'
        foreach ($rel in @('runtime','tools','npm-global')) { [IO.Directory]::CreateDirectory((Join-Path $script:ProjectRoot $rel)) | Out-Null }
    }

    Write-Host '阶段 1/6：优先从官方站点准备 Node.js、Git、Python 和 uv；官方源限时失败时只使用源码固定版本的校验镜像。' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'bootstrap.ps1') -OfficialOnly -AllowVerifiedMirrors
    foreach ($relative in @('runtime\node\node.exe','runtime\git\cmd\git.exe','runtime\git\bin\bash.exe','runtime\python\python.exe','runtime\uv\uv.exe')) {
        if (-not [IO.File]::Exists((Join-Path $script:ProjectRoot $relative))) { throw "基础运行时仍缺少 $relative；仅基础准备失败。" }
    }
    $script:BaseRuntimeReady = $true

    Write-Host '阶段 2/6：下载并校验官方 CC Switch 和 WebView2 固定运行时。' -ForegroundColor Cyan
    $ccPackage = Prepare-CcSwitch
    Prepare-WebViewRuntime

    Write-Host '阶段 3/6：检查 Visual Studio C++ 工具链并编译更新适配器。' -ForegroundColor Cyan
    $adapter = Prepare-PortableUpdater

    Write-Host '阶段 4/6：按官方 registry 元数据和 SHA-512 校验安装 Claude Code。' -ForegroundColor Cyan
    Install-InitialClaude

    Write-Host '阶段 5/6：写入原生 CC Switch 的无密钥统一配置模板。未创建密码、供应商或 API 密钥。' -ForegroundColor Cyan
    $templatePath = Join-Path $script:ProjectRoot 'release-templates\config\settings.json'
    $settingsPath = Join-Path $script:ProjectRoot 'config\settings.json'
    if (-not [IO.File]::Exists($templatePath)) { throw '仓库中的 CC Switch 空配置模板缺失。' }
    [IO.Directory]::CreateDirectory((Join-Path $script:ProjectRoot 'config')) | Out-Null
    if ([IO.File]::Exists($settingsPath)) {
        $templateBytes = [IO.File]::ReadAllBytes($templatePath); $settingsBytes = [IO.File]::ReadAllBytes($settingsPath)
        if ($templateBytes.Length -ne $settingsBytes.Length -or [Convert]::ToBase64String($templateBytes) -cne [Convert]::ToBase64String($settingsBytes)) { throw 'config\settings.json 不是内置空模板，拒绝覆盖。' }
    } else { [IO.File]::Copy($templatePath,$settingsPath,$false) }

    Write-Host '阶段 6/6：检查隔离启动依赖和固定版本。' -ForegroundColor Cyan
    $status = & (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action Status -StickRoot $script:ProjectRoot
    if (-not $status.PackageVerified -or -not $status.FixedRuntimeVerified) {
        throw ('隔离启动依赖未全部就绪：' + (@($status.Reasons) -join ' '))
    }
    if (-not $status.LaunchAllowed) { Write-Host '依赖已准备；尚未设置主密码和供应商，因此尚不能实际启动会话。' -ForegroundColor Yellow }
    if (-not $adapter -or -not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'tools\cc-switch-adapter\cc-switch-portable-updater-shim.dll') -PathType Leaf)) { throw '更新适配器尚未完成校验。' }
    Write-OwnerRecord -State 'complete' -Receipt (Get-PreparationReceipt)
    Write-Host ''
    Write-Host 'Windows 源码准备完成。' -ForegroundColor Green
    Write-Host ('CC Switch ' + $ccPackage.Version + '、WebView2 ' + $script:WebViewVersion + '、更新适配器和 Claude Code 已通过校验。')
    Write-Host '准备机需要 Visual Studio C++ 工具链；日常使用这套源码的电脑不需要安装 Visual Studio。'
    Write-Host '尚未设置主密码或供应商密钥，也没有发起 API 请求。首次配置：AI设置.cmd → 10 CC Switch → 8 联网。'
} catch {
    if ($script:PreparationWriteStarted -and [IO.File]::Exists($script:OwnerPath)) { try { Write-OwnerRecord -State 'failed' -ErrorText ([string]$_.Exception.Message) } catch {} }
    $stageText = if ($script:BaseRuntimeReady) { '基础运行时准备成功，但完整 Windows 准备未完成。' } else { '基础运行时尚未全部准备成功。' }
    Write-Error -Message ($stageText + ' ' + $_.Exception.Message)
    exit 1
}

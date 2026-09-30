[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$VsDevCmd = 'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat'
)

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $OutputDirectory){$OutputDirectory=Join-Path $projectRoot 'tools\cc-switch-adapter'}
$outputFull=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if (-not (Test-Path -LiteralPath $VsDevCmd -PathType Leaf)) { throw 'Visual Studio x64 build environment is unavailable.' }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('ccsu-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
[IO.File]::WriteAllText((Join-Path $scratch '.ccsu-build-owned'),'build scratch v1',[Text.Encoding]::ASCII)
try {
    $source=Join-Path $PSScriptRoot 'cc-switch-portable-updater-shim.cpp'
    $noopSource=Join-Path $PSScriptRoot 'cc-switch-portable-update-noop.cpp'
    $temporaryDll=Join-Path $scratch 'cc-switch-portable-updater-shim.dll'
    $temporaryNoop=Join-Path $scratch 'cc-switch-portable-update-noop.exe'
    $batch=Join-Path $scratch 'build.cmd'
    $content=@"
@echo off
cd /d "$scratch"
if errorlevel 1 exit /b 19
call "$VsDevCmd" -no_logo -arch=x64
if errorlevel 1 exit /b 20
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD "$source" /link /OUT:"$temporaryDll" shell32.lib
if errorlevel 1 exit /b 21
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT "$noopSource" /link /OUT:"$temporaryNoop"
if errorlevel 1 exit /b 22
exit /b %errorlevel%
"@
    [IO.File]::WriteAllText($batch,$content,[Text.Encoding]::ASCII)
    & $env:ComSpec /d /c $batch
    if ($LASTEXITCODE -ne 0) { throw "Portable updater shim build failed with exit code $LASTEXITCODE." }
    $destination=Join-Path $outputFull 'cc-switch-portable-updater-shim.dll'
    $noopDestination=Join-Path $outputFull 'cc-switch-portable-update-noop.exe'
    $manifestPath=Join-Path $outputFull 'cc-switch-portable-updater-shim.manifest.json'
    $temporaryManifest=Join-Path $scratch 'manifest.json'
    $manifest=[ordered]@{
        schema=1
        architecture='x64'
        runtime='static-msvc-vcruntime'
        export='CCSU_InstallOpenerHook'
        source='scripts/cc-switch-portable-updater-shim.cpp'
        sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        dllSha256=(Get-FileHash -LiteralPath $temporaryDll -Algorithm SHA256).Hash.ToLowerInvariant()
        noopSource='scripts/cc-switch-portable-update-noop.cpp'
        noopSourceSha256=(Get-FileHash -LiteralPath $noopSource -Algorithm SHA256).Hash.ToLowerInvariant()
        noopExeSha256=(Get-FileHash -LiteralPath $temporaryNoop -Algorithm SHA256).Hash.ToLowerInvariant()
        executableSha256='e7ffb7d1385da943219ab09f72ae65152b276a608fc1d9ddf3cba9d692255283'
        nativeTrigger='Verified main-module CreateProcessW lifecycle call and GetFinalPathNameByHandleW owned-executable fallback; exact AppContainer batch and release URL only'
        mailbox='runtime/updates/portable-update.request'
    }
    [IO.File]::WriteAllText($temporaryManifest,(ConvertTo-Json -InputObject $manifest -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $temporaryDll -Destination $destination -Force
    Copy-Item -LiteralPath $temporaryNoop -Destination $noopDestination -Force
    Copy-Item -LiteralPath $temporaryManifest -Destination $manifestPath -Force
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.dllSha256) { throw 'Copied shim binary failed its generated digest check.' }
    if ((Get-FileHash -LiteralPath $noopDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.noopExeSha256) { throw 'Copied no-op child failed its generated digest check.' }
    Write-Output ('Built x64 shim: ' + $destination)
    Write-Output ('SHA-256: ' + $manifest.dllSha256)
}
finally {
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $scratchFull=[IO.Path]::GetFullPath($scratch).TrimEnd('\')
    $entry=Get-Item -LiteralPath $scratchFull -Force -ErrorAction SilentlyContinue
    if ($entry -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        [string]::Equals((Split-Path -Parent $scratchFull),$temp,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $scratchFull) -match '^ccsu-build-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath (Join-Path $scratchFull '.ccsu-build-owned') -PathType Leaf)) {
        Remove-Item -LiteralPath $scratchFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

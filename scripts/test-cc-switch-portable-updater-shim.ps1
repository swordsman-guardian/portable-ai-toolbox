[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$vsRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community'
$devCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) { throw 'Visual Studio x64 build environment is unavailable.' }

$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('ccsu-shim-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildRoot | Out-Null
Set-Content -LiteralPath (Join-Path $buildRoot '.ccsu-test-owned') -Value 'synthetic build output' -Encoding ASCII
try {
    $shimSource = Join-Path $PSScriptRoot 'cc-switch-portable-updater-shim.cpp'
    $noopSource = Join-Path $PSScriptRoot 'cc-switch-portable-update-noop.cpp'
    $hostSource = Join-Path $PSScriptRoot 'test-cc-switch-portable-updater-shim.cpp'
    $bat = Join-Path $buildRoot 'build-and-test.cmd'
    $batText = @"
@echo off
cd /d "$buildRoot"
if errorlevel 1 exit /b 19
call "$devCmd" -no_logo -arch=x64
if errorlevel 1 exit /b 20
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD "$shimSource" /link /OUT:"$buildRoot\cc-switch-portable-updater-shim.dll" shell32.lib
if errorlevel 1 exit /b 21
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT "$noopSource" /link /OUT:"$buildRoot\cc-switch-portable-update-noop.exe"
if errorlevel 1 exit /b 22
cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT "$hostSource" /link /OUT:"$buildRoot\shim-probe.exe" shell32.lib
if errorlevel 1 exit /b 23
mkdir "$buildRoot\fixtures"
mkdir "$buildRoot\fixtures\valid\app"
mkdir "$buildRoot\fixtures\valid\runtime\updates"
copy /y "$buildRoot\cc-switch-portable-update-noop.exe" "$buildRoot\fixtures\valid\app\cc-switch-portable-update-noop.exe" >nul
"$buildRoot\shim-probe.exe" "$buildRoot\cc-switch-portable-updater-shim.dll" valid "$buildRoot\fixtures\valid"
if errorlevel 1 exit /b 23
mkdir "$buildRoot\fixtures\nonmatching\app"
mkdir "$buildRoot\fixtures\nonmatching\runtime\updates"
copy /y "$buildRoot\cc-switch-portable-update-noop.exe" "$buildRoot\fixtures\nonmatching\app\cc-switch-portable-update-noop.exe" >nul
"$buildRoot\shim-probe.exe" "$buildRoot\cc-switch-portable-updater-shim.dll" nonmatching "$buildRoot\fixtures\nonmatching"
if errorlevel 1 exit /b 25
mkdir "$buildRoot\fixtures\lifecycle\app"
mkdir "$buildRoot\fixtures\lifecycle\runtime\updates"
mkdir "$buildRoot\fixtures\lifecycle\ac-temp"
copy /y "$buildRoot\cc-switch-portable-update-noop.exe" "$buildRoot\fixtures\lifecycle\app\cc-switch-portable-update-noop.exe" >nul
"$buildRoot\shim-probe.exe" "$buildRoot\cc-switch-portable-updater-shim.dll" lifecycle "$buildRoot\fixtures\lifecycle"
if errorlevel 1 exit /b 26
mkdir "$buildRoot\fixtures\invalid-nonce\app"
mkdir "$buildRoot\fixtures\invalid-nonce\runtime\updates"
copy /y "$buildRoot\cc-switch-portable-update-noop.exe" "$buildRoot\fixtures\invalid-nonce\app\cc-switch-portable-update-noop.exe" >nul
"$buildRoot\shim-probe.exe" "$buildRoot\cc-switch-portable-updater-shim.dll" invalid-nonce "$buildRoot\fixtures\invalid-nonce"
if errorlevel 1 exit /b 24
mkdir "$buildRoot\fixtures\invalid-path\app"
mkdir "$buildRoot\fixtures\invalid-path\runtime\updates"
copy /y "$buildRoot\cc-switch-portable-update-noop.exe" "$buildRoot\fixtures\invalid-path\app\cc-switch-portable-update-noop.exe" >nul
"$buildRoot\shim-probe.exe" "$buildRoot\cc-switch-portable-updater-shim.dll" invalid-path "$buildRoot\fixtures\invalid-path"
exit /b %errorlevel%
"@
    [IO.File]::WriteAllText($bat, $batText, [Text.Encoding]::ASCII)
    & $env:ComSpec /d /c $bat
    if ($LASTEXITCODE -ne 0) { throw "Native shim synthetic probe failed with exit code $LASTEXITCODE." }
}
finally {
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $buildFull = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\')
    $ownedMarker = Join-Path $buildFull '.ccsu-test-owned'
    $item = Get-Item -LiteralPath $buildFull -Force -ErrorAction SilentlyContinue
    if ($item -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        [string]::Equals((Split-Path -Parent $buildFull), $tempFull, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $buildFull) -match '^ccsu-shim-test-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $ownedMarker -PathType Leaf)) {
        Remove-Item -LiteralPath $buildFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

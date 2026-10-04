[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$guid = [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $tempRoot ('aistick-prepare-windows-test-' + $guid)
$fixtureMarker = Join-Path $fixtureRoot '.aistick-prepare-windows-test-owned'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$prepareSource = Join-Path $sourceRoot 'scripts\prepare-windows.ps1'
$templateSource = Join-Path $sourceRoot 'release-templates\config\settings.json'

function Assert-PrepareTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-PreparePreflight {
    param([string]$ProjectRoot)
    $scriptPath = Join-Path $ProjectRoot 'scripts\prepare-windows.ps1'
    $process = New-Object Diagnostics.Process
    $psi = $process.StartInfo
    $psi.FileName = $windowsPowerShell
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -PreflightOnly'
    $psi.WorkingDirectory = $ProjectRoot
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { throw 'Could not start Windows PowerShell 5.1 for preparation preflight.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { try { $process.Kill() } catch { }; throw 'Preparation preflight exceeded 15 seconds.' }
        $null = $stdoutTask.Result; $null = $stderrTask.Result
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}

try {
    if ([IO.Directory]::Exists($fixtureRoot) -or [IO.File]::Exists($fixtureRoot)) { throw 'Unique preparation test fixture path already exists.' }
    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'scripts')) | Out-Null
    [IO.File]::WriteAllText($fixtureMarker,'owned prepare-windows test fixture v1',[Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $prepareSource -Destination (Join-Path $fixtureRoot 'scripts\prepare-windows.ps1') -ErrorAction Stop
    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'release-templates\config')) | Out-Null
    Copy-Item -LiteralPath $templateSource -Destination (Join-Path $fixtureRoot 'release-templates\config\settings.json') -ErrorAction Stop

    $freshRoot = Join-Path $fixtureRoot 'fresh-source'
    [IO.Directory]::CreateDirectory($freshRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'scripts') -Destination $freshRoot -Recurse
    Assert-PrepareTest ((Invoke-PreparePreflight $freshRoot) -eq 0) 'A clean source directory did not pass read-only preflight.'
    foreach ($name in @('runtime','tools','npm-global','logs','cache','.aistick-open-source-preparation.json')) {
        Assert-PrepareTest (-not (Test-Path -LiteralPath (Join-Path $freshRoot $name))) "Read-only preflight unexpectedly created $name."
    }

    $usedRoot = Join-Path $fixtureRoot 'existing-config'
    [IO.Directory]::CreateDirectory((Join-Path $usedRoot 'scripts')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'scripts\prepare-windows.ps1') -Destination (Join-Path $usedRoot 'scripts\prepare-windows.ps1')
    $userSettings = Join-Path $usedRoot 'config\settings.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $userSettings)) | Out-Null
    [IO.File]::WriteAllText($userSettings,'user-settings-sentinel',[Text.Encoding]::UTF8)
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'release-templates') -Destination $usedRoot -Recurse
    $usedMarkerPath = Join-Path $usedRoot '.aistick-open-source-preparation.json'
    $usedMarkerRecord = [ordered]@{schema=1;kind='aistick-windows-preparation';state='failed';sourceRoot=$usedRoot;updatedUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ');lastError='synthetic';receipt=$null}
    [IO.File]::WriteAllText($usedMarkerPath,(ConvertTo-Json $usedMarkerRecord),(New-Object Text.UTF8Encoding($false)))
    $markerBefore = [IO.File]::ReadAllBytes($usedMarkerPath)
    Assert-PrepareTest ((Invoke-PreparePreflight $usedRoot) -ne 0) 'Preparation accepted a directory containing user configuration.'
    Assert-PrepareTest ([IO.File]::ReadAllText($userSettings,[Text.Encoding]::UTF8) -ceq 'user-settings-sentinel') 'Preparation changed existing user configuration.'
    $markerAfter = [IO.File]::ReadAllBytes($usedMarkerPath)
    Assert-PrepareTest ($markerBefore.Length -eq $markerAfter.Length -and [Convert]::ToBase64String($markerBefore) -ceq [Convert]::ToBase64String($markerAfter)) 'Rejected read-only preflight changed the ownership marker.'
    foreach ($name in @('runtime','tools','npm-global','logs','cache')) {
        Assert-PrepareTest (-not (Test-Path -LiteralPath (Join-Path $usedRoot $name))) "Rejected preflight created $name."
    }

    $retryRoot = Join-Path $fixtureRoot 'owned-failed-run'
    [IO.Directory]::CreateDirectory((Join-Path $retryRoot 'scripts')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'scripts\prepare-windows.ps1') -Destination (Join-Path $retryRoot 'scripts\prepare-windows.ps1')
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'release-templates') -Destination $retryRoot -Recurse
    foreach ($relative in @('runtime\node','tools\cc-switch','npm-global','logs','cache')) { [IO.Directory]::CreateDirectory((Join-Path $retryRoot $relative)) | Out-Null }
    $failedMarker = [ordered]@{schema=1;kind='aistick-windows-preparation';state='failed';sourceRoot=$retryRoot;updatedUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ');lastError='synthetic';receipt=$null}
    [IO.File]::WriteAllText((Join-Path $retryRoot '.aistick-open-source-preparation.json'),(ConvertTo-Json $failedMarker),(New-Object Text.UTF8Encoding($false)))
    $template = Join-Path $retryRoot 'release-templates\config\settings.json'
    [IO.Directory]::CreateDirectory((Join-Path $retryRoot 'config')) | Out-Null
    [IO.File]::Copy($template,(Join-Path $retryRoot 'config\settings.json'),$false)
    Assert-PrepareTest ((Invoke-PreparePreflight $retryRoot) -eq 0) 'An owned failed preparation with the exact empty settings template could not resume.'
    [IO.File]::WriteAllText((Join-Path $retryRoot 'config\settings.json'),'changed-user-settings',[Text.Encoding]::UTF8)
    Assert-PrepareTest ((Invoke-PreparePreflight $retryRoot) -ne 0) 'Retry accepted modified user settings instead of protecting them.'
    Assert-PrepareTest ([IO.File]::ReadAllText((Join-Path $retryRoot 'config\settings.json'),[Text.Encoding]::UTF8) -ceq 'changed-user-settings') 'Retry overwrote modified settings.'

    'PASS: Windows preparation clean-source preflight, user-config rejection, and exact-template retry protection'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
    $markerFile = Join-Path $resolvedRoot '.aistick-prepare-windows-test-owned'
    if ([IO.Directory]::Exists($resolvedRoot) -and
        [string]::Equals((Split-Path -Parent $resolvedRoot),$resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedRoot) -ceq ('aistick-prepare-windows-test-' + $guid) -and
        [IO.File]::Exists($markerFile) -and [IO.File]::ReadAllText($markerFile,[Text.Encoding]::ASCII) -ceq 'owned prepare-windows test fixture v1') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

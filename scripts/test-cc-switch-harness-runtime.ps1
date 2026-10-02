[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1'
. $modulePath

# The runtime must remain independent of module auto-loading and Get-FileHash.
function Get-FileHash { throw 'Get-FileHash cmdlet must not be required by harness runtime.' }

function Assert-HarnessRuntimeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$usbRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$sourceNode = Join-Path $usbRoot 'runtime\node'
$sourceNodeExe = Join-Path $sourceNode 'node.exe'
$sourceNpmCli = Join-Path $sourceNode 'node_modules\npm\bin\npm-cli.js'
foreach ($source in @($sourceNodeExe, $sourceNpmCli)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'The existing USB Node/npm source is incomplete; no host fallback is permitted.' }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$guid = [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $tempBase ('aistick-ac-probe-' + $guid)
$fixturePath = Join-Path $fixtureRoot 'fixture.json'
$profileProbe = Join-Path $PSScriptRoot 'appcontainer-probe.ps1'
$appDir = Join-Path $fixtureRoot 'app'
$syntheticStick = Join-Path $fixtureRoot 'stick'
$syntheticRuntime = Join-Path $fixtureRoot 'runtime'
$syntheticNode = Join-Path $syntheticRuntime 'node'
$nodeAlias = Join-Path $appDir 'cc-switch.exe'
$cleanupOk = $false

try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureRoot '.aistick-ac-probe'), 'synthetic appcontainer fixture v1', (New-Object Text.UTF8Encoding($false)))
    $hashFixtureRoot=Join-Path $fixtureRoot 'known-hash';[IO.Directory]::CreateDirectory($hashFixtureRoot)|Out-Null
    [IO.File]::WriteAllText((Join-Path $hashFixtureRoot 'known.txt'),'cc-switch-harness-runtime hash fixture v1',(New-Object Text.ASCIIEncoding))
    $knownInventory=Get-CcSwitchManagedHarnessTreeInventory -Path $hashFixtureRoot
    $knownEntry=@($knownInventory.Entries|Where-Object{-not $_.Directory})[0]
    Assert-HarnessRuntimeTest ($knownEntry.Hash -ceq 'A0238CBC2E00B11EE4992D62A9E4242BD1FE7BD117F3C8114C9C31539B1D9E6F') 'Managed tree hashing must match the known SHA-256 fixture without Get-FileHash.'
    foreach ($directory in @($appDir, $syntheticStick, $syntheticNode, (Join-Path $syntheticNode 'node_modules'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    Copy-Item -LiteralPath $sourceNodeExe -Destination (Join-Path $syntheticNode 'node.exe')
    Copy-Item -LiteralPath (Join-Path $sourceNode 'node_modules\npm') -Destination (Join-Path $syntheticNode 'node_modules\npm') -Recurse
    Copy-Item -LiteralPath (Join-Path $syntheticNode 'node.exe') -Destination $nodeAlias

    $status = Get-CcSwitchHarnessRuntimeStatus -StickRoot $usbRoot
    Assert-HarnessRuntimeTest $status.Ready 'USB runtime readiness should be true.'
    Assert-HarnessRuntimeTest (Test-CcSwitchHarnessRuntimeWithin -Path $status.NpmCli -Root $usbRoot) 'npm CLI escaped the USB root.'
    $plan = Get-CcSwitchHarnessNpmInstallPlan -StickRoot $usbRoot -Package '@example/synthetic'
    Assert-HarnessRuntimeTest (-not $plan.Executes) 'The plan API must be declarative and must not execute installs.'
    Assert-HarnessRuntimeTest ([string]::Equals($plan.InstallPrefix, (Join-Path $usbRoot 'npm-global'), [StringComparison]::OrdinalIgnoreCase)) 'npm prefix must be the USB managed prefix.'
    $localSpecRejected = $false
    try { Get-CcSwitchHarnessNpmInstallPlan -StickRoot $usbRoot -Package '..\host-target' | Out-Null } catch { $localSpecRejected = $true }
    Assert-HarnessRuntimeTest $localSpecRejected 'A local-path npm package spec must be rejected.'
    $environment = Get-CcSwitchHarnessRuntimeEnvironment -StickRoot $usbRoot
    Assert-HarnessRuntimeTest ($environment.PATH.StartsWith(($status.RuntimeRoot + ';'), [StringComparison]::OrdinalIgnoreCase)) 'Managed Node must lead the subprocess PATH.'
    Assert-HarnessRuntimeTest ($environment.PATH -notmatch [regex]::Escape($env:APPDATA)) 'Host AppData must not be injected into managed PATH.'
    foreach ($key in @('USERPROFILE','APPDATA','LOCALAPPDATA','TEMP','TMP','npm_config_prefix','npm_config_cache','npm_config_userconfig','npm_config_globalconfig','HOME')) {
        Assert-HarnessRuntimeTest (Test-CcSwitchHarnessRuntimeWithin -Path ([string]$environment[$key]) -Root $usbRoot) ("Environment value escaped StickRoot: " + $key)
    }

    $fixture = [ordered]@{
        Root = $fixtureRoot
        Exe = $nodeAlias
        StickRoot = $syntheticStick
        RuntimeRoot = $syntheticRuntime
        Environment = [ordered]@{
            HOME = $syntheticStick
            USERPROFILE = (Join-Path $fixtureRoot 'profile')
            APPDATA = (Join-Path $fixtureRoot 'profile\AppData\Roaming')
            LOCALAPPDATA = (Join-Path $fixtureRoot 'profile\AppData\Local')
            TEMP = (Join-Path $fixtureRoot 'profile\temp')
            TMP = (Join-Path $fixtureRoot 'profile\temp')
        }
        Arguments = @('--version')
    }
    [IO.File]::WriteAllText($fixturePath, (ConvertTo-Json -InputObject $fixture -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $nodeRun = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $profileProbe -Action Run -FixturePath $fixturePath -TimeoutSeconds 30 2>&1); $nodeExitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedErrorPreference }
    if ($nodeExitCode -ne 0) { throw ('AppContainer Node launch failed: ' + (ConvertTo-Json -InputObject $nodeRun -Compress)) }

    $fixture.Arguments = @((Join-Path $syntheticNode 'node_modules\npm\bin\npm-cli.js'), '--version')
    [IO.File]::WriteAllText($fixturePath, (ConvertTo-Json -InputObject $fixture -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $ErrorActionPreference = 'Continue'
    try { $npmRun = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $profileProbe -Action Run -FixturePath $fixturePath -TimeoutSeconds 30 2>&1); $npmExitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedErrorPreference }
    if ($npmExitCode -ne 0) { throw ('AppContainer npm CLI launch failed: ' + (ConvertTo-Json -InputObject $npmRun -Compress)) }

    Write-Output ([pscustomobject]@{
        RuntimeStatusReady = $status.Ready
        NpmPlanConfinedToStick = (Test-CcSwitchHarnessRuntimeWithin -Path $plan.InstallPrefix -Root $usbRoot)
        NodeAppContainerRun = 'Passed'
        NpmCliAppContainerRun = 'Passed'
        ModelRequestSent = $false
        HostInstallPerformed = $false
        SyntheticFixtureRoot = $fixtureRoot
    })
} finally {
    # Fixture root name is an exact unique child of the OS temp directory; remove only after probes exit.
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        if (-not (Test-CcSwitchHarnessRuntimeWithin -Path $fixtureRoot -Root $tempBase) -or
            (Split-Path -Parent ([IO.Path]::GetFullPath($fixtureRoot))).TrimEnd('\','/') -ine $tempBase -or
            (Split-Path -Leaf $fixtureRoot) -cne ('aistick-ac-probe-' + $guid)) { throw 'Refusing cleanup because the synthetic fixture path no longer matches its unique temp boundary.' }
        $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [string]::Equals($_.Path, $nodeAlias, [StringComparison]::OrdinalIgnoreCase) })
        if ($processes.Count -gt 0) { throw 'A synthetic AppContainer Node process is still running; fixture retained for inspection.' }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
        $cleanupOk = $true
    }
}

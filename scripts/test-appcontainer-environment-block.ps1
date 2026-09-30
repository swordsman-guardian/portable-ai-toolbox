[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

$hostHadPathExt = Test-Path Env:PATHEXT
$hostPathExt = if ($hostHadPathExt) { [string]$env:PATHEXT } else { $null }
$expectedPathExt = '.COM;.EXE;.BAT;.CMD'

function Read-TestEnvironmentBlock([string]$Block) {
    $result = @{}
    foreach ($entry in $Block.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)) {
        $separator = $entry.IndexOf('=')
        if ($separator -gt 0) { $result[$entry.Substring(0,$separator)] = $entry.Substring($separator+1) }
    }
    return $result
}

$defaultBlock = Read-TestEnvironmentBlock (New-AppContainerProbeEnvironmentBlock -Overrides ([pscustomobject]@{}))
if ($defaultBlock.PATHEXT -cne $expectedPathExt) { throw 'AppContainer environment did not set the fixed batch executable extensions.' }
Write-Host 'PASS AppContainer environment always supplies fixed PATHEXT'

$overrideBlock = Read-TestEnvironmentBlock (New-AppContainerProbeEnvironmentBlock -Overrides ([pscustomobject]@{PATHEXT='.PS1;.EXE'}))
if ($overrideBlock.PATHEXT -cne $expectedPathExt) { throw 'A fixture override changed the fixed AppContainer PATHEXT.' }
$hostHasPathExtAfter = Test-Path Env:PATHEXT
$hostPathExtAfter = if ($hostHasPathExtAfter) { [string]$env:PATHEXT } else { $null }
if ($hostHasPathExtAfter -ne $hostHadPathExt -or $hostPathExtAfter -cne $hostPathExt) { throw 'Constructing an AppContainer environment changed the host PATHEXT.' }
Write-Host 'PASS PATHEXT override is ignored and host environment stays unchanged'

$fixtureRoot = New-AppContainerProbeFixtureRoot
$fixtureGuid = (Split-Path -Leaf $fixtureRoot).Substring('aistick-ac-probe-'.Length)
try {
    $app = Join-Path $fixtureRoot 'app'
    $stick = Join-Path $fixtureRoot 'stick'
    $runtime = Join-Path $fixtureRoot 'runtime'
    foreach ($path in @($app,$stick,$runtime)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $exe = Join-Path $app 'cc-switch.exe'
    [IO.File]::WriteAllText($exe,'synthetic fixture executable',(New-Object Text.UTF8Encoding($false)))
    $fixture = [ordered]@{
        Root = $fixtureRoot
        Exe = $exe
        StickRoot = $stick
        RuntimeRoot = $runtime
        Environment = [ordered]@{HOME=$stick;USERPROFILE=$stick;APPDATA=$stick;LOCALAPPDATA=$stick;TEMP=$stick;TMP=$stick}
        Arguments = @()
    }
    $fixturePath = Join-Path $fixtureRoot 'fixture.json'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    Read-AppContainerFixture -Path $fixturePath | Out-Null
    $fixture.Environment['PATHEXT'] = '.PS1;.EXE'
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $rejected = $false
    try { Read-AppContainerFixture -Path $fixturePath | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Fixture reader accepted a caller-supplied PATHEXT override.' }
    Write-Host 'PASS fixture reader rejects caller-supplied PATHEXT'
} finally {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($fixtureRoot))).TrimEnd('\','/') -ine $temp -or (Split-Path -Leaf $fixtureRoot) -cne ('aistick-ac-probe-' + $fixtureGuid)) { throw 'Refusing cleanup outside the unique synthetic fixture boundary.' }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}

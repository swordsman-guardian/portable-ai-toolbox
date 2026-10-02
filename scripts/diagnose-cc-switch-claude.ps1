[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')

$usbRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = $null
$state = $null
$cleanupSafe = $false
$phase = 'preflight'
$report = [ordered]@{
    schema = 1
    diagnostic = 'cc-switch-claude-discovery'
    startedUtc = [DateTime]::UtcNow.ToString('o')
    osVersion = [Environment]::OSVersion.Version.ToString()
    is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    is64BitProcess = [Environment]::Is64BitProcess
    phase = $phase
    outcome = 'failed'
    probes = [ordered]@{}
    errorCategory = $null
    errorHResult = $null
    cleanup = 'pending'
}

function Get-DiagnosticCategory([string]$Message) {
    if ($Message -match 'runtime is incomplete') { return 'usb-runtime-incomplete' }
    if ($Message -match 'Claude installation is incomplete|No valid stable Claude|No saved public Claude') { return 'usb-claude-package-missing' }
    if ($Message -match 'timed out|exceeded') { return 'timeout' }
    if ($Message -match 'worker exited') { return 'worker-nonzero-exit' }
    if ($Message -match 'AppContainer|profile|token') { return 'appcontainer-failure' }
    return 'diagnostic-setup-failure'
}

function Remove-DiagnosticOwnedRoot([string]$Path) {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $leaf = Split-Path -Leaf $full
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact(($leaf -replace '^aistick-ac-probe-',''),'N',[ref]$guid) -or
        $leaf -cne ('aistick-ac-probe-' + $guid.ToString('N')) -or
        -not [string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$temp,[StringComparison]::OrdinalIgnoreCase)) { throw 'Owned diagnostic root identity did not validate.' }
    Assert-AppContainerProbePlainTree -Path $full -Boundary $temp
    $marker = Join-Path $full '.aistick-ac-probe'
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker).Trim() -cne 'synthetic appcontainer fixture v1') { throw 'Owned diagnostic marker did not validate.' }
    if ([IO.File]::Exists((Join-Path $full '.aistick-appcontainer-profile-owner.json'))) { throw 'AppContainer profile marker remains; refusing to remove its owned root.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

try {
    $phase = 'validate-usb-runtime-and-claude'
    $report.phase = $phase
    Write-Host '检查U盘内的Node与Claude文件…'
    $source = Get-CcSwitchHarnessRuntimeStatus -StickRoot $usbRoot
    if (-not $source.Ready) { throw 'USB Node/npm runtime is incomplete.' }

    $root = New-AppContainerProbeFixtureRoot
    $ownedRoot = $root
    $runtimeRoot = Join-Path $ownedRoot 'runtime'
    $stickRoot = Join-Path $ownedRoot 'stick'
    $sessionRoot = Join-Path $runtimeRoot 'session'
    $reportPath = Join-Path $stickRoot 'claude-diagnostic-result.json'

    $phase = 'copy-owned-payload'
    $report.phase = $phase
    Write-Host '复制U盘内的Claude与运行环境到临时隔离目录（可能需要一些时间）…'
    [IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    . (Join-Path $PSScriptRoot 'cc-switch-isolated-managed-owner.ps1')
    $contextOwner = Initialize-CcSwitchIsolatedManagedHarness -UsbRoot $usbRoot -OwnedRoot $ownedRoot -StickRoot $stickRoot -SessionRoot $sessionRoot -RuntimeRoot $runtimeRoot
    $managed = $contextOwner.ManagedSession
    if (-not $managed.Ready) { throw 'Managed Claude session runtime is incomplete.' }
    $slotPath = Join-Path $managed.ManagedHarnessRoot ('slots\' + $managed.SlotId)
    $slot = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $managed.ManagedHarnessRoot -SlotId $managed.SlotId
    if (-not $slot.Valid) { throw 'Managed Claude slot failed validation.' }
    $environment = $contextOwner.Environment

    $phase = 'prepare-worker'
    $report.phase = $phase
    $app = Join-Path $root 'app'
    [IO.Directory]::CreateDirectory($app) | Out-Null
    $workerExe = Join-Path $app 'cc-switch.exe'
    # Use Windows' command interpreter directly: Node child_process can block
    # before returning a child handle under an AppContainer on some hosts.
    [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\cmd.exe'),$workerExe,$false)
    $shimRelative = '..\harness\slots\' + $managed.SlotId + '\claude.cmd'
    $exeRelative = '..\' + ([string]$slot.ExecutablePath).Substring($root.Length + 1)
    $commands = [ordered]@{
        where = '"%SystemRoot%\System32\where.exe" $PATH:claude'
        shim = 'call "' + $shimRelative + '" --version'
        directExe = '"' + $exeRelative + '" --version'
    }
    $phase = 'run-appcontainer-probes'
    $report.phase = $phase
    foreach ($name in $commands.Keys) {
        Write-Host ('Testing isolated Claude: ' + $name + ' ...')
        $workerPath = Join-Path $app ($name + '.cmd')
        $outputPath = Join-Path $stickRoot ($name + '.txt')
        $batch = "@echo off`r`n" + $commands[$name] + ' >"..\stick\' + $name + '.txt" 2>&1' + "`r`nexit /b %errorlevel%`r`n"
        [IO.File]::WriteAllText($workerPath,$batch,[Text.Encoding]::ASCII)
        $fixturePath = Join-Path $root ($name + '-fixture.json')
        $fixture = [ordered]@{
            Root=$root; Exe=$workerExe; StickRoot=$stickRoot; RuntimeRoot=$runtimeRoot
            ManagedHarnessRoot=$managed.ManagedHarnessRoot; Environment=$environment
            Arguments=@('/D','/S','/C',($name + '.cmd'))
        }
        [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 6),(New-Object Text.UTF8Encoding($false)))
        $validated = Read-AppContainerFixture -Path $fixturePath
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $state = Start-AppContainerProbeProcess -Fixture $validated -NetworkMode None
        $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 25
        # Always terminate this probe's complete Job before reading its output.
        Complete-AppContainerProbeProcess -State $state
        $state = $null
        $output = ''
        if ([IO.File]::Exists($outputPath)) {
            Assert-AppContainerProbePlainTree -Path $outputPath -Boundary $root
            if ((Get-Item -LiteralPath $outputPath).Length -le 65536) { $output=[IO.File]::ReadAllText($outputPath) }
        }
        $version = $null
        if ($name -eq 'where' -and $output) {
            Write-Verbose ($output.Replace($root,'<temporary>').Replace($usbRoot,'<USB>').Trim())
        }
        if ($name -ne 'where' -and $output -match '\b(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)\b') { $version=$Matches[1] }
        $result = if (-not $wait.Completed) { 'timeout' } elseif ($wait.ExitCode -ne 0) { 'nonzero-exit' } elseif ($name -eq 'where') { 'found' } elseif ($version) { 'ok' } else { 'no-version-output' }
        $report.probes[$name] = [ordered]@{
            result=$result
            exitCode=if($wait.Completed){[int64]$wait.ExitCode}else{$null}
            exitHex=if($wait.Completed){'0x{0:X8}' -f [uint32]$wait.ExitCode}else{$null}
            version=$version
            elapsedMs=[int]$timer.ElapsedMilliseconds
        }
    }
    $report.claudePackageVersion = [string]$managed.PackageVersion
    $report.outcome = 'complete'
    $phase = 'complete'
    $report.phase = $phase
} catch {
    $report.phase = $phase
    $report.errorCategory = Get-DiagnosticCategory $_.Exception.Message
    $report.errorHResult = ([int]$_.Exception.HResult).ToString('X8')
    Write-Warning ('Claude诊断未完成，报告会记录阶段分类：' + $report.errorCategory)
} finally {
    if ($state) {
        try {
            Complete-AppContainerProbeProcess -State $state
            $state = $null
            $cleanupSafe = $true
        } catch {
            $report.cleanup = 'appcontainer-cleanup-failed-fixture-retained'
            $report.cleanupHResult = ([int]$_.Exception.HResult).ToString('X8')
            $cleanupSafe = $false
        }
    } else { $cleanupSafe = $true }
    if ($root -and $cleanupSafe) {
        try {
            Remove-DiagnosticOwnedRoot -Path $root
            $report.cleanup = 'complete'
        } catch {
            $report.cleanup = 'owned-root-retained-after-validation-failure'
            $report.cleanupHResult = ([int]$_.Exception.HResult).ToString('X8')
        }
    }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $logs = Join-Path $usbRoot 'logs'
    try {
        Assert-CcSwitchHarnessRuntimePlainPath -Path $logs -Boundary $usbRoot
        [IO.Directory]::CreateDirectory($logs) | Out-Null
        Assert-CcSwitchHarnessRuntimePlainPath -Path $logs -Boundary $usbRoot
        $name = 'cc-switch-claude-diagnostic-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N') + '.json'
        $destination = Join-Path $logs $name
        $json = ConvertTo-Json -InputObject $report -Depth 8
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$json)
        $stream = New-Object IO.FileStream($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Write-Host ('诊断报告已保存：logs\' + $name)
    } catch {
        Write-Warning '无法写入U盘logs目录；报告未写入其他位置。'
    }
}

if ($report.outcome -eq 'complete') { Write-Host 'Claude诊断完成。' } else { Write-Host ('Claude诊断结束：' + [string]$report.errorCategory) }
foreach ($name in @('where','shim','directExe')) {
    if ($report.probes.Contains($name)) {
        $probe = $report.probes[$name]
        Write-Host ('{0}: result={1}, exit={2}, version={3}' -f $name,[string]$probe.result,[string]$probe.exitHex,[string]$probe.version)
    }
}
if ($report.outcome -ne 'complete' -or $report.cleanup -ne 'complete') { exit 1 }

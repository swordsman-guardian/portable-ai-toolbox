[CmdletBinding()]
param(
    [switch]$ProbeChild,
    [string]$ProbeRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($ProbeChild) {
    if ([string]::IsNullOrWhiteSpace($ProbeRoot)) { exit 20 }

    if (-not ('CcKnownFolderProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcKnownFolderProbe
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
        uint dwFlags,
        IntPtr hToken,
        out IntPtr ppszPath);

    [DllImport("ole32.dll")]
    private static extern void CoTaskMemFree(IntPtr pv);

    public sealed class QueryResult
    {
        public int HResult { get; set; }
        public string Path { get; set; }
    }

    public static QueryResult Query(Guid id)
    {
        IntPtr value = IntPtr.Zero;
        // dirs-sys 0.4.1 calls SHGetKnownFolderPath with dwFlags = 0.
        int result = SHGetKnownFolderPath(id, 0, IntPtr.Zero, out value);
        try
        {
            return new QueryResult {
                HResult = result,
                Path = result == 0 && value != IntPtr.Zero ? Marshal.PtrToStringUni(value) : null
            };
        }
        finally { if (value != IntPtr.Zero) CoTaskMemFree(value); }
    }
}
'@
    }

    $root = [IO.Path]::GetFullPath($ProbeRoot).TrimEnd('\') + '\'
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $isUnderRoot = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
        return $full.StartsWith($root, $comparison)
    }

    $envChecks = [ordered]@{
        HOME = (& $isUnderRoot $env:HOME)
        USERPROFILE = (& $isUnderRoot $env:USERPROFILE)
        APPDATA = (& $isUnderRoot $env:APPDATA)
        LOCALAPPDATA = (& $isUnderRoot $env:LOCALAPPDATA)
    }
    $knownFolders = [ordered]@{}
    foreach ($folder in @(
        [pscustomobject]@{ Name = 'Profile'; Id = '5E6C858F-0E22-4760-9AFE-EA3317B67173' },
        [pscustomobject]@{ Name = 'RoamingAppData'; Id = '3EB685DB-65F9-4CF6-A03A-E3EF65729F3D' },
        [pscustomobject]@{ Name = 'LocalAppData'; Id = 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091' }
    )) {
        $query = [CcKnownFolderProbe]::Query([Guid]$folder.Id)
        $inRoot = $null
        if ($query.HResult -eq 0 -and -not [string]::IsNullOrWhiteSpace($query.Path)) {
            $inRoot = [bool](& $isUnderRoot $query.Path)
        }
        $knownFolders[$folder.Name] = [pscustomobject]@{
            Success = ($query.HResult -eq 0 -and -not [string]::IsNullOrWhiteSpace($query.Path))
            HResult = ('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$query.HResult), 0))
            InRoot = $inRoot
        }
    }
    [pscustomobject]@{ Environment = $envChecks; KnownFolders = $knownFolders } | ConvertTo-Json -Compress -Depth 5
    exit 0
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This path probe requires Windows.'
}

$testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$leaf = 'cc-switch-path-boundary-' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $testParent $leaf
$childScript = Join-Path $testRoot 'probe-child.ps1'
$markerPath = Join-Path $testRoot '.created-by-test-cc-path-boundary'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$childSource = [IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8)

try {
    New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText($markerPath, 'synthetic path-boundary probe', $utf8Bom)
    [IO.File]::WriteAllText($childScript, $childSource, $utf8Bom)

    $envRoot = Join-Path $testRoot 'redirected-env'
    $envAppData = Join-Path $envRoot 'AppData\Roaming'
    $envLocalAppData = Join-Path $envRoot 'AppData\Local'
    foreach ($directory in @($envRoot, $envAppData, $envLocalAppData)) {
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    }

    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { $powershellPath = Join-Path $PSHOME 'pwsh.exe' }
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { throw 'Could not locate a PowerShell executable for the isolated child process.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ProbeChild -ProbeRoot "{1}"' -f $childScript, $testRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['HOME'] = $envRoot
    $startInfo.EnvironmentVariables['USERPROFILE'] = $envRoot
    $startInfo.EnvironmentVariables['APPDATA'] = $envAppData
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $envLocalAppData

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit() } catch { }
        throw 'The hidden synthetic probe process did not finish within 30 seconds.'
    }
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    if ($process.ExitCode -ne 0) { throw "The synthetic child probe failed (exit $($process.ExitCode)). $stderr" }
    $result = $stdout | ConvertFrom-Json -ErrorAction Stop

    Write-Output 'Path behavior probe only; CC Switch GUI was not run.'
    Write-Output 'SHGetKnownFolderPath flags: 0 (dirs-sys 0.4.1).'
    $environmentPassed = $true
    foreach ($property in $result.Environment.PSObject.Properties) {
        $isInRoot = [bool]$property.Value
        Write-Output ('Environment {0}: InRoot={1}' -f $property.Name, $isInRoot)
        if (-not $isInRoot) { $environmentPassed = $false }
    }
    $knownFoldersPassed = $true
    foreach ($property in $result.KnownFolders.PSObject.Properties) {
        $folder = $property.Value
        $inRootText = if ($null -eq $folder.InRoot) { '<null>' } else { [string][bool]$folder.InRoot }
        Write-Output ('KnownFolder {0}: Success={1} HResult={2} InRoot={3}' -f $property.Name, [bool]$folder.Success, [string]$folder.HResult, $inRootText)
        if (-not $folder.Success) { $knownFoldersPassed = $false }
        if ($property.Name -eq 'Profile' -and $folder.Success -and $folder.InRoot -ne $false) { $knownFoldersPassed = $false }
    }
    if (-not $environmentPassed) { throw 'Probe failed: one or more synthetic environment paths did not resolve under the dedicated test root.' }
    if (-not $knownFoldersPassed) { throw 'Probe failed or is indeterminate: all Known Folder queries must succeed, and Profile must resolve outside the dedicated test root.' }
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedParent = [IO.Path]::GetFullPath((Split-Path -Parent $testRoot)).TrimEnd('\')
        $resolvedRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
        $expectedLeafPattern = '^cc-switch-path-boundary-[0-9a-f]{32}$'
        $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
        if ($resolvedParent.Equals($testParent, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedRoot) -match $expectedLeafPattern -and
            $markerExists -and
            -not ((Get-Item -LiteralPath $testRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
        } else {
            Write-Warning 'Cleanup skipped because the temporary test-root identity checks did not match.'
        }
    }
}

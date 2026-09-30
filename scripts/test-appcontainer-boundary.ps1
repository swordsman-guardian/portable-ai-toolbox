[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

$script:passed = 0
$script:failed = 0
$script:fixtureRoot = $null
$script:hostRoot = $null
$script:state = $null
$script:hostMutex = $null
$script:cleanupSafe = $true
$script:proxyEnvironmentBefore = $null

function Assert-BoundaryTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-BoundaryTest {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-ProxyEnvironmentSnapshot {
    $snapshot = @{}
    foreach ($name in @('NO_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        $entry = Get-ChildItem Env: | Where-Object { [string]::Equals($_.Name, $name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        $snapshot[$name] = [pscustomobject]@{ Present = ($null -ne $entry); Value = $(if ($null -ne $entry) { [string]$entry.Value } else { $null }) }
    }
    return $snapshot
}

function Set-SyntheticHostOnlyDirectoryAcl {
    param([string]$Path)
    $acl = [IO.Directory]::GetAccessControl($Path)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRuleAll($_) }
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    foreach ($sid in @($userSid, $systemSid, $adminSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($Path, $acl)
}

function Remove-OwnedTempTree {
    param([string]$Path, [string]$Prefix)
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $full
    $guid = [guid]::Empty
    if (-not $leaf.StartsWith($Prefix, [StringComparison]::Ordinal) -or
        -not [guid]::TryParseExact(($leaf.Substring($Prefix.Length)), 'N', [ref]$guid) -or
        -not [string]::Equals((Split-Path -Parent $full).TrimEnd('\', '/'), $tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup refused a path outside this script-owned unique temp directory.'
    }
    $links = @(Get-ChildItem -LiteralPath $full -Force -Recurse -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count -gt 0) { throw 'Cleanup refused a synthetic tree containing reparse points.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

$workerSource = @'
using System;
using System.IO;
using System.Security;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class AppContainerBoundaryWorker {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);

    static bool IsAppContainer() {
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr value = Marshal.AllocHGlobal(sizeof(int));
            try {
                int returned;
                if (!GetTokenInformation(token, 29, value, sizeof(int), out returned)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return Marshal.ReadInt32(value) == 1;
            } finally { Marshal.FreeHGlobal(value); }
        } finally { CloseHandle(token); }
    }

    public static int Main(string[] args) {
        if (args.Length != 4) return 10;
        bool appContainer = false, managedWrite = false, hostDenied = false, mutexCreatedNew = false;
        bool noProxyWildcard = String.Equals(Environment.GetEnvironmentVariable("NO_PROXY"), "*", StringComparison.Ordinal);
        bool proxyVarsAbsent = Environment.GetEnvironmentVariable("HTTP_PROXY") == null &&
            Environment.GetEnvironmentVariable("HTTPS_PROXY") == null &&
            Environment.GetEnvironmentVariable("ALL_PROXY") == null;
        string hostError = "";
        try { appContainer = IsAppContainer(); } catch { return 11; }
        try { File.WriteAllText(args[0], "synthetic-appcontainer-write", new UTF8Encoding(false)); managedWrite = true; }
        catch { managedWrite = false; }
        try { File.AppendAllText(args[1], "synthetic-write-attempt", new UTF8Encoding(false)); }
        catch (UnauthorizedAccessException e) { hostDenied = true; hostError = e.GetType().Name; }
        catch (SecurityException e) { hostDenied = true; hostError = e.GetType().Name; }
        catch (Exception e) { hostError = e.GetType().Name; }
        try { using (Mutex mutex = new Mutex(true, args[2], out mutexCreatedNew)) { } }
        catch { mutexCreatedNew = false; }
        try {
            string json = "{\"tokenIsAppContainer\":" + appContainer.ToString().ToLowerInvariant() +
                ",\"managedWriteSucceeded\":" + managedWrite.ToString().ToLowerInvariant() +
                ",\"hostWriteDenied\":" + hostDenied.ToString().ToLowerInvariant() +
                ",\"hostWriteFailureType\":\"" + hostError.Replace("\\", "\\\\").Replace("\"", "\\\"") +
                "\",\"mutexCreatedNew\":" + mutexCreatedNew.ToString().ToLowerInvariant() +
                ",\"noProxyWildcard\":" + noProxyWildcard.ToString().ToLowerInvariant() +
                ",\"proxyVarsAbsent\":" + proxyVarsAbsent.ToString().ToLowerInvariant() + "}";
            File.WriteAllText(args[3], json, new UTF8Encoding(false));
        } catch { return 12; }
        return appContainer && managedWrite && hostDenied && mutexCreatedNew && noProxyWildcard && proxyVarsAbsent ? 0 : 13;
    }
}
'@

try {
    $script:proxyEnvironmentBefore = Get-ProxyEnvironmentSnapshot
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempDrive = [IO.Path]::GetPathRoot($tempPath).TrimEnd('\')
    $tempVolume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$tempDrive'" -ErrorAction Stop | Select-Object -First 1
    if ($tempVolume.FileSystem -ne 'NTFS') { throw 'Boundary test requires a synthetic temp directory on NTFS.' }

    $script:fixtureRoot = New-AppContainerProbeFixtureRoot
    $fixtureGuid = (Split-Path -Leaf $script:fixtureRoot).Substring('aistick-ac-probe-'.Length)
    $script:hostRoot = Join-Path $tempPath ('aistick-ac-host-probe-' + [guid]::NewGuid().ToString('N'))
    $appDir = Join-Path $script:fixtureRoot 'app'
    $stickRoot = Join-Path $script:fixtureRoot 'stick'
    $runtimeRoot = Join-Path $script:fixtureRoot 'runtime'
    foreach ($directory in @($appDir, $stickRoot, $runtimeRoot, $script:hostRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

    Set-SyntheticHostOnlyDirectoryAcl -Path $script:hostRoot
    $hostSentinel = Join-Path $script:hostRoot 'synthetic-host-sentinel.txt'
    [IO.File]::WriteAllText($hostSentinel, 'synthetic-host-sentinel-v1', (New-Object Text.UTF8Encoding($false)))
    $sentinelHashBefore = Get-Sha256Hex -Path $hostSentinel

    $workerExe = Join-Path $appDir 'cc-switch.exe'
    Add-Type -TypeDefinition $workerSource -OutputType ConsoleApplication -OutputAssembly $workerExe -ErrorAction Stop

    $managedWritePath = Join-Path $stickRoot 'managed-write.txt'
    $workerResultPath = Join-Path $stickRoot 'worker-result.json'
    $mutexName = 'AiStick.AppContainer.Boundary.' + $fixtureGuid
    $createdNew = $false
    $script:hostMutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
    Assert-BoundaryTest $createdNew 'The random parent-process mutex name was unexpectedly occupied.'

    $fixturePath = Join-Path $script:fixtureRoot 'fixture.json'
    $fixture = [ordered]@{
        Root = $script:fixtureRoot
        Exe = $workerExe
        StickRoot = $stickRoot
        RuntimeRoot = $runtimeRoot
        Environment = [ordered]@{ HOME = $stickRoot; USERPROFILE = $stickRoot; APPDATA = $stickRoot; LOCALAPPDATA = $stickRoot; CC_SWITCH_TEST_HOME = $stickRoot; TEMP = $stickRoot; TMP = $stickRoot; WEBVIEW2_USER_DATA_FOLDER = $stickRoot }
        Arguments = @($managedWritePath, $hostSentinel, $mutexName, $workerResultPath)
    }
    [IO.File]::WriteAllText($fixturePath, (ConvertTo-Json -InputObject $fixture -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $loadedFixture = Read-AppContainerFixture -Path $fixturePath
    $loadedFixture | Add-Member -MemberType NoteProperty -Name __SourcePath -Value $fixturePath -Force

    $script:state = Start-AppContainerProbeProcess -Fixture $loadedFixture
    $wait = Wait-AppContainerProbeProcess -State $script:state -TimeoutSeconds 30
    Assert-BoundaryTest $wait.Completed 'Synthetic AppContainer worker timed out.'
    Assert-BoundaryTest (Test-Path -LiteralPath $workerResultPath -PathType Leaf) 'Worker did not produce a result inside the authorized synthetic root.'
    $result = [IO.File]::ReadAllText($workerResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop

    Invoke-BoundaryTest 'synthetic .NET worker exited successfully in AppContainer' {
        Assert-BoundaryTest ($wait.ExitCode -eq 0) ("Worker exited {0}; runtime/AppContainer compatibility or one boundary failed." -f $wait.ExitCode)
    }
    Invoke-BoundaryTest 'worker has a real AppContainer token' { Assert-BoundaryTest ([bool]$result.tokenIsAppContainer) 'Worker token does not report TokenIsAppContainer=true.' }
    Invoke-BoundaryTest 'AppContainer can write its explicitly authorized fixture root' { Assert-BoundaryTest ([bool]$result.managedWriteSucceeded -and (Test-Path -LiteralPath $managedWritePath -PathType Leaf)) 'Managed-root write did not succeed.' }
    Invoke-BoundaryTest 'AppContainer is denied write access to host-only synthetic sentinel' {
        $hashAfter = Get-Sha256Hex -Path $hostSentinel
        Assert-BoundaryTest ([bool]$result.hostWriteDenied) 'Worker was not denied writing the host-only sentinel.'
        Assert-BoundaryTest ($hashAfter -ceq $sentinelHashBefore) 'Synthetic host sentinel hash changed.'
    }
    Invoke-BoundaryTest 'same-named host mutex is independent inside AppContainer' { Assert-BoundaryTest ([bool]$result.mutexCreatedNew) 'AppContainer did not create a new same-named mutex while the host held one.' }
    Invoke-BoundaryTest 'AppContainer child has no network capability' { Assert-BoundaryTest (-not [bool]$script:state.NetworkCapabilitiesGranted) 'Network capability was unexpectedly granted to the boundary worker.' }
    Invoke-BoundaryTest 'AppContainer child receives NO_PROXY wildcard' { Assert-BoundaryTest ([bool]$result.noProxyWildcard) 'NO_PROXY was not exactly a wildcard inside the worker.' }
    Invoke-BoundaryTest 'AppContainer child does not inherit proxy environment variables' { Assert-BoundaryTest ([bool]$result.proxyVarsAbsent) 'A proxy environment variable was present inside the worker.' }
    Invoke-BoundaryTest 'parent proxy environment is unchanged' {
        $after = Get-ProxyEnvironmentSnapshot
        foreach ($name in @('NO_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
            Assert-BoundaryTest ($after[$name].Present -eq $script:proxyEnvironmentBefore[$name].Present) ("Parent environment presence changed for {0}." -f $name)
            Assert-BoundaryTest ([string]$after[$name].Value -ceq [string]$script:proxyEnvironmentBefore[$name].Value) ("Parent environment value changed for {0}." -f $name)
        }
    }

    $script:state | Add-Member -MemberType NoteProperty -Name Completed -Value $false -Force
    Complete-AppContainerProbeProcess -State $script:state
    $script:state = $null
} catch {
    $script:failed++
    Write-Host ("FAIL boundary setup/worker - {0}" -f $_.Exception.Message)
} finally {
    if ($script:state) {
        try { Complete-AppContainerProbeProcess -State $script:state; $script:state = $null }
        catch { $script:cleanupSafe = $false; Write-Host 'CLEANUP FAILED: preserving the owned synthetic fixture because AppContainer cleanup was not verified.' }
    }
    if ($script:hostMutex) { try { $script:hostMutex.ReleaseMutex() } catch {}; $script:hostMutex.Dispose() }
    if ($script:cleanupSafe) {
        try { Remove-OwnedTempTree -Path $script:hostRoot -Prefix 'aistick-ac-host-probe-' }
        catch { Write-Host ("CLEANUP FAILED: host test fixture retained: {0}" -f $_.Exception.Message); $script:cleanupSafe = $false }
        if ($script:cleanupSafe) {
            try { Remove-OwnedTempTree -Path $script:fixtureRoot -Prefix 'aistick-ac-probe-' }
            catch { Write-Host ("CLEANUP FAILED: AppContainer test fixture retained: {0}" -f $_.Exception.Message); $script:cleanupSafe = $false }
        }
    }
}

Write-Host "`nAppContainer boundary checks: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0 -or -not $script:cleanupSafe) { exit 1 }

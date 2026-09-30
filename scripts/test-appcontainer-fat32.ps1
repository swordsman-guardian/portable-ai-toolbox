[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')

$script:passed = 0
$script:failed = 0
$script:usbRoot = $null
$script:hostRoot = $null
$script:fixtureRoot = $null
$script:state = $null
$script:cleanupSafe = $true

function Assert-Fat32Probe {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Fat32ProbeTest {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}

function Get-Fat32ProbeHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Set-Fat32ProbeHostOnlyAcl {
    param([string]$Path)
    $acl = [IO.Directory]::GetAccessControl($Path)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
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

function Remove-Fat32ProbeTree {
    param([string]$Path, [string]$Parent, [string]$Prefix)
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $full
    $guid = [guid]::Empty
    if (-not $leaf.StartsWith($Prefix, [StringComparison]::Ordinal) -or
        -not [guid]::TryParseExact($leaf.Substring($Prefix.Length), 'N', [ref]$guid) -or
        -not [string]::Equals((Split-Path -Parent $full).TrimEnd('\', '/'), $expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup refused a path outside this test-owned GUID directory.'
    }
    $reparse = @(Get-ChildItem -LiteralPath $full -Force -Recurse -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($reparse.Count -gt 0) { throw 'Cleanup refused a test tree containing a reparse point.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

$workerSource = @'
using System;
using System.IO;
using System.Security;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class AppContainerFat32Worker {
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

    static bool TryRead(string path, string expected) {
        try { return File.ReadAllText(path, Encoding.UTF8) == expected; } catch { return false; }
    }
    static bool TryWrite(string path, string value, bool append) {
        try { if (append) File.AppendAllText(path, value, new UTF8Encoding(false)); else File.WriteAllText(path, value, new UTF8Encoding(false)); return true; }
        catch { return false; }
    }
    static bool IsAccessDenied(Exception e) { return e is UnauthorizedAccessException || e is SecurityException; }

    public static int Main(string[] args) {
        if (args.Length != 4) return 10;
        bool appContainer = false;
        try { appContainer = IsAppContainer(); } catch { return 11; }
        bool usb1Read = TryRead(args[0], "synthetic-fat32-file-one-v1");
        bool usb2Read = TryRead(args[1], "synthetic-fat32-file-two-v1");
        bool usb1Write = TryWrite(args[0], "synthetic-fat32-file-one-v2", false);
        bool usb2Write = TryWrite(args[1], "synthetic-fat32-file-two-v2", false);
        bool hostReadDenied = false, hostWriteDenied = false;
        try { File.ReadAllText(args[2], Encoding.UTF8); }
        catch (Exception e) { hostReadDenied = IsAccessDenied(e); }
        try { File.AppendAllText(args[2], "synthetic-host-write-attempt", new UTF8Encoding(false)); }
        catch (Exception e) { hostWriteDenied = IsAccessDenied(e); }
        string json = "{\"tokenIsAppContainer\":" + appContainer.ToString().ToLowerInvariant() +
            ",\"usb1Read\":" + usb1Read.ToString().ToLowerInvariant() +
            ",\"usb2Read\":" + usb2Read.ToString().ToLowerInvariant() +
            ",\"usb1Write\":" + usb1Write.ToString().ToLowerInvariant() +
            ",\"usb2Write\":" + usb2Write.ToString().ToLowerInvariant() +
            ",\"hostReadDenied\":" + hostReadDenied.ToString().ToLowerInvariant() +
            ",\"hostWriteDenied\":" + hostWriteDenied.ToString().ToLowerInvariant() + "}";
        try { File.WriteAllText(args[3], json, new UTF8Encoding(false)); } catch { return 12; }
        return appContainer ? 0 : 13;
    }
}
'@

try {
    $stickRoot = [IO.Path]::GetPathRoot($PSScriptRoot)
    $docs = Join-Path $stickRoot 'docs'
    if (-not [IO.Directory]::Exists($docs)) { throw 'Expected docs directory on the test volume is missing.' }
    $docsItem = Get-Item -LiteralPath $docs -Force -ErrorAction Stop
    if ($docsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The test parent cannot be a reparse point.' }
    $deviceId = $stickRoot.TrimEnd('\')
    $volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction Stop | Select-Object -First 1
    if (-not $volume -or $volume.FileSystem -ne 'FAT32') { throw 'This test specifically requires the StickRoot volume to report FAT32.' }

    $guidText = [guid]::NewGuid().ToString('N')
    $script:usbRoot = Join-Path $docs ('aistick-ac-fat32-' + $guidText)
    $script:hostRoot = Join-Path ([IO.Path]::GetTempPath()) ('aistick-ac-host-fat32-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $script:usbRoot) { throw 'The unique USB test target already exists.' }
    if (Test-Path -LiteralPath $script:hostRoot) { throw 'The unique host test target already exists.' }
    [IO.Directory]::CreateDirectory($script:usbRoot) | Out-Null
    [IO.Directory]::CreateDirectory($script:hostRoot) | Out-Null

    $usbFile1 = Join-Path $script:usbRoot 'synthetic-file-one.txt'
    $usbFile2 = Join-Path $script:usbRoot 'synthetic-file-two.txt'
    $hostSentinel = Join-Path $script:hostRoot 'synthetic-host-sentinel.txt'
    [IO.File]::WriteAllText($usbFile1, 'synthetic-fat32-file-one-v1', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($usbFile2, 'synthetic-fat32-file-two-v1', (New-Object Text.UTF8Encoding($false)))
    Set-Fat32ProbeHostOnlyAcl -Path $script:hostRoot
    [IO.File]::WriteAllText($hostSentinel, 'synthetic-host-sentinel-v1', (New-Object Text.UTF8Encoding($false)))
    $hostHashBefore = Get-Fat32ProbeHash -Path $hostSentinel

    $script:fixtureRoot = New-AppContainerProbeFixtureRoot
    $fixtureLeaf = Split-Path -Leaf $script:fixtureRoot
    $appDir = Join-Path $script:fixtureRoot 'app'
    $runtimeRoot = Join-Path $script:fixtureRoot 'runtime'
    $managedRoot = Join-Path $script:fixtureRoot 'stick'
    foreach ($directory in @($appDir, $runtimeRoot, $managedRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $workerExe = Join-Path $appDir 'cc-switch.exe'
    Add-Type -TypeDefinition $workerSource -OutputType ConsoleApplication -OutputAssembly $workerExe -ErrorAction Stop
    $workerResult = Join-Path $managedRoot 'worker-result.json'
    $fixturePath = Join-Path $script:fixtureRoot 'fixture.json'
    $fixture = [ordered]@{
        Root = $script:fixtureRoot
        Exe = $workerExe
        StickRoot = $managedRoot
        RuntimeRoot = $runtimeRoot
        Environment = [ordered]@{ HOME = $managedRoot; USERPROFILE = $managedRoot; APPDATA = $managedRoot; LOCALAPPDATA = $managedRoot; CC_SWITCH_TEST_HOME = $managedRoot; TEMP = $managedRoot; TMP = $managedRoot; WEBVIEW2_USER_DATA_FOLDER = $managedRoot }
        Arguments = @($usbFile1, $usbFile2, $hostSentinel, $workerResult)
    }
    [IO.File]::WriteAllText($fixturePath, (ConvertTo-Json -InputObject $fixture -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $loaded = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $loaded
    $script:state = $state
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 30
    Assert-Fat32Probe $wait.Completed 'Synthetic worker timed out inside AppContainer.'
    Assert-Fat32Probe (Test-Path -LiteralPath $workerResult -PathType Leaf) 'Worker result is missing from its authorized synthetic root.'
    $result = [IO.File]::ReadAllText($workerResult, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    Write-Host ("Synthetic FAT32 result flags: read1={0}; read2={1}; write1={2}; write2={3}; hostReadDenied={4}; hostWriteDenied={5}" -f $result.usb1Read, $result.usb2Read, $result.usb1Write, $result.usb2Write, $result.hostReadDenied, $result.hostWriteDenied)

    Invoke-Fat32ProbeTest 'worker ran under an AppContainer token' { Assert-Fat32Probe ([bool]$result.tokenIsAppContainer) 'Worker token did not report AppContainer.' }
    Invoke-Fat32ProbeTest 'AppContainer reads FAT32 synthetic file one without E: ACL changes' { Assert-Fat32Probe ([bool]$result.usb1Read) 'Read of synthetic FAT32 file one was denied or mismatched.' }
    Invoke-Fat32ProbeTest 'AppContainer reads FAT32 synthetic file two without E: ACL changes' { Assert-Fat32Probe ([bool]$result.usb2Read) 'Read of synthetic FAT32 file two was denied or mismatched.' }
    Invoke-Fat32ProbeTest 'AppContainer writes FAT32 synthetic file one without E: ACL changes' { Assert-Fat32Probe ([bool]$result.usb1Write -and [IO.File]::ReadAllText($usbFile1, [Text.Encoding]::UTF8) -ceq 'synthetic-fat32-file-one-v2') 'Write to synthetic FAT32 file one was denied or did not persist.' }
    Invoke-Fat32ProbeTest 'AppContainer writes FAT32 synthetic file two without E: ACL changes' { Assert-Fat32Probe ([bool]$result.usb2Write -and [IO.File]::ReadAllText($usbFile2, [Text.Encoding]::UTF8) -ceq 'synthetic-fat32-file-two-v2') 'Write to synthetic FAT32 file two was denied or did not persist.' }
    Invoke-Fat32ProbeTest 'AppContainer cannot read or write a separate NTFS host sentinel' {
        Assert-Fat32Probe ([bool]$result.hostReadDenied -and [bool]$result.hostWriteDenied) 'Host sentinel read/write was not denied.'
        Assert-Fat32Probe ((Get-Fat32ProbeHash -Path $hostSentinel) -ceq $hostHashBefore) 'Host sentinel hash changed.'
    }

    Complete-AppContainerProbeProcess -State $state
    $script:state = $null
} catch {
    $script:failed++
    Write-Host ("FAIL setup/worker - {0}" -f $_.Exception.Message)
} finally {
    if ($script:state) {
        try { Complete-AppContainerProbeProcess -State $script:state; $script:state = $null }
        catch { $script:cleanupSafe = $false; Write-Host 'CLEANUP FAILED: preserving the synthetic fixture because AppContainer cleanup was not verified.' }
    }
    if ($script:cleanupSafe) {
        try { Remove-Fat32ProbeTree -Path $script:hostRoot -Parent ([IO.Path]::GetTempPath()) -Prefix 'aistick-ac-host-fat32-' }
        catch { Write-Host ("CLEANUP FAILED: synthetic host sentinel retained: {0}" -f $_.Exception.Message); $script:cleanupSafe = $false }
        if ($script:cleanupSafe) {
            try { Remove-Fat32ProbeTree -Path $script:fixtureRoot -Parent ([IO.Path]::GetTempPath()) -Prefix 'aistick-ac-probe-' }
            catch { Write-Host ("CLEANUP FAILED: AppContainer fixture retained: {0}" -f $_.Exception.Message); $script:cleanupSafe = $false }
        }
        if ($script:cleanupSafe) {
            try { Remove-Fat32ProbeTree -Path $script:usbRoot -Parent (Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) 'docs') -Prefix 'aistick-ac-fat32-' }
            catch { Write-Host ("CLEANUP FAILED: synthetic USB directory retained: {0}" -f $_.Exception.Message); $script:cleanupSafe = $false }
        }
    }
}

Write-Host "`nAppContainer FAT32 checks: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0 -or -not $script:cleanupSafe) { exit 1 }

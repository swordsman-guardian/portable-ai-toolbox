[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MetadataPath,
    [Parameter(Mandatory=$true)][string]$GuardianCopy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-GuardianExpectedSids {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    return @(
        $current.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
}

function Assert-GuardianProtectedDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if (-not [IO.Directory]::Exists($full)) { throw 'Protected guardian directory is missing.' }
    $walk = $full
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            $item = Get-Item -LiteralPath $walk -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Guardian path may not pass through a reparse point.' }
        }
        $parent = Split-Path -Parent $walk
        if (-not $parent -or $parent -eq $walk) { break }
        $walk = $parent
    }
    $acl = [IO.Directory]::GetAccessControl($full)
    if (-not $acl.AreAccessRulesProtected) { throw 'Guardian directory DACL must not inherit permissions.' }
    $allowed = Get-GuardianExpectedSids
    foreach ($entry in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $allowed -notcontains $entry.IdentityReference.Value) {
            throw 'Guardian directory grants access to an unexpected principal.'
        }
    }
}

function Assert-GuardianProtectedFile([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw 'Protected guardian file is missing.' }
    if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guardian file may not be a reparse point.' }
    $acl = [IO.File]::GetAccessControl($full)
    if (-not $acl.AreAccessRulesProtected) { throw 'Guardian file DACL must not inherit permissions.' }
    $allowed = Get-GuardianExpectedSids
    foreach ($entry in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $allowed -notcontains $entry.IdentityReference.Value) {
            throw 'Guardian file grants access to an unexpected principal.'
        }
    }
}

function Read-GuardianMetadata {
    $path = [IO.Path]::GetFullPath($MetadataPath)
    $dir = Split-Path -Parent $path
    Assert-GuardianProtectedDirectory $dir
    Assert-GuardianProtectedFile $path
    if ((Get-Item -LiteralPath $path -Force).Length -gt 65536) { throw 'Guardian metadata exceeds its fixed size limit.' }
    $data = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ([int]$data.Version -ne 1) { throw 'Unsupported guardian metadata version.' }
    if ([string]$data.SessionId -notmatch '^[0-9a-f]{32}$') { throw 'Guardian session id is invalid.' }
    if ([string]$data.State -notin @('Planned','Running','Complete','Preserve')) { throw 'Guardian state is invalid.' }
    if ([int]$data.OwnerPid -le 0 -or [long]$data.OwnerStartTicks -le 0) { throw 'Guardian owner identity is incomplete.' }
    if ([string]$data.StickRoot -notmatch '^[A-Za-z]:\\') { throw 'Guardian stick root must be an absolute local path.' }
    if ([string]$data.DriveLetter -notmatch '^[A-Za-z]$') { throw 'Guardian drive letter is invalid.' }
    if (-not $data.VolumeGuid -and -not $data.Serial) { throw 'Guardian metadata has no volume identity.' }

    $temp = [IO.Path]::GetFullPath([string]$data.TempRoot).TrimEnd('\','/')
    $owned = [IO.Path]::GetFullPath([string]$data.OwnedRoot).TrimEnd('\','/')
    $checkpoint = [IO.Path]::GetFullPath([string]$data.TrustedCheckpointRoot).TrimEnd('\','/')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($checkpoint),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($checkpoint) -cne ('aistick-cc-switch-checkpoints-' + [string]$data.SessionId)) { throw 'Trusted checkpoint root is not the session unique direct child of the configured temp root.' }
    $leaf = [IO.Path]::GetFileName($owned)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($owned),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^aistick-ac-probe-[0-9a-f]{32}$' -or
        $leaf -cne ('aistick-ac-probe-' + [string]$data.SessionId)) { throw 'Owned root is not the unique direct child named in guardian metadata.' }
    $expectedApp = [IO.Path]::GetFullPath((Join-Path $owned 'app\cc-switch.exe'))
    if ([string]$data.AppExePath -cne $expectedApp) { throw 'Guardian app executable path does not match the owned root.' }
    $expectedRuntime = [IO.Path]::GetFullPath((Join-Path $owned 'runtime'))
    if ([string]$data.RuntimeRoot -cne $expectedRuntime) { throw 'Guardian runtime path does not match the owned root.' }

    if ($data.State -eq 'Running') {
        if ([string]$data.ProfileName -notmatch '^AiStick\.Probe\.[0-9a-f]{32}$' -or
            [string]$data.AppContainerSid -notmatch '^S-1-15-2-(?:[0-9]+-){1,8}[0-9]+$' -or
            [string]::IsNullOrWhiteSpace([string]$data.OriginalAccessSddl)) { throw 'Running metadata lacks the exact AppContainer profile and ACL restoration data.' }
    }
    if ($data.ProcessId -and ([int]$data.ProcessId -le 0 -or [long]$data.ProcessStartTicks -le 0)) { throw 'Guardian AppContainer process identity is incomplete.' }
    if (-not $data.ProcessId -and $data.ProcessStartTicks) { throw 'Guardian AppContainer process start time has no matching process id.' }
    return $data
}

function Test-GuardianExpectedVolume($Data) {
    try {
        $driveRoot = [string]$Data.DriveLetter + ':\'
        if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) { return $false }
        $guid = $null; $serial = $null
        try { $v = Get-Volume -DriveLetter ([string]$Data.DriveLetter) -ErrorAction Stop; $guid = [string]$v.UniqueId } catch { }
        try { $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + [string]$Data.DriveLetter + ":'") -ErrorAction Stop; if ($d) { $serial = [string]$d.VolumeSerialNumber } } catch { }
        $compared = $false
        if ($Data.VolumeGuid -and $guid) { $compared = $true; if (-not [string]::Equals([string]$Data.VolumeGuid,$guid,[StringComparison]::OrdinalIgnoreCase)) { return $false } }
        if ($Data.Serial -and $serial) { $compared = $true; if (-not [string]::Equals([string]$Data.Serial,$serial,[StringComparison]::OrdinalIgnoreCase)) { return $false } }
        if (-not $compared) { return $null }
        return $true
    } catch { return $null }
}

function Get-GuardianOwnerProcess($Data) {
    try {
        $p = Get-Process -Id ([int]$Data.OwnerPid) -ErrorAction Stop
        if ([long]$p.StartTime.ToUniversalTime().Ticks -ne [long]$Data.OwnerStartTicks) { return $null }
        $w = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$Data.OwnerPid) -ErrorAction Stop
        if (-not $w -or [string]$w.Name -notin @('powershell.exe','pwsh.exe')) { return $null }
        $cmd = [string]$w.CommandLine
        if ($cmd.IndexOf('cc-switch-secure-session.ps1',[StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $cmd.IndexOf([string]$Data.StickRoot,[StringComparison]::OrdinalIgnoreCase) -lt 0) { return $null }
        return $p
    } catch { return $null }
}

function Assert-GuardianPlainTree([string]$Path,[string]$Boundary) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $base = [IO.Path]::GetFullPath($Boundary).TrimEnd('\','/')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full),$base,[StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Guardian cleanup path escaped its configured boundary.' }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($full)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point found; refusing guardian cleanup.' }
        if ($item.PSIsContainer) { foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current,'*',[IO.SearchOption]::TopDirectoryOnly)) { $stack.Push($child) } }
    }
}

function Remove-GuardianOwnedRoot([string]$Root,[string]$TempRoot,[string]$SessionId) {
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $temp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\','/')
    $leaf = [IO.Path]::GetFileName($full)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        $leaf -cne ('aistick-ac-probe-' + $SessionId) -or $leaf -notmatch '^aistick-ac-probe-[0-9a-f]{32}$') {
        throw 'Guardian refused a root outside its unique direct-child ownership boundary.'
    }
    if (-not [IO.Directory]::Exists($full)) { return }
    Assert-GuardianPlainTree -Path $full -Boundary $temp
    $marker = Join-Path $full '.aistick-ac-probe'
    if (-not [IO.File]::Exists($marker) -or ((Get-Item -LiteralPath $marker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [IO.File]::ReadAllText($marker).Trim() -cne 'aistick appcontainer workspace v1') { throw 'Guardian root marker is invalid; root retained.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

function Remove-GuardianCheckpointRoot([string]$Root,[string]$TempRoot,[string]$SessionId) {
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $temp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\','/')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full),$temp,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($full) -cne ('aistick-cc-switch-checkpoints-' + $SessionId)) { throw 'Guardian refused checkpoint cleanup outside its session-specific direct child.' }
    if (-not [IO.Directory]::Exists($full)) { return }
    Assert-GuardianPlainTree -Path $full -Boundary $temp
    $marker = Join-Path $full '.aistick-cc-switch-checkpoints'
    if (-not [IO.File]::Exists($marker) -or ((Get-Item -LiteralPath $marker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [IO.File]::ReadAllText($marker).Trim() -cne $SessionId) { throw 'Trusted checkpoint marker mismatch; checkpoint root retained.' }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
}

if (-not ('CcSessionGuardianNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class CcSessionGuardianNative {
    const int TokenAppContainerSid = 31;
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LocalFree(IntPtr value);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int DeleteAppContainerProfile(string name);
    public static bool TerminateExactProcess(int processId, long expectedStartTicks) {
        IntPtr process=OpenProcess(0x0001|0x1000,false,processId); if(process==IntPtr.Zero) return false;
        try {
            long creation,exit,kernel,user; Check(GetProcessTimes(process,out creation,out exit,out kernel,out user));
            long actual=DateTime.FromFileTimeUtc(creation).Ticks;
            if(actual!=expectedStartTicks) return false;
            return TerminateProcess(process,0xE001);
        } finally { CloseHandle(process); }
    }
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static bool HasAppContainerSid(int processId, string expectedSid) {
        IntPtr process=OpenProcess(0x1000,false,processId); if(process==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr token=IntPtr.Zero;
        try {
            Check(OpenProcessToken(process,0x0008,out token));
            int length=0; GetTokenInformation(token,TokenAppContainerSid,IntPtr.Zero,0,out length); if(length<=0) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr buffer=Marshal.AllocHGlobal(length);
            try {
                int returned; Check(GetTokenInformation(token,TokenAppContainerSid,buffer,length,out returned));
                IntPtr sid=Marshal.ReadIntPtr(buffer); if(sid==IntPtr.Zero) return false;
                IntPtr text; Check(ConvertSidToStringSidW(sid,out text));
                try { return String.Equals(Marshal.PtrToStringUni(text),expectedSid,StringComparison.OrdinalIgnoreCase); }
                finally { LocalFree(text); }
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { if(token!=IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
    }
}
'@ -ErrorAction Stop
}

function Test-GuardianProfileProcessGone($Data) {
    if ($Data.State -ne 'Running' -or -not $Data.AppContainerSid) { return $true }
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $processes) {
        $pidValue = [int]$process.ProcessId
        $tracked = $Data.ProcessId -and $pidValue -eq [int]$Data.ProcessId
        if ($tracked) {
            $trackedProcess = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if (-not $trackedProcess) { continue }
            if ([long]$trackedProcess.StartTime.ToUniversalTime().Ticks -ne [long]$Data.ProcessStartTicks) { continue }
        }
        $path = [string]$process.ExecutablePath
        $underRoot = $false
        if ($path) {
            $rootPrefix = [IO.Path]::GetFullPath([string]$Data.OwnedRoot).TrimEnd('\') + '\'
            $underRoot = [IO.Path]::GetFullPath($path).StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)
        }
        try {
            $hasSid = [CcSessionGuardianNative]::HasAppContainerSid($pidValue,[string]$Data.AppContainerSid)
            if ($hasSid -or $tracked) { return $false }
        } catch { if ($underRoot -or $tracked) { throw 'Cannot establish token state for an owned AppContainer process.' } }
        # OpenProcess/token-query failures can be access denied for unrelated system
        # processes. A process executable in this private root is never treated as gone.
    if ($underRoot -or $tracked) {
            $p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($p) { return $false }
        }
    }
    return $true
}

function Restore-GuardianRootAcl($Data) {
    $root = [IO.Path]::GetFullPath([string]$Data.OwnedRoot)
    Assert-GuardianPlainTree -Path $root -Boundary ([string]$Data.TempRoot)
    $acl = [IO.Directory]::GetAccessControl($root)
    $acl.SetSecurityDescriptorSddlForm([string]$Data.OriginalAccessSddl,[Security.AccessControl.AccessControlSections]::Access)
    [IO.Directory]::SetAccessControl($root,$acl)
    $after = [IO.Directory]::GetAccessControl($root).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    if ($after -cne [string]$Data.OriginalAccessSddl) { throw 'Restored owned-root ACL did not verify.' }
}

function Remove-GuardianAppContainerProfile($Data) {
    if ($Data.State -ne 'Running' -or -not $Data.ProfileName) { return }
    $result = [CcSessionGuardianNative]::DeleteAppContainerProfile([string]$Data.ProfileName)
    if ($result -ne 0) { throw ('DeleteAppContainerProfile failed: 0x{0:X8}' -f [uint32]$result) }
}

function Write-GuardianLog([string]$Message) {
    try {
        $dir = Split-Path -Parent ([IO.Path]::GetFullPath($MetadataPath))
        $log = Join-Path $dir 'guardian-cleanup.log'
        [IO.File]::AppendAllText($log,('[{0:o}] {1}{2}' -f [DateTime]::UtcNow,$Message,[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Remove-GuardianProtectedFile([string]$Path,[string]$Root) {
    $full = [IO.Path]::GetFullPath($Path); $base = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full),$base,[StringComparison]::OrdinalIgnoreCase)) { throw 'Guardian file escaped its protected directory.' }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guardian cleanup refused a reparse-point file.' }
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    }
}

$metadata = Read-GuardianMetadata
$metadataDir = Split-Path -Parent ([IO.Path]::GetFullPath($MetadataPath))
if (-not [string]::Equals([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($metadataDir)),'AiStick',[StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals([IO.Path]::GetFileName($metadataDir),'SecureSessions',[StringComparison]::OrdinalIgnoreCase)) { throw 'Guardian metadata must live in LocalAppData\AiStick\SecureSessions.' }
if (-not [string]::Equals([IO.Path]::GetFullPath($metadataDir),[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'AiStick\SecureSessions')),[StringComparison]::OrdinalIgnoreCase)) { throw 'Guardian metadata is outside this user profile trusted directory.' }
if ([IO.Path]::GetFileName([IO.Path]::GetFullPath($MetadataPath)) -cne ([string]$metadata.SessionId + '.json')) { throw 'Guardian metadata filename does not match the session id.' }
Assert-GuardianProtectedFile $GuardianCopy
if (-not [string]::Equals((Split-Path -Parent ([IO.Path]::GetFullPath($GuardianCopy))),[IO.Path]::GetFullPath($metadataDir),[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName([IO.Path]::GetFullPath($GuardianCopy)) -cne ('cc-switch-session-guardian-' + [string]$metadata.SessionId + '.ps1')) { throw 'Guardian code copy must be the per-session protected copy beside its metadata.' }

$unplugged = $false
$ownerExited = $false
while ($true) {
    $metadata = Read-GuardianMetadata
    if ($metadata.State -eq 'Complete') {
        Remove-GuardianProtectedFile -Path $MetadataPath -Root $metadataDir
        Remove-GuardianProtectedFile -Path $GuardianCopy -Root $metadataDir
        exit 0
    }
    if ($metadata.State -eq 'Preserve') {
        Write-GuardianLog 'Owner requested recovery preservation; owned root and metadata retained.'
        Remove-GuardianProtectedFile -Path $GuardianCopy -Root $metadataDir
        exit 0
    }
    $owner = Get-GuardianOwnerProcess $metadata
    if (-not $owner) {
        $raw = Get-Process -Id ([int]$metadata.OwnerPid) -ErrorAction SilentlyContinue
        if ($raw -and [long]$raw.StartTime.ToUniversalTime().Ticks -eq [long]$metadata.OwnerStartTicks) {
            Write-GuardianLog 'Owner identity did not match the expected secure-session command line; refusing to terminate or clean.'
            exit 5
        }
        $ownerExited = $true; break
    }
    $volumeMatch = Test-GuardianExpectedVolume $metadata
    if ($null -eq $volumeMatch) {
        Write-GuardianLog 'Volume identity could not be established; owner and root retained.'
        exit 6
    }
    if (-not $volumeMatch) {
        $unplugged = $true
        # Owner identity was just revalidated (PID, start time, executable host,
        # secure-session entry point, and exact stick root). Never kill by name.
        try { if (-not [CcSessionGuardianNative]::TerminateExactProcess([int]$metadata.OwnerPid,[long]$metadata.OwnerStartTicks)) { Write-GuardianLog 'Verified owner termination request failed or process identity changed.' } }
        catch { Write-GuardianLog ('Verified owner termination request failed: ' + $_.Exception.Message) }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 100
            $owner = Get-GuardianOwnerProcess $metadata
        } while ($owner -and $watch.Elapsed.TotalSeconds -lt 20)
        if ($owner) { Write-GuardianLog 'Owner did not exit after verified unplug; cleanup deferred.'; exit 2 }
        $ownerExited = $true
        break
    }
    Start-Sleep -Milliseconds 300
}

$metadata = Read-GuardianMetadata
if ($metadata.State -eq 'Complete') {
    Remove-GuardianProtectedFile -Path $MetadataPath -Root $metadataDir
    Remove-GuardianProtectedFile -Path $GuardianCopy -Root $metadataDir
    exit 0
}
if ($metadata.State -eq 'Preserve' -and -not $unplugged) {
    Write-GuardianLog 'Owner requested recovery preservation; owned root and metadata retained.'
    Remove-GuardianProtectedFile -Path $GuardianCopy -Root $metadataDir
    exit 0
}

$goneWatch = [Diagnostics.Stopwatch]::StartNew()
$emptySince = $null
do {
    if (Test-GuardianProfileProcessGone $metadata) {
        if ($null -eq $emptySince) { $emptySince = [DateTime]::UtcNow }
        if (([DateTime]::UtcNow - $emptySince).TotalSeconds -ge 2) { break }
    } else { $emptySince = $null }
    Start-Sleep -Milliseconds 250
} while ($goneWatch.Elapsed.TotalSeconds -lt 20)
if ($null -eq $emptySince -or ([DateTime]::UtcNow - $emptySince).TotalSeconds -lt 2) {
    Write-GuardianLog 'Matching AppContainer token remained or process state could not be established; root retained.'
    exit 3
}

try {
    $metadata = Read-GuardianMetadata
    if ($metadata.State -eq 'Running') {
        if ([IO.Directory]::Exists([string]$metadata.OwnedRoot)) { Restore-GuardianRootAcl $metadata }
        Remove-GuardianAppContainerProfile $metadata
    }
    if ([IO.Directory]::Exists([string]$metadata.OwnedRoot)) { Assert-GuardianPlainTree -Path ([string]$metadata.OwnedRoot) -Boundary ([string]$metadata.TempRoot) }
    Remove-GuardianOwnedRoot -Root ([string]$metadata.OwnedRoot) -TempRoot ([string]$metadata.TempRoot) -SessionId ([string]$metadata.SessionId)
    Remove-GuardianCheckpointRoot -Root ([string]$metadata.TrustedCheckpointRoot) -TempRoot ([string]$metadata.TempRoot) -SessionId ([string]$metadata.SessionId)
    Remove-GuardianProtectedFile -Path $MetadataPath -Root $metadataDir
    Write-GuardianLog 'Owned root and per-session metadata were cleaned after owner and AppContainer exit.'
    Remove-GuardianProtectedFile -Path $GuardianCopy -Root $metadataDir
} catch {
    Write-GuardianLog ('Cleanup failed closed; retained owned root and metadata: ' + $_.Exception.Message)
    exit 4
}

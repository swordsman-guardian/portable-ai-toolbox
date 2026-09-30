[CmdletBinding()]
param(
    [ValidateSet('Inspect','Run')][string]$Action = 'Inspect',
    [string]$FixturePath,
    [ValidateRange(1,600)][int]$TimeoutSeconds = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ('AiStickAppContainerNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct AiStickStartupInfo {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickStartupInfoEx {
    public AiStickStartupInfo StartupInfo;
    public IntPtr AttributeList;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickProcessInfo {
    public IntPtr hProcess, hThread;
    public int dwProcessId, dwThreadId;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickSecurityCapabilities {
    public IntPtr AppContainerSid;
    public IntPtr Capabilities;
    public uint CapabilityCount;
    public uint Reserved;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickSidAndAttributes { public IntPtr Sid; public uint Attributes; }
[StructLayout(LayoutKind.Sequential)]
public struct AiStickIoCounters {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickJobBasicLimitInformation {
    public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickJobExtendedLimitInformation {
    public AiStickJobBasicLimitInformation BasicLimitInformation;
    public AiStickIoCounters IoInfo;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
}
[StructLayout(LayoutKind.Sequential)]
public struct AiStickJobBasicAccountingInformation {
    public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
    public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
}

public static class AiStickAppContainerNative {
    const int PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES = 0x00020009;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const int JobObjectExtendedLimitInformation = 9;
    const uint TOKEN_QUERY = 0x0008;
    const int TokenIsAppContainer = 29;
    const int TokenAppContainerSid = 31;
    const int TokenCapabilities = 30;
    const uint SE_GROUP_ENABLED = 0x00000004;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;
    const uint INFINITE = 0xffffffff;

    [DllImport("userenv.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int CreateAppContainerProfile(string name, string displayName, string description, IntPtr capabilities, uint capabilityCount, out IntPtr sid);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int DeleteAppContainerProfile(string name);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern IntPtr FreeSid(IntPtr sid);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LocalFree(IntPtr value);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSidToSidW(string text, out IntPtr sid);
    public static IntPtr CreateInternetClientSid() {
        IntPtr sid;
        if (!ConvertStringSidToSidW("S-1-15-3-1", out sid)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return sid;
    }
    public static void FreeLocal(IntPtr value) { if (value != IntPtr.Zero) LocalFree(value); }
    static IntPtr CreateCapabilityArray(IntPtr capabilitySid) {
        if (capabilitySid == IntPtr.Zero) return IntPtr.Zero;
        IntPtr value = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AiStickSidAndAttributes)));
        var item = new AiStickSidAndAttributes(); item.Sid = capabilitySid; item.Attributes = SE_GROUP_ENABLED;
        Marshal.StructureToPtr(item, value, false); return value;
    }
    public static string SidToString(IntPtr sid) {
        IntPtr text;
        if (!ConvertSidToStringSidW(sid, out text)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Marshal.PtrToStringUni(text); } finally { LocalFree(text); }
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string currentDirectory,
        ref AiStickStartupInfoEx startup, out AiStickProcessInfo processInfo);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetProcessId(IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    public static AiStickProcessInfo StartSuspendedInAppContainer(string app, string commandLine, string currentDirectory, IntPtr appContainerSid, string environmentBlock, bool internetClient) {
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        if (size == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot size process attribute list.");
        IntPtr attributes = Marshal.AllocHGlobal(size);
        IntPtr securityPtr = IntPtr.Zero;
        IntPtr envPtr = IntPtr.Zero;
        IntPtr capabilitySid = IntPtr.Zero;
        IntPtr capabilityArray = IntPtr.Zero;
        bool attributesInitialized = false;
        try {
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            attributesInitialized = true;
            var security = new AiStickSecurityCapabilities();
            security.AppContainerSid = appContainerSid;
            if (internetClient) { capabilitySid = CreateInternetClientSid(); capabilityArray = CreateCapabilityArray(capabilitySid); }
            security.Capabilities = capabilityArray;
            security.CapabilityCount = internetClient ? 1U : 0U;
            security.Reserved = 0;
            securityPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AiStickSecurityCapabilities)));
            Marshal.StructureToPtr(security, securityPtr, false);
            if (!UpdateProcThreadAttribute(attributes, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES,
                securityPtr, (IntPtr)Marshal.SizeOf(typeof(AiStickSecurityCapabilities)), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot attach AppContainer security capabilities.");

            if (!String.IsNullOrEmpty(environmentBlock)) envPtr = Marshal.StringToHGlobalUni(environmentBlock);
            var startup = new AiStickStartupInfoEx();
            startup.StartupInfo.cb = Marshal.SizeOf(typeof(AiStickStartupInfoEx));
            startup.AttributeList = attributes;
            AiStickProcessInfo info;
            uint flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
            if (!CreateProcessW(app, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, flags,
                envPtr, currentDirectory, ref startup, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        } finally {
            if (envPtr != IntPtr.Zero) Marshal.FreeHGlobal(envPtr);
            if (capabilityArray != IntPtr.Zero) Marshal.FreeHGlobal(capabilityArray);
            if (capabilitySid != IntPtr.Zero) LocalFree(capabilitySid);
            if (securityPtr != IntPtr.Zero) Marshal.FreeHGlobal(securityPtr);
            if (attributesInitialized) DeleteProcThreadAttributeList(attributes);
            Marshal.FreeHGlobal(attributes);
        }
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, out uint returned);
    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new AiStickJobExtendedLimitInformation();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(AiStickJobExtendedLimitInformation));
        IntPtr memory = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, memory, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, memory, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Marshal.StructureToPtr(new AiStickJobExtendedLimitInformation(), memory, false);
            uint returned;
            if (!QueryInformationJobObject(job, JobObjectExtendedLimitInformation, memory, (uint)size, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var check = (AiStickJobExtendedLimitInformation)Marshal.PtrToStructure(memory, typeof(AiStickJobExtendedLimitInformation));
            if (check.BasicLimitInformation.LimitFlags != JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) throw new InvalidOperationException("KILL_ON_JOB_CLOSE did not verify.");
            return job;
        } catch { CloseHandle(job); throw; }
        finally { Marshal.FreeHGlobal(memory); }
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint code);
    public static uint GetJobActiveProcessCount(IntPtr job) {
        var info = new AiStickJobBasicAccountingInformation();
        int size = Marshal.SizeOf(typeof(AiStickJobBasicAccountingInformation));
        IntPtr memory = Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if (!QueryInformationJobObject(job, 1, memory, (uint)size, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
            info = (AiStickJobBasicAccountingInformation)Marshal.PtrToStructure(memory, typeof(AiStickJobBasicAccountingInformation));
            return info.ActiveProcesses;
        } finally { Marshal.FreeHGlobal(memory); }
    }

    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    public static bool VerifyAppContainerToken(int processId, string expectedSid, bool internetClient) {
        IntPtr process = OpenProcess(0x1000, false, processId);
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int returned;
            IntPtr flag = Marshal.AllocHGlobal(sizeof(int));
            try {
                if (!GetTokenInformation(token, TokenIsAppContainer, flag, sizeof(int), out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (Marshal.ReadInt32(flag) != 1) return false;
            } finally { Marshal.FreeHGlobal(flag); }
            int sidLength = 0;
            GetTokenInformation(token, TokenAppContainerSid, IntPtr.Zero, 0, out sidLength);
            if (sidLength <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr sidBuffer = Marshal.AllocHGlobal(sidLength);
            try {
                if (!GetTokenInformation(token, TokenAppContainerSid, sidBuffer, sidLength, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr sid = Marshal.ReadIntPtr(sidBuffer);
                if (sid == IntPtr.Zero) return false;
                if (!String.Equals(SidToString(sid), expectedSid, StringComparison.OrdinalIgnoreCase)) return false;
            } finally { Marshal.FreeHGlobal(sidBuffer); }
            int capsLength = 0;
            GetTokenInformation(token, TokenCapabilities, IntPtr.Zero, 0, out capsLength);
            if (capsLength < sizeof(int)) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr caps = Marshal.AllocHGlobal(capsLength);
            try {
                if (!GetTokenInformation(token, TokenCapabilities, caps, capsLength, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
                int count = Marshal.ReadInt32(caps);
                int itemSize = Marshal.SizeOf(typeof(AiStickSidAndAttributes));
                int arrayOffset = IntPtr.Size == 8 ? 8 : 4;
                bool found = false;
                for (int i = 0; i < count; i++) {
                    IntPtr itemPtr = IntPtr.Add(caps, arrayOffset + i * itemSize);
                    var item = (AiStickSidAndAttributes)Marshal.PtrToStructure(itemPtr, typeof(AiStickSidAndAttributes));
                    if (item.Sid != IntPtr.Zero && String.Equals(SidToString(item.Sid), "S-1-15-3-1", StringComparison.OrdinalIgnoreCase) && (item.Attributes & SE_GROUP_ENABLED) != 0) found = true;
                }
                return found == internetClient;
            } finally { Marshal.FreeHGlobal(caps); }
        } finally { if (token != IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
    }
}
'@
}

if (-not ('AiStickAppContainerTimingV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AiStickAppContainerTimingV1 {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
}
'@
}

function Get-AppContainerProbePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Test-AppContainerProbeWithin {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $p = Get-AppContainerProbePath $Path
    $r = Get-AppContainerProbePath $Root
    return $p.StartsWith(($r + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AppContainerProbePlainTree {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Boundary)
    $current = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Boundary)
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture paths may not contain reparse points.' }
        }
        if ([string]::Equals($current.TrimEnd('\','/'), $base.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current -or -not $current.StartsWith(($base.TrimEnd('\','/') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture path escaped its approved boundary.'
        }
        $current = $parent
    }
}

function Read-AppContainerFixture {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullFixture = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullFixture) -or (Get-Item -LiteralPath $fullFixture -Force).Length -gt 1048576) { throw 'Fixture metadata is missing or exceeds its 1 MiB limit.' }
    if ((Get-Item -LiteralPath $fullFixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture metadata may not be a reparse point.' }
    $fixture = [IO.File]::ReadAllText($fullFixture, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $root = [IO.Path]::GetFullPath([string]$fixture.Root).TrimEnd('\','/')
    $leaf = Split-Path -Leaf $root
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact(($leaf -replace '^aistick-ac-probe-',''), 'N', [ref]$guid) -or $leaf -cne ('aistick-ac-probe-' + $guid.ToString('N'))) {
        throw 'Fixture root must have the unique aistick-ac-probe-<guid> name.'
    }
    if (-not [string]::Equals((Split-Path -Parent $root).TrimEnd('\','/'), $tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture root must be a direct child of the current temp directory.' }
    if (-not [IO.Directory]::Exists($root)) { throw 'Fixture root is missing.' }
    Assert-AppContainerProbePlainTree -Path $root -Boundary $tempRoot
    $marker = Join-Path $root '.aistick-ac-probe'
    if (-not [IO.File]::Exists($marker)) { throw 'Synthetic fixture ownership marker is missing or invalid.' }
    Assert-AppContainerProbePlainTree -Path $marker -Boundary $root
    $markerValue = [IO.File]::ReadAllText($marker).Trim()
    if ($markerValue -cnotin @('synthetic appcontainer fixture v1','aistick appcontainer workspace v1')) { throw 'AppContainer fixture/workspace ownership marker is missing or invalid.' }
    $exe = [IO.Path]::GetFullPath([string]$fixture.Exe)
    $expectedExe = Join-Path $root 'app\cc-switch.exe'
    if (-not [string]::Equals($exe, $expectedExe, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($exe)) { throw 'Fixture executable must be app\cc-switch.exe inside the owned synthetic root.' }
    Assert-AppContainerProbePlainTree -Path $exe -Boundary $root
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$fixture.StickRoot), (Join-Path $root 'stick'), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$fixture.RuntimeRoot), (Join-Path $root 'runtime'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture storage roots are not the expected synthetic children.' }
    foreach ($required in @([string]$fixture.StickRoot, [string]$fixture.RuntimeRoot)) {
        if (-not [IO.Directory]::Exists($required) -or -not (Test-AppContainerProbeWithin -Path $required -Root $root)) { throw 'Fixture storage root is missing or escaped its owned root.' }
        Assert-AppContainerProbePlainTree -Path $required -Boundary $root
    }
    $managedHarnessRoot = $null
    if ($fixture.PSObject.Properties['ManagedHarnessRoot']) {
        $managedHarnessRoot = [IO.Path]::GetFullPath([string]$fixture.ManagedHarnessRoot)
        if (-not [string]::Equals($managedHarnessRoot, (Join-Path $root 'harness'), [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Directory]::Exists($managedHarnessRoot)) { throw 'ManagedHarnessRoot must be the owned NTFS workspace harness directory.' }
        Assert-AppContainerProbePlainTree -Path $managedHarnessRoot -Boundary $root
    }
    $allowedEnvironmentKeys = @('HOME','USERPROFILE','APPDATA','LOCALAPPDATA','CC_SWITCH_TEST_HOME','WEBVIEW2_USER_DATA_FOLDER','WEBVIEW2_BROWSER_EXECUTABLE_FOLDER','TEMP','TMP','CLAUDE_CONFIG_DIR','CODEX_HOME','GEMINI_CLI_HOME','PATH','npm_config_prefix','npm_config_cache','npm_config_userconfig','npm_config_globalconfig','npm_config_registry','NODE_OPTIONS','CCSWITCH_PORTABLE_UPDATE_MAILBOX','CCSWITCH_PORTABLE_UPDATE_NONCE')
    if ($null -eq $fixture.Environment -or $fixture.Environment -isnot [pscustomobject]) { throw 'Fixture environment map is invalid.' }
    $managedPath = $fixture.Environment.PSObject.Properties['PATH']
    if ($managedPath) {
        $prefixProperty = $fixture.Environment.PSObject.Properties['npm_config_prefix']
        if (-not $prefixProperty) { throw 'Managed PATH requires a matching npm_config_prefix.' }
        $prefix = [IO.Path]::GetFullPath([string]$prefixProperty.Value).TrimEnd('\','/')
        if (-not $managedHarnessRoot) { throw 'Managed PATH requires an owned NTFS ManagedHarnessRoot.' }
        $managedSlots = Join-Path $managedHarnessRoot 'slots'
        if (-not (Test-AppContainerProbeWithin -Path $prefix -Root $managedSlots) -or
            [string]::Equals($prefix, [IO.Path]::GetFullPath($managedSlots).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Parent $prefix).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($managedSlots).TrimEnd('\','/') -or
            (Split-Path -Leaf $prefix) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'npm_config_prefix must identify one direct managed Claude version slot.' }
        $parts = @(([string]$managedPath.Value).Split(';'))
        $expectedPath = @($prefix,(Join-Path ([string]$fixture.RuntimeRoot) 'node'),(Join-Path ([string]$env:SystemRoot) 'System32'))
        if ($parts.Count -ne 3) { throw 'Managed PATH must contain exactly slot, copied Node runtime, and System32.' }
        for ($i = 0; $i -lt 3; $i++) {
            if (-not [string]::Equals([IO.Path]::GetFullPath($parts[$i]).TrimEnd('\','/'), [IO.Path]::GetFullPath($expectedPath[$i]).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed PATH contains an unapproved search directory.' }
        }
        $npmData = [IO.Path]::GetFullPath((Join-Path $managedHarnessRoot 'state\npm-data')).TrimEnd('\','/') + '\'
        foreach ($name in @('npm_config_cache','npm_config_userconfig','npm_config_globalconfig')) {
            $property = $fixture.Environment.PSObject.Properties[$name]
            if (-not $property -or -not [IO.Path]::GetFullPath([string]$property.Value).StartsWith($npmData,[StringComparison]::OrdinalIgnoreCase)) { throw 'Managed npm state must stay below the synthetic harness state directory.' }
        }
        $registryProperty = $fixture.Environment.PSObject.Properties['npm_config_registry']
        if (-not $registryProperty -or [string]$registryProperty.Value -cne 'https://registry.npmjs.org/') { throw 'Managed npm registry must be the official public npm registry.' }
        $nodeOptionsProperty = $fixture.Environment.PSObject.Properties['NODE_OPTIONS']
        if (-not $nodeOptionsProperty -or [string]$nodeOptionsProperty.Value -cne '--preserve-symlinks --preserve-symlinks-main') { throw 'Managed Node options must use the fixed symlink-preservation flags.' }
    } elseif ($fixture.Environment.PSObject.Properties['npm_config_prefix'] -or $fixture.Environment.PSObject.Properties['npm_config_cache'] -or $fixture.Environment.PSObject.Properties['npm_config_userconfig'] -or $fixture.Environment.PSObject.Properties['npm_config_globalconfig'] -or $fixture.Environment.PSObject.Properties['npm_config_registry']) {
        throw 'npm environment overrides require the complete managed PATH contract.'
    } elseif ($fixture.Environment.PSObject.Properties['NODE_OPTIONS']) {
        throw 'NODE_OPTIONS is accepted only with the complete managed PATH contract.'
    }
    $mailboxProperty = $fixture.Environment.PSObject.Properties['CCSWITCH_PORTABLE_UPDATE_MAILBOX']
    $nonceProperty = $fixture.Environment.PSObject.Properties['CCSWITCH_PORTABLE_UPDATE_NONCE']
    if ([bool]$mailboxProperty -ne [bool]$nonceProperty) { throw 'Portable update mailbox and nonce must be supplied together.' }
    if ($mailboxProperty) {
        $expectedMailbox = [IO.Path]::GetFullPath((Join-Path $root 'runtime\updates\portable-update.request'))
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$mailboxProperty.Value),$expectedMailbox,[StringComparison]::OrdinalIgnoreCase)) { throw 'Portable update mailbox must use its fixed owned RuntimeRoot path.' }
        if ([string]$nonceProperty.Value -cnotmatch '^[0-9a-f]{32}$') { throw 'Portable update nonce must be 32 lowercase hexadecimal characters.' }
        Assert-AppContainerProbePlainTree -Path (Join-Path $root 'runtime') -Boundary $root
    }
    foreach ($property in $fixture.Environment.PSObject.Properties) {
        if ($allowedEnvironmentKeys -notcontains $property.Name) { throw 'Fixture contains an unapproved environment override.' }
        if ($property.Name -in @('PATH','npm_config_registry','NODE_OPTIONS','CCSWITCH_PORTABLE_UPDATE_NONCE','CCSWITCH_PORTABLE_UPDATE_MAILBOX')) { continue }
        $value = [IO.Path]::GetFullPath([string]$property.Value)
        if (-not (Test-AppContainerProbeWithin -Path $value -Root $root)) { throw 'Environment overrides must stay inside the synthetic root.' }
        Assert-AppContainerProbePlainTree -Path $value -Boundary $root
    }
    $fixture | Add-Member -MemberType NoteProperty -Name __SourcePath -Value $fullFixture -Force
    return $fixture
}

function New-AppContainerProbeEnvironmentBlock {
    param([Parameter(Mandatory = $true)]$Overrides)
    $vars = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot) -or -not [IO.Directory]::Exists($systemRoot)) { throw 'Cannot construct a minimal system environment for the AppContainer child.' }
    $vars['SystemRoot'] = $systemRoot
    $vars['WINDIR'] = $systemRoot
    if ($env:SystemDrive) { $vars['SystemDrive'] = [string]$env:SystemDrive }
    $vars['ComSpec'] = Join-Path $systemRoot 'System32\cmd.exe'
    if ($env:PROCESSOR_ARCHITECTURE) { $vars['PROCESSOR_ARCHITECTURE'] = [string]$env:PROCESSOR_ARCHITECTURE }
    if ($env:PROCESSOR_IDENTIFIER) { $vars['PROCESSOR_IDENTIFIER'] = [string]$env:PROCESSOR_IDENTIFIER }
    if ($env:NUMBER_OF_PROCESSORS) { $vars['NUMBER_OF_PROCESSORS'] = [string]$env:NUMBER_OF_PROCESSORS }
    if ($env:OS) { $vars['OS'] = [string]$env:OS }
    $vars['PATH'] = Join-Path $systemRoot 'System32'
    # Keep automatic HTTP clients independent of the host Windows proxy.
    # Explicit in-app upstream proxy settings remain the application's choice.
    foreach ($property in $Overrides.PSObject.Properties) { $vars[[string]$property.Name] = [string]$property.Value }
    # Windows command discovery for batch shims (including npm.cmd) uses
    # PATHEXT. Keep the list fixed for the owned child instead of inheriting
    # the host's executable search policy or accepting a fixture override.
    $vars['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    $vars['NO_PROXY'] = '*'
    $lines = @($vars.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value })
    return (($lines -join [char]0) + [char]0)
}

function New-AppContainerProbeJob {
    return [AiStickAppContainerNative]::CreateKillOnCloseJob()
}

function Wait-AppContainerProbeJobEmpty {
    param([Parameter(Mandatory = $true)][IntPtr]$JobHandle, [int]$TimeoutMilliseconds = 10000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ([AiStickAppContainerNative]::GetJobActiveProcessCount($JobHandle) -eq 0) { return $true }
        Start-Sleep -Milliseconds 100
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return ([AiStickAppContainerNative]::GetJobActiveProcessCount($JobHandle) -eq 0)
}

function Write-AppContainerProbeProfileMarker {
    param([string]$Root, [string]$ProfileName, [string]$Sid)
    $path = Join-Path $Root '.aistick-appcontainer-profile-owner.json'
    if (Test-Path -LiteralPath $path) { throw 'A profile ownership marker already exists; refusing to replace it.' }
    $record = [ordered]@{
        schema = 1
        profileName = $ProfileName
        appContainerSid = $Sid
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $json = ConvertTo-Json -InputObject $record -Depth 3
        $encoded = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$json)
        $stream.Write($encoded, 0, $encoded.Length)
        $stream.Flush($true)
    } catch {
        if ($stream) { $stream.Dispose(); $stream = $null }
        if ([IO.File]::Exists($path)) {
            try { Assert-AppContainerProbePlainTree -Path $path -Boundary $Root; Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { }
        }
        throw
    } finally { if ($stream) { $stream.Dispose() } }
    return $path
}

function Remove-AppContainerProbeProfileMarker {
    param([Parameter(Mandatory = $true)]$State)
    $path = Join-Path ([string]$State.FixtureRoot) '.aistick-appcontainer-profile-owner.json'
    if (-not [IO.File]::Exists($path)) { return }
    Assert-AppContainerProbePlainTree -Path $path -Boundary ([string]$State.FixtureRoot)
    $record = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$record.profileName -ne [string]$State.ProfileName -or
        [string]$record.appContainerSid -ne [string]$State.AppContainerSid) {
        throw 'Profile ownership marker changed; refusing to remove it.'
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Start-AppContainerProbeProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture, [ValidateSet('None','InternetClient')][string]$NetworkMode = 'None', [switch]$DeferResume)

    # Re-read and validate the metadata at the point of use; callers cannot widen the ACL by mutation.
    if ($Fixture -is [string]) { $sourcePath = [string]$Fixture } else { $sourcePath = [string]$Fixture.__SourcePath }
    if (-not $sourcePath) { throw 'Pass a fixture path or an object returned by Read-AppContainerFixture.' }
    $fresh = Read-AppContainerFixture -Path $sourcePath
    $fresh | Add-Member -MemberType NoteProperty -Name __SourcePath -Value $sourcePath -Force
    $root = [IO.Path]::GetFullPath([string]$fresh.Root)
    $exe = [IO.Path]::GetFullPath([string]$fresh.Exe)
    $working = Join-Path $root 'app'
    $profileName = 'AiStick.Probe.' + [guid]::NewGuid().ToString('N')
    $sidPointer = [IntPtr]::Zero
    $capabilitySid = [IntPtr]::Zero
    $capabilityArray = [IntPtr]::Zero
    $profileCreated = $false
    $originalSddl = $null
    $job = [IntPtr]::Zero
    $processInfo = New-Object AiStickProcessInfo
    $aclChanged = $false
    $markerPath = $null
    $markerCreated = $false
    try {
        if ($NetworkMode -eq 'InternetClient') {
            $capabilitySid = [AiStickAppContainerNative]::CreateInternetClientSid()
            $capabilityArray = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf([type][AiStickSidAndAttributes]))
            $capability = New-Object AiStickSidAndAttributes
            $capability.Sid = $capabilitySid
            $capability.Attributes = 4
            [Runtime.InteropServices.Marshal]::StructureToPtr($capability, $capabilityArray, $false)
        }
        $description = if ($NetworkMode -eq 'InternetClient') { 'Temporary AppContainer probe with internetClient capability' } else { 'Temporary no-capability AppContainer probe' }
        $hresult = [AiStickAppContainerNative]::CreateAppContainerProfile($profileName, 'AI Stick bounded probe', $description, $capabilityArray, [uint32]$(if ($NetworkMode -eq 'InternetClient') { 1 } else { 0 }), [ref]$sidPointer)
        if ($hresult -ne 0) { throw ('CreateAppContainerProfile failed: 0x{0:X8}' -f $hresult) }
        $profileCreated = $true
        $sid = [AiStickAppContainerNative]::SidToString($sidPointer)
        $securityId = New-Object Security.Principal.SecurityIdentifier($sid)
        # Windows rewrites TEMP/TMP for an AppContainer to its package-local
        # `LOCALAPPDATA\Packages\<profile-name>\AC\Temp` directory, even when
        # the caller supplied TEMP/TMP in the environment block. Rust's
        # std::env::temp_dir() follows that path. Create it owner-side beneath
        # the fixture's already-validated LOCALAPPDATA so Rust lifecycle code
        # can create its temporary .bat without granting access outside Root.
        $localAppDataProperty = $fresh.Environment.PSObject.Properties['LOCALAPPDATA']
        if (-not $localAppDataProperty) { throw 'AppContainer fixture must supply LOCALAPPDATA inside its owned root.' }
        $localAppDataRoot = [IO.Path]::GetFullPath([string]$localAppDataProperty.Value)
        if (-not (Test-AppContainerProbeWithin -Path $localAppDataRoot -Root $root)) { throw 'AppContainer LOCALAPPDATA must stay inside its owned root.' }
        Assert-AppContainerProbePlainTree -Path $localAppDataRoot -Boundary $root
        $packageLocalName = $profileName.ToLowerInvariant()
        $appContainerTemp = [IO.Path]::GetFullPath((Join-Path $localAppDataRoot ('Packages\' + $packageLocalName + '\AC\Temp')))
        if (-not (Test-AppContainerProbeWithin -Path $appContainerTemp -Root $root)) { throw 'AppContainer TEMP path escaped its owned root.' }
        Assert-AppContainerProbePlainTree -Path $appContainerTemp -Boundary $root
        [IO.Directory]::CreateDirectory($appContainerTemp) | Out-Null
        Assert-AppContainerProbePlainTree -Path $appContainerTemp -Boundary $root
        $markerPath = Write-AppContainerProbeProfileMarker -Root $root -ProfileName $profileName -Sid $sid
        $markerCreated = $true

        $acl = [IO.Directory]::GetAccessControl($root)
        $originalSddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $securityId,
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        $aclChanged = $true
        [IO.Directory]::SetAccessControl($root, $acl)

        $job = New-AppContainerProbeJob
        $args = [string[]]@()
        if ($fresh.PSObject.Properties['Arguments']) { $args = [string[]]@($fresh.Arguments) }
        $commandLine = (Quote-AppContainerArgument $exe) + $(if ($args.Count) { ' ' + (($args | ForEach-Object { Quote-AppContainerArgument ([string]$_) }) -join ' ') } else { '' })
        $environmentBlock = New-AppContainerProbeEnvironmentBlock -Overrides $fresh.Environment
        $processInfo = [AiStickAppContainerNative]::StartSuspendedInAppContainer($exe, $commandLine, $working, $sidPointer, $environmentBlock, ($NetworkMode -eq 'InternetClient'))
        if (-not [AiStickAppContainerNative]::AssignProcessToJobObject($job, $processInfo.hProcess)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            [AiStickAppContainerNative]::TerminateProcess($processInfo.hProcess, 1) | Out-Null
            throw (New-Object ComponentModel.Win32Exception($code))
        }
        if (-not [AiStickAppContainerNative]::VerifyAppContainerToken($processInfo.dwProcessId, $sid, ($NetworkMode -eq 'InternetClient'))) {
            [AiStickAppContainerNative]::TerminateProcess($processInfo.hProcess, 1) | Out-Null
            throw 'Suspended process did not have the expected AppContainer token and capability set; it was terminated.'
        }
        [long]$createdFileTime=0;[long]$exitedFileTime=0;[long]$kernelTime=0;[long]$userTime=0
        if(-not [AiStickAppContainerTimingV1]::GetProcessTimes($processInfo.hProcess,[ref]$createdFileTime,[ref]$exitedFileTime,[ref]$kernelTime,[ref]$userTime)) { throw 'Cannot capture the owned process creation time from its handle.' }
        $processStartTicks=[DateTime]::FromFileTimeUtc($createdFileTime).Ticks
        if (-not $DeferResume) {
            $initialResumeCount=[AiStickAppContainerNative]::ResumeThread($processInfo.hThread)
            if ($initialResumeCount -eq [uint32]::MaxValue) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                [AiStickAppContainerNative]::TerminateJobObject($job,1) | Out-Null
                throw (New-Object ComponentModel.Win32Exception($code))
            }
            if ($initialResumeCount -ne [uint32]1) {
                [AiStickAppContainerNative]::TerminateJobObject($job,1) | Out-Null
                throw 'Initial AppContainer thread resume returned an unexpected suspend count; owned Job was terminated.'
            }
            [AiStickAppContainerNative]::CloseHandle($processInfo.hThread) | Out-Null
            $processInfo.hThread = [IntPtr]::Zero
        }
        $state = [pscustomobject]@{
            ProcessId = $processInfo.dwProcessId
            ProcessStartTicks = $processStartTicks
            ProcessHandle = $processInfo.hProcess
            ThreadHandle = $processInfo.hThread
            IsResumed = (-not $DeferResume.IsPresent)
            JobHandle = $job
            ProfileName = $profileName
            AppContainerTempPath = $appContainerTemp
            AppContainerSid = $sid
            FixtureRoot = $root
            ProfileMarkerPath = $markerPath
            OriginalAccessSddl = $originalSddl
            ProfileCreated = $profileCreated
            AclChanged = $aclChanged
            NetworkMode = $NetworkMode
            NetworkCapabilitiesGranted = ($NetworkMode -eq 'InternetClient')
            Completed = $false
        }
        $processInfo.hProcess = [IntPtr]::Zero
        $job = [IntPtr]::Zero
        $profileCreated = $false
        $aclChanged = $false
        return $state
    } catch {
        $startupError = $_
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        if ($processInfo.hThread -ne [IntPtr]::Zero) { [AiStickAppContainerNative]::CloseHandle($processInfo.hThread) | Out-Null }
        if ($job -ne [IntPtr]::Zero) {
            try {
                [AiStickAppContainerNative]::TerminateJobObject($job, 1) | Out-Null
                if (-not (Wait-AppContainerProbeJobEmpty -JobHandle $job -TimeoutMilliseconds 10000)) { throw 'Owned Job did not become empty within 10 seconds.' }
            } catch { $cleanupErrors.Add($_.Exception.Message) }
            [AiStickAppContainerNative]::CloseHandle($job) | Out-Null
            $job = [IntPtr]::Zero
        }
        if ($processInfo.hProcess -ne [IntPtr]::Zero) {
            [AiStickAppContainerNative]::TerminateProcess($processInfo.hProcess, 1) | Out-Null
            $processWait = [AiStickAppContainerNative]::WaitForSingleObject($processInfo.hProcess, 10000)
            if ($processWait -eq 258) { $cleanupErrors.Add('Owned process did not exit within 10 seconds.') }
            [AiStickAppContainerNative]::CloseHandle($processInfo.hProcess) | Out-Null
        }
        if ($aclChanged -and $originalSddl -and $cleanupErrors.Count -eq 0) { try { Restore-AppContainerProbeAcl -Root $root -Sddl $originalSddl } catch { $cleanupErrors.Add('Could not restore the fixture ACL.') } }
        if ($profileCreated -and $cleanupErrors.Count -eq 0) {
            $deleteResult = [AiStickAppContainerNative]::DeleteAppContainerProfile($profileName)
            if ($deleteResult -eq 0) {
                $profileCreated = $false
                if ($markerCreated) { try { Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop } catch { $cleanupErrors.Add('Profile was deleted but its ownership marker could not be removed.') } }
            } else { $cleanupErrors.Add(('Could not delete the temporary AppContainer profile: 0x{0:X8}' -f $deleteResult)) }
        }
        if ($cleanupErrors.Count -gt 0) { throw ('AppContainer startup failed and cleanup requires inspection: ' + ($cleanupErrors -join ' ')) }
        throw $startupError
    } finally {
        if ($capabilityArray -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($capabilityArray) }
        if ($capabilitySid -ne [IntPtr]::Zero) { [AiStickAppContainerNative]::FreeLocal($capabilitySid) }
        if ($sidPointer -ne [IntPtr]::Zero) { [void][AiStickAppContainerNative]::FreeSid($sidPointer) }
    }
}

function Resume-AppContainerProbeProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State)
    if ($State.Completed -or [IntPtr]$State.JobHandle -eq [IntPtr]::Zero -or [IntPtr]$State.ProcessHandle -eq [IntPtr]::Zero) {
        throw 'Cannot resume an AppContainer process without its live owned Job and process handles.'
    }
    if ($State.IsResumed) { throw 'The AppContainer process has already been resumed.' }
    $thread = [IntPtr]$State.ThreadHandle
    if ($thread -eq [IntPtr]::Zero -or [AiStickAppContainerNative]::GetProcessId($State.ProcessHandle) -ne [uint32]$State.ProcessId) {
        [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle, 1) | Out-Null
        throw 'Deferred AppContainer thread ownership validation failed; owned Job was terminated.'
    }
    if (-not [AiStickAppContainerNative]::VerifyAppContainerToken([int]$State.ProcessId, [string]$State.AppContainerSid, [bool]$State.NetworkCapabilitiesGranted)) {
        [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle, 1) | Out-Null
        throw 'Deferred AppContainer token verification failed; owned Job was terminated.'
    }
    $resumeCount=[AiStickAppContainerNative]::ResumeThread($thread)
    if ($resumeCount -eq [uint32]::MaxValue) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle, 1) | Out-Null
        throw (New-Object ComponentModel.Win32Exception($code))
    }
    if ($resumeCount -ne [uint32]1) {
        [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle, 1) | Out-Null
        throw 'Deferred AppContainer thread resume returned an unexpected suspend count; owned Job was terminated.'
    }
    [AiStickAppContainerNative]::CloseHandle($thread) | Out-Null
    $State.ThreadHandle = [IntPtr]::Zero
    $State.IsResumed = $true
    return $State
}

function Quote-AppContainerArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"'); $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$builder.Append(('\' * (2 * $slashes + 1))); [void]$builder.Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Restore-AppContainerProbeAcl {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Sddl)
    $acl = [IO.Directory]::GetAccessControl($Root)
    $acl.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::Access)
    [IO.Directory]::SetAccessControl($Root, $acl)
}

function Wait-AppContainerProbeProcess {
    param([Parameter(Mandatory = $true)]$State, [int]$TimeoutSeconds = 0)
    $milliseconds = [uint32]::MaxValue
    if ($TimeoutSeconds -gt 0) {
        if ($TimeoutSeconds -ge 4294967) { $milliseconds = [uint32]::MaxValue - 1 }
        else { $milliseconds = [uint32]($TimeoutSeconds * 1000) }
    }
    $result = [AiStickAppContainerNative]::WaitForSingleObject([IntPtr]$State.ProcessHandle, $milliseconds)
    if ($result -eq 258) { return [pscustomobject]@{ Completed = $false; ExitCode = $null; ProcessId = $State.ProcessId } }
    if ($result -ne 0) { throw 'Waiting for the AppContainer process failed.' }
    [uint32]$exitCode = 0
    if (-not [AiStickAppContainerNative]::GetExitCodeProcess([IntPtr]$State.ProcessHandle, [ref]$exitCode)) { throw 'Cannot read the AppContainer process exit code.' }
    return [pscustomobject]@{ Completed = $true; ExitCode = [int64]$exitCode; ProcessId = $State.ProcessId }
}

function Complete-AppContainerProbeProcess {
    param([Parameter(Mandatory = $true)]$State)
    if ($State.Completed) { return }
    if ([IntPtr]$State.ThreadHandle -ne [IntPtr]::Zero) {
        [AiStickAppContainerNative]::CloseHandle([IntPtr]$State.ThreadHandle) | Out-Null
        $State.ThreadHandle = [IntPtr]::Zero
    }
    # Terminate and observe the complete Job tree before restoring its ACL or deleting its profile.
    if ([IntPtr]$State.JobHandle -ne [IntPtr]::Zero) {
        if (-not [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle, 0)) {
            throw ('TerminateJobObject failed: {0}' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        if (-not (Wait-AppContainerProbeJobEmpty -JobHandle ([IntPtr]$State.JobHandle) -TimeoutMilliseconds 10000)) {
            throw 'Owned AppContainer Job still has active processes after 10 seconds; ACL and profile are retained for inspection.'
        }
        [AiStickAppContainerNative]::CloseHandle([IntPtr]$State.JobHandle) | Out-Null
        $State.JobHandle = [IntPtr]::Zero
    }
    if ([IntPtr]$State.ProcessHandle -ne [IntPtr]::Zero) {
        $waitResult = [AiStickAppContainerNative]::WaitForSingleObject([IntPtr]$State.ProcessHandle, 10000)
        if ($waitResult -ne 0) { throw 'Owned AppContainer process did not signal exit after its Job became empty.' }
        [AiStickAppContainerNative]::CloseHandle([IntPtr]$State.ProcessHandle) | Out-Null
        $State.ProcessHandle = [IntPtr]::Zero
    }
    $aclError = $null
    if ($State.AclChanged) {
        try { Restore-AppContainerProbeAcl -Root ([string]$State.FixtureRoot) -Sddl ([string]$State.OriginalAccessSddl) }
        catch { $aclError = $_ }
    }
    $deleteHresult = 0
    if ($State.ProfileCreated) {
        $deleteHresult = [AiStickAppContainerNative]::DeleteAppContainerProfile([string]$State.ProfileName)
        if ($deleteHresult -eq 0) { $State.ProfileCreated = $false }
    }
    if (-not $aclError) { $State.AclChanged = $false }
    if ($deleteHresult -eq 0 -and -not $aclError) {
        Remove-AppContainerProbeProfileMarker -State $State
        $State.Completed = $true
    }
    if ($aclError) { throw $aclError }
    if ($deleteHresult -ne 0) { throw ('DeleteAppContainerProfile failed: 0x{0:X8}' -f $deleteHresult) }
}

function New-AppContainerProbeFixtureRoot {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $name = 'aistick-ac-probe-' + [guid]::NewGuid().ToString('N')
    $root = Join-Path $tempRoot $name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.aistick-ac-probe'), 'synthetic appcontainer fixture v1', (New-Object Text.UTF8Encoding($false)))
    return $root
}

function Invoke-AppContainerProbeFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSeconds = 0, [ValidateSet('None','InternetClient')][string]$NetworkMode = 'None')
    $fixture = Read-AppContainerFixture -Path $Path
    $fixture | Add-Member -MemberType NoteProperty -Name __SourcePath -Value ([IO.Path]::GetFullPath($Path)) -Force
    $state = $null
    $summary = $null
    $runError = $null
    $cleanupError = $null
    try {
        $state = Start-AppContainerProbeProcess -Fixture $fixture -NetworkMode $NetworkMode
        $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds $TimeoutSeconds
        if (-not $wait.Completed) { throw 'Synthetic app did not exit within the configured timeout.' }
        $summary = [pscustomobject]@{
            ProcessId = $wait.ProcessId
            ExitCode = $wait.ExitCode
            IsAppContainer = $true
            AppContainerSidVerified = $true
            NetworkMode = $NetworkMode
            NetworkCapabilitiesGranted = ($NetworkMode -eq 'InternetClient')
            FilesystemGrantRoot = $state.FixtureRoot
            ProfileName = $state.ProfileName
            FixtureRetainedForInspection = $true
        }
        Complete-AppContainerProbeProcess -State $state
    } catch { $runError = $_ }
    finally {
        if ($state -and -not $state.Completed) {
            try { Complete-AppContainerProbeProcess -State $state } catch { $cleanupError = $_ }
        }
    }
    if ($cleanupError) { throw ('AppContainer cleanup failed; profile/ACL state requires inspection: ' + $cleanupError.Exception.Message) }
    if ($runError) { throw $runError }
    return $summary
}

$dotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $dotSourced) {
    if (-not $FixturePath) { $FixturePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\cc-appcontainer-fixture.json' }
    if ($Action -eq 'Inspect') {
        $fixture = Read-AppContainerFixture -Path $FixturePath
        [pscustomobject]@{
            FixtureValid = $true
            Executable = [string]$fixture.Exe
            FilesystemGrantRoot = [string]$fixture.Root
            EnvironmentOverrides = @($fixture.Environment.PSObject.Properties.Name)
            NetworkMode = 'None'
            NetworkCapabilitiesGranted = $false
            LaunchPerformed = $false
        }
    } else {
        $result = Invoke-AppContainerProbeFixture -Path $FixturePath -TimeoutSeconds $TimeoutSeconds
        Write-Output $result
        Write-Host ("AppContainer probe exited {0}; PID {1}; profile cleaned; fixture retained." -f $result.ExitCode, $result.ProcessId)
    }
}

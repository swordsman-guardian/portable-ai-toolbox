Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ('CcPortableUpdaterInjectionNativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct CcPortableModuleEntryV1 {
    public uint dwSize, th32ModuleID, th32ProcessID, GlblcntUsage, ProccntUsage;
    public IntPtr modBaseAddr; public uint modBaseSize; public IntPtr hModule;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szModule;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExePath;
}

public static class CcPortableUpdaterInjectionNativeV1 {
    const uint PROCESS_ACCESS = 0x0010043A;
    const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000;
    const uint PAGE_READWRITE = 0x04, TH32CS_SNAPMODULE = 0x08, TH32CS_SNAPMODULE32 = 0x10;
    const uint WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258;
    const uint PAGE_EXECUTE_READWRITE = 0x40;
    const uint CONTEXT_CONTROL_AMD64 = 0x00100001;
    [StructLayout(LayoutKind.Sequential)] public struct ProcessBasicInformationV1 {
        public IntPtr Reserved1, PebBaseAddress, Reserved2_0, Reserved2_1, UniqueProcessId, InheritedFromUniqueProcessId;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetProcessId(IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsWow64Process(IntPtr process, out bool wow64);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protection);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr size, out UIntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, UIntPtr stackSize, IntPtr start, IntPtr parameter, uint flags, out uint threadId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeThread(IntPtr thread, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetThreadContext(IntPtr thread, IntPtr context);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualProtectEx(IntPtr process, IntPtr address, UIntPtr size, uint protection, out uint oldProtection);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FlushInstructionCache(IntPtr process, IntPtr address, UIntPtr size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, out ProcessBasicInformationV1 info, int length, out int returned);

    static byte[] ReadExact(IntPtr process, IntPtr address, int count) {
        byte[] bytes = new byte[count]; UIntPtr read;
        if (!ReadProcessMemory(process,address,bytes,(UIntPtr)count,out read) || read.ToUInt64() != (ulong)count) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot read owned suspended process memory.");
        return bytes;
    }
    static void WriteExecutableBytes(IntPtr process, IntPtr address, byte[] bytes) {
        uint old; UIntPtr size=(UIntPtr)bytes.Length;
        if (!VirtualProtectEx(process,address,size,PAGE_EXECUTE_READWRITE,out old)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot temporarily protect owned entry point.");
        try {
            UIntPtr written;
            if (!WriteProcessMemory(process,address,bytes,size,out written) || written.ToUInt64() != (ulong)bytes.Length) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot patch owned entry point in memory.");
            if (!FlushInstructionCache(process,address,size)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot flush owned entry-point instruction cache.");
        } finally {
            uint ignored;
            if (!VirtualProtectEx(process,address,size,old,out ignored))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot restore owned entry-point memory protection; the caller must terminate the owned Job.");
        }
    }
    public static void ReachOwnedPreEntryBarrier(IntPtr process, IntPtr thread, string exePath) {
        byte[] image=System.IO.File.ReadAllBytes(exePath);
        if(image.Length<0x100 || image[0]!=(byte)'M' || image[1]!=(byte)'Z') throw new InvalidOperationException("Owned executable is not a valid PE image.");
        int pe=BitConverter.ToInt32(image,0x3c);
        if(pe<0x40 || pe>image.Length-0x100 || BitConverter.ToUInt32(image,pe)!=0x4550 || BitConverter.ToUInt16(image,pe+4)!=0x8664) throw new InvalidOperationException("Owned executable is not the expected x64 PE image.");
        int optional=pe+24;
        if(BitConverter.ToUInt16(image,optional)!=0x20b) throw new InvalidOperationException("Owned executable has an unsupported PE optional header.");
        uint entryRva=BitConverter.ToUInt32(image,optional+16), imageSize=BitConverter.ToUInt32(image,optional+56);
        ushort sectionCount=BitConverter.ToUInt16(image,pe+6), optionalSize=BitConverter.ToUInt16(image,pe+20);
        if(entryRva==0 || imageSize==0 || entryRva>=imageSize || sectionCount==0) throw new InvalidOperationException("Owned executable entry-point RVA is invalid.");
        int sectionTable=optional+optionalSize; bool executableEntry=false;
        for(int i=0;i<sectionCount;i++) {
            int sh=sectionTable+i*40; if(sh<0 || sh>image.Length-40) throw new InvalidOperationException("Owned executable section table is truncated.");
            uint virtualSize=BitConverter.ToUInt32(image,sh+8), virtualAddress=BitConverter.ToUInt32(image,sh+12), rawSize=BitConverter.ToUInt32(image,sh+16), characteristics=BitConverter.ToUInt32(image,sh+36);
            uint span=Math.Max(virtualSize,rawSize);
            if((characteristics&0x20000000)!=0 && entryRva>=virtualAddress && (ulong)entryRva<(ulong)virtualAddress+span) executableEntry=true;
        }
        if(!executableEntry) throw new InvalidOperationException("Owned entry-point RVA is outside an executable PE section.");
        ProcessBasicInformationV1 basic; int returned;
        int status=NtQueryInformationProcess(process,0,out basic,Marshal.SizeOf(typeof(ProcessBasicInformationV1)),out returned);
        if(status!=0 || basic.PebBaseAddress==IntPtr.Zero) throw new InvalidOperationException("Cannot validate the owned process PEB.");
        byte[] imageBaseBytes=ReadExact(process,IntPtr.Add(basic.PebBaseAddress,0x10),8);
        long imageBase=BitConverter.ToInt64(imageBaseBytes,0);
        IntPtr entry= new IntPtr(checked(imageBase+(long)entryRva));
        byte[] original=ReadExact(process,entry,2);
        byte[] barrier=new byte[]{0xEB,0xFE};
        WriteExecutableBytes(process,entry,barrier);
        bool suspended=false, reached=false;
        IntPtr contextRaw=IntPtr.Zero, context=IntPtr.Zero;
        try {
            contextRaw=Marshal.AllocHGlobal(1247);
            long aligned=(contextRaw.ToInt64()+15L)&~15L; context=new IntPtr(aligned);
            uint initialResumeCount=ResumeThread(thread);
            if(initialResumeCount==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot enter the owned loader pre-entry barrier.");
            if(initialResumeCount!=1) throw new InvalidOperationException("Owned pre-entry thread had an unexpected initial suspend count; terminate the owned Job.");
            var timer=System.Diagnostics.Stopwatch.StartNew();
            while(timer.ElapsedMilliseconds<10000) {
                System.Threading.Thread.Sleep(10);
                uint prior=SuspendThread(thread);
                if(prior==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot hold the owned process at its pre-entry barrier.");
                suspended=true;
                if(prior!=0) throw new InvalidOperationException("Owned pre-entry thread had an unexpected suspend count; terminate the owned Job.");
                byte[] clear=new byte[1232];Marshal.Copy(clear,0,context,clear.Length);Marshal.WriteInt32(context,48,(int)CONTEXT_CONTROL_AMD64);
                if(!GetThreadContext(thread,context)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot inspect the owned pre-entry thread context.");
                long rip=Marshal.ReadInt64(context,248);
                if(rip==entry.ToInt64()) { reached=true; break; }
                uint resumeCount=ResumeThread(thread);
                if(resumeCount==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot continue waiting for the owned pre-entry barrier.");
                if(resumeCount!=1) throw new InvalidOperationException("Owned pre-entry thread had an unexpected resume count; terminate the owned Job.");
                suspended=false;
            }
            if(!suspended || !reached) throw new TimeoutException("Owned process did not reach its entry-point barrier within 10 seconds.");
            WriteExecutableBytes(process,entry,original);
        } finally {
            // Fail closed: leave the entry-point spin patch or a suspended thread
            // in place; the caller terminates the owned Job on any exception.
            if(contextRaw!=IntPtr.Zero) Marshal.FreeHGlobal(contextRaw);
        }
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr GetModuleHandleW(string module);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr handle, StringBuilder path, uint count, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Module32FirstW(IntPtr snapshot, ref CcPortableModuleEntryV1 entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool Module32NextW(IntPtr snapshot, ref CcPortableModuleEntryV1 entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool GetModuleHandleExW(uint flags, IntPtr address, out IntPtr module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetModuleFileNameW(IntPtr module, StringBuilder path, uint size);

    public static IntPtr FindRemoteModule(uint pid, string fullPath) {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snapshot == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var entry = new CcPortableModuleEntryV1(); entry.dwSize = (uint)Marshal.SizeOf(typeof(CcPortableModuleEntryV1));
            if (!Module32FirstW(snapshot, ref entry)) throw new Win32Exception(Marshal.GetLastWin32Error());
            do { if (String.Equals(System.IO.Path.GetFullPath(entry.szExePath), System.IO.Path.GetFullPath(fullPath), StringComparison.OrdinalIgnoreCase)) return entry.modBaseAddr; }
            while (Module32NextW(snapshot, ref entry));
            return IntPtr.Zero;
        } finally { CloseHandle(snapshot); }
    }
    public static IntPtr FindRemoteModuleByLeaf(uint pid, string leaf) {
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snapshot == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var entry = new CcPortableModuleEntryV1(); entry.dwSize = (uint)Marshal.SizeOf(typeof(CcPortableModuleEntryV1));
            if (!Module32FirstW(snapshot, ref entry)) throw new Win32Exception(Marshal.GetLastWin32Error());
            do { if (String.Equals(entry.szModule, leaf, StringComparison.OrdinalIgnoreCase)) return entry.modBaseAddr; }
            while (Module32NextW(snapshot, ref entry));
            return IntPtr.Zero;
        } finally { CloseHandle(snapshot); }
    }
    public static IntPtr LocalModuleForAddress(IntPtr address) {
        IntPtr module;
        if (!GetModuleHandleExW(0x4 | 0x2, address, out module)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return module;
    }
    public static string LocalModulePath(IntPtr module) {
        var path = new StringBuilder(32768);
        uint n = GetModuleFileNameW(module, path, (uint)path.Capacity);
        if (n == 0 || n >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
        return path.ToString();
    }
    public static string FinalPathFromOwnedHandle(string path, bool directory, uint volumeFlags) {
        const uint FILE_READ_ATTRIBUTES=0x80, FILE_SHARE_ALL=7, OPEN_EXISTING=3, FILE_FLAG_BACKUP_SEMANTICS=0x02000000;
        IntPtr handle=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_ALL,IntPtr.Zero,OPEN_EXISTING,directory?FILE_FLAG_BACKUP_SEMANTICS:0,IntPtr.Zero);
        if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot open the verified owned path for handle identity mapping.");
        try {
            uint required=GetFinalPathNameByHandleW(handle,null,0,volumeFlags);
            if(required==0 || required>32768) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot query the verified owned handle path.");
            var result=new StringBuilder((int)required+1);
            uint copied=GetFinalPathNameByHandleW(handle,result,(uint)result.Capacity,volumeFlags);
            if(copied==0 || copied>=result.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot read the verified owned handle path.");
            return result.ToString();
        } finally { CloseHandle(handle); }
    }
    public static uint RunRemote(IntPtr process, IntPtr start, IntPtr parameter, uint timeout) {
        uint threadId; IntPtr thread = CreateRemoteThread(process, IntPtr.Zero, UIntPtr.Zero, start, parameter, 0, out threadId);
        if (thread == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            uint wait = WaitForSingleObject(thread, timeout);
            if (wait == WAIT_TIMEOUT) throw new TimeoutException("Remote shim operation exceeded its bounded wait.");
            if (wait != WAIT_OBJECT_0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code; if (!GetExitCodeThread(thread, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return code;
        } finally { CloseHandle(thread); }
    }
    public static IntPtr AllocateAndWrite(IntPtr process, byte[] bytes) {
        IntPtr remote = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)bytes.Length, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (remote == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        UIntPtr written;
        if (!WriteProcessMemory(process, remote, bytes, (UIntPtr)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length) {
            int code = Marshal.GetLastWin32Error(); VirtualFreeEx(process, remote, UIntPtr.Zero, MEM_RELEASE); throw new Win32Exception(code);
        }
        return remote;
    }
}
'@
}

function Install-CcSwitchPortableUpdaterShim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)][string]$OwnedAppRoot,
        [Parameter(Mandatory=$true)][string]$ShimSource,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedShimSha256,
        [Parameter(Mandatory=$true)][string]$NoopSource,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedNoopSha256,
        [string]$ShimFileName,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedExeSha256,
        [Parameter(Mandatory=$true)][string]$MailboxPath,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$Nonce,
        [Parameter(Mandatory=$true)][long]$ExpectedProcessStartTicks
    )
    $ownedRoot = [IO.Path]::GetFullPath([string]$State.FixtureRoot).TrimEnd('\')
    $appRoot = [IO.Path]::GetFullPath($OwnedAppRoot).TrimEnd('\')
    $expectedAppRoot = [IO.Path]::GetFullPath((Join-Path $ownedRoot 'app')).TrimEnd('\')
    if (-not [string]::Equals($appRoot,$expectedAppRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Shim target must be the owned fixture app directory.' }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::Equals((Split-Path -Parent $ownedRoot),$tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $ownedRoot) -notmatch '^aistick-ac-probe-[0-9a-f]{32}$') { throw 'Shim target root is not an owned temporary AppContainer fixture.' }
    $runtimeRoot = Join-Path $ownedRoot 'runtime'
    $expectedMailbox = Join-Path $runtimeRoot 'updates\portable-update.request'
    if (-not [string]::Equals([IO.Path]::GetFullPath($MailboxPath),[IO.Path]::GetFullPath($expectedMailbox),[StringComparison]::OrdinalIgnoreCase)) { throw 'Mailbox must use the single fixed fixture runtime event path.' }
    if (-not [IO.Directory]::Exists((Split-Path -Parent $expectedMailbox)) -or [IO.File]::Exists($expectedMailbox)) { throw 'Mailbox parent must exist and the one-shot request file must not already exist.' }
    foreach ($path in @($ownedRoot,$appRoot,$runtimeRoot,(Split-Path -Parent $expectedMailbox))) {
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Shim fixture paths may not be reparse points.' }
    }
    $exe = Join-Path $appRoot 'cc-switch.exe'
    $shimPrefix=$ExpectedShimSha256.Substring(0,16).ToLowerInvariant()
    $expectedShimLeaf='cc-switch-portable-updater-shim-'+$shimPrefix+'.dll'
    if($ShimFileName -and $ShimFileName -cne $expectedShimLeaf){throw 'Shim filename must be derived from its pinned digest.'}
    if(-not $ShimFileName){$ShimFileName=$expectedShimLeaf}
    $shimPath = Join-Path $appRoot $ShimFileName
    $noopPath=Join-Path $appRoot 'cc-switch-portable-update-noop.exe'
    if (-not [IO.File]::Exists($exe) -or -not [IO.File]::Exists($ShimSource) -or -not [IO.File]::Exists($NoopSource)) { throw 'The owned app executable or verified adapter binary is missing.' }
    $exeHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    $sourceHash=(Get-FileHash -LiteralPath $ShimSource -Algorithm SHA256).Hash
    $noopSourceHash=(Get-FileHash -LiteralPath $NoopSource -Algorithm SHA256).Hash
    if (-not [string]::Equals($exeHash,$ExpectedExeSha256,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($sourceHash,$ExpectedShimSha256,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($noopSourceHash,$ExpectedNoopSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'Executable or adapter binary failed its pinned SHA-256 check.' }
    $exeItem=Get-Item -LiteralPath $exe -Force -ErrorAction Stop
    if($exeItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The verified executable may not be a reparse point.'}
    $ownedDosRoot=[CcPortableUpdaterInjectionNativeV1]::FinalPathFromOwnedHandle($ownedRoot,$true,0)
    $ownedNtRoot=[CcPortableUpdaterInjectionNativeV1]::FinalPathFromOwnedHandle($ownedRoot,$true,2)
    $expectedDosExe=[CcPortableUpdaterInjectionNativeV1]::FinalPathFromOwnedHandle($exe,$false,0)
    $expectedNtExe=[CcPortableUpdaterInjectionNativeV1]::FinalPathFromOwnedHandle($exe,$false,2)
    if(-not $ownedDosRoot.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase) -or
       -not [string]::Equals($expectedDosExe,($ownedDosRoot.TrimEnd('\')+'\app\cc-switch.exe'),[StringComparison]::OrdinalIgnoreCase) -or
       -not $expectedNtExe.StartsWith(($ownedNtRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Owned root and executable handle paths do not form the expected DOS/NT mapping.' }
    if(-not $State.ProfileName -or [string]$State.ProfileName -notmatch '^AiStick\.Probe\.[0-9a-f]{32}$' -or -not $State.AppContainerTempPath){throw 'AppContainer profile name or owner-recorded temporary directory is invalid.'}
    $expectedAcTemp=[IO.Path]::GetFullPath([string]$State.AppContainerTempPath).TrimEnd('\')
    $expectedTempSuffix='\Packages\'+([string]$State.ProfileName).ToLowerInvariant()+'\AC\Temp'
    if(-not $expectedAcTemp.StartsWith(($ownedRoot+'\'),[StringComparison]::OrdinalIgnoreCase) -or -not $expectedAcTemp.EndsWith($expectedTempSuffix,[StringComparison]::OrdinalIgnoreCase)){throw 'AppContainer temporary directory is not the exact profile-local child of the owned fixture.'}
    if(-not [IO.Directory]::Exists($expectedAcTemp)){throw 'The exact owner-created AppContainer temporary directory is missing.'}
    $acPath=$expectedAcTemp
    while($acPath -and $acPath.Length -ge $ownedRoot.Length){
        $acItem=Get-Item -LiteralPath $acPath -Force -ErrorAction Stop
        if($acItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The AppContainer temporary path may not contain a reparse point.'}
        if([string]::Equals($acPath,$ownedRoot,[StringComparison]::OrdinalIgnoreCase)){break}
        $acPath=Split-Path -Parent $acPath
    }
    if ([IO.File]::Exists($shimPath)) {
        if ((Get-FileHash -LiteralPath $shimPath -Algorithm SHA256).Hash -ne $ExpectedShimSha256) { throw 'A different shim already exists in the owned app directory.' }
    } else { [IO.File]::Copy($ShimSource,$shimPath,$false) }
    if ((Get-FileHash -LiteralPath $shimPath -Algorithm SHA256).Hash -ne $ExpectedShimSha256) { throw 'Copied shim failed verification.' }
    if ([IO.File]::Exists($noopPath)) {
        if ((Get-FileHash -LiteralPath $noopPath -Algorithm SHA256).Hash -ne $ExpectedNoopSha256) { throw 'A different no-op adapter executable already exists in the owned app directory.' }
    } else { [IO.File]::Copy($NoopSource,$noopPath,$false) }
    if ((Get-FileHash -LiteralPath $noopPath -Algorithm SHA256).Hash -ne $ExpectedNoopSha256) { throw 'Copied no-op adapter executable failed verification.' }

    $pidValue=[uint32]$State.ProcessId
    $process=[IntPtr]$State.ProcessHandle
    if ($process -eq [IntPtr]::Zero -or [CcPortableUpdaterInjectionNativeV1]::GetProcessId($process) -ne $pidValue) { throw 'The AppContainer process handle and PID do not identify the same process.' }
    $processPath=New-Object Text.StringBuilder 32768
    [uint32]$pathChars=32768
    if (-not [CcPortableUpdaterInjectionNativeV1]::QueryFullProcessImageNameW($process,0,$processPath,[ref]$pathChars) -or
        -not [string]::Equals([IO.Path]::GetFullPath($processPath.ToString()),[IO.Path]::GetFullPath($exe),[StringComparison]::OrdinalIgnoreCase)) { throw 'Running process image is not the pinned executable in the owned fixture.' }
    [long]$created=0;[long]$exited=0;[long]$kernel=0;[long]$user=0
    if (-not [CcPortableUpdaterInjectionNativeV1]::GetProcessTimes($process,[ref]$created,[ref]$exited,[ref]$kernel,[ref]$user) -or [DateTime]::FromFileTimeUtc($created).Ticks -ne $ExpectedProcessStartTicks) { throw 'Process start time changed from the owner-recorded fixture process.' }
    $isWow64=$false
    if (-not [CcPortableUpdaterInjectionNativeV1]::IsWow64Process($process,[ref]$isWow64) -or $isWow64) { throw 'Only the verified x64 fixture process can receive this shim.' }
    if (-not ('AiStickAppContainerNative' -as [type]) -or -not [AiStickAppContainerNative]::VerifyAppContainerToken([int]$pidValue,[string]$State.AppContainerSid,([string]$State.NetworkMode -eq 'InternetClient'))) { throw 'Target AppContainer SID or capability set failed verification.' }
    if (-not $State.IsResumed) {
        if ([IntPtr]$State.ThreadHandle -eq [IntPtr]::Zero) { throw 'Deferred injection requires the retained primary thread handle.' }
        # Let Windows finish loader initialization, but hold the verified image at
        # its in-memory entry-point spin barrier before Rust/Tauri constructors.
        [CcPortableUpdaterInjectionNativeV1]::ReachOwnedPreEntryBarrier($process,[IntPtr]$State.ThreadHandle,$exe)
    }

    $pathRemote=[IntPtr]::Zero;$configRemote=[IntPtr]::Zero;$localShim=[IntPtr]::Zero
    try {
        $loadLibraryLocal=[CcPortableUpdaterInjectionNativeV1]::GetProcAddress([CcPortableUpdaterInjectionNativeV1]::GetModuleHandleW('kernel32.dll'),'LoadLibraryW')
        if ($loadLibraryLocal -eq [IntPtr]::Zero) { throw 'Cannot resolve the Windows loader entry point.' }
        $loaderModule=[CcPortableUpdaterInjectionNativeV1]::LocalModuleForAddress($loadLibraryLocal)
        $loaderPath=[CcPortableUpdaterInjectionNativeV1]::LocalModulePath($loaderModule)
        $remoteLoaderModule=[CcPortableUpdaterInjectionNativeV1]::FindRemoteModule($pidValue,$loaderPath)
        if ($remoteLoaderModule -eq [IntPtr]::Zero) { throw 'Target process loader module could not be matched by full path.' }
        $remoteLoadLibrary=[IntPtr]($remoteLoaderModule.ToInt64()+($loadLibraryLocal.ToInt64()-$loaderModule.ToInt64()))

        $pathBytes=[Text.Encoding]::Unicode.GetBytes($shimPath + [char]0)
        $pathRemote=[CcPortableUpdaterInjectionNativeV1]::AllocateAndWrite($process,$pathBytes)
        if ([CcPortableUpdaterInjectionNativeV1]::RunRemote($process,$remoteLoadLibrary,$pathRemote,10000) -eq 0) { throw 'Remote LoadLibraryW failed to load the verified shim.' }
        $remoteShim=[CcPortableUpdaterInjectionNativeV1]::FindRemoteModule($pidValue,$shimPath)
        if ($remoteShim -eq [IntPtr]::Zero) { throw 'The loaded shim module could not be located by exact full path.' }
        $localShim=[CcPortableUpdaterInjectionNativeV1]::LoadLibraryW($shimPath)
        if ($localShim -eq [IntPtr]::Zero) { throw ('Owner could not load the verified shim to resolve its stable export RVA (Win32 error {0}).' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $installLocal=[CcPortableUpdaterInjectionNativeV1]::GetProcAddress($localShim,'CCSU_InstallOpenerHook')
        if ($installLocal -eq [IntPtr]::Zero) { throw 'The verified shim lacks its required hook export.' }
        $remoteInstall=[IntPtr]($remoteShim.ToInt64()+($installLocal.ToInt64()-$localShim.ToInt64()))

        $configStrings=@($expectedMailbox,$Nonce,$noopPath,$ownedDosRoot,$ownedNtRoot,$expectedDosExe,$expectedNtExe,$expectedAcTemp)
        $charCounts=[uint32[]]@($configStrings | ForEach-Object { $_.Length+1 })
        $tail=[Text.Encoding]::Unicode.GetBytes(($configStrings | ForEach-Object { $_+[char]0 }) -join '')
        $configBytes=New-Object byte[] (36+$tail.Length)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$configBytes.Length),0,$configBytes,0,4)
        for($i=0;$i -lt $charCounts.Length;$i++){[Array]::Copy([BitConverter]::GetBytes($charCounts[$i]),0,$configBytes,4+4*$i,4)}
        [Array]::Copy($tail,0,$configBytes,36,$tail.Length)
        $configRemote=[CcPortableUpdaterInjectionNativeV1]::AllocateAndWrite($process,$configBytes)
        $readyCode=[CcPortableUpdaterInjectionNativeV1]::RunRemote($process,$remoteInstall,$configRemote,10000)
        if ($readyCode -ne 1) {
            $setupMarkers=@(Get-ChildItem -LiteralPath (Split-Path -Parent $expectedMailbox) -Filter 'shim-*.hit' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            throw ('Shim hook did not report ready (code {0}; setup markers: {1}).' -f $readyCode,($setupMarkers -join ','))
        }
        return [pscustomobject]@{Ready=$true;ProcessId=$pidValue;ShimPath=$shimPath;NoopPath=$noopPath;MailboxPath=$expectedMailbox;HookExport='CCSU_InstallOpenerHook'}
    } catch {
        if ([IntPtr]$State.JobHandle -ne [IntPtr]::Zero) { [AiStickAppContainerNative]::TerminateJobObject([IntPtr]$State.JobHandle,1) | Out-Null }
        throw
    } finally {
        if ($configRemote -ne [IntPtr]::Zero) { [CcPortableUpdaterInjectionNativeV1]::VirtualFreeEx($process,$configRemote,[UIntPtr]::Zero,0x8000) | Out-Null }
        if ($pathRemote -ne [IntPtr]::Zero) { [CcPortableUpdaterInjectionNativeV1]::VirtualFreeEx($process,$pathRemote,[UIntPtr]::Zero,0x8000) | Out-Null }
        if ($localShim -ne [IntPtr]::Zero) { [CcPortableUpdaterInjectionNativeV1]::FreeLibrary($localShim) | Out-Null }
    }
}

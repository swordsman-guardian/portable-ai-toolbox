# ============================================================
#  guardian.ps1 —— 会话守护进程
#
#  ★ 这个脚本被拷到主机上运行（在 <会话>\guard\ 里），之后完全不依赖 U 盘。
#    放在 U 盘上就错了：盘一拔它自己先死，没法收拾残局。
#
#  三层设计（缺一层不成立）：
#    第一层 守护在主机上 → 拔盘后它活着
#    第二层 Job Object 的 KILL_ON_JOB_CLOSE → 内核级兜底，守护被强杀也不留活口
#    第三层 认卷不认盘符 → 拔盘后别的设备占用同一盘符也不会误判
#
#  ★★ 安全铁律：绝不按映像名杀进程。
#     禁止 taskkill /IM claude.exe、Stop-Process -Name claude 这类写法 ——
#     宿主上可能正跑着用户自己的 AI 会话，那样会直接杀掉它。
#     只终止我们自己 Job 里的进程。
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StickRoot,
    [Parameter(Mandatory)][string]$SessionRoot,     # 本机唯一 GUID 会话根目录
    [Parameter(Mandatory)][string]$GuardDir,        # <会话>\guard（本脚本所在）
    [Parameter(Mandatory)][string]$DriveLetter,
    [string]$VolumeGuid,
    [string]$Serial,
    [Parameter(Mandatory)][string]$HarnessExe,
    [Parameter(Mandatory)][string]$WorkingDir,
    [string[]]$HarnessArgs = @(),
    [Parameter(Mandatory)][string]$SessionsDir,     # U 盘 sessions\<主机>\<harness>\runs\<session-id>
    [Parameter(Mandatory)][string]$SourceDir,       # 会话里的 CLAUDE_CONFIG_DIR
    [ValidateSet('Archive','DirectUsb')][string]$StorageMode = 'Archive',
    [string]$SessionId = '',
    [object]$SessionLock = $null,
    [string]$ProjectName = '',
    [int]$SyncSeconds = 30,
    [int]$MaxMinutes = 0,                           # 0 = 不限时
    [ValidateRange(1,600)][int]$SyncDrainTimeoutSeconds = 30,
    [ValidateRange(1,60)][int]$SyncStopTimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $GuardDir 'lib.ps1')
. (Join-Path $GuardDir 'session-manager.ps1')
Set-ConsoleUtf8

# 日志：拔盘后就不能写 U 盘了，所以优先写本机（会话目录还在时），
# 同时尽量往 U 盘留一份给人看
$localLog = Join-Path $GuardDir 'guardian.log'

# ★ 守护进程和 harness 的 TUI **共用同一个控制台**。
#   运行期往控制台打任何一行，都会插进 TUI 的界面里，看起来就像"一堆同步错误"。
#   所以：运行期只写日志文件，不碰控制台；只有 harness 退出后的收尾汇总才打印。
#   （实测踩过：同步耗时超过间隔时会每轮打一条 WARN，把 TUI 刷花）
$script:EchoToConsole = $true

function Write-GLog {
    param([string]$Msg, [string]$Level = 'INFO', [switch]$Force)
    $line = '[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    if ($script:EchoToConsole -or $Force) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'OK'    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
    try { Add-Content -LiteralPath $localLog -Value $line -Encoding UTF8 -EA SilentlyContinue } catch { }
}

function Quote-Win32Argument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $b = New-Object Text.StringBuilder
    [void]$b.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$b.Append(('\' * (2 * $slashes + 1)))
            [void]$b.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$b.Append(('\' * $slashes)); $slashes = 0 }
        [void]$b.Append($ch)
    }
    if ($slashes) { [void]$b.Append(('\' * (2 * $slashes))) }
    [void]$b.Append('"')
    return $b.ToString()
}

# ============================================================
#  Job Object（内核级兜底）
# ============================================================
if (-not ('JobObj' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct IO_COUNTERS {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
}

[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass;
}
[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
}
public static class JobObj {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetInformationJobObject(IntPtr h, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, uint len, out uint ret);

    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    // ★ 整个建 job + 设 limit 的过程必须在 C# 里做。
    //   教训（实测踩过）：如果从 PowerShell 里写
    //       $ext.BasicLimitInformation.LimitFlags = 0x2000
    //   $ext 是值类型，PowerShell 取嵌套字段拿到的是**副本**，
    //   赋值丢在副本上，传下去的结构 LimitFlags 仍是 0。
    //   而 SetInformationJobObject 对这样的结构**照样返回 True**，
    //   于是"内核兜底"静默失效 —— 必须回读校验才能发现。
    public static IntPtr CreateKillOnCloseJob() {
        IntPtr h = CreateJobObject(IntPtr.Zero, null);
        if (h == IntPtr.Zero) return IntPtr.Zero;

        var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        ext.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        int size = Marshal.SizeOf(ext);
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(ext, p, false);
            if (!SetInformationJobObject(h, JobObjectExtendedLimitInformation, p, (uint)size)) {
                CloseHandle(h);
                return IntPtr.Zero;
            }
        } finally {
            Marshal.FreeHGlobal(p);
        }
        return h;
    }

    // 回读实际生效的 LimitFlags —— 用来断言 limit 真的设进去了
    public static uint GetLimitFlags(IntPtr job) {
        var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        int size = Marshal.SizeOf(ext);
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            uint ret;
            if (!QueryInformationJobObject(job, JobObjectExtendedLimitInformation, p, (uint)size, out ret))
                return 0xDEADBEEF;
            var back = (JOBOBJECT_EXTENDED_LIMIT_INFORMATION)Marshal.PtrToStructure(p, typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            return back.BasicLimitInformation.LimitFlags;
        } finally {
            Marshal.FreeHGlobal(p);
        }
    }
}
'@
}

$sessionMarkerPath = Join-Path $SessionRoot '.session-owner.json'
$sessionMarker = $null
try { $sessionMarker = Get-Content -LiteralPath $sessionMarkerPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "会话所有权标记无效: $sessionMarkerPath" }
if (-not $SessionId) { $SessionId = [string]$sessionMarker.sessionId }
if ([string]$sessionMarker.sessionRoot -ne (ConvertTo-SessionFullPath $SessionRoot) -or
    [string]$sessionMarker.sessionId -ne $SessionId.ToLowerInvariant()) { throw '会话标记与 guardian 参数不匹配' }
if (-not $SessionLock) { $SessionLock = Open-SessionLock -SessionRoot $SessionRoot }
New-SessionRegistration -SessionRoot $SessionRoot -SessionId $SessionId -TempRoot ([string]$sessionMarker.tempRoot) | Out-Null

function Assert-DirectUsbDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Label)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootNormalized = $rootFull.TrimEnd([char[]]@('\','/'))
    $pathNormalized = $pathFull.TrimEnd([char[]]@('\','/'))
    if ([string]::Equals($pathNormalized,$rootNormalized,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label 必须是 U 盘目录内的子目录，不能直接使用盘根目录。"
    }
    $rootPrefix = $rootFull.TrimEnd([char[]]@('\','/')) + '\'
    if (-not $pathFull.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label 必须严格位于 U 盘目录内。"
    }
    if ($pathFull.Substring($rootPrefix.Length).Contains(':')) { throw "$Label 路径不能使用备用数据流语法。" }
    foreach ($candidate in @($rootFull,$pathFull)) {
        $walk = $candidate
        while ($walk) {
            if ([IO.File]::Exists($walk) -or [IO.Directory]::Exists($walk)) {
                $attributes = [IO.File]::GetAttributes($walk)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label 路径包含重解析点。" }
                if ([string]::Equals($walk,$candidate,[StringComparison]::OrdinalIgnoreCase) -and
                    ($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw "$Label 必须是目录。" }
            }
            $parent = [IO.Directory]::GetParent($walk)
            if ($null -eq $parent) { break }
            $walk = $parent.FullName
        }
    }
    if (-not [IO.Directory]::Exists($rootFull)) { throw 'U 盘根目录当前不可访问。' }
    if (-not [IO.Directory]::Exists($pathFull)) { [IO.Directory]::CreateDirectory($pathFull) | Out-Null }
    if (-not [IO.Directory]::Exists($pathFull)) { throw "$Label 目录无法创建。" }
    $walk = $pathFull
    while ($walk) {
        if ([IO.Directory]::Exists($walk)) {
            $attributes = [IO.File]::GetAttributes($walk)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label 路径包含重解析点。" }
        }
        if ([string]::Equals($walk,$rootFull,[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Directory]::GetParent($walk)
        if ($null -eq $parent -or -not $walk.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "$Label 路径越出 U 盘目录。" }
        $walk = $parent.FullName
    }
    return $pathFull
}

if ($StorageMode -eq 'DirectUsb') {
    $StickRoot = [IO.Path]::GetFullPath($StickRoot)
    $stickFull = [IO.Path]::GetFullPath($StickRoot).TrimEnd([char[]]@('\','/'))
    $sessionFull = [IO.Path]::GetFullPath($SessionRoot).TrimEnd([char[]]@('\','/'))
    $stickPrefix = $stickFull + '\'; $sessionPrefix = $sessionFull + '\'
    if ($stickFull.Equals($sessionFull,[StringComparison]::OrdinalIgnoreCase) -or
        $sessionFull.StartsWith($stickPrefix,[StringComparison]::OrdinalIgnoreCase) -or
        $stickFull.StartsWith($sessionPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'DirectUsb 模式要求本机会话目录与 U 盘目录完全分离。'
    }
    $SourceDir = Assert-DirectUsbDirectory -Path $SourceDir -Root $StickRoot -Label '直接保存配置路径'
    $SessionsDir = Assert-DirectUsbDirectory -Path $SessionsDir -Root $StickRoot -Label '兼容会话路径'
    Write-GLog "DirectUsb 模式：声明的 USB 配置目录为 $SourceDir；guardian 只检查路径，不限制应用实际写入范围，也不执行同步或归档验证。" 'INFO'
}

if (-not ('SuspendedLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SuspendedLauncher {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    public static PROCESS_INFORMATION Start(string app, string commandLine, string cwd) {
        STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); PROCESS_INFORMATION pi;
        if (!CreateProcess(app, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, 0x00000004, IntPtr.Zero, cwd, ref si, out pi))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return pi;
    }
}
'@
}

$hJob = [JobObj]::CreateKillOnCloseJob()
if ($hJob -eq [IntPtr]::Zero) {
    throw "建立 Job Object 失败（错误码 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())）"
}

# ★ 必须回读校验。SetInformationJobObject 对 LimitFlags=0 的结构也会返回 True，
#   所以"调用成功"不等于"limit 生效"。不回读就会静默失去内核兜底。
$effective = [JobObj]::GetLimitFlags($hJob)
if ($effective -ne 0x2000) {
    Write-GLog ("Job 的 KILL_ON_JOB_CLOSE 没有真正生效！回读 LimitFlags = 0x{0:X}（期望 0x2000）" -f $effective) 'ERROR'
    [JobObj]::CloseHandle($hJob) | Out-Null
    if ($SessionLock) { $SessionLock.Dispose(); $SessionLock = $null }
    Remove-OwnedSessionDirectory -SessionRoot $SessionRoot `
        -TempRoot ([string]$sessionMarker.tempRoot) -SessionId $SessionId -AllowActiveOwner | Out-Null
    throw 'Job Object 的 KILL_ON_JOB_CLOSE 设置未通过回读校验；已停止启动并清理会话目录'
} else {
    Write-GLog 'Job Object 已建立，回读校验通过（KILL_ON_JOB_CLOSE = 0x2000）' 'OK'
}

# ============================================================
#  拔盘检测：认卷，不认盘符
# ============================================================
$expected = [pscustomobject]@{ DriveLetter = $DriveLetter; VolumeGuid = $VolumeGuid; Serial = $Serial }
$stickGone = $false
$goneReason = ''
$recoveryRequired = $false
$recoveryReason = ''

function Test-StickGone {
    if (-not (Test-Path -LiteralPath "${DriveLetter}:\")) { return '盘符不存在' }
    # 盘符还在，但它可能已经是别的设备了 —— 交叉校验卷标识
    try {
        $now = Get-VolumeIdentity -StickRoot "${DriveLetter}:\"
        if (-not (Test-VolumeIdentityMatch -Expected $expected -Actual $now)) { return '卷身份无法确认（可用标识不匹配或缺失）' }
    } catch { return '卷查询失败' }
    return $null
}

function Mark-SessionRecoveryRequired {
    param([Parameter(Mandatory)][string]$Reason)
    $script:recoveryRequired = $true
    $script:recoveryReason = $Reason
    try {
        Set-SessionRecoveryRequired -SessionRoot $SessionRoot -TempRoot ([string]$sessionMarker.tempRoot) `
            -SessionId $SessionId -Reason $Reason -ArchiveDir $SessionsDir -SourceDir $SourceDir | Out-Null
        Write-GLog "本机会话已标记为待恢复；归档目标: $SessionsDir" 'ERROR'
    } catch {
        Write-GLog "无法写入恢复标记: $($_.Exception.Message)；将把标记文件置为未知状态以阻止自动删除" 'ERROR'
        try {
            [IO.File]::WriteAllText((Join-Path $SessionRoot '.session-owner.json'),
                ('RECOVERY_REQUIRED ' + ($Reason -replace '[\r\n\t]+', ' ')), (New-Object Text.UTF8Encoding($false)))
        } catch { Write-GLog '连未知状态标记也无法写入；本会话仍会保留到当前进程退出' 'ERROR' }
    }
}

function Record-FinalPushFailure {
    param([Parameter(Mandatory)][string]$Reason)
    $missing = Test-StickGone
    if ($missing) {
        $script:stickGone = $true
        $script:goneReason = $missing
        Write-GLog "最终归档失败时 U 盘已不可确认（$missing）；按拔盘清理流程继续" 'WARN'
        return
    }
    Mark-SessionRecoveryRequired -Reason $Reason
}

# ============================================================
#  启动 harness（放进 Job）
# ============================================================
Write-GLog "启动: $HarnessExe"
Write-GLog "工作目录: $WorkingDir"
if ($StorageMode -eq 'DirectUsb') {
    Write-GLog "DirectUsb 兼容会话路径（不由 guardian 归档）: $SessionsDir"
} else {
    Write-GLog "本次运行独立归档目录: $SessionsDir"
}

$proc = $null
$pi = $null
try {
    $cmdline = (Quote-Win32Argument $HarnessExe) + ' ' + (($HarnessArgs | ForEach-Object { Quote-Win32Argument ([string]$_) }) -join ' ')
    $pi = [SuspendedLauncher]::Start($HarnessExe, $cmdline.Trim(), $WorkingDir)
    $proc = Get-Process -Id $pi.dwProcessId -ErrorAction Stop
} catch {
    Write-GLog "启动失败: $($_.Exception.Message)" 'ERROR'
    [JobObj]::CloseHandle($hJob) | Out-Null
    throw
}

 # Child starts suspended so it cannot create descendants before Job assignment.
if (-not [JobObj]::AssignProcessToJobObject($hJob, $pi.hProcess)) {
    $jobError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [SuspendedLauncher]::TerminateProcess($pi.hProcess, 1) | Out-Null
    [SuspendedLauncher]::CloseHandle($pi.hThread) | Out-Null
    [SuspendedLauncher]::CloseHandle($pi.hProcess) | Out-Null
    [JobObj]::CloseHandle($hJob) | Out-Null
    Write-GLog "进程加入 Job 失败，已终止尚未运行的会话进程（错误码 $jobError）" 'ERROR'
    throw "无法将会话进程加入 Job Object（错误码 $jobError）"
}
if ([SuspendedLauncher]::ResumeThread($pi.hThread) -eq [uint32]::MaxValue) {
    $resumeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [JobObj]::TerminateJobObject($hJob, 1) | Out-Null
    [SuspendedLauncher]::CloseHandle($pi.hThread) | Out-Null
    [SuspendedLauncher]::CloseHandle($pi.hProcess) | Out-Null
    [JobObj]::CloseHandle($hJob) | Out-Null
    throw "恢复会话进程失败（错误码 $resumeError）"
}
[SuspendedLauncher]::CloseHandle($pi.hThread) | Out-Null
[SuspendedLauncher]::CloseHandle($pi.hProcess) | Out-Null
Write-GLog "进程已在挂起状态加入 Job 后恢复运行 (PID $($pi.dwProcessId))" 'OK'

# ============================================================
#  主循环：盯盘 + 定时同步
# ============================================================
$syncScript = Join-Path $GuardDir 'sync.ps1'
$nextSync   = (Get-Date).AddSeconds($SyncSeconds)
$identityTick = 0
$startedAt  = Get-Date
$syncPs     = $null       # 后台同步用的 runspace，避免阻塞盯盘
$finalSync  = $false

function Complete-BackgroundSync {
    param([Parameter(Mandatory)]$Item, [string]$Label = '后台同步')
    $ok = $true
    $result = $null
    try { $result = $Item.PowerShell.EndInvoke($Item.AsyncState) }
    catch { $ok = $false; Write-GLog "${Label}执行失败: $($_.Exception.Message)" 'WARN' }
    $streamErrors = @($Item.PowerShell.Streams.Error)
    if ($streamErrors.Count -gt 0) {
        $ok = $false
        $brief = @($streamErrors | Select-Object -First 3 | ForEach-Object { $_.ToString() })
        Write-GLog "${Label}报告了 $($streamErrors.Count) 个错误: $($brief -join ' | ')" 'WARN'
    }
    try { $Item.PowerShell.Dispose() } catch { $ok = $false; Write-GLog "${Label}释放失败: $($_.Exception.Message)" 'WARN' }
    return [pscustomobject]@{ Success = $ok; Result = $result }
}

if ($StorageMode -eq 'DirectUsb') {
    Write-GLog 'DirectUsb 会话开始。guardian 不做同步或归档验证；盯盘间隔 1 秒。'
} else {
    Write-GLog "会话开始。每 $SyncSeconds 秒搬运一次，盯盘间隔 1 秒。"
}
if ($MaxMinutes -gt 0) { Write-GLog "最长运行 $MaxMinutes 分钟后自动结束" 'WARN' }

# ★ 从这里开始静音 —— harness 的 TUI 要接管这个控制台了，
#   运行期再往控制台打日志就会把界面刷花，看起来像一堆报错。
$script:EchoToConsole = $false

while ($true) {
    Start-Sleep -Seconds 1

    # --- 盘还在吗 ---
    $identityTick++
    if ($identityTick -ge 5) {
        $identityTick = 0
        $reason = Test-StickGone
        if ($reason) { $stickGone = $true; $goneReason = $reason; break }
    } else {
        if (-not (Test-Path -LiteralPath "${DriveLetter}:\")) { $stickGone = $true; $goneReason = '盘符不存在'; break }
    }

    # --- harness 退出了吗 ---
    if ($proc.HasExited) { break }

    # --- 超时保护 ---
    if ($MaxMinutes -gt 0 -and ((Get-Date) - $startedAt).TotalMinutes -ge $MaxMinutes) {
        Write-GLog '达到时长上限，结束会话' 'WARN'
        break
    }

    # --- 定时搬运（后台跑，不阻塞盯盘） ---
    if ($StorageMode -eq 'Archive' -and ((Get-Date) -ge $nextSync)) {
        $nextSync = (Get-Date).AddSeconds($SyncSeconds)
        if ($syncPs) {
            if ($syncPs.AsyncState.IsCompleted) {
                $completedSync = Complete-BackgroundSync -Item $syncPs -Label '上轮同步'
                $syncResult = $completedSync.Result
                # 每轮记一条痕迹（只进日志文件，不碰控制台）——
                # 否则 -Quiet 下同步无声，"跑了没/跑成什么样"完全无从判断
                if ($syncResult) {
                    $sr = @($syncResult)[-1]
                    Write-GLog ("同步: 新增 {0} / 追加 {1} / 跳过 {2}，{3:N0} KB" -f `
                        $sr.copied, $sr.appended, $sr.skipped, ($sr.bytes / 1KB))
                }
                $syncPs = $null
            } else {
                # 同步没跑完就跳过是**正常行为**，不是错误。
                # 早先这里写成 WARN，同步一旦超过间隔就每轮刷一条，
                # 加上守护和 TUI 共用控制台，看起来就是"满屏同步错误"。
                Write-GLog '上轮同步还没跑完，跳过这一轮（正常）' 'INFO'
            }
        }
        if (-not $syncPs) {
            try {
                $ps = [powershell]::Create()
                [void]$ps.AddCommand($syncScript)
                [void]$ps.AddParameter('SourceDir', $SourceDir)
                [void]$ps.AddParameter('SessionsDir', $SessionsDir)
                [void]$ps.AddParameter('Direction', 'Push')
                [void]$ps.AddParameter('Quiet')
                $syncPs = [pscustomobject]@{ PowerShell = $ps; AsyncState = $ps.BeginInvoke() }
            } catch {
                Write-GLog "启动同步失败: $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# ============================================================
#  收尾
# ============================================================
$script:EchoToConsole = $true      # harness 已退出，控制台交还给我们
Write-Host ''
if ($stickGone) {
    Write-GLog "检测到 U 盘已移除（$goneReason）—— 开始销毁" 'WARN'
    if ($StorageMode -eq 'DirectUsb') { Write-GLog 'DirectUsb 声明的配置路径位于 U 盘；guardian 不限制应用实际写入范围，也不验证归档或数据库提交，未提交的写入可能丢失' 'WARN' }
} else {
    Write-GLog '会话正常结束 —— 开始销毁' 'OK'
    if ($StorageMode -eq 'DirectUsb') { Write-GLog 'DirectUsb 声明的配置路径位于 U 盘；guardian 不限制应用实际写入范围，也不执行数据库 flush、同步或归档验证，未提交的写入可能丢失' 'WARN' }
}

# 先确认后台 Push 已经停稳，才能启动最后一次 Push。
if ($StorageMode -eq 'Archive' -and $syncPs) {
    $syncCompleted = $syncPs.AsyncState.IsCompleted
    if (-not $syncCompleted) {
        Write-GLog "等待后台同步完成，最多 $SyncDrainTimeoutSeconds 秒" 'INFO'
        $syncCompleted = $syncPs.AsyncState.AsyncWaitHandle.WaitOne($SyncDrainTimeoutSeconds * 1000)
    }
    if (-not $syncCompleted) {
        Write-GLog '后台同步超时，发送有界停止请求' 'WARN'
        $stopAsync = $null
        $stopWatch = [Diagnostics.Stopwatch]::StartNew()
        try { $stopAsync = $syncPs.PowerShell.BeginStop($null, $null) }
        catch { Write-GLog "无法停止后台同步: $($_.Exception.Message)" 'ERROR' }
        $stopped = $false
        if ($stopAsync) {
            try {
                if ($stopAsync.AsyncWaitHandle.WaitOne($SyncStopTimeoutSeconds * 1000)) {
                    $syncPs.PowerShell.EndStop($stopAsync)
                    $stopped = $syncPs.AsyncState.IsCompleted
                    if (-not $stopped) {
                        $remainingMs = [Math]::Max(0, ($SyncStopTimeoutSeconds * 1000) - [int]$stopWatch.ElapsedMilliseconds)
                        if ($remainingMs -gt 0) { $stopped = $syncPs.AsyncState.AsyncWaitHandle.WaitOne($remainingMs) }
                    }
                }
            } catch { Write-GLog "停止后台同步出错: $($_.Exception.Message)" 'WARN' }
        }
        if (-not $stopped) { $stopped = $syncPs.AsyncState.IsCompleted }
        if (-not $stopped) {
            Write-GLog '无法确认后台同步已停止；跳过最终 Push 并保留会话目录，避免并发写入或删除源文件' 'ERROR'
            Mark-SessionRecoveryRequired -Reason '后台 Push 无法在时限内确认停止；请在归档目标可用时重试'
            try { Set-Variable -Name preserveSession -Scope 1 -Value $true -ErrorAction Stop } catch { }
            [JobObj]::TerminateJobObject($hJob, 1) | Out-Null
            [JobObj]::CloseHandle($hJob) | Out-Null
            if ($SessionLock) { $SessionLock.Dispose(); $SessionLock = $null }
            Write-GLog '守护将立即退出，让系统关闭未能确认停止的后台同步；本次归档状态为失败' 'ERROR'
            exit 2
        }
        Write-GLog '后台同步已停止；继续收集其错误并按顺序执行收尾' 'WARN'
    }
    $drained = Complete-BackgroundSync -Item $syncPs -Label '收尾后台同步'
    if (-not $drained.Success) { Write-GLog '后台同步收尾报告失败；最终 Push 仍会在它完全结束后单独执行' 'WARN' }
    $syncPs = $null
}

# --- 最后一次搬运（只有盘还在才有意义）---
if ($StorageMode -eq 'Archive' -and -not $stickGone) {
    Write-GLog '做最后一次搬运...'
    try {
        $finalResult = @(& $syncScript -SourceDir $SourceDir -SessionsDir $SessionsDir -Direction Push)
        $finalStats = if ($finalResult.Count -gt 0) { $finalResult[-1] } else { $null }
        $hasFinalStats = $false
        if ($null -ne $finalStats) {
            $hasFinalStats = ($null -ne $finalStats.PSObject.Properties['copied']) -and
                ($null -ne $finalStats.PSObject.Properties['appended']) -and
                ($null -ne $finalStats.PSObject.Properties['skipped'])
        }
        if (-not $hasFinalStats) {
            Write-GLog '最后一次搬运没有返回有效统计；不能确认归档完成' 'WARN'
            Record-FinalPushFailure -Reason '最终 Push 未返回有效统计对象'
        } elseif ($finalStats.PSObject.Properties['failed'] -and [int]$finalStats.failed -gt 0) {
            Write-GLog "最后一次搬运有失败: $($finalStats.failed)" 'WARN'
            Record-FinalPushFailure -Reason "最终 Push 报告 $($finalStats.failed) 个失败"
        } else {
            $finalSync = $true
        }
    } catch {
        Write-GLog "最后一次搬运失败: $($_.Exception.Message)" 'WARN'
        Record-FinalPushFailure -Reason ("最终 Push 异常: " + $_.Exception.Message)
    }
}

# --- 杀 Job 内整树（只杀我们自己 Job 里的，绝不动宿主进程）---
# 不判断 $proc.HasExited，也不按映像名杀 —— 直接终止 Job，
# 无论 harness 是否还在跑，效果都是"本会话的树一个不留"
[JobObj]::TerminateJobObject($hJob, 0) | Out-Null
Write-GLog '已终止本会话的进程树（未触碰宿主任何进程）' 'OK'
[JobObj]::CloseHandle($hJob) | Out-Null

# 给文件句柄一点释放时间，否则会话目录可能删不掉
Start-Sleep -Milliseconds 800

# --- 把守护日志留一份到 U 盘（否则会话目录一删，线索就没了）---
# 运行期为了不刷花 TUI，所有日志都只写在这里 —— 删掉就等于自毁证据，
# 出问题时无从排查。所以趁盘还在，先抄一份走。
if (-not $stickGone) {
    try {
        $dst = Join-Path $StickRoot 'logs'
        if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $keep = Join-Path $dst ("guardian-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
        if (Test-Path -LiteralPath $localLog) {
            Copy-Item -LiteralPath $localLog -Destination $keep -Force
            Write-GLog "守护日志已留一份到 U 盘: $keep"
        }
    } catch {
        Write-GLog "守护日志留存失败（不影响清理）: $($_.Exception.Message)" 'WARN'
    }
}

# --- 擦除本机会话目录（只删我们自己建的）---
$ok = $false
if ($recoveryRequired) {
    try { Set-Variable -Name preserveSession -Scope 1 -Value $true -ErrorAction Stop } catch { }
    if ($SessionLock) { $SessionLock.Dispose(); $SessionLock = $null }
    Write-GLog "保留待恢复会话目录: $SessionRoot" 'ERROR'
    Write-GLog "归档目标: $SessionsDir" 'ERROR'
} else {
    try {
        if ($SessionLock) { $SessionLock.Dispose(); $SessionLock = $null }
        $ok = Remove-OwnedSessionDirectory -SessionRoot $SessionRoot `
            -TempRoot ([string]$sessionMarker.tempRoot) -SessionId $SessionId -AllowActiveOwner
    } catch { Write-GLog "安全清理拒绝或失败: $($_.Exception.Message)" 'WARN' }
    if ($ok) { Write-GLog "已清除会话目录: $SessionRoot" 'OK' }
    else     { Write-GLog "会话目录未能完全清除: $SessionRoot（下次启动会自动扫孤儿目录清理）" 'WARN' }
}

Write-Host ''
Write-Host '----------------------------------------'
Write-Host ' 会话已结束' -ForegroundColor Cyan
if ($recoveryRequired) {
    Write-Host ' 原因: 最终归档失败，已保留本机会话以便重试' -ForegroundColor Yellow
} elseif ($stickGone) {
    Write-Host " 原因: U 盘被拔出（$goneReason）" -ForegroundColor Yellow
} else {
    Write-Host ' 原因: 正常退出'
}
Write-Host " 已终止本会话进程树，未触碰宿主其他进程"
if ($recoveryRequired) {
    Write-Host " 已保留待恢复目录: $SessionRoot" -ForegroundColor Yellow
    Write-Host " 归档目标: $SessionsDir" -ForegroundColor Yellow
    $manualSync = Join-Path $StickRoot 'scripts\sync.ps1'
    Write-Host ' 手动重试命令：' -ForegroundColor Yellow
    Write-Host (' powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -SourceDir "{1}" -SessionsDir "{2}" -Direction Push' -f $manualSync, $SourceDir, $SessionsDir) -ForegroundColor DarkGray
} else {
    Write-Host " 已清除本机临时目录: $(if($ok){'是'}else{'部分失败'})"
}
if ($StorageMode -eq 'DirectUsb') {
    Write-Host " DirectUsb：应用配置直接写入 U 盘（声明路径: $SourceDir；guardian 只检查该路径，不限制应用实际写入范围，也未验证归档或数据库提交）" -ForegroundColor Yellow
    Write-Host ' 最后一次搬运会话: 不适用（DirectUsb）'
} else {
    Write-Host " 最后一次搬运会话: $(if($finalSync){'完成'}elseif($stickGone){'跳过（盘已拔）'}else{'失败'})"
}
Write-Host '----------------------------------------'
Write-Host ''
# 双击启动时窗口会随脚本结束而关闭，停一下让人看清清理结果。
# ★ 但只在**真的有人在看**的时候停 —— stdin 被重定向（脚本化调用、管道）时
#   Read-Host 会一直等输入，把整个流程卡死（实测踩过：自动化测试就卡在这）。
$canPause = $true
try { $canPause = -not [Console]::IsInputRedirected } catch { $canPause = $false }
if ($canPause) {
    try { Read-Host '按回车关闭' | Out-Null } catch { }
}

# 日志：会话目录已删，把 guardian 自己的日志也清掉（只清我们的）
if (-not $recoveryRequired) {
    try { Remove-Item -LiteralPath $localLog -Force -EA SilentlyContinue } catch { }
    try { Remove-ItemForce -Path $GuardDir | Out-Null } catch { }
}
if ($recoveryRequired) { exit 2 }
exit 0

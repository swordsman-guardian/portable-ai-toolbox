# ============================================================
#  test-guardian.ps1 —— 守护 / 销毁 机制测试
#
#  验证三件事（对应计划里的验证项 10-12）：
#    A. 正常退出  → 进程树死、会话目录被清
#    B. 盘消失    → 同样销毁（用伪造的卷标识模拟拔盘，不真的拔）
#    C. 守护被强杀 → 内核 Job 兜底，子进程也跟着死
#
#  ★ 测试绝不能碰宿主的任何进程。为此用盘上便携 node 开一个
#    "睡很久"的子进程当靶子，并记录它的 PID 精确核对。
#
#  用法： powershell -File test-guardian.ps1
# ============================================================

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'session-manager.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot
$NodeExe   = Join-Path $StickRoot 'runtime\node\node.exe'
if (-not (Test-Path -LiteralPath $NodeExe)) { throw "找不到盘上的 node: $NodeExe" }

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ("  [√] $Name") -ForegroundColor Green }
    else     { $script:Fail++; Write-Host ("  [×] $Name  $Detail") -ForegroundColor Red }
}
function Test-PidAlive { param([int]$ProcId)
    return ($null -ne (Get-Process -Id $ProcId -EA SilentlyContinue))
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  守护 / 销毁 测试' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 公共：搭一个沙盒会话 ----------
function New-Sandbox {
    $sessionId = [Guid]::NewGuid().ToString()
    $sb = Join-Path $env:TEMP ("aistick-" + $sessionId)
    $work  = Join-Path $sb 'work'
    $guard = Join-Path $sb 'guard'
    $sess  = Join-Path $sb 'sessions'
    New-Item -ItemType Directory -Path $work, $guard, $sess -Force | Out-Null
    foreach ($f in @('lib.ps1', 'guardian.ps1', 'sync.ps1', 'session-manager.ps1', 'python-env.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { continue }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $guard $f) -Force
    }
    # 造点会话内容，好验证"被清了"
    $cfg = Join-Path $work 'config\claude'
    New-Item -ItemType Directory -Path $cfg -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cfg '.claude.json'), '{"test":1}', (New-Object Text.UTF8Encoding($false)))
    New-SessionRegistration -SessionRoot $sb -SessionId $sessionId -TempRoot $env:TEMP | Out-Null
    return [pscustomobject]@{ Root = $sb; Work = $work; Guard = $guard; Sessions = $sess }
}

$vol = Get-VolumeIdentity -StickRoot $StickRoot

# 把 sleep 逻辑写成脚本文件，这样 harness 参数只是一个简单路径 ——
# 避免在多层 Start-Process 之间传递带引号/特殊字符的参数（实测会串味）
function New-SleepScript {
    param([Parameter(Mandatory)]$Sb, [Parameter(Mandatory)][int]$Ms)
    $p = Join-Path $Sb.Work 'sleep.js'
    [IO.File]::WriteAllText($p, "setTimeout(()=>{}, $Ms);", (New-Object Text.UTF8Encoding($false)))
    return $p
}

function Invoke-Guardian {
    param(
        [Parameter(Mandatory)]$Sb,
        [Parameter(Mandatory)][string]$HarnessScript,
        [string]$VolGuid = '',           # 留空 = 用真实卷标识
        [switch]$AsSeparateProcess
    )
    $g = Join-Path $Sb.Guard 'guardian.ps1'
    $a = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $g,
        '-StickRoot', $Sb.Root,
        '-SessionRoot', $Sb.Root,                    # 故意传沙盒根，让清理删整个沙盒
        '-GuardDir', $Sb.Guard,
        '-DriveLetter', $vol.DriveLetter,
        '-VolumeGuid', $(if ($VolGuid) { $VolGuid } else { $vol.VolumeGuid }),
        '-Serial', $vol.Serial,
        '-HarnessExe', $NodeExe,
        '-WorkingDir', $Sb.Work,
        '-SessionsDir', $Sb.Sessions,
        '-SourceDir', (Join-Path $Sb.Work 'config\claude'),
        '-SyncSeconds', '30',
        '-HarnessArgs', $HarnessScript
    )

    if ($AsSeparateProcess) {
        $txt = $a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        return Start-Process -FilePath 'powershell' -ArgumentList $txt -PassThru -WindowStyle Hidden
    } else {
        & powershell @a
        return $null
    }
}

# ============================================================
Write-Host '【A】正常退出 → 进程树死、会话目录被清' -ForegroundColor Yellow
$sbA = New-Sandbox
# node 跑 2 秒就自己退出，模拟"用户正常退出 harness"
$jsA = New-SleepScript -Sb $sbA -Ms 2000
Invoke-Guardian -Sb $sbA -HarnessScript $jsA | Out-Null
Start-Sleep -Milliseconds 500
Check '会话目录被清除' (-not (Test-Path $sbA.Root)) ("仍存在: $($sbA.Root)")
Check '沙盒内容（含 config）一并清掉' (-not (Test-Path $sbA.Work))
Write-Host ("    沙盒: $($sbA.Root)  -> " + $(if (Test-Path $sbA.Root) { '仍存在' } else { '已删除' })) -ForegroundColor DarkGray

# ============================================================
Write-Host ''
Write-Host '【B】盘消失（伪造卷标识）→ 同样销毁' -ForegroundColor Yellow
$sbB = New-Sandbox
# node 睡 120 秒，按理不会自己退出；靠 guardian 检测"盘没了"来终止它
$sw = [Diagnostics.Stopwatch]::StartNew()
$jsB = New-SleepScript -Sb $sbB -Ms 120000
Invoke-Guardian -Sb $sbB -HarnessScript $jsB -VolGuid 'BOGUS-VOLUME-GUID-0000' | Out-Null
$sw.Stop()
Start-Sleep -Milliseconds 500
Check '检测到卷标识不符后主动结束（未等满 120 秒）' ($sw.Elapsed.TotalSeconds -lt 30) ("耗时 $([int]$sw.Elapsed.TotalSeconds) 秒")
Check '会话目录被清除' (-not (Test-Path $sbB.Root))
Write-Host ("    耗时 $([int]$sw.Elapsed.TotalSeconds) 秒") -ForegroundColor DarkGray

# ============================================================
Write-Host ''
Write-Host '【C】守护被强杀 → 内核 Job 兜底，子进程跟着死' -ForegroundColor Yellow
$sbC = New-Sandbox
# node 睡很久；guardian 作为独立进程启动，便于我们精确地杀它
$jsC = New-SleepScript -Sb $sbC -Ms 120000
$gp = Invoke-Guardian -Sb $sbC -HarnessScript $jsC -AsSeparateProcess

# 等 node 子进程出现，并记下它的 PID（一会儿要核对它是否还活着）
$nodePid = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $p = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -EA SilentlyContinue |
         Where-Object { $_.ParentProcessId -eq $gp.Id -and $_.CommandLine -and $_.CommandLine.Contains($jsC) } | Select-Object -First 1
    if ($p) { $nodePid = [int]$p.ProcessId; break }
}
Check '已找到靶子子进程 (node)' ($null -ne $nodePid) '没找到 node 子进程，无法继续 C'

if ($nodePid) {
    Write-Host ("    靶子 PID: $nodePid   守护 PID: $($gp.Id)") -ForegroundColor DarkGray
    Check '靶子确实活着（前置条件）' (Test-PidAlive $nodePid)

    # ★ 只杀守护这一个 PID —— 绝不按映像名杀
    Stop-Process -Id $gp.Id -Force -EA SilentlyContinue
    Write-Host '    已强杀守护进程（只按 PID 杀）' -ForegroundColor DarkGray

    $gone = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-PidAlive $nodePid)) { $gone = $true; break }
    }
    Check '内核 Job 兜底生效：守护死后子进程也被杀' $gone '子进程仍然活着 —— KILL_ON_JOB_CLOSE 没生效'
    if (-not $gone) { Stop-Process -Id $nodePid -Force -EA SilentlyContinue }
}

# ---------- 收尾：只清我们自己的沙盒 ----------
foreach ($sb in @($sbA, $sbB, $sbC)) {
    if (Test-Path -LiteralPath $sb.Root) {
        $resolved = (Resolve-Path -LiteralPath $sb.Root).Path
        $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $resolved -Leaf) -notmatch '^aistick-[a-f0-9-]{36}$') { throw '拒绝清理测试范围外的目录' }
        Remove-ItemForce -Path $resolved | Out-Null
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ("  通过 $script:Pass 项，失败 $script:Fail 项") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '注意：本测试用伪造卷标识模拟拔盘，没有真的拔盘。' -ForegroundColor DarkGray
Write-Host '      真拔盘（卷真的消失、句柄失效）仍需手工测一次。' -ForegroundColor DarkGray
Write-Host ''
if ($script:Fail -gt 0) { exit 1 }
exit 0

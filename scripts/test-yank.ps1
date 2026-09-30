# ============================================================
#  test-yank.ps1 —— 真拔盘测试的对照工具
#
#  真拔盘时卷会消失、文件句柄失效，和"伪造卷标识"的自动测试不一样，
#  必须实测一次。这个脚本帮你把前后的状态记下来对比，不靠肉眼看。
#
#  用法：
#    1) 会话跑起来后，在【另一个】窗口运行：
#         powershell -ExecutionPolicy Bypass -File test-yank.ps1
#       它会记下基线，并把自己拷到本机（因为拔盘后 U 盘就没了）
#    2) 直接拔 U 盘
#    3) 按它提示的路径，运行本机那份拷贝：
#         powershell -ExecutionPolicy Bypass -File %TEMP%\aistick-yank\test-yank.ps1
#       它会对比并给出结论
#
#  ★ 本脚本刻意不依赖 lib.ps1 —— 拔盘后 U 盘上的东西都读不到了，
#    对比阶段必须能独立运行。
# ============================================================

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Before', 'After')][string]$Mode = 'Auto'
)

$ErrorActionPreference = 'Continue'

# ★ 目录名不能用 aistick- 前缀！
#   launch.ps1 扫孤儿会话目录时按 aistick-* 删，会把本工具的目录当垃圾清掉
#   （实测踩过：第一次跑就被自己的孤儿清扫逻辑盯上了）
$HostTempDir = Join-Path $env:TEMP 'yankcheck'
$SnapFile    = Join-Path $HostTempDir 'before.json'

function Get-ClaudeProcs {
    Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Pid  = $_.ProcessId
                Path = $_.ExecutablePath
                # 属于我们会话的：可执行体在 aistick-* 临时目录下
                Ours = ($_.ExecutablePath -like '*aistick-*')
            }
        }
}

function Get-Sessions {
    # 真会话目录里一定有 work\ 和 guard\ 两个子目录（launch.ps1 建的），
    # 用这个特征过滤，别只按名字前缀 —— 免得把别的 aistick-* 误认成会话
    Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'aistick-*' -Force -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'work')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'guard'))
        } |
        ForEach-Object {
            $n = (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object).Count
            [pscustomobject]@{ Path = $_.FullName; Files = $n }
        }
}

function Take-Snap {
    $procs = @(Get-ClaudeProcs)
    $sess  = @(Get-Sessions)
    $keeper = @(Get-CimInstance Win32_Process -Filter "Name='codex-windows-sandbox-service.exe'" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty ProcessId)

    return [pscustomobject]@{
        TakenAt          = (Get-Date).ToString('HH:mm:ss')
        OurClaudePids    = @($procs | Where-Object { $_.Ours }  | Select-Object -ExpandProperty Pid)
        OtherClaudePids  = @($procs | Where-Object { -not $_.Ours } | Select-Object -ExpandProperty Pid)
        SessionDirs      = @($sess | Select-Object -ExpandProperty Path)
        SessionFiles     = ($sess | Measure-Object -Property Files -Sum).Sum
        KeeperPids       = $keeper
    }
}

# ------------------------------------------------------------
if ($Mode -eq 'Auto') {
    # 有基线就做对比，没有就记基线
    if (Test-Path -LiteralPath $SnapFile) { $Mode = 'After' } else { $Mode = 'Before' }
}

# ============================================================
if ($Mode -eq 'Before') {
    Write-Host ''
    Write-Host '=== 拔盘测试 · 记录基线 ===' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $HostTempDir)) { New-Item -ItemType Directory -Path $HostTempDir -Force | Out-Null }

    $snap = Take-Snap
    if ($snap.SessionDirs.Count -eq 0) {
        Write-Host ''
        Write-Host '  ！没有发现 aistick-* 会话目录。' -ForegroundColor Yellow
        Write-Host '    拔盘销毁只在"会话正在跑"时触发。' -ForegroundColor Yellow
        Write-Host '    请先双击 AI.cmd 把 Claude Code 起起来，再运行本脚本。' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    if ($snap.OurClaudePids.Count -eq 0) {
        Write-Host '  ！没找到属于本会话的 claude.exe（可执行体应在 aistick-* 下）' -ForegroundColor Yellow
        Write-Host '    确认 Claude Code 已经起来了再试。' -ForegroundColor Yellow
    }

    $snap | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SnapFile -Encoding UTF8

    Write-Host ("  本会话 claude.exe PID : " + ($snap.OurClaudePids -join ', '))
    Write-Host ("  宿主其他 claude.exe PID: " + ($snap.OtherClaudePids -join ', ') + "   <- 这些必须活着")
    Write-Host ("  会话目录              : " + ($snap.SessionDirs -join ', '))
    Write-Host ("  会话目录里的文件数    : " + $snap.SessionFiles)
    Write-Host ("  其他后台服务 PID      : " + ($snap.KeeperPids -join ', '))

    # 把自己拷到本机 —— 拔盘后 U 盘就读不到了
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $HostTempDir 'test-yank.ps1') -Force

    Write-Host ''
    Write-Host '  基线已记录。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  现在直接拔掉 U 盘（不要安全弹出，就要最粗暴的那种）。' -ForegroundColor Yellow
    Write-Host '  然后运行本机那份拷贝来对比：' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    powershell -ExecutionPolicy Bypass -File `"$HostTempDir\test-yank.ps1`"" -ForegroundColor White
    Write-Host ''
    exit 0
}

# ============================================================
if ($Mode -eq 'After') {
    Write-Host ''
    Write-Host '=== 拔盘测试 · 对比结果 ===' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $SnapFile)) {
        Write-Host '  找不到基线文件，请先运行一次记录基线。' -ForegroundColor Red
        exit 1
    }
    $before = Get-Content -LiteralPath $SnapFile -Raw -Encoding UTF8 | ConvertFrom-Json

    # 守护进程在被拔盘后会自己清理并退出，给它几秒
    Write-Host '  等待 8 秒，让守护完成清理...'
    for ($i = 8; $i -gt 0; $i--) { Write-Host ("`r  倒计时 $i " ) -NoNewline; Start-Sleep -Seconds 1 }
    Write-Host ''

    $now = Take-Snap
    $pass = 0; $fail = 0
    function Verdict {
        param([string]$Name, [bool]$Ok, [string]$Detail = '')
        if ($Ok) { Write-Host ("  [√] $Name") -ForegroundColor Green; $script:pass++ }
        else     { Write-Host ("  [×] $Name  $Detail") -ForegroundColor Red; $script:fail++ }
    }

    Write-Host ''
    Write-Host '  [基线]' -ForegroundColor DarkGray
    Write-Host ("    本会话 claude PID : " + ($before.OurClaudePids -join ', ')) -ForegroundColor DarkGray
    Write-Host ("    宿主 claude PID   : " + ($before.OtherClaudePids -join ', ')) -ForegroundColor DarkGray
    Write-Host ("    会话目录          : " + ($before.SessionDirs -join ', ')) -ForegroundColor DarkGray
    Write-Host ("    文件数            : " + $before.SessionFiles) -ForegroundColor DarkGray
    Write-Host ''

    # 1) 我们自己的 claude 必须全死
    $aliveOurs = @($now.OurClaudePids | Where-Object { $before.OurClaudePids -contains $_ })
    Verdict '本会话的 claude.exe 全部终止' ($aliveOurs.Count -eq 0) ("仍存活: " + ($aliveOurs -join ', '))

    # 2) 宿主原有的 claude 必须全活 —— 这条是安全底线
    $deadOthers = @($before.OtherClaudePids | Where-Object { $now.OtherClaudePids -notcontains $_ })
    Verdict '宿主的 claude.exe 全部存活（进程隔离）' ($deadOthers.Count -eq 0) ("被误杀: " + ($deadOthers -join ', '))

    # 3) 其他后台服务必须全活
    $deadKeepers = @($before.KeeperPids | Where-Object { $now.KeeperPids -notcontains $_ })
    Verdict '宿主其他后台服务存活' ($deadKeepers.Count -eq 0) ("被误杀: " + ($deadKeepers -join ', '))

    # 4) 会话目录必须被清掉
    $left = @($now.SessionDirs)
    Verdict '会话目录已被清除' ($left.Count -eq 0) ("残留: " + ($left -join ', '))

    Write-Host ''
    if ($fail -eq 0) {
        Write-Host '  ────────────────────────────────' -ForegroundColor Green
        Write-Host '  真拔盘测试通过：本会话干净自毁，宿主毫发无伤' -ForegroundColor Green
        Write-Host '  ────────────────────────────────' -ForegroundColor Green
    } else {
        Write-Host '  ────────────────────────────────' -ForegroundColor Red
        Write-Host ("  有 $fail 项没过，看上面标红的部分") -ForegroundColor Red
        Write-Host '  ────────────────────────────────' -ForegroundColor Red
        Write-Host ''
        Write-Host '  排查提示：' -ForegroundColor Yellow
        Write-Host '    · 会话目录残留 → 看残留目录里的 guard\guardian.log'
        Write-Host '    · 本会话 claude 没死 → 内核 Job 兜底没生效，看实现笔记"陷阱 4"'
        Write-Host '    · 宿主 claude 被误杀 → 严重缺陷，检查有没有按映像名杀进程的写法'
    }
    Write-Host ''

    # 清掉这次的对照文件（只清我们自己的）
    Remove-Item -LiteralPath $SnapFile -Force -ErrorAction SilentlyContinue
    exit $(if ($fail -eq 0) { 0 } else { 1 })
}
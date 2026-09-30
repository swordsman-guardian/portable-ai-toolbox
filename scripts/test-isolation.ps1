# ============================================================
#  test-isolation.ps1 —— 隔离验证
#
#  验证两件事（这两条是"不污染宿主"的核心承诺）：
#    1) 读隔离：宿主已有的 claude/codex 配置在会话期间一字未变
#    2) 写隔离：会话产生的东西落在会话目录，不落宿主家目录
#
#  用法：
#    powershell -File test-isolation.ps1                  # 用最新的会话目录
#    powershell -File test-isolation.ps1 -ArgList '--help'  # 跑指定命令
# ============================================================

[CmdletBinding()]
param(
    [string]$SessionWorkDir = '',
    [string[]]$ArgList = @('mcp', 'list')   # 这个命令会真正写配置，用来验证写隔离
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot

# 找会话目录（launch 建的 aistick-*）
if (-not $SessionWorkDir) {
    $latest = Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'aistick-*' -Force -EA SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw '找不到 aistick-* 会话目录，请先跑一次 launch.ps1 -NoLaunch' }
    $SessionWorkDir = Join-Path $latest.FullName 'work'
}
if (-not (Test-Path -LiteralPath $SessionWorkDir)) { throw "会话目录不存在: $SessionWorkDir" }

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  隔离验证' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "会话目录: $SessionWorkDir"
Write-Host ''

# ---------- 要盯住的宿主路径 ----------
# ★ 必须在隔离之前就把绝对路径算好。隔离之后 $env:USERPROFILE 会变成会话目录，
#   那时候再拼 "$env:USERPROFILE\.claude" 就指到会话里的假家目录去了（实测踩过）。
$HostHome = $env:USERPROFILE
$HostWatch = @(
    "$HostHome\.claude.json",
    "$HostHome\.claude\settings.json",
    "$HostHome\.claude\settings.local.json",
    "$HostHome\.claude\history.jsonl",
    "$HostHome\.claude\config.json",
    "$HostHome\.codex\config.toml",
    "$HostHome\.gitconfig"
)
$HostWatchDirs = @("$HostHome\.claude", "$HostHome\.codex")

function Get-Snap {
    $snap = @{}
    foreach ($f in $HostWatch) {
        if (Test-Path -LiteralPath $f) {
            $i = Get-Item -LiteralPath $f -Force
            $snap[$f] = "$($i.Length)|$($i.LastWriteTimeUtc.ToString('o'))"
        } else { $snap[$f] = 'ABSENT' }
    }
    foreach ($d in $HostWatchDirs) {
        if (Test-Path -LiteralPath $d) {
            $i = Get-Item -LiteralPath $d -Force
            $snap["DIR:$d"] = $i.LastWriteTimeUtc.ToString('o')
        } else { $snap["DIR:$d"] = 'ABSENT' }
    }
    return $snap
}

Write-Host '[1] 记录宿主基线...' -ForegroundColor Yellow
$before = Get-Snap
foreach ($k in $before.Keys) { Write-Host ("    " + $k + "  " + ($before[$k] -replace '\|', '  ')) }

# ---------- 构造隔离环境并跑命令 ----------
Write-Host ''
Write-Host '[2] 构造隔离环境...' -ForegroundColor Yellow
$iso = New-IsolatedEnvironment -StickRoot $StickRoot -WorkPath $SessionWorkDir -RealHostUser $env:USERNAME

Write-Host ("    屏蔽了 $($iso.BlockedVars.Count) 个宿主变量: " + ($iso.BlockedVars -join ', '))
Write-Host "    CLAUDE_CONFIG_DIR -> $($iso.ConfigDir)"
Write-Host "    HOME             -> $($iso.HomeDir)"

Write-Host ''
Write-Host '[3] 隔离后的环境自证' -ForegroundColor Yellow

# 两类变量的要求是相反的，不能混在一起判：
#   A. 会话隔离类 —— 必须落在会话目录里（否则数据会写进宿主）
#   B. 宿主保持类 —— 必须保持宿主原值（重定向它们会打死宿主的 hooks / 项目配置）
$mustBeSessionScoped = @('CLAUDE_CONFIG_DIR', 'ANTHROPIC_CONFIG_DIR', 'TMP', 'TEMP', 'GIT_CONFIG_GLOBAL')
$mustStayHost      = @('HOME', 'USERPROFILE')

Write-Host '  A. 应当指向会话目录的：' -ForegroundColor DarkGray
foreach ($v in $mustBeSessionScoped) {
    $val = (Get-Item "Env:$v" -EA SilentlyContinue).Value
    # 会话目录形如 ...\Temp\aistick-xxxx\work\...
    $ok = $val -and ($val -like '*aistick-*')
    $color = if ($ok) { 'Gray' } else { 'Red' }
    $mark  = if ($ok) { '' } else { '  <-- 没指到会话目录，会写到宿主上！' }
    Write-Host ("    {0,-26} = {1}{2}" -f $v, $val, $mark) -ForegroundColor $color
}

Write-Host '  B. 应当保持宿主原值的（重定向会打死宿主 hooks）：' -ForegroundColor DarkGray
foreach ($v in $mustStayHost) {
    $val = (Get-Item "Env:$v" -EA SilentlyContinue).Value
    $ok = ($val -eq $HostHome)          # $HostHome 在隔离前就抓下来了
    $color = if ($ok) { 'Gray' } else { 'Red' }
    $mark  = if ($ok) { '' } else { "  <-- 被改动了！应为 $HostHome" }
    Write-Host ("    {0,-26} = {1}{2}" -f $v, $val, $mark) -ForegroundColor $color
}
# PATH 里不该出现宿主装的 node/git/npm
# 注意排除盘根自己 —— 我们盘上也有 runtime\git\cmd，别把它误判成宿主目录
$hostPathHits = @()
foreach ($seg in ($env:PATH -split ';')) {
    if (-not $seg) { continue }
    if ($seg.StartsWith($StickRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($seg -match 'AppData\\Roaming\\npm|Program Files\\nodejs|Program Files\\Git|anaconda|cargo|Scoop|chocolatey') {
        $hostPathHits += $seg
    }
}
if ($hostPathHits.Count) {
    Write-Host ("    PATH 里混入了宿主目录: " + ($hostPathHits -join ' | ')) -ForegroundColor Red
} else {
    Write-Host '    PATH 干净：没有混入宿主装的 node/git/npm/anaconda' -ForegroundColor Green
}

Write-Host ''
Write-Host "[4] 在隔离环境里跑 harness: $($ArgList -join ' ')" -ForegroundColor Yellow
$h = @((Read-JsonFile -Path (Join-Path $StickRoot 'harness\registry.json')).harnesses | Where-Object { $_.enabled })[0]
$exe = Resolve-HarnessExe -Harness $h -BaseDir $SessionWorkDir

if (-not $exe) {
    Write-Host '    找不到可执行体，跳过运行' -ForegroundColor Red
} else {
    Write-Host "    $exe"
    try {
        $out = & $exe @ArgList 2>&1 | Select-Object -First 5
        foreach ($l in $out) { Write-Host ("    > " + $l) }
    } catch {
        Write-Host ("    运行报错: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ---------- 会话目录里应运而生 ----------
Write-Host ''
Write-Host '[5] 会话目录里产生了什么（应该有配置/会话，而不是空）' -ForegroundColor Yellow
$cd = Join-Path $SessionWorkDir 'config\claude'
if (Test-Path $cd) {
    Get-ChildItem -LiteralPath $cd -Force -EA SilentlyContinue |
        Select-Object -First 12 |
        ForEach-Object { Write-Host ("    " + $_.Name + $(if ($_.PSIsContainer) { '\' } else { "  ($($_.Length) B)" })) }
    $n = (Get-ChildItem -LiteralPath $cd -Recurse -Force -File -EA SilentlyContinue | Measure-Object).Count
    Write-Host "    共 $n 个文件" -ForegroundColor Gray
} else {
    Write-Host '    config\claude 还不存在' -ForegroundColor Gray
}
$homeDir = Join-Path $SessionWorkDir 'home'
if (Test-Path $homeDir) {
    $hn = (Get-ChildItem -LiteralPath $homeDir -Recurse -Force -EA SilentlyContinue | Measure-Object).Count
    Write-Host "    home\ 里有 $hn 项（.claude.json 若被重定向就应该出现在这）" -ForegroundColor Gray
}

# ---------- 比对宿主 ----------
Write-Host ''
Write-Host '[6] 再取一次宿主快照并比对' -ForegroundColor Yellow
Start-Sleep -Milliseconds 500
$after = Get-Snap
$changed = @()
foreach ($k in $before.Keys) {
    if ($before[$k] -ne $after[$k]) { $changed += "$k`n        前: $($before[$k])`n        后: $($after[$k])" }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
if ($changed.Count -eq 0) {
    Write-Host '  读/写隔离通过：宿主文件一字未变' -ForegroundColor Green
} else {
    Write-Host "  隔离失败：$($changed.Count) 个宿主文件被改动了" -ForegroundColor Red
    foreach ($c in $changed) { Write-Host "    - $c" -ForegroundColor Red }
}
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
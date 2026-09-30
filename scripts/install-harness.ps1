# ============================================================
#  install-harness.ps1 —— 把 harness 装进 U 盘的 npm-global/
#
#  ★ 一律用盘上便携 node 自带的 npm，显式 --prefix 指到 U 盘。
#    绝不碰宿主的 npm、不碰宿主的全局目录、不写宿主任何位置。
#  ★ npm 走 npmmirror（本机实测 0.2s，官方源 0.7s）
#
#  ★ FAT32 上的已知问题与对策（实测踩过）：
#    @anthropic-ai/claude-code 的 postinstall 会用**硬链接**把平台二进制
#    放到 bin/claude.exe，而 FAT32 不支持硬链接 →
#      EISDIR: illegal operation on a directory,
#      link '...claude-code-win32-x64\claude.exe' -> '...\bin\claude.exe'
#    install.cjs 里虽然有 copyFileSync 兜底，但没捕获这个错误码。
#    对策：--ignore-scripts 跳过 postinstall，然后
#      1) 用 Resolve-HarnessExe 找到真正的平台二进制
#      2) 把 npm 生成的 shim 改指向它（零额外磁盘，PATH 上的 `claude` 照常可用）
# ============================================================

[CmdletBinding()]
param(
    [string]$Only = ''      # 只装某个 id；留空 = 装 registry 里所有 enabled 的
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot
Initialize-Log -LogDir (Join-Path $StickRoot 'logs') -Name install

$registry = Read-JsonFile -Path (Join-Path $StickRoot 'harness\registry.json')

$NodeDir  = Join-Path $StickRoot 'runtime\node'
$NpmCmd   = Join-Path $NodeDir 'npm.cmd'
$Prefix   = Join-Path $StickRoot 'npm-global'
$NpmCache = Join-Path $StickRoot 'cache\npm'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  安装 harness 到 U 盘' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $NpmCmd)) {
    Write-Log "找不到盘上的 npm: $NpmCmd" 'ERROR'
    Write-Host '请先双击 AI设置.cmd → 运行初始化（bootstrap）' -ForegroundColor Yellow
    exit 1
}

foreach ($d in @($Prefix, $NpmCache)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 让盘上的 node 优先；只改本进程，不碰宿主
$origPath = $env:PATH
$env:PATH = "$NodeDir;$env:PATH"
$env:npm_config_cache    = $NpmCache
$env:npm_config_prefix   = $Prefix
$env:npm_config_registry = 'https://registry.npmmirror.com'

Write-Log "node : $(& (Join-Path $NodeDir 'node.exe') --version)"
Write-Log "npm  : $(& $NpmCmd --version)"
Write-Log "安装前缀: $Prefix"

# ---------- 把 shim 改指向真正的二进制 ----------
function Update-HarnessShims {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$StubRel,
        [Parameter(Mandatory)][string]$RealRel
    )
    $forms = @(
        @{ from = $StubRel;                  to = $RealRel },
        @{ from = $StubRel.Replace('\','/'); to = $RealRel.Replace('\','/') }
    )
    $patched = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Prefix -File -Force -EA SilentlyContinue)) {
        try {
            $txt = [IO.File]::ReadAllText($f.FullName)
            $orig = $txt
            foreach ($p in $forms) {
                if ($txt -like "*$($p.from)*") { $txt = $txt.Replace($p.from, $p.to) }
            }
            if ($txt -ne $orig) {
                [IO.File]::WriteAllText($f.FullName, $txt, (New-Object Text.UTF8Encoding($false)))
                $patched++
                Write-Log "  已改指向: $($f.Name)"
            }
        } catch { Write-Log "  shim 处理失败 $($f.Name): $($_.Exception.Message)" 'WARN' }
    }
    return $patched
}

$targets = @($registry.harnesses | Where-Object { $_.enabled -and ($_.install.type -eq 'npm') })
if ($Only) { $targets = @($targets | Where-Object { $_.id -eq $Only }) }
if (-not $targets -or $targets.Count -eq 0) {
    Write-Log '没有要安装的目标' 'WARN'
    exit 0
}

$failed = @()
foreach ($h in $targets) {
    Write-Host ''
    Write-Log "--- 安装 $($h.name)  ($($h.install.package)) ---"

    $skipScripts = ($h.install.PSObject.Properties.Name -contains 'ignoreScripts') -and $h.install.ignoreScripts

    $npmArgs = @('install', '--global', '--prefix', $Prefix, '--no-fund', '--no-audit')
    if ($skipScripts) {
        $npmArgs += '--ignore-scripts'
        Write-Log '使用 --ignore-scripts（FAT32 上必需：postinstall 要建硬链接）' 'WARN'
    }
    $npmArgs += $h.install.package

    $out = & $NpmCmd @npmArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $out) { Write-Log ("  " + $l) }

    if ($code -ne 0) {
        Write-Log "$($h.name) 安装失败（npm 返回 $code）" 'ERROR'
        $failed += $h.name
        continue
    }

    # 找到真正能跑的那个可执行体（关键：绕开 FAT32 上的存根）
    # ★ BaseDir 必须是盘根 —— registry 里的候选路径是相对盘根的（含 npm-global/ 前缀）
    $exe = Resolve-HarnessExe -Harness $h -BaseDir $StickRoot
    if (-not $exe) {
        Write-Log "$($h.name) 装完了，但找不到体积达标的可执行体" 'ERROR'
        Write-Log "  检查 $Prefix\node_modules 下的实际结构" 'WARN'
        $failed += $h.name
        continue
    }
    Write-Log "可执行体: $exe" 'OK'
    Write-Log ("  体积: {0:N0} MB" -f ((Get-Item -LiteralPath $exe).Length / 1MB))

    # 如果选中的不是第一个候选（说明第一个是存根），就把 shim 改指过去。
    # ★ shim 里的路径是相对 npm-global\ 的，所以要剥掉 npm-global/ 前缀 —— 两处基准不同
    $firstCand = @($h.run.pathCandidates)[0]
    $firstFull = Join-Path $StickRoot $firstCand
    if ($exe -ne $firstFull) {
        Write-Log '检测到首选路径是存根，改修 shim 指向真二进制...'
        $stubRel = ($firstCand -replace '^npm-global[/\\]', '')   -replace '/', '\'
        $realRel = ($exe.Substring($Prefix.Length).TrimStart('\')) -replace '/', '\'
        $n = Update-HarnessShims -Prefix $Prefix -StubRel $stubRel -RealRel $realRel
        if ($n -eq 0) { Write-Log '  没有 shim 需要改（可能未生成）' 'WARN' } else { Write-Log "  改了 $n 个 shim" 'OK' }
    }

    # 装完立刻验证真的能跑
    try {
        $v = & $exe --version 2>&1 | Select-Object -First 1
        Write-Log "  $($h.name) 可运行，版本: $v" 'OK'
    } catch {
        Write-Log "  可执行体在，但 --version 失败: $($_.Exception.Message)" 'WARN'
    }

    # 顺带验证 PATH 上的 shim 也能跑（这是用户日常会用到的那条路）
    $shim = Join-Path $Prefix 'claude.cmd'
    if (Test-Path -LiteralPath $shim) {
        try {
            $sv = & $shim --version 2>&1 | Select-Object -First 1
            if ($sv -match '\d+\.\d+') { Write-Log "  shim 验证通过: $sv" 'OK' }
            else { Write-Log "  shim 输出异常: $sv" 'WARN' }
        } catch {
            Write-Log "  shim 跑不起来: $($_.Exception.Message)" 'WARN'
        }
    }
}

$env:PATH = $origPath

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Log '全部安装完成' 'OK'
    Write-Host '下一步：AI设置 → 凭据保险箱配置密钥，然后双击 AI.cmd' -ForegroundColor Yellow
} else {
    Write-Log "以下安装失败: $($failed -join ', ')" 'ERROR'
}
Write-Host ''
Write-Log "日志: $script:LogPath"
# ============================================================
#  bootstrap.ps1 —— 一次性初始化：把便携运行时下载到 U 盘
#  用法：powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#  可选：-SkipPython  跳过 Python 预装
#  说明：只在本机跑一次。跑完之后插到任何机器都不再需要下载。
# ============================================================

[CmdletBinding()]
param(
    [switch]$SkipPython,
    [switch]$Force,             # 已存在的运行时也重新下载
    [switch]$UseSystemProxy     # 强制走系统代理（公司内网等场景）。默认绕过
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot
Initialize-Log -LogDir (Join-Path $StickRoot 'logs') -Name bootstrap

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  便携 AI 工具箱 —— 初始化' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "盘根: $StickRoot"
Write-Host ''

# HTTPS 必须开 TLS 1.2，否则 PS 5.1 连不上现代站点
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------- 下载（带进度、带镜像回退） ----------
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [long]$ExpectedSize = 0
    )
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'aistick/0.1'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 45000      # 卡住就快点失败，换下一个源
    $req.AllowAutoRedirect = $true

    # ★ 关键：绕过系统代理。
    # [Net.HttpWebRequest] 默认走 Windows 的 WinINET 代理设置，而本机实测
    # 系统代理是 127.0.0.1:7890（Clash）。走它时下载会卡到 4KB/s 甚至中断；
    # 直连同一个源反而有 10-12 MB/s。curl 不走系统代理，所以之前对比时没暴露。
    # 需要强制走代理的环境（公司内网）请加 -UseSystemProxy。
    if (-not $UseSystemProxy) { $req.Proxy = $null }

    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $in    = $resp.GetResponseStream()
        $dir   = Split-Path -Parent $OutFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $out   = [IO.File]::Create($OutFile)
        try {
            $buf = New-Object byte[] (1MB)
            $read = 0L; $lastPct = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $read += $n
                if ($total -gt 0) {
                    $pct = [int]($read * 100 / $total)
                    if ($pct -ne $lastPct) {
                        Write-Progress -Activity ("下载 " + (Split-Path $OutFile -Leaf)) `
                            -Status ("{0} / {1} MB" -f [math]::Round($read/1MB,1), [math]::Round($total/1MB,1)) `
                            -PercentComplete $pct
                        $lastPct = $pct
                    }
                }
            }
        } finally { $out.Close(); $in.Close() }
    } finally { $resp.Close() }
    Write-Progress -Activity '下载' -Completed

    $actual = (Get-Item -LiteralPath $OutFile).Length
    if ($ExpectedSize -gt 0 -and $actual -ne $ExpectedSize) {
        throw "体积不符：期望 $ExpectedSize，实际 $actual"
    }
    return $actual
}

function Invoke-DownloadWithFallback {
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$OutFile,
        [long]$ExpectedSize = 0
    )
    $errs = @()
    foreach ($u in $Urls) {
        try {
            $short = if ($u.Length -gt 78) { $u.Substring(0, 75) + '...' } else { $u }
            Write-Log "来源: $short"
            $size = Invoke-Download -Url $u -OutFile $OutFile -ExpectedSize $ExpectedSize
            Write-Log ("下载完成 {0:N1} MB" -f ($size / 1MB)) 'OK'
            return $u
        } catch {
            $errs += "$u  ->  $($_.Exception.Message)"
            Write-Log "该来源失败，换下一个" 'WARN'
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -EA SilentlyContinue }
        }
    }
    throw "所有来源都失败:`n  " + ($errs -join "`n  ")
}

function Test-Sha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($h -eq $Expected.ToUpper())
}

# ---------- 镜像链（都是本机实测过的） ----------
#
# 实测结论（2026-09-24，本机）：
#   · GitHub 直连            —— 20 秒超时，不通
#   · gh-proxy.com 等公共代理 —— 吞吐极不稳定：同一源同一目标，
#                                从 12 MB/s 到 89 KB/s 都出现过，后两轮 90 秒没下完
#   · USTC github-release    —— 稳定 1.1-1.3 MB/s，能完整下完，而且提供 .sha256
#   · nodejs.org / npmmirror —— Node 快（10 MB/s / 7 MB/s）
#
# 所以：能走 USTC 的走 USTC，其余才退回公共代理链。
# Node 不在 USTC 的 github-release 里（它是 nodejs.org 的产物），走官方 + npmmirror。

function Get-GithubUrls {
    param([Parameter(Mandatory)][string]$GhUrl)
    # $GhUrl 形如 https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
    $urls = @()
    # 1) USTC github-release 镜像（最稳）
    if ($GhUrl -match '^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$') {
        $owner, $repo, $tag, $file = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
        $encTag = [Uri]::EscapeDataString($tag)
        # USTC 的 tag 目录名对 git-for-windows 是 "Git for Windows v2.55.0.windows.5" 形式
        if ($repo -eq 'git') { $encTag = [Uri]::EscapeDataString("Git for Windows $tag") }
        $urls += "https://mirrors.ustc.edu.cn/github-release/$owner/$repo/$encTag/$file"
        $urls += "https://mirrors.ustc.edu.cn/github-release/$owner/$repo/LatestRelease/$file"
    }
    # 2) 公共代理链（不稳定，兜底）
    foreach ($m in @('https://gh-proxy.com/', 'https://ghproxy.net/', 'https://ghfast.top/')) {
        $urls += "$m$GhUrl"
    }
    # 3) 直连（最后兜底）
    $urls += $GhUrl
    return $urls
}

# ============================================================
#  1. Node.js LTS v24.21.0
# ============================================================
$NodeVer  = 'v24.21.0'
$NodeZip  = "node-$NodeVer-win-x64.zip"
$NodeDir  = Join-Path $StickRoot 'runtime\node'
$NodeOk   = (Test-Path (Join-Path $NodeDir 'node.exe'))

Write-Host ''
Write-Log "--- [1/4] Node.js $NodeVer ---"

if ($NodeOk -and -not $Force) {
    Write-Log '已存在，跳过' 'OK'
} else {
    $tmp = Join-Path $StickRoot 'cache\dl'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }

    # 先取官方校验文件（官方源实测可用且快）
    $sumsUrl = "https://nodejs.org/dist/$NodeVer/SHASUMS256.txt"
    $sumsTxt = Join-Path $tmp 'SHASUMS256.txt'
    Invoke-DownloadWithFallback -Urls @(
        $sumsUrl,
        "https://registry.npmmirror.com/-/binary/node/$NodeVer/SHASUMS256.txt"
    ) -OutFile $sumsTxt | Out-Null

    $wantHash = $null
    foreach ($line in [IO.File]::ReadAllLines($sumsTxt)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($NodeZip) + '\s*$') {
            $wantHash = $Matches[1]; break
        }
    }
    if (-not $wantHash) { throw "在 SHASUMS256.txt 里找不到 $NodeZip 的校验值" }
    Write-Log "期望 sha256: $($wantHash.Substring(0,16))..."

    $zipPath = Join-Path $tmp $NodeZip
    Invoke-DownloadWithFallback -Urls @(
        "https://nodejs.org/dist/$NodeVer/$NodeZip",
        "https://registry.npmmirror.com/-/binary/node/$NodeVer/$NodeZip"
    ) -OutFile $zipPath | Out-Null

    if (Test-Sha256 -Path $zipPath -Expected $wantHash) {
        Write-Log 'sha256 校验通过' 'OK'
    } else {
        Remove-Item -LiteralPath $zipPath -Force
        throw 'sha256 校验失败，已删除下载文件。请重试。'
    }

    Write-Log '解压中...'
    $stage = Join-Path $tmp 'node-stage'
    Remove-ItemForce -Path $stage | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $stage -Force
    # zip 里是 node-v24.21.0-win-x64/ 一层，挪上来
    $inner = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
    Remove-ItemForce -Path $NodeDir | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $NodeDir
    Remove-ItemForce -Path $stage | Out-Null
    Remove-Item -LiteralPath $zipPath -Force -EA SilentlyContinue
    Write-Log 'Node 就绪' 'OK'
}

# ============================================================
#  2. uv 0.12.18（单文件，很小）
# ============================================================
# 用 0.12.17 而不是最新的 0.12.18：USTC 镜像上 0.12.17 已归档且有 .sha256，
# 能做强校验；公共代理上有 .18 但吞吐不可靠。
$UvVer   = '0.12.17'
$UvName  = 'uv-x86_64-pc-windows-msvc.zip'
$UvSize  = 17906210        # 该版本的真实体积（已实测）
$UvDir   = Join-Path $StickRoot 'runtime\uv'
$UvExe   = Join-Path $UvDir 'uv.exe'

Write-Host ''
Write-Log "--- [2/4] uv $UvVer ---"

if ((Test-Path $UvExe) -and -not $Force) {
    Write-Log '已存在，跳过' 'OK'
} else {
    $tmp = Join-Path $StickRoot 'cache\dl'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    $ghUrl = "https://github.com/astral-sh/uv/releases/download/$UvVer/$UvName"
    $zipPath = Join-Path $tmp $UvName
    $mirrors = Get-GithubUrls $ghUrl

    # USTC 提供 .sha256，能做强校验；拿不到就退回体积校验
    $wantHash = $null
    foreach ($u in $mirrors[0..([Math]::Min(1, $mirrors.Count - 1))]) {
        try {
            $tmpSum = Join-Path $tmp 'uv.sha256'
            Invoke-Download -Url "$u.sha256" -OutFile $tmpSum | Out-Null
            $txt = [IO.File]::ReadAllText($tmpSum)
            if ($txt -match '([0-9a-fA-F]{64})') { $wantHash = $Matches[1]; break }
        } catch { continue }
    }
    if ($wantHash) { Write-Log "期望 sha256: $($wantHash.Substring(0,16))...（来自 USTC）" }
    else { Write-Log '拿不到 sha256，改用体积校验' 'WARN' }

    Invoke-DownloadWithFallback -Urls $mirrors -OutFile $zipPath -ExpectedSize $UvSize | Out-Null

    if ($wantHash) {
        if (Test-Sha256 -Path $zipPath -Expected $wantHash) {
            Write-Log 'sha256 校验通过' 'OK'
        } else {
            Remove-Item -LiteralPath $zipPath -Force
            throw 'uv 的 sha256 校验失败，已删除下载文件'
        }
    }

    Remove-ItemForce -Path $UvDir | Out-Null
    New-Item -ItemType Directory -Path $UvDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $UvDir -Force
    Remove-Item -LiteralPath $zipPath -Force -EA SilentlyContinue

    if (-not (Test-Path $UvExe)) { throw '解压后找不到 uv.exe' }
    $v = & $UvExe --version 2>&1
    Write-Log "uv 就绪: $v" 'OK'
}

# ============================================================
#  3. PortableGit（含 bash.exe —— Claude Code 的 Bash 工具需要）
# ============================================================
$GitVer  = 'v2.55.0.windows.5'
$GitName = 'PortableGit-2.55.0.5-64-bit.7z.exe'
$GitDir  = Join-Path $StickRoot 'runtime\git'
$BashExe = Join-Path $GitDir 'bin\bash.exe'

Write-Host ''
Write-Log "--- [3/4] PortableGit $GitVer ---"

if ((Test-Path $BashExe) -and -not $Force) {
    Write-Log '已存在，跳过' 'OK'
} else {
    $tmp = Join-Path $StickRoot 'cache\dl'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    $ghUrl = "https://github.com/git-for-windows/git/releases/download/$GitVer/$GitName"
    $sfx   = Join-Path $tmp $GitName

    $expSize = 58960208
    Invoke-DownloadWithFallback -Urls (Get-GithubUrls $ghUrl) -OutFile $sfx -ExpectedSize $expSize | Out-Null

    Write-Log '自解压中（FAT32 上硬链接会退化成副本，体积会比官方大，属正常）...'
    Remove-ItemForce -Path $GitDir | Out-Null
    New-Item -ItemType Directory -Path $GitDir -Force | Out-Null

    # 7z 自解压包：-o 指定目标 -y 全部确认
    $p = Start-Process -FilePath $sfx -ArgumentList "-o`"$GitDir`"", '-y' -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { Write-Log "自解压返回码 $($p.ExitCode)（可能有硬链接警告，继续检查）" 'WARN' }

    if (-not (Test-Path $BashExe)) {
        throw "解压后找不到 $BashExe —— 自解压在 FAT32 上失败了。回退方案见 docs/ 说明（改用 MinGit + 另找 bash）"
    }
    Remove-Item -LiteralPath $sfx -Force -EA SilentlyContinue
    $sz = (Get-ChildItem $GitDir -Recurse -Force -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Log ("git 就绪，占用 {0:N0} MB" -f ($sz/1MB)) 'OK'
}

# ============================================================
#  4. Python 预装进盘
#
#  ★ 这里不用 `uv python install`。实测它在 FAT32 上必然失败：
#      Downloading cpython-3.12.14 ...  (下载其实是成功的)
#      error: Failed to create Python minor version link directory
#      cause: 函数不正确。 (os error 1)
#    原因是 uv 要建一个 cpython-3.12 -> cpython-3.12.14-... 的**链接目录**，
#    而 FAT32 不支持符号链接/联接点（重解析点）。uv 也没有关掉它的开关
#    （查过 python install --help，只有 --no-bin / --no-registry）。
#
#  ★ 改为自己下官方 install_only tarball 再解压：
#    · 完全绕开 uv 的链接逻辑
#    · USTC 镜像实测 1.9-8 MB/s
#    · 解压出来的 Python 放在 PATH 上，uv 会把它当"系统 Python"用，
#      `uv venv` / `uv pip` 都正常工作
#    · 代价：`uv python install` 在这个 FAT32 盘上不能用（已知限制，写入文档）
# ============================================================
Write-Host ''
Write-Log '--- [4/4] Python 预装 ---'

$PyRelVer = '3.12.14'
$PyTag    = '20260901'
$PyName   = "cpython-$PyRelVer+$PyTag-x86_64-pc-windows-msvc-install_only.tar.gz"
$PySize   = 46184075      # 已实测
$PyDir    = Join-Path $StickRoot 'runtime\python'
$PyExe    = Join-Path $PyDir 'python.exe'

if ($SkipPython) {
    Write-Log '按要求跳过' 'WARN'
} elseif ((Test-Path $PyExe) -and -not $Force) {
    Write-Log '已存在，跳过' 'OK'
} else {
    $tmp = Join-Path $StickRoot 'cache\dl'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }

    # USTC 路径布局与 GitHub 的 releases/download 不同（少了 releases/download 一层），
    # 所以这里手写 URL，不走 Get-GithubUrls
    $pbsBase = 'https://mirrors.ustc.edu.cn/github-release/astral-sh/python-build-standalone'
    $tarUrls = @(
        "$pbsBase/$PyTag/$PyName",
        "$pbsBase/LatestRelease/$PyName",
        "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download/$PyTag/$PyName"
    )

    $tarball = Join-Path $tmp $PyName
    Invoke-DownloadWithFallback -Urls $tarUrls -OutFile $tarball -ExpectedSize $PySize | Out-Null

    Write-Log '解压 Python（约 3400 个文件，FAT32 上要一两分钟）...'
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tarExe)) {
        throw "找不到 $tarExe（Windows 10 1803+ 自带）。无法解压 Python。"
    }

    # tarball 顶层是 python/ 一层，直接解到 runtime\ 就会得到 runtime\python\
    Remove-ItemForce -Path $PyDir | Out-Null
    $p = Start-Process -FilePath $tarExe -ArgumentList @('-xzf', $tarball, '-C', (Join-Path $StickRoot 'runtime')) `
         -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "tar 解压失败，返回码 $($p.ExitCode)" }
    Remove-Item -LiteralPath $tarball -Force -EA SilentlyContinue

    if (-not (Test-Path $PyExe)) { throw "解压后找不到 $PyExe" }
    $v = & $PyExe --version 2>&1
    $sz = (Get-ChildItem $PyDir -Recurse -Force -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Log ("Python 就绪: $v  占用 {0:N0} MB" -f ($sz/1MB)) 'OK'
    Write-Log '注意：FAT32 不支持重解析点，所以 `uv python install` 在本盘上不可用（用盘上这份 Python 即可）' 'WARN'
}

# ============================================================
#  汇总
# ============================================================
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Log '初始化完成。运行时清单：' 'OK'

$rows = @()
foreach ($item in @(
    @{ n='Node';  p=(Join-Path $StickRoot 'runtime\node\node.exe') },
    @{ n='uv';    p=(Join-Path $StickRoot 'runtime\uv\uv.exe') },
    @{ n='bash';  p=(Join-Path $StickRoot 'runtime\git\bin\bash.exe') },
    @{ n='git';   p=(Join-Path $StickRoot 'runtime\git\cmd\git.exe') },
    @{ n='python'; p=(Join-Path $StickRoot 'runtime\python\python.exe') }
)) {
    $exists = Test-Path -LiteralPath $item.p
    $rows += [pscustomobject]@{
        组件 = $item.n
        状态 = if ($exists) { '就绪' } else { '缺失' }
        路径 = $item.p
    }
}
$rows | Format-Table -AutoSize

$total = (Get-ChildItem $StickRoot -Recurse -Force -File -EA SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\logs\\' } |
          Measure-Object Length -Sum).Sum
Write-Host ("U 盘当前占用: {0:N0} MB" -f ($total/1MB))
Write-Host ''
Write-Host '下一步：' -ForegroundColor Yellow
Write-Host '  1) 双击 AI设置.cmd，选「安装 harness」把 Claude Code 装进盘'
Write-Host '  2) 在 config\keys.env 里填入你的阿里云百炼密钥'
Write-Host '  3) 双击 AI.cmd 开始使用'
Write-Host ''
Write-Log "日志: $script:LogPath"
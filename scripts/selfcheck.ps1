# ============================================================
#  selfcheck.ps1 —— 逐项自检
#  把"能自动验的"都验一遍，剩下的（拔盘、进程隔离）见 README 的手工清单
# ============================================================

[CmdletBinding()]
param(
    [string]$StickRoot,
    [string]$TempRoot = [IO.Path]::GetTempPath()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'     # 自检要跑完全部，不能中途停

. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

if (-not $StickRoot) { $StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot }
$StickRoot = [IO.Path]::GetFullPath($StickRoot).TrimEnd('\')
Initialize-Log -LogDir (Join-Path $StickRoot 'logs') -Name selfcheck

$results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Item, [bool]$Ok, [string]$Detail = '')
    [void]$results.Add([pscustomobject]@{ 检查项 = $Item; 结果 = $(if ($Ok) { '通过' } else { '失败' }); 说明 = $Detail })
    $c = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}  {2}" -f $(if ($Ok) { '√' } else { '×' }), $Item, $Detail) -ForegroundColor $c
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  便携 AI 工具箱 —— 自检' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "盘根: $StickRoot"
Write-Host ''

# ---------- 1. 运行时 ----------
Write-Host '[运行时]' -ForegroundColor Yellow
$rt = @(
    @{ n = 'node.exe'; p = 'runtime\node\node.exe'; req = $true },
    @{ n = 'npm.cmd';  p = 'runtime\node\npm.cmd';  req = $true },
    @{ n = 'uv.exe';   p = 'runtime\uv\uv.exe';     req = $false },
    @{ n = 'bash.exe'; p = 'runtime\git\bin\bash.exe'; req = $true },
    @{ n = 'git.exe';  p = 'runtime\git\cmd\git.exe';  req = $false },
    @{ n = 'python';   p = 'runtime\python';        req = $false }
)
foreach ($x in $rt) {
    $full = Join-Path $StickRoot $x.p
    $exists = Test-Path -LiteralPath $full
    if ($exists) {
        Add-Result "运行时 $($x.n)" $true '存在'
    } elseif ($x.req) {
        Add-Result "运行时 $($x.n)" $false '缺失（必需）—— 请运行初始化'
    } else {
        # 非必需项：算通过，但说明里标注
        Add-Result "运行时 $($x.n)" $true '未安装（非必需）'
    }
}

# ---------- 2. harness ----------
Write-Host ''
Write-Host '[harness]' -ForegroundColor Yellow
$registryPath = Join-Path $StickRoot 'harness\registry.json'
if (-not (Test-Path -LiteralPath $registryPath)) {
    Add-Result 'registry.json' $false '缺失'
} else {
    Add-Result 'registry.json' $true '可读'
    try {
        $registry = Read-JsonFile -Path $registryPath
        foreach ($h in @($registry.harnesses | Where-Object { $_.enabled })) {
            $exe = Resolve-HarnessExe -Harness $h -BaseDir $StickRoot
            if ($exe) {
                $sz = (Get-Item -LiteralPath $exe).Length / 1MB
                Add-Result "$($h.name) 可执行体" $true ("{0:N0} MB  {1}" -f $sz, $exe.Substring($StickRoot.Length))
            } else {
                Add-Result "$($h.name) 可执行体" $false '未安装或只有存根 —— 请运行「安装 / 更新 harness」'
            }
            $sf = Join-Path $StickRoot $h.settingsFile
            Add-Result "$($h.name) settings" (Test-Path -LiteralPath $sf) $(if (Test-Path -LiteralPath $sf) { '存在' } else { '缺失' })
        }
} catch {
    Add-Result 'registry.json 解析' $false '格式异常或不可读'
    }
}

# ---------- 3. 凭据来源（不解锁、不读取内容） ----------
Write-Host ''
Write-Host '[凭据来源]' -ForegroundColor Yellow
$vaultFile = Join-Path $StickRoot 'config\credentials.vault.json'
$keysFile = Join-Path $StickRoot 'config\keys.env'
$providersPath = Join-Path $StickRoot 'harness\providers.json'
if (Test-Path -LiteralPath $vaultFile -PathType Leaf) {
    Add-Result '凭据来源' $true '保险箱存在；内容未验证，解锁后才能检查'
} elseif ((Test-Path -LiteralPath ($vaultFile + '.bak') -PathType Leaf) -or
    (Test-Path -LiteralPath ($vaultFile + '.tmp') -PathType Leaf)) {
    Add-Result '凭据来源' $false '发现保险箱恢复文件，禁止回退到 keys.env；请先恢复保险箱'
} elseif (Test-Path -LiteralPath $keysFile -PathType Leaf) {
    Add-Result '凭据来源' $true 'keys.env 存在；内容未读取，完整性未验证'
} else {
    Add-Result '凭据来源' $false '保险箱与 keys.env 均不存在'
}
Add-Result '凭据内容验证' $true '自检不读取密钥；需要时请在保险箱解锁后验证'
Add-Result 'providers.json 配置' (Test-Path -LiteralPath $providersPath -PathType Leaf) $(if (Test-Path -LiteralPath $providersPath -PathType Leaf) { '存在；自检未读取凭据定义' } else { '缺失' })

# ---------- 4. 卷标识 / 主机标识 ----------
Write-Host ''
Write-Host '[标识（程序运行时现场采集，不写死）]' -ForegroundColor Yellow
try {
    $vol = Get-VolumeIdentity -StickRoot $StickRoot
    Add-Result '卷标识可获取' $true "盘符 $($vol.DriveLetter): / 序列号 $($vol.Serial)"
    Add-Result '卷在场检测' (Test-StickPresent -Expected $vol) '认卷不认盘符'
} catch {
    Add-Result '卷标识可获取' $false '无法读取卷标识'
}
Add-Result '主机标识可获取' $true (Get-HostIdentity)

# ---------- 5. 脚本自身健康 ----------
Write-Host ''
Write-Host '[脚本健康]' -ForegroundColor Yellow
$psFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File
$noBom = @()
$hardcoded = @()
foreach ($f in $psFiles) {
    # BOM 检查：ACP=936 的机器上没有 BOM 会把中文解成乱码（已实测）
    $head = [IO.File]::ReadAllBytes($f.FullName) | Select-Object -First 3
    $hasBom = ($head.Count -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
    if (-not $hasBom) { $noBom += $f.Name }

    # 硬编码盘符检查：除了注释里的示意，代码里不该出现 "E:\"
    $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($line in ($txt -split "`n")) {
        if ($line -match '=\s*["'']?[A-Z]:\\' -and $line -notmatch '^\s*#') { $hardcoded += "$($f.Name): $($line.Trim())" }
    }
}
Add-Result '所有 .ps1 都带 UTF-8 BOM' ($noBom.Count -eq 0) $(if ($noBom.Count) { $noBom -join ', ' } else { "$($psFiles.Count) 个文件全部合格" })
Add-Result '代码里没有硬编码盘符' ($hardcoded.Count -eq 0) $(if ($hardcoded.Count) { $hardcoded -join ' | ' } else { '全部用 $PSScriptRoot / 参数推导' })

# ---------- 6. 完整性校验能力 ----------
Write-Host ''
Write-Host '[共享读取能力（决定能否边跑边同步）]' -ForegroundColor Yellow
try {
    $probe = Join-Path $StickRoot 'cache\.probe'
    if (-not (Test-Path (Split-Path $probe))) { New-Item -ItemType Directory -Path (Split-Path $probe) -Force | Out-Null }
    [IO.File]::WriteAllText($probe, 'probe', (New-Object Text.UTF8Encoding($false)))
    $fs = Open-SharedRead -Path $probe
    $fs.Close()
    Remove-Item -LiteralPath $probe -Force
    Add-Result 'FILE_SHARE_READ|WRITE|DELETE 可用' $true '不需要管理员、不需要卷影副本'
} catch {
    Add-Result 'FILE_SHARE_READ|WRITE|DELETE 可用' $false '共享读取能力不可用'
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$fail = @($results | Where-Object { $_.结果 -eq '失败' })
Write-Host ("  共 {0} 项，通过 {1}，失败 {2}" -f $results.Count, ($results.Count - $fail.Count), $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Yellow' } else { 'Green' })
if ($fail.Count) {
    Write-Host ''
    Write-Host '  需要处理：' -ForegroundColor Yellow
    foreach ($f in $fail) { Write-Host "    - $($f.检查项): $($f.说明)" -ForegroundColor Yellow }
}
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '以下项目无法自动验证，需手工测（见 docs\验证清单.md）：' -ForegroundColor DarkGray
Write-Host '  · 拔盘后进程树是否被杀、临时目录是否被清' -ForegroundColor DarkGray
Write-Host '  · 强杀守护进程后内核兜底是否生效' -ForegroundColor DarkGray
Write-Host '  · 宿主已有 claude.exe 是否被误杀（进程隔离）' -ForegroundColor DarkGray
Write-Host '  · 宿主 ~/.claude.json 等是否一字未变（读/写隔离）' -ForegroundColor DarkGray
Write-Host ''

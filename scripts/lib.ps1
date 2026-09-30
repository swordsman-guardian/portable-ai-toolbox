# ============================================================
#  lib.ps1 —— 公共函数库
#  被 launch / guardian / sync / selfcheck 共用
#  ★ 必须存成 UTF-8 带 BOM：Windows PowerShell 5.1 在 ACP=936 下
#    读无 BOM 的 UTF-8 脚本会把中文字符串解成乱码（已实测）
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- 控制台编码（保证中文能正确显示，不改系统设置） ----------
function Set-ConsoleUtf8 {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
        $OutputEncoding           = [System.Text.Encoding]::UTF8
    } catch { }
}

# ---------- 日志 ----------
$script:LogPath = $null

function Initialize-Log {
    param([Parameter(Mandatory)][string]$LogDir, [string]$Name = 'run')
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath = Join-Path $LogDir "$Name-$stamp.log"
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:LogPath) {
        try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
}

# ---------- 盘根定位（绝不写死盘符） ----------
# 传入某个脚本文件所在目录（通常是 $PSScriptRoot），返回盘根
function Get-StickRoot {
    param([Parameter(Mandatory)][string]$ScriptDir)
    # 脚本都在 <盘根>\scripts\ 下，所以盘根 = 上一级
    $root = Split-Path -Parent $ScriptDir
    if (-not $root) { throw "无法从上路径推导盘根: $ScriptDir" }
    # 规范化成不带尾斜杠的绝对路径
    return (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
}

# ---------- 主机标识 ----------
# 计算机名 + MachineGuid 前 8 位。机器名可读，GUID 保证唯一（机器名会重名）
function Get-HostIdentity {
    $name = $env:COMPUTERNAME
    if (-not $name) { $name = 'UNKNOWN' }

    $guid = $null
    try {
        $guid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    } catch {
        # 读不到就退回用主机名，不阻断流程
        Write-Log "读不到 MachineGuid，主机标识将只用机器名" 'WARN'
    }

    # 机器名里可能有非法路径字符，清掉
    $safe = ($name -replace '[^\w\-]', '_')
    if ($guid) {
        $short = $guid.Replace('-', '').Substring(0, 8)
        return "$safe-$short"
    }
    return $safe
}

# ---------- 卷标识（认卷，不认盘符） ----------
# 拔盘后别的设备可能占用同一盘符，所以必须认卷
function Get-VolumeIdentity {
    param([Parameter(Mandatory)][string]$StickRoot)

    $drive = (Split-Path -Qualifier $StickRoot).TrimEnd(':')   # 'E:\...' -> 'E'
    $id = [ordered]@{ DriveLetter = $drive; VolumeGuid = $null; Serial = $null; Label = $null }

    # 卷 GUID —— 首选，唯一性最强
    try {
        $v = Get-Volume -DriveLetter $drive -ErrorAction Stop
        $id.VolumeGuid = $v.UniqueId
        $id.Label      = $v.FileSystemLabel
    } catch { }

    # 卷序列号 —— 次选，交叉校验
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'" -ErrorAction Stop
        if ($ld) { $id.Serial = $ld.VolumeSerialNumber }
    } catch { }

    if (-not $id.VolumeGuid -and -not $id.Serial) {
        throw "拿不到 $drive`: 的卷标识，无法可靠检测拔盘"
    }
    return [pscustomobject]$id
}

# 至少有一个共同且相等的标识才认为是同一卷；不能把“无法比较”当作相同。
function Test-VolumeIdentityMatch {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual)
    $comparable = 0
    foreach ($name in @('VolumeGuid', 'Serial')) {
        $expectedProperty = $Expected.PSObject.Properties[$name]
        $actualProperty = $Actual.PSObject.Properties[$name]
        if ($expectedProperty -and $actualProperty -and $expectedProperty.Value -and $actualProperty.Value) {
            $comparable++
            if (-not [string]::Equals([string]$expectedProperty.Value, [string]$actualProperty.Value, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return ($comparable -gt 0)
}

# 判定盘还在不在：盘符不存在 或 标识与启动时不一致 —— 都算没了
function Test-StickPresent {
    param([Parameter(Mandatory)]$Expected)
    try {
        if (-not (Test-Path -LiteralPath "$($Expected.DriveLetter):\")) { return $false }
        $now = Get-VolumeIdentity -StickRoot "$($Expected.DriveLetter):\"
        return (Test-VolumeIdentityMatch -Expected $Expected -Actual $now)
    } catch {
        return $false
    }
}

# ---------- JSON 读取（显式 UTF-8，避免中文乱码） ----------
function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到文件: $Path" }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Read-ProviderConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    try {
        Assert-ToolboxPlainPath -Path $Path
        $result = Read-JsonFile -Path $Path
        if (-not $result.PSObject.Properties['providers'] -or -not $result.PSObject.Properties['default']) { throw 'Invalid provider structure' }
        return $result
    } catch {
        if (Test-Path -LiteralPath ($Path + '.bak')) {
            throw '供应商配置读取失败，已停止启动。保留现有文件，按接入文档从 providers.json.bak 恢复后重试。'
        }
        throw '供应商配置读取失败，已停止启动，请检查 providers.json。'
    }
}

function Assert-ToolboxPlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '配置路径含重解析点，已停止读取或写入。' }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

# ---------- 密钥读取 ----------
# 保险箱存在（含恢复痕迹）时不再回退到明文文件。密码只由调用方传入内存。
function Test-ProviderVaultPresent {
    param([Parameter(Mandatory)][string]$KeysFile)
    $vaultPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($KeysFile))) 'credentials.vault.json'
    return ((Test-Path -LiteralPath $vaultPath) -or (Test-Path -LiteralPath ($vaultPath + '.bak')) -or
        (Test-Path -LiteralPath ($vaultPath + '.tmp')) -or (Test-Path -LiteralPath ($vaultPath + '.restore.tmp')))
}

function Read-LegacyProviderSecrets {
    param([Parameter(Mandatory)][string]$KeysFile)
    $values = @{}
    Assert-ToolboxPlainPath -Path $KeysFile
    if (-not (Test-Path -LiteralPath $KeysFile)) { return $values }
    if ((Get-Item -LiteralPath $KeysFile).Length -gt 1MB) { throw '旧凭据文件过大，已停止读取。' }
    foreach ($line in [IO.File]::ReadAllLines($KeysFile, [Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { throw '旧凭据文件格式不正确，请在本机检查。' }
        $name = $t.Substring(0, $i).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') { throw '旧凭据文件含无效的变量名称。' }
        $values[$name] = $t.Substring($i + 1).Trim()
    }
    return $values
}

function Get-ProviderSecret {
    param(
        [Parameter(Mandatory)][string]$KeysFile,
        [Parameter(Mandatory)][string]$Name,
        [Security.SecureString]$VaultPassword
    )
    Assert-ToolboxPlainPath -Path $KeysFile
    if (Test-ProviderVaultPresent -KeysFile $KeysFile) {
        if (-not $VaultPassword) { throw '凭据保险箱已锁定，请交互输入主密码；不会改用旧明文密钥。' }
        $module = Join-Path $PSScriptRoot 'vault.ps1'
        if (-not (Test-Path -LiteralPath $module)) { throw '缺少保险箱模块，无法读取加密凭据。' }
        . $module
        $path = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($KeysFile))) 'credentials.vault.json'
        $opened = Read-PortableVault -Path $path -Password $VaultPassword
        try {
            if ($opened.Secrets.ContainsKey($Name)) { return [string]$opened.Secrets[$Name] }
            return $null
        } finally { $opened.Secrets.Clear() }
    }
    $values = Read-LegacyProviderSecrets -KeysFile $KeysFile
    try {
        if ($values.ContainsKey($Name)) { return $values[$Name] }
        return $null
    } finally { $values.Clear() }
}

# 判断密钥是不是还没填（占位符）
function Test-SecretIsPlaceholder {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return ($Value -match '在这里填|your.?key|placeholder|<.*>')
}

# ---------- 用 FILE_SHARE_READ|WRITE|DELETE 打开文件 ----------
# 实测：Claude 运行中也用这个模式能读到，不需要管理员、不需要卷影副本
function Open-SharedRead {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    )
}

# ---------- 删除文件/目录（只读属性也一并处理） ----------
function Remove-ItemForce {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            # 主机上可能有句柄没释放，给一次重试机会（常见于刚退出的进程）
            Start-Sleep -Milliseconds 400
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                return $true
            } catch {
                Write-Log "删不掉: $Path  ($($_.Exception.Message))" 'WARN'
                return $false
            }
        }
    }
    return $true
}

# ---------- 当前进程的真实宿主信息（必须在重定向 HOME 之前取） ----------
function Get-RealHostInfo {
    return [pscustomobject]@{
        Home = $env:USERPROFILE
        Cwd  = (Get-Location).Path
        ComputerName = $env:COMPUTERNAME
        User = $env:USERNAME
    }
}

# ---------- 构造隔离环境 ----------
# 把宿主的污染挡在外面、把自己的东西全指到会话目录/盘上。
# launch.ps1 和隔离测试共用这一个函数，避免两处逻辑漂移。
#
# ★ 只改本进程的环境变量，绝不碰宿主的注册表/PATH/配置文件
function New-IsolatedEnvironment {
    param(
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string]$WorkPath,
        [Parameter(Mandatory)][string]$RealHostUser
    )

    # 1) 显式屏蔽宿主注入的变量（防串台、防污染）
    $BlockedVars = @(
        'NODE_OPTIONS', 'NODE_PATH', 'PYTHONPATH', 'PYTHONHOME',
        'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'VIRTUAL_ENV',
        'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
        'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
        'ANTHROPIC_MODEL', 'ANTHROPIC_CONFIG_DIR',
        'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
        'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_GIT_BASH_PATH',
        'OPENAI_BASE_URL', 'OPENAI_API_KEY', 'CODEX_HOME'
    )
    $blocked = @()
    foreach ($v in $BlockedVars) {
        if (Test-Path "Env:$v") { $blocked += $v; Remove-Item "Env:$v" -Force -EA SilentlyContinue }
    }
    # 清除所有宿主 UV_* 注入，包括 UV_PROJECT_ENVIRONMENT 和 UV_CONFIG_FILE；
    # 随后建立工具箱自己的受控配置，避免不同项目共用一个全局环境。
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UV_*' })) {
        $blocked += $item.Name
        Remove-Item -LiteralPath "Env:$($item.Name)" -Force -EA SilentlyContinue
    }

    # 2) PATH 不继承主机：显式构造
    $winDir = $env:SystemRoot
    $pathParts = @(
        (Join-Path $WorkPath 'npm-global\node_modules\.bin'),
        (Join-Path $StickRoot 'runtime\node'),
        (Join-Path $StickRoot 'runtime\uv'),
        (Join-Path $StickRoot 'runtime\python'),
        (Join-Path $StickRoot 'runtime\python\Scripts'),
        (Join-Path $StickRoot 'runtime\git\cmd'),
        (Join-Path $StickRoot 'runtime\git\bin'),
        (Join-Path $StickRoot 'runtime\git\usr\bin'),
        (Join-Path $winDir 'system32'),
        $winDir,
        (Join-Path $winDir 'System32\Wbem')
    )
    $env:PATH = (($pathParts | Where-Object { $_ }) -join ';')

    # 3) ★ HOME / USERPROFILE 保持宿主原值，**不要重定向**
    #
    #    早先这里把 HOME 指到了会话目录，想堵住"~/.claude.json 被宿主读到"的口子。
    #    实测证明那是多余且有害的：
    #
    #    (a) 多余 —— .claude.json 由 CLAUDE_CONFIG_DIR 管，跟 HOME 无关。
    #        实验：HOME=homeA、CLAUDE_CONFIG_DIR=cfgX，跑完 mcp list 和一次真请求，
    #        .claude.json 落在 cfgX，homeA 里一份都没有；宿主那份哨兵文件的
    #        大小/mtime/内容一字未变。
    #
    #    (b) 有害 —— 重定向 HOME 会把所有引用 $HOME 的东西打死。典型后果：
    #        宿主 ~/.claude/settings.json 里的 hook 写的是
    #            bash "$HOME/.claude/hooks/xxx.sh"
    #        HOME 一指走，这路径就不存在了，会话一启动就报
    #            SessionStart:startup hook error ... No such file or directory
    #
    #    所以：隔离 .claude.json 靠 CLAUDE_CONFIG_DIR，不靠 HOME。
    #    这样宿主的 hooks、项目级配置、CLAUDE.md 全都能正常工作。

    # 4) 临时目录
    $tmpDir = Join-Path $WorkPath 'tmp'
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $env:TMP  = $tmpDir
    $env:TEMP = $tmpDir

    # 5) 会话目录（写本机才快）
    $configDir = Join-Path $WorkPath 'config\claude'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $env:CLAUDE_CONFIG_DIR    = $configDir
    $env:ANTHROPIC_CONFIG_DIR = $configDir

    # 6) git 配置指到会话目录，不读也不写宿主 ~/.gitconfig
    $gitCfgDir = Join-Path $WorkPath 'config\git'
    New-Item -ItemType Directory -Path $gitCfgDir -Force | Out-Null
    $gitCfg = Join-Path $gitCfgDir 'config'
    if (-not (Test-Path $gitCfg)) {
        [IO.File]::WriteAllText($gitCfg, "[user]`n`tname = $RealHostUser`n", (New-Object Text.UTF8Encoding($false)))
    }
    $env:GIT_CONFIG_GLOBAL = $gitCfg

    # 7) bash：Claude Code 的 Bash 工具靠这个变量找 shell
    $bash = Join-Path $StickRoot 'runtime\git\bin\bash.exe'
    $bashOk = Test-Path -LiteralPath $bash
    if ($bashOk) { $env:CLAUDE_CODE_GIT_BASH_PATH = $bash }

    # 8) uv：FAT32 建不了硬链接，必须 copy
    $env:UV_LINK_MODE          = 'copy'
    $env:UV_CACHE_DIR          = Join-Path $StickRoot 'cache\uv'
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $StickRoot 'runtime\python'
    $env:UV_TOOL_DIR           = Join-Path $StickRoot 'cache\uv-tools'
    $env:UV_PYTHON_DOWNLOADS   = 'never'
    $env:PYTHONNOUSERSITE      = '1'

    # 9) 盘上的 python 也要能被找到（uv 会把它当"系统 Python"）
    $portablePython = Join-Path $StickRoot 'runtime\python\python.exe'
    if (Test-Path -LiteralPath $portablePython -PathType Leaf) { $env:UV_PYTHON = $portablePython }
    else { Remove-Item Env:UV_PYTHON -EA SilentlyContinue }

    return [pscustomobject]@{
        BlockedVars = $blocked
        PathParts   = $pathParts
        ConfigDir   = $configDir
        HostHome    = $env:USERPROFILE      # 宿主原值，我们对它不做任何重定向
        BashPath    = $(if ($bashOk) { $bash } else { $null })
    }
}

# ---------- 定位 harness 的真实可执行体 ----------
# 按 pathCandidates 顺序试，返回第一个存在且体积达标的。
# ★ minBytes 是关键：FAT32 上 bin\claude.exe 会是个 500 字节的报错存根，
#   和真二进制同名同路径，只能靠体积区分。
function Resolve-HarnessExe {
    param(
        [Parameter(Mandatory)]$Harness,
        [Parameter(Mandatory)][string]$BaseDir
    )
    $min = 0
    if ($Harness.run.PSObject.Properties.Name -contains 'minBytes') { $min = [long]$Harness.run.minBytes }

    $cands = @()
    if ($Harness.run.PSObject.Properties.Name -contains 'pathCandidates') { $cands = @($Harness.run.pathCandidates) }
    elseif ($Harness.run.PSObject.Properties.Name -contains 'path')   { $cands = @($Harness.run.path) }

    $rejected = @()
    foreach ($rel in $cands) {
        $full = Join-Path $BaseDir $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $len = (Get-Item -LiteralPath $full).Length
        if ($len -ge $min) { return $full }
        $rejected += "$rel (只有 $len 字节，疑似存根)"
    }
    if ($rejected.Count -gt 0) {
        Write-Log ("候选可执行体都太小，可能是 FAT32 上 postinstall 没跑成: " + ($rejected -join '; ')) 'ERROR'
    }
    return $null
}

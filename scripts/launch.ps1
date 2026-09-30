# ============================================================
#  launch.ps1 —— 会话主控
#
#  流程：定位盘根 → 建会话目录 → 只拷选中 harness → 环境隔离
#        → 反向拉取本机历史 → 交给 guardian 启动并守护
#
#  ★ 盘符会变，一律用 $PSScriptRoot 推导，绝不写死
#  ★ 安全铁律：绝不按映像名杀进程（见 guardian.ps1）
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$WorkDir,   # 工作目录（拖拽文件夹到 AI.cmd 时由 cmd 传入）
    [switch]$Config,                              # 配置模式
    [switch]$SkipPull,                            # 跳过反向拉取（测试用）
    [switch]$NoLaunch,                            # 只做准备工作，不启动（测试用）
    [switch]$NoPrompt,                            # 不弹"选工作目录"的窗（脚本/无人值守用）
    [string]$Probe                                # 探针：在隔离环境里跑一句非交互提问，验证中转是否连通，然后退出
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'session-manager.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-provider.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-unified-mode.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot
Initialize-Log -LogDir (Join-Path $StickRoot 'logs') -Name launch

$RegistryPath  = Join-Path $StickRoot 'harness\registry.json'
$ProvidersPath = Join-Path $StickRoot 'harness\providers.json'
$KeysFile      = Join-Path $StickRoot 'config\keys.env'
$SettingsPath  = Join-Path $StickRoot 'config\settings.json'

# ---------- 读配置 ----------
$registry  = Read-JsonFile -Path $RegistryPath
$unifiedMode = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
$providers = if ($unifiedMode) { [pscustomobject]@{default='cc-switch-current';providers=@()} } else { Read-ProviderConfiguration -Path $ProvidersPath }

$userSettings = [pscustomobject]@{ lastWorkDir = ''; provider = $providers.default; ccSwitchClaudeProvider = $false }
if (Test-Path -LiteralPath $SettingsPath) {
    try {
        $userSettings = Read-JsonFile -Path $SettingsPath
    } catch {
        # ★ 不能静默吞掉。之前这里是 catch {}，结果配置文件一旦损坏就会
        #   无声降级成默认值（表现为"上次记住的目录不见了"），排查起来毫无线索。
        Write-Host ''
        Write-Host "  ！配置文件解析失败，已停止启动：" -ForegroundColor Yellow
        Write-Host "     $SettingsPath" -ForegroundColor Yellow
        Write-Host "     原因: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '     （供应商凭据单独保存在保险箱或旧 keys.env 中，不受影响）' -ForegroundColor DarkGray
        Write-Host ''
        throw 'settings.json 无法读取，已停止启动，不回退到另一套供应商。'
    }
}
if (-not $userSettings.PSObject.Properties['provider'] -or -not $userSettings.provider) {
    $userSettings | Add-Member -NotePropertyName provider -NotePropertyValue $providers.default -Force
}
if ($unifiedMode) { $userSettings | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $true -Force }
if (-not ($userSettings.PSObject.Properties.Name -contains 'ccSwitchClaudeProvider')) {
    $userSettings | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $false
} elseif ($userSettings.ccSwitchClaudeProvider -isnot [bool]) {
    throw 'settings.json ccSwitchClaudeProvider must be a JSON boolean.'
}
$script:settingsBaseline = $userSettings | ConvertTo-Json -Depth 8 | ConvertFrom-Json

function Save-UserSettings {
    param($Obj)
    function Test-SettingsProperty {
        param($Value, [string]$Name)
        if (-not $Value) { return $false }
        foreach ($candidate in $Value.PSObject.Properties) { if ($candidate.Name -eq $Name) { return $true } }
        return $false
    }
    $lockPath = $SettingsPath + '.lock'
    $lock = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $lock -and (Get-Date) -lt $deadline) {
        try { $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $lock) { throw '无法取得 settings.json 写入锁' }
    try {
        $latest = [pscustomobject]@{}
        if (Test-Path -LiteralPath $SettingsPath) { $latest = Read-JsonFile -Path $SettingsPath }
        $latestUnified = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
        $base = $script:settingsBaseline
        foreach ($prop in $Obj.PSObject.Properties) {
            $name = $prop.Name
            if ($name -eq 'workDirByHost') { continue }
            if ($latestUnified -and $name -in @('provider','ccSwitchClaudeProvider','ccSwitchUnifiedConfig')) { continue }
            $old = if (Test-SettingsProperty $base $name) { $base.$name | ConvertTo-Json -Depth 8 -Compress } else { $null }
            $new = $prop.Value | ConvertTo-Json -Depth 8 -Compress
            if ($old -ne $new) { $latest | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
        }
        if ($latestUnified) {
            $Obj | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $true -Force
            $Obj | Add-Member -NotePropertyName ccSwitchUnifiedConfig -NotePropertyValue $true -Force
        }
        if ($Obj.PSObject.Properties.Name -contains 'workDirByHost') {
            if (-not (Test-SettingsProperty $latest 'workDirByHost') -or -not $latest.workDirByHost) {
                $latest | Add-Member -NotePropertyName workDirByHost -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $oldMap = if (Test-SettingsProperty $base 'workDirByHost') { $base.workDirByHost } else { [pscustomobject]@{} }
            foreach ($p in $Obj.workDirByHost.PSObject.Properties) {
                $oldValue = if (Test-SettingsProperty $oldMap $p.Name) { [string]$oldMap.($p.Name) } else { $null }
                if ($oldValue -ne [string]$p.Value) { $latest.workDirByHost | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
            }
        }
        $tmp = $SettingsPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tmp, ($latest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $SettingsPath) { Move-Item -LiteralPath $tmp -Destination $SettingsPath -Force }
        else { Move-Item -LiteralPath $tmp -Destination $SettingsPath }
        # Baseline must track this window's in-memory state. Using the merged disk
        # state here would make a later save treat another window's fields as edits.
        $script:settingsBaseline = $Obj | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    } finally { $lock.Dispose() }
}

function Get-EnabledHarness {
    $list = @($registry.harnesses | Where-Object { $_.enabled })
    if (-not $list -or $list.Count -eq 0) { throw 'registry.json 里没有启用的 harness' }
    return $list[0]     # 原型阶段只有一个
}

# ---------- 先把宿主的真实信息抓下来 ----------
# HOME 现在不再重定向了，但工作目录/卷标识这些仍然要在这里先记下
$RealHost = Get-RealHostInfo

# 主机标识要提前算 —— 工作目录是"按主机记住"的，定目录时就要用到
$hostId = Get-HostIdentity

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  便携 AI 工具箱' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "  盘根      : $StickRoot"
Write-Host "  宿主      : $($RealHost.ComputerName) / $($RealHost.User)"
Write-Host "  宿主主目录: $($RealHost.Home)"
Write-Host ''

# ============================================================
#  配置模式菜单
# ============================================================
function Show-FolderPicker {
    param([string]$Initial)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择要让 AI 干活的目录'
        $dlg.ShowNewFolderButton = $true
        if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.SelectedPath = $Initial }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    } catch {
        Write-Log "文件夹选择框打不开（$($_.Exception.Message)），改用文字输入" 'WARN'
        $p = Read-Host '请输入目录路径'
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        return $null
    }
}

function Show-ProviderSwitcher {
    if (Get-CcSwitchUnifiedMode -StickRoot $StickRoot) { Write-Host '供应商统一在 CC Switch 中修改。'; return }
    Write-Host ''
    if ($userSettings.ccSwitchClaudeProvider) {
        Write-Host '当前 Claude 新会话使用 CC Switch USB settings.json 中的供应商；选普通供应商会关闭此模式。' -ForegroundColor Yellow
    }
    Write-Host '可用供应商：'
    $i = 1
    foreach ($p in $providers.providers) {
        $mark = if ($p.id -eq $userSettings.provider) { ' *当前*' } else { '' }
        $flag = if ($p.enabled) { '' } else { '  (未启用)' }
        Write-Host ("  {0}. {1}  [{2}]{3}{4}" -f $i, $p.name, $p.id, $flag, $mark)
        $i++
    }
    $sel = Read-Host '选择编号（回车取消）'
    if (-not $sel) { return }
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $providers.providers.Count) {
        Write-Host '无效编号' -ForegroundColor Yellow; return
    }
    $userSettings.provider = $providers.providers[$idx - 1].id
    $wasCcCurrent = [bool]$userSettings.ccSwitchClaudeProvider
    if ($userSettings.ccSwitchClaudeProvider) {
        $userSettings.ccSwitchClaudeProvider = $false
    }
    Save-UserSettings $userSettings
    if (Get-CcSwitchUnifiedMode -StickRoot $StickRoot) {
        Write-Host '另一窗口已启用 CC Switch 唯一入口；此次旧供应商选择未生效。' -ForegroundColor Yellow
        return
    }
    if ($wasCcCurrent) { Write-Host '已关闭 CC Switch 覆盖，切回工具箱保险箱/供应商配置。' -ForegroundColor Yellow }
    Write-Host "已切换为: $($userSettings.provider)" -ForegroundColor Green
}

if ($Config) {
    while ($true) {
        $unifiedMode = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
        Write-Host ''
        Write-Host '----------- 配置模式 -----------' -ForegroundColor Cyan
        Write-Host '  1. 开始使用'
        if (-not $unifiedMode) { Write-Host '  2. 安装 / 更新 harness' }
        Write-Host '  3. 选择工作目录'
        if (-not $unifiedMode) { Write-Host '  4. 切换供应商' }
        Write-Host '  5. 运行自检'
        Write-Host '  6. 测试中转连通性（真发一次请求）'
        Write-Host '  7. 退出'
        Write-Host '  8. 查看内置 Python / uv'
        if (-not $unifiedMode) { Write-Host '  9. 凭据保险箱（创建 / 迁移 / 更新 / 恢复）' }
        Write-Host ' 10. CC Switch 接入'
        Write-Host ' 11. 查看工具箱状态 / 待恢复会话'
        if (-not $unifiedMode) { Write-Host ' 12. 加密配置存档（保存 / 恢复）' }
        Write-Host '-------------------------------'
        $c = Read-Host '请选择'
        if ($unifiedMode -and $c -in @('2','4','9','12')) { Write-Host '配置统一在 CC Switch 中管理；当前版本的原生升级适配尚未接通。' -ForegroundColor Yellow; continue }

        switch ($c) {
            '1' { break }
            '2' {
                $inst = Join-Path $PSScriptRoot 'install-harness.ps1'
                if (Test-Path $inst) { & $inst } else { Write-Host '找不到 install-harness.ps1' -ForegroundColor Red }
                Read-Host '回车继续'
            }
            '3' {
                $d = Show-FolderPicker -Initial $(if ($userSettings.lastWorkDir) { $userSettings.lastWorkDir } else { $RealHost.Home })
                if ($d) {
                    # 在选的时候就拦，别等到启动才发现
                    $userCfg = Join-Path $RealHost.Home '.claude'
                    $picked  = Join-Path $d '.claude'
                    $collide = $false
                    if ((Test-Path -LiteralPath $userCfg) -and (Test-Path -LiteralPath $picked)) {
                        try {
                            $collide = ((Resolve-Path -LiteralPath $picked).Path -eq (Resolve-Path -LiteralPath $userCfg).Path)
                        } catch { }
                    }
                    if ($collide) {
                        Write-Host ''
                        Write-Host '  这个目录不能用：' -ForegroundColor Red
                        Write-Host "    $d 下的 .claude\ 就是 Claude Code 自己的用户配置目录" -ForegroundColor Red
                        Write-Host '    用它当工作目录，宿主的配置会被当项目配置加载（额外目录授权、' -ForegroundColor Red
                        Write-Host '    插件市场同步、hooks 全都会跑起来），这不是你想要的。' -ForegroundColor Red
                        Write-Host ''
                        Write-Host '    请选一个具体的项目目录，不要选宿主主目录。' -ForegroundColor Yellow
                    } else {
                        # 按主机分开记住（配置菜单跑得比 step2 早，所以这里内联写）
                        if (-not ($userSettings.PSObject.Properties.Name -contains 'workDirByHost')) {
                            $userSettings | Add-Member -NotePropertyName workDirByHost -NotePropertyValue ([pscustomobject]@{}) -Force
                        }
                        $userSettings.workDirByHost | Add-Member -NotePropertyName $hostId -NotePropertyValue $d -Force
                        Save-UserSettings $userSettings
                        Write-Host "已设为: $d" -ForegroundColor Green
                        Write-Host "  （按这台电脑记住：$hostId）" -ForegroundColor DarkGray
                        $pj = @()
                        foreach ($rel in @('.claude\settings.json', '.claude\settings.local.json', 'CLAUDE.md')) {
                            if (Test-Path -LiteralPath (Join-Path $d $rel)) { $pj += $rel }
                        }
                        if ($pj.Count -gt 0) {
                            Write-Host "  注意：该目录自带项目配置（$($pj -join ', ')），会被加载" -ForegroundColor Yellow
                            Write-Host '  Claude Code 启动时会就「是否信任该工作区」询问你' -ForegroundColor Yellow
                        }
                    }
                }
            }
            '4' { Show-ProviderSwitcher }
            '5' {
                $sc = Join-Path $PSScriptRoot 'selfcheck.ps1'
                if (Test-Path $sc) { & $sc } else { Write-Host '找不到 selfcheck.ps1' -ForegroundColor Red }
                Read-Host '回车继续'
            }
            '6' {
                # 探针要在隔离环境里跑，所以不能在菜单进程里直接跑 —— 重入自身
                $self = Join-Path $PSScriptRoot 'launch.ps1'
                & powershell -NoProfile -ExecutionPolicy Bypass -File $self `
                    -Probe 'Reply with exactly the word: PONG' -SkipPull
                Read-Host '回车继续'
            }
            '7' { Write-Host '已取消'; exit 0 }
            '8' {
                $pythonTool = Join-Path $PSScriptRoot 'python-env.ps1'
                $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $pythonTool -Action inventory -StickRoot $StickRoot
                Read-Host '回车继续' | Out-Null
            }
            '9' {
                . (Join-Path $PSScriptRoot 'vault-menu.ps1')
                Show-ToolboxVaultMenu -StickRoot $StickRoot
            }
            '10' {
                . (Join-Path $PSScriptRoot 'cc-switch-menu.ps1')
                Show-ToolboxCcSwitchMenu -StickRoot $StickRoot
                # 导入完成后重新载入非敏感供应商配置。
                $unifiedMode = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
                $providers = if ($unifiedMode) { [pscustomobject]@{default='cc-switch-current';providers=@()} } else { Read-ProviderConfiguration -Path $ProvidersPath }
                $freshSettings = [pscustomobject]@{ lastWorkDir = ''; provider = $providers.default; ccSwitchClaudeProvider = $false }
                if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) { $freshSettings = Read-JsonFile -Path $SettingsPath }
                if (-not ($freshSettings.PSObject.Properties.Name -contains 'ccSwitchClaudeProvider')) {
                    $freshSettings | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $false
                } elseif ($freshSettings.ccSwitchClaudeProvider -isnot [bool]) {
                    throw 'settings.json ccSwitchClaudeProvider must be a JSON boolean.'
                }
                $userSettings = $freshSettings
                if ($unifiedMode) { $userSettings | Add-Member -NotePropertyName ccSwitchClaudeProvider -NotePropertyValue $true -Force }
                $script:settingsBaseline = $userSettings | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            }
            '11' {
                . (Join-Path $PSScriptRoot 'toolbox-status.ps1')
                Show-ToolboxStatus -StickRoot $StickRoot -TempRoot $env:TEMP -ProjectContext @{
                    Project = $userSettings.lastWorkDir; Supplier = $userSettings.provider; Tool = (Get-EnabledHarness).name
                }
                Read-Host '回车继续' | Out-Null
            }
            '12' {
                . (Join-Path $PSScriptRoot 'portable-profile-menu.ps1')
                Show-ToolboxProfileMenu -StickRoot $StickRoot
            }
            default { Write-Host '请输入 1-12' -ForegroundColor Yellow }
        }
        if ($c -eq '1') { break }
    }
}

# ============================================================
#  1) 定 harness
# ============================================================
$h = Get-EnabledHarness
Write-Log "harness: $($h.name) ($($h.id))"

# ============================================================
#  2) 定工作目录
#
#  优先级：拖拽/参数 > 配置里选的 > **盘上的中性工作区**
#
#  ★ 不再默认到宿主主目录。原因是实测撞到的坑：
#    Claude Code 会把 <工作目录>\.claude\ 当成**项目级配置目录**加载。
#    而宿主主目录下的 .claude 恰好是它的**用户级配置目录**，
#    于是宿主的 additionalDirectories / enabledPlugins / hooks / permissions
#    全部被当项目级配置生效了。真实后果：
#      · 会话凭空获得了 d:\XXZK\... 等几个目录的访问权
#      · Claude Code 去 github 拉插件市场（网络不通）→ 满屏同步错误
#    中性工作区没有 .claude，从根上没有这个问题。
# ============================================================
$WorkspaceDir = Join-Path $StickRoot 'workspace'
if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null
}

# 判断某个目录的 .claude 是不是"宿主的用户配置目录"（而不是真项目配置）
function Test-HostUserConfigCollision {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$HostHome)
    $userCfg = Join-Path $HostHome '.claude'
    if (-not (Test-Path -LiteralPath $userCfg)) { return $false }
    try { $userCfg = (Resolve-Path -LiteralPath $userCfg).Path } catch { return $false }

    # 情况一：工作目录本身就是 <家目录>\.claude
    try {
        if ((Resolve-Path -LiteralPath $Dir).Path -eq $userCfg) { return $true }
    } catch { }

    # 情况二：工作目录下的 .claude 就是那个用户配置目录
    $sub = Join-Path $Dir '.claude'
    if (-not (Test-Path -LiteralPath $sub)) { return $false }
    try { return ((Resolve-Path -LiteralPath $sub).Path -eq $userCfg) } catch { return $false }
}

# 读这台电脑上次记住的目录（按主机标识分开存）
function Get-RememberedWorkDir {
    param($Settings, [string]$HostId)
    if ($Settings.PSObject.Properties.Name -contains 'workDirByHost') {
        $p = $Settings.workDirByHost.PSObject.Properties | Where-Object { $_.Name -eq $HostId }
        if ($p -and $p.Value) { return $p.Value }
    }
    # 兼容早期版本留下的全局 lastWorkDir
    if (($Settings.PSObject.Properties.Name -contains 'lastWorkDir') -and $Settings.lastWorkDir) {
        return $Settings.lastWorkDir
    }
    return $null
}

function Save-RememberedWorkDir {
    param($Settings, [string]$HostId, [string]$Dir)
    if (-not ($Settings.PSObject.Properties.Name -contains 'workDirByHost')) {
        $Settings | Add-Member -NotePropertyName workDirByHost -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $Settings.workDirByHost | Add-Member -NotePropertyName $HostId -NotePropertyValue $Dir -Force
    Save-UserSettings $Settings
}

$target = $null
$targetWhy = ''
$chosenExplicitly = $false

# 1) 拖拽 / 参数指定 —— 优先级最高，且总是信任（用户当场指定）
if ($WorkDir -and (Test-Path -LiteralPath $WorkDir)) {
    $target = (Resolve-Path -LiteralPath $WorkDir).Path
    $targetWhy = '拖拽/参数指定'
    $chosenExplicitly = $true
}

# 2) 取出"这台电脑上次用的目录" —— 只当默认值，**不要**直接把它当结果
#    ★ 踩过的坑：这里原来直接把 $target 填成记住的目录，结果第 3 步的提问
#      因为 "if (-not $target)" 被整段跳过 —— "每次都问"根本没生效。
$remembered = Get-RememberedWorkDir -Settings $userSettings -HostId $hostId
if ($remembered -and -not (Test-Path -LiteralPath $remembered)) {
    Write-Host "  （上次那个目录已经不在了：$remembered）" -ForegroundColor DarkGray
    Write-Log "上次记住的目录已不存在: $remembered" 'WARN'
    $remembered = $null
}

# 3) 每次都问一句 —— 回车沿用上次那个，也可以当场换
#    拖拽/参数指定时不问（那是明确指定，问了多余）
#    -NoPrompt / 测试开关下也不问，直接走兜底
$interactive = (-not $NoPrompt) -and (-not $NoLaunch) -and (-not $Probe)
if ((-not $target) -and $interactive) {
    $rememberedHint = $remembered          # 上面第 2 步已经校验过存在性
    $defaultHint    = if ($rememberedHint) { $rememberedHint } else { $WorkspaceDir }

    Write-Host ''
    Write-Host '  要处理哪个目录？' -ForegroundColor Cyan
    if ($rememberedHint) {
        Write-Host "    回车 = 沿用上次： $rememberedHint"
    } else {
        Write-Host "    回车 = 用盘上工作区： $WorkspaceDir"
    }
    Write-Host '    或直接输入/粘贴路径；输入 ? 打开文件夹选择框' -ForegroundColor DarkGray
    Write-Host '    （别选“当前用户的主目录”—— 那会跟 Claude Code 自己的配置打架，程序会拒绝）' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  > ' -NoNewline

    $answer = ''
    try { $answer = ([string](Read-Host)).Trim() } catch { $answer = '' }

    if (-not $answer) {
        # 回车：沿用上次（或盘上工作区）
        $target = $defaultHint
        if ($rememberedHint) { $targetWhy = '回车沿用上次'; $chosenExplicitly = $true }
        else                 { $targetWhy = '回车用盘上工作区' }
    }
    elseif ($answer -eq '?') {
        $picked = Show-FolderPicker -Initial $defaultHint
        if ($picked) { $target = $picked; $targetWhy = '选择框选定'; $chosenExplicitly = $true }
    }
    else {
        # 去掉路径两边可能带的引号（从资源管理器复制/拖进来常带引号）
        $clean = $answer.Trim('"').Trim("'").TrimEnd('\')
        if ($clean -and (Test-Path -LiteralPath $clean)) {
            $target = (Resolve-Path -LiteralPath $clean).Path
            $targetWhy = '手动输入'
            $chosenExplicitly = $true
        } else {
            # 输入无效 —— 明确落到"实际会用的那个"并说清楚，别口头说 A 实际用 B
            $fallback = if ($rememberedHint) { $rememberedHint } else { $WorkspaceDir }
            Write-Host ''
            Write-Host "  找不到这个目录：$clean" -ForegroundColor Red
            Write-Host "  这次先用：$fallback" -ForegroundColor Yellow
            Write-Host '  （想改可以重开一次，或用 AI设置.cmd → 「选择工作目录」）' -ForegroundColor DarkGray
            Write-Log "用户输入的目录不存在: $clean —— 退回 $fallback" 'WARN'
            $target = $fallback
            $targetWhy = if ($rememberedHint) { '上次那个（输入无效）' } else { '盘上工作区（输入无效）' }
        }
    }
}

# 4) 非交互模式（脚本/测试/-NoPrompt）下的兜底
#    有记住的就用记住的，否则用盘上的中性工作区
if (-not $target) {
    if ($remembered) {
        $target = $remembered
        $targetWhy = '这台电脑上次选的（非交互）'
    } else {
        $target = $WorkspaceDir
        $targetWhy = '盘上工作区（兜底）'
    }
}

# ★ 碰撞拦截：这不是项目配置，是宿主 Claude Code 自己的配置，加载它永远是错的。
#   实测确认：--settings 也盖不掉项目的 additionalDirectories，所以只能从源头拦。
if ($target -and (Test-HostUserConfigCollision -Dir $target -HostHome $RealHost.Home)) {
    Write-Log "工作目录 $target 的 .claude\ 就是宿主自己的用户配置目录（$($RealHost.Home)\.claude）" 'WARN'
    Write-Log '  拿它当工作目录会让宿主的配置被当项目配置加载（附加目录授权、插件市场同步、hooks）' 'WARN'
    Write-Log "  已改用盘上工作区: $WorkspaceDir" 'WARN'
    Write-Log '  要在这里干活请换一个具体项目目录，别用宿主主目录' 'WARN'
    $target = $WorkspaceDir
    $targetWhy = '盘上工作区（因碰撞被拦截）'
    $chosenExplicitly = $false      # 被拦下的选择不记住，免得每次都撞
}

# 记住这次的选择（按主机分开）
if ($chosenExplicitly -and $target -ne $WorkspaceDir) {
    try {
        Save-RememberedWorkDir -Settings $userSettings -HostId $hostId -Dir $target
        Write-Log "已按这台电脑记住工作目录: $target"
    } catch {
        Write-Log "记住工作目录失败（不影响本次使用）: $($_.Exception.Message)" 'WARN'
    }
}

Write-Log "工作目录（$targetWhy）: $target"

# 在创建大体积会话副本之前读取本窗口凭据。保险箱不会自动回退到旧明文文件。
$unifiedMode = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
$ccSwitchMode = $unifiedMode -or [bool]$userSettings.ccSwitchClaudeProvider
$ccLaunchFiles = $null
if ($ccSwitchMode) {
    if ($h.id -ne 'claude') { throw 'CC Switch 当前供应商模式仅支持 Claude Code。' }
    if ($unifiedMode) {
        . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $StickRoot
        $ccBundle = Get-CcSecureSessionClaudeLaunchBundle -StickRoot $StickRoot
        $ccLaunchFiles = $ccBundle.LaunchFiles
        $ccProfile = $ccBundle.Provider
        $ccBundle = $null
    } else { $ccProfile = Get-ToolboxCcSwitchClaudeProvider -StickRoot $StickRoot }
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ccProfile.Secret)
        $keyVal = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($ccProfile.Secret) { $ccProfile.Secret.Dispose() }
    }
    $modelProperties = [ordered]@{}
    foreach ($modelKey in $ccProfile.Models.Keys) { $modelProperties[$modelKey] = $ccProfile.Models[$modelKey] }
    $prov = [pscustomobject]@{ id = 'cc-switch-current'; name = $ccProfile.Name; baseUrl = $ccProfile.BaseUrl; apikeyEnv = $ccProfile.AuthEnvironmentName; models = [pscustomobject]$modelProperties; extraEnv = $null }
    if (Test-ToolboxCcEncryptedStorePresent -StickRoot $StickRoot) {
        Write-Log '本窗口已从解锁的 CC Switch 会话读取供应商；后续切换仅影响新窗口。'
    } else {
        Write-Log '本窗口使用旧版 CC Switch 明文配置。请从 CC Switch 菜单打开加密会话完成迁移。' 'WARN'
    }
} else {
    $prov = $providers.providers | Where-Object { $_.id -eq $userSettings.provider } | Select-Object -First 1
    if (-not $prov) { $prov = $providers.providers | Where-Object { $_.id -eq $providers.default } | Select-Object -First 1 }
    if (-not $prov) { throw '找不到可用的供应商配置。' }
    $vaultPassword = $null
    try {
        if (Test-ProviderVaultPresent -KeysFile $KeysFile) {
            if ($NoPrompt) { throw '保险箱已锁定：请正常启动并在本机输入主密码，非交互启动不会读取旧明文凭据。' }
            $vaultPassword = Read-Host '请输入本窗口的保险箱主密码' -AsSecureString
        }
        $keyVal = Get-ProviderSecret -KeysFile $KeysFile -Name $prov.apikeyEnv -VaultPassword $vaultPassword
    } finally { if ($vaultPassword) { $vaultPassword.Dispose(); $vaultPassword = $null } }
    $keyMissing = Test-SecretIsPlaceholder -Value $keyVal
    if ($keyMissing) { throw '当前供应商没有可用凭据。请到 AI设置 → 凭据保险箱添加对应密钥；尚未启用保险箱时可编辑旧 keys.env。' }
}

# 透明化：这个目录带了哪些项目级配置，让用户知情
$projCfg = @()
foreach ($rel in @('.claude\settings.json', '.claude\settings.local.json', 'CLAUDE.md', '.claude\skills')) {
    $p = Join-Path $target $rel
    if (Test-Path -LiteralPath $p) { $projCfg += $rel }
}
if ($projCfg.Count -gt 0) {
    Write-Log "该目录自带项目级配置（会被加载）: $($projCfg -join ', ')" 'WARN'
    if ($projCfg -match 'settings.json|settings.local.json') {
        Write-Log '  注意：项目配置可以授权项目外的目录、并定义启动时执行的 hook' 'WARN'
        Write-Log '  Claude Code 会就「是否信任该工作区」弹窗询问；不信任就别继续' 'WARN'
    }
}

# ============================================================
#  3) 建会话目录（随机名，避免可预测）
# ============================================================
$sessionId = [guid]::NewGuid().ToString()
$sessionTempRoot = [IO.Path]::GetFullPath($env:TEMP)
$SessionRoot = Join-Path $sessionTempRoot "aistick-$sessionId"
$WorkPath    = Join-Path $SessionRoot 'work'
$GuardPath   = Join-Path $SessionRoot 'guard'
$sessionLock = $null
$preserveSession = $false
$activeApiKeyEnv = $null

try {
New-Item -ItemType Directory -Path $WorkPath, $GuardPath -Force | Out-Null
Write-Log "会话目录: $SessionRoot"
New-SessionRegistration -SessionRoot $SessionRoot -SessionId $sessionId -TempRoot $sessionTempRoot | Out-Null
$sessionLock = Open-SessionLock -SessionRoot $SessionRoot

# 扫孤儿目录：上次守护被强杀时留下的。
# ★ 删任何东西之前先验证它**确实是个会话目录**（必须有 work\ 和 guard\ 结构），
#   不能只按 aistick-* 前缀就动手 —— 否则会误删同前缀的无关目录
#   （实测踩过：我的拔盘对照工具目录就被这条规则盯上过）
Write-Log '清扫上次残留的孤儿会话目录...'
$sweptOrphans = 0
try { $sweptOrphans = Remove-StaleOwnedSessions -TempRoot $sessionTempRoot -CurrentSessionRoot $SessionRoot }
catch { Write-Log "孤儿扫描失败（保留未确认目录）: $($_.Exception.Message)" 'WARN' }
Write-Log "  清扫了 $sweptOrphans 个孤儿目录"

# ============================================================
#  4) 只拷选中的 harness 到会话目录
# ============================================================
Write-Log '拷贝 harness 到会话目录（只拷选中的，别的不动）...'
$managedClaudeVersion = $null
$managedClaudeSlotsRoot = Join-Path $StickRoot 'tools\harness\claude\slots'
$hasManagedClaudeSlots = $false
if (Test-Path -LiteralPath $managedClaudeSlotsRoot -PathType Container) {
    foreach ($candidateSlot in (Get-ChildItem -LiteralPath $managedClaudeSlotsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $candidateSidecar = Join-Path $managedClaudeSlotsRoot ($candidateSlot.Name + '.manifest.json')
        if ($candidateSlot.Name -match '^\d+\.\d+\.\d+$' -and (Test-Path -LiteralPath $candidateSidecar -PathType Leaf)) { $hasManagedClaudeSlots = $true; break }
    }
}
if ($unifiedMode -and $h.id -eq 'claude' -and $hasManagedClaudeSlots) {
    . (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
    $managedClaudeVersion = Resolve-CcManagedClaudeVersionSlot -UsbRoot $StickRoot
}
$copied = 0
foreach ($rel in @($h.copyToHost)) {
    if ($managedClaudeVersion) {
        Write-Log '已发现已验证公共版本槽；跳过 registry 中的旧 Claude 包路径。'
        continue
    }
    $src = Join-Path $StickRoot $rel
    if (-not (Test-Path -LiteralPath $src)) { throw "registry 里声明的 $rel 不存在，请先运行 install-harness.ps1" }
    $dst = Join-Path $WorkPath $rel
    $d = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    $copied++
}
Write-Log "已拷 $copied 项" 'OK'
$managedClaudeExe = $null
if ($managedClaudeVersion) {
    $managedSessionHarnessRoot = Join-Path $WorkPath 'managed-harness'
    $managedSessionSlots = Join-Path $managedSessionHarnessRoot 'slots'
    [IO.Directory]::CreateDirectory($managedSessionSlots) | Out-Null
    Copy-CcSwitchManagedHarnessTree -Source $managedClaudeVersion.Path -Destination (Join-Path $managedSessionSlots $managedClaudeVersion.SlotId)
    $managedSessionSlot = Test-CcSwitchManagedClaudeSlot -ManagedHarnessRoot $managedSessionHarnessRoot -SlotId $managedClaudeVersion.SlotId
    $publicManifest = Join-Path (Split-Path -Parent $managedClaudeVersion.Path) ($managedClaudeVersion.Version + '.manifest.json')
    if (-not $managedSessionSlot.Valid -or $managedSessionSlot.PackageVersion -cne $managedClaudeVersion.Version -or -not (Test-CcSwitchManagedClaudeHashManifest -SlotPath $managedSessionSlot.SlotPath -ManifestPath $publicManifest)) { throw '复制到本次会话的 Claude 公共版本槽未通过 package/hash 清单验证。' }
    $managedClaudeExe = [string]$managedSessionSlot.ExecutablePath
    Write-Log ("Claude Code 版本槽已验证并复制到本次 NTFS 会话：" + $managedClaudeVersion.Version)
}

# 守护相关的小文件也拷过去 —— 这样拔盘后它们仍然可执行
foreach ($f in @('lib.ps1', 'guardian.ps1', 'sync.ps1', 'session-manager.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $GuardPath $f) -Force
}

# ============================================================
# ============================================================
#  5) 环境隔离
# ============================================================
Write-Log '构造隔离环境...'

$iso = New-IsolatedEnvironment -StickRoot $StickRoot -WorkPath $WorkPath -RealHostUser $RealHost.User

# ★ 把函数返回的会话目录接回来。
#   重构时踩过：这几行原本在块 5 里直接定义，搬进函数后忘了在外面赋值，
#   结果反向拉取静默失败（被 catch 成 WARN），守护启动时直接抛
#   "The variable '$ConfigDir' cannot be retrieved" —— 整个会话起不来。
$ConfigDir = $iso.ConfigDir

# 立刻校验，别把这个错误拖到后面 —— 否则会被后面的 catch 吞成
# "反向拉取失败"之类的误导性 WARN，真因（变量没接回来）根本看不出来
if ([string]::IsNullOrWhiteSpace($ConfigDir) -or -not (Test-Path -LiteralPath $ConfigDir)) {
    throw "隔离环境没建好：会话配置目录无效（'$ConfigDir'）。这是脚本 bug，不是环境问题。"
}

# The helpers are loaded only for launch, not by the detached guardian.
# Pass parameters explicitly: dot-sourced script parameters share this scope.
. (Join-Path $PSScriptRoot 'python-env.ps1') -StickRoot $StickRoot -WorkPath $WorkPath -ProjectPath $target
. (Join-Path $PSScriptRoot 'python-session.ps1')
$pythonState = Initialize-PortablePythonEnvironment -StickRoot $StickRoot -WorkPath $WorkPath -ProjectPath $target
$projectPython = Set-PortablePythonSession -State $pythonState -StickRoot $StickRoot -WorkPath $WorkPath
if ($projectPython) {
    $pythonLevel = if ($pythonState.DependenciesPending) { 'WARN' } else { 'OK' }
    Write-Log ("Python: " + $pythonState.Message) $pythonLevel
    Write-Log "本项目 Python: $projectPython"
} else {
    Write-Log ("Python 不可用（AI 仍可启动）: " + $pythonState.Message) 'WARN'
}

if ($iso.BlockedVars.Count -gt 0) {
    Write-Log "已屏蔽宿主注入的变量（$($iso.BlockedVars.Count) 个）: $($iso.BlockedVars -join ', ')" 'WARN'
} else {
    Write-Log '宿主没有注入需要屏蔽的变量'
}
Write-Log 'PATH 已重写为纯盘上路径 + 最小系统路径（宿主 PATH 未继承）'
Write-Log "会话目录（配置/会话都写这里）: $($iso.ConfigDir)"
Write-Log "HOME 保持宿主原值（不重定向 —— 否则宿主的 hooks 会找不到文件）: $($iso.HostHome)"
if ($iso.BashPath) {
    Write-Log "bash 已指定: $($iso.BashPath)"
} else {
    Write-Log '找不到盘上的 bash.exe —— Claude Code 的 Bash 工具可能不可用' 'WARN'
}
# ============================================================
#  6) 注入供应商配置（密钥走环境变量，不落宿主磁盘）
# ============================================================
if ($ccSwitchMode) { Write-Log "供应商: CC Switch 当前 Claude 设置 ($($prov.baseUrl))" }
else { Write-Log "供应商: $($prov.name) ($($prov.id))" }

$pe = $h.providerEnv
$activeApiKeyEnv = if ($ccSwitchMode) { $prov.apikeyEnv } else { $pe.apiKey }
Set-Item -Path "Env:$($pe.baseUrl)" -Value $prov.baseUrl
Set-Item -Path "Env:$activeApiKeyEnv" -Value $keyVal
$keyVal = $null
Write-Log "本窗口凭据已注入 $activeApiKeyEnv" 'OK'

foreach ($p in $prov.models.PSObject.Properties) {
    if ($p.Value) { Set-Item -Path "Env:$($p.Name)" -Value $p.Value }
}
if ($prov.extraEnv) {
    foreach ($p in $prov.extraEnv.PSObject.Properties) { Set-Item -Path "Env:$($p.Name)" -Value $p.Value }
}
# harness 自带的固定 env
if (-not $unifiedMode -and $h.env) {
    foreach ($p in $h.env.PSObject.Properties) { Set-Item -Path "Env:$($p.Name)" -Value $p.Value }
}

# ============================================================
#  7) 反向拉取（只拉本机自己的）
# ============================================================
# $hostId 已经在前面算过了（定工作目录时要按主机查），这里直接用
$sessionsHostDir = Join-Path $StickRoot "sessions\$hostId"
$sessionsHarnessDir = Join-Path $sessionsHostDir $h.id
$runArchiveDir = Join-Path (Join-Path $sessionsHarnessDir 'runs') $sessionId
$sessionsDir = $sessionsHarnessDir
$projName = ($target -replace '[^a-zA-Z0-9]', '-')
Write-Log "主机标识: $hostId"

if ($SkipPull) {
    Write-Log '按要求跳过反向拉取'
} else {
    Write-Log "反向拉取（只拉本机自己的，当前项目: $projName）..."
    try {
        $pullResult = @(& (Join-Path $PSScriptRoot 'sync.ps1') -SourceDir $ConfigDir -SessionsDir $sessionsHarnessDir `
            -Direction Pull -ArchiveSet -LegacySessionsDir $sessionsHostDir `
            -TargetDir $ConfigDir -ProjectName $projName -Quiet)
        $pullStats = if ($pullResult.Count -gt 0) { $pullResult[-1] } else { $null }
        if ($pullStats -and [int]$pullStats.failed -gt 0) {
            Write-Log "反向拉取有部分失败: 失败 $($pullStats.failed)，冲突 $($pullStats.conflicts)；本次归档仍独立" 'WARN'
        } else {
            Write-Log '反向拉取完成；本次写入独立 session archive' 'OK'
        }
    } catch {
        Write-Log "反向拉取失败（不影响使用）: $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================
#  8) 定位卷标识（认卷，不认盘符）
# ============================================================
$vol = Get-VolumeIdentity -StickRoot $StickRoot
Write-Log "卷标识: GUID=$($vol.VolumeGuid) 序列号=$($vol.Serial)"

# ============================================================
#  9) 组装启动参数，交给 guardian
# ============================================================
# 用体积达标的候选（FAT32 上首选路径可能是 500 字节的报错存根）
$exePath = if ($managedClaudeExe) { $managedClaudeExe } else { Resolve-HarnessExe -Harness $h -BaseDir $WorkPath }
if (-not $exePath) {
    Write-Log '在会话目录里找不到可运行的可执行体（体积都不达标）' 'ERROR'
    Write-Host '请先运行 AI设置.cmd → 「安装 / 更新 harness」' -ForegroundColor Yellow
    Read-Host '回车退出'
    exit 1
}
Write-Log "可执行体: $exePath"

$hArgs = @()
if ($unifiedMode) {
    . (Join-Path $PSScriptRoot 'cc-switch-claude-launch-files.ps1')
    $null = Set-CcClaudeLaunchFiles -Files $ccLaunchFiles -ConfigDir $ConfigDir -SessionRoot $SessionRoot
    $ccLaunchFiles = $null
    Write-Log '已载入 CC Switch 保存的 Claude 配置。'
} elseif ($h.settingsFile) {
    $settingsAbs = Join-Path $StickRoot $h.settingsFile
    if (Test-Path -LiteralPath $settingsAbs) {
        $hArgs += '--settings'
        $hArgs += $settingsAbs
        Write-Log "settings 从盘上直接读（不拷进主机）: $settingsAbs"
    } else {
        Write-Log "找不到 settings 文件: $settingsAbs（继续，用默认设置）" 'WARN'
    }
}

Write-Host ''
Write-Log "准备就绪。启动 $($h.name) ..." 'OK'
Write-Host "  工作目录  : $target"
Write-Host "  harness   : $exePath"
Write-Host "  会话目录  : $SessionRoot"
Write-Host "  会话归档  : $sessionsDir"
Write-Host ''
Write-Host '  正常退出并等待保存完成后再拔盘；意外拔盘会触发进程清理，未保存内容可能丢失。' -ForegroundColor DarkGray
Write-Host ''

if ($NoLaunch) {
    Write-Log '（NoLaunch：只做准备工作，不真正启动）' 'WARN'
    $preserveSession = $true
    Write-Host "会话目录保留: $SessionRoot" -ForegroundColor Yellow
    exit 0
}

# ============================================================
#  探针模式：在完全隔离的环境里问一句，验证中转真的通
#  这是唯一能证明"密钥 + 中转 + 模型映射"三者同时正确的办法
# ============================================================
if ($Probe) {
    Write-Host ''
    Write-Log "探针：在隔离环境里执行 $($h.name) -p `"$Probe`" ..." 'OK'

    # ★ 判断成败要看 **stdout**，不能看"有没有 stderr 输出"。
    #   实测教训：这个中转会往 stderr 打一行无害提示
    #     [claude-code:unrecognized_model] {"model":"...","query_source":"sdk"}
    #   但请求其实成功了。早先的写法把 stderr 当失败，误判成"中转不通"。
    $errFile = [IO.Path]::GetTempFileName()
    $exitCode = 0
    $out = @()          # StrictMode 下必须先初始化，否则下面读取会报"变量未设置"
    $exMsg = ''
    try {
        # 原生命令往 stderr 写字时，$ErrorActionPreference='Stop' 会把它变成
        # 终止性错误。这里临时放开，避免把"中转的提示信息"当成失败。
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # 给一个空 stdin，免得它等 3 秒超时（-p 的提示词已由参数给出）
            $out = @('' | & $exePath '-p' $Probe 2>$errFile)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
    } catch {
        $exitCode = -1
        $exMsg = $_.Exception.Message
    }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) {
        $errText = [IO.File]::ReadAllText($errFile)
        Remove-Item -LiteralPath $errFile -Force -EA SilentlyContinue
    }

    $answer = ($out -join "`n").Trim()
    Write-Host ''
    if ($answer) {
        Write-Host '--- 模型回复 ---' -ForegroundColor Green
        foreach ($l in $out) { Write-Host ("  " + $l) }
        Write-Host '----------------' -ForegroundColor Green
        Write-Log '探针成功：中转连通、密钥有效、模型可用' 'OK'
    } else {
        Write-Host '--- 没有拿到回复 ---' -ForegroundColor Red
        if ($exMsg) { Write-Host ("  异常: " + $exMsg) -ForegroundColor Red }
        if ($errText) {
            Write-Host '  错误输出:' -ForegroundColor Red
            foreach ($l in ($errText -split "`n" | Select-Object -First 6)) { Write-Host ("    " + $l) -ForegroundColor Red }
        }
        Write-Log "探针失败（退出码 $exitCode）" 'ERROR'
        Write-Host ''
        Write-Host '可能的原因：' -ForegroundColor Yellow
        Write-Host "  · 密钥无效或过期（$KeysFile）"
        Write-Host '  · 中转地址不对（harness\providers.json）'
        Write-Host '  · 网络不通（这台机器需要代理吗？）'
        Write-Host '  · 模型名不被该中转支持（providers.json 里的 models）'
    }
    # 即使成功，也把 stderr 里那条常见提示说清楚，免得下次又误判
    if ($answer -and $errText -and $errText -match 'unrecognized_model') {
        Write-Host ''
        Write-Host '  注：stderr 里那条 unrecognized_model 是提示不是错误，' -ForegroundColor DarkGray
        Write-Host '      该中转对 SDK 来源的模型名会打这行，请求本身是成功的。' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

$guardian = Join-Path $GuardPath 'guardian.ps1'
& $guardian `
    -StickRoot      $StickRoot `
    -SessionRoot    $SessionRoot `
    -GuardDir       $GuardPath `
    -DriveLetter    $vol.DriveLetter `
    -VolumeGuid     $vol.VolumeGuid `
    -Serial         $vol.Serial `
    -HarnessExe     $exePath `
    -WorkingDir     $target `
    -HarnessArgs    $hArgs `
    -SessionsDir    $runArchiveDir `
    -SourceDir      $ConfigDir `
    -ProjectName    $projName `
    -SessionLock    $sessionLock `
    -SyncSeconds    30 `
    -SessionId      $sessionId

exit $LASTEXITCODE
} finally {
    $keyVal = $null
    if ($activeApiKeyEnv) { Remove-Item -LiteralPath ("Env:" + $activeApiKeyEnv) -ErrorAction SilentlyContinue }
    if ($ccSwitchMode -and $h -and $h.providerEnv -and $h.providerEnv.apiKey -ne $activeApiKeyEnv) { Remove-Item -LiteralPath ("Env:" + $h.providerEnv.apiKey) -ErrorAction SilentlyContinue }
    if ($sessionLock) { $sessionLock.Dispose(); $sessionLock = $null }
    if (-not $preserveSession -and $sessionId) {
        try {
            Remove-OwnedSessionDirectory -SessionRoot $SessionRoot -TempRoot $sessionTempRoot `
                -SessionId $sessionId -AllowActiveOwner | Out-Null
        } catch { Write-Log "会话目录安全清理失败: $($_.Exception.Message)" 'WARN' }
    }
}

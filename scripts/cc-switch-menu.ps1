# Provider integration and the verified, isolated upstream GUI entry point.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'vault.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-provider.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-unified-mode.ps1')

function Import-ToolboxCcSwitchProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    if (Get-CcSwitchUnifiedMode -StickRoot $StickRoot) { throw '配置已统一由 CC Switch 管理，旧保险箱导入入口已停用。' }
    $profile = & (Join-Path $PSScriptRoot 'cc-switch.ps1') -Action ReadClaudeProfile -ProfilePath $ProfilePath -ProfileName $Name
    $providerPath = Join-Path $StickRoot 'harness\providers.json'
    $vaultPath = Join-Path $StickRoot 'config\credentials.vault.json'
    $lock = $null; $opened = $null; $tempPath = $null
    try {
        foreach ($checked in @($providerPath, ($providerPath + '.lock'), ($providerPath + '.bak'))) {
            Assert-ToolboxPlainPath -Path $checked
        }
        $lock = New-Object IO.FileStream(($providerPath + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if ((Get-Item -LiteralPath $providerPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '供应商配置不能使用重解析路径。' }
        $beforeHash = (Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash
        try { $providers = [IO.File]::ReadAllText($providerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw '供应商配置格式无效，导入已停止。' }
        if (-not $providers.PSObject.Properties['providers'] -or -not $providers.PSObject.Properties['default']) { throw '供应商配置缺少必要字段。' }
        $opened = Read-PortableVault -Path $vaultPath -Password $Password
        $suffix = [guid]::NewGuid().ToString('N')
        $id = 'cc-' + $suffix
        $keyName = 'CCSWITCH_' + $suffix.ToUpperInvariant()
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($profile.Secret)
        try { $opened.Secrets[$keyName] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        # Commit the secret first. A metadata write failure may leave an unused
        # encrypted entry, but never creates a provider with a missing secret.
        $null = Write-PortableVault -Path $vaultPath -Password $Password -Secrets $opened.Secrets -ExpectedRevision $opened.Revision
        $newProvider = [pscustomobject]@{
            id = $id; name = $profile.Name; enabled = $true
            baseUrl = $profile.BaseUrl; apikeyEnv = $keyName
            models = $profile.Models; extraEnv = [pscustomobject]@{}
        }
        $providers.providers = @($providers.providers) + @($newProvider)
        if ((Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash -ne $beforeHash) { throw '供应商配置已被其他进程修改，请重新导入。' }
        $tempPath = $providerPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tempPath, ($providers | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($false)))
        # Same-volume rename avoids in-place partial JSON. Keep a valid previous
        # file for recovery if the process ends between the two rename calls.
        $newHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash
        $backupPath = $providerPath + '.bak'
        if (Test-Path -LiteralPath $backupPath) {
            $backupInfo = Get-Item -LiteralPath $backupPath -Force
            if ($backupInfo.PSIsContainer -or ($backupInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '供应商备份路径异常，已停止提交。' }
            [IO.File]::Delete($backupPath)
        }
        [IO.File]::Move($providerPath, $backupPath)
        try {
            [IO.File]::Move($tempPath, $providerPath)
            if ((Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash -ne $newHash) { throw 'Provider checksum mismatch' }
        } catch {
            if (-not (Test-Path -LiteralPath $providerPath)) { [IO.File]::Copy($backupPath, $providerPath, $false) }
            throw '供应商提交失败，旧版 .bak 已保留，请按接入文档恢复。'
        }
        return [pscustomobject]@{ Id = $id; Name = $newProvider.name; KeyReference = $keyName }
    } finally {
        if ($opened) { $opened.Secrets.Clear() }
        if ($profile -and $profile.Secret) { $profile.Secret.Dispose() }
        if ($lock) { $lock.Dispose() }
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Show-ToolboxCcSwitchMenu {
    param([Parameter(Mandatory)][string]$StickRoot)
    $module = Join-Path $PSScriptRoot 'cc-switch.ps1'
    $packageRoot = Join-Path $StickRoot 'tools\cc-switch'
    while ($true) {
        $unifiedMode = Get-CcSwitchUnifiedMode -StickRoot $StickRoot
        Write-Host ''
        Write-Host '--- CC Switch 接入 ---' -ForegroundColor Cyan
        Write-Host '供应商配置从 U 盘读取，不接管本机安装的 AI 工具。'
        Write-Host '原生窗口通过盘内隔离启动器运行，可与本机 CC Switch 同时使用。'
        try {
            $useCcCurrent = Get-ToolboxCcSwitchClaudeMode -StickRoot $StickRoot
            Write-Host $(if ($useCcCurrent) { '新 Claude 窗口：使用 CC Switch 当前供应商。' } else { '新 Claude 窗口：使用工具箱供应商 / 保险箱。' })
        } catch { Write-Host '供应商模式设置异常，请先检查 config\settings.json。' -ForegroundColor Yellow }
        Write-Host '  1. 查看包状态'
        Write-Host '  2. 校验 / 准备官方便携 ZIP'
        if (-not $unifiedMode) {
            Write-Host '  3. 从选定的 Claude settings JSON 导入供应商到保险箱（旧入口）'
            Write-Host '  4. 新 Claude 窗口使用盘内 CC Switch 当前供应商'
            Write-Host '  5. 切回工具箱供应商 / 保险箱'
        }
        Write-Host '  6. 解锁 / 打开原生 CC Switch（隔离离线）'
        Write-Host '  7. 锁定 CC Switch 会话'
        Write-Host '  8. 解锁 / 打开原生 CC Switch（隔离联网）'
        if (-not $unifiedMode) {
            Write-Host '  9. 一次性迁移工具箱配置到 CC Switch'
            Write-Host ' 10. 核对迁移后，启用 CC Switch 唯一配置入口'
        } else { Write-Host '配置已统一由 CC Switch 管理；Claude 原生升级与 U 盘版本保存已通过验证，其他 harness 尚待验收。' }
        Write-Host '  0. 返回'
        $choice = Read-Host '请选择'
        if ($choice -eq '0' -or -not $choice) { return }
        if ($unifiedMode -and $choice -in @('3','4','5','9','10')) { Write-Host '配置已统一由 CC Switch 管理，旧入口已停用。' -ForegroundColor Yellow; continue }
        $password = $null
        try {
            switch ($choice) {
                '1' {
                    $status = & (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action Status -StickRoot $StickRoot
                    Write-Host ("启动状态：{0}；详情见 docs\CC-Switch原生接入验收.md。" -f $status.Status)
                    foreach ($reason in @($status.Reasons)) { Write-Host $reason -ForegroundColor Yellow }
                    . (Join-Path $PSScriptRoot 'cc-switch-encrypted-store.ps1')
                    $encrypted = Get-CcEncryptedStoreStatus -StickRoot $StickRoot
                    $stateNames = @{Absent='尚未创建';Ready='已创建，尚无快照';Locked='已有加密快照';RecoveryRequired='需要恢复，已停止自动写入';Corrupt='校验失败，已停止自动写入'}
                    Write-Host ('加密存储：' + $stateNames[$encrypted.State])
                    if (Test-ToolboxCcEncryptedStorePresent -StickRoot $StickRoot) {
                        try {
                            . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $StickRoot
                            $broker = Get-CcSecureSessionStatus -StickRoot $StickRoot
                            Write-Host ('解锁会话：运行中；原生窗口：' + $(if ($broker.GuiRunning) {'运行中'} else {'已关闭'}))
                            Write-Host ('最近保存状态：' + $broker.LastSaveStatus)
                            Write-Host ('网络模式：' + $(if ($broker.NetworkMode -eq 'InternetClient') {'联网直连'} else {'离线'}))
                        } catch { Write-Host '解锁会话：未连接，请选择 6 解锁。' }
                    }
                }
                '2' {
                    $archive = Read-Host '官方便携 ZIP 的完整路径（回车取消）'
                    if (-not $archive) { continue }
                    $null = & $module -Action Prepare -PackageRoot $packageRoot -ArchivePath $archive
                    Write-Host '官方包已准备。选择 6 启动前还会检查隔离组件和自带运行环境。' -ForegroundColor Green
                }
                '3' {
                    Write-Host '仅导入所选 JSON 的供应商字段；不接受 SQL 备份或本地代理占位配置。'
                    Write-Host '请先在保险箱菜单创建 / 迁移凭据。原 JSON 是明文来源，导入不会替你删除。' -ForegroundColor Yellow
                    $profilePath = Read-Host '选择的 Claude settings JSON 完整路径（回车取消）'
                    if (-not $profilePath) { continue }
                    $name = Read-Host '给这个供应商起一个名称'
                    $password = Read-Host '本工具箱保险箱的主密码' -AsSecureString
                    $result = Import-ToolboxCcSwitchProvider -StickRoot $StickRoot -ProfilePath $profilePath -Name $name -Password $password
                    Write-Host ('已导入：{0}。返回后在「切换供应商」中选择，新窗口生效。' -f $result.Name) -ForegroundColor Green
                }
                '4' {
                    Write-Host '加密模式需要先选择 6 解锁；每个新窗口读取最近保存的 CC Switch 供应商。'
                    if (-not (Test-ToolboxCcEncryptedStorePresent -StickRoot $StickRoot)) {
                        Write-Host '尚未迁移：现有 CC Switch 配置仍是明文。选择 6 可创建加密存储。' -ForegroundColor Yellow
                    }
                    $currentProfile = Get-ToolboxCcSwitchClaudeProvider -StickRoot $StickRoot
                    try { Set-ToolboxCcSwitchClaudeMode -StickRoot $StickRoot -Enabled $true }
                    finally { if ($currentProfile.Secret) { $currentProfile.Secret.Dispose() } }
                    Write-Host '已启用。每个新 Claude 窗口读取当前供应商，已运行的窗口不变。' -ForegroundColor Green
                }
                '5' {
                    Set-ToolboxCcSwitchClaudeMode -StickRoot $StickRoot -Enabled $false
                    Write-Host '已切回工具箱供应商 / 保险箱，新窗口生效。' -ForegroundColor Green
                }
                '6' {
                    Write-Host '正在校验并准备独立窗口，首次准备可能稍慢。'
                    Write-Host '首次需创建主密码并迁移旧配置。此入口离线；CC About 更新检查请选择 8。Claude 新版安装及版本槽切换仍在验证。' -ForegroundColor Yellow
                    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action SecureManager -StickRoot $StickRoot
                    if ($LASTEXITCODE -ne 0) { Write-Host '隔离窗口未正常完成，请查看上方原因和恢复位置。' -ForegroundColor Yellow }
                }
                '7' {
                    . (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $StickRoot
                    $lockResult = Lock-CcSecureSession -StickRoot $StickRoot
                    if (Test-CcSecureSessionNoSessionResult $lockResult) { Write-Host '当前没有活动的加密会话，无需锁定。' -ForegroundColor Green }
                    else { Write-Host '已请求保存并锁定。已启动的 harness 窗口仍使用各自启动时的供应商。' -ForegroundColor Green }
                }
                '8' {
                    Write-Host '正在准备独立联网窗口，可检测供应商连通性。'
                    Write-Host '此窗口不自动使用本机系统代理。切换联网 / 离线前，请先选择 7 锁定当前会话。'
                    Write-Host 'CC About 更新请求已接入受控检查；Claude 新版安装及 USB 版本槽切换仍未完成真实验收。联网成功不代表密钥或模型调用成功。' -ForegroundColor Yellow
                    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action SecureManager -StickRoot $StickRoot -NetworkMode InternetClient
                    if ($LASTEXITCODE -ne 0) { Write-Host '联网窗口未正常启动，请查看上方原因。' -ForegroundColor Yellow }
                }
                '9' {
                    Write-Host '将把工具箱供应商和 Claude 设置导入 CC Switch 加密配置；旧文件保留。请先锁定已有会话。'
                    $engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'cc-switch-isolated.ps1') -Action SecureManager -StickRoot $StickRoot -NetworkMode InternetClient -ImportToolboxBeforeLaunch
                    if($LASTEXITCODE -ne 0){throw '迁移会话未能启动。'}
                }
                '10' {
                    $null=Enable-CcSwitchUnifiedMode -StickRoot $StickRoot
                    Write-Host '已统一为 CC Switch 配置入口；新 Claude 会话不再使用旧供应商、保险箱或旧 settings 文件。' -ForegroundColor Green
                }
                default { Write-Host '请选择当前显示的编号。' -ForegroundColor Yellow }
            }
        } catch {
            $safeStatePrefixes=@('加密会话管道仍在运行，但安全定位文件缺失','Secure session host is still running but its pipe is unavailable','Secure session locator path contains a reparse point','Secure session locator ACL is inheritable','Secure session locator ACL grants access','Secure session locator does not match this volume root','Secure session locator exceeds the fixed size limit')
            $message=[string]$_.Exception.Message
            $isSafeState=$false
            foreach($prefix in $safeStatePrefixes){if($message.StartsWith($prefix,[StringComparison]::Ordinal)){$isSafeState=$true;break}}
            if($isSafeState){Write-Host ('会话状态异常：'+$message) -ForegroundColor Yellow}
            else { Write-Host '操作未完成：请检查包校验、会话解锁及配置状态。加密会话不可用时不会回退读取旧明文。' -ForegroundColor Yellow }
        }
        finally { if ($password) { $password.Dispose() } }
    }
}

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$StickRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Load the existing authenticated broker client and its protected-locator checks.
. (Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot $StickRoot

function Start-CcSwitchStartupManager {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher = Join-Path $PSScriptRoot 'cc-switch-isolated.ps1'
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw '找不到 Windows PowerShell 5.1，无法打开 CC Switch 解锁窗口。' }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw '缺少 CC Switch 隔离启动器；未尝试读取其他配置。' }

    & $engine -NoProfile -ExecutionPolicy Bypass -File $launcher -Action SecureManager -StickRoot $Root -NetworkMode InternetClient
    if ($LASTEXITCODE -ne 0) { throw 'CC Switch 解锁窗口未能启动；请在 AI设置 → CC Switch 接入 → 8 手动解锁后重试。' }
}

function Get-CcSwitchStartupSessionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $pipeName = Get-CcSecurePipeName $Root
    $locatorPath = Get-CcSecureLocatorPath $pipeName
    $locatorExists = [IO.File]::Exists($locatorPath)
    $pipeExists = Test-CcSecureSessionPipeAvailable -StickRoot $Root -PipeName $pipeName

    if ($pipeExists) {
        if (-not $locatorExists) {
            throw '检测到 CC Switch 管道但缺少安全定位文件。为避免连接到未认证会话或启动重复实例，请关闭该会话窗口后再试。'
        }

        # This call validates locator path, ACL, process identity/start time, pipe
        # server PID, and the authenticated broker reply. Let every failure escape.
        $status = Get-CcSecureSessionStatus -StickRoot $Root
        if ($status.Unlocked -isnot [bool]) { throw 'CC Switch 返回了无效的解锁状态；已停止启动。' }
        return [pscustomobject]@{ State = if ($status.Unlocked) { 'Unlocked' } else { 'Locked' }; Status = $status }
    }

    if ($locatorExists) {
        # Validate that this is genuinely stale before allowing the existing
        # secure manager to replace it. ACL/PID/reparse errors remain fatal.
        Assert-CcSecureSessionStaleLocator -StickRoot $Root -PipeName $pipeName -LocatorPath $locatorPath | Out-Null
    }
    return [pscustomobject]@{ State = 'Absent'; Status = $null }
}

function Ensure-CcSwitchStartupSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][bool]$Interactive
    )

    if (-not $Interactive) {
        throw 'CC Switch 尚未解锁。请双击 AI设置.cmd → 10「CC Switch 接入」→ 8「解锁 / 打开原生 CC Switch（隔离联网）」完成本机解锁，再重新启动。未读取其他配置。'
    }

    $startedByThisCall = $false
    $launchCount = 0
    $maxChecks = 3
    for ($check = 1; $check -le $maxChecks; $check++) {
        $state = Get-CcSwitchStartupSessionState -Root $Root
        if ($state.State -eq 'Unlocked') {
            if ([string]::IsNullOrWhiteSpace([string]$state.Status.ProviderName)) {
                throw 'CC Switch 已解锁，但还没有可用的 Claude 供应商。请在 CC Switch 中添加供应商、密钥和模型并保存，然后重新启动 AI.cmd。未回退到旧配置。'
            }
            return $state.Status
        }

        if ($state.State -eq 'Absent') {
            if ($launchCount -ge 1) { throw 'CC Switch 密码窗口已关闭或会话未就绪。请从 AI设置 → 10 → 8 手动解锁后重试。' }
            Start-CcSwitchStartupManager -Root $Root
            $launchCount++
            $startedByThisCall = $true
            Write-Host ''
            Write-Host '已打开 CC Switch 主密码窗口。请完成解锁并保留该窗口；完成后回到这里按 Enter 检查，输入 Q 只取消本次 AI 启动（密码窗口会保留，不用时可自行关闭）。' -ForegroundColor Yellow
        } elseif ($state.State -eq 'Locked') {
            Write-Host '安全会话已连接但尚未解锁。请在 CC Switch 主密码窗口完成解锁并保留该窗口，然后按 Enter 检查；输入 Q 只取消本次 AI 启动，密码窗口会保留。' -ForegroundColor Yellow
        }

        if ($check -eq $maxChecks) { break }
        $answer = ([string](Read-Host '完成后按 Enter 继续检查；Q 只取消本次 AI 启动')).Trim()
        if ($answer -match '^(?i:q|quit|cancel)$') { throw '用户取消了本次 AI 启动；已打开的 CC Switch 密码窗口保持运行。需要时请从 AI设置 → 10 → 8 解锁后重试。' }
    }

    # One final authenticated status request distinguishes a completed unlock
    # from cancellation/window closure. It never treats pipe reachability alone
    # as successful authentication.
    $state = Get-CcSwitchStartupSessionState -Root $Root
    if ($state.State -eq 'Unlocked') {
        if ([string]::IsNullOrWhiteSpace([string]$state.Status.ProviderName)) {
            throw 'CC Switch 已解锁，但还没有可用的 Claude 供应商。请在 CC Switch 中添加供应商、密钥和模型并保存，然后重新启动 AI.cmd。未回退到旧配置。'
        }
        return $state.Status
    }

    $detail = if ($startedByThisCall) { '没有收到已解锁的认证状态；密码窗口可能已关闭或解锁未完成。' } else { '当前会话仍处于锁定状态。' }
    throw ($detail + ' 请从 AI设置 → 10 → 8 解锁 CC Switch 后重试。')
}

[CmdletBinding()]
param(
    [ValidateSet('Status','Launch')][string]$Action = 'Status',
    [string]$StickRoot,
    [string[]]$HarnessIds = @('claude')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LauncherRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'session-manager.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')

function Get-CcSwitchOfficialPackageStatus {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $module = Join-Path $script:LauncherRoot 'cc-switch.ps1'
    return (& $module -Action Status -PackageRoot $PackageRoot)
}

function Assert-CcSwitchVerifiedPackage {
    param([Parameter(Mandatory = $true)]$Status, [Parameter(Mandatory = $true)][string]$Executable)
    if (-not $Status.ArchiveVerified -or -not $Status.AppPrepared -or -not $Status.ExtractedFilesVerified) {
        throw 'CC Switch 官方 ZIP、已解包文件和可执行文件校验未全部通过；请先用 CC Switch 菜单准备官方包。'
    }
    $full = [IO.Path]::GetFullPath($Executable)
    if (-not [IO.File]::Exists($full)) { throw '已验证的 CC Switch 可执行文件不存在。' }
    if (Test-CcSwitchPathHasReparseComponent -Path $full) { throw 'CC Switch 可执行文件路径包含重解析点。' }
    return $full
}

function Get-CcSwitchExistingHostInstances {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cc-switch.exe'" -ErrorAction Stop)
    } catch {
        throw '无法可靠检查宿主上是否已有 CC Switch 实例；为避免接管或冲突，已拒绝启动。'
    }
}

function Test-CcSwitchHostConflict {
    param([scriptblock]$ProcessProvider = { Get-CcSwitchExistingHostInstances })
    $existing = @(& $ProcessProvider)
    if ($existing.Count -gt 0) {
        return [pscustomobject]@{ Exists = $true; Count = $existing.Count }
    }
    return [pscustomobject]@{ Exists = $false; Count = 0 }
}

function Quote-CcSwitchLaunchArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-CcSwitchChildWrapper {
    param(
        [Parameter(Mandatory = $true)][string]$WrapperPath,
        [Parameter(Mandatory = $true)][string]$EnvironmentPath,
        [Parameter(Mandatory = $true)][string]$Executable
    )
    $exeBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Executable))
    $wrapper = @'
param([Parameter(Mandatory=$true)][string]$EnvironmentPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$exe = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__EXE_B64__'))
$environment = Get-Content -LiteralPath $EnvironmentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
foreach ($property in $environment.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable([string]$property.Name, [string]$property.Value, 'Process')
}
$process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru -ErrorAction Stop
$process.WaitForExit()
exit $process.ExitCode
'@
    $wrapper = $wrapper.Replace('__EXE_B64__', $exeBase64)
    [IO.File]::WriteAllText($WrapperPath, $wrapper, (New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($EnvironmentPath, ($environmentForDisk = (Get-CcSwitchPortableEnvironment -Context $script:CurrentLaunchContext) | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-CcSwitchDirectLaunchCore {
    <# Internal test seam. The production entry never accepts an executable override and always
       verifies cc-switch.ps1 Status before calling this function. #>
    param(
        [Parameter(Mandatory = $true)]$VerifiedPackage,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$StickRoot,
        [Parameter(Mandatory = $true)][string]$SessionTempRoot,
        [Parameter(Mandatory = $true)]$VolumeIdentity,
        [string[]]$EnabledHarnessIds = @('claude'),
        [string]$PowerShellExe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )
    $exePath = Assert-CcSwitchVerifiedPackage -Status $VerifiedPackage -Executable $Executable
    $stick = [IO.Path]::GetFullPath($StickRoot)
    $tempRoot = [IO.Path]::GetFullPath($SessionTempRoot)
    if (-not [IO.Directory]::Exists($tempRoot)) { throw '本机临时会话根目录不存在。' }
    Assert-CcSwitchContextPlainPath -Path $tempRoot -MustExist

    $persistentRoot = Join-Path $stick 'config\cc-switch'
    Assert-CcSwitchContextDirectorySafe -Path $persistentRoot -Root $stick
    if (-not [IO.Directory]::Exists($persistentRoot)) { [IO.Directory]::CreateDirectory($persistentRoot) | Out-Null }
    Assert-CcSwitchContextDirectorySafe -Path $persistentRoot -Root $stick

    $launchLockPath = Join-Path $persistentRoot '.launch-session.lock'
    Assert-CcSwitchContextDirectorySafe -Path $launchLockPath -Root $stick
    $launchLock = $null
    $writerLock = $null
    $sessionRoot = $null
    $sessionId = [guid]::NewGuid().ToString()
    $guardianStarted = $false
    $registered = $false
    $guardianProcess = $null
    try {
        try { $launchLock = New-Object IO.FileStream($launchLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw '同一 U 盘上的 CC Switch 会话已运行或正在启动；本次拒绝并发启动。' }

        $sessionRoot = Join-Path $tempRoot "aistick-$sessionId"
        if (Test-Path -LiteralPath $sessionRoot) { throw '随机会话目录已存在，拒绝复用。' }
        [IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
        $guardDir = Join-Path $sessionRoot 'guard'
        [IO.Directory]::CreateDirectory($guardDir) | Out-Null
        New-SessionRegistration -SessionRoot $sessionRoot -SessionId $sessionId -TempRoot $tempRoot | Out-Null
        $registered = $true

        $context = New-CcSwitchPortableContext -StickRoot $stick -SessionRoot $sessionRoot -HarnessIds $EnabledHarnessIds
        $script:CurrentLaunchContext = $context
        $contextResult = Initialize-CcSwitchPortableContext -Context $context

        $writerLockPath = Join-Path $context.PersistentRoot '.settings-write.lock'
        Assert-CcSwitchContextDirectorySafe -Path $writerLockPath -Root $stick
        try { $writerLock = New-Object IO.FileStream($writerLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw '无法取得 CC Switch 配置写锁；拒绝与同盘配置写入操作并发。' }

        foreach ($name in @('lib.ps1','guardian.ps1','session-manager.ps1')) {
            $from = Join-Path $script:LauncherRoot $name
            if (-not [IO.File]::Exists($from)) { throw "缺少会话守护依赖：$name" }
            Copy-Item -LiteralPath $from -Destination (Join-Path $guardDir $name) -ErrorAction Stop
        }
        $envPath = Join-Path $sessionRoot 'cc-switch-env.json'
        $wrapperPath = Join-Path $sessionRoot 'cc-switch-child.ps1'
        New-CcSwitchChildWrapper -WrapperPath $wrapperPath -EnvironmentPath $envPath -Executable $exePath

        $emptyInput = Join-Path $sessionRoot 'guardian.stdin'
        $stdoutPath = Join-Path $sessionRoot 'guardian.stdout.log'
        $stderrPath = Join-Path $sessionRoot 'guardian.stderr.log'
        [IO.File]::WriteAllBytes($emptyInput, [byte[]]@())
        $guardianArgs = @(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $guardDir 'guardian.ps1'),
            '-StickRoot',$stick,'-SessionRoot',$sessionRoot,'-GuardDir',$guardDir,
            '-DriveLetter',[string]$VolumeIdentity.DriveLetter,
            '-VolumeGuid',[string]$VolumeIdentity.VolumeGuid,
            '-Serial',[string]$VolumeIdentity.Serial,
            '-HarnessExe',$PowerShellExe,
            '-WorkingDir',$context.Home,
            '-HarnessArgs',@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapperPath,'-EnvironmentPath',$envPath),
            '-SessionsDir',(Join-Path $stick 'sessions\cc-switch'),
            '-SourceDir',[string]$context.HarnessDirectories.claude,
            '-StorageMode','DirectUsb','-SessionId',$sessionId
        )
        $guardianQuoted = @($guardianArgs | ForEach-Object { Quote-CcSwitchLaunchArgument ([string]$_) })
        $guardianProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $guardianQuoted -PassThru -WindowStyle Hidden `
            -RedirectStandardInput $emptyInput -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        $guardianStarted = $true
        $guardianProcess.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $guardianProcess.ExitCode
            SessionRoot = $sessionRoot
            ConfigurationRoot = $context.PersistentRoot
            ConfigPath = $context.HarnessDirectories.claude
            GuiIsolationValidated = $false
            EnvironmentBlockComplete = $false
            SettingsCreatedOrUpdated = [bool]$contextResult.SettingsCreatedOrUpdated
        }
    } finally {
        if ($guardianProcess) { $guardianProcess.Dispose() }
        if ($writerLock) { $writerLock.Dispose() }
        if ($launchLock) { $launchLock.Dispose() }
        if ($registered -and -not $guardianStarted -and $sessionRoot -and (Test-Path -LiteralPath $sessionRoot)) {
            try { Remove-OwnedSessionDirectory -SessionRoot $sessionRoot -TempRoot $tempRoot -SessionId $sessionId -AllowActiveOwner | Out-Null } catch { }
        }
        $script:CurrentLaunchContext = $null
    }
}

if (-not $StickRoot) { $StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot }
$StickRoot = [IO.Path]::GetFullPath($StickRoot)
if ($Action -eq 'Launch') {
    throw '普通 DirectUsb 启动入口已封闭；只有通过经验证的 AppContainer 强隔离入口才可启动原生 GUI。'
}
$packageRoot = Join-Path $StickRoot 'tools\cc-switch'
$packageStatus = Get-CcSwitchOfficialPackageStatus -PackageRoot $packageRoot
$hostConflict = Test-CcSwitchHostConflict

if ($Action -eq 'Status') {
    [pscustomobject]@{
        Status = 'BlockedStrongIsolation'
        LaunchAllowed = $false
        ExistingCcSwitchInstances = $hostConflict.Count
        ExistingCcSwitchInstanceObserved = [bool]$hostConflict.Exists
        ArchiveVerified = [bool]$packageStatus.ArchiveVerified
        AppPrepared = [bool]$packageStatus.AppPrepared
        ExtractedFilesVerified = [bool]$packageStatus.ExtractedFilesVerified
        GuiIsolationValidated = $false
        EnvironmentBlockComplete = $false
        Message = '普通启动入口已封闭；原生 GUI 仅能经强隔离入口启动。宿主实例探测仅是防误用信号，不代表隔离状态或产品可用性。'
    }
    return
}

if ($hostConflict.Exists) { throw '检测到宿主上已有 CC Switch 实例；为避免与宿主实例冲突，已拒绝启动且不会关闭它。' }
$verifiedExe = Assert-CcSwitchVerifiedPackage -Status $packageStatus -Executable (Join-Path $packageRoot 'app\cc-switch.exe')
$volume = Get-VolumeIdentity -StickRoot $StickRoot
if (-not $volume -or (-not $volume.VolumeGuid -and -not $volume.Serial)) { throw '无法确认 U 盘卷身份，拒绝启动 DirectUsb 会话。' }
$launch = Invoke-CcSwitchDirectLaunchCore -VerifiedPackage $packageStatus -Executable $verifiedExe `
    -StickRoot $StickRoot -SessionTempRoot ([IO.Path]::GetFullPath($env:TEMP)) -VolumeIdentity $volume -EnabledHarnessIds $HarnessIds
Write-Host "CC Switch guardian 已退出（代码 $($launch.ExitCode)）。配置目录声明为 $($launch.ConfigPath)；原生 GUI 全部写入范围仍未验证。" -ForegroundColor Yellow
if ($launch.ExitCode -ne 0) { exit $launch.ExitCode }

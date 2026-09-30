# 基础能力回归入口：每组测试在独立 Windows PowerShell 5.1 进程内运行。
[CmdletBinding()]
param(
    [string[]]$Suites = @('test-sync.ps1', 'test-archive-set.ps1', 'test-sessions.ps1', 'test-python-env.ps1', 'test-python-commands.ps1', 'test-volume-identity.ps1', 'test-guardian.ps1', 'test-guardian-sync.ps1', 'test-launch-integration.ps1', 'test-vault.ps1', 'test-vault-integration.ps1', 'test-toolbox-status.ps1', 'test-cc-switch.ps1', 'test-portable-profile.ps1', 'test-portable-profile-menu.ps1', 'test-portable-lifecycle.ps1', 'test-cc-path-boundary.ps1', 'test-cc-write-scope.ps1', 'test-cc-switch-context.ps1', 'test-guardian-direct-usb.ps1', 'test-cc-switch-provider.ps1', 'test-cc-switch-checkpoint.ps1', 'test-cc-switch-store.ps1', 'test-appcontainer-boundary.ps1', 'test-cc-switch-encrypted-store.ps1', 'test-cc-switch-migration.ps1', 'test-cc-switch-secure-session.ps1', 'test-cc-switch-session-guardian.ps1', 'test-cc-switch-ipc.ps1', 'test-cc-switch-claude-launch-files.ps1', 'test-cc-switch-unified-mode.ps1', 'test-cc-switch-toolbox-migration.ps1', 'test-launch-unified-settings-race.ps1', 'test-cc-switch-unified-launch.ps1', 'test-cc-switch-unified-launch-full.ps1', 'test-cc-switch-legacy-plaintext-cleanup.ps1', 'test-cc-switch-portable-updater.ps1', 'test-cc-switch-portable-updater-owner.ps1', 'test-cc-switch-isolated-managed-owner.ps1', 'test-appcontainer-usb-boundary.ps1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$allowed = @('test-sync.ps1', 'test-archive-set.ps1', 'test-sessions.ps1', 'test-python-env.ps1', 'test-python-commands.ps1', 'test-volume-identity.ps1', 'test-guardian.ps1', 'test-guardian-sync.ps1', 'test-launch-integration.ps1', 'test-vault.ps1', 'test-vault-integration.ps1', 'test-toolbox-status.ps1', 'test-cc-switch.ps1', 'test-portable-profile.ps1', 'test-portable-profile-menu.ps1', 'test-portable-lifecycle.ps1', 'test-cc-path-boundary.ps1', 'test-cc-write-scope.ps1', 'test-cc-switch-context.ps1', 'test-guardian-direct-usb.ps1', 'test-cc-switch-provider.ps1', 'test-cc-switch-checkpoint.ps1', 'test-cc-switch-store.ps1', 'test-appcontainer-boundary.ps1', 'test-cc-switch-encrypted-store.ps1', 'test-cc-switch-migration.ps1', 'test-cc-switch-secure-session.ps1', 'test-cc-switch-session-guardian.ps1', 'test-cc-switch-ipc.ps1', 'test-cc-switch-claude-launch-files.ps1', 'test-cc-switch-unified-mode.ps1', 'test-cc-switch-toolbox-migration.ps1', 'test-launch-unified-settings-race.ps1', 'test-cc-switch-unified-launch.ps1', 'test-cc-switch-unified-launch-full.ps1', 'test-cc-switch-legacy-plaintext-cleanup.ps1', 'test-cc-switch-portable-updater.ps1', 'test-cc-switch-portable-updater-owner.ps1', 'test-cc-switch-isolated-managed-owner.ps1', 'test-appcontainer-usb-boundary.ps1')
$failed = New-Object System.Collections.Generic.List[string]

# 不加载项目配置或密钥，只做静态解析与编码检查。
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $failed.Add("语法: $($file.Name)")
        $parseErrors | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }
    }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
        $failed.Add("UTF-8 BOM: $($file.Name)")
    }
}

foreach ($suite in $Suites) {
    if ($allowed -notcontains $suite) { throw "不允许的测试名称: $suite" }
    $path = Join-Path $PSScriptRoot $suite
    if (-not (Test-Path -LiteralPath $path)) { $failed.Add("缺少测试: $suite"); continue }
    Write-Host "运行 $suite" -ForegroundColor Cyan
    & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path
    $result = $LASTEXITCODE
    if ($result -ne 0) { $failed.Add("$suite (exit=$result)") }
}

if ($failed.Count -gt 0) {
    Write-Host ('工具箱回归失败: ' + ($failed -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host "工具箱回归通过：$($Suites.Count) 组，Windows PowerShell 5.1。真实拔盘、断电和陌生电脑仍需手工验证。" -ForegroundColor Green
exit 0

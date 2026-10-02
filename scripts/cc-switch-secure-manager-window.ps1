[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StickRoot,
    [ValidateSet('None','InternetClient')][string]$NetworkMode = 'None',
    [switch]$ImportToolboxBeforeLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $manager = Join-Path $PSScriptRoot 'cc-switch-secure-session.ps1'
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) { throw 'Secure session manager is missing.' }
    & $manager -StickRoot $StickRoot -NetworkMode $NetworkMode -ImportToolboxBeforeLaunch:$ImportToolboxBeforeLaunch.IsPresent
    exit 0
} catch {
    [Console]::Error.WriteLine('安全会话未能启动或解锁：' + $_.Exception.Message)
    if (-not [Console]::IsInputRedirected) {
        try { [void](Read-Host '按 Enter 关闭此错误窗口') } catch { }
    }
    exit 1
}

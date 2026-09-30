# Exercise the actual interactive menu with synthetic input and secret data.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'portable-profile-menu.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('profile-menu-' + [guid]::NewGuid().ToString('N'))
$stick = Join-Path $root 'usb'
$source = Join-Path $root 'stopped-app'
$destination = Join-Path $stick 'harness\restored-profiles\test-app'
$script:answers = New-Object 'System.Collections.Generic.Queue[object]'
$passed = 0
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($script:answers.Count -eq 0) { throw 'Unexpected interactive input request.' }
    $next = $script:answers.Dequeue()
    if ($AsSecureString -and $next -isnot [Security.SecureString]) { throw 'Password was not requested securely.' }
    return $next
}
function Assert-Menu([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++; Write-Host "PASS $Message" -ForegroundColor Green
}
function Add-MenuPassword { $script:answers.Enqueue((ConvertTo-SecureString 'synthetic-menu-password' -AsPlainText -Force)) }
try {
    [void][IO.Directory]::CreateDirectory($stick)
    [void][IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'settings.json'), 'synthetic-config-contents')
    foreach ($value in @('1', 'test-app', $source)) { $script:answers.Enqueue($value) }
    Add-MenuPassword; Add-MenuPassword
    $script:answers.Enqueue('0')
    Show-ToolboxProfileMenu -StickRoot $stick
    $path = Get-ToolboxProfilePath -StickRoot $stick -Name test-app
    Assert-Menu (Test-Path -LiteralPath $path -PathType Leaf) 'first menu save creates its missing USB storage parents'
    Assert-Menu (-not [IO.File]::ReadAllText($path).Contains('synthetic-config-contents')) 'menu stores encrypted configuration'
    Assert-Menu ($script:answers.Count -eq 0) 'new snapshot password confirmation is consumed'
    foreach ($value in @('2', 'test-app')) { $script:answers.Enqueue($value) }
    Add-MenuPassword
    $script:answers.Enqueue('0')
    Show-ToolboxProfileMenu -StickRoot $stick
    Assert-Menu ([IO.File]::ReadAllText((Join-Path $destination 'settings.json')) -eq 'synthetic-config-contents') 'menu restores configuration only into the USB harness area'
    $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $source 'settings.json'), 'synthetic-updated')
    foreach ($value in @('1', 'test-app', $source)) { $script:answers.Enqueue($value) }
    Add-MenuPassword
    $script:answers.Enqueue('0')
    Show-ToolboxProfileMenu -StickRoot $stick
    Assert-Menu ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $before) 'existing snapshot updates with authenticated revision'
    $pending = Get-ToolboxProfilePath -StickRoot $stick -Name pending-app
    [IO.File]::Copy($path, $pending)
    [IO.File]::WriteAllText(($pending + '.tmp'), 'synthetic-incomplete-commit')
    foreach ($value in @('2', 'pending-app', '0')) { $script:answers.Enqueue($value) }
    Show-ToolboxProfileMenu -StickRoot $stick
    Assert-Menu (-not (Test-Path -LiteralPath (Join-Path $stick 'harness\restored-profiles\pending-app'))) 'pending recovery cannot silently restore an older snapshot'
    Assert-Menu ($script:answers.Count -eq 0) 'pending recovery is rejected before requesting a password'
    foreach ($name in @('../escape', 'C:\outside', 'NUL', 'test/app')) {
        $denied = $false
        try { $null = Get-ToolboxProfilePath -StickRoot $stick -Name $name } catch { $denied = $true }
        Assert-Menu $denied 'invalid snapshot name cannot redirect a USB write'
    }
} finally {
    while ($script:answers.Count -gt 0) { $value = $script:answers.Dequeue(); if ($value -is [Security.SecureString]) { $value.Dispose() } }
    $full = [IO.Path]::GetFullPath($root)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $full) -ne $parent -or (Split-Path -Leaf $full) -notmatch '^profile-menu-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-ToolboxPlainPath -Path $full
    if (Test-Path -LiteralPath $full) {
        $links = @(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count -gt 0) { throw 'Test cleanup found a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Host "Profile menu: $passed passed. Synthetic fixtures only."

# Interactive management; master passwords never cross a process boundary.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'vault.ps1')

function Test-ToolboxSecureEqual {
    param([Security.SecureString]$First, [Security.SecureString]$Second)
    if ($First.Length -ne $Second.Length) { return $false }
    $a = [IntPtr]::Zero; $b = [IntPtr]::Zero
    try {
        $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $difference = 0
        for ($i = 0; $i -lt ($First.Length * 2); $i++) {
            $difference = $difference -bor ([Runtime.InteropServices.Marshal]::ReadByte($a, $i) -bxor [Runtime.InteropServices.Marshal]::ReadByte($b, $i))
        }
        return ($difference -eq 0)
    } finally {
        if ($a -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a) }
        if ($b -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
}

function Read-ToolboxNewPassword {
    $first = Read-Host '设置主密码（至少 12 个字符，请自行妥善保管）' -AsSecureString
    $second = $null
    try {
        if ($first.Length -lt 12) { throw '主密码至少需要 12 个字符。' }
        $second = Read-Host '再次输入主密码' -AsSecureString
        if (-not (Test-ToolboxSecureEqual $first $second)) { throw '两次输入不同，未修改保险箱。' }
        return $first
    } catch { $first.Dispose(); throw }
    finally { if ($second) { $second.Dispose() } }
}

function Initialize-ToolboxVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot, [Parameter(Mandatory)][Security.SecureString]$Password)
    if ($Password.Length -lt 12) { throw '主密码至少需要 12 个字符。' }
    $keysPath = Join-Path $StickRoot 'config\keys.env'
    $vaultPath = Join-Path $StickRoot 'config\credentials.vault.json'
    Assert-ToolboxPlainPath -Path $keysPath
    Assert-ToolboxPlainPath -Path $vaultPath
    if (Test-ProviderVaultPresent -KeysFile $keysPath) { throw '已有保险箱或恢复文件，不能重新初始化。' }
    $legacyLock = $null; $values = $null; $verified = $null
    try {
        if (Test-Path -LiteralPath $keysPath) {
            $item = Get-Item -LiteralPath $keysPath -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '旧凭据路径必须是普通文件。' }
            $legacyLock = New-Object IO.FileStream($keysPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        }
        $values = Read-LegacyProviderSecrets -KeysFile $keysPath
        $revision = Write-PortableVault -Path $vaultPath -Password $Password -Secrets $values -ExpectedRevision $null
        $verified = Read-PortableVault -Path $vaultPath -Password $Password
        if ($verified.Secrets.Count -ne $values.Count) { throw '迁移后的凭据数量校验失败，旧文件已保留。' }
        foreach ($name in $values.Keys) {
            if (-not $verified.Secrets.ContainsKey($name) -or -not [string]::Equals([string]$verified.Secrets[$name], [string]$values[$name], [StringComparison]::Ordinal)) {
                throw '迁移后校验失败，旧文件已保留。'
            }
        }
        $count = $values.Count
        if ($legacyLock) { $legacyLock.Dispose(); $legacyLock = $null; Remove-Item -LiteralPath $keysPath -Force -ErrorAction Stop }
        return [pscustomobject]@{ Count = $count; Revision = $revision; Path = $vaultPath }
    } finally {
        if ($legacyLock) { $legacyLock.Dispose() }
        if ($null -ne $values) { $values.Clear() }
        if ($verified) { $verified.Secrets.Clear() }
    }
}

function Show-ToolboxVaultMenu {
    param([Parameter(Mandatory)][string]$StickRoot)
    $path = Join-Path $StickRoot 'config\credentials.vault.json'
    while ($true) {
        Write-Host ''
        Write-Host '--- 凭据保险箱 ---' -ForegroundColor Cyan
        $state = Get-VaultStatus -Path $path
        Write-Host ("状态：{0}；不在此界面显示密钥内容。" -f $state.State)
        Write-Host '  1. 创建 / 迁移（校验成功后删除旧 keys.env）'
        Write-Host '  2. 添加 / 更新一个凭据'
        Write-Host '  3. 修改主密码'
        Write-Host '  4. 恢复中断写入的加密副本'
        Write-Host '  0. 返回'
        $choice = Read-Host '请选择'
        if ($choice -eq '0' -or -not $choice) { return }
        $password = $null; $newPassword = $null; $opened = $null; $secretInput = $null
        try {
            switch ($choice) {
                '1' {
                    Write-Host '这里只加密凭据；会话历史和项目文件不在加密范围内。忘记主密码无法解密。' -ForegroundColor Yellow
                    $password = Read-ToolboxNewPassword
                    $result = Initialize-ToolboxVault -StickRoot $StickRoot -Password $password
                    Write-Host ("已迁移并验证 {0} 个凭据；旧明文文件已移除。删除不等于物理擦除。" -f $result.Count) -ForegroundColor Green
                }
                '2' {
                    $password = Read-Host '主密码' -AsSecureString
                    $opened = Read-PortableVault -Path $path -Password $password
                    $name = Read-Host '凭据变量名（例如 ANTHROPIC_API_KEY）'
                    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') { throw '请输入有效变量名。' }
                    $secretInput = Read-Host '新的密钥（输入不可见）' -AsSecureString
                    if ($secretInput.Length -eq 0) { throw '密钥为空，已取消。' }
                    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretInput)
                    try { $opened.Secrets[$name] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
                    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
                    $null = Write-PortableVault -Path $path -Password $password -Secrets $opened.Secrets -ExpectedRevision $opened.Revision
                    Write-Host '已保存；正在运行的窗口继续使用启动时的凭据，新窗口使用新值。' -ForegroundColor Green
                }
                '3' {
                    $password = Read-Host '原主密码' -AsSecureString
                    $opened = Read-PortableVault -Path $path -Password $password
                    $newPassword = Read-ToolboxNewPassword
                    $null = Write-PortableVault -Path $path -Password $newPassword -Secrets $opened.Secrets -ExpectedRevision $opened.Revision
                    Write-Host '主密码已更新；旧加密备份可能仍需旧密码，请按保险箱文档管理备份。' -ForegroundColor Green
                }
                '4' {
                    Write-Host '恢复可能回到较早的凭据版本。请保留当前加密文件及副本。' -ForegroundColor Yellow
                    $source = Read-Host '输入 Backup 恢复备份，或 Temp 恢复临时副本（回车取消）'
                    if ($source -notin @('Backup', 'Temp')) { continue }
                    $password = Read-Host '所选加密副本的主密码' -AsSecureString
                    $null = Restore-PortableVault -Path $path -Password $password -Source $source
                    Write-Host '加密副本已通过认证并恢复。' -ForegroundColor Green
                }
                default { Write-Host '请输入 0-4。' -ForegroundColor Yellow }
            }
        } catch { Write-Host '操作未完成；请检查密码、文件状态和写入权限。原凭据不会因此回退为明文。' -ForegroundColor Yellow }
        finally {
            if ($opened) { $opened.Secrets.Clear() }
            if ($password) { $password.Dispose() }
            if ($newPassword) { $newPassword.Dispose() }
            if ($secretInput) { $secretInput.Dispose() }
        }
    }
}

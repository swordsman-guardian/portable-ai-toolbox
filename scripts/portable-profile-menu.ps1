# Interactive access to encrypted configuration snapshots on this USB toolkit.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'vault-menu.ps1')
. (Join-Path $PSScriptRoot 'portable-profile.ps1')

function Get-ToolboxProfilePath {
    param([Parameter(Mandatory)][string]$StickRoot, [Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$' -or $Name -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])$') {
        throw '存档名称限 1–48 位英文字母、数字、下划线或短横线，不能使用 Windows 保留名称。'
    }
    $root = [IO.Path]::GetFullPath($StickRoot).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $root ('config\app-profiles\' + $Name + '.vault.json')))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw '存档路径必须位于 U 盘工具箱内。' }
    Assert-ToolboxPlainPath -Path $path
    return $path
}

function Show-ToolboxProfileMenu {
    param([Parameter(Mandatory)][string]$StickRoot)
    while ($true) {
        Write-Host ''
        Write-Host '--- 加密配置存档 ---' -ForegroundColor Cyan
        Write-Host '把已关闭应用的配置文件夹加密保存在 U 盘，之后恢复到盘内独立文件夹。'
        Write-Host '这是手动存档，不会启动 CC Switch，也不是运行中数据库的实时备份。' -ForegroundColor DarkGray
        Write-Host '  1. 保存配置文件夹'
        Write-Host '  2. 恢复已保存的配置'
        Write-Host '  0. 返回'
        $choice = Read-Host '请选择'
        if (-not $choice -or $choice -eq '0') { return }
        if (@('1', '2') -notcontains $choice) { continue }
        $password = $null
        try {
            $name = Read-Host '存档名称，例如 cc-switch（回车取消）'
            if (-not $name) { continue }
            $path = Get-ToolboxProfilePath -StickRoot $StickRoot -Name $name
            if ($choice -eq '1') {
                $source = Read-Host '已关闭应用的配置文件夹完整路径（回车取消）'
                if (-not $source) { continue }
                Write-Host '请确保应用已经关闭；存档最多包含 16 MiB、512 个文件，不适合会话历史或安装目录。' -ForegroundColor Yellow
                $state = Get-VaultStatus -Path $path
                if ($state.State -notin @('Absent', 'Present')) { throw '存档存在待恢复文件或格式异常，请先处理恢复，不能覆盖。' }
                $revision = $null
                if ($state.Exists) {
                    $password = Read-Host '输入此存档的密码' -AsSecureString
                    $opened = Read-PortableVault -Path $path -Password $password
                    try { $revision = $opened.Revision } finally { $opened.Secrets.Clear() }
                } else { $password = Read-ToolboxNewPassword }
                # Create only the named toolkit-owned storage directory, after
                # validating all existing ancestors. The profile API itself
                # deliberately requires an existing parent directory.
                Assert-ToolboxPlainPath -Path $path
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                Assert-ToolboxPlainPath -Path $path
                $null = Save-PortableProfile -Path $path -Password $password -SourceRoot $source.Trim('"') -ExpectedRevision $revision
                Write-Host "已加密保存在 U 盘：$path" -ForegroundColor Green
            } else {
                $state = Get-VaultStatus -Path $path
                if ($state.State -ne 'Present') { throw '找不到可用存档，或存在待恢复文件；请先处理存档恢复，未向目标目录写入。' }
                # The user-facing restore destination is fixed under the USB
                # harness area. The low-level API also supports owned runtime
                # temporary directories for future supervised integrations.
                $destination = Join-Path ([IO.Path]::GetFullPath($StickRoot)) ('harness\restored-profiles\' + $name)
                Assert-ToolboxPlainPath -Path $destination
                Write-Host "恢复位置：$destination"
                $password = Read-Host '输入此存档的密码' -AsSecureString
                $null = Restore-PortableProfile -Path $path -Password $password -DestinationRoot $destination
                Write-Host '已恢复到盘内独立文件夹；不会覆盖现有配置，也不会修改本机安装的工具。' -ForegroundColor Green
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        finally { if ($password) { $password.Dispose() } }
    }
}

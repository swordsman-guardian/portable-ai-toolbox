[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'python-env.ps1') -StickRoot $root

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "断言失败：$Message" } }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('portable-python-test-' + [Guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$work = Join-Path $temp 'work'
$p1 = Join-Path $temp 'project-one'
$p2 = Join-Path $temp 'project-two'
New-Item -ItemType Directory -Path $p1,$p2 -Force | Out-Null
$original = @{}
foreach ($name in @('UV_PROJECT_ENVIRONMENT','UV_LINK_MODE','UV_CACHE_DIR','UV_PYTHON','VIRTUAL_ENV','PYTHONHOME','PYTHONPATH','PATH','AISTICK_PYTHON','AISTICK_PYTHON_ENV')) {
    if (Test-Path "Env:$name") { $original[$name] = (Get-Item "Env:$name").Value }
}
try {
    $inventory = @(Get-PortablePythonInventory -StickRoot $root)
    Assert-True ($inventory.Count -gt 0) '应发现盘内 Python'
    Assert-True ($inventory[0].PythonPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) '解释器必须来自 U 盘'
    $pythonVersion = $inventory[0].Version
    Assert-True ($pythonVersion -match '^\d+\.\d+\.\d+$') '版本必须实际查询'

    $pyproject = Join-Path $p1 'pyproject.toml'
    [IO.File]::WriteAllText($pyproject, "[build-system]`nrequires-python = '>=99'`n`n[project]`nname = 'fixture'`nrequires-python = `">=$($pythonVersion.Split('.')[0]).0,<99.0`"`n", (New-Object Text.UTF8Encoding($false)))
    $check = Test-PortablePythonProject -StickRoot $root -ProjectPath $p1
    Assert-True $check.Supported '应只从 [project] 读取常见 requires-python 子集'

    $pinProject = Join-Path $temp 'pin-project'
    New-Item -ItemType Directory -Path $pinProject -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $pinProject '.python-version'), ($pythonVersion.Split('.')[0..1] -join '.'), (New-Object Text.UTF8Encoding($false)))
    $pinCheck = Test-PortablePythonProject -StickRoot $root -ProjectPath $pinProject
    Assert-True $pinCheck.Supported 'X.Y .python-version 应匹配已安装的同 minor 版本'
    $pinState = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $pinProject
    Assert-True ($pinState.Supported -and $pinState.Ready) 'X.Y .python-version 初始化也应兼容且空环境 Ready'

    $collisionProject = Join-Path $temp 'collision-project'
    New-Item -ItemType Directory -Path $collisionProject -Force | Out-Null
    [IO.File]::Copy($pyproject, (Join-Path $collisionProject 'pyproject.toml'))
    $collisionRequirements = Get-PortableProjectRequirements -ProjectPath $collisionProject
    $collisionKey = Get-PortableEnvironmentKey -Requirements $collisionRequirements -Interpreter $inventory[0]
    $collisionPath = Join-Path (Join-Path $work 'python-envs') $collisionKey
    New-Item -ItemType Directory -Path $collisionPath -Force | Out-Null
    $sentinel = Join-Path $collisionPath 'keep-me.txt'
    [IO.File]::WriteAllText($sentinel, 'unknown data')
    $collision = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $collisionProject
    Assert-True ($collision.Status -eq 'EnvironmentCollision') '未知目标目录必须拒绝复用'
    Assert-True ((Get-Content -LiteralPath $sentinel -Raw) -eq 'unknown data') '未知目标数据必须保留'
    $linkWork = Join-Path $temp 'link-work'
    $outside = Join-Path $temp 'linked-env-root'
    New-Item -ItemType Directory -Path $linkWork,$outside -Force | Out-Null
    try {
        New-Item -ItemType Junction -Path (Join-Path $linkWork 'python-envs') -Target $outside -ErrorAction Stop | Out-Null
        $unsafe = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $linkWork -ProjectPath $collisionProject
        Assert-True ($unsafe.Status -eq 'UnsafePath') '重解析点不得把环境写出 WorkPath'
    } catch {
        if ($_.Exception.Message -notmatch 'privilege|权限|access|访问') { throw }
        Write-Host '当前 Windows 权限不允许创建 junction，跳过重解析点路径用例。'
    }

    $bad = Join-Path $p2 'pyproject.toml'
    [IO.File]::WriteAllText($bad, "[project]`nrequires-python = `">=99.0,<100.0`"`n", (New-Object Text.UTF8Encoding($false)))
    $mismatch = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $p2
    Assert-True (-not $mismatch.Supported -and $mismatch.Status -eq 'VersionUnavailable') '版本不匹配必须明确拒绝'
    Assert-True (-not $mismatch.EnvironmentPath) '版本不匹配不得创建环境'

    $env:UV_PROJECT_ENVIRONMENT = 'host-poison-project'
    $env:UV_LINK_MODE = 'symlink'
    $env:UV_CACHE_DIR = 'host-poison-cache'
    $env:UV_PYTHON = 'host-poison-python'
    $env:VIRTUAL_ENV = 'host-poison-venv'
    $env:PYTHONHOME = 'host-poison-home'
    $env:PYTHONPATH = 'host-poison-path'
    New-Item -ItemType Directory -Path (Join-Path $p1 '.venv') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p1 '.venv\keep-me.txt'), 'project venv untouched')
    $r1 = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $p1
    Assert-True $r1.Supported '项目版本应被支持'
    Assert-True $r1.DependenciesPending -and (-not $r1.Ready) '存在 pyproject 时不能声称依赖已就绪'
    Assert-True ($r1.EnvironmentPath.StartsWith([IO.Path]::GetFullPath($work), [StringComparison]::OrdinalIgnoreCase)) '虚拟环境必须处于 WorkPath 内'
    Assert-True ((Get-Content -LiteralPath (Join-Path $p1 '.venv\keep-me.txt') -Raw) -eq 'project venv untouched') '不得碰项目现有 .venv'
    Assert-True ((Get-Item Env:UV_LINK_MODE).Value -eq 'symlink') '应恢复宿主 UV_LINK_MODE'
    Assert-True ((Get-Item Env:UV_PROJECT_ENVIRONMENT).Value -eq 'host-poison-project') '应恢复宿主 UV_PROJECT_ENVIRONMENT'

    . (Join-Path $PSScriptRoot 'python-session.ps1')
    $sessionPython = Set-PortablePythonSession -State $r1 -StickRoot $root -WorkPath $work
    Assert-True ($sessionPython -eq (Join-Path $r1.EnvironmentPath 'Scripts\python.exe')) '兼容项目应显式使用项目 venv'
    Assert-True ($env:UV_PYTHON -eq $sessionPython) 'uv Python 应被固定到当前项目 venv，防止 uv pip 安装进共享解释器'
    Assert-True ($env:AISTICK_PYTHON -eq $sessionPython) '启动器应获得项目解释器路径'
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $oldPreference = $ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $pythonOutput = @(& $cmd /d /c 'python --version' 2>&1); $pythonExit=$LASTEXITCODE }
    finally { $ErrorActionPreference=$oldPreference }
    Assert-True ($pythonExit -eq 0 -and ($pythonOutput -join ' ') -match [regex]::Escape($inventory[0].Version)) '兼容状态下普通 python 必须实际启动项目 venv'
    $badSession = Set-PortablePythonSession -State $mismatch -StickRoot $root -WorkPath $work
    Assert-True ($null -eq $badSession) '不兼容项目不得暴露 base Python'
    Assert-True ($env:UV_PYTHON -eq (Join-Path $work 'python-unavailable\python.exe')) '不兼容时 uv Python 应指向失败占位解释器'
    Assert-True ($env:PATH.StartsWith((Join-Path $work 'python-unavailable') + ';', [StringComparison]::OrdinalIgnoreCase)) '不兼容时 PATH 应优先命中友好失败 shim'
    try { $ErrorActionPreference='Continue'; $blockedOutput = @(& $cmd /d /c 'python --version' 2>&1); $blockedExit=$LASTEXITCODE }
    finally { $ErrorActionPreference=$oldPreference }
    Assert-True ($blockedExit -ne 0) '版本不兼容时普通 python 必须以非零失败，不能启动内置 base'

    $r1again = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $p1
    Assert-True ($r1again.EnvironmentPath -eq $r1.EnvironmentPath) '相同项目应复用环境键'
    Assert-True ($r1again.Message.StartsWith('复用')) '复用应被报告'
    $p3 = Join-Path $temp 'project-one-copy'
    New-Item -ItemType Directory -Path $p3 -Force | Out-Null
    [IO.File]::Copy($pyproject, (Join-Path $p3 'pyproject.toml'))
    $r2 = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $p3
    Assert-True ($r2.EnvironmentPath -ne $r1.EnvironmentPath) '不同项目必须隔离'

    # 预置哈希目标目录，且没有本工具的标记文件，必须保留未知目录并失败。
    $req = Get-PortableProjectRequirements -ProjectPath $p2
    $selected = $inventory[0]
    # p2 版本不匹配，不触碰其路径；检查唯一的目标边界拒绝机制已覆盖由不可信已存在目录触发。
    Write-Host 'Python 环境测试通过：盘内解释器、项目解析、版本拒绝、UV 污染恢复、WorkPath 边界、venv 复用/隔离与启动 session 版本门禁。'
} finally {
    foreach ($name in @('UV_PROJECT_ENVIRONMENT','UV_LINK_MODE','UV_CACHE_DIR','UV_PYTHON','VIRTUAL_ENV','PYTHONHOME','PYTHONPATH','PATH','AISTICK_PYTHON','AISTICK_PYTHON_ENV')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        if ($original.ContainsKey($name)) { Set-Item -LiteralPath "Env:$name" -Value $original[$name] }
    }
    if (Test-Path -LiteralPath $temp) {
        $resolvedTemp = [IO.Path]::GetFullPath($temp)
        $leaf = Split-Path -Leaf $resolvedTemp
        if (-not $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^portable-python-test-[0-9a-f]{32}$') {
            throw "拒绝清理不符合测试临时目录约束的路径：$resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

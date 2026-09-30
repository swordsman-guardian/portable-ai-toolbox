# Verify actual uv commands use the launch-bound environment, offline.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$sandbox = Join-Path $testBase ('ai-uv-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$project = Join-Path $sandbox 'project'
$work = Join-Path $sandbox 'work'
New-Item -ItemType Directory -Path $project,$work -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert-Command([bool]$Ok,[string]$Name) { if (-not $Ok) { throw $Name }; Write-Host "通过: $Name" }
try {
    . (Join-Path $PSScriptRoot 'lib.ps1')
    $null = New-IsolatedEnvironment -StickRoot $root -WorkPath $work -RealHostUser 'fixture'
    . (Join-Path $PSScriptRoot 'python-env.ps1') -StickRoot $root -WorkPath $work -ProjectPath $project
    . (Join-Path $PSScriptRoot 'python-session.ps1')
    [IO.File]::WriteAllText((Join-Path $project 'pyproject.toml'), "[project]`nname = `"portable-test`"`nversion = `"0.0.1`"`nrequires-python = `">=3.10`"`ndependencies = []`n", $utf8)
    $existing = Join-Path $project '.venv'
    [void][IO.Directory]::CreateDirectory($existing)
    [IO.File]::WriteAllText((Join-Path $existing 'keep.txt'), 'untouched', $utf8)
    $state = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $project
    $selected = Set-PortablePythonSession -State $state -StickRoot $root -WorkPath $work
    Assert-Command ([bool]$selected) '建立可用的会话 Python'
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pipResult = @(& $cmd /d /c 'pip --version' 2>&1)
        $pipCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $priorPreference }
    Assert-Command ($pipCode -ne 0) '未安装 pip 时明确提示 uv pip，不回退共享 pip'
    $probe = Join-Path $project 'probe.py'
    [IO.File]::WriteAllText($probe, "import sys`nprint('PYTHON=' + sys.executable)`n", $utf8)
    Push-Location -LiteralPath $project
    try {
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $state.UvPath run --offline python $probe 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        Assert-Command ($code -eq 0) ('uv run 离线成功: ' + ($output -join ' '))
        Assert-Command (@($output | Where-Object { [string]$_ -eq ('PYTHON=' + $selected) }).Count -eq 1) 'uv run 使用会话 venv'

        $build = Join-Path $sandbox 'make_fixture.py'
        $wheel = Join-Path $sandbox 'aistick_scope_fixture-0.0.1-py3-none-any.whl'
        $python = @'
import sys, zipfile
d = 'aistick_scope_fixture-0.0.1.dist-info/'
files = {
 'aistick_scope_fixture/__init__.py': 'VALUE = "isolated"\n',
 d+'METADATA': 'Metadata-Version: 2.1\nName: aistick-scope-fixture\nVersion: 0.0.1\n',
 d+'WHEEL': 'Wheel-Version: 1.0\nGenerator: fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
}
files[d+'RECORD'] = ''.join(p+',,\n' for p in files) + d+'RECORD,,\n'
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for path, data in files.items(): z.writestr(path, data)
'@
        [IO.File]::WriteAllText($build, $python, $utf8)
        & $state.PythonPath -I $build $wheel
        Assert-Command ($LASTEXITCODE -eq 0) '生成离线测试 wheel'
        try {
            $ErrorActionPreference = 'Continue'
            $installOutput = @(& $state.UvPath pip install --offline --no-index --no-deps $wheel 2>&1)
            $installCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        Assert-Command ($installCode -eq 0) ('uv pip 离线安装成功: ' + ($installOutput -join ' '))
        $importCheck = Join-Path $sandbox 'check_import.py'
        [IO.File]::WriteAllText($importCheck, "import importlib.util`nprint(importlib.util.find_spec('aistick_scope_fixture') is not None)`n", $utf8)
        $inVenv = @(& $selected -I $importCheck)
        $inBase = @(& $state.PythonPath -I $importCheck)
        Assert-Command (($inVenv -join '') -eq 'True') '依赖实际安装到项目 venv'
        Assert-Command (($inBase -join '') -eq 'False') '共享基础 Python 未被安装测试依赖'
        Assert-Command ([IO.File]::ReadAllText((Join-Path $existing 'keep.txt')) -eq 'untouched' -and @(Get-ChildItem -LiteralPath $existing -Force).Count -eq 1) 'uv run 和 uv pip 都未改项目已有 .venv'

        $badProject = Join-Path $sandbox 'bad-project'
        [void][IO.Directory]::CreateDirectory($badProject)
        [IO.File]::WriteAllText((Join-Path $badProject 'pyproject.toml'), "[project]`nname = `"bad-version-test`"`nversion = `"0.0.1`"`nrequires-python = `">=99.0`"`n", $utf8)
        $userVenv = Join-Path $badProject '.venv'
        try {
            $ErrorActionPreference = 'Continue'
            $null = & $state.UvPath venv --python $state.PythonPath $userVenv 2>&1
            $createCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        Assert-Command ($createCode -eq 0) '建立负向测试用的真实项目 .venv'
        $badState = Initialize-PortablePythonEnvironment -StickRoot $root -WorkPath $work -ProjectPath $badProject
        $null = Set-PortablePythonSession -State $badState -StickRoot $root -WorkPath $work
        Push-Location -LiteralPath $badProject
        try {
            try {
                $ErrorActionPreference = 'Continue'
                $null = & $state.UvPath run --offline python $probe 2>&1
                $badRunCode = $LASTEXITCODE
                $null = & $state.UvPath pip install --offline --no-index --no-deps $wheel 2>&1
                $badPipCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $oldPreference }
            Assert-Command ($badRunCode -ne 0 -and $badPipCode -ne 0) '不兼容项目的 uv run 与 uv pip 均拒绝执行'
            $untouched = @(& (Join-Path $userVenv 'Scripts\python.exe') -I $importCheck)
            Assert-Command (($untouched -join '') -eq 'False') '失败路径未把测试包装进项目原有 .venv'
            Assert-Command (-not (Test-Path -LiteralPath $env:UV_PROJECT_ENVIRONMENT)) '失败路径未创建占位环境'
        } finally { Pop-Location }
    } finally { Pop-Location }
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        $resolved = (Resolve-Path -LiteralPath $sandbox).Path
        if (-not $resolved.StartsWith($testBase + '\',[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $resolved -Leaf) -notmatch '^ai-uv-[a-f0-9]{8}$') { throw '拒绝清理测试范围外目录' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0

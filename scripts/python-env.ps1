# Portable Python runtime selection and per-project venv management.
# Windows PowerShell 5.1 compatible; intentionally does not install dependencies.

[CmdletBinding()]
param(
    [ValidateSet('inventory','check','prepare')][string]$Action='inventory',
    [string]$StickRoot='',
    [string]$WorkPath='',
    [string]$ProjectPath=(Get-Location).Path
)

if (-not $StickRoot) { $StickRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
if (-not $WorkPath) { $WorkPath = Join-Path ([IO.Path]::GetTempPath()) 'AIStick\python-work' }

function Get-PortablePythonInventory {
    param([Parameter(Mandatory)][string]$StickRoot)
    $root = [IO.Path]::GetFullPath($StickRoot)
    $runtime = Join-Path $root 'runtime'
    $candidates = @()
    if (Test-Path -LiteralPath $runtime -PathType Container) {
        $direct = Join-Path $runtime 'python'
        if (Test-Path -LiteralPath $direct -PathType Container) { $candidates += Get-Item -LiteralPath $direct }
        $candidates += @(Get-ChildItem -LiteralPath $runtime -Directory -Filter 'python-*' -ErrorAction SilentlyContinue)
    }
    $rows = @()
    foreach ($dir in $candidates) {
        $exe = Join-Path $dir.FullName 'python.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $version = $null
        $saved = @{}
        try {
            foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UV_*' -or $_.Name -in @('VIRTUAL_ENV','PYTHONHOME','PYTHONPATH','PYTHONNOUSERSITE') })) { $saved[$item.Name] = $item.Value; Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction SilentlyContinue }
            $env:PYTHONNOUSERSITE = '1'
            $out = @(& $exe -c 'import sys; print(sys.version.split()[0])' 2>&1)
            if ($out.Count -gt 0 -and "$($out[-1])" -match '^\d+\.\d+\.\d+$') { $version = "$($out[-1])" }
        } catch { Write-Verbose ("无法查询内置 Python 版本 $exe：$($_.Exception.Message)") }
        finally {
            Remove-Item Env:PYTHONNOUSERSITE -ErrorAction SilentlyContinue
            foreach ($name in @($saved.Keys)) { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
        }
        $rows += [pscustomobject]@{ Version = $version; PythonPath = $exe; Root = $dir.FullName; Source = 'U盘内置' }
    }
    return ,@($rows | Sort-Object Version, PythonPath)
}

function Get-PortableUvPath {
    param([Parameter(Mandatory)][string]$StickRoot)
    $path = Join-Path ([IO.Path]::GetFullPath($StickRoot)) 'runtime\uv\uv.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

function ConvertTo-PortableVersionTuple {
    param([Parameter(Mandatory)][string]$Version)
    if ($Version -notmatch '^(\d+)\.(\d+)(?:\.(\d+))?$') { throw "不支持的 Python 版本格式 '$Version'；只接受 X.Y 或 X.Y.Z。" }
    return ,@([int]$Matches[1], [int]$Matches[2], $(if ($Matches[3]) { [int]$Matches[3] } else { 0 }))
}

function Compare-PortableVersion {
    param([int[]]$Left, [int[]]$Right)
    for ($i = 0; $i -lt 3; $i++) {
        if ($Left[$i] -lt $Right[$i]) { return -1 }
        if ($Left[$i] -gt $Right[$i]) { return 1 }
    }
    return 0
}

function Test-PortablePythonConstraint {
    param([Parameter(Mandatory)][string]$Constraint, [Parameter(Mandatory)][string]$Version)
    $actual = ConvertTo-PortableVersionTuple $Version
    $clauses = $Constraint.Split(',')
    foreach ($raw in $clauses) {
        $clause = $raw.Trim()
        if (-not $clause) { throw "requires-python '$Constraint' 含空约束；暂不支持。" }
        if ($clause -match '^==\s*(\d+)\.(\d+)\.\*$') {
            if ($actual[0] -ne [int]$Matches[1] -or $actual[1] -ne [int]$Matches[2]) { return $false }
            continue
        }
        if ($clause -match '^(!=|==|>=|<=|>|<|~=)\s*(\d+\.\d+(?:\.\d+)?)$') {
            $op = $Matches[1]; $versionText = $Matches[2]; $required = ConvertTo-PortableVersionTuple $versionText
            $cmp = Compare-PortableVersion $actual $required
            $ok = switch ($op) {
                '==' { $cmp -eq 0 }
                '!=' { $cmp -ne 0 }
                '>=' { $cmp -ge 0 }
                '<=' { $cmp -le 0 }
                '>' { $cmp -gt 0 }
                '<' { $cmp -lt 0 }
                '~=' { if ($versionText -match '^\d+\.\d+$') { ($cmp -ge 0) -and ($actual[0] -eq $required[0]) } else { ($cmp -ge 0) -and ($actual[0] -eq $required[0]) -and ($actual[1] -eq $required[1]) } }
            }
            if (-not $ok) { return $false }
            continue
        }
        throw "暂不支持 requires-python 约束 '$clause'。支持逗号分隔的 ==、!=、>=、<=、>、<、~= 和 ==X.Y.*。"
    }
    return $true
}

function Get-PortableProjectRequirements {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $project = [IO.Path]::GetFullPath($ProjectPath)
    if (-not (Test-Path -LiteralPath $project -PathType Container)) { throw "项目目录不存在: $project" }
    $requires = $null; $source = $null; $unsupported = $null
    $toml = Join-Path $project 'pyproject.toml'
    if (Test-Path -LiteralPath $toml -PathType Leaf) {
        $section = ''; $insideProject = $false; $found = $false
        foreach ($line in [IO.File]::ReadAllLines($toml, [Text.Encoding]::UTF8)) {
            if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') { $section = $Matches[1]; $insideProject = ($section -eq 'project'); continue }
            if ($insideProject -and $line -match '^\s*requires-python\s*=\s*"([^"]+)"\s*(?:#.*)?$') { $requires = $Matches[1]; $source = 'pyproject.toml [project] requires-python'; $found = $true; break }
            if ($insideProject -and $line -match '^\s*requires-python\s*=') { $unsupported = 'pyproject.toml 的 requires-python 必须是单行双引号字符串。'; break }
        }
    }
    $pv = Join-Path $project '.python-version'
    $pin = $null
    if (Test-Path -LiteralPath $pv -PathType Leaf) {
        $pin = [IO.File]::ReadAllText($pv, [Text.Encoding]::UTF8).Trim()
        if ($pin -notmatch '^\d+\.\d+(?:\.\d+)?$') { $unsupported = '.python-version 仅支持精确 X.Y 或 X.Y.Z 版本。' }
    }
    $deps = @()
    foreach ($name in @('pyproject.toml','requirements.txt','requirements-dev.txt','setup.py','setup.cfg','Pipfile','Pipfile.lock','poetry.lock','uv.lock')) {
        $p = Join-Path $project $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { $deps += Get-Item -LiteralPath $p }
    }
    return [pscustomobject]@{ ProjectPath=$project; RequiresPython=$requires; RequiresSource=$source; PythonVersionPin=$pin; Unsupported=$unsupported; DependencyFiles=$deps }
}

function Test-PortablePythonProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StickRoot, [Parameter(Mandatory)][string]$ProjectPath)
    try {
        $requirements = Get-PortableProjectRequirements -ProjectPath $ProjectPath
        $inventory = @(Get-PortablePythonInventory -StickRoot $StickRoot)
        $clauses = @()
        if ($requirements.RequiresPython) { $clauses += $requirements.RequiresPython }
        if ($requirements.PythonVersionPin) {
            if ($requirements.PythonVersionPin -match '^\d+\.\d+$') { $clauses += "==$($requirements.PythonVersionPin).*" }
            else { $clauses += "==$($requirements.PythonVersionPin)" }
        }
        if ($requirements.Unsupported) { return [pscustomobject]@{ Supported=$false; Status='UnsupportedRequirement'; RequiredVersion=($clauses -join ', '); PythonPath=$null; UvPath=(Get-PortableUvPath $StickRoot); DependenciesPending=($requirements.DependencyFiles.Count -gt 0); Message=$requirements.Unsupported } }
        $compatible = @()
        foreach ($item in $inventory) {
            if (-not $item.Version) { continue }
            $ok = $true
            foreach ($clause in $clauses) { if (-not (Test-PortablePythonConstraint -Constraint $clause -Version $item.Version)) { $ok=$false; break } }
            if ($ok) { $compatible += $item }
        }
        if ($compatible.Count -gt 0) {
            $best = $compatible[0]
            foreach ($item in $compatible | Select-Object -Skip 1) { if ((Compare-PortableVersion (ConvertTo-PortableVersionTuple $item.Version) (ConvertTo-PortableVersionTuple $best.Version)) -gt 0) { $best=$item } }
            return [pscustomobject]@{ Supported=$true; Status='Compatible'; RequiredVersion=if ($clauses.Count) { $clauses -join ', ' } else { '(项目未声明)' }; PythonPath=$best.PythonPath; UvPath=(Get-PortableUvPath $StickRoot); DependenciesPending=($requirements.DependencyFiles.Count -gt 0); Message="兼容：工具箱 Python $($best.Version)；此检查未创建环境或安装依赖。" }
        }
        $available = @($inventory | ForEach-Object { if ($_.Version) { $_.Version } else { '版本查询失败' } }) -join ', '
        return [pscustomobject]@{ Supported=$false; Status='VersionUnavailable'; RequiredVersion=if ($clauses.Count) { $clauses -join ', ' } else { '(未检测到工具箱 Python)' }; PythonPath=$null; UvPath=(Get-PortableUvPath $StickRoot); DependenciesPending=($requirements.DependencyFiles.Count -gt 0); Message="工具箱 Python 与项目要求不兼容。要求 $($clauses -join ', ')；可用版本：$available。" }
    } catch { return [pscustomobject]@{ Supported=$false; Status='Error'; RequiredVersion=$null; PythonPath=$null; UvPath=$null; DependenciesPending=$false; Message=$_.Exception.Message } }
}

function Get-PortableEnvironmentKey {
    param($Requirements, $Interpreter)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append($Requirements.ProjectPath.ToLowerInvariant()).Append("`n").Append($Interpreter.Version).Append("`n").Append($Interpreter.PythonPath.ToLowerInvariant()).Append("`n")
        foreach ($file in @($Requirements.DependencyFiles | Sort-Object Name)) {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            [void]$builder.Append($file.Name.ToLowerInvariant()).Append(':').Append($hash).Append("`n")
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Test-PortablePathHasReparseComponent {
    param([string]$BasePath, [string]$TargetPath)
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($TargetPath)
    if (-not $target.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $relative = $target.Substring($base.Length).TrimStart('\')
    $current = $base
    foreach ($part in $relative.Split('\')) {
        if (-not $part) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
    }
    return $false
}

function Invoke-PortableUvVenv {
    param([string]$UvPath, [string]$PythonPath, [string]$EnvironmentPath, [string]$CachePath)
    $saved = @{}
    $oldErrorActionPreference = $ErrorActionPreference
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UV_*' -or $_.Name -in @('VIRTUAL_ENV','PYTHONHOME','PYTHONPATH') })) { $saved[$item.Name] = $item.Value }
    try {
        foreach ($name in @($saved.Keys)) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        $env:UV_LINK_MODE = 'copy'
        $env:UV_PYTHON_DOWNLOADS = 'never'
        $env:UV_CACHE_DIR = $CachePath
        $ErrorActionPreference = 'Continue'
        $output = @(& $UvPath venv --python $PythonPath $EnvironmentPath 2>&1)
        $exit = $LASTEXITCODE
        if ($exit -ne 0) { throw "uv 创建项目环境失败（退出码 $exit）：$($output -join ' ')" }
        return ($output -join "`n")
    } finally {
        foreach ($name in @('UV_LINK_MODE','UV_PYTHON_DOWNLOADS','UV_CACHE_DIR')) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        foreach ($name in @($saved.Keys)) { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function Initialize-PortablePythonEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string]$WorkPath,
        [Parameter(Mandatory)][string]$ProjectPath
    )
    $result = [ordered]@{ Status='Unavailable'; Requested=$true; Supported=$false; RequiredVersion=$null; PythonPath=$null; UvPath=$null; EnvironmentPath=$null; Ready=$false; DependenciesPending=$false; Message='' }
    try {
        $root = [IO.Path]::GetFullPath($StickRoot); $work = [IO.Path]::GetFullPath($WorkPath)
        $inventory = @(Get-PortablePythonInventory -StickRoot $root)
        $result.UvPath = Get-PortableUvPath -StickRoot $root
        if (-not $result.UvPath) { $result.Message = "工具箱缺少 uv：$root\runtime\uv\uv.exe。请按 docs\Python环境管理.md 手动安装受支持运行时。"; return [pscustomobject]$result }
        if ($inventory.Count -eq 0) { $result.Message = "工具箱 runtime 下没有可运行的内置 Python。不会回退到宿主 Python；请按 docs\Python环境管理.md 手动安装。"; return [pscustomobject]$result }
        $requirements = Get-PortableProjectRequirements -ProjectPath $ProjectPath
        if ($requirements.Unsupported) { $result.Status='UnsupportedRequirement'; $result.Message=$requirements.Unsupported; return [pscustomobject]$result }
        $clauses = @()
        if ($requirements.RequiresPython) { $clauses += $requirements.RequiresPython }
        if ($requirements.PythonVersionPin) {
            if ($requirements.PythonVersionPin -match '^\d+\.\d+$') { $clauses += "==$($requirements.PythonVersionPin).*" }
            else { $clauses += "==$($requirements.PythonVersionPin)" }
        }
        $result.RequiredVersion = if ($clauses.Count) { $clauses -join ', ' } else { '(项目未声明)' }
        $compatible = @()
        foreach ($item in $inventory) {
            if (-not $item.Version) { continue }
            $ok = $true
            foreach ($clause in $clauses) { if (-not (Test-PortablePythonConstraint -Constraint $clause -Version $item.Version)) { $ok=$false; break } }
            if ($ok) { $compatible += $item }
        }
        if ($compatible.Count -eq 0) {
            $found = @($inventory | ForEach-Object { if ($_.Version) { $_.Version } else { '版本查询失败' } }) -join ', '
            $result.Status='VersionUnavailable'; $result.Message="项目要求 Python $($result.RequiredVersion)，工具箱内可用版本：$found。当前不会下载或调用宿主 Python；请手动安装兼容版到 runtime\python 或 runtime\python-<版本>。"; return [pscustomobject]$result
        }
        $selected = $compatible[0]
        foreach ($candidate in $compatible | Select-Object -Skip 1) {
            if ((Compare-PortableVersion (ConvertTo-PortableVersionTuple $candidate.Version) (ConvertTo-PortableVersionTuple $selected.Version)) -gt 0) { $selected = $candidate }
        }
        $result.PythonPath=$selected.PythonPath; $result.Supported=$true
        $key = Get-PortableEnvironmentKey -Requirements $requirements -Interpreter $selected
        $envRoot = Join-Path $work 'python-envs'; $environment = Join-Path $envRoot $key
        $result.EnvironmentPath=$environment
        if (-not (Test-PortablePathHasReparseComponent -BasePath $work -TargetPath $environment)) { }
        else { $result.Status='UnsafePath'; $result.Message='目标虚拟环境路径越界或经过重解析点，已拒绝写入。'; return [pscustomobject]$result }
        if (-not (Test-Path -LiteralPath $envRoot -PathType Container)) { New-Item -ItemType Directory -Path $envRoot -Force | Out-Null }
        if (Test-PortablePathHasReparseComponent -BasePath $work -TargetPath $environment) { $result.Status='UnsafePath'; $result.Message='目标虚拟环境路径经过重解析点，已拒绝写入。'; return [pscustomobject]$result }
        $marker = Join-Path $environment '.portable-python-env.json'
        $venvPython = Join-Path $environment 'Scripts\python.exe'
        $reuse = $false
        if (Test-Path -LiteralPath $environment) {
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                try { $data = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) | ConvertFrom-Json; if ($data.Key -eq $key) { $reuse = $true } } catch { }
            }
            if (-not $reuse) { $result.Status='EnvironmentCollision'; $result.Message="目标目录已存在但不是可验证的工具箱环境：$environment。为避免删除未知数据，已停止。"; return [pscustomobject]$result }
        } else {
            [void](Invoke-PortableUvVenv -UvPath $result.UvPath -PythonPath $selected.PythonPath -EnvironmentPath $environment -CachePath (Join-Path $root 'cache\uv'))
            if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw 'uv 返回成功但虚拟环境 Python 不存在。' }
            $meta = [ordered]@{ Key=$key; ProjectPath=$requirements.ProjectPath; PythonVersion=$selected.Version; CreatedAt=(Get-Date).ToString('o') }
            [IO.File]::WriteAllText($marker, ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
        }
        $result.Status=if ($requirements.DependencyFiles.Count -gt 0) { 'DependenciesPending' } else { 'Ready' }
        $result.DependenciesPending=($requirements.DependencyFiles.Count -gt 0)
        $result.Ready=(-not $result.DependenciesPending)
        if ($reuse) { $verb='复用' } else { $verb='已创建' }
        if ($result.DependenciesPending) { $result.Message="$verb Python $($selected.Version) 虚拟环境；发现依赖清单但没有安装依赖，因此 Ready=false。请在联网策略允许时显式安装依赖。" }
        else { $result.Message="$verb Python $($selected.Version) 空虚拟环境；项目没有已识别的依赖清单。" }
        return [pscustomobject]$result
    } catch {
        $result.Status='Error'; $result.Message=$_.Exception.Message
        return [pscustomobject]$result
    }
}

function Invoke-PortablePython {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PythonPath, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw "指定的工具箱 Python 不存在: $PythonPath" }
    & $PythonPath @Arguments
    return $LASTEXITCODE
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($Action -eq 'inventory') {
            $items = @(Get-PortablePythonInventory -StickRoot $StickRoot)
            $uv = Get-PortableUvPath -StickRoot $StickRoot
            if ($items.Count -eq 0) { Write-Host '未发现可用的工具箱内置 Python。'; exit 1 }
            foreach ($item in $items) { Write-Host ("Python {0}: {1}" -f $item.Version, $item.PythonPath) }
            if ($uv) { Write-Host "uv: $uv" } else { Write-Host 'uv: 缺失' }
            exit 0
        }
        if ($Action -eq 'check') { $r = Test-PortablePythonProject -StickRoot $StickRoot -ProjectPath $ProjectPath }
        else { $r = Initialize-PortablePythonEnvironment -StickRoot $StickRoot -WorkPath $WorkPath -ProjectPath $ProjectPath }
        Write-Host $r.Message
        if ($r.PythonPath) { Write-Host "Python: $($r.PythonPath)" }
        if ($r.PSObject.Properties['EnvironmentPath'] -and $r.EnvironmentPath) { Write-Host "环境: $($r.EnvironmentPath)" }
        if ($r.PSObject.Properties['DependenciesPending'] -and $r.DependenciesPending) { Write-Host '依赖状态：待安装' }
        if (-not $r.Supported -or $r.Status -in @('Error','UnsafePath','EnvironmentCollision','VersionUnavailable','UnsupportedRequirement')) { exit 1 }
        exit 0
    } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}

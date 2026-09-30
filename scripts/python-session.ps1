# Apply the selected Python to this launch process only.
function Set-PortablePythonSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$StickRoot,
        [Parameter(Mandatory)][string]$WorkPath
    )
    $env:UV_PYTHON_DOWNLOADS = 'never'
    $env:PYTHONNOUSERSITE = '1'
    Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
    Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
    $venvPython = $null
    if ($State.EnvironmentPath) { $venvPython = Join-Path $State.EnvironmentPath 'Scripts\python.exe' }
    if ($State.Supported -and $venvPython -and (Test-Path -LiteralPath $venvPython -PathType Leaf) -and
        $State.Status -in @('Ready', 'DependenciesPending')) {
        $commandDir = Join-Path $WorkPath 'python-commands'
        [void][IO.Directory]::CreateDirectory($commandDir)
        $pipMessage = "@echo off`r`necho [ERROR] This environment has no pip executable. Use uv pip instead. 1>&2`r`nexit /b 1`r`n"
        foreach ($name in @('pip.cmd', 'pip3.cmd')) {
            [IO.File]::WriteAllText((Join-Path $commandDir $name), $pipMessage, [Text.Encoding]::ASCII)
        }
        $python3Command = '@echo off' + "`r`n" + '"%AISTICK_PYTHON%" %*' + "`r`n" + 'exit /b %ERRORLEVEL%' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $commandDir 'python3.cmd'), $python3Command, [Text.Encoding]::ASCII)
        # A missing pip must not fall through to the shared base installation.
        $env:PATH = (Split-Path -Parent $venvPython) + ';' + $commandDir + ';' + $env:PATH
        $env:UV_PYTHON = $venvPython
        $env:VIRTUAL_ENV = $State.EnvironmentPath
        # This process is bound to the launcher's chosen project. Each window
        # gets a different WorkPath; project commands must not touch its .venv.
        $env:UV_PROJECT_ENVIRONMENT = $State.EnvironmentPath
        $env:AISTICK_PYTHON = $venvPython
        $env:AISTICK_PYTHON_ENV = $State.EnvironmentPath
        return $venvPython
    }

    # Prevent an incompatible base interpreter from looking like a usable project
    # Python. These launch-local shims give a clear failure without blocking the AI.
    $shimDir = Join-Path $WorkPath 'python-unavailable'
    [void][IO.Directory]::CreateDirectory($shimDir)
    $message = "@echo off`r`necho [ERROR] Project Python is unavailable. See the launcher Python status. 1>&2`r`nexit /b 1`r`n"
    foreach ($name in @('python.cmd', 'python3.cmd', 'pip.cmd', 'pip3.cmd')) {
        [IO.File]::WriteAllText((Join-Path $shimDir $name), $message, [Text.Encoding]::ASCII)
    }
    $runtime = [IO.Path]::GetFullPath((Join-Path $StickRoot 'runtime')).TrimEnd('\') + '\'
    $parts = @($env:PATH -split ';' | Where-Object {
        if (-not $_) { return $false }
        $full = [IO.Path]::GetFullPath($_)
        return -not ($full.StartsWith($runtime, [StringComparison]::OrdinalIgnoreCase) -and
            $full.Substring($runtime.Length) -match '^python(?:-[^\\]+)?(?:\\|$)')
    })
    $env:PATH = $shimDir + ';' + ($parts -join ';')
    $env:UV_PYTHON = Join-Path $shimDir 'python.exe'
    $env:UV_PROJECT_ENVIRONMENT = Join-Path $shimDir 'blocked-project-environment'
    $env:VIRTUAL_ENV = $env:UV_PROJECT_ENVIRONMENT
    Remove-Item Env:AISTICK_PYTHON -ErrorAction SilentlyContinue
    Remove-Item Env:AISTICK_PYTHON_ENV -ErrorAction SilentlyContinue
    return $null
}

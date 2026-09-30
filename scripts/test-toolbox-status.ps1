[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toolbox-status.ps1')

function Assert-StatusTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS: $Message" -ForegroundColor Green
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('toolbox-status-test-' + [guid]::NewGuid().ToString('N'))
$stick = Join-Path $fixture 'stick'
$temp = Join-Path $fixture 'temp'
try {
    New-Item -ItemType Directory -Path (Join-Path $stick 'config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stick 'runtime\uv') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stick 'runtime\python') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stick 'runtime\python-3.12') -Force | Out-Null
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stick 'runtime\python\python.exe'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $stick 'runtime\python-3.12\python.exe'), 'fixture')

    $keys = Join-Path $stick 'config\keys.env'
    [IO.File]::WriteAllText($keys, 'TOKEN=synthetic-status-secret')
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp -ProjectContext @{
        Project = 'demo'; Supplier = 'fixture'; Tool = 'claude'; Extra = 'must-not-display'
    }
    Assert-StatusTest ($status.Vault.State -eq 'Missing' -and $status.Credentials.Source -eq 'KeysEnv') 'keys.env is reported by existence without reading content'
    Assert-StatusTest (-not $status.Credentials.ContentValidated -and -not $status.Credentials.NeedsUnlockValidation) 'legacy credential contents remain unverified'
    Assert-StatusTest ($status.Context.Project -eq 'demo' -and $status.Context.Supplier -eq 'fixture' -and $status.Context.Tool -eq 'claude') 'only explicit context fields are returned'
    Assert-StatusTest ($status.Runtime.PythonInstalled -and $status.Runtime.PythonPaths.Count -eq 2 -and -not $status.Runtime.UvInstalled) 'portable Python paths and uv state are summarized'

    $validVaultMetadata = '{"format":"portable-credential-vault","version":1,"kdf":"PBKDF2-HMAC-SHA256","iterations":600000,"cipher":"AES-256-CBC-PKCS7"}'
    [IO.File]::WriteAllText((Join-Path $stick 'config\credentials.vault.json'), $validVaultMetadata)
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp
    Assert-StatusTest ($status.Vault.State -eq 'Locked' -and $status.Credentials.Source -eq 'Vault' -and $status.Credentials.NeedsUnlockValidation) 'vault takes precedence over keys.env and stays locked'
    [IO.File]::WriteAllText((Join-Path $stick 'config\credentials.vault.json'), '{"format":"wrong"}')
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp
    Assert-StatusTest ($status.Vault.State -eq 'InvalidFormat' -and -not $status.Credentials.NeedsUnlockValidation) 'invalid vault metadata is distinguished from a locked valid vault'

    Remove-Item -LiteralPath (Join-Path $stick 'config\credentials.vault.json') -Force
    [IO.File]::WriteAllText((Join-Path $stick 'config\credentials.vault.json.bak'), 'opaque')
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp
    Assert-StatusTest ($status.Vault.State -eq 'RecoveryRequired' -and $status.Credentials.Source -eq 'Vault') 'vault sidecar prevents fallback to keys.env'

    $pendingId = [guid]::NewGuid().ToString()
    $pending = Join-Path $temp "aistick-$pendingId"
    New-Item -ItemType Directory -Path $pending -Force | Out-Null
    $marker = [pscustomobject]@{
        sessionId = $pendingId; sessionRoot = [IO.Path]::GetFullPath($pending)
        tempRoot = [IO.Path]::GetFullPath($temp); recoveryRequired = $true
        recoveryReason = 'synthetic marker content must not be returned'
    }
    [IO.File]::WriteAllText((Join-Path $pending '.session-owner.json'), ($marker | ConvertTo-Json))
    $unknownId = [guid]::NewGuid().ToString()
    $unknown = Join-Path $temp "aistick-$unknownId"
    New-Item -ItemType Directory -Path $unknown -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown '.session-owner.json'), '{ invalid marker secret }')
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp
    Assert-StatusTest ($status.Recovery.PendingCount -eq 1 -and $status.Recovery.PendingPaths[0] -eq [IO.Path]::GetFullPath($pending)) 'only a valid owned recovery marker yields a pending path'
    Assert-StatusTest ($status.Recovery.UnknownCount -eq 1 -and $status.Recovery.UnknownPaths[0] -eq [IO.Path]::GetFullPath($unknown)) 'malformed ownership markers are reported as unknown, not normal'
    Assert-StatusTest (($status | ConvertTo-Json -Depth 8) -notmatch 'synthetic marker content|invalid marker secret|synthetic-status-secret') 'status output contains no marker or credential contents'

    Remove-Item -LiteralPath (Join-Path $stick 'config\credentials.vault.json.bak') -Force
    [IO.File]::WriteAllText((Join-Path $stick 'config\credentials.vault.json.restore.tmp'), 'opaque recovery fixture')
    $status = Get-ToolboxStatus -StickRoot $stick -TempRoot $temp
    Assert-StatusTest ($status.Vault.State -eq 'RecoveryRequired' -and $status.Credentials.Source -eq 'Vault') 'restore staging file blocks fallback to keys.env'
    Remove-Item -LiteralPath (Join-Path $stick 'config\credentials.vault.json.restore.tmp') -Force
    [IO.File]::WriteAllText((Join-Path $stick 'config\credentials.vault.json'), $validVaultMetadata)
    $ps = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $ps -PathType Leaf)) { $ps = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $selfcheckOutput = @(& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'selfcheck.ps1') -StickRoot $stick 2>&1 | ForEach-Object { [string]$_ })
    Assert-StatusTest ($LASTEXITCODE -eq 0) 'selfcheck completes with a synthetic toolbox root'
    Assert-StatusTest (($selfcheckOutput -join "`n") -notmatch 'synthetic-status-secret|前4位|TOKEN=') 'selfcheck does not display secret fragments or credential lines'
    Assert-StatusTest (($selfcheckOutput -join "`n") -match '保险箱存在；内容未验证') 'selfcheck reports an unverified vault without unlocking'

    Write-Host 'All toolbox status tests passed.' -ForegroundColor Cyan
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'cc-switch.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cc-switch-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$ExpectedText)
    $caught = $null
    try { & $Script | Out-Null } catch { $caught = $_ }
    if (-not $caught) { throw "Expected failure containing: $ExpectedText" }
    if ($caught.Exception.Message -notlike "*$ExpectedText*") { throw $caught }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Script)
    try {
        & $Script
        $script:passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Write-TestJson {
    param([string]$Path, [string]$BaseUrl, [string]$AuthToken, [string]$ApiKey, [string]$Model)
    $envBlock = [ordered]@{ ANTHROPIC_BASE_URL = $BaseUrl }
    if ($AuthToken -ne $null) { $envBlock.ANTHROPIC_AUTH_TOKEN = $AuthToken }
    if ($ApiKey -ne $null) { $envBlock.ANTHROPIC_API_KEY = $ApiKey }
    if ($Model -ne $null) { $envBlock.ANTHROPIC_MODEL = $Model }
    $json = [ordered]@{
        env = $envBlock
        permissions = [ordered]@{ allow = @('Bash(*)') }
        arbitrarySecret = 'must-not-be-returned'
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $profileFile = Join-Path $testRoot 'claude-settings.json'
    $record = $null

    Invoke-Test 'reads only Claude fields and keeps the credential secure' {
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.example.test/v1/' -AuthToken 'synthetic-token-123' -ApiKey $null -Model 'synthetic-model'
        $record = & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Synthetic provider'
        Assert-True ($record.Name -eq 'Synthetic provider') 'Name was not returned.'
        Assert-True ($record.BaseUrl -eq 'https://api.example.test/v1') 'BaseUrl was not normalized.'
        Assert-True ($record.Secret -is [Security.SecureString]) 'Secret was not returned as SecureString.'
        Assert-True ($record.AuthEnvironmentName -eq 'ANTHROPIC_AUTH_TOKEN') 'Auth token variable identity was lost.'
        Assert-True ($record.Models.Count -eq 1 -and $record.Models['ANTHROPIC_MODEL'] -eq 'synthetic-model') 'Models contains unexpected values.'
        Assert-True (-not $record.Models.Contains('arbitrarySecret')) 'Non-model fields were returned.'
        Assert-True (-not ($record | ConvertTo-Json -Depth 4).Contains('synthetic-token-123')) 'Plain secret appeared in serialized output.'
    }

    Invoke-Test 'rejects the local routing placeholder' {
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.example.test/v1' -AuthToken 'PROXY_MANAGED' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Placeholder' } 'proxy placeholders'
    }

    Invoke-Test 'rejects loopback and localhost endpoints' {
        Write-TestJson -Path $profileFile -BaseUrl 'http://127.0.0.1:15721' -AuthToken 'synthetic-token-123' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Loopback' } 'Localhost and loopback'
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.localhost/v1' -AuthToken 'synthetic-token-123' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Localhost' } 'Localhost and loopback'
    }

    Invoke-Test 'rejects ambiguous credentials, URL userinfo, query, and fragment' {
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.example.test/v1' -AuthToken 'token-a' -ApiKey 'key-b' -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Ambiguous' } 'both Claude auth token and API key'
        Write-TestJson -Path $profileFile -BaseUrl 'https://user:pass@api.example.test/v1' -AuthToken 'token-a' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Userinfo' } 'without embedded credentials'
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.example.test/v1?key=hidden' -AuthToken 'token-a' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Query' } 'without embedded credentials'
        Write-TestJson -Path $profileFile -BaseUrl 'https://api.example.test/v1#hidden' -AuthToken 'token-a' -ApiKey $null -Model $null
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Fragment' } 'without embedded credentials'
    }

    Invoke-Test 'only returns the Claude model environment allowlist' {
        $json = '{"env":{"ANTHROPIC_BASE_URL":"https://api.example.test/v1","ANTHROPIC_API_KEY":"synthetic-api-key","ANTHROPIC_DEFAULT_SONNET_MODEL":"synthetic-sonnet","ANTHROPIC_EXTRA_SECRET":"hidden-env-secret"},"unrelated":"hidden-root-secret"}'
        [IO.File]::WriteAllText($profileFile, $json, (New-Object Text.UTF8Encoding($false)))
        $record = & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Allowlist'
        Assert-True ($record.AuthEnvironmentName -eq 'ANTHROPIC_API_KEY') 'API key variable identity was lost.'
        Assert-True ($record.Models.Count -eq 1 -and $record.Models['ANTHROPIC_DEFAULT_SONNET_MODEL'] -eq 'synthetic-sonnet') 'Models did not contain only allowed model values.'
        Assert-True (-not ($record | ConvertTo-Json -Depth 4).Contains('synthetic-api-key')) 'API key appeared in profile output.'
        Assert-True (-not ($record | ConvertTo-Json -Depth 4).Contains('hidden-env-secret')) 'Unrecognized env value appeared in profile output.'
        Assert-True (-not ($record | ConvertTo-Json -Depth 4).Contains('hidden-root-secret')) 'Unrelated root value appeared in profile output.'
    }

    Invoke-Test 'rejects an invalid model before returning or creating a secret object' {
        $json = '{"env":{"ANTHROPIC_BASE_URL":"https://api.example.test/v1","ANTHROPIC_API_KEY":"synthetic-api-key","ANTHROPIC_MODEL":"bad\nmodel"}}'
        [IO.File]::WriteAllText($profileFile, $json, (New-Object Text.UTF8Encoding($false)))
        $output = @()
        try { $output = @(& $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Bad model') } catch { }
        Assert-True ($output.Count -eq 0) 'Invalid model validation emitted an object.'
    }

    Invoke-Test 'uses a generic JSON parse error without echoing file contents' {
        [IO.File]::WriteAllText($profileFile, '{ invalid-json synthetic-secret }', (New-Object Text.UTF8Encoding($false)))
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Invalid' } 'not valid JSON'
    }

    Invoke-Test 'rejects files over one MiB' {
        $largeJson = '{"env":{},"padding":"' + ('x' * 1048600) + '"}'
        [IO.File]::WriteAllText($profileFile, $largeJson, (New-Object Text.UTF8Encoding($false)))
        Assert-Throws { & $modulePath -Action ReadClaudeProfile -ProfilePath $profileFile -ProfileName 'Oversize' } 'exceeds the 1 MiB safety limit'
    }

    Invoke-Test 'reports isolation blocked and refuses GUI launch' {
        $status = & $modulePath -Action Status -PackageRoot $testRoot
        Assert-True ($status.Status -eq 'BlockedPortableIsolation' -and -not $status.LaunchAllowed) 'Status did not report the isolation block.'
        Assert-Throws { & $modulePath -Action Launch -PackageRoot $testRoot } 'has not passed validation'
    }

    Invoke-Test 'refuses an unverified archive without extracting it' {
        $fakeZip = Join-Path $testRoot 'unverified.zip'
        [IO.File]::WriteAllBytes($fakeZip, [byte[]](1, 2, 3, 4))
        Assert-Throws { & $modulePath -Action Prepare -PackageRoot (Join-Path $testRoot 'prepared') -ArchivePath $fakeZip } 'SHA-256 does not match'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'prepared\app'))) 'Prepare created an app directory for an unverified archive.'
    }

    Invoke-Test 'Prepare accepts the pinned archive without session/data path arguments' {
        $repoPackage = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\cc-switch'
        $archive = Join-Path $repoPackage 'CC-Switch-v3.20.4-Windows-Portable.zip'
        $status = & $modulePath -Action Prepare -PackageRoot $repoPackage -ArchivePath $archive
        Assert-True $status.ArchiveVerified 'Pinned official archive did not verify.'
        Assert-True $status.AppPrepared 'Pinned official app files were not prepared.'
        Assert-True $status.ExtractedFilesVerified 'Extracted executable was not independently verified.'
    }

    Invoke-Test 'tampered extracted executable is rejected without being overwritten' {
        $archive = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\cc-switch\CC-Switch-v3.20.4-Windows-Portable.zip'
        $isolatedPackage = Join-Path $testRoot 'tampered-package'
        $null = & $modulePath -Action Prepare -PackageRoot $isolatedPackage -ArchivePath $archive
        $exe = Join-Path $isolatedPackage 'app\cc-switch.exe'
        $bytes = [IO.File]::ReadAllBytes($exe)
        $bytes[100] = $bytes[100] -bxor 1
        [IO.File]::WriteAllBytes($exe, $bytes)
        $tamperedHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        $status = & $modulePath -Action Status -PackageRoot $isolatedPackage -ArchivePath $archive
        Assert-True $status.ArchiveVerified 'Official archive unexpectedly failed.'
        Assert-True (-not $status.AppPrepared -and -not $status.ExtractedFilesVerified) 'Status trusted the tampered executable.'
        Assert-Throws { & $modulePath -Action Prepare -PackageRoot $isolatedPackage -ArchivePath $archive } 'do not match the verified official archive'
        Assert-True ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq $tamperedHash) 'Prepare overwrote existing tampered files.'
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup path escaped the temp directory.' }
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}

Write-Host "`nCC Switch checks: $passed passed, $failed failed."
if ($failed -gt 0) { exit 1 }

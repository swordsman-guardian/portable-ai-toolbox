[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-claude-launch-files.ps1')

$script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cc-claude-launch-files-' + [guid]::NewGuid().ToString('N'))
$script:passed = 0
$script:failed = 0
$script:revision = '0123456789abcdef0123456789abcdef'
$script:fixtureFiles = @()

function Get-CcEncryptedStoreStatus([string]$StickRoot) {
    return [pscustomobject]@{ CurrentRevision = [string]$script:revision }
}
function Get-CcEncVerifiedZip([string]$Store, [string]$Revision, [byte[]]$Key) {
    if ($Revision -cne $script:revision) { throw 'Synthetic revision mismatch.' }
    return New-FakeVerifiedZip $script:fixtureFiles
}
function New-FakeVerifiedZip($Files) {
    Add-Type -AssemblyName System.IO.Compression
    $memory = New-Object IO.MemoryStream
    $writer = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $Files) {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$file.Content)
        $entry = $writer.CreateEntry([string]$file.Path)
        $stream = $entry.Open()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $records.Add([pscustomobject]@{ path = [string]$file.Path; length = $bytes.Length; sha256 = ('0' * 64) })
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    $writer.Dispose()
    $memory.Position = 0
    $reader = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read, $true)
    return [pscustomobject]@{ Zip = $reader; Stream = $memory; Plain = (New-Object byte[] 0); Manifest = [pscustomobject]@{ files = $records.ToArray() } }
}
function Set-FakeFiles($Files) { $script:fixtureFiles = @($Files) }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Script, [string]$Message) {
    $failure = $null
    try { & $Script | Out-Null } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -notlike "*$Message*") { throw "Expected error containing '$Message'. Actual: $($failure.Exception.Message)" }
}
function Invoke-Case([string]$Name, [scriptblock]$Script) {
    try { & $Script; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-RegisteredSession {
    $temp = Join-Path $script:testRoot 'temp'
    [void][IO.Directory]::CreateDirectory($temp)
    $id = [guid]::NewGuid().ToString()
    $root = Join-Path $temp ('aistick-' + $id)
    $work = Join-Path $root 'work'
    $guard = Join-Path $root 'guard'
    $config = Join-Path $work 'config\claude'
    [void][IO.Directory]::CreateDirectory($config)
    [void][IO.Directory]::CreateDirectory($guard)
    $proc = Get-Process -Id $PID
    $marker = [pscustomobject]@{
        schema = 1; sessionId = $id; sessionRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        tempRoot = [IO.Path]::GetFullPath($temp).TrimEnd('\'); ownerProcessId = $PID
        ownerStartTimeUtc = $proc.StartTime.ToUniversalTime().ToString('o'); createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $root '.session-owner.json'), ($marker | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Root = $root; Work = $work; Config = $config; Id = $id }
}

try {
    [void][IO.Directory]::CreateDirectory($script:testRoot)
    $stick = Join-Path $script:testRoot 'usb'
    [void][IO.Directory]::CreateDirectory($stick)
    $session = [pscustomobject]@{ StickRoot = $stick; DataKey = (New-Object byte[] 32); Locked = $false; Revision = $script:revision }
    $launchSession = New-RegisteredSession
    $files = @(
        [pscustomobject]@{ Path = 'harness/cc-switch/claude/settings.json'; Content = '{"name":"snapshot-provider","env":{"ANTHROPIC_BASE_URL":"https://synthetic.invalid/v1","ANTHROPIC_AUTH_TOKEN":"synthetic","ANTHROPIC_MODEL":"fixture-model"},"hooks":{"keep":true},"permissions":{"allow":["Bash(*)"]}}' },
        [pscustomobject]@{ Path = 'harness/cc-switch/claude/.claude.json'; Content = '{"hasCompletedOnboarding":true}' },
        [pscustomobject]@{ Path = 'harness/cc-switch/claude/CLAUDE.md'; Content = 'fixture instructions' },
        [pscustomobject]@{ Path = 'harness/cc-switch/claude/skills/review/SKILL.md'; Content = 'name: review' },
        [pscustomobject]@{ Path = 'harness/cc-switch/codex/settings.json'; Content = '{"ignore":true}' }
    )

    Invoke-Case 'exports the complete Claude subtree and preserves nested paths' {
        Set-FakeFiles $files
        $bundle = Get-CcEncryptedClaudeLaunchBundle -Session $session
        try {
            Assert-True ($bundle.Revision -eq $script:revision) 'Bundle revision mismatch.'
            Assert-True ($bundle.Provider.Name -eq 'snapshot-provider') 'Provider did not come from the bundled settings snapshot.'
            Assert-True ($bundle.Provider.Secret -is [Security.SecureString]) 'Bundle provider credential was not protected.'
            Assert-True ($bundle.Provider.Models['ANTHROPIC_MODEL'] -eq 'fixture-model') 'Bundle provider model mismatch.'
        } finally { $bundle.Provider.Secret.Dispose() }
        $exported = @(Get-CcEncryptedClaudeLaunchFiles -Session $session)
        Assert-True ($exported.Count -eq 4) 'Claude subtree export omitted or included an unrelated harness file.'
        $skill = $exported | Where-Object { $_.Path -eq 'skills/review/SKILL.md' }
        Assert-True ($null -ne $skill) 'Nested skills file was not exported.'
        $settings = $exported | Where-Object { $_.Path -eq 'settings.json' }
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($settings.ContentBase64))
        Assert-True ($text.Contains('synthetic') -and $text.Contains('Bash(*)')) 'Settings fields or credential bytes were changed.'
    }
    Invoke-Case 'imports into registered session config after prevalidation' {
        Set-FakeFiles $files
        $exported = @(Get-CcEncryptedClaudeLaunchFiles -Session $session)
        $count = Set-CcClaudeLaunchFiles -Files $exported -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root
        Assert-True ($count -eq 4) 'Unexpected file count imported.'
        Assert-True (([IO.File]::ReadAllText((Join-Path $launchSession.Config 'settings.json'))).Contains('Bash(*)')) 'Full settings document was not preserved.'
        Assert-True (([IO.File]::ReadAllText((Join-Path $launchSession.Config '.claude.json'))).Contains('hasCompletedOnboarding')) '.claude.json was not imported.'
        Assert-True (([IO.File]::ReadAllText((Join-Path $launchSession.Config 'skills\review\SKILL.md')) -eq 'name: review')) 'Nested skill did not land in session config.'
    }
    Invoke-Case 'clears old config-only files while preserving the explicit history allowlist' {
        foreach ($rel in @('settings.local.json','.claude.json','config.json','backups\old.json','skills\legacy\SKILL.md')) {
            $path = Join-Path $launchSession.Config $rel
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path, 'old-config', (New-Object Text.UTF8Encoding($false)))
        }
        foreach ($rel in @('projects\fixture\history.jsonl','file-history\entry.txt','plans\plan.md','tasks\task.md','teams\team.md','history.jsonl')) {
            $path = Join-Path $launchSession.Config $rel
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path, 'synthetic-history', (New-Object Text.UTF8Encoding($false)))
        }
        Set-FakeFiles $files
        $settingsRecord = @(Get-CcEncryptedClaudeLaunchFiles -Session $session | Where-Object { $_.Path -ceq 'settings.json' })
        $count = Set-CcClaudeLaunchFiles -Files $settingsRecord -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root
        Assert-True ($count -eq 1) 'Expected one current configuration file to be restored.'
        foreach ($rel in @('settings.local.json','.claude.json','config.json','backups','skills\legacy')) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchSession.Config $rel))) "Old config residue remains: $rel"
        }
        foreach ($rel in @('projects\fixture\history.jsonl','file-history\entry.txt','plans\plan.md','tasks\task.md','teams\team.md','history.jsonl')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $launchSession.Config $rel)) "History was not preserved: $rel"
        }
    }
    Invoke-Case 'locked session is rejected' {
        $locked = [pscustomobject]@{ StickRoot = $stick; DataKey = $session.DataKey; Locked = $true; Revision = $script:revision }
        Assert-Throws { Get-CcEncryptedClaudeLaunchFiles -Session $locked } 'session is locked'
    }
    Invoke-Case 'stale encrypted revision is rejected' {
        $stale = [pscustomobject]@{ StickRoot = $stick; DataKey = $session.DataKey; Locked = $false; Revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        Assert-Throws { Get-CcEncryptedClaudeLaunchFiles -Session $stale } 'revision is stale'
    }
    Invoke-Case 'duplicate or case-conflicting paths are rejected before writes' {
        $before = [IO.Directory]::GetFiles($launchSession.Config, '*', [IO.SearchOption]::AllDirectories).Count
        $dupes = @(
            [pscustomobject]@{ Path = 'settings.json'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('one')) },
            [pscustomobject]@{ Path = 'SETTINGS.JSON'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('two')) }
        )
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $dupes -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root } 'duplicate or case-conflicting'
        Assert-True ([IO.Directory]::GetFiles($launchSession.Config, '*', [IO.SearchOption]::AllDirectories).Count -eq $before) 'Invalid import wrote files.'
    }
    Invoke-Case 'traversal paths are rejected before writes' {
        $escape = @([pscustomobject]@{ Path = '../outside.txt'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('no')) })
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $escape -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root } 'invalid component'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchSession.Work 'outside.txt'))) 'Traversal wrote outside ConfigDir.'
        $backslash = @([pscustomobject]@{ Path = 'skills/a\..\settings.json'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('no')) })
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $backslash -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root } 'file path is invalid'
    }
    Invoke-Case 'file and directory path collisions are rejected before writes' {
        $collision = @(
            [pscustomobject]@{ Path = 'collision'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('file')) },
            [pscustomobject]@{ Path = 'collision/new.md'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('child')) }
        )
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $collision -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root } 'path collision'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchSession.Config 'collision'))) 'Collision import wrote a file.'
    }
    Invoke-Case 'wrong or unregistered destination is rejected' {
        $single = @([pscustomobject]@{ Path = 'settings.json'; ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x')) })
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $single -ConfigDir $launchSession.Work -SessionRoot $launchSession.Root } 'must be the registered session'
        $fake = Join-Path $script:testRoot 'unregistered'
        [void][IO.Directory]::CreateDirectory($fake)
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $single -ConfigDir $launchSession.Config -SessionRoot $fake } 'not a registered AIStick launch session'
    }
    Invoke-Case 'oversized import is rejected before writing' {
        $large = New-Object byte[] (8MB + 1)
        $tooLarge = @([pscustomobject]@{ Path = 'large.bin'; ContentBase64 = [Convert]::ToBase64String($large) })
        Assert-Throws { Set-CcClaudeLaunchFiles -Files $tooLarge -ConfigDir $launchSession.Config -SessionRoot $launchSession.Root } 'exceed the 8 MiB total limit'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $launchSession.Config 'large.bin'))) 'Oversized import wrote a file.'
        [Array]::Clear($large,0,$large.Length)
    }
} finally {
    $script:fixtureFiles = @()
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + '\'
    $resolvedRoot = [IO.Path]::GetFullPath($script:testRoot).TrimEnd('\', '/')
    if (-not $resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'cc-claude-launch-files-*') {
        throw 'Refusing cleanup outside the GUID-scoped synthetic test root.'
    }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop }
}

Write-Host ("CC Switch Claude launch file tests: {0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }

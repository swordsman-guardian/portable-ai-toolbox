[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-store.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-context.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cc-store-test-' + [guid]::NewGuid().ToString('N'))
$usbRoot = Join-Path $testRoot 'usb'
$sourceRoot = Join-Path $testRoot 'runtime\virtual-stick'
$destinationRoot = Join-Path $testRoot 'runtime\restored-stick'
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Script, [string]$Text) {
    $failure = $null
    try { & $Script | Out-Null } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -notlike "*$Text*") {
        if ($failure) { throw "Expected '$Text', got '$($failure.Exception.Message)'" }
        throw "Expected error containing '$Text'."
    }
}
function Invoke-Case([string]$Name, [scriptblock]$Script) {
    try { & $Script; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Write-SyntheticFile([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Get-FileSha([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

try {
    [void][IO.Directory]::CreateDirectory($usbRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch'))
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'harness\cc-switch\claude'))
    [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'config\cc-switch\home\excluded-from-store'))
    Write-SyntheticFile (Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\settings.json') '{"claudeConfigDir":"C:\\old-host\\claude","futureOption":true}'
    Write-SyntheticFile (Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\cc-switch.db') 'SYNTHETIC_DB_COPY_A'
    Write-SyntheticFile (Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\runtime.log') 'SYNTHETIC_LOG_MUST_NOT_BE_SAVED'
    Write-SyntheticFile (Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\cc-switch.db-wal') 'SYNTHETIC_WAL_MUST_NOT_BE_SAVED'
    Write-SyntheticFile (Join-Path $sourceRoot 'config\cc-switch\home\excluded-from-store\private.txt') 'OUTSIDE_ALLOWED_SUBTREE'
    Write-SyntheticFile (Join-Path $sourceRoot 'harness\cc-switch\claude\settings.json') '{"env":{"ANTHROPIC_BASE_URL":"https://synthetic.example/v1","ANTHROPIC_AUTH_TOKEN":"synthetic-only-provider-token"}}'
    Write-SyntheticFile (Join-Path $sourceRoot 'harness\cc-switch\codex\config.toml') 'model = "synthetic-model"'
    $runtimeSettings = Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\settings.json'
    $sourceDb = Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\cc-switch.db'
    $sourceProfile = Join-Path $sourceRoot 'harness\cc-switch\claude\settings.json'
    $sourceDbHash = Get-FileSha $sourceDb
    $sourceProfileHash = Get-FileSha $sourceProfile

    Invoke-Case 'online snapshots are rejected unless caller declares stopped state' {
        Assert-Throws { Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $sourceRoot -StoppedOnly:$false } 'explicitly stopped'
    }
    Invoke-Case 'first stopped save creates a bounded generation and exports the fixed Claude profile' {
        $saved = Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $sourceRoot -StoppedOnly
        Assert-True ($saved.Consistency -eq 'StoppedOnly' -and $saved.ProfileExported) 'Save result did not report stopped snapshot plus provider export.'
        Assert-True ($saved.FileCount -eq 4) 'Unexpected included file count.'
        Assert-True ((Get-FileSha (Join-Path $usbRoot 'harness\cc-switch\claude\settings.json')) -eq $sourceProfileHash) 'The fixed bridge profile export does not match the stopped snapshot.'
        Assert-True ((Get-CcSwitchStoreStatus -StickRoot $usbRoot).CurrentRevision -eq $saved.Revision) 'Status did not report the committed generation.'
        $savedGeneration = Join-Path $usbRoot ('config\cc-switch\store\generations\' + $saved.Revision)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $savedGeneration 'payload\config\cc-switch\home\excluded-from-store'))) 'Unapproved home files entered the snapshot.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $savedGeneration 'payload\config\cc-switch\home\.cc-switch\runtime.log'))) 'Log file entered the snapshot.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $savedGeneration 'payload\config\cc-switch\home\.cc-switch\cc-switch.db-wal'))) 'SQLite WAL entered the snapshot.'
        $script:revisionA = $saved.Revision
    }
    Invoke-Case 'failed save does not replace the previous successful generation' {
        Assert-Throws { Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot (Join-Path $testRoot 'missing-source') -StoppedOnly } 'SourceRoot must exist'
        Assert-True ((Get-CcSwitchStoreStatus -StickRoot $usbRoot).CurrentRevision -eq $script:revisionA) 'A failed save replaced the previous success.'
    }
    Invoke-Case 'second save retains exactly the last successful predecessor' {
        Write-SyntheticFile $sourceDb 'SYNTHETIC_DB_COPY_B'
        $saved = Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $sourceRoot -StoppedOnly
        $status = Get-CcSwitchStoreStatus -StickRoot $usbRoot
        Assert-True ($status.CurrentRevision -eq $saved.Revision -and $status.PreviousRevision -eq $script:revisionA) 'The generation pointer did not preserve the previous success.'
        Assert-True ($status.GenerationCount -eq 2) 'Old generations were not bounded to current and previous.'
        Assert-True ((Get-FileSha (Join-Path $usbRoot 'harness\cc-switch\claude\settings.json')) -eq (Get-FileSha $sourceProfile)) 'The provider export is stale.'
        $script:revisionB = $saved.Revision
        $script:sourceProfileHashB = Get-FileSha $sourceProfile
    }
    Invoke-Case 'restores to a new runtime root and signals path regeneration' {
        $restored = Restore-CcSwitchStoreSnapshot -StickRoot $usbRoot -DestinationRoot $destinationRoot -StoppedOnly
        Assert-True ($restored.Revision -eq $script:revisionB -and $restored.RequiresContextPathRegeneration) 'Restore did not require runtime path regeneration.'
        Assert-True ((Get-FileSha (Join-Path $destinationRoot 'config\cc-switch\home\.cc-switch\cc-switch.db')) -eq (Get-FileSha (Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\cc-switch.db'))) 'Database bytes did not roundtrip.'
        Assert-True ((Get-FileSha (Join-Path $destinationRoot 'harness\cc-switch\claude\settings.json')) -eq $script:sourceProfileHashB) 'Claude settings did not roundtrip.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'config\cc-switch\home\excluded-from-store'))) 'Excluded home content was restored.'
        $session = Join-Path $testRoot 'runtime\context-session'
        [void][IO.Directory]::CreateDirectory($session)
        $context = New-CcSwitchPortableContext -StickRoot $destinationRoot -SessionRoot $session -HarnessIds @('claude')
        $null = Initialize-CcSwitchPortableContext -Context $context
        $rewritten = [IO.File]::ReadAllText((Join-Path $destinationRoot 'config\cc-switch\home\.cc-switch\settings.json')) | ConvertFrom-Json
        Assert-True ($rewritten.claudeConfigDir -eq (Join-Path $destinationRoot 'harness\cc-switch\claude')) 'Context initialization did not replace the prior host path.'
    }
    Invoke-Case 'nonempty destination is refused and its sentinel survives' {
        $occupied = Join-Path $testRoot 'runtime\occupied-root'
        [void][IO.Directory]::CreateDirectory($occupied)
        $sentinel = Join-Path $occupied 'host-sentinel.txt'
        Write-SyntheticFile $sentinel 'HOST_SYNTHETIC_SENTINEL'
        Assert-Throws { Restore-CcSwitchStoreSnapshot -StickRoot $usbRoot -DestinationRoot $occupied -StoppedOnly } 'Destination must be empty'
        Assert-True (Test-Path -LiteralPath $sentinel) 'Restore removed an existing host item.'
    }
    Invoke-Case 'payload tampering is detected before destination writes' {
        $generation = Join-Path $usbRoot ('config\cc-switch\store\generations\' + $script:revisionB)
        $database = Join-Path $generation 'payload\config\cc-switch\home\.cc-switch\cc-switch.db'
        [IO.File]::WriteAllText($database, 'TAMPERED_SYNTHETIC_DATABASE')
        $untouched = Join-Path $testRoot 'runtime\must-stay-absent'
        Assert-Throws { Restore-CcSwitchStoreSnapshot -StickRoot $usbRoot -DestinationRoot $untouched -StoppedOnly } 'does not match its manifest'
        Assert-True (-not (Test-Path -LiteralPath $untouched)) 'Restore created its target before validating every payload file.'
    }
    Invoke-Case 'profile-free snapshot succeeds and invalidates an older fixed bridge export' {
        $noClaude = Join-Path $testRoot 'runtime\no-claude-stick'
        [void][IO.Directory]::CreateDirectory((Join-Path $noClaude 'config\cc-switch\home\.cc-switch'))
        Write-SyntheticFile (Join-Path $noClaude 'config\cc-switch\home\.cc-switch\settings.json') '{"codexConfigDir":"C:\\old-host\\codex"}'
        Write-SyntheticFile (Join-Path $noClaude 'config\cc-switch\home\.cc-switch\cc-switch.db') 'SYNTHETIC_DB_NO_CLAUDE'
        $saved = Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $noClaude -StoppedOnly
        Assert-True (-not $saved.ProfileExported -and $saved.ProfileExportStatus -eq 'AbsentInSnapshot_Invalidated') 'Snapshot without Claude did not report missing profile.'
        $fixedText = [IO.File]::ReadAllText((Join-Path $usbRoot 'harness\cc-switch\claude\settings.json'))
        Assert-True ($fixedText -eq '{"env":{}}') 'An old Claude profile was left usable after profile-free save.'
        $script:revisionNoClaude = $saved.Revision
    }
    Invoke-Case 'saving Claude profile again refreshes the provider bridge and prunes beyond previous generation' {
        $saved = Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $sourceRoot -StoppedOnly
        Assert-True ($saved.ProfileExported) 'A present profile was not exported.'
        Assert-True ((Get-FileSha (Join-Path $usbRoot 'harness\cc-switch\claude\settings.json')) -eq (Get-FileSha $sourceProfile)) 'The fixed profile export was not refreshed.'
        Assert-True ((Get-CcSwitchStoreStatus -StickRoot $usbRoot).GenerationCount -eq 2) 'Generation retention exceeded current plus previous.'
        $script:revisionB = $saved.Revision
    }
    Invoke-Case 'manifest path traversal is rejected even with a matching manifest digest' {
        $currentPath = Join-Path $usbRoot 'config\cc-switch\store\current.json'
        $pointer = [IO.File]::ReadAllText($currentPath) | ConvertFrom-Json
        $manifestPath = Join-Path $usbRoot ('config\cc-switch\store\generations\' + $script:revisionB + '\manifest.json')
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $manifest.Directories = @($manifest.Directories) + @('harness/cc-switch/claude/../../escape')
        $manifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($manifest | ConvertTo-Json -Depth 8))
        [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $pointer.ManifestSha256 = [BitConverter]::ToString($sha.ComputeHash($manifestBytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        [IO.File]::WriteAllText($currentPath, ($pointer | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        $blocked = Join-Path $testRoot 'runtime\traversal-blocked'
        Assert-Throws { Restore-CcSwitchStoreSnapshot -StickRoot $usbRoot -DestinationRoot $blocked -StoppedOnly } 'invalid path component'
        Assert-True (-not (Test-Path -LiteralPath $blocked)) 'Malicious manifest path created output.'
    }
    Invoke-Case 'configured byte quota is enforced before store commit' {
        $freshUsb = Join-Path $testRoot 'usb-quota'
        [void][IO.Directory]::CreateDirectory($freshUsb)
        $extra = Join-Path $sourceRoot 'config\cc-switch\home\.cc-switch\large.synthetic'
        Write-SyntheticFile $extra 'SYNTHETIC_OVER_LIMIT'
        $oldLimit = $script:CcStoreMaxBytes
        try {
            $script:CcStoreMaxBytes = 8
            Assert-Throws { Save-CcSwitchStoreSnapshot -StickRoot $freshUsb -SourceRoot $sourceRoot -StoppedOnly } 'byte limit'
            Assert-True ((Get-CcSwitchStoreStatus -StickRoot $freshUsb).Status -eq 'Absent') 'Quota failure committed a generation.'
        } finally { $script:CcStoreMaxBytes = $oldLimit; Remove-Item -LiteralPath $extra -Force }
    }
    Invoke-Case 'source/store overlap is refused' {
        Assert-Throws { Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $usbRoot -StoppedOnly } 'must not overlap the USB store'
    }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\', '/')
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'cc-store-test-*') {
        throw 'Refusing to remove a path outside the GUID-scoped synthetic test root.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        foreach ($item in [IO.Directory]::EnumerateFileSystemEntries($resolvedTestRoot, '*', [IO.SearchOption]::AllDirectories)) {
            if ([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) { throw 'Test cleanup found a reparse point; refusing recursive removal.' }
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
    }
}
Write-Host ("CC Switch stopped store tests: {0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cc-switch-toolbox-migration.ps1')

$python = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime\python\python.exe'))
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Bundled Python runtime is unavailable.' }
$base = Join-Path ([IO.Path]::GetTempPath()) ('cc-switch-toolbox-migration-test-' + [guid]::NewGuid().ToString('N'))
$stick = Join-Path $base 'synthetic-stick'
$seed = Join-Path $base 'seed'
$database = Join-Path $seed 'config\cc-switch\home\.cc-switch\cc-switch.db'
$dbFixture = Join-Path $base 'make-v19.py'
$session = $null
$failed = $false
$syntheticSecretOne = 'sk-synthetic-current-78a2'
$syntheticSecretTwo = 'sk-synthetic-secondary-55fd'
try {
    foreach ($path in @(
        (Join-Path $seed 'config\cc-switch\home\.cc-switch'),
        (Join-Path $seed 'harness\cc-switch\claude'),
        (Join-Path $stick 'config\claude'),
        (Join-Path $stick 'harness'),
        (Join-Path $stick 'config')
    )) { [void][IO.Directory]::CreateDirectory($path) }

    $createDb = @'
import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE providers (
 id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT NOT NULL, settings_config TEXT NOT NULL,
 website_url TEXT, category TEXT, created_at INTEGER, sort_index INTEGER, notes TEXT, icon TEXT,
 icon_color TEXT, meta TEXT NOT NULL DEFAULT '{}', is_current BOOLEAN NOT NULL DEFAULT 0,
 in_failover_queue BOOLEAN NOT NULL DEFAULT 0, PRIMARY KEY (id, app_type));
CREATE TABLE mcp_servers (id TEXT PRIMARY KEY, name TEXT NOT NULL, server_config TEXT NOT NULL,
 description TEXT, homepage TEXT, docs TEXT, tags TEXT NOT NULL DEFAULT '[]',
 enabled_claude BOOLEAN NOT NULL DEFAULT 0, enabled_codex BOOLEAN NOT NULL DEFAULT 0,
 enabled_gemini BOOLEAN NOT NULL DEFAULT 0, enabled_grokbuild BOOLEAN NOT NULL DEFAULT 0,
 enabled_opencode BOOLEAN NOT NULL DEFAULT 0, enabled_mcode BOOLEAN NOT NULL DEFAULT 0,
 enabled_hermes BOOLEAN NOT NULL DEFAULT 0);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
""")
c.execute("PRAGMA user_version=19")
c.execute("INSERT INTO providers(id,app_type,name,settings_config,is_current) VALUES(?,?,?,?,1)",
          ('existing-claude','claude','Existing CC provider',json.dumps({'env':{'ANTHROPIC_BASE_URL':'https://old.example','ANTHROPIC_AUTH_TOKEN':'PLACEHOLDER','ANTHROPIC_MODEL':'old-model','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1'}})))
c.execute("INSERT INTO providers(id,app_type,name,settings_config,is_current) VALUES(?,?,?, ?,1)",
          ('existing-codex','codex','Keep Codex',json.dumps({'auth':{},'config':''})))
c.execute("INSERT INTO mcp_servers(id,name,server_config) VALUES('keep-mcp','Keep MCP','{}')")
c.execute("INSERT INTO settings(key,value) VALUES('language','zh-CN')")
c.commit(); assert c.execute('PRAGMA integrity_check').fetchone()[0]=='ok'; c.close()
'@
    [IO.File]::WriteAllText($dbFixture,$createDb,(New-Object Text.UTF8Encoding($false)))
    $null = & $python -I $dbFixture $database
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic v19 SQLite fixture creation failed.' }

    $existingClaude = @{
        permissions = @{ allow = @('Read(*)') }
        enableAllProjectMcpServers = $true
        _comment = 'preserve-synthetic-settings'
        env = @{ ANTHROPIC_BASE_URL = 'https://old.example'; ANTHROPIC_AUTH_TOKEN = 'PLACEHOLDER'; ANTHROPIC_MODEL = 'old-model'; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1' }
    } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $seed 'harness\cc-switch\claude\settings.json'),$existingClaude,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $seed 'config\cc-switch\home\.cc-switch\settings.json'),'{}',(New-Object Text.UTF8Encoding($false)))

    $providersDoc = [ordered]@{
        default = 'fixture-disabled'
        providers = @(
            [ordered]@{id='fixture-current';name='Synthetic Current';enabled=$true;baseUrl='https://current.example/v1';apikeyEnv='FIXTURE_CURRENT';models=[ordered]@{ANTHROPIC_MODEL='current-model';ANTHROPIC_DEFAULT_SONNET_MODEL='sonnet-current'};extraEnv=[ordered]@{CLAUDE_CODE_MAX_CONTEXT_TOKENS='256000'};verified='verified-synthetic-record';notes='synthetic provider notes'},
            [ordered]@{id='fixture-secondary';name='Synthetic Secondary';enabled=$true;baseUrl='https://secondary.example/v1';apikeyEnv='FIXTURE_SECONDARY';models=[ordered]@{ANTHROPIC_MODEL='secondary-model'};extraEnv=[ordered]@{};verified='verified-secondary-synthetic';notes='secondary synthetic notes'},
            [ordered]@{id='fixture-disabled';name='Disabled Fixture';enabled=$false}
        )
    }
    $providersPath = Join-Path $stick 'harness\providers.json'
    [IO.File]::WriteAllText($providersPath,($providersDoc | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $goodProvidersJson = [IO.File]::ReadAllText($providersPath,[Text.Encoding]::UTF8)
    $toolSettingsPath = Join-Path $stick 'config\settings.json'
    [IO.File]::WriteAllText($toolSettingsPath,'{"provider":"fixture-current","lastWorkDir":"","ccSwitchClaudeProvider":false}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $stick 'config\keys.env'),("FIXTURE_CURRENT=$syntheticSecretOne`nFIXTURE_SECONDARY=$syntheticSecretTwo`n"),(New-Object Text.UTF8Encoding($false)))
    $registry = '{"harnesses":[{"id":"claude","enabled":true,"providerEnv":{"baseUrl":"ANTHROPIC_BASE_URL","apiKey":"ANTHROPIC_AUTH_TOKEN"}}]}'
    [IO.File]::WriteAllText((Join-Path $stick 'harness\registry.json'),$registry,(New-Object Text.UTF8Encoding($false)))
    $userClaude = @{
        permissions = @{ allow = @('Read(*)') }
        enableAllProjectMcpServers = $true
        _comment = 'preserve-synthetic-settings'
        env = @{ CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'; CLAUDE_CODE_MAX_CONTEXT_TOKENS = 'old-context'; ANTHROPIC_BASE_URL = 'https://toolbox-old.example'; ANTHROPIC_AUTH_TOKEN = 'old-secret' }
    } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $stick 'config\claude\settings.json'),$userClaude,(New-Object Text.UTF8Encoding($false)))

    $vaultPassword = ConvertTo-SecureString 'synthetic-only-passphrase' -AsPlainText -Force
    $session = Open-CcEncryptedStoreSession -StickRoot $stick -Password $vaultPassword -Create
    $null = Save-CcEncryptedSnapshot -Session $session -SourceRoot $seed -StoppedOnly
    $beforeRevision = [string]$session.Revision
    $sourceHash = (Get-FileHash -LiteralPath $providersPath -Algorithm SHA256).Hash
    $result = Import-CcToolboxProviders -StickRoot $stick -Session $session -PythonExe $python
    if ($result.Status -cne 'Imported' -or $result.ImportedProviders -ne 2 -or $result.Revision -ceq $beforeRevision) { throw 'Migration result did not report a new encrypted snapshot.' }
    if ((Get-FileHash -LiteralPath $providersPath -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Toolbox provider source was modified.' }
    $resultText = ConvertTo-Json -InputObject $result -Compress
    if ($resultText.Contains($syntheticSecretOne) -or $resultText.Contains($syntheticSecretTwo)) { throw 'Synthetic credential escaped in the migration result.' }

    $restored = Join-Path $base 'restored-final'
    $null = Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $restored -StoppedOnly
    $verifyDb = Join-Path $restored 'config\cc-switch\home\.cc-switch\cc-switch.db'
    $inspect = Invoke-CcToolboxMigrationHelper -PythonExe $python -HelperPath (Join-Path $PSScriptRoot 'cc-switch-toolbox-migration.py') -Action inspect -DatabasePath $verifyDb
    if ($inspect.CurrentId -cne $result.CurrentProviderId) { throw 'Imported toolbox provider did not become Claude current.' }
    if ($inspect.EnvKeys -notcontains 'CLAUDE_CODE_MAX_CONTEXT_TOKENS') { throw 'extraEnv was omitted from the active CC provider.' }
    $checkPy = @'
import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row
assert c.execute("PRAGMA user_version").fetchone()[0]==19
assert c.execute("SELECT COUNT(*) FROM providers WHERE app_type='claude'").fetchone()[0]==3
assert c.execute("SELECT COUNT(*) FROM providers WHERE app_type='codex' AND id='existing-codex'").fetchone()[0]==1
assert c.execute("SELECT COUNT(*) FROM mcp_servers WHERE id='keep-mcp'").fetchone()[0]==1
assert c.execute("SELECT value FROM settings WHERE key='language'").fetchone()[0]=='zh-CN'
row=c.execute("SELECT settings_config FROM providers WHERE app_type='claude' AND is_current=1").fetchone()
config=json.loads(row[0]); env=config['env']
assert env['CLAUDE_CODE_MAX_CONTEXT_TOKENS']=='256000'
assert env['ANTHROPIC_AUTH_TOKEN']=='sk-synthetic-current-78a2'
assert config['permissions']['allow']==['Read(*)'] and config['enableAllProjectMcpServers'] is True
assert config['_comment']=='preserve-synthetic-settings'
row=c.execute("SELECT notes,meta FROM providers WHERE app_type='claude' AND id LIKE 'toolbox-%' ORDER BY notes LIMIT 1").fetchone()
assert row is not None
rows=c.execute("SELECT notes,meta FROM providers WHERE app_type='claude' AND id LIKE 'toolbox-%'").fetchall()
assert len(rows)==2
assert all(r[0] in ('synthetic provider notes','secondary synthetic notes') for r in rows)
assert all(json.loads(r[1]).get('toolboxMigration',{}).get('verified') in ('verified-synthetic-record','verified-secondary-synthetic') for r in rows)
assert c.execute("PRAGMA integrity_check").fetchone()[0]=='ok'
c.close()
'@
    $checkPath = Join-Path $base 'check-v19.py'
    [IO.File]::WriteAllText($checkPath,$checkPy,(New-Object Text.UTF8Encoding($false)))
    $null = & $python -I $checkPath $verifyDb
    if ($LASTEXITCODE -ne 0) { throw 'Imported snapshot did not retain the expected real v19 schema and settings.' }

    $stableRevision = [string]$session.Revision
    $repeatResult = Import-CcToolboxProviders -StickRoot $stick -Session $session -PythonExe $python
    if ($repeatResult.Status -cne 'Imported' -or $repeatResult.ImportedProviders -ne 2 -or [string]$session.Revision -ceq $stableRevision) { throw 'An identical second migration was not accepted idempotently.' }
    $stableRevision = [string]$session.Revision
    $metadataDoc = [IO.File]::ReadAllText($providersPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $metadataProvider = @($metadataDoc.providers | Where-Object { $_.id -ceq 'fixture-current' })[0]
    $metadataProvider.notes = 'changed synthetic notes must conflict'
    [IO.File]::WriteAllText($providersPath,($metadataDoc | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    $metadataConflictRejected = $false
    try { $null = Import-CcToolboxProviders -StickRoot $stick -Session $session -PythonExe $python } catch { $metadataConflictRejected = $true }
    $afterMetadataConflictStatus = Get-CcEncryptedStoreStatus -StickRoot $stick
    if (-not $metadataConflictRejected -or [string]$session.Revision -cne $stableRevision -or [string]$afterMetadataConflictStatus.CurrentRevision -cne $stableRevision) { throw 'Changing notes/verified for an existing ID was not rejected without changing the encrypted current snapshot.' }
    [IO.File]::WriteAllText($providersPath,$goodProvidersJson,(New-Object Text.UTF8Encoding($false)))

    $badDoc = [ordered]@{default='fixture-current';providers=@([ordered]@{id='fixture-current';name='Bad';enabled=$true;baseUrl='https://bad.example';apikeyEnv='FIXTURE_CURRENT';models=[ordered]@{};extraEnv=[ordered]@{};unsupportedConfigField='must reject'})}
    [IO.File]::WriteAllText($providersPath,($badDoc | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $rejected = $false
    try { $null = Import-CcToolboxProviders -StickRoot $stick -Session $session -PythonExe $python } catch { $rejected = $true }
    if (-not $rejected -or [string]$session.Revision -cne $stableRevision) { throw 'Unsupported fields were not rejected before encrypted commit.' }

    # Inject a failure after the real snapshot core has switched current.json.
    # This exercises the narrow post-pointer/pre-return rollback boundary.
    [IO.File]::WriteAllText($providersPath,$goodProvidersJson,(New-Object Text.UTF8Encoding($false)))
    $script:CcToolboxTestOriginalSaveCore = (Get-Command Save-CcEncryptedSnapshotCore -CommandType Function).ScriptBlock
    Set-Item Function:\Save-CcEncryptedSnapshotCore -Value {
        param($Session,[string]$SourceRoot,[switch]$StoppedOnly,[switch]$MigrationAuthorized)
        $null = & $script:CcToolboxTestOriginalSaveCore -Session $Session -SourceRoot $SourceRoot -StoppedOnly:$StoppedOnly -MigrationAuthorized:$MigrationAuthorized
        throw 'synthetic failure after current pointer switch'
    }
    $injectedFailure = $false
    try { $null = Import-CcToolboxProviders -StickRoot $stick -Session $session -PythonExe $python } catch { $injectedFailure = $true }
    Remove-Item Function:\Save-CcEncryptedSnapshotCore -ErrorAction SilentlyContinue
    Set-Item Function:\Save-CcEncryptedSnapshotCore -Value $script:CcToolboxTestOriginalSaveCore
    Remove-Variable CcToolboxTestOriginalSaveCore -Scope Script -ErrorAction SilentlyContinue
    $afterInjectedStatus = Get-CcEncryptedStoreStatus -StickRoot $stick
    if (-not $injectedFailure -or [string]$session.Revision -cne $stableRevision -or [string]$afterInjectedStatus.CurrentRevision -cne $stableRevision) { throw 'Failure after current pointer switch did not restore the prior encrypted snapshot.' }
    $afterInjectedRoot = Join-Path $base 'restored-after-injected-failure'
    $null = Restore-CcEncryptedSnapshot -Session $session -DestinationRoot $afterInjectedRoot -StoppedOnly
    $afterInjectedDb = Join-Path $afterInjectedRoot 'config\cc-switch\home\.cc-switch\cc-switch.db'
    $afterInjectedInspect = Invoke-CcToolboxMigrationHelper -PythonExe $python -HelperPath (Join-Path $PSScriptRoot 'cc-switch-toolbox-migration.py') -Action inspect -DatabasePath $afterInjectedDb
    if ($afterInjectedInspect.CurrentId -cne $result.CurrentProviderId) { throw 'Restored encrypted database did not contain the prior selected provider after injected commit failure.' }
    Write-Output 'PASS: synthetic v19 import/verify, settings and extraEnv preservation, notes/verified metadata retention, identical second import success, changed-metadata same-ID rejection without snapshot change, old rows/MCP/settings retention, credential-output check, pre-commit rejection, and post-pointer commit-failure rollback.'
} catch {
    $failed = $true
    Write-Error $_.Exception.Message
} finally {
    if ($session) { try { Close-CcEncryptedStoreSession -Session $session } catch { } }
    if (Test-Path -LiteralPath $base -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($base).TrimEnd('\')
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ((Split-Path -Parent $resolved) -eq $tempRoot -and (Split-Path -Leaf $resolved) -match '^cc-switch-toolbox-migration-test-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        }
    }
}
if ($failed) { exit 1 }

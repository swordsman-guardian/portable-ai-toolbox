$ErrorActionPreference = 'Stop'
$scripts = $PSScriptRoot
. (Join-Path $scripts 'cc-switch-checkpoint.ps1')
. (Join-Path $scripts 'cc-switch-store.ps1')
$python = [IO.Path]::GetFullPath((Join-Path $scripts '..\runtime\python\python.exe'))
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Bundled Python runtime is unavailable.' }
$base = Join-Path ([IO.Path]::GetTempPath()) ('cc-switch-checkpoint-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $base 'source'
$published = Join-Path $base 'checkpoint'
$usbRoot = Join-Path $base 'synthetic-usb'
$restored = Join-Path $base 'restored'
$writer = $null
$failed = $false
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'config\cc-switch\home\.cc-switch'))
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'harness\cc-switch\claude'))
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'config\cc-switch\home\logs'))
    [IO.File]::WriteAllText((Join-Path $source 'config\cc-switch\home\.cc-switch\settings.json'),'{"synthetic":"fixture-only","otherField":{"keep":true}}',(New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'harness\cc-switch\claude\settings.json'),'{"model":"synthetic-model"}',(New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'config\cc-switch\home\logs\ignored.log'),'synthetic-log',(New-Object System.Text.UTF8Encoding($false)))
    $db = Join-Path $source 'config\cc-switch\home\.cc-switch\cc-switch.db'
    $init = "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table fixture(id integer primary key, value text)'); c.execute('insert into fixture(value) values(?)',('synthetic',)); c.commit(); c.execute('pragma journal_mode=wal'); c.close()"
    & $python -c $init $db | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create synthetic SQLite fixture.' }
    $writerScript = Join-Path $base 'writer.py'
    $writerCode = @'
import sqlite3,sys,time,os
c=sqlite3.connect(sys.argv[1],timeout=5)
c.execute('pragma journal_mode=wal')
i=0
while not os.path.exists(sys.argv[2]):
    try:
        c.execute('insert into fixture(value) values(?)',('writer-'+str(i),)); c.commit(); i+=1
    except sqlite3.OperationalError:
        time.sleep(.01)
    time.sleep(.01)
c.close()
'@
    [IO.File]::WriteAllText($writerScript,$writerCode,(New-Object System.Text.UTF8Encoding($false)))
    $stopWriter = Join-Path $base 'stop-writer'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $python
    $psi.Arguments = '"' + $writerScript + '" "' + $db + '" "' + $stopWriter + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $writer = [Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 350
    $result = New-CcSwitchOnlineCheckpoint -SourceRoot $source -DestinationRoot $published -PythonExe $python
    if ($result.Status -ne 'Complete' -or -not $result.DatabaseBackedUp -or $result.DatabaseIntegrity -ne 'ok' -or $result.MultiFileConsistencyGuaranteed) { throw 'Checkpoint result metadata was incorrect.' }
    if (-not (Test-Path -LiteralPath (Join-Path $published 'harness\cc-switch\claude\settings.json'))) { throw 'Managed harness settings were not copied.' }
    $settingsPath = Join-Path $published 'config\cc-switch\home\.cc-switch\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'CC Switch settings.json was not included in checkpoint.' }
    $settings = [IO.File]::ReadAllText($settingsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($settings.synthetic -cne 'fixture-only' -or -not $settings.otherField.keep) { throw 'Checkpoint settings content did not survive copy.' }
    if (Test-Path -LiteralPath (Join-Path $published 'config\cc-switch\home\logs\ignored.log')) { throw 'Excluded log was copied.' }
    foreach ($sidecar in @('cc-switch.db-wal','cc-switch.db-shm','cc-switch.db-journal')) {
        if (Test-Path -LiteralPath (Join-Path $published ('config\cc-switch\home\.cc-switch\' + $sidecar))) { throw 'A live SQLite sidecar was copied.' }
    }
    $check = "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); assert c.execute('pragma integrity_check').fetchone()[0]=='ok'; assert c.execute('select count(*) from fixture').fetchone()[0]>=1; c.close()"
    & $python -c $check (Join-Path $published 'config\cc-switch\home\.cc-switch\cc-switch.db') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Checkpoint database failed read validation.' }
    $reuseRejected = $false
    try { [void](New-CcSwitchOnlineCheckpoint -SourceRoot $source -DestinationRoot $published -PythonExe $python) } catch { $reuseRejected = $true }
    if (-not $reuseRejected) { throw 'Existing destination was not rejected.' }
    [IO.File]::WriteAllText($stopWriter,'stop')
    if (-not $writer.WaitForExit(5000)) { throw 'Synthetic SQLite writer did not stop.' }
    [void][IO.Directory]::CreateDirectory($usbRoot)
    [void](Save-CcSwitchStoreSnapshot -StickRoot $usbRoot -SourceRoot $published -StoppedOnly)
    [void](Restore-CcSwitchStoreSnapshot -StickRoot $usbRoot -DestinationRoot $restored -StoppedOnly)
    $restoredSettingsPath = Join-Path $restored 'config\cc-switch\home\.cc-switch\settings.json'
    if (-not (Test-Path -LiteralPath $restoredSettingsPath -PathType Leaf)) { throw 'Store restore omitted CC Switch settings.json.' }
    $restoredSettings = [IO.File]::ReadAllText($restoredSettingsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($restoredSettings.synthetic -cne 'fixture-only' -or -not $restoredSettings.otherField.keep) { throw 'CC Switch settings.json did not survive Store Save/Restore.' }
    Write-Output 'PASS: online SQLite backup under active synthetic writer; settings.json preserved through checkpoint and store restore; integrity ok; managed trees copied; runtime artifacts excluded; existing destination rejected.'
} catch {
    $failed = $true
    Write-Error $_.Exception.Message
} finally {
    if ($writer -and -not $writer.HasExited) {
        [IO.File]::WriteAllText((Join-Path $base 'stop-writer'),'stop')
        if (-not $writer.WaitForExit(5000)) { $writer.Kill(); [void]$writer.WaitForExit(5000) }
    }
    if (Test-Path -LiteralPath $base) {
        $resolvedBase = [IO.Path]::GetFullPath($base)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedBase) -match '^cc-switch-checkpoint-test-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolvedBase -Recurse -Force
        }
    }
}
if ($failed) { exit 1 }

# Synthetic reliability and ArchiveSet tests. All data lives under TEMP.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SyncScript = Join-Path $PSScriptRoot 'sync.ps1'
$Sandbox = Join-Path $env:TEMP ("aisync-archive-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null
$script:Pass = 0; $script:Fail = 0
function Check { param([string]$Name, [bool]$Ok, [string]$Detail='')
    if ($Ok) { $script:Pass++; Write-Host "  [OK] $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red }
}
function WriteText { param([string]$Path,[string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}
function MakeManifest { param([string]$Dir,[string]$Updated,[hashtable]$Files)
    $map = [ordered]@{}
    foreach ($key in $Files.Keys) { $map[$key] = [pscustomobject]@{mode='rewrite';size=([IO.File]::ReadAllBytes((Join-Path $Dir $key))).Length;mtime=$Updated;headHash=''} }
    $m = [pscustomobject]@{hostId='synthetic';updated=$Updated;files=[pscustomobject]$map}
    WriteText (Join-Path $Dir 'manifest.json') ($m | ConvertTo-Json -Depth 8)
}
Write-Host '【1】大初始文件、完整行边界与 manifest offset 修复' -ForegroundColor Yellow
$src = Join-Path $Sandbox 'src'; $dst = Join-Path $Sandbox 'run'
New-Item -ItemType Directory -Path $src,$dst -Force | Out-Null
$history = Join-Path $src 'history.jsonl'
$prefix = ('{"seed":"' + ('x' * 5000) + '"}' + "`n")
WriteText $history ($prefix + '{"partial":"half')
& $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
$out = Join-Path $dst 'history.jsonl'
Check '大于 4096 字节的完整初始行已写入，半行未写入' (([IO.File]::ReadAllText($out) -eq $prefix))
$m = Get-Content -Raw (Join-Path $dst 'manifest.json') | ConvertFrom-Json
Check 'manifest offset 等于归档实际长度' ([long]$m.files.'history.jsonl'.offset -eq (Get-Item $out).Length)
# A final line longer than the 64 KiB probe must not be cut at a chunk boundary.
$long = Join-Path $src 'projects\huge\long.jsonl'; WriteText $long ('z' * 70000)
& $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
Check '尾部超过 64KB 且无换行时本轮不复制半行' (-not (Test-Path (Join-Path $dst 'projects\huge\long.jsonl')))
WriteText $long (('z' * 70000) + "`n")
& $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
Check '补齐换行后完整长行可恢复复制' ((Get-Item (Join-Path $dst 'projects\huge\long.jsonl')).Length -eq 70001)
# Simulate a prior interrupted/partial append that leaves target longer than the committed manifest.
[IO.File]::AppendAllText($out,'junk')
WriteText $history ($prefix + '{"complete":2}' + "`n" + '{"tail":"open')
& $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
Check '实际长度与 offset 不符时重建安全前缀' ([IO.File]::ReadAllText($out) -eq ($prefix + '{"complete":2}' + "`n"))

Write-Host '【2】替换中断后可恢复旧副本并继续' -ForegroundColor Yellow
$cfg = Join-Path $src 'config.json'; $cfgDst = Join-Path $dst 'config.json'
WriteText $cfg '{"version":1}'; & $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
WriteText $cfg '{"version":2}'
$env:AISYNC_TEST_INTERRUPT_AFTER_MARKER = '1'
try { & $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null } catch { }
Remove-Item Env:\AISYNC_TEST_INTERRUPT_AFTER_MARKER -ErrorAction SilentlyContinue
Check '中断后旧目标仍可验证读取' (([IO.File]::ReadAllText($cfgDst) | ConvertFrom-Json).version -eq 1)
$txMarker = Get-Content -Raw "$cfgDst.sync-txn.json" | ConvertFrom-Json
Check '事务记录备份为相对文件名，允许归档换盘符恢复' (-not [IO.Path]::IsPathRooted([string]$txMarker.backup))
& $SyncScript -SourceDir $src -SessionsDir $dst -Quiet | Out-Null
Check '下轮恢复事务后安装新版本' (([IO.File]::ReadAllText($cfgDst) | ConvertFrom-Json).version -eq 2)

# Manifest interruption occurs after the data file append, so the next pass
# must restore the old manifest and rebuild rather than duplicate the tail.
$manifestSrc = Join-Path $Sandbox 'manifest-src'; $manifestDst = Join-Path $Sandbox 'manifest-run'
$seedLine = '{"payload":"' + ('x' * 5000) + '"}' + "`n"
WriteText (Join-Path $manifestSrc 'history.jsonl') $seedLine
& $SyncScript -SourceDir $manifestSrc -SessionsDir $manifestDst -Quiet | Out-Null
$oldManifest = Get-Content -Raw (Join-Path $manifestDst 'manifest.json') | ConvertFrom-Json
WriteText (Join-Path $manifestSrc 'history.jsonl') ($seedLine + "{`"seq`":2}`n")
$env:AISYNC_TEST_INTERRUPT_AFTER_MARKER = '1'
try { & $SyncScript -SourceDir $manifestSrc -SessionsDir $manifestDst -Quiet | Out-Null } catch { }
Remove-Item Env:\AISYNC_TEST_INTERRUPT_AFTER_MARKER -ErrorAction SilentlyContinue
$duringManifest = Get-Content -Raw (Join-Path $manifestDst 'manifest.json') | ConvertFrom-Json
Check 'manifest 替换中断时旧清单仍可读且事务标记留存' (([long]$duringManifest.files.'history.jsonl'.offset -eq [long]$oldManifest.files.'history.jsonl'.offset) -and (Test-Path (Join-Path $manifestDst 'manifest.json.sync-txn.json')))
& $SyncScript -SourceDir $manifestSrc -SessionsDir $manifestDst -Quiet | Out-Null
$recoveredManifest = Get-Content -Raw (Join-Path $manifestDst 'manifest.json') | ConvertFrom-Json
Check '下轮先恢复 manifest 事务并使 offset 与实际长度一致' ([long]$recoveredManifest.files.'history.jsonl'.offset -eq (Get-Item (Join-Path $manifestDst 'history.jsonl')).Length)

# A corrupt manifest must be retained before a full rebuild replaces it.
$badManifestDir = Join-Path $Sandbox 'bad-manifest-run'; New-Item -ItemType Directory -Path $badManifestDir -Force | Out-Null
WriteText (Join-Path $badManifestDir 'manifest.json') '{this is broken'
& $SyncScript -SourceDir $manifestSrc -SessionsDir $badManifestDir -Quiet | Out-Null
$corruptCopies = @(Get-ChildItem -LiteralPath $badManifestDir -Filter 'manifest.json.corrupt.*' -File)
Check '坏 manifest 在重建前有校验过的隔离副本' (($corruptCopies.Count -gt 0) -and ((Get-Content -Raw (Join-Path $badManifestDir 'manifest.json') | ConvertFrom-Json).files -ne $null))

Write-Host '【3】文件已安装、manifest 未提交时仍恢复精确旧代' -ForegroundColor Yellow
$commitCases = @(
    @{ name='rewrite-same-size'; rel='config.json'; old='{"v":1}'; new='{"v":2}' },
    @{ name='small-grow'; rel='plans\grow.md'; old='v1'; new='a longer v2 value' },
    @{ name='small-shrink'; rel='plans\shrink.md'; old='a longer v1 value'; new='v2' }
)
foreach ($case in $commitCases) {
    $caseSrc = Join-Path $Sandbox ("commit-src-" + $case.name)
    $caseHarness = Join-Path $Sandbox ("commit-set-" + $case.name)
    $caseRun = Join-Path $caseHarness 'runs\session-1'
    $caseSourceFile = Join-Path $caseSrc $case.rel
    $caseArchiveFile = Join-Path $caseRun $case.rel
    WriteText $caseSourceFile $case.old
    & $SyncScript -SourceDir $caseSrc -SessionsDir $caseRun -Quiet | Out-Null
    WriteText $caseSourceFile $case.new
    $interrupted = $false
    $env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL = '1'
    try { & $SyncScript -SourceDir $caseSrc -SessionsDir $caseRun -Quiet | Out-Null } catch { $interrupted = $true }
    Remove-Item Env:\AISYNC_TEST_INTERRUPT_AFTER_INSTALL -ErrorAction SilentlyContinue
    $prePullDir = Join-Path $Sandbox ("pre-pull-" + $case.name)
    $preStat = & $SyncScript -SourceDir $caseSrc -SessionsDir $caseHarness -ArchiveSet -Direction Pull -TargetDir $prePullDir -Quiet
    $preRestored = [IO.File]::ReadAllText((Join-Path $prePullDir $case.rel))
    Check "$($case.name): 安装后故障确实发生且 Pull 按旧 manifest 还原 v1" ($interrupted -and ($preRestored -eq $case.old) -and ([IO.File]::ReadAllText($caseArchiveFile) -eq $case.new) -and ($preStat.failed -eq 0))
    & $SyncScript -SourceDir $caseSrc -SessionsDir $caseRun -Quiet | Out-Null
    $postPullDir = Join-Path $Sandbox ("post-pull-" + $case.name)
    $postStat = & $SyncScript -SourceDir $caseSrc -SessionsDir $caseHarness -ArchiveSet -Direction Pull -TargetDir $postPullDir -Quiet
    $postRestored = [IO.File]::ReadAllText((Join-Path $postPullDir $case.rel))
    Check "$($case.name): 下轮 Push 提交 v2 并清理旧代事务" (($postRestored -eq $case.new) -and ($postStat.failed -eq 0) -and (-not (Test-Path "$caseArchiveFile.sync-txn.json")))
}

# Append archive backup can carry bytes beyond the old committed offset. Pull
# must hash/select only the old prefix and ignore that uncommitted tail.
$appendSrc = Join-Path $Sandbox 'append-commit-src'
$appendHarness = Join-Path $Sandbox 'append-commit-set'
$appendRun = Join-Path $appendHarness 'runs\session-1'
$appendSource = Join-Path $appendSrc 'history.jsonl'
$appendArchive = Join-Path $appendRun 'history.jsonl'
WriteText $appendSource "{`"n`":1}`n"
& $SyncScript -SourceDir $appendSrc -SessionsDir $appendRun -Quiet | Out-Null
$legacyAppendManifest = Get-Content -Raw (Join-Path $appendRun 'manifest.json') | ConvertFrom-Json
$legacyAppendManifest.files.'history.jsonl'.PSObject.Properties.Remove('contentHash')
WriteText (Join-Path $appendRun 'manifest.json') ($legacyAppendManifest | ConvertTo-Json -Depth 8)
[IO.File]::AppendAllText($appendArchive,'{"uncommitted"')
WriteText $appendSource "{`"n`":2}`n"
$env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL = '1'
$appendInterrupted = $false
try { & $SyncScript -SourceDir $appendSrc -SessionsDir $appendRun -Quiet | Out-Null } catch { $appendInterrupted = $true }
Remove-Item Env:\AISYNC_TEST_INTERRUPT_AFTER_INSTALL -ErrorAction SilentlyContinue
$appendPullDir = Join-Path $Sandbox 'append-pre-pull'
$appendPull = & $SyncScript -SourceDir $appendSrc -SessionsDir $appendHarness -ArchiveSet -Direction Pull -TargetDir $appendPullDir -Quiet
Check 'append 事务备份有未提交尾部时按 prefix hash 还原旧 committed 行' ($appendInterrupted -and ([IO.File]::ReadAllText((Join-Path $appendPullDir 'history.jsonl')) -eq "{`"n`":1}`n") -and ($appendPull.failed -eq 0))
& $SyncScript -SourceDir $appendSrc -SessionsDir $appendRun -Quiet | Out-Null
$appendPostDir = Join-Path $Sandbox 'append-post-pull'
$appendPost = & $SyncScript -SourceDir $appendSrc -SessionsDir $appendHarness -ArchiveSet -Direction Pull -TargetDir $appendPostDir -Quiet
Check 'append 下轮 Push 提交新代且不保留半行/重复行' ([IO.File]::ReadAllText((Join-Path $appendPostDir 'history.jsonl')) -eq "{`"n`":2}`n" -and ($appendPost.failed -eq 0))

# A first run with no previously committed manifest must remain invisible to
# ArchiveSet Pull until its manifest is installed.
$firstSrc = Join-Path $Sandbox 'first-commit-src'; $firstHarness = Join-Path $Sandbox 'first-commit-set'
$firstRun = Join-Path $firstHarness 'runs\session-1'; $firstSource = Join-Path $firstSrc 'config.json'
WriteText $firstSource '{"first":1}'
$env:AISYNC_TEST_INTERRUPT_AFTER_INSTALL = '1'
$firstInterrupted = $false
try { & $SyncScript -SourceDir $firstSrc -SessionsDir $firstRun -Quiet | Out-Null } catch { $firstInterrupted = $true }
Remove-Item Env:\AISYNC_TEST_INTERRUPT_AFTER_INSTALL -ErrorAction SilentlyContinue
$firstPullDir = Join-Path $Sandbox 'first-pre-pull'
$firstPull = & $SyncScript -SourceDir $firstSrc -SessionsDir $firstHarness -ArchiveSet -Direction Pull -TargetDir $firstPullDir -Quiet
Check '首份 manifest 未提交前 Pull 不暴露未提交文件' ($firstInterrupted -and ($firstPull.sources -eq 0) -and (-not (Test-Path (Join-Path $firstPullDir 'config.json'))))
& $SyncScript -SourceDir $firstSrc -SessionsDir $firstRun -Quiet | Out-Null
$firstPostDir = Join-Path $Sandbox 'first-post-pull'
$firstPost = & $SyncScript -SourceDir $firstSrc -SessionsDir $firstHarness -ArchiveSet -Direction Pull -TargetDir $firstPostDir -Quiet
Check '下轮 Push 安装首份清单后 Pull 才恢复文件' (([IO.File]::ReadAllText((Join-Path $firstPostDir 'config.json')) -eq '{"first":1}') -and ($firstPost.failed -eq 0))

Write-Host '【5】ArchiveSet：多会话、两项目、历史去重与冲突选择' -ForegroundColor Yellow
$set = Join-Path $Sandbox 'sessions\host\claude'; $legacy = Join-Path $Sandbox 'legacy'
$runA = Join-Path $set 'runs\session-a'; $runB = Join-Path $set 'runs\session-b'
foreach ($d in @($runA,$runB,$legacy)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
WriteText (Join-Path $runA 'projects\proj-A\same.jsonl') "{`"session`":`"A-old`"}`n"
WriteText (Join-Path $runA 'projects\proj-A\only-a.jsonl') "{`"session`":`"A-only`"}`n"
WriteText (Join-Path $runA 'history.jsonl') "{`"id`":1}`n{`"id`":2}`n"
WriteText (Join-Path $runB 'projects\proj-A\same.jsonl') "{`"session`":`"A-new`"}`n"
WriteText (Join-Path $runB 'projects\proj-B\only-b.jsonl') "{`"session`":`"B-only`"}`n"
WriteText (Join-Path $runA 'projects\proj-A\invalid.jsonl') "{broken json`n"
WriteText (Join-Path $runB 'history.jsonl') "{`"id`":2}`n{`"id`":3}`n"
WriteText (Join-Path $legacy 'settings.local.json') '{"legacy":true}'
MakeManifest $runA '2026-01-10T00:00:00Z' @{ 'projects\proj-A\same.jsonl'=''; 'projects\proj-A\only-a.jsonl'=''; 'projects\proj-A\invalid.jsonl'=''; 'history.jsonl'='' }
MakeManifest $runB '2026-01-02T00:00:00Z' @{ 'projects\proj-A\same.jsonl'=''; 'projects\proj-B\only-b.jsonl'=''; 'history.jsonl'='' }
WriteText (Join-Path $runA 'history.jsonl') (([IO.File]::ReadAllText((Join-Path $runA 'history.jsonl'))) + '{"id":4')
$ma = Get-Content -Raw (Join-Path $runA 'manifest.json') | ConvertFrom-Json
$mb = Get-Content -Raw (Join-Path $runB 'manifest.json') | ConvertFrom-Json
$ma.files.'projects\proj-A\same.jsonl'.mtime = '2026-01-01T00:00:00Z'
$mb.files.'projects\proj-A\same.jsonl'.mtime = '2026-01-03T00:00:00Z'
WriteText (Join-Path $runA 'manifest.json') ($ma | ConvertTo-Json -Depth 8)
WriteText (Join-Path $runB 'manifest.json') ($mb | ConvertTo-Json -Depth 8)
MakeManifest $legacy '2025-12-31T00:00:00Z' @{ 'settings.local.json'='' }
Copy-Item -LiteralPath (Join-Path $legacy 'manifest.json') -Destination (Join-Path $legacy 'manifest.json.corrupt.test')
WriteText (Join-Path $legacy 'manifest.json') '{broken manifest'
$pull = Join-Path $Sandbox 'pull'; New-Item -ItemType Directory -Path $pull -Force | Out-Null
$firstPullStat = & $SyncScript -SourceDir $src -SessionsDir $set -LegacySessionsDir $legacy -ArchiveSet -Direction Pull -TargetDir $pull -ProjectName 'proj-A' -Quiet
Check '兩個來源的不同項目文件恢复' ((Test-Path (Join-Path $pull 'projects\proj-A\only-a.jsonl')) -and (Test-Path (Join-Path $pull 'projects\proj-A\same.jsonl')))
Check '项目过滤阻止其他项目恢复' (-not (Test-Path (Join-Path $pull 'projects\proj-B\only-b.jsonl')))
Check '无效 JSONL 不落入恢复目录' (-not (Test-Path (Join-Path $pull 'projects\proj-A\invalid.jsonl')))
Check '冲突选择时间较新的完整源版本' ([IO.File]::ReadAllText((Join-Path $pull 'projects\proj-A\same.jsonl')) -eq "{`"session`":`"A-new`"}`n")
Check 'history 按行合并去重' ([IO.File]::ReadAllText((Join-Path $pull 'history.jsonl')) -eq "{`"id`":1}`n{`"id`":2}`n{`"id`":3}`n")
Check '显式 legacy 源也合并全局文件' (Test-Path (Join-Path $pull 'settings.local.json'))
Check '损坏 manifest 经有效备份候选恢复读取' (Test-Path (Join-Path $legacy 'manifest.json.corrupt.test'))
# A readable transaction backup is used without repairing/mutating an active run.
$txSrc = Join-Path $runA 'config.json'; WriteText $txSrc '{"state":"old"}'
$txBackup = "$txSrc.sync-bak.test"
[IO.File]::Copy($txSrc,$txBackup,$false)
$oldHash = (Get-FileHash -LiteralPath $txBackup -Algorithm SHA256).Hash.ToLowerInvariant()
WriteText $txSrc 'partial'
WriteText "$txSrc.sync-txn.json" (([pscustomobject]@{backup=(Split-Path -Leaf $txBackup);oldHash=$oldHash;newHash='invalid-new-hash'} | ConvertTo-Json))
$mc = Get-Content -Raw (Join-Path $runA 'manifest.json') | ConvertFrom-Json
$mc.files | Add-Member -NotePropertyName 'config.json' -NotePropertyValue ([pscustomobject]@{mode='rewrite';size=15;mtime='2026-01-04T00:00:00Z';headHash=''}) -Force
WriteText (Join-Path $runA 'manifest.json') ($mc | ConvertTo-Json -Depth 8)
$txPull = & $SyncScript -SourceDir $src -SessionsDir $set -LegacySessionsDir $legacy -ArchiveSet -Direction Pull -TargetDir $pull -ProjectName 'proj-A' -Quiet
Check 'Pull 从有效旧副本读取，并保持活动 run 现场不变' (([IO.File]::ReadAllText((Join-Path $pull 'config.json')) -eq '{"state":"old"}') -and ([IO.File]::ReadAllText($txSrc) -eq 'partial') -and (Test-Path "$txSrc.sync-txn.json"))
Check 'Pull 返回扩展 failed/sources/conflicts 状态字段' (($txPull.failed -gt 0) -and ($txPull.sources -eq 3) -and ($txPull.conflicts -ge 1))

Write-Host '【6】manifest 路径穿越必须失败且不写出 TargetDir' -ForegroundColor Yellow
$evil = Join-Path $Sandbox 'evil'; New-Item -ItemType Directory -Path $evil -Force | Out-Null
WriteText (Join-Path $evil 'secret.txt') 'should stay inside'
$evilMap = [pscustomobject]@{ '../escaped.txt'=[pscustomobject]@{size=18;mode='small'} }
WriteText (Join-Path $evil 'manifest.json') (([pscustomobject]@{updated='2026-01-01T00:00:00Z';files=$evilMap} | ConvertTo-Json -Depth 5))
$evilPull = & $SyncScript -SourceDir $src -SessionsDir $evil -Direction Pull -TargetDir $pull -Quiet
Check '非法路径的 manifest 被拒绝并报告失败' ($evilPull.failed -gt 0)
Check 'TargetDir 外没有创建逃逸文件' (-not (Test-Path (Join-Path $Sandbox 'escaped.txt')))
Write-Host '【7】拒绝经 junction 写出 TargetDir' -ForegroundColor Yellow
$realTarget = Join-Path $Sandbox 'junction-target'; $linkTarget = Join-Path $Sandbox 'junction-link'
New-Item -ItemType Directory -Path $realTarget -Force | Out-Null
New-Item -ItemType Junction -Path $linkTarget -Target $realTarget | Out-Null
$junctionPull = & $SyncScript -SourceDir $src -SessionsDir $set -LegacySessionsDir $legacy -ArchiveSet -Direction Pull -TargetDir $linkTarget -ProjectName 'proj-A' -Quiet
Check 'junction target 被拒绝并通过 failed 暴露' ($junctionPull.failed -gt 0)
Check 'junction 指向目录没有写入恢复文件' (@(Get-ChildItem -LiteralPath $realTarget -Force).Count -eq 0)

Write-Host "通过 $script:Pass，失败 $script:Fail" -ForegroundColor $(if ($script:Fail) {'Red'} else {'Green'})
Write-Host "沙盒: $Sandbox" -ForegroundColor DarkGray
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

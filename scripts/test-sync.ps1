# ============================================================
#  test-sync.ps1 —— 搬运引擎的针对性测试
#
#  搬运是整个原型里最容易出错的一块：读半截文件、写出坏 JSON、
#  重复搬全量。这里用合成数据把这些边界逐个压一遍，不碰真实会话。
#
#  用法： powershell -File test-sync.ps1
# ============================================================

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')
Set-ConsoleUtf8

$StickRoot = Get-StickRoot -ScriptDir $PSScriptRoot
$SyncScript = Join-Path $PSScriptRoot 'sync.ps1'

# 沙盒：源(本机) 与 目标(U盘) 都在临时区，不碰真实会话和真实归档
$Sandbox = Join-Path $env:TEMP ("aisync-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$Src  = Join-Path $Sandbox 'src'
$Dst  = Join-Path $Sandbox 'dst'
New-Item -ItemType Directory -Path $Src, $Dst -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ("  [√] $Name") -ForegroundColor Green }
    else     { $script:Fail++; Write-Host ("  [×] $Name  $Detail") -ForegroundColor Red }
}

function Push { param([string]$D = 'Push', [string]$Proj = '')
    $a = @{ SourceDir = $Src; SessionsDir = $Dst; Direction = $D }
    if ($Proj) { $a.ProjectName = $Proj }
    & $SyncScript @a -Quiet
}
function WriteText { param([string]$P, [string]$T)
    $d = Split-Path -Parent $P
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($P, $T, (New-Object Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  搬运引擎测试' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "沙盒: $Sandbox"
Write-Host ''

# ------------------------------------------------------------
Write-Host '【1】追加模式：末尾残缺行不能被搬过去' -ForegroundColor Yellow
$jsonl = Join-Path $Src 'projects\E--\session-a.jsonl'
# 三行完整 + 一行残缺（没有换行结尾）
WriteText $jsonl ('{"n":1}' + "`n" + '{"n":2}' + "`n" + '{"n":3}' + "`n" + '{"n":4,"partial":tru')
Push | Out-Null

$dstJsonl = Join-Path $Dst 'projects\E--\session-a.jsonl'
$got = [IO.File]::ReadAllText($dstJsonl)
Check '目标文件已生成' (Test-Path $dstJsonl)
Check '残缺尾行没有被搬过去（只搬到最后一个换行）' `
      ($got -eq ('{"n":1}' + "`n" + '{"n":2}' + "`n" + '{"n":3}' + "`n")) `
      ("实际内容: " + ($got -replace "`n", '\n'))
Check '目标文件每行都是完整 JSON' `
      (@($got.TrimEnd("`n") -split "`n" | Where-Object { $_ -and ($_ | ConvertFrom-Json -EA SilentlyContinue) -eq $null }).Count -eq 0)

# ------------------------------------------------------------
Write-Host ''
Write-Host '【2】追加模式：只搬新增部分，不重复搬全量' -ForegroundColor Yellow
$before = (Get-Item $dstJsonl).Length
# 把那行残缺的补完整，再加一行
WriteText $jsonl ('{"n":1}' + "`n" + '{"n":2}' + "`n" + '{"n":3}' + "`n" + '{"n":4,"partial":true}' + "`n" + '{"n":5}' + "`n")
Push | Out-Null
$after = (Get-Item $dstJsonl).Length
$expectedDelta = ('{"n":4,"partial":true}' + "`n" + '{"n":5}' + "`n").Length
Check '增量正好等于新增字节数（没重搬全量）' (($after - $before) -eq $expectedDelta) `
      ("增量 $($after-$before) 字节，期望 $expectedDelta")
$got2 = [IO.File]::ReadAllText($dstJsonl)
$lines = @($got2.TrimEnd("`n") -split "`n")
Check '增量后共 5 行' ($lines.Count -eq 5) ("实际 $($lines.Count) 行")
Check '第 5 行内容正确' ($lines[4] -eq '{"n":5}')

# ------------------------------------------------------------
Write-Host ''
Write-Host '【3】追加模式：源被整体重写（变短）要能察觉并全量重搬' -ForegroundColor Yellow
WriteText $jsonl ('{"reset":1}' + "`n")
Push | Out-Null
$got3 = [IO.File]::ReadAllText($dstJsonl)
Check '重写后目标内容与源一致' ($got3 -eq ('{"reset":1}' + "`n")) ("实际: " + ($got3 -replace "`n", '\n'))

# ------------------------------------------------------------
Write-Host ''
Write-Host '【4】重写模式：坏 JSON 必须被跳过，不能写出半截 JSON' -ForegroundColor Yellow
$cfg = Join-Path $Src '.claude.json'
WriteText $cfg '{"good":1}'
Push | Out-Null
$cfgDst = Join-Path $Dst '.claude.json'
Check '好的 JSON 被正常搬过去' ((Test-Path $cfgDst) -and ([IO.File]::ReadAllText($cfgDst) -match '"good"'))

# 现在写一个坏 JSON（模拟 Claude 正在写、被我们读到一半）
WriteText $cfg '{"broken": tru'
$badJsonStat = Push
$afterBad = [IO.File]::ReadAllText($cfgDst)
Check '坏 JSON 被跳过（目标仍是上一份好的）' ($afterBad -match '"good"') ("实际: $afterBad")
Check '目标 JSON 仍可解析' (($afterBad | ConvertFrom-Json) -ne $null)
Check '非空坏 JSON 计入 failed 而不伪报成功' ($badJsonStat.failed -gt 0)
# 再写回好的，应该能恢复搬运
WriteText $cfg '{"good":2}'
Push | Out-Null
Check '源恢复后能继续搬' ([IO.File]::ReadAllText($cfgDst) -match '"good":2')

# ------------------------------------------------------------
Write-Host ''
Write-Host '【5】小文件：变了才搬，没变就跳过' -ForegroundColor Yellow
$small = Join-Path $Src 'plans\p1.md'
WriteText $small 'v1'
Push | Out-Null
$smallDst = Join-Path $Dst 'plans\p1.md'
Check '小文件被搬过去' (([IO.File]::ReadAllText($smallDst)) -eq 'v1')
$t1 = (Get-Item $smallDst).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
$unchangedStat = Push
$t2 = (Get-Item $smallDst).LastWriteTimeUtc
Check '没变就不重搬（目标时间戳未变）' ($t1 -eq $t2)
Check '正常 skipped 不计入 failed' (($unchangedStat.skipped -gt 0) -and ($unchangedStat.failed -eq 0))
WriteText $small 'v2'
Push | Out-Null
Check '变了就搬' (([IO.File]::ReadAllText($smallDst)) -eq 'v2')

# ------------------------------------------------------------
Write-Host ''
Write-Host '【6】不搬的东西：缓存 / 进程级临时目录' -ForegroundColor Yellow
WriteText (Join-Path $Src 'cache\junk.bin') 'x'
WriteText (Join-Path $Src 'sessions\1234.json') '{"pid":1234}'
WriteText (Join-Path $Src 'paste-cache\p.txt') 'x'
Push | Out-Null
Check 'cache/ 没被搬' (-not (Test-Path (Join-Path $Dst 'cache')))
Check 'sessions/（按PID命名的进程级临时）没被搬' (-not (Test-Path (Join-Path $Dst 'sessions')))
Check 'paste-cache/ 没被搬' (-not (Test-Path (Join-Path $Dst 'paste-cache')))

# ------------------------------------------------------------
Write-Host ''
Write-Host '【7】反向拉取：只拉本机自己的项目' -ForegroundColor Yellow
# 造两个项目，只拉其中一个
WriteText (Join-Path $Src 'projects\projX\sx.jsonl') ('{"x":1}' + "`n")
WriteText (Join-Path $Src 'projects\projY\sy.jsonl') ('{"y":1}' + "`n")
Push | Out-Null

$PullTo = Join-Path $Sandbox 'pull'
New-Item -ItemType Directory -Path $PullTo -Force | Out-Null
& $SyncScript -SourceDir $Src -SessionsDir $Dst -Direction Pull -TargetDir $PullTo -ProjectName 'projX' -Quiet | Out-Null

Check '指定项目被拉回' (Test-Path (Join-Path $PullTo 'projects\projX\sx.jsonl'))
Check '未指定的项目没被拉回' (-not (Test-Path (Join-Path $PullTo 'projects\projY\sy.jsonl')))
Check '全局文件（.claude.json）被拉回' (Test-Path (Join-Path $PullTo '.claude.json'))

# ------------------------------------------------------------
Write-Host ''
Write-Host '【8】目标盘写不进去时不能崩（模拟拔盘）' -ForegroundColor Yellow
$bogus = Join-Path $Sandbox 'nonexistent-drive-Z\sub'
try {
    & $SyncScript -SourceDir $Src -SessionsDir $bogus -Direction Push -Quiet | Out-Null
    Check '对不可写目标不抛异常' $true
} catch {
    # 允许它抛，但必须是可读的错误，不是死循环或崩溃
    Check '对不可写目标抛出了可读错误' ($_.Exception.Message.Length -gt 0) $_.Exception.Message
}

# A real destination type conflict exercises a copy/install failure and the
# machine-readable Push failure counter. The entire test remains synthetic.
$failSrc = Join-Path $Sandbox 'copy-failure-src'
$failDst = Join-Path $Sandbox 'copy-failure-dst'
WriteText (Join-Path $failSrc 'plans\blocked.md') 'synthetic'
New-Item -ItemType Directory -Path (Join-Path $failDst 'plans\blocked.md') -Force | Out-Null
$failureStat = & $SyncScript -SourceDir $failSrc -SessionsDir $failDst -Quiet
Check '真实目标类型冲突被计入 Push failed' ($failureStat.failed -gt 0)

# ------------------------------------------------------------
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ("  通过 $script:Pass 项，失败 $script:Fail 项") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "沙盒保留供检查: $Sandbox" -ForegroundColor DarkGray
Write-Host ''
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

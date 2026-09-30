# 使用假 harness、假密钥和临时盘根验证完整启动流程；不调用真实 AI。
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-int-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$fakeStick = Join-Path $testRoot 'portable kit'
$testTemp = Join-Path $testRoot 'temp'
$processes = New-Object System.Collections.Generic.List[object]
$utf8 = New-Object Text.UTF8Encoding($false)
$failures = 0
function Assert-Integration([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "集成检查失败: $Label" }
    Write-Host "通过: $Label" -ForegroundColor Green
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Start-Fixture([string]$Project, [string]$Name, [switch]$VaultMode) {
    $originalTemp = $env:TEMP
    $originalTmp = $env:TMP
    try {
        $env:TEMP = $testTemp
        $env:TMP = $testTemp
        $argsText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -WorkDir "{1}" -NoPrompt' -f (Join-Path $fakeStick 'scripts\launch.ps1'), $Project
        if ($VaultMode) {
            $argsText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -WorkDir "{1}"' -f (Join-Path $testRoot 'synthetic-unlock.ps1'), $Project
        }
        $child = Start-Process -FilePath $engine -ArgumentList $argsText -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $testRoot ($Name + '.out')) -RedirectStandardError (Join-Path $testRoot ($Name + '.err'))
        $null = $child.Handle
        $processes.Add($child)
        return $child
    } finally { $env:TEMP = $originalTemp; $env:TMP = $originalTmp }
}
function Wait-Ready([string]$Project, $Child) {
    $ready = Join-Path $Project 'ready.txt'
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $Child.Refresh()
        if (Test-Path -LiteralPath $ready) {
            $lines = [IO.File]::ReadAllLines($ready)
            if ($lines.Length -ge 3) { return $lines }
        }
        if ($Child.HasExited) { throw "启动进程过早结束，exit=$($Child.ExitCode)；检查 $testRoot 的输出" }
        Start-Sleep -Milliseconds 150
    }
    throw '等待假 harness 就绪超时'
}
function Stop-Fixture([string]$Project, $Child, [int]$ExpectedExit = 0) {
    Write-Fixture (Join-Path $Project 'stop') 'stop'
    if (-not $Child.WaitForExit(45000)) { throw '会话未在时限内退出' }
    $Child.Refresh()
    Assert-Integration ($Child.ExitCode -eq $ExpectedExit) "启动器退出状态符合预期 ($ExpectedExit)"
}

try {
    foreach ($dir in @($fakeStick, $testTemp, (Join-Path $fakeStick 'scripts'), (Join-Path $fakeStick 'bin'))) {
        [void][IO.Directory]::CreateDirectory($dir)
    }
    foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        Copy-Item -LiteralPath $scriptFile.FullName -Destination (Join-Path $fakeStick ('scripts\' + $scriptFile.Name))
    }
    $source = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Threading;
public class PortableFixture {
    public static void Main(string[] args) {
        try { Run(); }
        catch (Exception ex) {
            File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "fixture-error.txt"), ex.GetType().FullName + "\n" + ex.Message);
            Environment.Exit(2);
        }
    }
    public static void Run() {
        string project = Environment.CurrentDirectory;
        string config = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        Directory.CreateDirectory(config);
        string projectName = System.Text.RegularExpressions.Regex.Replace(project, "[^a-zA-Z0-9]", "-");
        string transcripts = Path.Combine(config, "projects", projectName);
        Directory.CreateDirectory(transcripts);
        bool restored = File.Exists(Path.Combine(transcripts, "fixture.jsonl"));
        File.WriteAllText(Path.Combine(transcripts, "fixture.jsonl"), "{\"fixture\":true}\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(config, "history.jsonl"), "{\"project\":\"fixture\"}\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(config, ".claude.json"), "{\"fixture\":true}", new UTF8Encoding(false));
        string auth = Environment.GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN");
        string apiKey = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY");
        string credentialName = String.IsNullOrEmpty(auth) ? "ANTHROPIC_API_KEY" : "ANTHROPIC_AUTH_TOKEN";
        string credential = String.IsNullOrEmpty(auth) ? apiKey : auth;
        string credentialHash;
        using (var sha = System.Security.Cryptography.SHA256.Create()) {
            credentialHash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(credential ?? ""))).Replace("-", "");
        }
        File.WriteAllLines(Path.Combine(project, "ready.txt"), new string[] {
            config, Process.GetCurrentProcess().Id.ToString(), restored.ToString(),
            Environment.GetEnvironmentVariable("ANTHROPIC_BASE_URL") ?? "",
            Environment.GetEnvironmentVariable("ANTHROPIC_MODEL") ?? "",
            credentialName, credentialHash
        });
        DateTime limit = DateTime.UtcNow.AddSeconds(100);
        while (!File.Exists(Path.Combine(project, "stop")) && DateTime.UtcNow < limit) Thread.Sleep(100);
    }
}
'@
    $exe = Join-Path $fakeStick 'bin\fixture.exe'
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $exe -OutputType ConsoleApplication
    Write-Fixture (Join-Path $fakeStick 'harness\registry.json') '{"harnesses":[{"id":"fixture","name":"Fixture","enabled":true,"copyToHost":["bin/fixture.exe"],"run":{"pathCandidates":["bin/fixture.exe"],"minBytes":1},"providerEnv":{"baseUrl":"ANTHROPIC_BASE_URL","apiKey":"ANTHROPIC_AUTH_TOKEN","model":"ANTHROPIC_MODEL"},"env":{},"settingsFile":""}]}'
    Write-Fixture (Join-Path $fakeStick 'harness\providers.json') '{"default":"fixture","providers":[{"id":"fixture","name":"Fixture","baseUrl":"https://example.invalid","apikeyEnv":"FIXTURE_KEY","models":{},"extraEnv":{}}]}'
    Write-Fixture (Join-Path $fakeStick 'config\settings.json') '{"provider":"fixture","lastWorkDir":"","workDirByHost":{}}'
    Write-Fixture (Join-Path $fakeStick 'config\keys.env') 'FIXTURE_KEY=synthetic-test-token'
    $projectA = Join-Path $testRoot 'project A'
    $projectB = Join-Path $testRoot 'project B'
    [void][IO.Directory]::CreateDirectory($projectA)
    [void][IO.Directory]::CreateDirectory($projectB)
    $a = Start-Fixture $projectA 'A'
    $readyA = Wait-Ready $projectA $a
    $b = Start-Fixture $projectB 'B'
    $readyB = Wait-Ready $projectB $b
    Assert-Integration ($readyA[0] -ne $readyB[0]) '两个窗口拥有独立配置目录'
    Assert-Integration (Test-Path -LiteralPath $readyA[0]) 'B 启动后 A 的配置仍存在'
    Stop-Fixture $projectA $a
    $b.Refresh()
    Assert-Integration (-not $b.HasExited -and (Test-Path -LiteralPath $readyB[0])) '关闭 A 后 B 仍在运行且目录未被清理'
    Assert-Integration (-not (Test-Path -LiteralPath $readyA[0])) 'A 的临时配置已清理'
    Stop-Fixture $projectB $b
    Assert-Integration (-not (Test-Path -LiteralPath $readyB[0])) 'B 的临时配置已清理'
    Assert-Integration ([IO.File]::ReadAllText((Join-Path $testRoot 'A.out')) -match '最后一次搬运会话: 完成') '真实同步结果被报告为保存完成'
    $manifests = @(Get-ChildItem -LiteralPath (Join-Path $fakeStick 'sessions') -Filter manifest.json -Recurse -File)
    Assert-Integration ($manifests.Count -eq 2) '两个窗口分别保存独立归档'
    $configText = [IO.File]::ReadAllText((Join-Path $fakeStick 'config\settings.json'))
    Assert-Integration ($null -ne ($configText | ConvertFrom-Json)) '并发后的共享设置仍为有效 JSON'

    Remove-Item -LiteralPath (Join-Path $projectA 'stop'), (Join-Path $projectA 'ready.txt') -Force
    $c = Start-Fixture $projectA 'C'
    $readyC = Wait-Ready $projectA $c
    Assert-Integration ($readyC[2] -eq 'True') '重开项目 A 恢复了之前的历史'
    Stop-Fixture $projectA $c
    Assert-Integration (@(Get-ChildItem -LiteralPath $testTemp -Directory -Filter 'aistick-*').Count -eq 0) '正常退出后没有会话临时目录残留'

    # 用真实同步引擎制造最终保存失败，验证失败状态一路传回启动器。
    Remove-Item -LiteralPath (Join-Path $projectA 'stop'), (Join-Path $projectA 'ready.txt') -Force
    $d = Start-Fixture $projectA 'D'
    $readyD = Wait-Ready $projectA $d
    Write-Fixture (Join-Path $readyD[0] '.claude.json') '{"unfinished":'
    Stop-Fixture $projectA $d 2
    Assert-Integration (Test-Path -LiteralPath $readyD[0]) '最终保存失败保留原始配置目录'
    $retained = @(Get-ChildItem -LiteralPath $testTemp -Directory -Filter 'aistick-*')
    Assert-Integration ($retained.Count -eq 1) '仅失败会话保留本机副本'
    $recovery = [IO.File]::ReadAllText((Join-Path $retained[0].FullName '.session-owner.json')) | ConvertFrom-Json
    Assert-Integration ($recovery.recoveryRequired -eq $true) '失败会话持久记录恢复状态'
    Remove-Item -LiteralPath (Join-Path $projectB 'stop'), (Join-Path $projectB 'ready.txt') -Force
    $e = Start-Fixture $projectB 'E'
    $readyE = Wait-Ready $projectB $e
    Assert-Integration (Test-Path -LiteralPath $readyD[0]) '后续启动不会清理待恢复副本'
    Stop-Fixture $projectB $e
    Assert-Integration (Test-Path -LiteralPath $readyD[0]) '其他窗口退出后待恢复副本仍保留'

    # Supply a SecureString within the test process; never add a password to
    # launch.ps1 arguments or environment variables. These values are synthetic.
    . (Join-Path $PSScriptRoot 'lib.ps1')
    . (Join-Path $PSScriptRoot 'vault-menu.ps1')
    $testPassword = ConvertTo-SecureString 'synthetic-launch-password-only' -AsPlainText -Force
    try { $null = Initialize-ToolboxVault -StickRoot $fakeStick -Password $testPassword }
    finally { $testPassword.Dispose() }

    # Exercise the opt-in CC Switch bridge through the real launcher and a
    # synthetic harness. The child reports only a credential hash, never text.
    $vaultPath = Join-Path $fakeStick 'config\credentials.vault.json'
    $vaultHashBeforeCc = (Get-FileHash -LiteralPath $vaultPath -Algorithm SHA256).Hash
    $claudeRegistry = '{"harnesses":[{"id":"claude","name":"Synthetic Claude","enabled":true,"copyToHost":["bin/fixture.exe"],"run":{"pathCandidates":["bin/fixture.exe"],"minBytes":1},"providerEnv":{"baseUrl":"ANTHROPIC_BASE_URL","apiKey":"ANTHROPIC_AUTH_TOKEN","model":"ANTHROPIC_MODEL"},"env":{},"settingsFile":""}]} '
    Write-Fixture (Join-Path $fakeStick 'harness\registry.json') $claudeRegistry
    Write-Fixture (Join-Path $fakeStick 'config\settings.json') '{"provider":"fixture","lastWorkDir":"","workDirByHost":{},"ccSwitchClaudeProvider":true}'
    $ccSettings = Join-Path $fakeStick 'harness\cc-switch\claude\settings.json'
    $hashA = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('synthetic-current-key-A'))).Replace('-', '')
    $hashB = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('synthetic-current-key-B'))).Replace('-', '')
    Write-Fixture $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider-a.invalid/v1","ANTHROPIC_AUTH_TOKEN":"synthetic-current-key-A","ANTHROPIC_MODEL":"cc-model-A"}}'
    Remove-Item -LiteralPath (Join-Path $projectA 'stop'), (Join-Path $projectA 'ready.txt') -Force -ErrorAction SilentlyContinue
    $ccA = Start-Fixture $projectA 'CcA'
    $readyCcA = Wait-Ready $projectA $ccA
    Assert-Integration ($readyCcA[3] -eq 'https://provider-a.invalid/v1' -and $readyCcA[4] -eq 'cc-model-A' -and $readyCcA[5] -eq 'ANTHROPIC_AUTH_TOKEN' -and $readyCcA[6] -eq $hashA) 'CC provider A env/model/credential were injected into the new window'
    Write-Fixture $ccSettings '{"env":{"ANTHROPIC_BASE_URL":"https://provider-b.invalid/v2","ANTHROPIC_API_KEY":"synthetic-current-key-B","ANTHROPIC_MODEL":"cc-model-B"}}'
    Remove-Item -LiteralPath (Join-Path $projectB 'stop'), (Join-Path $projectB 'ready.txt') -Force -ErrorAction SilentlyContinue
    $ccB = Start-Fixture $projectB 'CcB'
    $readyCcB = Wait-Ready $projectB $ccB
    Assert-Integration ($readyCcB[3] -eq 'https://provider-b.invalid/v2' -and $readyCcB[4] -eq 'cc-model-B' -and $readyCcB[5] -eq 'ANTHROPIC_API_KEY' -and $readyCcB[6] -eq $hashB) 'CC provider B change is read by the next window with API_KEY semantics'
    Assert-Integration (([IO.File]::ReadAllLines((Join-Path $projectA 'ready.txt'))[3]) -eq 'https://provider-a.invalid/v1') 'An already running A window keeps its original environment after CC switches to B'
    Assert-Integration ((Get-FileHash -LiteralPath $vaultPath -Algorithm SHA256).Hash -eq $vaultHashBeforeCc) 'CC current mode leaves the encrypted vault unchanged'
    Stop-Fixture $projectA $ccA
    Stop-Fixture $projectB $ccB
    Assert-Integration (-not (Test-Path -LiteralPath $readyCcA[0]) -and -not (Test-Path -LiteralPath $readyCcB[0])) 'Both CC-backed synthetic sessions follow the normal cleanup path'

    Remove-Item -LiteralPath $ccSettings -Force
    Remove-Item -LiteralPath (Join-Path $projectA 'stop'), (Join-Path $projectA 'ready.txt') -Force -ErrorAction SilentlyContinue
    $missing = Start-Fixture $projectA 'CcMissing'
    Assert-Integration ($missing.WaitForExit(20000)) 'Missing CC profile fails without hanging or prompting'
    $missing.Refresh()
    Assert-Integration ($missing.ExitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $projectA 'ready.txt'))) 'Missing CC profile refuses launch rather than falling back'
    Write-Fixture (Join-Path $fakeStick 'harness\registry.json') '{"harnesses":[{"id":"fixture","name":"Fixture","enabled":true,"copyToHost":["bin/fixture.exe"],"run":{"pathCandidates":["bin/fixture.exe"],"minBytes":1},"providerEnv":{"baseUrl":"ANTHROPIC_BASE_URL","apiKey":"FIXTURE_KEY","model":"ANTHROPIC_MODEL"},"env":{},"settingsFile":""}]}'
    Write-Fixture (Join-Path $fakeStick 'config\settings.json') '{"provider":"fixture","lastWorkDir":"","workDirByHost":{},"ccSwitchClaudeProvider":false}'
    $wrapper = @'
param([string]$WorkDir)
function global:Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { return (ConvertTo-SecureString 'synthetic-launch-password-only' -AsPlainText -Force) }
    return ''
}
& (Join-Path $PSScriptRoot 'portable kit\scripts\launch.ps1') -WorkDir $WorkDir
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'synthetic-unlock.ps1'), $wrapper, (New-Object Text.UTF8Encoding($true)))
    Remove-Item -LiteralPath (Join-Path $projectB 'stop'), (Join-Path $projectB 'ready.txt') -Force
    $locked = Start-Fixture $projectB 'Locked'
    Assert-Integration ($locked.WaitForExit(15000)) '锁定保险箱的非交互启动及时结束'
    $locked.Refresh()
    Assert-Integration ($locked.ExitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $projectB 'ready.txt'))) '非交互锁定状态没有启动工具'
    $unlocked = Start-Fixture $projectB 'Unlocked' -VaultMode
    $readyUnlocked = Wait-Ready $projectB $unlocked
    Assert-Integration (Test-Path -LiteralPath $readyUnlocked[0]) '本机输入主密码后加密凭据可启动完整会话'
    Stop-Fixture $projectB $unlocked
    Assert-Integration (-not (Test-Path -LiteralPath $readyUnlocked[0])) '加密凭据会话正常保存并清理'
    Write-Host '启动器集成测试通过。沙盒保留供审查。' -ForegroundColor Green
} catch {
    $failures++
    Write-Host $_.Exception.Message -ForegroundColor Red
    foreach ($file in Get-ChildItem -LiteralPath $testRoot -Filter '*.err' -File -ErrorAction SilentlyContinue) {
        try { Write-Host ([IO.File]::ReadAllText($file.FullName)) } catch { Write-Host "输出仍被占用: $($file.FullName)" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $testRoot -Filter 'fixture-error.txt' -Recurse -File -ErrorAction SilentlyContinue) {
        Write-Host ([IO.File]::ReadAllText($file.FullName))
    }
} finally {
    foreach ($child in $processes) {
        $child.Refresh()
        if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
        $child.Dispose()
    }
    Write-Host "测试沙盒: $testRoot"
}
if ($failures -gt 0) { exit 1 }
exit 0

[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$root = Join-Path ([IO.Path]::GetTempPath()) ('aistick-unified-full-' + [guid]::NewGuid().ToString('N'))
$stick = Join-Path $root 'usb copy'
$project = Join-Path $root 'project'
$testTemp = Join-Path $root 'temp'
$proc = $null
$err = $null
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Fixture([string]$Path,[string]$Text) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllText($Path,$Text,$utf8) }
function Assert-Fixture([bool]$Ok,[string]$Message) { if(-not $Ok){throw $Message}; Write-Host ('PASS: '+$Message) }
try {
    foreach($d in @($stick,$project,$testTemp,(Join-Path $stick 'scripts'))){[void][IO.Directory]::CreateDirectory($d)}
    foreach($f in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stick ('scripts\'+$f.Name))}
    $copiedLaunch=Join-Path $stick 'scripts\launch.ps1'
    $launchText=[IO.File]::ReadAllText($copiedLaunch)
    $line="        . (Join-Path `$PSScriptRoot 'cc-switch-secure-session.ps1') -StickRoot `$StickRoot"
    if(-not $launchText.Contains($line)){throw 'Could not locate the secure-session dot-source line in the synthetic copy.'}
    $launchText=$launchText.Replace($line,'        # synthetic broker function is injected by the wrapper')
    [IO.File]::WriteAllText($copiedLaunch,$launchText,(New-Object Text.UTF8Encoding($true)))
    $harnessSrc=@'
using System;using System.IO;using System.Threading;using System.Text;
public class UnifiedFixture { public static void Main(){ string p=Environment.CurrentDirectory; string c=Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR"); string s=File.ReadAllText(Path.Combine(c,".claude","settings.json")); string e=Environment.GetCommandLineArgs()[0]; File.WriteAllText(Path.Combine(p,"ready.txt"),c+"\n"+s+"\n"+e,new UTF8Encoding(false)); while(!File.Exists(Path.Combine(p,"stop")))Thread.Sleep(100); } }
'@
    $slotId='2.1.1'
    $slot=Join-Path $stick ('tools\harness\claude\slots\'+$slotId)
    $packageRoot=Join-Path $slot 'node_modules\@anthropic-ai\claude-code'
    $exe=Join-Path $packageRoot 'bin\claude.exe'; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $exe))
    $sourcePath=Join-Path $root 'fixture.cs';Write-Fixture $sourcePath $harnessSrc
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){ $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if(-not(Test-Path -LiteralPath $compiler)){throw 'The in-box .NET Framework C# compiler is unavailable for the synthetic fixture.'}
    $compileArgs='/nologo /target:exe /platform:x64 /out:"{0}" "{1}"' -f $exe,$sourcePath
    $compile=Start-Process -FilePath $compiler -ArgumentList $compileArgs -Wait -PassThru -WindowStyle Hidden
    if($compile.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $exe)){throw 'Could not compile the synthetic harness fixture.'}
    $padded=[IO.File]::Open($exe,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$padded.SetLength(1000000)}finally{$padded.Dispose()}
    Write-Fixture (Join-Path $slot 'claude.cmd') '@echo off'
    Write-Fixture (Join-Path $packageRoot 'package.json') '{"name":"@anthropic-ai/claude-code","version":"2.1.1"}'
    . (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')
    Write-CcSwitchManagedClaudeHashManifest -SlotPath $slot -ManifestPath (Join-Path (Split-Path -Parent $slot) ($slotId+'.manifest.json')) -Version $slotId
    Write-Fixture (Join-Path $stick 'harness\registry.json') '{"harnesses":[{"id":"claude","name":"Synthetic Claude","enabled":true,"copyToHost":[],"run":{"pathCandidates":["npm-global/node_modules/@anthropic-ai/claude-code/bin/claude.exe"],"minBytes":1000000},"providerEnv":{"baseUrl":"ANTHROPIC_BASE_URL","apiKey":"ANTHROPIC_AUTH_TOKEN","model":"ANTHROPIC_MODEL"},"env":{},"settingsFile":""}]}'
    Write-Fixture (Join-Path $stick 'config\settings.json') '{"provider":"cc-switch-current","ccSwitchClaudeProvider":true,"ccSwitchUnifiedConfig":true,"lastWorkDir":""}'
    # There is intentionally no harness/providers.json and no real CC Switch store/config.
    $wrapper=Join-Path $root 'run-unified.ps1'
    $wrapperText=@'
param([string]$Project)
function global:Get-CcSecureSessionClaudeLaunchBundle { param([string]$StickRoot)
  $secret=New-Object Security.SecureString; foreach($ch in 'synthetic-only-secret'.ToCharArray()){$secret.AppendChar($ch)}; $secret.MakeReadOnly()
  [pscustomobject]@{Provider=[pscustomobject]@{Name='Synthetic broker provider';BaseUrl='https://example.invalid/v1';AuthEnvironmentName='ANTHROPIC_AUTH_TOKEN';Secret=$secret;Models=@{ANTHROPIC_MODEL='synthetic-model'}};LaunchFiles=@([pscustomobject]@{Path='.claude/settings.json';ContentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"env":{"ANTHROPIC_MODEL":"synthetic-model"},"fixture":"broker-bundle"}'))})}
}
& (Join-Path $PSScriptRoot 'usb copy\scripts\launch.ps1') -WorkDir $Project -NoPrompt -SkipPull
exit $LASTEXITCODE
'@
    Write-Fixture $wrapper $wrapperText
    $out=Join-Path $root 'launch.out';$err=Join-Path $root 'launch.err'
    $oldTemp=$env:TEMP;$oldTmp=$env:TMP
    try{$env:TEMP=$testTemp;$env:TMP=$testTemp;$argsText='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Project "{1}"' -f $wrapper,$project;$proc=Start-Process -FilePath $engine -ArgumentList $argsText -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
    $readyPath=Join-Path $project 'ready.txt';$deadline=(Get-Date).AddSeconds(50)
    while((Get-Date)-lt $deadline -and -not(Test-Path -LiteralPath $readyPath)){$proc.Refresh();if($proc.HasExited){throw 'Launcher exited before fake harness started.'};Start-Sleep -Milliseconds 100}
    Assert-Fixture (Test-Path -LiteralPath $readyPath) 'real launcher starts synthetic harness through unified mode'
    $ready=[IO.File]::ReadAllText($readyPath);$parts=$ready -split "`n",3;$config=$parts[0].Trim();$settings=$parts[1] | ConvertFrom-Json
    Assert-Fixture ($parts.Count -ge 3 -and $parts[2].Trim() -match ('managed-harness\\slots\\'+[regex]::Escape($slotId)+'\\.*claude\.exe$')) 'new unified Claude session launched the committed public version slot copy'
    Assert-Fixture ($settings.fixture -eq 'broker-bundle' -and $settings.env.ANTHROPIC_MODEL -eq 'synthetic-model') 'fake harness can read bundle settings written to its actual ConfigDir'
    $sessionRoot=Split-Path -Parent $config
    while($sessionRoot -and -not(Test-Path -LiteralPath (Join-Path $sessionRoot '.session-owner.json'))){$sessionRoot=Split-Path -Parent $sessionRoot}
    $marker=Join-Path $sessionRoot '.session-owner.json'
    Assert-Fixture (Test-Path -LiteralPath $marker) 'actual launcher registered its session ownership marker'
    Write-Fixture (Join-Path $project 'stop') 'stop'
    if(-not $proc.WaitForExit(45000)){throw 'launcher did not finish normal shutdown'};$proc.Refresh()
    Assert-Fixture $proc.HasExited 'launcher exits after the synthetic harness closes'
    Assert-Fixture (-not(Test-Path -LiteralPath $config)) 'normal launcher shutdown cleans the actual session ConfigDir'
    $output=[IO.File]::ReadAllText($out)
    Assert-Fixture ($output -match '最后一次搬运会话: 完成') 'normal shutdown completes save path'
    Write-Host 'NOTE: end-to-end launcher uses a wrapper-injected synthetic broker function; named-pipe protocol is covered separately by test-cc-switch-ipc.ps1.'
} catch {
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    if($proc){$proc.Refresh();if(-not $proc.HasExited){$proc.Kill();[void]$proc.WaitForExit(5000)};try{if(Test-Path $err){Write-Host ([IO.File]::ReadAllText($err))}}catch{}}
    exit 1
} finally {
    if($proc){$proc.Refresh();if(-not $proc.HasExited){$proc.Kill();[void]$proc.WaitForExit(5000)};$proc.Dispose()}
    if(Test-Path $root){$resolved=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if((Split-Path -Parent $resolved).TrimEnd('\','/') -ceq $tempRoot -and (Split-Path -Leaf $resolved) -match '^aistick-unified-full-[0-9a-f]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}}
}

[CmdletBinding()]
param([ValidateSet('None','InternetClient')][string]$NetworkMode = 'None')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'appcontainer-probe.ps1')
. (Join-Path $PSScriptRoot 'cc-switch-harness-runtime.ps1')

function Assert-PlainTree {
    param([string]$Path)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push([IO.Path]::GetFullPath($Path))
    while ($stack.Count) {
        $current = $stack.Pop()
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Node/npm fixture contains a reparse point.' }
        if ($item.PSIsContainer) { foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current,'*',[IO.SearchOption]::TopDirectoryOnly)) { $stack.Push($child) } }
    }
}

function Copy-PlainTree {
    param([string]$Source,[string]$Destination)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Source)) {
        $item = Get-Item -LiteralPath $entry -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Node/npm source contains a reparse point.' }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-PlainTree -Source $entry -Destination $target }
        else { [IO.File]::Copy($entry,$target,$false) }
    }
}

$root = $null
$state = $null
$safeToRemove = $false
try {
    $sourceStatus = Get-CcSwitchHarnessRuntimeStatus -StickRoot 'E:\'
    if (-not $sourceStatus.Ready) { throw 'USB Node/npm runtime is incomplete.' }
    $sourceRoot = [IO.Path]::GetFullPath($sourceStatus.RuntimeRoot)
    if (-not [string]::Equals($sourceRoot,'E:\runtime\node',[StringComparison]::OrdinalIgnoreCase)) { throw 'Expected the verified USB runtime at E:\runtime\node.' }
    Assert-PlainTree -Path $sourceRoot
    $sourceClaude = 'E:\npm-global\node_modules\@anthropic-ai\claude-code\node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe'
    if (-not [IO.File]::Exists($sourceClaude)) { throw 'Expected nested USB Claude executable was not found.' }

    $root = New-AppContainerProbeFixtureRoot
    $app = Join-Path $root 'app'
    $stick = Join-Path $root 'stick'
    $runtime = Join-Path $root 'runtime'
    $profile = Join-Path $runtime 'profile'
    $nodeRoot = Join-Path $runtime 'node'
    $claudeRoot = Join-Path $stick 'claude-package'
    $temp = Join-Path $runtime 'temp'
    foreach ($dir in @($app,$stick,$runtime,$profile,(Join-Path $profile 'AppData\Roaming'),(Join-Path $profile 'AppData\Local'),$temp)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $npmState = Join-Path $stick 'npm-state'
    foreach ($dir in @($npmState,(Join-Path $npmState 'cache'),(Join-Path $npmState 'prefix'))) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    foreach ($file in @((Join-Path $npmState 'user.npmrc'),(Join-Path $npmState 'global.npmrc'))) { [IO.File]::WriteAllText($file,'',(New-Object Text.UTF8Encoding($false))) }
    Copy-PlainTree -Source $sourceRoot -Destination $nodeRoot
    [IO.Directory]::CreateDirectory($claudeRoot) | Out-Null
    [IO.File]::Copy($sourceClaude,(Join-Path $claudeRoot 'claude.exe'),$false)
    Assert-PlainTree -Path $nodeRoot

    $sourceNodeHash = (Get-FileHash -LiteralPath $sourceStatus.NodeExe -Algorithm SHA256).Hash
    $copyNodeHash = (Get-FileHash -LiteralPath (Join-Path $nodeRoot 'node.exe') -Algorithm SHA256).Hash
    $sourceNpmCliHash = (Get-FileHash -LiteralPath $sourceStatus.NpmCli -Algorithm SHA256).Hash
    $copyNpmCliHash = (Get-FileHash -LiteralPath (Join-Path $nodeRoot 'node_modules\npm\bin\npm-cli.js') -Algorithm SHA256).Hash
    $sourceClaudeHash = (Get-FileHash -LiteralPath $sourceClaude -Algorithm SHA256).Hash
    $copyClaudeHash = (Get-FileHash -LiteralPath (Join-Path $claudeRoot 'claude.exe') -Algorithm SHA256).Hash
    if ($sourceNodeHash -cne $copyNodeHash -or $sourceNpmCliHash -cne $copyNpmCliHash -or $sourceClaudeHash -cne $copyClaudeHash) { throw 'Copied runtime hash does not match the verified USB source.' }

    $source = @'
use std::{env, os::windows::process::CommandExt, process::{Command, Stdio}};
const CREATE_NO_WINDOW: u32 = 0x08000000;
fn quote(s: &str) -> String { s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r") }
fn capture(label: &str, command: &mut Command, output: &mut String) {
    match command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).creation_flags(CREATE_NO_WINDOW).output() {
        Ok(result) => output.push_str(&format!("\"{}Exit\":{},\"{}Stdout\":\"{}\",\"{}Stderr\":\"{}\",", label, result.status.code().unwrap_or(-1), label, quote(&String::from_utf8_lossy(&result.stdout)), label, quote(&String::from_utf8_lossy(&result.stderr)))),
        Err(error) => output.push_str(&format!("\"{}SpawnErrorKind\":\"{:?}\",\"{}SpawnErrorCode\":{},", label, error.kind(), label, error.raw_os_error().unwrap_or(-1))),
    }
}
fn main() {
    let args: Vec<String> = env::args().collect();
    let node = &args[1]; let npm = &args[2]; let cmdexe = &args[3]; let node_root = &args[4]; let npm_cli = &args[5]; let stick = &args[6]; let profile = &args[7]; let temp = &args[8]; let owned_file = &args[9]; let result_path = &args[10]; let claude_exe = &args[11]; let system_root = env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_string());
    let path = format!("{};{}\\System32", node_root, system_root);
    let mut report = String::from("{");
    let appdata = format!("{}\\AppData\\Roaming", profile); let local = format!("{}\\AppData\\Local", profile); let prefix = format!("{}\\npm-state\\prefix", stick); let cache = format!("{}\\npm-state\\cache", stick); let user_config = format!("{}\\npm-state\\user.npmrc", stick); let global_config = format!("{}\\npm-state\\global.npmrc", stick);
    let mut node_version = Command::new(node); node_version.arg("--version").env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("nodeVersion", &mut node_version, &mut report);
    let mut realpath = Command::new(node); realpath.args(["-e", "console.log(require('fs').realpathSync(process.execPath))"]).env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("nodeRealpath", &mut realpath, &mut report);
    let mut native_realpath = Command::new(node); native_realpath.args(["-e", "console.log(require('fs').realpathSync.native(process.execPath))"]).env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("nodeNativeRealpathExe", &mut native_realpath, &mut report);
    let mut owned_realpath = Command::new(node); owned_realpath.args(["-e", "console.log(require('fs').realpathSync.native(process.argv[1]))", owned_file]).env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("nodeNativeRealpathOwned", &mut owned_realpath, &mut report);
    let mut owned_realpath_js = Command::new(node); owned_realpath_js.args(["-e", "console.log(require('fs').realpathSync(process.argv[1]))", owned_file]).env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("nodeRealpathOwned", &mut owned_realpath_js, &mut report);
    let mut npm_cli_version = Command::new(node); npm_cli_version.args(["--preserve-symlinks", "--preserve-symlinks-main", npm_cli, "--version"]).env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile);
    capture("npmCliVersionWithPreserveSymlinks", &mut npm_cli_version, &mut report);
    let npm_env = |command: &mut Command| { command.env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("ComSpec", cmdexe).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile).env("APPDATA", &appdata).env("LOCALAPPDATA", &local).env("npm_config_prefix", &prefix).env("npm_config_cache", &cache).env("npm_config_userconfig", &user_config).env("npm_config_globalconfig", &global_config).env("npm_config_registry", "https://registry.npmjs.org/").env("npm_config_update_notifier", "false").env("npm_config_audit", "false").env("npm_config_fund", "false").env("NO_PROXY", "*"); };
    let mut npm_version = Command::new(cmdexe); npm_version.raw_arg(format!("/D /S /C call \"{}\" --version", npm)); npm_env(&mut npm_version);
    capture("npmVersion", &mut npm_version, &mut report);
    let mut npm_version_preserve = Command::new(cmdexe); npm_version_preserve.raw_arg(format!("/D /S /C call \"{}\" --version", npm)); npm_env(&mut npm_version_preserve); npm_version_preserve.env("NODE_OPTIONS", "--preserve-symlinks --preserve-symlinks-main");
    capture("npmVersionWithPreserveSymlinks", &mut npm_version_preserve, &mut report);
    let mut claude_version = Command::new(claude_exe); claude_version.arg("--version").env_clear().env("SystemRoot", &system_root).env("WINDIR", &system_root).env("PATH", &path).env("TEMP", temp).env("TMP", temp).env("HOME", stick).env("USERPROFILE", profile).env("APPDATA", &appdata).env("LOCALAPPDATA", &local);
    capture("claudeVersion", &mut claude_version, &mut report);
    let mut npm_view = Command::new(cmdexe); npm_view.raw_arg(format!("/D /S /C call \"{}\" view @anthropic-ai/claude-code version --json", npm)); npm_env(&mut npm_view); npm_view.env("NODE_OPTIONS", "--preserve-symlinks --preserve-symlinks-main");
    capture("officialNpmViewClaudeVersion", &mut npm_view, &mut report);
    report.push_str("\"Registry\":\"https://registry.npmjs.org/\",\"PackageInstallRequested\":false,\"ModelRequestMade\":false}");
    std::fs::write(result_path, report).expect("write report within synthetic fixture");
}
'@
    $sourcePath = Join-Path $runtime 'managed-node-npm-probe.rs'
    $exe = Join-Path $app 'cc-switch.exe'
    $resultPath = Join-Path $stick 'managed-node-npm-result.json'
    [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))
    $rustc = (Get-Command rustc.exe -ErrorAction Stop).Source
    $buildOut = Join-Path $runtime 'build.stdout.txt'
    $buildErr = Join-Path $runtime 'build.stderr.txt'
    $build = Start-Process -FilePath $rustc -ArgumentList @('--edition=2021',$sourcePath,'-o',$exe) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $buildOut -RedirectStandardError $buildErr
    if ($build.ExitCode -ne 0 -or -not [IO.File]::Exists($exe)) { throw ('Rust managed Node/npm probe did not build: ' + [IO.File]::ReadAllText($buildErr)) }

    $fixturePath = Join-Path $root 'fixture.json'
    $environment = [ordered]@{HOME=$stick;USERPROFILE=$profile;APPDATA=(Join-Path $profile 'AppData\Roaming');LOCALAPPDATA=(Join-Path $profile 'AppData\Local');CC_SWITCH_TEST_HOME=$stick;TEMP=$temp;TMP=$temp}
    $ownedFile = Join-Path $stick 'owned-realpath-check.txt'
    [IO.File]::WriteAllText($ownedFile,'owned-file-realpath-check',(New-Object Text.UTF8Encoding($false)))
    $fixture = [ordered]@{Root=$root;Exe=$exe;StickRoot=$stick;RuntimeRoot=$runtime;Environment=$environment;Arguments=@((Join-Path $nodeRoot 'node.exe'),(Join-Path $nodeRoot 'npm.cmd'),(Join-Path $env:SystemRoot 'System32\cmd.exe'),$nodeRoot,(Join-Path $nodeRoot 'node_modules\npm\bin\npm-cli.js'),$stick,$profile,$temp,$ownedFile,$resultPath,(Join-Path $claudeRoot 'claude.exe'))}
    [IO.File]::WriteAllText($fixturePath,(ConvertTo-Json -InputObject $fixture -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $fresh = Read-AppContainerFixture -Path $fixturePath
    $state = Start-AppContainerProbeProcess -Fixture $fresh -NetworkMode $NetworkMode
    $wait = Wait-AppContainerProbeProcess -State $state -TimeoutSeconds 60
    if (-not $wait.Completed -or $wait.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)) { throw 'Managed Node/npm AppContainer worker failed or timed out.' }
    $result = [IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $report = [ordered]@{
        schema=2;Test='USB Node/npm and nested Claude executable copied to owned NTFS and run in AppContainer';SourceRuntime='E:\runtime\node';NetworkMode=$NetworkMode
        SourceNodeVersion=$sourceStatus.NodeVersion;SourceNpmVersion=$sourceStatus.NpmVersion
        NodeBinaryHashMatches=($sourceNodeHash -ceq $copyNodeHash);NpmCliHashMatches=($sourceNpmCliHash -ceq $copyNpmCliHash);NestedClaudeHashMatches=($sourceClaudeHash -ceq $copyClaudeHash)
        NodeVersionExit=$result.nodeVersionExit;NodeVersionStdout=([string]$result.nodeVersionStdout).Trim();NodeVersionStderr=$result.nodeVersionStderr
        NodeRealpathExit=$result.nodeRealpathExit;NodeRealpathStdout=([string]$result.nodeRealpathStdout).Trim();NodeRealpathStderr=$result.nodeRealpathStderr
        NodeNativeRealpathExeExit=$result.nodeNativeRealpathExeExit;NodeNativeRealpathExeStdout=([string]$result.nodeNativeRealpathExeStdout).Trim();NodeNativeRealpathExeStderr=$result.nodeNativeRealpathExeStderr
        NodeNativeRealpathOwnedExit=$result.nodeNativeRealpathOwnedExit;NodeNativeRealpathOwnedStdout=([string]$result.nodeNativeRealpathOwnedStdout).Trim();NodeNativeRealpathOwnedStderr=$result.nodeNativeRealpathOwnedStderr
        NodeRealpathOwnedExit=$result.nodeRealpathOwnedExit;NodeRealpathOwnedStdout=([string]$result.nodeRealpathOwnedStdout).Trim();NodeRealpathOwnedStderr=$result.nodeRealpathOwnedStderr
        NpmCliVersionWithPreserveSymlinksExit=$result.npmCliVersionWithPreserveSymlinksExit;NpmCliVersionWithPreserveSymlinksStdout=([string]$result.npmCliVersionWithPreserveSymlinksStdout).Trim();NpmCliVersionWithPreserveSymlinksStderr=$result.npmCliVersionWithPreserveSymlinksStderr
        NpmVersionExit=$result.npmVersionExit;NpmVersionStdout=([string]$result.npmVersionStdout).Trim();NpmVersionStderr=$result.npmVersionStderr
        NpmVersionWithPreserveSymlinksExit=$result.npmVersionWithPreserveSymlinksExit;NpmVersionWithPreserveSymlinksStdout=([string]$result.npmVersionWithPreserveSymlinksStdout).Trim();NpmVersionWithPreserveSymlinksStderr=$result.npmVersionWithPreserveSymlinksStderr
        ClaudeVersionExit=$result.claudeVersionExit;ClaudeVersionStdout=([string]$result.claudeVersionStdout).Trim();ClaudeVersionStderr=$result.claudeVersionStderr
        OfficialNpmViewClaudeVersionExit=$result.officialNpmViewClaudeVersionExit;OfficialNpmViewClaudeVersionStdout=([string]$result.officialNpmViewClaudeVersionStdout).Trim();OfficialNpmViewClaudeVersionStderr=$result.officialNpmViewClaudeVersionStderr
        PackageInstallRequested=$false;ModelRequestMade=$false;SecretsUsed=$false
    }
    $reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\cc-appcontainer-managed-node-npm-latest.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $reportPath)) | Out-Null
    [IO.File]::WriteAllText($reportPath,(ConvertTo-Json -InputObject $report -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Write-Output ([pscustomobject]$report)
    Complete-AppContainerProbeProcess -State $state
    $state = $null
    $safeToRemove = $true
} finally {
    if ($state) { try { Complete-AppContainerProbeProcess -State $state; $state=$null; $safeToRemove=$true } catch { Write-Warning 'AppContainer cleanup failed; preserving its owned test fixture.' } }
    if ($root -and $safeToRemove -and [IO.Directory]::Exists($root)) {
        $full=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $leaf=Split-Path -Leaf $full
        $parsed=[guid]::Empty
        if ([string]::Equals((Split-Path -Parent $full).TrimEnd('\','/'),$tempRoot,[StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('aistick-ac-probe-',[StringComparison]::Ordinal) -and [guid]::TryParseExact($leaf.Substring('aistick-ac-probe-'.Length),'N',[ref]$parsed)) {
            Assert-AppContainerProbePlainTree -Path $root -Boundary $tempRoot
            $marker=Join-Path $root '.aistick-ac-probe'
            if ([IO.File]::Exists($marker) -and [IO.File]::ReadAllText($marker).Trim() -ceq 'synthetic appcontainer fixture v1') { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        }
    }
}
